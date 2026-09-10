# ThinkDiag as a second adapter protocol — plan

**Scope: the iOS app only.** The web and Android versions are out of scope as of
2026-09-10. **Priority: the engine data stream.** No work on the BSI or any
other module until the engine stream is optimised.

## Why bother — the hypothesis this has to earn

The engine stream on iOS is notification-bound, not ECU-bound. A proprietary
`21xx8001` page answers with 40-70 bytes and the BLE link hands them over about
20 at a time, one notification per connection event; measured elsewhere in the
same session, a page that answers costs 78 ms and one that does not costs a full
169 ms timeout, out of a 2353 ms cycle.

ThinkDiag is worth building **only if its LE link moves that number** — a larger
MTU, or fewer round-trips per page. That is measurable with instruments the app
already has: `LinkStats` counts notifications, bytes and the largest piece;
`TechLog` records it per exchange; `tools/tech` analyses the log. So the honest
order is measure first, build second.

## What the 2026-09-10 capture settled

Evidence and detail in `out/thinkdiag_protocol.md`.

- **The licence payload is static and replayable.** Two sessions minutes apart
  sent byte-identical blobs; the adapter's one varying reply is never referenced
  again. No Launch cloud round-trip.
- **The adapter is dual-mode.** It advertises LE as `9TFD20257708` (442
  advertising reports in the snoop, "BR/EDR not supported" bit clear) and the
  phone bonds it as `[ DUAL ]`. The Android app happened to choose classic SPP;
  the iPhone reaches it over LE. An earlier note in this plan claimed iOS could
  not reach it at all — that was a conclusion drawn from one app's choice, and
  it was wrong.
- **Addressing is a handle, not a CAN id.** `27/01` carries
  `64 00 01 ff | len(2) | 61 01 | n | link(2) | reqlen | request`, where `link`
  is resolved inside the adapter's own vehicle software: `2905` engine, `2a25`
  BSI. No CAN identifier appears in the stream in any encoding.

## What is still unknown

1. ~~The GATT layout.~~ **Done** — ISSC transparent UART, one notify and one
   write characteristic, listed in `out/thinkdiag_protocol.md`. S2 and S3 are
   both answered: the app already lists the adapter and brings the link up, and
   every ELM command times out on it. Transport fine, protocol wrong.
2. **Whether `55aa` over GATT is framed the same** as over RFCOMM, and at what
   MTU — which is the whole point of the exercise.
3. **Whether the link handle is stable.** `2905` and `2a25` recur within the
   13:02 session, but the two short CITROEN sessions used a different descriptor
   form, so cross-session stability is not yet shown.
4. **Whether a link has to be opened** before `27/01` will accept a handle, or
   whether the handle alone is enough after the licence frames.

## Steps

**S1 — measure the baseline, without ThinkDiag.** Record a tech log of the
engine stream on the current adapter and get notifications-per-page and
ms-per-page. Every later claim is judged against this, and the number is worth
having whatever happens to ThinkDiag.

**S2 — enumerate the GATT** (`tools/ble/enumerate.py 9TFD`). Services,
characteristics, properties, MTU.

**S3 — probe with what already exists.** `AdapterScanner` scans with
`withServices: nil` and `BleTransport` calls `discoverServices(nil)` and picks a
notify/write pair generically, so the app should already list the adapter and
may already bring up a byte pipe. Find out, and log which characteristics it
chose and the negotiated MTU. No new transport code until this says one is
needed.

**S4 — speak the protocol.** `55aa` framing, the licence replay, then
`21CB8001` on handle `2905`. One page answering correctly is the milestone.

**S5 — compare against S1** and keep it only if it wins.

## Deliberately out of scope

- The web and Android versions.
- The BSI and every other module. The BSI DID sweep from this capture is
  documented in `out/thinkdiag_protocol.md` and stays parked until the engine
  stream is optimised.
- New iOS transport plumbing before S3 proves it is needed.

## Kill conditions

- S1 shows the engine stream is not notification-bound — then ThinkDiag cannot
  help, whatever else is true.
- S2 or S3 shows no usable GATT pipe.
- S4 needs setup we cannot reproduce without Launch's vehicle software. In that
  case stop and keep the capture for its reference value.
