# FAP Live

Single-file browser OBD live-data tool for a Citroën/Peugeot Valeo V46.21 engine.
No dashboard — scrollable parameter list, tap a numeric parameter for a scalable live graph.

Talks to an ELM327 adapter via **Web Serial** (USB / classic-Bluetooth COM) or **Web Bluetooth** (BLE).

## Open it
- **Desktop Chrome/Edge:** open the Pages URL directly. Web Serial (COM port) + Web Bluetooth both available.
- **Android Chrome:** open the Pages URL. Web Bluetooth (BLE) works directly.
- **iPhone:** standard Safari/Chrome do **not** support Web Bluetooth. Open the Pages URL inside a
  WebBLE browser such as **Bluefy** to use a BLE adapter.

## Protocols (CFG)
- **CAN OBD-II standard** (default) — reliable standardized PIDs, no calibration.
- **CAN PSA** — proprietary V46.21 `21Cx` engine params (byte offsets still being calibrated).
- **K-line KWP** — for adapters with a working K-line transceiver.

Requires HTTPS (GitHub Pages provides it) or localhost — Web Bluetooth won't run from `file://`.
