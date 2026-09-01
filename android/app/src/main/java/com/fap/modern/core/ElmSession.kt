package com.fap.modern.core

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.util.ArrayDeque
import java.util.concurrent.ConcurrentHashMap
import kotlin.math.min

enum class ConnState { DISCONNECTED, CONNECTING, CONNECTED, ERROR }

enum class InitMode { AUTO, FAST_KLINE, SLOW_KLINE }

/**
 * The reverse-engineered FAP comm core, re-implemented cleanly.
 *
 * Connect sequence (from out/fap_session_sequence.md, K-line ISO 14230-4 KWP):
 *   reset  -> ATZ ATD ATE0 ATL0 ATH0 ATS0 ATAL
 *   fast   -> ATSP5 ATSH8110F1 ATFI ATSW00 ; "81"->C1 ; "1003"/"10C0"/"10A4"->50
 *   5-baud -> ATSP4 ATSH8110F1 ATSW00      ; "81"->C1 ; ...
 * Keep-alive: "3E" (or "3E00" after 1003) when idle > ~2.5 s.
 * Live reads: bare service-21 pages 21CB 21CA 21C0 21C1 21C2.
 */
class ElmSession(private val profile: V4621Profile = V4621Profile) {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var loopJob: Job? = null
    private var transport: ElmTransport? = null

    private val _state = MutableStateFlow(ConnState.DISCONNECTED)
    val state: StateFlow<ConnState> = _state.asStateFlow()

    private val _statusText = MutableStateFlow("Disconnected")
    val statusText: StateFlow<String> = _statusText.asStateFlow()

    private val _values = MutableStateFlow<Map<String, Sample>>(emptyMap())
    val values: StateFlow<Map<String, Sample>> = _values.asStateFlow()

    private val history = ConcurrentHashMap<String, ArrayDeque<Point>>()
    private val historyCap = 6000

    var logger: CsvLogger? = null
    var initMode: InitMode = InitMode.AUTO
    @Volatile var loggingEnabled: Boolean = true

    val isConnected: Boolean get() = _state.value == ConnState.CONNECTED
    val isLogging: Boolean get() = logger?.isRunning == true

    /** Start/stop CSV recording while already connected. */
    fun startLogging() { if (isConnected) logger?.start(profile.params) }
    fun stopLogging() { logger?.stop() }

    private var extended = false
    @Volatile private var lastCmdMs = 0L

    val isBusy: Boolean get() = loopJob?.isActive == true

    fun connect(cfg: TransportConfig) {
        if (isBusy) return
        history.clear()
        _values.value = emptyMap()
        _state.value = ConnState.CONNECTING
        _statusText.value = "Connecting…"
        val t: ElmTransport = when (cfg) {
            is TransportConfig.Bluetooth -> BluetoothTransport(cfg)
            is TransportConfig.Wifi -> WifiTransport(cfg)
        }
        transport = t
        loopJob = scope.launch { runSession(t) }
    }

    fun disconnect() {
        loopJob?.cancel()
        loopJob = null
        closeTransport()
        logger?.stop()
        _state.value = ConnState.DISCONNECTED
        _statusText.value = "Disconnected"
    }

    fun shutdown() {
        disconnect()
        scope.cancel()
    }

    fun historySnapshot(key: String): List<Point> {
        val dq = history[key] ?: return emptyList()
        synchronized(dq) { return ArrayList(dq) }
    }

    private suspend fun runSession(t: ElmTransport) {
        try {
            t.open()
            _statusText.value = "Adapter open, initialising…"
            val ok = initEcu()
            if (!ok) {
                _statusText.value = "ECU init failed (check adapter / ignition)"
                _state.value = ConnState.ERROR
                closeTransport()
                return
            }
            _state.value = ConnState.CONNECTED
            _statusText.value = "Connected (${if (extended) "extended" else "default"} session)"
            if (loggingEnabled) logger?.start(profile.params)
            pollLoop()
        } catch (e: Exception) {
            _statusText.value = "Error: ${e.message}"
            _state.value = ConnState.ERROR
        } finally {
            logger?.stop()
            closeTransport()
        }
    }

