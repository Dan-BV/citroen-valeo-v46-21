package com.fap.modern.core

/**
 * Turning ELM327 replies into numbers.
 *
 * The multi-frame handling matters: for an ISO-TP answer the adapter prints a
 * length header line and then one line per frame prefixed with its index —
 *
 *     03B
 *     0:61FF044F8F4F
 *     1:50FFFFFF0000
 *
 * Stripping every non-hex character would fold those `0`, `1`, `03B` digits
 * into the payload and silently corrupt every field after the first frame.
 */
object Frames {

    private val FRAME_LINE = Regex("^([0-9A-Fa-f]):(.*)$")
    private val LENGTH_LINE = Regex("^[0-9A-Fa-f]{1,3}$")

    fun clean(raw: String): String {
        val lines = raw.split('\r', '\n')
        val multi = lines.any { FRAME_LINE.matches(it.trim()) }
        val sb = StringBuilder(raw.length)
        for (line in lines) {
            val ln = line.trim()
            if (ln.isEmpty() || ln == ">") continue
            val m = FRAME_LINE.matchEntire(ln)
            if (m != null) {
                sb.append(hexOnly(m.groupValues[2]))
                continue
            }
            if (multi && LENGTH_LINE.matches(ln)) continue
            sb.append(hexOnly(ln))
        }
        return sb.toString()
    }

    private fun hexOnly(s: String): String {
        val sb = StringBuilder(s.length)
        for (c in s) if (c.isHex()) sb.append(c.uppercaseChar())
        return sb.toString()
    }

    private fun Char.isHex() = this in '0'..'9' || this in 'a'..'f' || this in 'A'..'F'

    fun isError(raw: String): Boolean {
        val u = raw.uppercase()
        return u.contains("NO DATA") || u.contains("ERROR") || u.contains("UNABLE") ||
            u.contains("STOPPED") || u.contains("BUFFER FULL") || u.contains("?")
    }

    /**
     * Read [field] out of an answer, MSB first. The database labels these
     * little-endian but the wire is the other way round; live captures settle
     * it (engine speed `04 4F` = 1103 rpm).
     */
    fun extract(cleanHex: String, marker: String, field: Field): Int? {
        val at = cleanHex.indexOf(marker)
        if (at < 0) return null
        val start = at + field.offset * 2
        val end = start + field.length * 2
        if (start < at || end > cleanHex.length) return null
        return cleanHex.substring(start, end).toIntOrNull(16)
    }

    /** Hex digits of a field, for identification values that are packed digits. */
    fun extractHex(cleanHex: String, marker: String, field: Field): String? {
        val at = cleanHex.indexOf(marker)
        if (at < 0) return null
        val start = at + field.offset * 2
        val end = start + field.length * 2
        if (start < at || end > cleanHex.length) return null
        return cleanHex.substring(start, end)
    }

    /**
     * ELM waits out its whole timeout after a reply in case another ECU
     * answers. Appending the expected response count makes it return as soon
     * as the reply is assembled — the single biggest win in poll rate.
     */
    fun withResponseCount(request: String, use: Boolean): String =
        if (use) request + "1" else request
}
