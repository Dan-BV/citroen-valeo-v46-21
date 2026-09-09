# Driving this engine: what the logs say

Everything here is measured from [`data/logs/`](../data/logs/) — the three September 2026
sessions, 25 273 samples — not from a manual. Gear ratios are derived from the rpm/speed
ratio, torque from `COUPLE_MOTEUR_AVANCE`, knock from the four
`RETRAIT_AVANCE_ALLUMAGE_CYLINDRE_*` channels.

**One caveat on absolute numbers:** every sample was taken between 1000 and 2100 m, where the
engine loses roughly a fifth of its output. The shape of the curves is what to drive by; the
kW figures are what this car actually delivers up there.

## Lugging is load, not rpm

This is the correction worth internalising. At 2000–2600 rpm, warm:

| Cylinder filling | Samples | Knock | Mean retard |
|---|---|---|---|
| 15–35 % | 1074 | **0.0 %** | 0.00 |
| 35–50 % | 528 | **0.0 %** | 0.00 |
| 50–65 % | 217 | 2.3 % | 0.06 |
| 65–75 % | 161 | **0.0 %** | 0.00 |
| **75–95 %** | 66 | **33.3 %** | 0.74 |

2400 rpm is harmless up to 75 % filling. The cliff is at 75 %, and it is a load threshold, not
an rpm one.

> **Lugging = filling above 75 % below about 2800 rpm.**
> From the driver's seat: pedal past two thirds while the revs are low means the wrong gear.

| Pedal | Filling | Minimum rpm |
|---|---|---|
| under ⅓ | < 50 % | 1500 |
| ⅓–⅔ | 50–75 % | 2000 |
| **over ⅔** | **> 75 %** | **3000+** |

A "never below 3000" rule works on a climb only because a climb forces high filling anyway.
On the flat it is not needed.

## Torque is flat, power is not

Wide-open throttle, warm, torque at p90:

| rpm | Torque | Power |
|---|---|---|
| 2200 | 120 Nm | **28 kW (38 hp)** |
| 2600 | 125 Nm | 34 kW (46 hp) |
| 3000 | 129 Nm | 40 kW (55 hp) |
| 3400 | 130 Nm | 46 kW (63 hp) |
| 3800 | 130 Nm | 52 kW (71 hp) |
| 4250 | 127 Nm | 56 kW (77 hp) |
| 4750 | 126 Nm | **63 kW (85 hp)** |
| 5300 | 120 Nm | 67 kW (91 hp) |
| 5600 | ~101 Nm | ~59 kW |

(The 2000–2400 band rests on 7 samples and the 5600 figure on one; everything between is
40–140 samples per band.)

Lugging does not buy torque — the torque is the same. It costs power, and power is what climbs
a hill. Peak power sits near 5000–5300 and is falling by 5600.

## Gears

| Gear | rpm per km/h | Step to next |
|---|---|---|
| 1st | ≈140 (approximate — few samples) | ×0.554 |
| 2nd | 77.5 | ×0.690 |
| 3rd | 53.5 | ×0.738 |
| 4th | 39.5 | ×0.785 |
| 5th | 31.0 | — |

The steps grow monotonically, which is the standard progressive layout: 1st is a launch gear,
not a driving gear, so the drop out of it is always the largest. Nothing is mismatched.

**Speed at a given rpm:**

| rpm | 2nd | 3rd | 4th | 5th |
|---|---|---|---|---|
| 3000 | 39 | 56 | 76 | 97 |
| 3500 | 45 | 65 | 89 | 113 |
| 4000 | 52 | 75 | 101 | 129 |
| 4500 | 58 | 84 | 114 | 145 |

The 3000–4500 window per gear: 2nd 39–58 km/h, 3rd 56–84, 4th 76–114, 5th 97–145. **5th is
not a climbing gear** below 100 km/h; a mountain road at 50–70 km/h is always 3rd.

## Upshift points

Because the steps differ, the shift point differs. To land at 3000 rpm:

| Shift | Multiplier | Land 3000 | Land 3200 |
|---|---|---|---|
| 1→2 | ×0.554 | **5420** | 5780 |
| 2→3 | ×0.690 | **4350** | 4640 |
| 3→4 | ×0.738 | **4060** | 4330 |
| 4→5 | ×0.785 | **3820** | 4080 |

- **On a climb:** 1→2 at ~5400, 2→3 at 4400–4900, 3→4 at 4100–4600, 4→5 at 3800–4300.
  A flat "5000 for everything" over-revs 4→5 (lands at 3925) and under-revs 1→2 (lands at 2770).
