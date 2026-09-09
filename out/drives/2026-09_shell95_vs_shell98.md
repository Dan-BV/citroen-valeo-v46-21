# Shell 95 vs Shell 98 — what the logs actually show

Inputs: [`data/logs/fap_log_20260906_100733.csv`](../../data/logs/fap_log_20260906_100733.csv),
[`fap_log_20260906_140930.csv`](../../data/logs/fap_log_20260906_140930.csv) (both **Shell 95**)
and [`fap_log_20260909_080518.csv`](../../data/logs/fap_log_20260909_080518.csv) (**Shell 98**).
25 273 samples in total.

**Short version.** The 98 does buy a little knock margin — the retard tail loses its 7 °
events. It buys no ignition advance and therefore no power, because the applied advance never
exceeds `AVANCE_ALLUMAGE_OPTIMAL` and that ceiling is the same map on both fuels. And it costs
2–4 % more fuel by volume for the same air mass. On this ECU, 98 is a worse deal than 95
unless the goal is specifically to protect against low-rpm lugging knock.

## The runs are not comparable head-on

|  | 06-09 morning (95) | 06-09 afternoon (95) | 09-09 (98) |
|---|---|---|---|
| Distance | 112.0 km | 112.8 km | **18.5 km** |
| Moving | 109 min | 114 min | **38.6 min** |
| Idle | 10.8 min | 4.3 min | **22.8 min — 37 % of the log** |
| Mean moving speed | 61.5 km/h | 59.5 km/h | **28.7 km/h** |
| A/C compressor on | 82 % of samples | 57 % | not logged (14 °C, presumed off) |
| Barometric range | 805–867 mbar | 784–868 mbar | **855–894 mbar** |
| Elevation covered | ≈1050–1900 m | ≈1290–2110 m | **≈1040–1410 m** |

So: mountain highway versus town traffic, and 370 m of elevation range against 850 m. Every
integrated figure — fuel per 100 km, time above a coolant threshold, share of samples at
part load — differs because of that, not because of the fuel. Only condition-matched cells
say anything.

The lower altitude alone gave the engine 6–9 % more air at full throttle: filling 84–87 %
against 78–83 %, manifold 861–882 mbar against 777–819. The 09-09 run is the *more*
knock-prone of the three, before the fuel is even considered.

## Knock: the 98 shortens the tail, nothing more

Warm samples only (coolant ≥ 85 °C), maximum retard across the four cylinders:

| Fuel | Warm samples | With retard | Retard histogram (°) |
|---|---|---|---|
| 95, morning | 4075 | 251 (6.16 %) | 1:57 2:51 3:90 4:11 5:7 6:20 **7:15** |
| 95, afternoon | 3962 | 45 (1.14 %) | 1:6 2:3 3:21 6:8 **7:7** |
| **98** | 3683 | 51 (1.38 %) | 1:5 2:8 3:35 6:3 — **no 4, 5 or 7** |

The 98 run holds its worst case to 6 °, once, three samples long, while both 95 runs reached
7 °. It does that at higher cylinder filling and higher intake air temperature (36–40 °C
against 32–38), so the margin is real rather than an artefact of an easier drive.

What it does **not** fix is lugging. At 08:45:59, full pedal from 2320 rpm in a tall gear
produced 3 ° of retard in all ten consecutive samples — the same behaviour the 95 showed at
14:55:36. Low-rpm high-load knock is a gear-selection problem, not an octane one:

| Fuel | Warm, rpm < 2800, filling ≥ 70 % | With retard |
|---|---|---|
| 95, morning | 191 | 22 (11.5 %) |
| 95, afternoon | 174 | 12 (6.9 %) |
| 98 | 117 | 20 (17.1 %) |

Cylinder attribution is identical on both fuels — 2 and 3 dominate, 1 and 4 are rare. That is
the engine's geometry, not the fuel.

## The 98 buys no advance, because the ECU cannot spend it

`AVANCE_ALLUMAGE_APPLIQUEE` exceeded `AVANCE_ALLUMAGE_OPTIMAL` in **0 of 25 273 samples**.
The optimal value is a map ceiling; knock control only ever subtracts from it. There is no
octane adaptation raising that ceiling on this calibration — matched cells give the same
number on both fuels:

| rpm / filling | 95 morning (opt / applied) | 95 afternoon | 98 |
|---|---|---|---|
| 2500–3500 / 60–75 % | 22 / 21 | 21 / 21 | 21 / 21 |
| 2500–3500 / 75–95 % | 21 / 20 | 21 / 21 | 21 / 20 |
| 3500–4500 / 75–95 % | 24 / 24 | 25 / 24 | 24 / 22 |
| 4500–6200 / 75–95 % | 28 / 26 | 29 / 27 | 29 / 24 |

Torque tells the same story. Peak `COUPLE_MOTEUR_AVANCE` was 131 Nm on the 98 against 124 and
122 Nm on the 95, and peak `COUPLE_VOLONTE_CONDUCTEUR` was 175 Nm on all three — the extra
9 Nm is the denser air at 1100 m, not the fuel.

## The 98 needs 2–4 % more fuel for the same air

Measured as `(injection time × rpm) / DEBIT_AIR` — fuel flow over air *mass* flow, so it is
independent of altitude. Warm, closed loop, 1500–3000 rpm:

| Filling | 95 morning | 95 afternoon | 98 | Δ |
|---|---|---|---|---|
| 30–40 % | 237.6 | 235.6 | 241.3 | **+2.0 %** |
| 40–55 % | 237.8 | 238.1 | 247.8 | **+4.1 %** |
| 55–75 % | 245.5 | 250.3 | 252.3 | **+1.8 %** |

