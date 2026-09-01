package com.fap.modern.ui

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.widget.ArrayAdapter
import android.widget.EditText
import android.widget.RadioButton
import android.widget.Spinner
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import androidx.recyclerview.widget.LinearLayoutManager
import com.fap.modern.R
import com.fap.modern.core.AppState
import com.fap.modern.core.ConnState
import com.fap.modern.core.Dtc
import com.fap.modern.core.Page
import com.fap.modern.core.ScanResult
import com.fap.modern.databinding.ActivityMainBinding
import kotlinx.coroutines.launch

class MainActivity : AppCompatActivity() {

    private lateinit var binding: ActivityMainBinding
    private lateinit var adapter: ParamAdapter
    private val session get() = AppState.session
    private val profile get() = AppState.profile

    private val btPermLauncher =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            if (granted) attemptConnect()
            else toast("Для доступа к адаптеру нужно разрешение Bluetooth")
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        AppState.init(this)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

        adapter = ParamAdapter(
            ParamAdapter.rowsOf(profile.pages),
            onParam = { f -> openGraph(f.key) },
            onHeader = { p -> showPageDiag(p) },
        )
        binding.list.layoutManager = LinearLayoutManager(this)
        binding.list.adapter = adapter

        binding.toolbar.inflateMenu(R.menu.main)
        binding.toolbar.setOnMenuItemClickListener { item ->
            when (item.itemId) {
                R.id.action_dtc -> { readDtc(); true }
                R.id.action_ident -> { readIdent(); true }
                R.id.action_scan -> { scanModules(); true }
                else -> false
            }
        }

