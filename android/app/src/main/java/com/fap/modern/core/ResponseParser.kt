package com.fap.modern.core

/** Extracts parameter fields from raw ELM327 reply text. */
object ResponseParser {

    /** Strips prompt/whitespace/echo noise and upper-cases a raw ELM reply into a bare hex string. */
    fun clean(raw: String): String {
        val sb = StringBuilder(raw.length)
        for (c in raw) {
            when (c) {
                in '0'..'9', in 'A'..'F', in 'a'..'f' -> sb.append(c.uppercaseChar())
                // everything else (spaces, CR/LF, '>', ':', frame indices from ATH1, text) dropped
            }
        }
        return sb.toString()
    }

    fun isError(raw: String): Boolean {
        val u = raw.uppercase()
        return u.contains("NO DATA") || u.contains("ERROR") || u.contains("UNABLE") ||
            u.contains("STOPPED") || u.contains("?") || u.contains("BUFFER FULL")
    }

    /**
     * Locate the "61<page-low-byte>" marker inside [cleanHex] and read [def.dl] bytes at [def.sbi].
     * Returns null when the marker or the field is absent (short/garbled frame).
     */
    fun extractRaw(cleanHex: String, def: ParamDef): Int? {
        val marker = "61" + def.page.substring(2) // "21CB" -> "61CB"
        val markerIdx = cleanHex.indexOf(marker)
        if (markerIdx < 0) return null
        val startByte = def.sbi + ParserTuning.frameByteShift
        if (startByte < 0) return null
        val start = markerIdx + startByte * 2
        val end = start + def.dl * 2
        if (end > cleanHex.length || start < markerIdx) return null
        return cleanHex.substring(start, end).toIntOrNull(16)
    }
}
