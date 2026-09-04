package com.fap.modern.core

import android.content.Context
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * A one-shot dump of what every page really answers, meant to be read away
 * from the car.
 *
 * Each page is asked three ways, because that is exactly what is in doubt:
 * with the expected-response-count suffix, plain, and in the bare `21xx` form
 * without the `8001` tail. Whichever answer carries the marker is then decoded
 * field by field, so a field that lands past the end of a short reply shows up
 * as such instead of silently reading as "--".
 */
object Diagnostics {

    suspend fun build(session: ElmSession, profile: Profile): String {
        val sb = StringBuilder()
        val (dead, noSuffix) = session.probeState()

        sb.appendLine("ECU ${profile.ecu} / ${profile.platform}")
        sb.appendLine("CAN ${profile.canRequest} -> ${profile.canResponse}")
        sb.appendLine("status: ${session.statusText.value}")
        sb.appendLine("written off by the probe: " + dead.joinToString(", ").ifEmpty { "none" })
        sb.appendLine("needing the suffix omitted: " + noSuffix.joinToString(", ").ifEmpty { "none" })

        for (page in profile.pages) {
            val need = page.fields.maxOfOrNull { it.offset + it.length } ?: 0
            sb.appendLine()
            sb.appendLine(
                "=== ${page.id}  req=${page.request}  marker=${page.marker}  " +
                    "need=$need bytes  fields=${page.fields.size}"
            )

            var best: String? = null
            for ((cmd, clean) in session.probeVariants(page)) {
                val at = clean.indexOf(page.marker)
                val where = if (at < 0) "none" else (at / 2).toString()
                sb.appendLine("  $cmd -> ${clean.length / 2} bytes, marker at $where")
                sb.appendLine("    " + clean.ifEmpty { "(empty or error)" })
                if (best == null && at >= 0) best = clean
            }

            val good = best
            if (good == null) {
                sb.appendLine("  no variant produced the marker")
                continue
            }
            for (f in page.fields) {
                val raw = Frames.extract(good, page.marker, f)
                val shown = when {
                    raw == null -> "MISSING (past the end of the reply)"
                    f.kind == ValueKind.ENUM -> "$raw  ${f.stateText(raw)}"
                    else -> "${f.compute(raw)} ${f.unit}"
                }
                sb.appendLine("  b${f.offset + 1} ${f.key.take(44)} = $shown")
            }
        }
        return sb.toString()
    }

    /** Writes the report next to the CSV logs and returns the file. */
    fun write(ctx: Context, text: String): File {
        val dir = File(ctx.getExternalFilesDir("logs") ?: ctx.filesDir, "reports")
        if (!dir.exists()) dir.mkdirs()
        val stamp = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())
        val f = File(dir, "diag_$stamp.txt")
        f.writeText(text)
        return f
    }
}