        binding.connectButton.setOnClickListener { onConnectClicked() }
        binding.logButton.setOnClickListener { onLogClicked() }
        binding.settingsButton.setOnClickListener { showSettings() }
        updateLogButton()

        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                launch { session.values.collect { adapter.submit(it) } }
                launch { session.statusText.collect { binding.statusText.text = it } }
                launch { session.state.collect { updateConnectButton(it) } }
                launch { session.deadPages.collect { adapter.submitDead(it) } }
            }
        }
    }

    // ------------------------------------------------------------ connect

    private fun onConnectClicked() {
        when (session.state.value) {
            ConnState.CONNECTED, ConnState.CONNECTING -> session.disconnect()
            else -> attemptConnect()
        }
    }

    private fun attemptConnect() {
        session.loggingEnabled = AppState.loggingEnabled
        if (AppState.lastTransport == "wifi") {
            session.connect(AppState.transportConfig())
            return
        }
        if (needsBtPermission()) {
            btPermLauncher.launch(Manifest.permission.BLUETOOTH_CONNECT)
            return
        }
        if (AppState.btAddress.isEmpty()) {
            toast("Сначала выберите адаптер в CFG")
            showSettings()
            return
        }
        session.connect(AppState.transportConfig())
    }

    private fun needsBtPermission(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_CONNECT) !=
            PackageManager.PERMISSION_GRANTED

    private fun updateConnectButton(state: ConnState) {
        binding.connectButton.text = when (state) {
            ConnState.CONNECTED, ConnState.CONNECTING -> getString(R.string.disconnect)
            else -> getString(R.string.connect)
        }
    }

    // ------------------------------------------------------ fault codes

    /** Both reads need the KWP session the poll loop keeps open. */
    private fun requireConnected(): Boolean {
        if (session.isConnected) return true
        toast("Сначала подключитесь")
        return false
    }

    private fun readDtc() {
        if (!requireConnected()) return
        lifecycleScope.launch {
            try {
                showDtc(session.readDtc())
            } catch (e: Exception) {
                toast("Чтение ошибок: ${e.message}")
            }
        }
    }

    private fun showDtc(faults: List<Dtc>) {
        val text = if (faults.isEmpty()) "Ошибок нет (ЭБУ вернул 57 00)."
        else faults.joinToString("\n\n") { d ->
            "\$${d.code}  (статус ${d.status})\n${d.label ?: "нет описания в базе Diagbox"}"
        }
        val b = AlertDialog.Builder(this)
            .setTitle("Коды неисправностей")
            .setMessage(text)
            .setPositiveButton("Закрыть", null)
        if (faults.isNotEmpty()) {
            b.setNegativeButton("Стереть") { _, _ -> confirmClear() }
        }
        b.show()
    }

    private fun confirmClear() {
        AlertDialog.Builder(this)
            .setTitle("Стереть ошибки?")
            .setMessage("Запомненные условия появления будут потеряны.")
            .setNegativeButton("Отмена", null)
            .setPositiveButton("Стереть") { _, _ ->
                lifecycleScope.launch {
                    try {
                        session.clearDtc()
                        showDtc(session.readDtc())
                        toast("Ошибки стёрты")
                    } catch (e: Exception) {
                        toast("Не удалось стереть: ${e.message}")
                    }
                }
            }
            .show()
    }

    private fun readIdent() {
        if (!requireConnected()) return
        lifecycleScope.launch {
            try {
                val blocks = session.readIdent()
                val text = if (blocks.isEmpty()) "ЭБУ не ответил на запросы идентификации."
                else blocks.joinToString("\n\n") { b ->
                    b.title + "\n" + b.rows.joinToString("\n") { "  ${it.first}: ${it.second}" }
                }
                AlertDialog.Builder(this@MainActivity)
                    .setTitle("Идентификация ЭБУ")
                    .setMessage(text)
                    .setPositiveButton("Закрыть", null)
                    .show()
            } catch (e: Exception) {
                toast("Идентификация: ${e.message}")
            }
        }
    }

    // ---------------------------------------------------------- scanning

    private fun scanModules() {
        if (!requireConnected()) return
        if (AppState.scanProfile == null) { toast("Карта адресов не загружена"); return }
        val dialog = AlertDialog.Builder(this)
            .setTitle("Сканирование блоков")
            .setMessage("Подготовка…\nЖивые значения на это время заморожены.")
            .setCancelable(false)
            .create()
        dialog.show()
        lifecycleScope.launch {
            try {
                val res = session.scanModules { i, n, addr ->
                    runOnUiThread { dialog.setMessage("Опрос $i из $n — адрес $addr") }
                }
                dialog.dismiss()
                showScan(res)
            } catch (e: Exception) {
                dialog.dismiss()
                toast("Сканирование: ${e.message}")
            }
        }
    }

    private fun showScan(res: ScanResult) {
        val sb = StringBuilder()
        sb.append("Отвечают: ${res.found.size} из ${res.found.size + res.silent.size}\n")
        for (hit in res.found) {
            val t = hit.target
            // The engine is named by the loaded profile; elsewhere an ambiguous
            // address lists every candidate rather than guessing at one.
            val name = if (t.request == profile.canRequest) profile.ecu
            else t.names.joinToString(" / ") + if (t.ambiguous) " (один из)" else ""
            sb.append("\n${t.family}  ${t.request}/${t.response}\n  $name\n")
            sb.append("  " + when {
                hit.faults == null -> "нет ответа на чтение ошибок"
                hit.faults.isEmpty() -> "ошибок нет"
                else -> "${hit.faults.size}: " + hit.faults.joinToString(", ") { "\$${it.code}" }
            } + "\n")
            if (hit.identHex.isNotEmpty()) sb.append("  ид.: ${hit.identHex}\n")
        }
        sb.append("\nНе ответили: " + res.silentFamilies.joinToString(", "))
        AlertDialog.Builder(this)
            .setTitle("Сканирование блоков")
            .setMessage(sb.toString())
            .setPositiveButton("Закрыть", null)
            .show()
    }

    // ------------------------------------------------------- diagnostics

    /**
     * What a page actually answered - the quickest way to tell a page this ECU
     * does not implement from one the app mis-parses.
     */
    private fun showPageDiag(page: Page) {
        val raw = session.rawReply(page.request)
        val need = page.fields.maxOfOrNull { it.offset + it.length } ?: 0
        val clean = raw?.let { com.fap.modern.core.Frames.clean(it) }
        val sb = StringBuilder()
        sb.append("Запрос: ${page.request}\n")
        sb.append("Маркер ответа: ${page.marker}\n")
        sb.append("Нужно байт: $need\n")
        if (clean.isNullOrEmpty()) {
            sb.append("\nОтвет ещё не получен — подключитесь и дождитесь цикла опроса.")
        } else {
            sb.append("Получено байт: ${clean.length / 2}\n")
            val at = clean.indexOf(page.marker)
            sb.append("Маркер найден: " + (if (at < 0) "нет" else "да, смещение ${at / 2}") + "\n")
            sb.append("\nСырой ответ:\n$clean")
        }
        AlertDialog.Builder(this)
            .setTitle("Страница \$${page.id}")
            .setMessage(sb.toString())
            .setPositiveButton("Закрыть", null)
            .show()
    }

    // -------------------------------------------------------------- misc

    private fun onLogClicked() {
        val newState = !AppState.loggingEnabled
        AppState.loggingEnabled = newState
        if (session.isConnected) {
            if (newState) session.startLogging() else session.stopLogging()
        }
        updateLogButton()
        val path = session.logger?.currentPath
        if (newState && path != null) toast("Запись в\n$path")
    }

    private fun updateLogButton() {
        binding.logButton.text = if (AppState.loggingEnabled) "LOG ●" else "LOG"
    }

    private fun openGraph(key: String) {
        startActivity(Intent(this, GraphActivity::class.java).putExtra("key", key))
    }

    private fun toast(msg: String) = Toast.makeText(this, msg, Toast.LENGTH_LONG).show()

    @SuppressLint("MissingPermission")
    private fun showSettings() {
        val view = layoutInflater.inflate(R.layout.dialog_settings, null)
        val rbBt = view.findViewById<RadioButton>(R.id.rbBluetooth)
        val rbBle = view.findViewById<RadioButton>(R.id.rbBle)
        val rbWifi = view.findViewById<RadioButton>(R.id.rbWifi)
        val btSpinner = view.findViewById<Spinner>(R.id.btSpinner)
        val wifiHost = view.findViewById<EditText>(R.id.wifiHost)
        val wifiPort = view.findViewById<EditText>(R.id.wifiPort)

        when (AppState.lastTransport) {
            "wifi" -> rbWifi.isChecked = true
            "ble" -> rbBle.isChecked = true
            else -> rbBt.isChecked = true
        }
        wifiHost.setText(AppState.wifiHost)
        wifiPort.setText(AppState.wifiPort.toString())

        val devices = pairedDevices()
        val labels = devices.map { it.second }
            .ifEmpty { listOf("<нет сопряжённых устройств / нет разрешения>") }
        btSpinner.adapter =
            ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, labels)
        val curIdx = devices.indexOfFirst { it.first == AppState.btAddress }
        if (curIdx >= 0) btSpinner.setSelection(curIdx)

        AlertDialog.Builder(this)
            .setTitle("Подключение")
            .setView(view)
            .setPositiveButton("Сохранить") { _, _ ->
                AppState.lastTransport = when {
                    rbWifi.isChecked -> "wifi"
                    rbBle.isChecked -> "ble"
                    else -> "bluetooth"
                }
                AppState.wifiHost = wifiHost.text.toString().ifBlank { "192.168.0.10" }
                AppState.wifiPort = wifiPort.text.toString().toIntOrNull() ?: 35000
                if (devices.isNotEmpty()) {
                    val sel = devices[btSpinner.selectedItemPosition.coerceIn(devices.indices)]
                    AppState.btAddress = sel.first
                    AppState.btName = sel.second
                }
            }
            .setNegativeButton("Отмена", null)
            .show()
    }

    /**
     * Paired devices as (address, name). BLE adapters must be paired too for
     * this list; unpaired BLE scanning is a separate flow not needed here.
     */
    @SuppressLint("MissingPermission")
    private fun pairedDevices(): List<Pair<String, String>> {
        if (needsBtPermission()) {
            btPermLauncher.launch(Manifest.permission.BLUETOOTH_CONNECT)
            return emptyList()
        }
        val adapter = BluetoothAdapter.getDefaultAdapter() ?: return emptyList()
        return try {
            adapter.bondedDevices.map { it.address to (it.name ?: it.address) }
        } catch (e: SecurityException) {
            emptyList()
        }
    }
}
