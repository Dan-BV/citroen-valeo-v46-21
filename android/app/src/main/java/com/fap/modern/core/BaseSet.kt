package com.fap.modern.core

/**
 * The parameters ticked on a fresh install: enough to log the state of the car
 * and to see a fault forming, without the columns that never move.
 *
 * A page costs one request per cycle and a parameter inside a kept page costs
 * nothing, so the set is chosen page by page first, and a page that is worth
 * having but not worth having often gets a [PERIODS] entry instead of being
 * dropped. Every cycle: $C0 mixture, $C1 ignition, $C2 intake, $CA driving.
 * Every second cycle: $C4 torque. Every tenth: $CB engine environment, whose
 * survivors all move on the scale of minutes. Never: $B0 (immobilizer, static)
 * and $CF (the ZAPV service record, static).
 *
 * Inside those pages the rule is: keep every request/actual pair, every
 * per-cylinder signal, and every sensor that explains another reading; drop
 * duplicates (pedal track 2, throttle track voltages, sensor supplies 2 and 3),
 * the unconfirmed per-cylinder advance channels, anything an already-kept
 * parameter reports the outcome of, and everything that only matters parked.
 */
object BaseSet {

    val keys: Set<String> = linkedSetOf(
        // $C0 - mixture: load, supply, warm-up, per-injector balance, both
        // lambdas and the two richness corrections that a leak or a tired
        // injector moves first.
        "REGIME_MOTEUR",
        "TENSION_ALIMENTATION_CALCULATEUR_CONTROLE_MOTEUR",
        "TEMPERATURE_D_EAU_MOTEUR_d",
        "TEMPS_INJECTION_CYLINDRE_01",
        "TEMPS_INJECTION_CYLINDRE_02",
        "TEMPS_INJECTION_CYLINDRE_03",
        "TEMPS_INJECTION_CYLINDRE_04",
        "TENSION_SONDE_A_OXYGENE_AMONT",
        "TENSION_SONDE_A_OXYGENE_AVAL",
        "FACTEUR_CORRECTION_RICHESSE_AMONT",
        "FACTEUR_CORRECTION_RICHESSE_AVAL",

        // $C1 - ignition: what the map wanted, what cylinder 1 got, and the
        // four knock retards, which name the cylinder that is in trouble.
        "AVANCE_ALLUMAGE_OPTIMAL",
        "AVANCE_ALLUMAGE_APPLIQUEE_A_CHAQUE_CYLINDRE",
        "RETRAIT_AVANCE_ALLUMAGE_CYLINDRE_01",
        "RETRAIT_AVANCE_ALLUMAGE_CYLINDRE_02",
        "RETRAIT_AVANCE_ALLUMAGE_CYLINDRE_03",
        "RETRAIT_AVANCE_ALLUMAGE_CYLINDRE_04",

        // $C2 - intake: filling, boost, throttle and cam phaser each as a
        // request/actual pair, so the gap between them is the fault. The
        // fouling threshold is this engine's own carbon warning.
        "TEMP_AIR_ADMISSION_SUP",
        "REMPLISSAGE_DE_CONSIGNE",
        "REMPLISSAGE_MESURE",
        "DEBIT_AIR",
        "CONSIGNE_PRESSION_ADMISSION",
        "PRESSIONTUBULURE",
        "ANGLE_PAPILLON_CONSIGNE",
        "ANGLE_PAPILLON_MESURE",
        "CONSIGNE_POSITION_DEPHASEUR_AAC_ADMISSION",
        "POS_DEPHASEUR_ACC_1",
        "ETAT_COH_POSITION_AAC_ADMI_VIL",
        "DEPASSEMENT_SEUIL_ENCRASSEMENT_MOTEUR",

        // $CA - driving: the context every other reading is judged against,
        // plus the idle target, which is where a vacuum leak shows up.
        "REGMOTRALENTI",
        "VITESSE_VEHICULE",
        "POSPEDACC1",
        "RAPPORT_ENGAGE",
        "ETAT_FONCTIONNEMENT_MOTEUR_THERMIQUE",

        // $C4 - torque: the delivered figure against what the driver asked
        // for, plus the drag the ECU thinks it is pulling against. Read every
        // second cycle: it is worth logging, not worth a request every pass.
        "COUPLE_MOTEUR_AVANCE",
        "COUPLE_VOLONTE_CONDUCTEUR",
        "COUPLE_RESISTANT_MOTEUR_ESTIME",

        // $CB - environment, on the slow tier: what is left here moves over
        // minutes. Atmospheric pressure is what makes the manifold reading
        // mean something, and the fan duty catches a cooling fault.
        // Deliberately not here: oil pressure (a switch, not a pressure - it
        // says "below the threshold", which the oil light says too), mastervac
        // pressure (a brake-servo fault, not an engine one) and knock-sensor
        // noise (the four knock retards on $C1 report the outcome of it, at
        // full rate).
        "TEMPERATURE_AIR_EXTERIEUR",
        "PRESSION_ATMOSPHERIQUE",
        "CONSIGNE_VITESSE_GMV_C5",
    )

    /**
     * How often a page is worth asking for, in poll cycles, for pages that are
     * neither every-cycle nor the profile's own static `slow` ones.
     *
     * This is the lever that actually shortens a cycle: the loop pays one
     * adapter turnaround per page it asks for, and nothing at all for the
     * parameters inside it. Keyed by page id.
     */
    val PERIODS: Map<String, Int> = mapOf(
        "C4" to 2,
        "CB" to 10,
    )

    /**
     * The base set as this profile actually spells it. A regenerated profile
     * may rename or drop a key, and a selection holding keys no page owns
     * would quietly poll nothing.
     */
    fun keysIn(profile: Profile): Set<String> {
        val known = profile.fields.map { it.key }.toSet()
        return keys.filter { known.contains(it) }.toSet()
    }
}
