# FAP Live — modern UI (V46.21)

A clean re-implementation of the FAP diagnostic app's **core** (ELM327 + Valeo V46.21
K-line KWP protocol, decrypted from the original APK) with a **new interface**:

- **No fixed dashboard.** Every parameter is shown in one **scrollable list** with its live value.
- **Tap a numeric parameter → a scalable live graph** (pinch-to-zoom on both axes, drag to pan,
  double-tap to reset to auto-follow).
- **Boolean indicators** (`BR` brake pedal, `CL` clutch pedal) show a coloured **ON/OFF** state and
  are *not* tappable to a graph.
- **Background CSV logging** (toggle `LOG`), written to the app's external files dir.

## Where the "core" came from

Nothing here is guessed — it is transcribed from the reverse-engineering already in `../out/`:

| New file | Source of truth |
|---|---|
| `core/ParamDef.kt` (V46.21 table) | `fap_src/.../o0.java` + `out/v46_21_params.md` |
| `core/ElmSession.kt` (connect + poll) | `out/fap_session_sequence.md` |

Connect sequence (K-line, ISO 14230-4 KWP): `ATZ ATD ATE0 ATL0 ATH0 ATS0 ATAL`, then
`ATSP5`(fast) / `ATSP4`(5-baud), `ATSH8110F1`, `ATFI`, `ATSW00`, then `81`→`C1`,
`1003`/`10C0`/`10A4`→`50`, keep-alive `3E`/`3E00`, live reads `21CB 21CA 21C0 21C1 21C2`.

## Build & run

**Recommended: Android Studio** (Hedgehog or newer, JDK 17).

1. `File → Open…` → select this `fap_modern` folder.
2. Let Studio sync Gradle (it will download AGP 8.5.2 / Gradle 8.7 and the AndroidX deps).
   If prompted about a missing Gradle wrapper, accept — Studio generates it.
3. Plug in an Android phone (USB debugging on) and press **Run**.

The project intentionally has **zero third-party chart library** — the graph is a self-contained
`ScalableChartView` (Canvas) so it builds offline once the standard AndroidX/Material artifacts
are cached.

## Using it

1. `CFG` → pick **Bluetooth** (choose your paired ELM327) or **WiFi** (host/port, default
   `192.168.0.10:35000`). On Android 12+ grant the Bluetooth permission when asked.
2. `Connect`. Turn ignition on. Status shows the negotiated session.
3. Scroll the list; tap any numeric row to open its live graph.

## Important caveats (carried over from the reverse engineering)

- **Byte offsets are "derivation CONFIRMED; offset UNCERTAIN"** (see `out/v46_21_params.md`).
  Scale/offset/unit are reliable; the exact response byte index could not be cross-checked against
  a live `21Cx` capture. If a value reads wrong, use `CFG → Frame byte shift` to nudge **all**
  offsets at once, or edit the per-parameter `sbi` in `ParamDef.kt`.
- **K-line init is timing-sensitive.** Genuine ELM327 v1.4+ / STN adapters do it reliably; many
  cheap "v1.5" clones have weak K-line transceivers and fail ISO 14230 init. Try `CFG → KWP init
  mode` = 5-baud if fast init fails.
- **`BR` / `CL` bit position is uncertain** — currently treated as "byte ≠ 0". Adjust in
  `ParamDef.kt` if needed.

## Structure

```
core/  ParamDef.kt        V46.21 parameter table + value formula
       Sample.kt          live sample + history point
       ResponseParser.kt  "61<page>" alignment + field extraction
       ElmTransport.kt    Bluetooth SPP + WiFi TCP pipes
       ElmSession.kt      connect sequence, poll loop, history, keep-alive
       CsvLogger.kt       background CSV recorder
       AppState.kt        singleton session + persisted settings
ui/    MainActivity.kt    scrollable parameter list + connect/log/cfg
       ParamAdapter.kt    list row binding (numeric vs boolean)
       GraphActivity.kt   hosts the live graph for one parameter
       ScalableChartView.kt  pinch-zoom / pan time-series chart (no deps)
```
