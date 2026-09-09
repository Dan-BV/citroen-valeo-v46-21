package com.fap.modern.core

/**
 * The parameters ticked on a fresh install: enough to log the state of the car
 * and to see a fault forming, without the columns that never move.
 *
 * A page costs one request per cycle and a parameter inside a kept page costs
 * nothing, so the set is chosen page by page first, and a page that is worth
 * having but not worth having often gets a [PERIODS] entry instead of being
 * dropped. Every cycle: $C0 mixture, $C1 ignition, $C2 intake, $CA driving.
 * Every second cycle: $C4 torque. Every third: $CB engine environment. Never:
 * $B0 (immobilizer, static) and $CF (the ZAPV service record, static).
 *
 * Inside those pages the rule is: keep every request/actual pair, every sensor
 * that explains another reading, and every per-cylinder signal the ECU actually
 * computes per cylinder; drop duplicates (pedal track 2, throttle track
 * voltages, sensor supplies 2 and 3), the unconfirmed per-cylinder advance
 * channels, anything an already-kept parameter reports the outcome of, and
 * everything that only matters parked.
 *
 * The drops listed at the end of the set are the ones 25 273 logged samples
 * argued for rather than the datasheet; `data/logs/README.md` holds the
 * evidence.
 */
object BaseSet {

    val keys: Set<String> = linkedSetOf(
        // $C0 - mixture: load, supply, warm-up, injection time, both lambdas
        // and the richness correction that a leak or a tired injector moves
        // first. The canister trio is here because purge is what perturbs that
        // correction: without it a trim shift cannot be told from a purge
        // event, and the commanded richness separates "the ECU asked to
        // enrich" from "this fuel needs more fuel for the same air".
        "REGIME_MOTEUR",
        "TENSION_ALIMENTATION_CALCULATEUR_CONTROLE_MOTEUR",
        "TEMPERATURE_D_EAU_MOTEUR_d",
        "TEMPS_INJECTION_CYLINDRE_01",
        "TENSION_SONDE_A_OXYGENE_AMONT",
        "TENSION_SONDE_A_OXYGENE_AVAL",
        "FACTEUR_CORRECTION_RICHESSE_AMONT",
        "CON_RICHESSE",
        "CHARGE_ESTIMEE_CANISTER",
        "CDERCOELECPURGE",

        // $C1 - ignition: what the map wanted, what cylinder 1 got, and the
        // four knock retards, which name the cylinder that is in trouble.
        "AVANCE_ALLUMAGE_OPTIMAL",
        "AVANCE_ALLUMAGE_APPLIQUEE_A_CHAQUE_CYLINDRE",
        "RETRAIT_AVANCE_ALLUMAGE_CYLINDRE_01",
        "RETRAIT_AVANCE_ALLUMAGE_CYLINDRE_02",
        "RETRAIT_AVANCE_ALLUMAGE_CYLINDRE_03",
        "RETRAIT_AVANCE_ALLUMAGE_CYLINDRE_04",

        // $C2 - intake: filling, boost, throttle and cam phaser each as a
        // request/actual pair, so the gap between them is the fault.
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

        // $CA - driving: the context every other reading is judged against,
        // the idle target, which is where a vacuum leak shows up, and the fuel
        // gauge in litres, which is the only direct measurement of consumption
        // this ECU offers.
        "REGMOTRALENTI",
        "VITESSE_VEHICULE",
        "POSPEDACC1",
        "ETAT_FONCTIONNEMENT_MOTEUR_THERMIQUE",
        "NIVEAU_CARBURANT_AFFICHE",

        // $C4 - torque: the delivered figure against what the driver asked
        // for, plus the drag the ECU thinks it is pulling against. Read every
        // second cycle: it is worth logging, not worth a request every pass.
        "COUPLE_MOTEUR_AVANCE",
        "COUPLE_VOLONTE_CONDUCTEUR",
        "COUPLE_RESISTANT_MOTEUR_ESTIME",

        // $CB - environment. Atmospheric pressure is what makes the manifold
        // reading mean something and doubles as an altimeter; the fan duty
        // catches a cooling fault, but only once the compressor load says
        // whether the fan was spinning for the engine or for the A/C - that
        // was the hidden variable behind two logs that looked like different
        // cooling behaviour. Knock-sensor noise is the raw signal behind the
        // $C1 retards; it clamps at 5000 mV, so only its lower half informs.
        // Deliberately not here: oil pressure (a switch, not a pressure - it
        // says "below the threshold", which the oil lamp says too) and
        // mastervac pressure (a brake-servo fault, not an engine one).
        "TEMPERATURE_AIR_EXTERIEUR",
        "PRESSION_ATMOSPHERIQUE",
        "CONSIGNE_VITESSE_GMV_C5",
        "ESTIMATION_PUISSANCE_CONSO_COMPRESSEUR_REFRI",
        "BRUIT_CAPTEUR_CLIQUETIS",

        // Not selected, and why. All six sat in this set until three logged
        // sessions showed there was nothing in them. FILTER still offers them.
        //
        // TEMPS_INJECTION_CYLINDRE_02/03/04: byte-identical to cylinder 01 in
        //   every one of 25 273 samples. The ECU commands one injection time
        //   for all four; there is no per-cylinder fuel trim to watch.
        // FACTEUR_CORRECTION_RICHESSE_AVAL: byte-identical to _AMONT in every
        //   sample, although the two read different offsets and both agree
        //   with the Diagbox definition.
        // DEPASSEMENT_SEUIL_ENCRASSEMENT_MOTEUR: alternates 0/1 from one
        //   sample to the next, near enough 50/50, in all three logs. The
        //   offset agrees with Diagbox, so the byte is simply not a stable
        //   flag on this ECU.
        // RAPPORT_ENGAGE: constant 8, which the Diagbox enum spells "Uncertain
        //   gear". Manual box, no gear sensor; it cannot read anything else.
    )

    /**
     * How often a page is worth asking for, in poll cycles, for pages that are
     * neither every-cycle nor the profile's own static `slow` ones.
     *
     * This is the lever that actually shortens a cycle: the loop pays one
     * adapter turnaround per page it asks for, and nothing at all for the
     * parameters inside it. Keyed by page id.
     *
     * $CB was every tenth cycle while it only held signals that move over
     * minutes. Knock-sensor noise does not: at one sample per six seconds it
     * is a lottery. Every third cycle puts it near 1.8 s for about 5 % more
     * cycle time, which is the cheapest useful rate on offer.
     */
    val PERIODS: Map<String, Int> = mapOf(
        "C4" to 2,
        "CB" to 3,
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
