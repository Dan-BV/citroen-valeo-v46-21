# ThinkDiag as a second adapter type — implementation plan

**Scope: the iOS app only.** Web and Android are out. **Poll optimisation is
deferred** — the page-period work in `out/engine_stream_pages.md` waits until
this is done.

The investigation is finished; what follows is the build. Findings behind every
decision here: `out/thinkdiag_protocol.md`, baseline in
`out/drives/2026-09-10_ios_baseline.md`.

## What is already settled

- **The licence replays.** Two sessions minutes apart sent byte-identical
  payloads, and the adapter's one varying reply is never referenced again. No
  cloud round trip.
- **The link is a plain transparent UART.** Service
  `49535343-FE7D-4AE5-8FA9-9FAFD205E455`, notify
  `49535343-1E4D-4BD9-BA61-23C647249616`, write
  `49535343-8841-43F4-A8D4-ECBE34729BB3` (`49535343` is ASCII `ISSC`). Our
  `BleTransport` discovers a notify/write pair generically and already brings
  this link up — measured on the car, where every ELM command then timed out.
  **There is no transport work to do.**
- **It is worth 2.15x.** MTU 247 against the ELM clone's 136, and it delivers a
  whole frame in one notification where the clone always uses twenty-byte
  pieces. Against the measured cost model, a seven-page cycle goes from 883 ms
  to about 412.

## How the adapter is identified

There is one adapter and no second one to choose between, so no picker and no
stored selection: choosing the ThinkDiag *type* is the whole choice.

Identify it by its **advertised name, `9TFD20257708`** — its case serial, which
is stable. Not by the CoreBluetooth identifier: that is per-app, not a MAC, and
it can change when the app is reinstalled, which happens on every SideStore
resign. Cache the identifier once found to make reconnection quick, but never
depend on it.

## The work

**W1 — the seam.** `actor Adapter` (`ios/Sources/ElmSession.swift:706`) already
exposes everything `ElmSession` uses: `send(command:timeout:)`, `lastStats`,
`lastMs`. Turn it into a protocol; today's body becomes `ElmAdapter`. Nothing
in the session changes.

**W2 — the adapter type in settings.** `TransportConfig` gains a case beside
`.ble(id:name:)`. `AdapterStore` persists it as `Codable` already, so the
migration matters: a previously stored `.ble` value must still decode.
A segmented control in `AdapterSheet` — ELM327 / ThinkDiag — and picking
ThinkDiag hides the scan list, because there is nothing to pick.

**W3 — connect by name.** A scan that matches the advertised name and connects
to the first hit, instead of connecting to a chosen identifier.

**W4 — the framing.** Build and parse
`55aa | tag(2) | len(2) | seq(1) | cmd(1) | payload | cksum(1)`; `f0f8` out,
`f8f0` back, a reply echoes the request's `seq` with `cmd | 0x40`. Replies
arrive whole in one notification on this link, but accumulate against `len`
rather than assuming it.

**W5 — the handshake.** `21/03` and `21/05` for identity, then the licence
frames replayed byte for byte. Writes go out in twenty-byte chunks, which the
existing `Chunker` already does.

**W6 — addressing.** Requests ride `27/01` as
`64 00 01 ff | len(2) | 61 01 | n | link(2) | reqlen | request`, with link
`2905` for the engine. **The first experiment of the build**: whether that
handle works on its own after the licence frames, or whether a setup exchange
has to be replayed to create it. No CAN identifier ever crosses the wire, so
there is nothing else to try if it does not.

**W7 — translation.** `ThinkDiagAdapter` interprets the finite ELM vocabulary
the session actually sends — `ATZ ATD ATE0 ATL0 ATH0 ATS0 ATAL ATAT2 ATST19
ATSP6 ATSH ATCRA ATFCSH ATFCSD ATFCSM` as configuration or no-ops, and `81`,
`3E`, `17FF00`, `2180`, `21FE`, `21xx8001` as requests onto `27/01`.

**W8 — the measurement stays honest.** Report `LinkStats` — notifications,
bytes, largest — exactly as `BleTransport` does, so `TechLog` and `tools/tech`
keep working. That is how the 2.15x gets proved rather than assumed.

## Milestone and proof

One `21CB8001` answering the right bytes over the ThinkDiag link. Then a full
cycle measured against the 721 ms model and the 755 ms observed, with the same
pages and periods, so the comparison means something.

## Kill condition

W6 needing a setup sequence we cannot reproduce without Launch's vehicle
software. Then stop: the capture keeps its documentary value, and the
poll-period work is the fallback for the same order of gain.

## Deliberately out of scope

- The web and Android clients.
- The BSI and every other module. The DID sweep is documented in
  `out/thinkdiag_protocol.md` and waits.
- Poll optimisation — deferred by decision, not forgotten:
  `out/engine_stream_pages.md`.
