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

## Phase 0 — the gate — DONE (2026-09-10)

Captured a full CITROEN session: system scan plus data-stream reads on the BSI
and the engine, with the HCI snoop covering it from link setup on. Findings and
evidence → **`out/thinkdiag_protocol.md`**. Three answers:

1. **The licence is static.** Two CITROEN sessions minutes apart sent
   byte-identical `21/18` and licence payloads, and the adapter's one varying
   reply is never referenced again. No cloud round-trip to reproduce — this gate
   is passed.
2. **Classic SPP only, no BLE.** Zero ATT packets; RFCOMM on PSM 3, DLCI 2.
   That decides platform reach, and it rules iOS out entirely.
3. **A new blocker: no CAN addressing on the wire.** `27/01` names a two-byte
   link handle (`2905` engine, `2a25` BSI), and no CAN identifier appears in the
   stream in any encoding. The identifiers live in the adapter's downloaded
   vehicle software.

Blocker 3 is what now sets the cost. Reaching the engine means replaying the
link-setup sequence the app performs, which is tied to a vehicle-software
version rather than being a stable primitive — so the next step is not Phase 1
but a decision about whether that replay is worth owning. Options, cheapest
first:

- **Android only, replay the setup.** The one platform that can talk to this
  adapter at all. Prove the replay works before touching the app's structure.
- **Look for a raw-CAN command.** Nothing in this capture exposes one; it would
  take either more captures across different vehicle software or work on the
  adapter's own firmware. Unbounded.
- **Stop here** and keep the capture for its reference value.

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

## Platform reach — measured

- **Android** — works. `BluetoothTransport` already speaks RFCOMM SPP.
- **iOS** — impossible. Classic SPP needs MFi hardware. Drop it from scope.
- **Web** — Web Bluetooth cannot reach a classic-SPP device. On Windows the
  adapter pairs as a Bluetooth COM port, which the existing Web Serial path
  already handles with no new transport code.

## What to expect

This is a new transport, not a speedup: days rather than hours, and gated on a
licence question that may end it. The value that does *not* depend on the gate
is the capture itself — a reference V46.21 dialogue from the official tool,
useful for calibration whether or not the app ever drives this adapter.