- **On the flat:** anything from 2500 up. Shifting at 3500 lands at 2416 / 2584 / 2747, all of
  which are fine because the load is low.

**The 1→2 drop** is the biggest and it is normal. It only feels like a hole when the pedal goes
deep immediately after the shift. Two ways out, pick by situation: in town shift at 2500–3000
(landing at 1400–1660) and do not floor it straight away; pulling away uphill, take 1st to
5000–5400. Revving 1st to 6000 lands at 3324 — past peak torque, noise for nothing.

## Sitting at 4500–5000 on a climb

No time limit from the engine's side. Evidence from the logs:

- longest stretch above 4000 rpm: **59 s** — coolant went 85 → 87 °C;
- bursts to 5100–5716 rpm for 10–12 s: coolant +1–2 °C;
- fan duty never exceeded 62 %, coolant never exceeded 98 °C.

Plenty of headroom. Honest limit of this evidence: no long sustained high-rpm climb was ever
logged, so this is inferred from margin rather than measured.

**Fuel cost of revving, at high load:**

| rpm | Fuel per second | Power | Fuel per unit of work |
|---|---|---|---|
| 2000–2600 | 28.5 | 29 kW | 0.0962 |
| 2600–3200 | 34.2 | 35 kW | 0.1004 |
| 3200–3800 | 40.9 | 43 kW | 0.1000 |
| 3800–4400 | 49.4 | 50 kW | 0.1049 |
| 4400–5100 | 61.4 | 59 kW | 0.1087 |

At 4500–5000 you burn 2.15× more fuel per second than at 2300 but make 2.03× the power — a
13 % efficiency penalty. Revving to climb is loud, not wasteful.

Still, 4500–5000 is the shift zone, not the cruise zone. Pick the gear so a long climb settles
at **3200–4200 with 60–80 % pedal**; stay at 4500–5000 only when the climb genuinely needs
55–60 kW. Watch the coolant: past 100–103 °C with the fan maxed and still rising, back off.

## Above 6000 rpm

Almost never, for propulsion. Only 9 samples of ~20 800 driving samples sat above 5600 rpm,
and 7 of them had the pedal at zero or filling near 20 % — downshift blips and over-run, not
pulls. The two loaded ones made 101 and 95 Nm, against 126 Nm at 4750. Torque has dropped
about a fifth by 5600 and power with it.

Legitimate reasons to hold past 5300: not shifting mid-corner or mid-overtake; a short crest
where the upshift would drop you into the wrong band for the two seconds the climb has left;
and rev-matching on a downshift.

## Backing off beats a taller gear

Same rpm, different load, warm:

| rpm | filling 50–70 % | 70–80 % | 80–95 % |
|---|---|---|---|
| 2200–2800 | **4.6 %** | 9.8 % | — |
| 2800–3400 | **4.9 %** | 11.3 % | 17.2 % |
| 3400–4200 | **4.2 %** | 27.3 % | 25.4 % |

The same power taken as "lower gear + two thirds pedal" knocks five to six times less than
"taller gear + floored", and leaves pedal in reserve.

## Watching it live in the app

- `RETRAIT_AVANCE_ALLUMAGE_CYLINDRE_02` and `_03` — these two catch it first, on every fuel and
  in every log. Anything non-zero on a climb means the gear is too tall or the pedal too deep.
- `REMPLISSAGE_MESURE` — keep it under 75 % on a sustained climb. Past 80 %, change down.
- `TEMPERATURE_D_EAU_MOTEUR_d` with `CONSIGNE_VITESSE_GMV_C5` — the pair that says whether a hot
  climb is still under control.

## Habit worth changing

Share of driving time by rpm, all three logs:

```
1500-1999  10.1%  ######
2000-2499  21.4%  ############
2500-2999  40.0%  ########################
3000-3499  12.5%  #######
3500-3999   3.0%  #
4000+       1.3%
```

83 % below 3000 rpm, 4.3 % above 3500. Fine and economical on the flat — and exactly the habit
that produces lugging on a climb.

## Related

- [`out/drives/2026-09_shell95_vs_shell98.md`](drives/2026-09_shell95_vs_shell98.md) — the fuel
  comparison these logs were originally recorded for, and why 98 buys no advance here.
- [`data/logs/README.md`](../data/logs/README.md) — the session index and the columns that are
  not worth reading.
