# btsnoop calibration toolkit

Reverse-engineer the Citroën/Valeo **V46.21** proprietary parameters by sniffing the
**FAP Android app's own Bluetooth traffic** and its CSV export, then solving each
parameter's byte offset + formula by regression. This is how 30/39 params were
calibrated on 2026-08-27 — full results in [`../../out/fap_calib_from_btsnoop.md`](../../out/fap_calib_from_btsnoop.md).

## Why this works
The FAP app talks to a classic **SPP ELM327** over Bluetooth. Android's HCI snoop log
captures the whole ELM dialog (below link encryption), so we recover FAP's exact
requests (`21CX8001`) and raw responses (`61 FF 04 …`). The FAP CSV gives the *decoded*
value of every parameter with timestamps. Aligning the two and regressing solves the
mapping — no guessing from decompilation.

## Capture a session (phone at the car)
Prereqs: phone with USB-debugging on; `adb` (bundled at `../platform-tools/adb.exe`).

1. Phone → Developer options → **Enable Bluetooth HCI snoop log = Full** (not Filtered).
   On this Redmi (MediaTek) it writes `BT_HCI_*.cfa.curf`, which is **standard btsnoop inside**.
2. At the car: toggle Bluetooth off→on (starts a clean log file).
3. Connect the **FAP app** to the car via a classic SPP ELM327, start FAP's **CSV recording**
   (keep the timestamp column and **Revs** — used to auto-align clocks).
4. Drive the protocol for whatever you want to calibrate:
   - idle + revs → base signals
   - **A/C on** → FanSpeed, refrigerant pressure
   - **brake presses** → BrakePress (vacuum)
   - **load / gear changes** → per-cylinder advance corrections
5. **DO NOT toggle Bluetooth after the drive.** On this MediaTek/MIUI phone the snoop is
   ONE rotating file — turning BT off→on (or reconnecting) creates a new file and **deletes
   the drive's log**. (Lost the 2026-08-28 drive this way.) Leave BT on and connected.
6. Phone → PC over USB, run the bugreport **immediately, with BT still on**:
   ```
   adb bugreport fap_session.zip
   ```
   The snoop is inside at `FS/data/misc/bluetooth/logs/BT_HCI_*.cfa.curf` — verify it is
   multi-MB (a 32 KB file = the drive log was already rotated out; recapture).

## Analyze
```bash
# 1) bugreport zip (or a raw .curf) -> ELM transcript
python parse_btsnoop.py fap_session.zip transcript.json

# 2a) verify the known calibration reproduces a CSV
python calibrate.py transcript.json fap_export.csv verify

# 2b) discover offsets for still-unknown params on a NEW targeted drive
python calibrate.py transcript.json fap_export.csv discover
```
`calibrate.py` needs numpy (`python -m pip install numpy`).

## Reproduce the 2026-08-27 result
```bash
python parse_btsnoop.py data/btsnoop_2026-08-27.curf /tmp/t.json
python calibrate.py data/transcript_2026-08-27.json data/fap_export_2026-08-27.csv verify
```

## Key facts (don't relearn these)
- **FAP requests pages as `21CA8001 21C08001 21CB8001 21C18001 21C28001`** (NOT plain `21CB`).
  Response prefix is constant `61 FF` (byte0=0x61, byte1=0xFF); byte2+ is data (byte2/3 = RPM).
  Offsets in the calib table are indexed from byte0 and are valid ONLY for the `21CX8001` form.
- Page response lengths: 21CA=0x2B, 21C0=0x48, 21CB=0x3B, 21C1=0x20, 21C2=0x48.
- Init (FAP): `ATZ ATWS ATD ATE0 ATL0 ATH0 ATS0 ATAL ATV0 ATSP6 ATSH6A8 ATCRA688
  ATFCSH6A8 ATFCSD300000 ATFCSM1` then `81`; one `81` sufficed for a 96-min session.
- Transport = RFCOMM/SPP, DLCI 2, UIH frames, 2-byte length. (A BLE/ATT adapter would
  need a different link-layer parser — not implemented.)
- btsnoop timestamp == phone local wall clock; `calibrate.py` still auto-fits a small
  offset via RPM correlation (was +0.38 s on 2026-08-27).

## Files
- `parse_btsnoop.py` — btsnoop/bugreport → `transcript.json`
- `calibrate.py` — transcript + FAP CSV → verify/discover calibration (holds `KNOWN_CALIB`)
- `data/` — the 2026-08-27 source capture (curf), transcript, and FAP CSV for reproduction
- App integration lives in `../../fap_web/fap_live.html` (PARAMS table, protocol "CAN PSA").
