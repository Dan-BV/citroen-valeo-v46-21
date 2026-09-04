package com.fap.modern.ui

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
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
import androidx.core.content.FileProvider
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import androidx.recyclerview.widget.LinearLayoutManager
import com.fap.modern.R
import com.fap.modern.core.AppState
import com.fap.modern.core.ConnState
import com.fap.modern.core.Diagnostics
import com.fap.modern.core.Dtc
import com.fap.modern.core.Page
import com.fap.modern.core.ScanResult
import com.fap.modern.databinding.ActivityMainBinding
import kotlinx.coroutines.launch
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

private const val NEWLINE = "\n"

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

        binding.list.layoutManager = LinearLayoutManager(this)
        rebuildList()

        binding.toolbar.inflateMenu(R.menu.main)
        binding.toolbar.setOnMenuItemClickListener { item ->
            when (item.itemId) {
                R.id.action_dtc -> { readDtc(); true }
                R.id.action_ident -> { readIdent(); true }
                R.id.action_scan -> { scanModules(); true }
                R.id.action_report -> { buildReport(); true }
                R.id.action_share_log -> { shareLog(); true }
                else -> false
            }
        }

        binding.connectButton.setOnClickListener { onConnectClicked() }
        binding.logButton.setOnClickListener { onLogClicked() }
        binding.settingsButton.setOnClickListener { showSettings() }
        binding.filterButton.setOnClickListener { showFilter() }
        updateLogButton()

        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                launch { session.values.collect { adapter.submit(it) } }
                launch { session.state.collect { updateLogButton() } }
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

    // ------------------------------------------------------------ filter

    /** Pages carrying only the fields the user kept. */
    private fun rebuildList() {
        val sel = AppState.selectedKeys
        val pages = profile.pages.map { p ->
            p.copy(fields = p.fields.filter { sel.contains(it.key) })
        }
        adapter = ParamAdapter(
            ParamAdapter.rowsOf(pages),
            onParam = { f -> openGraph(f.key) },
            onHeader = { p -> showPageDiag(p) },
        )
        binding.list.adapter = adapter
        adapter.submitDead(session.deadPages.value)
        adapter.submit(session.values.value)
    }

    private fun applySelection(keys: Set<String>) {
        AppState.selectedKeys = keys
        rebuildList()
        // The CSV header is fixed when the file opens, so a changed set of
        // columns needs a new file rather than a ragged old one.
        if (session.isConnected && AppState.loggingEnabled) {
            session.stopLogging()
            session.startLogging()
        }
        updateLogButton()
        toast("Показывается " + keys.size + " из " + profile.fields.size)
    }

    /**
     * Unticking a parameter is not cosmetic: a page with nothing selected is
     * not requested at all, which is the only real lever on cycle time.
     */
    private fun showFilter() {
        val fields = profile.fields
        val chosen = AppState.selectedKeys.toMutableSet()
        val labels = fields.map { "\$${it.pageId} · ${it.label}" }.toTypedArray()
        val checked = BooleanArray(fields.size) { chosen.contains(fields[it].key) }
        val allOn = checked.all { it }
        AlertDialog.Builder(this)
            .setTitle("Какие параметры опрашивать")
            .setMultiChoiceItems(labels, checked) { _, i, on ->
                if (on) chosen.add(fields[i].key) else chosen.remove(fields[i].key)
            }
            .setNeutralButton(if (allOn) "Снять все" else "Выбрать все") { _, _ ->
                applySelection(if (allOn) emptySet() else fields.map { it.key }.toSet())
            }
            .setNegativeButton("Отмена", null)
            .setPositiveButton("Применить") { _, _ -> applySelection(chosen) }
            .show()
    }

    // ------------------------------------------------- sharing evidence

    /**
     * Android/data is out of reach of a file manager on API 30+, so the log
     * and the report leave through a share sheet instead of a path the user
     * has to go hunting for.
     */
    private fun shareFiles(files: List<File>) {
        val uris = ArrayList<Uri>()
        for (f in files) uris.add(FileProvider.getUriForFile(this, packageName + ".files", f))
        val send = if (uris.size == 1) {
            Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_STREAM, uris[0])
        } else {
            Intent(Intent.ACTION_SEND_MULTIPLE)
                .putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
        }
        send.type = "text/*"
        send.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        startActivity(Intent.createChooser(send, "Отправить"))
    }

    /**
     * Every connect and every LOG toggle starts a new file, and reports pile up
     * beside them, so offer the lot newest-first and let several go at once.
     */
    private fun shareLog() {
        session.logger?.flush()
        val dir = getExternalFilesDir("logs") ?: filesDir
        val logs = dir.listFiles()?.toList() ?: emptyList()
        val reports = File(dir, "reports").listFiles()?.toList() ?: emptyList()
        val files = (logs + reports)
            .filter { it.isFile && it.length() > 0 }
            .sortedByDescending { it.lastModified() }
        if (files.isEmpty()) {
            toast("Файлов пока нет: включите LOG и подключитесь")
            return
        }
        val current = session.logger?.currentPath
        val stamp = SimpleDateFormat("dd.MM HH:mm", Locale.US)
        val labels = files.map { f ->
            val kb = f.length() / 1024
            val size = if (kb >= 1024) "%.1f МБ".format(kb / 1024.0) else kb.toString() + " КБ"
            val mark = if (f.absolutePath == current) "  ← идёт запись" else ""
            stamp.format(Date(f.lastModified())) + " · " + size + mark + NEWLINE + f.name
        }.toTypedArray()
        val picked = BooleanArray(files.size)
        AlertDialog.Builder(this)
            .setTitle("Что отправить")
            .setMultiChoiceItems(labels, picked) { _, i, on -> picked[i] = on }
            .setNegativeButton("Отмена", null)
            .setPositiveButton("Отправить") { _, _ ->
                val sel = files.filterIndexed { i, _ -> picked[i] }
                if (sel.isEmpty()) toast("Ничего не выбрано") else shareFiles(sel)
            }
            .show()
    }

    private fun buildReport() {
        if (!requireConnected()) return
        val dialog = AlertDialog.Builder(this)
            .setTitle("Отчёт для анализа")
            .setMessage("Опрашиваю каждую страницу тремя способами…")
            .setCancelable(false)
            .create()
        dialog.show()
        lifecycleScope.launch {
            try {
                val text = Diagnostics.build(session, profile)
                val file = Diagnostics.write(this@MainActivity, text)
                dialog.dismiss()
                shareFiles(listOf(file))
            } catch (e: Exception) {
                dialog.dismiss()
                toast("Отчёт: " + e.message)
            }
        }
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

    /**
     * Armed and recording are different things: the switch is a preference that
     * survives a disconnect, while a file is only open while connected. Showing
     * one for the other is how a stopped log looks like a running one.
     */
    private fun updateLogButton() {
        binding.logButton.text = when {
            AppState.loggingEnabled && session.isLogging -> "LOG ●"
            AppState.loggingEnabled -> "LOG ○"
            else -> "LOG"
        }
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
