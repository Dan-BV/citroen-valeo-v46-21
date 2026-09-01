package com.fap.modern.core

import android.content.Context
import org.json.JSONObject

/**
 * The diagnostic address map of the platform, from `assets/scan_B7.json`
 * (see `tools/diagbox/make_scan.py`).
 *
 * Several ECUs share one CAN address and answer the same recognition frame;
 * only the identification bytes separate them and those are not extracted, so
 * such candidates are merged into one probe carrying every possible name.
 */
data class FaultFrames(
    val request: String,
    val answer: String,
    /** Bytes before the first record: service id plus a count or status mask. */
    val header: Int,
    val record: Int,
    val codeAt: Int,
    val codeLen: Int,
    val statusAt: Int,
)

data class ScanTarget(
    val family: String,
    val name: String,
    val alternatives: List<String>,
    val request: String,
    val response: String,
    val init: String,
    val initAnswer: String,
    val reco: String,
    val recoAnswer: String,
    val faults: FaultFrames?,
    val clear: String?,
) {
    /** Every ECU this probe could have reached. */
    val names: List<String> get() = listOf(name) + alternatives
    val ambiguous: Boolean get() = alternatives.isNotEmpty()
}

data class ScanProfile(val platform: String, val targets: List<ScanTarget>) {

    /** One probe list per CAN address, in the order they should be tried. */
    fun byAddress(): Map<String, List<ScanTarget>> = targets.groupBy { it.request }

    companion object {
        fun fromAssets(ctx: Context, name: String = "scan_B7.json"): ScanProfile {
            val text = ctx.assets.open(name).bufferedReader().use { it.readText() }
            return parse(JSONObject(text))
        }

        fun parse(o: JSONObject): ScanProfile {
            val arr = o.optJSONArray("ecus") ?: return ScanProfile(o.optString("platform"), emptyList())
            val list = (0 until arr.length()).map { i ->
                val e = arr.getJSONObject(i)
                val altArr = e.optJSONArray("alts")
                val alts = if (altArr == null) emptyList()
                else (0 until altArr.length()).map { altArr.getString(it) }
                val d = e.optJSONObject("d")
                ScanTarget(
                    family = e.getString("f"),
                    name = e.getString("n"),
                    alternatives = alts,
                    request = e.getString("q"),
                    response = e.getString("r"),
                    init = e.optString("i", ""),
                    initAnswer = e.optString("io", ""),
                    reco = e.getString("rc"),
                    recoAnswer = e.getString("ro"),
                    faults = d?.let {
                        FaultFrames(
                            request = it.getString("q"),
                            answer = it.getString("o"),
                            header = it.getInt("h"),
                            record = it.getInt("l"),
                            codeAt = it.getInt("c"),
                            codeLen = it.getInt("cl"),
                            statusAt = it.getInt("s"),
                        )
                    },
                    clear = if (e.has("cl")) e.getString("cl") else null,
                )
            }
            return ScanProfile(o.optString("platform"), list)
        }
    }
}

/** One stored fault: the PSA code, its status byte, and a description if known. */
data class Dtc(val code: String, val status: String, val label: String? = null)

data class IdentBlock(val title: String, val rows: List<Pair<String, String>>)

data class ScanHit(
    val target: ScanTarget,
    val identHex: String,
    /** null when the module answered the recognition frame but not the fault read. */
    val faults: List<Dtc>?,
)

data class ScanResult(val found: List<ScanHit>, val silent: List<ScanTarget>) {
    val silentFamilies: List<String> get() = silent.map { it.family }.distinct()
}
