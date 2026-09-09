# Drive logs

Raw CSV recordings written by the Android app (`CsvLogger`): one column per polled
parameter, one row per poll cycle, `time_ms` in Unix milliseconds and `iso` in local
time. A cell is empty when that parameter had no valid reading in the cycle; a
parameter on a slowed-down page (see `BaseSet.PERIODS`) repeats its last value until
the page is asked for again, so consecutive equal values are expected, not a fault.

These are the inputs. Anything derived from them lives in [`out/drives/`](../../out/drives/),
and the standing conclusions in [`out/driving_cheatsheet.md`](../../out/driving_cheatsheet.md).

## Sessions

| File | Start | Duration | Distance | Rows | Params | Cycle | Coolant | Ambient | Baro | Peak rpm |
|---|---|---|---|---|---|---|---|---|---|---|
| `fap_log_20260904_090225.csv` | 2026-09-04 09:02 | 23 min | — | 2959 | 118 | 468 ms | 86–98 °C | 23–30 °C | 841–892 | 5801 |
| `fap_log_20260904_172133.csv` | 2026-09-04 17:21 | 9 min | 1.4 km | 851 | 121 | 638 ms | 37–88 °C | 30–31 °C | 850–857 | 4542 |
| `fap_log_20260904_173334.csv` | 2026-09-04 17:33 | 20 min | 3.1 km | 2235 | 121 | 529 ms | 88–97 °C | 31–32 °C | 848–863 | 5661 |
| `fap_log_20260905_182420.csv` | 2026-09-05 18:24 | 16 min | 4.9 km | 1801 | 107 | 532 ms | 78–97 °C | 24–25 °C | 839–860 | 5231 |
| `fap_log_20260905_195830.csv` | 2026-09-05 19:58 | 15 min | 5.6 km | 1151 | 107 | 803 ms | 76–96 °C | 21–23 °C | 836–860 | 5978 |
| `fap_log_20260906_100733.csv` | 2026-09-06 10:07 | 120 min | 112.0 km | 10232 | 107 | 704 ms | 24–98 °C | 18–26 °C | 805–867 | 5661 |
| `fap_log_20260906_140930.csv` | 2026-09-06 14:09 | 118 min | 112.8 km | 8717 | 107 | 812 ms | 65–98 °C | 18–32 °C | 784–868 | 6071 |
| `fap_log_20260909_080518.csv` | 2026-09-09 08:05 | 61 min | 18.5 km | 6324 | 40 | 583 ms | 15–97 °C | 11–18 °C | 855–894 | 6009 |

Distance is integrated from `VITESSE_VEHICULE`; the 09-04 09:02 session has none because
the car did not move (bench revving). Baro is `PRESSION_ATMOSPHERIQUE` in mbar — on this
engine it doubles as an altimeter, and the range is the elevation the drive covered.

## What was in the tank

| Session | Fuel |
|---|---|
| 2026-09-06, both runs | Shell 95 |
| 2026-09-09 | Shell 98 |

Earlier sessions: unrecorded.

## Notes per session

- **2026-09-04 09:02** — 118 parameters, stationary. First long capture on the full page set.
- **2026-09-04 17:21 / 17:33** — 121 parameters, the widest set recorded. Short town hops.
- **2026-09-05** — 107 parameters. A third file, `fap_log_20260905_195825.csv`, held four
  rows and is not kept; `CsvLogger.stop()` now deletes empty files by itself.
- **2026-09-06 10:07 and 14:09** — the reference pair: two ~112 km mountain runs on the same
  day and the same tank of Shell 95, 1050–2110 m of elevation, A/C on 82 % and 57 % of the
  time. These are the baseline every later drive is compared against.
- **2026-09-09 08:05** — first run on Shell 98, and the first on the trimmed 40-parameter
  selection (hence the shorter 583 ms cycle). Town traffic, 37 % of the log at idle,
  1040–1410 m. Analysed in
  [`out/drives/2026-09_shell95_vs_shell98.md`](../../out/drives/2026-09_shell95_vs_shell98.md).

## Columns that are not worth reading

Established from 25 273 samples across the three September sessions above, and the reason
the base selection dropped them (see `android/.../core/BaseSet.kt`):

- `TEMPS_INJECTION_CYLINDRE_02/03/04` — byte-identical to cylinder 01 in every sample. The
  ECU commands one injection time for all four; there is no per-cylinder fuel trim to see.
- `FACTEUR_CORRECTION_RICHESSE_AVAL` — byte-identical to `..._AMONT` in every sample, though
  the two read different offsets and both match the Diagbox definition.
- `DEPASSEMENT_SEUIL_ENCRASSEMENT_MOTEUR` — alternates 0/1 from one sample to the next, near
  enough 50/50, in all three logs. The offset agrees with Diagbox, so the byte is simply not
  a stable flag on this ECU.
- `RAPPORT_ENGAGE` — constant 8, which the Diagbox enum spells "Uncertain gear". Manual box,
  no gear sensor; it cannot read anything else.
- `PRESSION_HUILE_MOTEUR` — constant 1. It is a threshold switch, not a pressure, and the oil
  lamp already reports the same bit.
