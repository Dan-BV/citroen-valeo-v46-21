package com.fap.modern.core

/**
 * A single live parameter definition for the Valeo V46.21 (Citroen/Peugeot EC5) engine ECU.
 *
 * All fields are transcribed directly from the reverse-engineered FAP core
 * (`o0.java` = profile V46_21, cross-checked with `out/v46_21_params.md`).
 *
 * Value derivation (from `k1.G()`):
 *     raw   = parseInt(responseHex[byte sbi .. sbi+dl], 16)
 *     value = raw * scale               // z
 *     value = ((value.toInt() shr bitShift) and bitMask)   // only if bitMask != null
 *     value = value + offset            // D
 *
 * `sbi` is the byte index inside the clean "61<page>…" reply, counting the 0x61
 * mode-echo byte as index 0 (see v46_21_params.md). Byte/width are marked
 * "derivation CONFIRMED; offset UNCERTAIN" upstream, so [ParserTuning.frameByteShift]
 * lets you nudge every offset at once against a live 21Cx dump without recompiling.
 */
enum class ValueKind { NUMERIC, BOOLEAN }

data class ParamDef(
    val key: String,
    val label: String,
    val page: String,          // KWP service-21 request page, e.g. "21CB"
    val sbi: Int,              // byte index inside "61<page>…", 0x61 == 0
    val dl: Int,               // data length in bytes
    val scale: Double,         // z
    val offset: Double,        // D
    val unit: String,
    val min: Double,
    val max: Double,
    val bitShift: Int = 0,
    val bitMask: Int? = null,
    val kind: ValueKind = ValueKind.NUMERIC,
    val desc: String = "",
) {
    val decimals: Int = when {
        kind == ValueKind.BOOLEAN -> 0
        scale >= 1.0 -> 0
        scale >= 0.1 -> 1
        scale >= 0.01 -> 2
        else -> 3
    }

    /** Apply the ECU formula to a raw integer field. */
    fun compute(raw: Int): Double {
        if (kind == ValueKind.BOOLEAN) return if (raw != 0) 1.0 else 0.0
        var v = raw * scale
        val mask = bitMask
        if (mask != null) v = ((v.toInt() ushr bitShift) and mask).toDouble()
        return v + offset
    }
}

/** The full V46.21 live-parameter profile. Numeric params are graphable; BR/CL are boolean indicators. */
object V4621Profile {

    val name = "V46_21"

