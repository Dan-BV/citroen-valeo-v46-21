# Citroën Valeo V46.21

Single-file browser OBD live-data tool for a Citroën/Peugeot Valeo V46.21 engine.
No dashboard — scrollable parameter list, tap a numeric parameter for a scalable live graph.

Talks to an ELM327 adapter via **Web Serial** (USB / classic-Bluetooth COM) or **Web Bluetooth** (BLE).

## Open it
- **Desktop Chrome/Edge:** open the Pages URL directly. Web Serial (COM port) + Web Bluetooth both available.
- **Android Chrome:** open the Pages URL. Web Bluetooth (BLE) works directly.
- **iPhone:** standard Safari/Chrome do **not** support Web Bluetooth. Use the native app in
  `ios/` (see below), or open the Pages URL inside a WebBLE browser such as **Bluefy**.

## iOS app
`ios/` is a native SwiftUI app for the same ECU, because Safari on iOS has neither Web
Bluetooth nor Web Serial. **It is the product**; the web page and the Android app below are
mothballed as of 2026-09-10 and no longer developed. It bundles the generated
`data/profile/v46_21_profile.json` - referenced in place from `ios/project.yml`, never
copied - so the byte maps cannot drift from what the generator emits. Classic Bluetooth SPP and K-line are absent by design:
an iPhone can only reach an ELM327 clone over BLE.

### Two screens, one set of keys
The app reads the ECU on two screens: **dashboards** - hand-arranged tiles, a number, a
gauge, a bar or a minute of a curve each, swiped between and kept in `UserDefaults` - and
the **parameter list**, every reading the profile knows, grouped by the page it comes from.
The title switches between them and manages the boards.

Neither screen reads anything of its own. The dashboards hand the session a *set* of keys,
the list contributes its ticks, and the union is the one thing the poll loop and the CSV
recorder go by (`ElmSession.polled`). So a parameter shown in the list and on three tiles is
one request on the wire, one entry in memory and **one column** in the drive log: the log's
columns are built by walking the profile, which names each key exactly once
(`ElmSession.logKeys`). The recording format is unchanged - `time_ms,iso,<keys>`, the same
file `data/logs/README.md` describes.

Two consequences worth knowing at the wheel. A page nothing is ticked from is still read if
a tile shows it, so the list marks such a page rather than letting the switch look broken;
and the column set is frozen when the recording opens, so a tile added mid-drive is shown
but not written - the tile says so with an orange mark. "Читать только дашборды" in the
title menu drops the list to exactly what the tiles need, which is the one lever that
actually shortens a cycle: fewer pages.

### Faults, on every module of the car
"Ошибки" is not the engine's fault memory any more: it walks the 41 diagnostic CAN addresses
of the platform and gives every module that answers a node of its own, with its fault list
underneath. Three ways to clear, because three are useful - the whole car at once, one
module, or a single fault opened from the list.

The address map is `data/profile/scan_B7.json` (`tools/diagbox/make_scan.py`): per module,
the CAN pair, the frame that opens a session, the frame that identifies it, and the frames
that read and clear its faults - `17 FF 00` / `14 FF 00` on a KWP module, `19 02 09` /
`14 FF FF FF` on a UDS one. Several ECUs share one address and only the identification bytes
tell them apart, so such an address reports every candidate rather than picking one; the
engine is the exception, since the loaded profile already names it.

What the codes mean is `data/profile/dtc_B7.json` (`tools/diagbox/make_dtc.py`): 15 103
codes over 74 ECUs, plus the per-code failure-type byte that turns `$8001` into
"$8001-11, short to ground" and the module names Diagbox itself shows. It is 0.7 MB - more
than the rest of the app - so it is read off the main thread on the first sweep, and nothing
depends on it: a code it cannot name is still read, shown and cleared.

Two things the screen will tell you rather than hide. A UDS status byte is the ISO 14229 bit
field and PSA asks for mask `09`, so a fault is marked present, stored, or awaiting
confirmation; a KWP status byte has no published meaning and is shown raw instead of being
given one. And a ThinkDiag reaches only the modules whose handles its capture proved - no CAN
identifier crosses that wire - so with one connected the sweep says which addresses the
adapter cannot speak to rather than reporting the whole car as silent.

Clearing one fault is the same service with the fault itself as the group of DTC instead of
the "everything" group. Not every ECU accepts that; one that does not answers `7F 14 31`,
and the refusal is passed on as it came.

The first sweep is the slow one. The map is the whole platform and a given car answers on a
fraction of it, the rest being paid for one adapter timeout at a time - so what answered is
written down, and every sweep after it walks that list instead: seconds rather than a minute,
and only the candidate that answered rather than all of an address's. "Полный обход" walks
the platform again and rewrites the map, which is what a car that has gained or lost a module
needs; a short sweep never rewrites it, or one module that failed to answer once would erase
itself for good. Neither does a sweep the adapter could not carry out: with a ThinkDiag
connected only the engine is reachable, and a map made from that would tell every later
sweep - on any adapter - that this car has one module. The sweep can also be shared as a page of text - every module, its
identification bytes and its faults - which is the right grain for reading away from the car;
the technical log has the individual exchanges.