    private fun initEcu() : Boolean {
        // Common ELM reset.
        send("ATZ", 2500)
        send("ATD", 800)
        send("ATE0", 800)
        send("ATL0", 800)
        send("ATH0", 800)
        send("ATS0", 800)
        send("ATAL", 800)

        val order = when (initMode) {
            InitMode.FAST_KLINE -> listOf(true)
            InitMode.SLOW_KLINE -> listOf(false)
            InitMode.AUTO -> listOf(true, false)
        }
        for (fast in order) {
            if (tryKlineInit(fast)) return true
        }
        return false
    }

    private fun tryKlineInit(fast: Boolean): Boolean {
        send(if (fast) "ATSP5" else "ATSP4", 800)
        send("ATSH8110F1", 800)
        if (fast) send("ATFI", 1500)
        send("ATSW00", 800)

        val start = ResponseParser.clean(send("81", 3000))
        if (!start.contains("C1")) return false

        // StartDiagnosticSession(03) -> extended keep-alive if positive.
        val ext = ResponseParser.clean(send("1003", 2000))
        extended = ext.contains("50")
        send("10C0", 2000)
        send("10A4", 2000)
        return true
    }

    private suspend fun pollLoop() {
        val pages = profile.pages
        val live = HashMap<String, Sample>()
        while (scope.isActive && loopJob?.isActive == true) {
            keepAliveIfIdle()
            for (page in pages) {
                if (loopJob?.isActive != true) break
                val reply = send(page, 1200)
                val now = System.currentTimeMillis()
                if (ResponseParser.isError(reply)) continue
                val clean = ResponseParser.clean(reply)
                for (def in profile.paramsForPage(page)) {
                    val raw = ResponseParser.extractRaw(clean, def)
                    val sample = if (raw == null) {
                        Sample(0.0, now, false)
                    } else {
                        Sample(def.compute(raw), now, true)
                    }
                    live[def.key] = sample
                    if (sample.valid) appendHistory(def.key, Point(now, sample.value))
                }
            }
            _values.value = HashMap(live)
            logger?.logRow(System.currentTimeMillis(), live)
        }
    }

    private fun keepAliveIfIdle() {
        val idle = System.currentTimeMillis() - lastCmdMs
        if (idle > 2500) send(if (extended) "3E00" else "3E", 800)
    }

    private fun appendHistory(key: String, p: Point) {
        val dq = history.getOrPut(key) { ArrayDeque() }
        synchronized(dq) {
            dq.addLast(p)
            while (dq.size > historyCap) dq.removeFirst()
        }
    }

    /** Sends one ELM command (adds CR) and reads until the '>' prompt or [timeoutMs]. */
    private fun send(cmd: String, timeoutMs: Long): String {
        val t = transport ?: return ""
        val out = t.output()
        val inp = t.input()
        out.write((cmd + "\r").toByteArray(Charsets.US_ASCII))
        out.flush()
        lastCmdMs = System.currentTimeMillis()

        val sb = StringBuilder()
        val buf = ByteArray(512)
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            val avail = try { inp.available() } catch (e: Exception) { -1 }
            if (avail < 0) break
            if (avail > 0) {
                val n = try { inp.read(buf, 0, min(avail, buf.size)) } catch (e: Exception) { -1 }
                if (n < 0) break
                for (i in 0 until n) sb.append((buf[i].toInt() and 0xFF).toChar())
                if (sb.indexOf(">") >= 0) break
            } else {
                try { Thread.sleep(4) } catch (_: InterruptedException) { break }
            }
        }
        return sb.toString()
    }

    private fun closeTransport() {
        try { transport?.close() } catch (_: Exception) {}
        transport = null
    }
}
