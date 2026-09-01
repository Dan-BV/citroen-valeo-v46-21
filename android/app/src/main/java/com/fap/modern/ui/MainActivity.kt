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
import com.fap.modern.core.InitMode
import com.fap.modern.core.TransportConfig
import com.fap.modern.core.V4621Profile
import com.fap.modern.databinding.ActivityMainBinding
import kotlinx.coroutines.launch

class MainActivity : AppCompatActivity() {

    private lateinit var binding: ActivityMainBinding
    private lateinit var adapter: ParamAdapter
    private val session get() = AppState.session

    private val btPermLauncher =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            if (granted) attemptConnect()
            else toast("Bluetooth permission is required to reach the adapter")
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        AppState.init(this)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

        adapter = ParamAdapter(V4621Profile.params) { def -> openGraph(def.key) }
        binding.list.layoutManager = LinearLayoutManager(this)
        binding.list.adapter = adapter

        binding.connectButton.setOnClickListener { onConnectClicked() }
        binding.logButton.setOnClickListener { onLogClicked() }
        binding.settingsButton.setOnClickListener { showSettings() }
        updateLogButton()

        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                launch { session.values.collect { adapter.submit(it) } }
                launch { session.statusText.collect { binding.statusText.text = it } }
                launch { session.state.collect { updateConnectButton(it) } }
            }
        }
    }

    private fun onConnectClicked() {
        when (session.state.value) {
            ConnState.CONNECTED, ConnState.CONNECTING -> session.disconnect()
            else -> attemptConnect()
        }
    }

    private fun attemptConnect() {
        session.loggingEnabled = AppState.loggingEnabled
        if (AppState.lastTransport == "wifi") {
            session.connect(TransportConfig.Wifi(AppState.wifiHost, AppState.wifiPort))
            return
        }
        // Bluetooth
        if (needsBtPermission()) {
            btPermLauncher.launch(Manifest.permission.BLUETOOTH_CONNECT)
            return
        }
        val addr = AppState.btAddress
        if (addr.isEmpty()) {
            toast("Choose a paired Bluetooth adapter in CFG first")
            showSettings()
            return
        }
        session.connect(TransportConfig.Bluetooth(addr, AppState.btName))
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

    private fun onLogClicked() {
        val newState = !AppState.loggingEnabled
        AppState.loggingEnabled = newState
        session.loggingEnabled = newState
        if (session.isConnected) {
            if (newState) session.startLogging() else session.stopLogging()
        }
        updateLogButton()
        val path = session.logger?.currentPath
        if (newState && path != null) toast("Logging to\n$path")
    }

    private fun updateLogButton() {
        binding.logButton.text = if (AppState.loggingEnabled) "LOG ●" else "LOG"
    }

    private fun openGraph(key: String) {
        startActivity(Intent(this, GraphActivity::class.java).putExtra("key", key))
    }

    private fun toast(msg: String) = Toast.makeText(this, msg, Toast.LENGTH_LONG).show()

    // ---- settings dialog ----

    @SuppressLint("MissingPermission")
    private fun showSettings() {
        val view = layoutInflater.inflate(R.layout.dialog_settings, null)
        val rbBt = view.findViewById<RadioButton>(R.id.rbBluetooth)
        val rbWifi = view.findViewById<RadioButton>(R.id.rbWifi)
        val btSpinner = view.findViewById<Spinner>(R.id.btSpinner)
        val wifiHost = view.findViewById<EditText>(R.id.wifiHost)
        val wifiPort = view.findViewById<EditText>(R.id.wifiPort)
        val initSpinner = view.findViewById<Spinner>(R.id.initSpinner)
        val frameShift = view.findViewById<EditText>(R.id.frameShift)

        if (AppState.lastTransport == "wifi") rbWifi.isChecked = true else rbBt.isChecked = true
        wifiHost.setText(AppState.wifiHost)
        wifiPort.setText(AppState.wifiPort.toString())
        frameShift.setText(AppState.frameByteShift.toString())

        // Bluetooth paired devices
        val devices = pairedDevices()
        val labels = devices.map { it.second }.ifEmpty { listOf("<no paired devices / no permission>") }
        btSpinner.adapter = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, labels)
        val curIdx = devices.indexOfFirst { it.first == AppState.btAddress }
        if (curIdx >= 0) btSpinner.setSelection(curIdx)

        // Init modes
        val modes = InitMode.values()
        val modeLabels = modes.map {
            when (it) {
                InitMode.AUTO -> "Auto (fast → 5-baud)"
                InitMode.FAST_KLINE -> "K-line fast init (ATSP5)"
                InitMode.SLOW_KLINE -> "K-line 5-baud init (ATSP4)"
            }
        }
        initSpinner.adapter = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, modeLabels)
        initSpinner.setSelection(modes.indexOf(AppState.initMode).coerceAtLeast(0))

        AlertDialog.Builder(this)
            .setTitle("Connection settings")
            .setView(view)
            .setPositiveButton("Save") { _, _ ->
                AppState.lastTransport = if (rbWifi.isChecked) "wifi" else "bluetooth"
                AppState.wifiHost = wifiHost.text.toString().ifBlank { "192.168.0.10" }
                AppState.wifiPort = wifiPort.text.toString().toIntOrNull() ?: 35000
                AppState.frameByteShift = frameShift.text.toString().toIntOrNull() ?: 0
                AppState.initMode = modes[initSpinner.selectedItemPosition.coerceIn(modes.indices)]
                if (devices.isNotEmpty()) {
                    val sel = devices[btSpinner.selectedItemPosition.coerceIn(devices.indices)]
                    AppState.btAddress = sel.first
                    AppState.btName = sel.second
                }
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    /** Returns paired devices as (address, name). Requires BLUETOOTH_CONNECT on API 31+. */
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