No Apple Developer account is involved:

- `.github/workflows/ios.yml` builds an **unsigned** ipa on a macOS runner and publishes it,
  together with an AltStore/SideStore source manifest, to the rolling `ios-latest`
  prerelease. The `.xcodeproj` is generated by XcodeGen on the runner - only
  `ios/project.yml` is checked in, since this project is edited on a machine without Xcode.
- **SideStore** on the phone signs the ipa with the user's own free Apple ID and re-signs it
  every 7 days by itself.
- Adding the source manifest to SideStore turns every build into a one-tap update:
  `https://github.com/Dan-BV/citroen-valeo-v46-21/releases/download/ios-latest/source.json`

Windows prerequisite for the one-time SideStore setup (iLoader needs Apple's USB driver):
install the current classic iTunes from `https://www.apple.com/itunes/download/win64`. The
build linked from `support.apple.com/en-us/106372` is iTunes 12.10.11 from 2020, whose
driver Windows 11 silently rejects - the service installs, `usbaapl64.sys` does not, and the
iPhone stays visible only as a camera with no trust prompt.

## Parity between the versions
The same byte maps exist three times - in `index.html`, in the Android app and in the iOS
app - so `data/parity/golden.json` holds real frames recorded off the car together with the
values they must decode to. The expected values come from the **raw** Diagbox database, not
from the generated profile, so the fixture checks `tools/diagbox/make_profile.py` as well: a
wrong offset or factor fails a build instead of showing up as a wrong number in a moving
car.

```
python tools/parity/make_golden.py --every 25
```

613 frames over the five pages the recording covers (C0 C1 C2 CA CB), 89 fields each. The
iOS test target replays them on every push; the generator itself refuses to write a fixture
when the profile and the database disagree, unless the difference is listed in
`tools/parity/deviations.json` - which currently holds exactly one entry, three CA fields
the database prints as hex bytes and the generator emits as plain numbers.

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

Both embedded profiles are generated, not hand-written. **The copies inside `index.html`
are frozen** at the profile of 2026-09-10 (102 live parameters): this page is mothballed,
and regeneration no longer injects into it, so the two do not have to be kept in step. The
command that feeds the iOS app is

```
python tools/diagbox/make_profile.py --ecu-json data/diagbox/V46_21_B7.json     --out data/diagbox/v46_21_profile.js --json-out data/profile/v46_21_profile.json
```

Add `--inject index.html` to bring the page back in step, and it splices itself between the
`V46.21 PROFILE` and `SCAN PROFILE` markers there.

Requires HTTPS (GitHub Pages provides it) or localhost — Web Bluetooth won't run from `file://`.

## Reference data from Diagbox
The official Diagbox 9.85 databases were mined for this ECU, so the byte maps no
longer have to be guessed. Every frame below is what the official tool sends.

- `out/diagbox_v46_21_reference.md` — the main reference: session sequence, all
  13 services, the 10 live measurement pages with per-byte scaling and enums,
  identification, fault handling, freeze frames, 16 actuator tests, 14 learned-value
  resets, security access and the full telecoding read/write layout.
- `out/diagbox_v46_21_dtc.md` — all 291 fault codes for this ECU.
- `data/profile/dtc_B7.json` — the same, for all 74 ECUs of the platform: 15 103 codes
  with their descriptions, the per-code failure-type bytes and the module names, as the
  iOS fault screen reads them (`tools/diagbox/make_dtc.py`).
- `out/diagbox_b7_ecu_map.md` — every module on the B7 platform with its CAN ids
  and its init/recognition frames, i.e. a complete scan list.
- `out/diagbox_extraction_method.md` — how the databases and the `.DU8` string
  dictionaries were decoded, so this can be repeated for any other ECU.
- `data/diagbox/*.json` — the machine-readable form, labels in English and Russian.
- `tools/diagbox/` — the extraction pipeline plus `decode.py`, which replays a
  recorded transcript through the map (this is how it was verified).

## Car Scanner profiles
Two files, both generated by `tools/diagbox/make_csp.py`, both holding **only what
standard OBD-II does not already give on this ECU** (the ten parameters covered by
supported mode-01 PIDs — RPM 010C, coolant 0105, IAT 010F, voltage 0142, speed 010D,
both O2 voltages 0114/0115, throttle 0111, timing 010E, MAP 010B — are left out):

- **`out/custompids_v46_21_core.csp` — 32 PIDs, the one to import.** A working
  diagnostic set: mixture and oxygen sensors, canister, ignition and knock, air flow
  and throttle tracks, the inlet cam phaser, torque, sensor supplies, oil pressure,
  brake-booster vacuum.
- `out/custompids_v46_21_diagbox.csp` — all 85, for when something specific is needed.

The core set was chosen from the recorded drive, not by taste. Left out of it:
- pages `$C3` and `$DB`, which this ECU never answers;
- `ETAT_COMMANDE_POMPE_VIDE_ELECTRIQUE`, which reads `FF` (no data) in every sample —
  no electric vacuum pump fitted;
- parameters that were byte-identical to another one in every single sample: this ECU
  reports the same value for all four injection times, for both mixture corrections,
  for optimal and maximum advance, for commanded and measured throttle angle, and for
  air torque and driver-demand torque. Only one of each pair is kept.

Start with `out/custompids_v46_21_test.csp` (3 PIDs, one per page) to prove the
transport before importing a whole dashboard's worth.

Notes:
- Each entry's "before command" field is just **`81`**, which opens the KWP session —
  without it the ECU answers nothing to a `21xx` read.
- **Nothing else is set, deliberately: adapter state is sticky.** `ATCRA688` kept
  filtering out the 7E8 replies of every standard PID that followed. `ATFCSH6A8` plus
  `ATFCSM1` are worse — they make the adapter answer a multi-frame reply from 7E8 with
  a flow-control frame addressed to 6A8, so the ECU never receives it and every cycle
  stalls on a timeout. A dashboard mixing custom and standard PIDs freezes outright.
  Undoing it in the after-command was not enough. Automatic flow control derives the
  frame from the current request header, which is what we want anyway.
- `out/custompids_v46_21_test_fc.csp` is the same three PIDs *with* explicit flow
  control, kept only to compare against on an adapter that needs it.
- Car Scanner sends one request per PID, and each of these costs two bus transactions
  (`81` then the page read). A dashboard of 5-8 of them polls comfortably; thirty do
  not. If you want them faster, move `81` into the adapter's own init commands so it
  runs once per connection instead of once per PID — at the cost of values going blank
  if the ECU's session ever times out.
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

## Android app
`android/` is a native client with the same feature set as the web page, and one
thing the web page cannot have: **classic Bluetooth SPP**. Android Chrome's Web
Bluetooth speaks BLE only, so the working RFCOMM adapter is unreachable from the
browser on a phone. Both transports are supported here.

**Mothballed 2026-09-10**, along with the web page: the iOS app is the product and this
client is frozen where it stands. `.github/workflows/android.yml` no longer runs on push -
a red build nobody intends to fix only costs attention - but it is kept and can still be
started by hand.

Reviving it needs two small things, because the generated profile moved out of the app's
assets to `data/profile/v46_21_profile.json`: point `Profile.fromAssets` and the two paths
in `ParityTest.kt` at the new location (or copy the file back into `assets/`), and restore
the workflow's push trigger.

There is no JDK or Android SDK on the development machine, so CI was the compiler: a run
builds a debug APK and attaches it. Download it from the run's Artifacts section
(`gh run download <id> -n apk`) and sideload it.

`ФИЛЬТР` picks what is polled, shown and logged. What a cycle costs is
**requests, not parameters**: the loop pays one adapter turnaround per page and
nothing for the parameters inside it, so the presets are built page-first and a
page worth logging but not worth logging often gets a period instead of being
dropped. **БАЗОВЫЙ** - what a fresh install starts on - is 40 parameters:
`$C0` mixture, `$C1` ignition, `$C2` intake and `$CA` driving every cycle, `$C4`
torque every second cycle, `$CB` environment every tenth, and `$B0`
(immobilizer) and `$CF` (the ZAPV service record) never, both being static. It
keeps every request/actual pair and every per-cylinder signal, and drops the
duplicate channels, the unconfirmed per-cylinder advance, oil pressure (a
threshold switch, which the oil light already reports) and knock-sensor noise
(the four knock retards on `$C1` report its outcome at full rate). The list and
the periods are in `core/BaseSet.kt`; **ВСЕ** still gives all 107.

Cycle time is otherwise the adapter's, not the car's: after a reply is assembled
the ELM sits waiting in case a second module answers, which nothing can here
(`ATCRA688` filters to this ECU). `ATAT2` plus `ATST19` (100 ms cap, against a
200 ms default) cut that wait; a page's own cost is on its heading dialog next
to the raw reply. If a page starts answering NO DATA, raise `POLL_ST` in
`ElmSession.kt` before suspecting the ECU.

Not carried over: K-line, the init-mode picker and the byte-shift nudge. This ECU is
reached over CAN, neither adapter has a working K-line transceiver, and byte offsets
now come from the databases instead of being tuned by hand.

## Project layout & workflow
This repo is the single project root (moved here 2026-08-28).
- `index.html` — the app itself. **Edit it directly; `git push` deploys it** (GitHub Pages serves it).
- `tools/btsnoop/` — reverse-engineering toolkit: `parse_btsnoop.py` (btsnoop→ELM transcript),
  `calibrate.py` (align transcript+FAP CSV → verify/discover offsets), `gen_csp.py` / `gen_csp_obd.py`
  (emit Car Scanner `.csp`), and its own `README.md`. `data/` holds the reproducible captures.
- `tools/diagbox/` — Diagbox database extraction (see above).
- `android/` — the native Android client, built by GitHub Actions.
- `out/` — calibration docs (`*.md`) and Car Scanner profiles (`*.csp`).
- `tools/platform-tools/` — adb (git-ignored). Needed to pull a new drive's btsnoop via `adb bugreport`.

Not tracked (see `.gitignore`): adb binaries, decompiled FAP source, full Android bugreport zips.
