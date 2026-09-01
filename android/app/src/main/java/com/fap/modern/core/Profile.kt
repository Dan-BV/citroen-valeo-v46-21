package com.fap.modern.core

import android.content.Context
import org.json.JSONObject

/**
 * The ECU model, loaded from assets rather than written in code.
 *
 * `assets/v46_21_profile.json` is produced by `tools/diagbox/make_profile.py`
 * out of the official Diagbox databases, so byte offsets, scaling, units and
 * enumerated states are the ECU's own definitions. Regenerate it there; never
 * edit the values here.
 */
enum class ValueKind { NUMERIC, ENUM }

data class Field(
    val key: String,
    val label: String,
    /** 0-based byte offset from the start of the answer, 0 being the 0x61. */
    val offset: Int,
    val length: Int,
    val scale: Double,
    val zero: Double,
    val unit: String,
    val decimals: Int,
    val min: Double,
    val max: Double,
    val bitShift: Int = 0,
    val bitMask: Int? = null,
    val states: Map<Int, String>? = null,
    /** Identification fields are packed decimal digits, shown as hex. */
    val isHex: Boolean = false,
) {
    val kind: ValueKind get() = if (states != null) ValueKind.ENUM else ValueKind.NUMERIC

    /** Decode a raw reading into engineering units. */
    fun compute(raw: Int): Double {
        var v = raw
        bitMask?.let { v = (v ushr bitShift) and it }
        return v * scale + zero
    }

    fun stateText(raw: Int): String = states?.get(raw) ?: "?$raw"
}

data class Page(
    /** Page id as Diagbox names it, e.g. "CB". */
    val id: String,
    /** Full request, e.g. "21CB8001". */
    val request: String,
    /** Constant leading bytes of a positive answer, e.g. "61FF". */
    val marker: String,
    val title: String,
    /** Holds still while driving, so it is read once in a while. */
    val slow: Boolean,
    val fields: List<Field>,
    val header: String,
    val receive: String,
)

data class Profile(
    val ecu: String,
    val platform: String,
    val canRequest: String,
    val canResponse: String,
    val pages: List<Page>,
    val ident: List<Page>,
    /** PSA fault code, e.g. "0071", to its description. */
    val dtc: Map<String, String>,
) {
    val fields: List<Field> get() = pages.flatMap { it.fields }

    fun pageOf(field: Field): Page? = pages.firstOrNull { p -> p.fields.any { it === field } }

    companion object {
        fun fromAssets(ctx: Context, name: String = "v46_21_profile.json"): Profile {
            val text = ctx.assets.open(name).bufferedReader().use { it.readText() }
            return parse(JSONObject(text))
        }

        fun parse(o: JSONObject): Profile {
            val can = o.getJSONObject("can")
            val req = can.getString("req")
            val res = can.getString("res")

            fun fields(arr: org.json.JSONArray): List<Field> =
                (0 until arr.length()).map { i ->
                    val f = arr.getJSONObject(i)
                    val states = f.optJSONObject("st")?.let { st ->
                        st.keys().asSequence().associate { k -> k.toInt() to st.getString(k) }
                    }
                    Field(
                        key = f.getString("k"),
                        label = f.getString("l"),
                        offset = f.getInt("o"),
                        length = f.getInt("n"),
                        scale = f.optDouble("z", 1.0),
                        zero = f.optDouble("d", 0.0),
                        unit = f.optString("u", ""),
                        decimals = f.optInt("dec", 0),
                        min = f.optDouble("lo", 0.0),
                        max = f.optDouble("hi", 255.0),
                        bitShift = f.optInt("sh", 0),
                        bitMask = if (f.has("m")) f.getInt("m") else null,
                        states = states,
                        isHex = f.optBoolean("hex", false),
                    )
                }

            fun pages(key: String, slowDefault: Boolean): List<Page> {
                val arr = o.optJSONArray(key) ?: return emptyList()
                return (0 until arr.length()).map { i ->
                    val p = arr.getJSONObject(i)
                    Page(
                        id = p.optString("id", p.getString("req")),
                        request = p.getString("req"),
                        marker = p.getString("mk"),
                        title = p.optString("title", ""),
                        slow = p.optBoolean("slow", slowDefault),
                        fields = fields(p.getJSONArray("params")),
                        header = req,
                        receive = res,
                    )
                }
            }

            val dtcObj = o.optJSONObject("dtc") ?: JSONObject()
            return Profile(
                ecu = o.optString("ecu", "V46_21"),
                platform = o.optString("platform", ""),
                canRequest = req,
                canResponse = res,
                pages = pages("pages", false),
                ident = pages("ident", true),
                dtc = dtcObj.keys().asSequence().associateWith { dtcObj.getString(it) },
            )
        }
    }
}
