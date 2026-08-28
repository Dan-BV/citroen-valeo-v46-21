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
- **CAN PSA** (default) — 33 calibrated proprietary V46.21 params (FAP request form `21CX8001`),
  plus standard OBD load/oil-temp/fuel-rate/run-time merged in (poll loop switches header 6A8↔7E0).
- **CAN OBD-II standard** — standardized mode-01 PIDs incl. torque/load, no calibration.
- **K-line KWP** — for adapters with a working K-line transceiver.

Requires HTTPS (GitHub Pages provides it) or localhost — Web Bluetooth won't run from `file://`.

## Project layout & workflow
This repo is the single project root (moved here 2026-08-28).
- `index.html` — the app itself. **Edit it directly; `git push` deploys it** (GitHub Pages serves it).
- `tools/btsnoop/` — reverse-engineering toolkit: `parse_btsnoop.py` (btsnoop→ELM transcript),
  `calibrate.py` (align transcript+FAP CSV → verify/discover offsets), `gen_csp.py` / `gen_csp_obd.py`
  (emit Car Scanner `.csp`), and its own `README.md`. `data/` holds the reproducible captures.
- `out/` — calibration docs (`*.md`) and Car Scanner profiles (`*.csp`).
- `tools/platform-tools/` — adb (git-ignored). Needed to pull a new drive's btsnoop via `adb bugreport`.

Not tracked (see `.gitignore`): adb binaries, decompiled FAP source, full Android bugreport zips.
