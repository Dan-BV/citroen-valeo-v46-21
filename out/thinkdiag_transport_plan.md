# ThinkDiag as a second adapter protocol — plan

Goal: let the app talk to a ThinkDiag Mini alongside the ELM327 adapters, and
let the user pick which kind of adapter to use from the settings.

## Why this is not a drop-in

ThinkDiag does not speak ELM327. It speaks Launch's own binary framing, and the
app's whole transport layer is built around ELM text ending in a `>` prompt.

Frame layout, from the 2026-09-10 capture:

    55aa | tag(2) | len(2) | seq(1) | cmd(1) | payload | cksum(1)

`tag` is `f0f8` phone→adapter and `f8f0` back; a reply echoes the request's
`seq` and answers with `cmd | 0x40`.

What is already decoded (`tools/btsnoop/data/2026-09-10_0952_thinkdiag_eobd2.log`,
a 2-minute EOBD2 session — 492 request/reply pairs):

| cmd | sub | meaning |
|-----|-----|---------|
| `21` | `03` | adapter serial, firmware version, build date |
| `21` | `05` | firmware/bootloader/protocol versions, model `diagmini` |
| `27` | `01` | **generic pass-through** — protocol descriptor + the request verbatim |
| `21` | `18` | ~527 bytes, high entropy — licence/activation |
| `27` | `01` | one frame of 250+ high-entropy bytes ending in ASCII `Launch_Limited_ED` |

The pass-through is the good news: `02 01 14` went out untouched and came back
as `41 14 88 88`, so an arbitrary request such as `21CB8001` would go through
the same way. The licence frames are the risk.

## Phase 0 — the gate

**No app code until this is answered.** The whole feature depends on whether the
licence exchange can be reproduced without Launch's servers.

1. Capture a **CITROEN / V46.21** session with `tools/btsnoop/pull_btsnoop.ps1`
   (toggle Bluetooth off→on first, and pull before the phone reboots — the BT
   stack keeps only one snoop file and loses it on restart).
2. Diff the `21/18` blob and the `Launch_Limited_ED` frame against 2026-09-10:
   - **byte-identical** → static token, replayable, continue to Phase 1;
   - **different** → per-session challenge against Launch's cloud. Stop, and
     record the finding — that outcome kills the feature, and knowing why is
     worth more than a half-built transport.
3. Two more answers come free from the same capture:
   - the protocol descriptor for CAN `6A8`/`688` (today's is EOBD2-shaped);
   - whether the app reaches the adapter over classic RFCOMM/SPP or BLE GATT,
     which decides platform reach (see below).

Deliverable: `out/thinkdiag_protocol.md` — command reference plus the verdict.

## Phase 1 — raise the seam

The current abstraction is ELM-shaped and sits one level too low: `ElmTransport`
is a byte pipe and the reads end on a `>` prompt. ThinkDiag replaces both the
transport *and* the command layer, so the seam has to become "send this request,
get these bytes back".

- **iOS** — cheapest. `actor Adapter` (`ios/Sources/ElmSession.swift:706`)
  already exposes `send(command:_:)`, `lastStats` and `lastMs`, and `ElmSession`
  uses nothing else. Make `Adapter` a protocol; today's body becomes
  `ElmAdapter`.
- **Web** — nearly free. `ElmSerial` and `ElmBle` already share `cmd()`/`close()`
  and are picked in one line (`index.html:512`). A third class with the same
  interface slots in.
- **Android** — largest change. `ElmSession` holds an `ElmTransport` directly and
  frames inline (`ElmSession.kt:132`); the `Adapter` seam does not exist yet and
  has to be extracted first. `ParityTest.kt` must stay green through it.

One thing that makes this tractable: the ELM vocabulary the session actually
uses is a finite list — `ATZ ATD ATE0 ATL0 ATH0 ATS0 ATAL ATV0 ATSP6 ATSH ATCRA
ATFCSH ATFCSD ATFCSM` plus raw hex requests. A ThinkDiag adapter has to
*interpret* those into a protocol descriptor, not forward them.

## Phase 2 — adapter choice in settings

"Тип подключения" already exists in the web settings modal
(`index.html:139`) but it selects the *link* (Serial / BLE). Adapter kind is a
separate axis — a ThinkDiag is reached over Bluetooth, an ELM over Serial, BLE
or Wi-Fi — so it needs its own control rather than a third option in that list.

- **Web** — new select beside `#connType`, persisted with the existing
  `lsGet`/`lsSet` helpers.
- **Android** — `TransportConfig` gains a ThinkDiag case; picker in
  `MainActivity`.
- **iOS** — `TransportConfig` is `.ble`-only today; add a ThinkDiag case and
  surface it in `AdapterSheet`. `AdapterStore` already persists `Codable`.

UI strings in Russian, per `CLAUDE.md`.

## Phase 3 — the ThinkDiag adapter itself

- Framing: build and parse `55aa`, maintain the sequence counter, checksum.
- Handshake: `21/03`, `21/05`, then the licence exchange as Phase 0 decided.
- Configure the protocol descriptor for `6A8`/`688`.
- Map each request onto `27/01`; reassemble the reply, which arrives as a
  nested `55aa` frame inside the response payload.
- Report `LinkStats` and feed `TechLog` the same way the ELM path does, so the
  technical analyser keeps working across both.

## Phase 4 — proof

- Parity: extend the existing fixtures (`ParityTest.kt`, `ParityTests.swift`) so
  a recorded ThinkDiag exchange decodes to the same samples as the ELM path.
- On the car: a ThinkDiag run against a COM7 ELM run, same pages, compare
  cycle time and values.

## Platform reach

Decided by Phase 0's RFCOMM-vs-GATT answer:

- **Android** — either link, no obstacle.
- **iOS** — BLE only; classic SPP needs MFi hardware. If ThinkDiag is SPP-only,
  iOS cannot use it at all.
- **Web** — Web Bluetooth is BLE-only and Web Serial cannot reach a Bluetooth
  device that is not exposed as a COM port. Same condition as iOS, except on
  Windows where the adapter may pair as a Bluetooth COM port and reach the
  Serial path.

## What to expect

This is a new transport, not a speedup: days rather than hours, and gated on a
licence question that may end it. The value that does *not* depend on the gate
is the capture itself — a reference V46.21 dialogue from the official tool,
useful for calibration whether or not the app ever drives this adapter.
