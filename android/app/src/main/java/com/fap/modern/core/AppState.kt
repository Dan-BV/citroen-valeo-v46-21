package com.fap.modern.core

import android.content.Context
import android.content.SharedPreferences

/** Process-wide singleton: the live session plus persisted connection settings. */
object AppState {

    lateinit var session: ElmSession
        private set

    private lateinit var prefs: SharedPreferences
    private var initialised = false

    fun init(context: Context) {
        if (initialised) return
        val app = context.applicationContext
        prefs = app.getSharedPreferences("fap_modern", Context.MODE_PRIVATE)
        session = ElmSession()
        session.logger = CsvLogger(app.getExternalFilesDir("logs") ?: app.filesDir)
        session.initMode = initMode
        ParserTuning.frameByteShift = frameByteShift
        initialised = true
    }

    // ---- persisted settings ----

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
        set(v) = prefs.edit().putBoolean("logging", v).apply()

    var initMode: InitMode
        get() = runCatching { InitMode.valueOf(prefs.getString("init_mode", "AUTO")!!) }
            .getOrDefault(InitMode.AUTO)
        set(v) {
            prefs.edit().putString("init_mode", v.name).apply()
            if (initialised) session.initMode = v
        }

    var frameByteShift: Int
        get() = prefs.getInt("frame_shift", 0)
        set(v) {
            prefs.edit().putInt("frame_shift", v).apply()
            ParserTuning.frameByteShift = v
        }
}
