package com.fap.modern.core

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Replays `data/parity/golden.json` - real frames recorded off the car,
 * together with the values the raw Diagbox database says they mean - through
 * this app's decoder.
 *
 * The same fixture is replayed by the iOS test target, and the expected values
 * come from neither implementation: `tools/parity/make_golden.py` derives them
 * from the official database and refuses to write a fixture the generated
 * profile does not reproduce. So three independent readings of the same byte
 * maps are held to one truth, and a wrong offset, factor or bit mask in any of
 * them fails a build instead of showing up as a wrong number in a moving car.
 *
 * A JVM test on purpose - nothing here needs a device.
 */
class ParityTest {

    private val root: File by lazy {
        var dir: File? = File(System.getProperty("user.dir")!!).absoluteFile
        while (dir != null && !File(dir, "data/parity/golden.json").exists()) {
            dir = dir.parentFile
        }
        assertNotNull("data/parity/golden.json not found above the module", dir)
        dir!!
    }

    private fun json(path: String) = JSONObject(File(root, path).readText())

    private val golden by lazy { json("data/parity/golden.json") }

    private val profile by lazy {
        Profile.parse(json("android/app/src/main/assets/v46_21_profile.json"))
    }

    @Test
    fun `recorded frames decode to the expected values`() {
        val pages = golden.getJSONObject("pages")
        val samples = golden.getJSONArray("samples")
        val byId = profile.pages.associateBy { it.id }

        var checked = 0
        for (i in 0 until samples.length()) {
            val sample = samples.getJSONObject(i)
            val id = sample.getString("p")
            val page = byId[id] ?: error("page $id is not in the profile")
            val spec = pages.getJSONObject(id)
            assertEquals("page $id marker", spec.getString("marker"), page.marker)

            val clean = Frames.clean(sample.getString("h"))
            val fields = spec.getJSONArray("fields")
            val raws = sample.getJSONArray("r")
            val values = sample.getJSONArray("v")
            val byKey = page.fields.associateBy { it.key }

            for (j in 0 until fields.length()) {
                val wanted = fields.getJSONObject(j)
                val key = wanted.getString("k")
                val where = "$id/$key"
                val field = byKey[key] ?: error("$where is not in the profile")

                val unmasked = Frames.extract(clean, page.marker, field)
                if (raws.isNull(j)) {
                    assertNull("$where should not have decoded", unmasked)
                    continue
                }
                assertNotNull("$where failed to decode", unmasked)

                // The fixture records the value after the bit field is taken
                // out; Field.compute does that itself, so the raw has to be
                // masked here to be compared.
                val mask = field.bitMask
                val raw = if (mask != null) (unmasked!! ushr field.bitShift) and mask else unmasked!!
                assertEquals("$where raw", raws.getInt(j), raw)

                when (wanted.getString("kind")) {
                    "num" -> {
                        // The fixture rounds to four decimals, the app does not.
                        assertEquals("$where value", values.getDouble(j),
                            field.compute(unmasked), 5e-5)
                    }
                    "hex" -> {
                        assertEquals("$where digits", values.getString(j),
                            Frames.extractHex(clean, page.marker, field))
                    }
                    "state" -> {
                        assertTrue("$where has no value in the fixture", values.isNull(j))
                    }
                    else -> error("$where: unknown kind")
                }
                checked++
            }
        }

        // Guards against a fixture that silently decoded into nothing.
        assertTrue("the fixture looks empty: $checked readings", checked > 10_000)
        println("parity: $checked field readings over ${samples.length()} frames")
    }

    @Test
    fun `the fixture was built against this profile`() {
        val text = File(root, "android/app/src/main/assets/v46_21_profile.json")
            .readBytes()
        val digest = java.security.MessageDigest.getInstance("SHA-256").digest(text)
        val hex = digest.joinToString("") { "%02x".format(it) }
        assertEquals(
            "regenerate the fixture: python tools/parity/make_golden.py",
            golden.getString("profile_sha256"), hex
        )
    }

    /**
     * The recording comes from a Bluetooth sniff and carries no ELM
     * formatting, so the multi-frame handling is checked separately - it is the
     * part that silently corrupts everything after the first frame when it goes
     * wrong.
     */
    @Test
    fun `clean strips framing and length lines`() {
        assertEquals(
            "61FF044F8F4F50FFFFFF0000",
            Frames.clean("03B\r0:61FF044F8F4F\r1:50FFFFFF0000\r\r>")
        )
        assertEquals("61FF044F", Frames.clean("61 ff 04 4f\r\r>"))
        // A short hex line is only a length header when the reply is framed.
        assertEquals("410C1AF8", Frames.clean("41\r0C1AF8\r>"))
    }

    /**
     * The recording cannot cover this: the byte those two bit fields live in
     * reads 0x08 in all 3052 recorded CA frames, so a right and a wrong
     * extraction order come out the same. TYPE_BOITE_VITESSES has mask 3 and
     * shift 6, so masking before shifting would make it identically zero.
     */
    @Test
    fun `bit fields shift before masking`() {
        val page = profile.pages.first { it.id == "CA" }
        val gearbox = page.fields.first { it.key == "TYPE_BOITE_VITESSES" }
        val gear = page.fields.first { it.key == "RAPPORT_ENGAGE" }
        assertEquals(3, gearbox.bitMask)
        assertEquals(6, gearbox.bitShift)

        // A frame whose byte at the pair's offset is 0xC8: top bits 11.
        val bytes = ByteArray(gearbox.offset + 1)
        bytes[0] = 0x61
        bytes[1] = 0xFF.toByte()
        bytes[gearbox.offset] = 0xC8.toByte()
        val frame = bytes.joinToString("") { "%02X".format(it) }

        assertEquals("0xC8 ushr 6 and 3", 3.0, gearbox.compute(0xC8), 1e-9)
        assertEquals("mask 63, shift 0", 8.0, gear.compute(0xC8), 1e-9)
        assertEquals(0xC8, Frames.extract(frame, page.marker, gearbox))
    }
}
