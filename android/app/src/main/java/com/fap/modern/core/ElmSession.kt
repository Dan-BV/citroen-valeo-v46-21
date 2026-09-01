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
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.ArrayDeque
import java.util.concurrent.ConcurrentHashMap
import kotlin.math.min

enum class ConnState { DISCONNECTED, CONNECTING, CONNECTED, ERROR }

/**
 * Talks to the Valeo V46.21 engine ECU over CAN.
 *
 * KWP2000 on ISO 15765-2, request id 6A8, response id 688, taken from the
 * Diagbox databases and confirmed on the car. `81` opens the session and is
 * mandatory: the proprietary `21xx` pages answer nothing without it.
 *
 * K-line is not implemented - neither adapter to hand has a working K-line
 * transceiver, and this ECU is reached over CAN anyway.
 */
class ElmSession(
    private val profile: Profile,
    private val scanProfile: ScanProfile? = null,
) {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var loopJob: Job? = null
    private var transport: ElmTransport? = null

    /**
     * One adapter, several callers. A Mutex rather than a busy flag because it
     * queues fairly: the poll loop re-takes the lock in the same breath it
     * releases it, and a caller polling a flag would never catch it free.
     */
    private val io = Mutex()

    private val _state = MutableStateFlow(ConnState.DISCONNECTED)
    val state: StateFlow<ConnState> = _state.asStateFlow()

    private val _statusText = MutableStateFlow("Отключено")
    val statusText: StateFlow<String> = _statusText.asStateFlow()

    private val _values = MutableStateFlow<Map<String, Sample>>(emptyMap())
    val values: StateFlow<Map<String, Sample>> = _values.asStateFlow()

    /** Requests of pages the ECU did not answer when probed. */
    private val _deadPages = MutableStateFlow<Set<String>>(emptySet())
    val deadPages: StateFlow<Set<String>> = _deadPages.asStateFlow()

    private val history = ConcurrentHashMap<String, ArrayDeque<Point>>()
    private val historyCap = 6000

    /** Last raw reply per page, for the on-screen page diagnostic. */
    private val lastReply = ConcurrentHashMap<String, String>()

    var logger: CsvLogger? = null

    @Volatile
    var loggingEnabled: Boolean = true

    private val skip = HashSet<String>()
    private val noCount = HashSet<String>()
    private var curHeader: String? = null
    private var cycle = 0L

    @Volatile
    private var lastCmdMs = 0L

    val isConnected: Boolean get() = _state.value == ConnState.CONNECTED
    val isLogging: Boolean get() = logger?.isRunning == true
    val isBusy: Boolean get() = loopJob?.isActive == true

    fun rawReply(page: String): String? = lastReply[page]

    fun startLogging() { if (isConnected) logger?.start(profile.fields) }
    fun stopLogging() { logger?.stop() }

    fun connect(cfg: TransportConfig) {
        if (isBusy) return
        history.clear()
        lastReply.clear()
        skip.clear()
        noCount.clear()
        curHeader = null
        cycle = 0
        _values.value = emptyMap()
        _deadPages.value = emptySet()
        _state.value = ConnState.CONNECTING
        _statusText.value = "Подключение…"
        val t: ElmTransport = when (cfg) {
            is TransportConfig.Bluetooth -> BluetoothTransport(cfg)
            is TransportConfig.Ble -> BleTransport(cfg)
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
        _statusText.value = "Отключено"
    }

    fun shutdown() {
        disconnect()
        scope.cancel()
    }

    fun historySnapshot(key: String): List<Point> {
        val dq = history[key] ?: return emptyList()
        synchronized(dq) { return ArrayList(dq) }
    }

    // ----------------------------------------------------------- session

    private suspend fun runSession(t: ElmTransport) {
        try {
            t.open()
            _statusText.value = "Адаптер открыт, инициализация ЭБУ…"
            val ok = io.withLock { initEcu() }
            if (!ok) {
                _statusText.value = "ЭБУ не отвечает (адаптер / зажигание)"
                _state.value = ConnState.ERROR
                closeTransport()
                return
            }
            _state.value = ConnState.CONNECTED
            _statusText.value = "Проверка доступных страниц…"
            val dead = probePages()
            _deadPages.value = dead
            _statusText.value =
                "Подключено" + if (dead.isEmpty()) "" else " · без ответа: ${dead.size}"
            if (loggingEnabled) logger?.start(profile.fields)
            pollLoop()
        } catch (e: Exception) {
            _statusText.value = "Ошибка: ${e.message}"
            _state.value = ConnState.ERROR
        } finally {
            logger?.stop()
            closeTransport()
        }
    }

    private fun initEcu(): Boolean {
        send("ATZ", 2500); send("ATD", 800); send("ATE0", 800)
        send("ATL0", 800); send("ATH0", 800); send("ATS0", 800); send("ATAL", 800)
        send("ATSP6", 800)
        applyHeader(profile.canRequest, profile.canResponse)
        send("ATFCSH" + profile.canRequest, 800)
        send("ATFCSD300000", 800)
        send("ATFCSM1", 800)
        send("81", 2500)
        val probe = profile.pages.firstOrNull() ?: return true
        val reply = send(withCount(probe.request), 2500)
        return !Frames.isError(reply) && Frames.clean(reply).contains(probe.marker)
    }

    private fun applyHeader(header: String, receive: String) {
        if (curHeader == header) return
        send("ATSH$header", 600)
        send("ATCRA$receive", 600)
        curHeader = header
    }

    private fun withCount(request: String) =
        Frames.withResponseCount(request, !noCount.contains(request))

    /**
     * Ask every page once and remember the ones this ECU does not answer, so
     * the cycle stops paying an adapter timeout for them. A page that fails
     * with the response-count suffix is retried once without it, since some
     * adapter clones mishandle it.
     */
    private suspend fun probePages(): Set<String> = io.withLock {
        for (page in profile.pages) {
            applyHeader(page.header, page.receive)
            if (tryPage(page)) continue
            noCount.add(page.request)
            if (tryPage(page)) continue
            noCount.remove(page.request)
            skip.add(page.request)
        }
        HashSet(skip)
    }

    private fun tryPage(page: Page): Boolean {
        val reply = send(withCount(page.request), 1500)
        lastReply[page.request] = reply.trim()
        if (Frames.isError(reply)) return false
        val clean = Frames.clean(reply)
        val first = page.fields.firstOrNull() ?: return clean.contains(page.marker)
        return Frames.extract(clean, page.marker, first) != null
    }

    private suspend fun pollLoop() {
        val live = HashMap<String, Sample>()
        while (scope.isActive && loopJob?.isActive == true) {
            cycle++
            val started = System.currentTimeMillis()
            for (page in profile.pages) {
                if (loopJob?.isActive != true) break
                // Slow pages hold still while driving; dead ones get an
                // occasional retry in case the failure was transient.
                if (page.slow && cycle % 10L != 1L) continue
                if (skip.contains(page.request) && cycle % 100L != 0L) continue

                val reply = io.withLock {
                    applyHeader(page.header, page.receive)
                    send(withCount(page.request), 1200)
                }
                val now = System.currentTimeMillis()
                lastReply[page.request] = reply.trim()
                if (Frames.isError(reply)) continue
                skip.remove(page.request)
                val clean = Frames.clean(reply)
                for (f in page.fields) {
                    val raw = Frames.extract(clean, page.marker, f)
                    val sample = if (raw == null) Sample(0.0, 0, now, false)
                    else Sample(f.compute(raw), raw, now, true)
                    live[f.key] = sample
                    if (sample.valid && f.kind == ValueKind.NUMERIC) {
                        appendHistory(f.key, Point(now, sample.value))
                    }
                }
            }
            val elapsed = System.currentTimeMillis() - started
            _values.value = HashMap(live)
            _statusText.value = "Подключено · цикл $elapsed мс"
            logger?.logRow(System.currentTimeMillis(), live)
            keepAliveIfIdle()
        }
    }

    private suspend fun keepAliveIfIdle() {
        if (System.currentTimeMillis() - lastCmdMs > 2500) {
            io.withLock { send("3E", 800) }
        }
    }

    // -------------------------------------------------------- on demand

    /** `17 FF 00` -> `57 <count> [ code(2) status(1) ] x count`. */
    suspend fun readDtc(): List<Dtc> = io.withLock {
        applyHeader(profile.canRequest, profile.canResponse)
        val reply = send("17FF00", 3000)
        if (Frames.isError(reply)) throw IllegalStateException("нет ответа на 17FF00")
        val c = Frames.clean(reply)
        if (!c.startsWith("57")) throw IllegalStateException("неожиданный ответ: ${c.take(24)}")
        val count = c.substring(2, 4).toIntOrNull(16) ?: 0
        (0 until count).mapNotNull { i ->
            val at = 4 + i * 6
            if (at + 6 > c.length) {
                null
            } else {
                val code = c.substring(at, at + 4)
                Dtc(code, c.substring(at + 4, at + 6), profile.dtc[code])
            }
        }
    }

    suspend fun clearDtc(): Boolean = io.withLock {
        applyHeader(profile.canRequest, profile.canResponse)
        val c = Frames.clean(send("14FF00", 3000))
        if (!c.startsWith("54")) {
            val what = if (c.isEmpty()) "нет ответа" else c.take(24)
            throw IllegalStateException("ЭБУ не подтвердил стирание: $what")
        }
        true
    }

    suspend fun readIdent(): List<IdentBlock> = io.withLock {
        applyHeader(profile.canRequest, profile.canResponse)
        val out = ArrayList<IdentBlock>()
        for (block in profile.ident) {
            val reply = send(block.request, 2500)
            if (Frames.isError(reply)) continue
            val c = Frames.clean(reply)
            if (!c.contains(block.marker)) continue
            val rows = ArrayList<Pair<String, String>>()
            for (f in block.fields) {
                val hex = Frames.extractHex(c, block.marker, f) ?: continue
                val raw = hex.toIntOrNull(16)
                val state = if (raw != null) f.states?.get(raw) else null
                val shown = state ?: if (f.isHex) hex else (raw?.toString() ?: hex)
                rows.add(f.label to shown)
            }
            if (rows.isNotEmpty()) out.add(IdentBlock(block.title, rows))
        }
        out
    }

    /**
     * Walk every diagnostic address of the platform: open a session, ask the
     * recognition frame, and read the fault memory of whatever answers. Holds
     * the same lock as the poll loop, so live values freeze meanwhile.
     */
    suspend fun scanModules(onProgress: (Int, Int, String) -> Unit): ScanResult {
        val sp = scanProfile ?: return ScanResult(emptyList(), emptyList())
        return io.withLock {
            val byAddr = sp.byAddress()
            val found = ArrayList<ScanHit>()
            val silent = ArrayList<ScanTarget>()
            // Absent modules cost one adapter timeout each, so shorten it for
            // the sweep (0x32 = 50 * 4 ms) and restore the default afterwards.
            send("ATST32", 600)
            try {
                var i = 0
                for ((addr, candidates) in byAddr) {
                    i++
                    onProgress(i, byAddr.size, addr)
                    curHeader = null
                    applyHeader(addr, candidates[0].response)
                    send("ATFCSH$addr", 400)
                    var hitTarget: ScanTarget? = null
                    var hitIdent = ""
                    for (t in candidates) {
                        if (t.init.isNotEmpty()) {
                            val a = Frames.clean(send(t.init, 1200))
                            if (!a.startsWith(t.initAnswer.take(2))) continue
                        }
                        val rr = Frames.clean(send(t.reco, 1500))
                        if (!rr.startsWith(t.recoAnswer)) continue
                        hitTarget = t
                        hitIdent = rr.substring(t.recoAnswer.length)
                        break
                    }
                    val target = hitTarget
                    if (target == null) {
                        silent.add(candidates[0])
                    } else {
                        val faults = target.faults?.let { readFaultsOf(it) }
                        found.add(ScanHit(target, hitIdent, faults))
                    }
                }
            } finally {
                send("ATSTFF", 600)
                curHeader = null
                applyHeader(profile.canRequest, profile.canResponse)
                send("ATFCSH" + profile.canRequest, 400)
            }
            ScanResult(found, silent)
        }
    }

    private fun readFaultsOf(f: FaultFrames): List<Dtc>? {
        val c = Frames.clean(send(f.request, 2500))
        if (!c.startsWith(f.answer)) return null
        val body = c.substring(min(f.header * 2, c.length))
        val out = ArrayList<Dtc>()
        var i = 0
        while (i + f.record * 2 <= body.length) {
            val rec = body.substring(i, i + f.record * 2)
            val code = rec.substring(f.codeAt * 2, (f.codeAt + f.codeLen) * 2)
            out.add(Dtc(code, rec.substring(f.statusAt * 2, (f.statusAt + 1) * 2)))
            i += f.record * 2
        }
        return out
    }

    // --------------------------------------------------------- plumbing

    private fun appendHistory(key: String, p: Point) {
        val dq = history.getOrPut(key) { ArrayDeque() }
        synchronized(dq) {
            dq.addLast(p)
            while (dq.size > historyCap) dq.removeFirst()
        }
    }

    /** Sends one ELM command (adds CR) and reads until the '>' prompt or timeout. */
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
