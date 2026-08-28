# Citroen C4 (2013) petrol EC5 / Valeo V46.21 - FAP-derived live parameters

> **CORRECTION 2 (definitive): V46.21 is read over K-LINE, ISO 14230-4 KWP - not CAN, not 7E0.**
> `c.G0()` proves only the engine (`f1165a==0`) may use `f1166b` 2/3; CAN (0/1) returned NO DATA on the car.
> Sequence: `ATSP5` (KWP fast init; `ATSP4`=5-baud fallback), header **`ATSH8110F1`** (81 10 F1), `ATFI`, `ATSW00`,
> then `81`->C1, `1003`/`10C0`/`10A4`->50, keep-alive `3E` every ~2.9 s, then reads `21CB 21CA 21C0 21C1 21C2`.
> No CAN flow-control / ATCRA on K-line. `.csp` `HDR` = **8110F1** (Car Scanner protocol: ISO 14230-4 KWP fast).
> Full trace: `fap_session_sequence.md`; capture script: `terminal_commands.txt`.



ECU profile `V46_21` -> `x("V46_21")=50` -> `j1.W[50] = new o0().a()` (class `o0.java`). All values below are decrypted from the app's obfuscated tables (DES/CBC, key derived in `k1.I()`), not guessed.

## Response-string indexing convention (verified in code)

FAP keeps each ECU reply as a hex string `str4` (`MainActivity.d2`->`k1.G`). Layout:

```
char[0:2] = length/PCI byte (e.g. '48')
char[2:4] = response SID  (0x61 = 0x21 request + 0x40)
char[4:6] = echoed sub-parameter (e.g. 'CB')
char[6:] = data payload
```

Value = `Integer.parseInt(str4.substring(u,v),16) * z + D`, then an optional transform selected by field `M`.

`u` (1st int) and `v` (2nd int) are the SAME field's start offset under TWO adapter framings (proven by the injector/cylinder series: field width is constant while |u-v| grows ~4:3). The clean/re-assembled framing that Car Scanner sees corresponds to `min(u,v)`. Car Scanner SBI below = `(min(u,v)-2)/2` i.e. byte index counting the 0x61 mode-echo byte as index 0 (length byte removed). **Byte offset/width are UNCERTAIN: no captured 21Cx frame was available to confirm them (the provided validation frames use 21FF02xx, a different request scheme this profile does not use).**

## Formula primitives (k1.java)
`m(d)`=16-bit byteswap; `n(d,s,mask)`=(int(d)>>s)&mask; `o(d,k)`=d+k; `p`=interp on A/B curve; `q`=interp on C/D curve; `r(d)`=d-0.2. Transform selector `M`: 0=none,1=p,2=q,3=r,4=byteswap*z, 5=o(-0.25),6=n(bitmask),12=signed16,14=signed8. o0 uses mostly M=0.

