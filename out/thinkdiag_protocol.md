# ThinkDiag Mini — protocol findings and the Phase 0 verdict

Source captures (2026-09-10, kept local — see `.gitignore`): an EOBD2 session at
09:52, and two CITROEN / V46.21 sessions at 13:01 and 13:02 covering a full
system scan plus data-stream reads on the BSI and the engine. The Bluetooth HCI
snoop of the 13:02 session covers it from the link setup onward.

## Frame format

    55aa | tag(2) | len(2) | seq(1) | cmd(1) | payload | cksum(1)

`tag` is `f0f8` phone→adapter and `f8f0` back. `len` counts `seq` through the
end of the payload, checksum excluded. A reply echoes the request's `seq` and
answers with `cmd | 0x40`. Replies to `27/01` carry the ECU's answer as a
*nested* `55aa` frame inside their payload.

## Command map

| cmd/sub | direction | meaning |
|---------|-----------|---------|
| `21/03` | out | adapter serial, firmware version, build date |
| `21/05` | out | firmware/bootloader/protocol versions, model `diagmini` |
| `21/11`, `21/17`, `21/2a`, `21/29`, `25/05` | out | further startup queries |
| `21/18` | out | 524-byte licence payload |
| `61/18` | in | 7-byte answer, 4 bytes of which vary per session |
| `27/01` | out | run a request on an established link |
| `67/01` | in | the ECU's answer, nested |

## Verdict 1 — the licence is static, so it is replayable

This was the gate the whole feature hung on.

| capture | `21/18` (524 B) | licence frame in `27/01` |
|---------|-----------------|--------------------------|
| EOBD2 09:52 | sha `ac35b649…` | 298 B, sha `9ac72b5c…` |
| CITROEN 13:01 | sha `3699 7748…` | 1626 B, sha `bab0486d…` |
| CITROEN 13:02 | sha `3699 7748…` | 1626 B, sha `bab0486d…` |

The two CITROEN sessions — separate connections minutes apart — send
**byte-identical** payloads. The blob differs between EOBD2 and CITROEN, so it
is per-diagnostic-application data, not a per-session challenge.

The adapter's 7-byte `61/18` answer does vary (`…74432e4c…`, `…91c33ea0…`,
`…4277ad81…`), which would matter if it seeded later traffic. It does not: those
bytes never appear again in anything the phone sends. Checked in both CITROEN
sessions.

**So: no cloud round-trip to reproduce.** The gate is passed.

## Verdict 2 — the adapter is dual-mode; Android chose SPP, iOS uses LE

An earlier reading of this capture said the adapter had no BLE at all. That was
wrong: it described what the *Android ThinkDiag app* chose, not what the adapter
can do. The same snoop contains the evidence, in the scan that preceded the
connection.

From the HCI snoop of the 13:02 session (11 420 packets):

- 442 LE advertising reports from `DC:0D:30:51:4E:36`, carrying a Complete Local
  Name of `9TFD20257708` and TX power, with the flags byte at `0x01` — the
  "BR/EDR not supported" bit is *not* set, i.e. dual mode.
- The session itself then ran over classic Bluetooth: L2CAP connection requests
  to PSM 1 (SDP) and PSM 3 (RFCOMM), payload on CID `0x45`, DLCI 2, UIH frames,
  the same shape as the August ELM327 capture. Zero ATT packets — because the
  Android app never opened a GATT link, not because there is none to open.

The bonded-device list agrees: the phone records it as `[ DUAL ]`.

So each platform reaches it its own way, and the iPhone reaching it over LE — as
the ThinkDiag iOS app does — is consistent with everything here.

**What is still unknown, and cannot come from an Android capture:** the GATT
service and characteristic pair the LE link uses, and whether the `55aa`
framing over GATT is chunked differently than over RFCOMM. Resolve it by
powering the adapter within range and running

    python tools/ble/enumerate.py 9TFD

## The GATT layout, measured on the iPhone (2026-09-10)

