package com.fap.modern.core

import android.content.Context
import android.content.SharedPreferences

/** Process-wide singleton: the loaded ECU model, the live session, settings. */
object AppState {

    lateinit var session: ElmSession
        private set

    /** The ECU model from assets; the UI builds its list from this. */
    lateinit var profile: Profile
        private set

    /** The platform address map, or null if the asset is missing. */
    var scanProfile: ScanProfile? = null
        private set

    private lateinit var prefs: SharedPreferences
    private lateinit var appContext: Context
    private var initialised = false

    fun init(context: Context) {
        if (initialised) return
        val app = context.applicationContext
        appContext = app
        prefs = app.getSharedPreferences("valeo_v4621", Context.MODE_PRIVATE)
        profile = Profile.fromAssets(app)
        scanProfile = runCatching { ScanProfile.fromAssets(app) }.getOrNull()
        session = ElmSession(profile, scanProfile)
        session.logger = CsvLogger(app.getExternalFilesDir("logs") ?: app.filesDir)
        session.loggingEnabled = loggingEnabled
        initialised = true
    }

    /** The transport config for the current settings. */
    fun transportConfig(): TransportConfig = when (lastTransport) {
        "wifi" -> TransportConfig.Wifi(wifiHost, wifiPort)
        "ble" -> TransportConfig.Ble(btAddress, btName, appContext)
        else -> TransportConfig.Bluetooth(btAddress, btName)
    }

    // ---- persisted settings ----

    /** One of "bluetooth" (classic SPP), "ble", "wifi". */
    var lastTransport: String
        get() = prefs.getString("transport", "bluetooth") ?: "bluetooth"
        set(v) = prefs.edit().putString("transport", v).apply()

    var btAddress: String
        get() = prefs.getString("bt_addr", "") ?: ""
        set(v) = prefs.edit().putString("bt_addr", v).apply()

    var btName: String
        get() = prefs.getString("bt_name", "") ?: ""
        set(v) = prefs.edit().putString("bt_name", v).apply()

    var wifiHost: String
        get() = prefs.getString("wifi_host", "192.168.0.10") ?: "192.168.0.10"
        set(v) = prefs.edit().putString("wifi_host", v).apply()

    var wifiPort: Int
        get() = prefs.getInt("wifi_port", 35000)
        set(v) = prefs.edit().putInt("wifi_port", v).apply()

    var loggingEnabled: Boolean
        get() = prefs.getBoolean("logging", true)
        set(v) {
            prefs.edit().putBoolean("logging", v).apply()
            if (initialised) session.loggingEnabled = v
        }
}
