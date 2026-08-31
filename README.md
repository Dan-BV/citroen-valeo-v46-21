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
  (read + clear, 291 descriptions) and **ECU identification** via the ОШИБКИ / ЭБУ buttons.
- **CAN OBD-II standard** — standardized mode-01 PIDs incl. torque/load, no calibration.
- **K-line KWP** — for adapters with a working K-line transceiver.

The parameter profile is generated, not hand-written: regenerate it with
`python tools/diagbox/make_profile.py --ecu-json data/diagbox/V46_21_B7.json --out
data/diagbox/v46_21_profile.js --inject index.html`, which splices it between the
`V46.21 PROFILE` markers in `index.html`.

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