Read with nRF Connect for Mobile against `9TFD20257708`.

| | |
|---|---|
| service | `49535343-FE7D-4AE5-8FA9-9FAFD205E455` (primary) |
| notify | `49535343-1E4D-4BD9-BA61-23C647249616`, with a CCCD |
| write | `49535343-8841-43F4-A8D4-ECBE34729BB3`, Write + Write Without Response |

Also present: Generic Access (1800), Generic Attribute (1801), and Device
Information (180A) exposing Serial Number, Software Revision, Hardware
Revision, Manufacturer Name and Model Number strings.

**Advertised services: none.** The adapter advertises only its name, so a client
has to connect first and then discover — which is what our `AdapterScanner`
already does, scanning with `withServices: nil`.

`49535343` is ASCII `ISSC`: this is the Microchip/ISSC **transparent UART**
service, the generic BLE-to-serial bridge profile. That is good news for us —
one notify characteristic, one write characteristic, no vendor framing of its
own. `BleTransport` discovers its pair generically rather than from a hardcoded
list, so it should bring this link up unchanged.

Confirmed on the car: our app lists the adapter at -50 dBm and connects, and
then every ELM command times out — `ATZ` at its full 2500 ms, `ATD`, `ATE0`,
`ATL0`, `ATH0`, `ATS0`, `ATAL`, `ATI` at 800 ms each, all with no reply. Exactly
the expected split: **the transport works, the protocol does not.** So the
remaining work on the adapter is the `55aa` protocol, not the link.

## Verdict 3 — a new blocker: no CAN addressing on the wire

`27/01` is not "send this request on CAN id X". Its payload is

    64 00 01 ff | len(2) | 61 01 | n | link(2) | reqlen | request

where `link` is a two-byte handle. Neither `6A8` nor `688` appears anywhere in
the phone→adapter stream, in any byte order or width, and neither do `752`,
`652`, `6D4`, `674`, `7E0` or `7E8`. The CAN identifiers live inside the
adapter's downloaded vehicle software; the phone only names a handle.

Handles seen in the 13:02 session, by the requests they carried:

| link | requests | module |
|------|----------|--------|
| `2905` | `21C0/C1/C2/C3/C4/CA/CB 8001`, `21B0 8001`, `2180`, `21FE`, `81`, `82` | engine, V46.21 |
| `2a25` | `22DAxx`, `22DDxx`, `22D4xx`, `22E7FF`, `2221xx`, `22F080`, `22F190`, `10C0` | BSI |
| ~35 others | `1003` + `22F0xx` + `1902` + `1001` | the system scan, one handle each |

So driving this adapter means reproducing the link-setup sequence the app
performs before it can address the engine at all — replay tied to a particular
vehicle-software version, not a stable primitive. No raw-CAN command appears in
this capture.

## What is worth keeping regardless

The capture is a reference dialogue from the official tool, and two parts of it
are useful to the app whether or not we ever drive this adapter.

**Engine.** ThinkDiag polls exactly the pages the profile already has — B0, C0,
C1, C2, C3, C4, CA, CB — with the `21xx8001` request form, confirming the form
the FAP calibration settled on. Nothing new to add.

**BSI.** This is new territory: the profile is engine-only. A full DID sweep on
handle `2a25`, with substantial answers:

| request | reply bytes |
|---------|-------------|
| `22E7FF` | 493 |
| `222104` | 411 |
| `22D40D` | 191 |
| `22D40F` | 181 |
| `22D413` | 169 |
| `22D405` | 133 |
| `22D417` | 111 |
| `22D419`, `22D401`, `22D407`, `22D41B`, `22D4xx` … | 8–175 |
| `22F080`, `22F190`, `2201`, `2221` | 22–27 |
| `22DAxx`, `22DDxx`, `22D87x`, `22DB8D` | 5–8 |

**DTCs.** The scan uses UDS `19 02 09` — ReadDTCInformation by status mask —
against every module, after `1003`. The app reads faults differently; this is
the official sweep for comparison.