    val params: List<ParamDef> = listOf(
        ParamDef("Revs", "Engine RPM", "21CB", 11, 2, 5.0, 0.0, "rpm", 0.0, 7000.0),
        ParamDef("Battery", "Battery", "21CB", 17, 1, 0.5, 0.0, "V", 0.0, 17.0),
        ParamDef("Coolant", "Coolant temp", "21CB", 23, 1, 5.0, -50.0, "°C", -50.0, 110.0),
        ParamDef("FanSpeed", "Fan speed", "21CB", 41, 1, 5.0, 0.0, "%", 0.0, 60.0,
            desc = "Instruction for engine fan speed."),
        ParamDef("AirCPress", "A/C pressure", "21CB", 71, 1, 0.5, 0.0, "bar", 0.0, 16.0,
            desc = "Air condition circuit pressure. At 20°C around 6.5 bar."),
        ParamDef("Speed", "Vehicle speed", "21CA", 29, 1, 5.0, 0.0, "km/h", 0.0, 200.0),
        ParamDef("Gear", "Gear", "21CA", 86, 1, 5.0, 0.0, "-", 0.0, 15.0, bitShift = 0, bitMask = 63,
            desc = "Functional on vehicles with automatic / controlled manual gearbox."),
        ParamDef("FuelLevel", "Fuel level", "21CA", 110, 1, 5.0, 0.0, "l", 0.0, 100.0,
            desc = "Fuel level info from BSI."),
        ParamDef("AirManifold", "Manifold air temp", "21C2", 20, 1, 5.0, -50.0, "°C", -50.0, 60.0),
        ParamDef("AtmosphPress", "Atmospheric press", "21CB", 173, 1, 5.0, 500.0, "mbar", 500.0, 1200.0),
        ParamDef("AccelPedalPos", "Accel pedal", "21CA", 47, 1, 0.5, 0.0, "%", 0.0, 100.0),
        ParamDef("KnockSensor", "Knock sensor", "21CB", 137, 1, 0.5, 0.0, "mV", 0.0, 100.0,
            desc = "Noise value measured by the knock detector."),
        ParamDef("Inj.1Time", "Injector 1 time", "21C0", 26, 1, 0.05, 0.0, "ms", 0.0, 10.0,
            desc = "Injector 1 injection time."),
        ParamDef("Inj.2Time", "Injector 2 time", "21C0", 32, 1, 0.05, 0.0, "ms", 0.0, 10.0,
            desc = "Injector 2 injection time."),
        ParamDef("Inj.3Time", "Injector 3 time", "21C0", 38, 1, 0.05, 0.0, "ms", 0.0, 10.0,
            desc = "Injector 3 injection time."),
        ParamDef("Inj.4Time", "Injector 4 time", "21C0", 44, 1, 0.05, 0.0, "ms", 0.0, 10.0,
            desc = "Injector 4 injection time."),
        ParamDef("Cyl.Adv", "Ignition advance", "21C1", 32, 1, 5.0, -100.0, "°", -100.0, 180.0,
            desc = "Ignition advance per cylinder relative to TDC (° crankshaft)."),
        ParamDef("Cyl.1AdvCorr", "Cyl.1 adv corr", "21C1", 50, 1, 5.0, -100.0, "°", -100.0, 180.0,
            desc = "Correction applied to nominal advance to correct knocking."),
        ParamDef("Cyl.2AdvCorr", "Cyl.2 adv corr", "21C1", 53, 1, 5.0, -100.0, "°", -100.0, 180.0,
            desc = "Correction applied to nominal advance to correct knocking."),
        ParamDef("Cyl.3AdvCorr", "Cyl.3 adv corr", "21C1", 56, 1, 5.0, -100.0, "°", -100.0, 180.0,
            desc = "Correction applied to nominal advance to correct knocking."),
        ParamDef("Cyl.4AdvCorr", "Cyl.4 adv corr", "21C1", 59, 1, 5.0, -100.0, "°", -100.0, 180.0,
            desc = "Correction applied to nominal advance to correct knocking."),
        ParamDef("UpMixCorr", "Upstream mix corr", "21C0", 146, 2, 3.82e-5, -0.25, "-", -0.25, 0.25,
            desc = "Richness regulation correction (upstream). ~0 when active, 0 when inactive."),
        ParamDef("DownMixCorr", "Downstream mix corr", "21C0", 158, 2, 3.82e-5, -0.25, "-", -0.25, 0.25,
            desc = "Richness regulation correction (downstream). ~0 when active, 0 when inactive."),
        ParamDef("UpO2Volt", "Upstream O2", "21C0", 86, 2, 5.0, 0.0, "mV", 0.0, 1800.0,
            desc = "Upstream oxygen sensor voltage."),
        ParamDef("DownO2Volt", "Downstream O2", "21C0", 110, 2, 5.0, 0.0, "mV", 0.0, 1800.0,
            desc = "Downstream oxygen sensor voltage."),
        ParamDef("UpO2Heat", "Upstream O2 heat", "21C0", 122, 1, 0.5, 0.0, "%", 0.0, 120.0,
            desc = "Upstream oxygen sensor heating; 0 if sensor fault."),
        ParamDef("DownO2Heat", "Downstream O2 heat", "21C0", 134, 1, 0.5, 0.0, "%", 0.0, 120.0,
            desc = "Downstream oxygen sensor heating; 0 if sensor fault."),
        ParamDef("CanisterValve", "Canister valve", "21C0", 176, 1, 5.0, 0.0, "%", 0.0, 120.0,
            desc = "Canister discharge electrovalve open cycle ratio."),
        ParamDef("BrakePress", "Brake servo press", "21CB", 179, 1, 5.0, 0.0, "mbar", 0.0, 1200.0,
            desc = "Brake servo pressure from vacuum sensor."),
        ParamDef("AirFlowInstr", "Air flow (instr)", "21C2", 161, 2, 0.5, 0.0, "kg/h", 0.0, 500.0,
            desc = "Instruction for air flow to be reached."),
        ParamDef("AirFlow", "Air flow", "21C2", 41, 2, 0.5, 0.0, "kg/h", 0.0, 500.0,
            desc = "Measured air flow."),
        ParamDef("IntakeAirPressInstr", "Intake press (instr)", "21C2", 44, 1, 105.0, 0.0, "mbar", 0.0, 2000.0,
            desc = "Instruction for intake pressure to be reached."),
        ParamDef("IntakeAirPress", "Intake press", "21C2", 47, 1, 105.0, 0.0, "mbar", 0.0, 2000.0,
            desc = "Intake pressure measured."),
        ParamDef("InCamDephaserInstr", "In cam dephaser (instr)", "21C2", 68, 1, 5.0, -100.0, "°", -100.0, 100.0,
            desc = "Instruction for inlet camshaft dephaser position (° crankshaft)."),
        ParamDef("InCamDephaser", "In cam dephaser", "21C2", 74, 1, 5.0, -100.0, "°", -100.0, 100.0,
            desc = "Should be close to InCamDephaser (instr)."),
        ParamDef("InCamDephaserValve", "In cam dephaser valve", "21C2", 80, 1, 5.0, 0.0, "%", 0.0, 120.0,
            desc = "Inlet camshaft dephaser solenoid valve position."),
        ParamDef("ExternalTemp", "External temp", "21CB", 125, 1, 5.0, -40.0, "°C", -40.0, 40.0),
        // Boolean indicators (bit flags in 21CA; exact bit uncertain, treated as byte != 0).
        ParamDef("BR", "Brake pedal", "21CA", 74, 1, 1.0, 0.0, "", 0.0, 1.0,
            kind = ValueKind.BOOLEAN, desc = "Indicator - Brake pedal pressed."),
        ParamDef("CL", "Clutch pedal", "21CA", 77, 1, 1.0, 0.0, "", 0.0, 1.0,
            kind = ValueKind.BOOLEAN, desc = "Indicator - Clutch pedal pressed."),
    )

    /** Request pages in the fixed poll order used by the original app. */
    val pages: List<String> = params.map { it.page }.distinct()

    fun paramsForPage(page: String): List<ParamDef> = params.filter { it.page == page }

    fun byKey(key: String): ParamDef? = params.firstOrNull { it.key == key }
}

/** Global, user-adjustable framing tweak for offset-uncertain profiles. */
object ParserTuning {
    /** Shifts every parameter's byte index by this many bytes. Adjust against a live 21Cx dump. */
    @Volatile
    var frameByteShift: Int = 0
}
