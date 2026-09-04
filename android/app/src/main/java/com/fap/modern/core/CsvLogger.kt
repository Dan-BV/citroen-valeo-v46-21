package com.fap.modern.core

import java.io.BufferedWriter
import java.io.File
import java.io.FileWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** Background CSV recorder: one column per parameter, one row per poll cycle. */
class CsvLogger(private val dir: File) {

    private var writer: BufferedWriter? = null
    private var keys: List<String> = emptyList()
    private var file: File? = null
    private var rows = 0

    var currentPath: String? = null
        private set

    val isRunning: Boolean get() = writer != null

    @Synchronized
    fun start(params: List<Field>) {
        if (writer != null) return
        if (!dir.exists()) dir.mkdirs()
        val stamp = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())
        val f = File(dir, "fap_log_$stamp.csv")
        keys = params.map { it.key }
        val w = BufferedWriter(FileWriter(f))
        w.write("time_ms,iso," + keys.joinToString(","))
        w.newLine()
        w.flush()
        writer = w
        file = f
        rows = 0
        currentPath = f.absolutePath
    }

    @Synchronized
    fun logRow(tMs: Long, values: Map<String, Sample>) {
        val w = writer ?: return
        val iso = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS", Locale.US).format(Date(tMs))
        val sb = StringBuilder()
        sb.append(tMs).append(',').append(iso)
        for (k in keys) {
            sb.append(',')
            val s = values[k]
            if (s != null && s.valid) sb.append(s.value)
        }
        w.write(sb.toString())
        w.newLine()
        rows++
    }

    /** Push buffered rows to disk so the file can be shared mid-session. */
    @Synchronized
    fun flush() {
        try { writer?.flush() } catch (_: Exception) {}
    }

    @Synchronized
    fun stop() {
        try { writer?.flush(); writer?.close() } catch (_: Exception) {}
        writer = null
        // A start with no rows leaves a header-only file; every connect
        // and every LOG toggle would otherwise litter the folder.
        if (rows == 0) {
            try { file?.delete() } catch (_: Exception) {}
            currentPath = null
        }
        file = null
    }
}