| Parameter | Request(CMD) | Header | u,v (chars) | SBI | DL | Formula | Unit | Min | Max | Confidence |
|---|---|---|---|---|---|---|---|---|---|---|
| Revs | 21CB | KWP | 24,30 | 11 | 2 | raw*5 | rpm | 0 | 7000 | derivation CONFIRMED; offset UNCERTAIN |
| Battery | 21CB | KWP | 40,36 | 17 | 1 | raw*0.5 | V | 0 | 17 | derivation CONFIRMED; offset UNCERTAIN |
| Coolant | 21CB | KWP | 56,48 | 23 | 1 | raw*5-50 | ℃ | -50 | 110 | derivation CONFIRMED; offset UNCERTAIN |
| FanSpeed | 21CB | KWP | 104,84 | 41 | 1 | raw*5 | % | 0 | 60 | derivation CONFIRMED; offset UNCERTAIN |
| AirCPress | 21CB | KWP | 184,144 | 71 | 1 | raw*0.5 | bar | 0 | 16 | derivation CONFIRMED; offset UNCERTAIN |
| Speed | 21CA | KWP | 72,60 | 29 | 1 | raw*5 | km/h | 0 | 200 | derivation CONFIRMED; offset UNCERTAIN |
| Gear | 21CA | KWP | 224,174 | 86 | 1 | (int(raw*5) >> 0) & 63 | - | 0 | 15 | derivation CONFIRMED; offset UNCERTAIN |
| FuelLevel | 21CA | KWP | 288,222 | 110 | 1 | raw*5 | l | 0 | 100 | derivation CONFIRMED; offset UNCERTAIN |
| AirManifold | 21C2 | KWP | 48,42 | 20 | 1 | raw*5-50 | ℃ | -50 | 60 | derivation CONFIRMED; offset UNCERTAIN |
| AtmosphPress | 21CB | KWP | 448,348 | 173 | 1 | raw*5+500 | mbar | 0 | 1200 | derivation CONFIRMED; offset UNCERTAIN |
| AccelPedalPos | 21CA | KWP | 112,96 | 47 | 1 | raw*0.5 | % | 0 | 100 | derivation CONFIRMED; offset UNCERTAIN |
| KnockSensor | 21CB | KWP | 352,276 | 137 | 1 | raw*0.5 | mV | 0 | 100 | derivation CONFIRMED; offset UNCERTAIN |
| Inj.1Time | 21C0 | KWP | 56,54 | 26 | 1 | raw*0.05 | ms | 0 | 10 | derivation CONFIRMED; offset UNCERTAIN |
| Inj.2Time | 21C0 | KWP | 72,66 | 32 | 1 | raw*0.05 | ms | 0 | 10 | derivation CONFIRMED; offset UNCERTAIN |
| Inj.3Time | 21C0 | KWP | 88,78 | 38 | 1 | raw*0.05 | ms | 0 | 10 | derivation CONFIRMED; offset UNCERTAIN |
| Inj.4Time | 21C0 | KWP | 104,90 | 44 | 1 | raw*0.05 | ms | 0 | 10 | derivation CONFIRMED; offset UNCERTAIN |
| Cyl.Adv | 21C1 | KWP | 80,66 | 32 | 1 | raw*5-100 | ° | -100 | 180 | derivation CONFIRMED; offset UNCERTAIN |
| Cyl.1AdvCorr | 21C1 | KWP | 128,102 | 50 | 1 | raw*5-100 | ° | -100 | 180 | derivation CONFIRMED; offset UNCERTAIN |
| Cyl.2AdvCorr | 21C1 | KWP | 136,108 | 53 | 1 | raw*5-100 | ° | -100 | 180 | derivation CONFIRMED; offset UNCERTAIN |
| Cyl.3AdvCorr | 21C1 | KWP | 144,114 | 56 | 1 | raw*5-100 | ° | -100 | 180 | derivation CONFIRMED; offset UNCERTAIN |
| Cyl.4AdvCorr | 21C1 | KWP | 152,120 | 59 | 1 | raw*5-100 | ° | -100 | 180 | derivation CONFIRMED; offset UNCERTAIN |
| UpMixCorr | 21C0 | KWP | 376,294 | 146 | 2 | raw*3.82e-05-0.25 | - | 0 | 100 | derivation CONFIRMED; offset UNCERTAIN |
| DownMixCorr | 21C0 | KWP | 408,318 | 158 | 2 | raw*3.82e-05-0.25 | - | 0 | 100 | derivation CONFIRMED; offset UNCERTAIN |
| UpO2Volt | 21C0 | KWP | 216,174 | 86 | 2 | raw*5 | mV | 0 | 1800 | derivation CONFIRMED; offset UNCERTAIN |
| DownO2Volt | 21C0 | KWP | 280,222 | 110 | 2 | raw*5 | mV | 0 | 1800 | derivation CONFIRMED; offset UNCERTAIN |
| UpO2Heat | 21C0 | KWP | 312,246 | 122 | 1 | raw*0.5 | % | 0 | 120 | derivation CONFIRMED; offset UNCERTAIN |
| DownO2Heat | 21C0 | KWP | 344,270 | 134 | 1 | raw*0.5 | % | 0 | 120 | derivation CONFIRMED; offset UNCERTAIN |
| CanisterValve | 21C0 | KWP | 464,354 | 176 | 1 | raw*5 | % | 0 | 120 | derivation CONFIRMED; offset UNCERTAIN |
| BrakePress | 21CB | KWP | 464,360 | 179 | 1 | raw*5 | mbar | 0 | 1200 | derivation CONFIRMED; offset UNCERTAIN |
| AirFlowInstr | 21C2 | KWP | 416,324 | 161 | 2 | raw*0.5 | kg/h | 0 | 500 | derivation CONFIRMED; offset UNCERTAIN |
| AirFlow | 21C2 | KWP | 96,84 | 41 | 2 | raw*0.5 | kg/h | 0 | 500 | derivation CONFIRMED; offset UNCERTAIN |
| IntakeAirPressInstr | 21C2 | KWP | 112,90 | 44 | 1 | raw*105 | mbar | 0 | 2000 | derivation CONFIRMED; offset UNCERTAIN |
| IntakeAirPress | 21C2 | KWP | 120,96 | 47 | 1 | raw*105 | mbar | 0 | 2000 | derivation CONFIRMED; offset UNCERTAIN |
| InCamDephaserInstr | 21C2 | KWP | 176,138 | 68 | 1 | raw*5-100 | ° | -100 | 100 | derivation CONFIRMED; offset UNCERTAIN |
| InCamDephaser | 21C2 | KWP | 192,150 | 74 | 1 | raw*5-100 | ° | -100 | 100 | derivation CONFIRMED; offset UNCERTAIN |
| InCamDephaserValve | 21C2 | KWP | 208,162 | 80 | 1 | raw*5 | % | 0 | 120 | derivation CONFIRMED; offset UNCERTAIN |
| ExternalTemp | 21CB | KWP | 328,252 | 125 | 1 | raw*5-40 | ℃ | -40 | 40 | derivation CONFIRMED; offset UNCERTAIN |

## Validation status

The requests this profile actually sends were confirmed in code: `MainActivity.g1()` sends each parameter's
`.f` field verbatim (`"21CB\r"`, `"21CA\r"`, `"21C0\r"`, `"21C1\r"`, `"21C2\r"`, plus `21FE`/`17FF00`). It does
**not** send `21FF02xx`.

The five captured frames provided for validation are all `21FF02xx` responses, i.e. a *different* KWP read scheme
that the `V46_21` profile does not use. Brute-forcing those frames against the code-derived scale factors and the
expected idle values produced only coincidental / ambiguous hits (several "matches" landed on the frame's leading
length byte), so they could **not** confirm the `21Cx` byte offsets. Consequently every parameter is marked
"derivation CONFIRMED; offset UNCERTAIN": the request page, scale (z), offset (D), transform (M) and unit are taken
directly from the decrypted tables and are reliable; the exact response byte index and field width could not be
cross-checked against a matching real `21Cx` capture and may need adjustment against a live `21CB/21CA/21C0/21C1/21C2`
dump from the car.