Steady state only (|drpm/dt| < 80 /s, pedal steady) gives 244.6–245.3 on the 98 against
236.1–240.6 on the 95 — the same 2–4 %.

The short-term lambda correction moved the same way: median **+0.011** on the 98 against
−0.003 and −0.001 on the 95, mean +0.0105 against −0.0045 and 0.000. The correction accounts
for about 1 % of the shift; the rest has presumably been absorbed by the long-term adaptives,
which this parameter set does not read.

**Altitude is ruled out as the cause.** Within the 06-09 afternoon log alone,
`DEBIT_AIR / (REMPLISSAGE × rpm)` holds at 0.5423 → 0.5494 across 789 → 878 mbar, so
`REMPLISSAGE_MESURE` is already a mass-normalised load and the barometer does not move the
fuel-per-air ratio.

The reading: Shell V-Power 98 carries more oxygenate than the 95, so stoichiometry sits at a
lower air-fuel ratio and the ECU injects more volume for the same air. 2–4 % is the right
order for that. A weakening fuel pump would produce the same signature — rail pressure is not
logged on this ECU — but the fuel change is the simpler explanation now that it is known, and
the way to settle it is one tank of 95 from the same station: if the offset disappears it was
the fuel.

## Cooling: hot, but not faulty

The 98 run spent **10.7 %** of its samples at coolant ≥ 95 °C against 0.7 % and 1.9 %, peaking
at 97 °C. That is the 23 minutes of idling, not a cooling fault:

| Coolant | 95 morning, fan duty | 95 afternoon | 98 |
|---|---|---|---|
| 88–92 °C | p50 48 % | p50 68 % | p50 28 % |
| 92–95 °C | p50 30 % | p50 30 % | p50 30 % |
| 95–101 °C | p50 44 %, max 62 % | p50 44 %, max 56 % | p50 44 %, max 56 % |

The fan follows the same map on all three. It reached 92 % and 78 % on 06-09 only because the
A/C was running — `ESTIMATION_PUISSANCE_CONSO_COMPRESSEUR_REFRI` was above zero for 82 % and
57 % of those logs, and it drives the fan for the condenser. The 06-09 logs also record
`TEMPERATURE_EAU_DERNIER_ARRET_MOTEUR` = 99 °C, so a hot shutdown predates all of this.

Worth watching, not acting on: if a long idle ever pushes past 100–103 °C, look at the
thermostat and the pump.

Warm-up on 09-09: 80 °C at 11.2 min, 90 °C at 21.9 min, from a 15 °C start at 11 °C ambient.
The 06-09 morning run reached 80 °C in 6.0 min from a 24 °C start. Slower, but consistent with
the colder start and the town traffic.

## Idle got tidier

| | 95 morning | 95 afternoon | 98 |
|---|---|---|---|
| Idle target | 800 rpm | 800 rpm | 750 rpm |
| Idle rpm, p05–p95 | 740–807 | 748–852 | **742–762** |
| Injection at idle | 2.87 ms | 2.83 ms | 2.44 ms |
| Filling at idle | 24 % | 24 % | 20 % |

Much steadier — but the A/C was cycling on both 95 runs and not on the 98 one, so this is not
attributable to the fuel.

## Parameter-set problems this exposed

Fixed in `BaseSet.kt` alongside this document. Dropped as unreadable or duplicated:
`TEMPS_INJECTION_CYLINDRE_02/03/04`, `FACTEUR_CORRECTION_RICHESSE_AVAL`,
`DEPASSEMENT_SEUIL_ENCRASSEMENT_MOTEUR`, `RAPPORT_ENGAGE` — evidence in
[`data/logs/README.md`](../../data/logs/README.md).

Added, all inside pages already being asked for, so they cost no bus time:
`CHARGE_ESTIMEE_CANISTER`, `CDERCOELECPURGE`, `CON_RICHESSE` ($C0), `BRUIT_CAPTEUR_CLIQUETIS`,
`ESTIMATION_PUISSANCE_CONSO_COMPRESSEUR_REFRI` ($CB), `NIVEAU_CARBURANT_AFFICHE` ($CA).

Every conclusion above needed one of those. The purge valve perturbs the very lambda
correction the fuel comparison rests on; the A/C load was the hidden variable behind the fan
duty; the commanded richness separates "the ECU asked for enrichment" from "this fuel needs
more"; the fuel gauge in litres is the only direct consumption measurement available.

`$CB`'s period drops from every 10th cycle to every 3rd, so knock-sensor noise arrives about
every 1.8 s instead of every 6 s. That is about +5 % cycle time.

Note on `BRUIT_CAPTEUR_CLIQUETIS`: it clamps at 5000 mV and the 06-09 logs sit at p95 = 5000,
so the top of its range carries no information. The median still separated the two runs
(4191 vs 3963 mV), which is what it is being kept for.

## How to make the next comparison decisive

The 09-09 run accidentally produced most of a usable reference. Repeat exactly this on 95:

- same climb, warm engine (coolant 88–92 °C), A/C off;
- third gear, 100 % pedal, 1500 → 5000 rpm, three runs back to back.

The 98 run's three consecutive pulls are the benchmark to beat:

| Time | rpm | Rate | Filling | Retard samples |
|---|---|---|---|---|
| 08:48:13 | 3467 → 5302 | +4.80 km/h/s | 87 % | 3 of 9 |
| 08:48:31 | 3572 → 4965 | +4.14 km/h/s | 87 % | 2 of 8 |
| 08:48:52 | 3519 → 5450 | +4.69 km/h/s | 86 % | 6 of 10 |

Record the barometer with them — at these altitudes it moves peak filling by most of a
tenth, which is larger than anything the fuel does.
