# Citroën Valeo V46.21

Single-file browser OBD live-data tool for a Citroën/Peugeot Valeo V46.21 engine.
No dashboard — scrollable parameter list, tap a numeric parameter for a scalable live graph.

Talks to an ELM327 adapter via **Web Serial** (USB / classic-Bluetooth COM) or **Web Bluetooth** (BLE).

## Open it
- **Desktop Chrome/Edge:** open the Pages URL directly. Web Serial (COM port) + Web Bluetooth both available.
- **Android Chrome:** open the Pages URL. Web Bluetooth (BLE) works directly.
- **iPhone:** standard Safari/Chrome do **not** support Web Bluetooth. Open the Pages URL inside a
  WebBLE browser such as **Bluefy** to use a BLE adapter.

## Protocols (CFG)
- **CAN PSA** (default) — 118 ECU parameters across 10 read pages, taken straight from the
  official Diagbox databases (byte offsets, scaling, units and text states are the ECU's own
  definitions), plus a few standard OBD readings the proprietary pages lack (oil temp, fuel
  rate, run time, absolute load) — the poll loop switches header 6A8↔7E0. Also **fault codes**
  (read + clear, 291 descriptions), **ECU identification** and a **whole-car module scan** via
  the ОШИБКИ / ЭБУ / СКАН buttons.
- **CAN OBD-II standard** — standardized mode-01 PIDs incl. torque/load, no calibration.
- **K-line KWP** — for adapters with a working K-line transceiver.

**СКАН** walks the 41 diagnostic CAN addresses of the platform, opens a session on each
(KWP `81`/`2180` and UDS `1001`/`22F080` are both handled), and reads the fault memory of
whatever answers — `17 FF 00` for KWP modules, `19 02 09` for UDS ones. Several ECUs share
one address; where the recognition frame cannot tell them apart the result lists every
candidate rather than picking one. Live values freeze while it runs (~1 minute).

Both embedded profiles are generated, not hand-written; regenerate with:
```
python tools/diagbox/make_profile.py --ecu-json data/diagbox/V46_21_B7.json     --out data/diagbox/v46_21_profile.js --inject index.html
python tools/diagbox/make_scan.py --vehicle-json data/diagbox/vehicle_B7.json     --out data/diagbox/scan_B7.js --inject index.html
```
They splice themselves between the `V46.21 PROFILE` and `SCAN PROFILE` markers in
`index.html`.

Requires HTTPS (GitHub Pages provides it) or localhost — Web Bluetooth won't run from `file://`.

## Reference data from Diagbox
The official Diagbox 9.85 databases were mined for this ECU, so the byte maps no
longer have to be guessed. Every frame below is what the official tool sends.

- `out/diagbox_v46_21_reference.md` — the main reference: session sequence, all
  13 services, the 10 live measurement pages with per-byte scaling and enums,
  identification, fault handling, freeze frames, 16 actuator tests, 14 learned-value
  resets, security access and the full telecoding read/write layout.
- `out/diagbox_v46_21_dtc.md` — all 291 fault codes for this ECU.
- `out/diagbox_b7_ecu_map.md` — every module on the B7 platform with its CAN ids
  and its init/recognition frames, i.e. a complete scan list.
- `out/diagbox_extraction_method.md` — how the databases and the `.DU8` string
  dictionaries were decoded, so this can be repeated for any other ECU.
- `data/diagbox/*.json` — the machine-readable form, labels in English and Russian.
- `tools/diagbox/` — the extraction pipeline plus `decode.py`, which replays a
  recorded transcript through the map (this is how it was verified).

## Car Scanner profile
`out/custompids_v46_21_diagbox.csp` — 86 custom PIDs for Car Scanner, generated from
the same extraction by `tools/diagbox/make_csp.py`. It holds **only what standard
OBD-II does not already give on this ECU**: the ten parameters covered by supported
mode-01 PIDs (RPM 010C, coolant 0105, IAT 010F, voltage 0142, speed 010D, both O2
voltages 0114/0115, throttle 0111, timing 010E, MAP 010B) are deliberately left out.

Notes:
- Each entry carries the session opener in its "before command" field
  (`ATCRA688;ATFCSH6A8;ATFCSD300000;ATFCSM1;81`) — without the `81` the ECU answers
  nothing to a `21xx` read.
- Requests use the bare `21Cx` form, whose answer is `61 Cx …`. Car Scanner strips
  those two bytes, so payload byte 1 is `A` in the formulas.
- Pages `$C3` and `$DB` are omitted: this ECU does not answer them. `$CF` (the dealer
  service stamp) is omitted too — its date/mileage encoding is not established.
- `RAPPORT_ENGAGE` and `TYPE_BOITE_VITESSES` share one byte through bit masks and are
  omitted, since Car Scanner's support for mask expressions varies by version.
- Every numeric formula was checked against `tools/diagbox/decode.py` on the recorded
  drive: 51 of 51 comparable values match. The rest are enumerations, where the tile
  shows the raw number and the legend sits in the long name.
- Car Scanner sends one request per PID, unlike this app which reads a whole page and
  splits it — so a dashboard packed with these will poll noticeably slower.

## Project layout & workflow
This repo is the single project root (moved here 2026-08-28).
- `index.html` — the app itself. **Edit it directly; `git push` deploys it** (GitHub Pages serves it).
- `tools/btsnoop/` — reverse-engineering toolkit: `parse_btsnoop.py` (btsnoop→ELM transcript),
  `calibrate.py` (align transcript+FAP CSV → verify/discover offsets), `gen_csp.py` / `gen_csp_obd.py`
  (emit Car Scanner `.csp`), and its own `README.md`. `data/` holds the reproducible captures.
- `tools/diagbox/` — Diagbox database extraction (see above).
- `out/` — calibration docs (`*.md`) and Car Scanner profiles (`*.csp`).
- `tools/platform-tools/` — adb (git-ignored). Needed to pull a new drive's btsnoop via `adb bugreport`.

Not tracked (see `.gitignore`): adb binaries, decompiled FAP source, full Android bugreport zips.
