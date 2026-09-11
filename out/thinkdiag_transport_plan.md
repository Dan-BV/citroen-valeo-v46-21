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

**W1 — the seam. Done.** `protocol Adapter: Actor` in
`ios/Sources/Adapter.swift` declares the eight members `ElmSession` uses;
the old body is `actor ElmAdapter` in `ios/Sources/ElmAdapter.swift`. The
session holds `any Adapter` and is otherwise unchanged.

**W2 and W3 — the adapter type in settings, and connecting by name. Done.**

`TransportConfig` gained `.thinkDiag(name:)` beside `.ble(id:name:)`, and the
migration is covered by a test that decodes a literal stored `.ble` blob —
re-encoding today's enum would prove nothing about what is already on the
phone. `BleTransport` now recognises a device either by identifier or by the
name in its advertisement, preferring the advertisement over
`peripheral.name`, which the system caches and can answer with a name from an
earlier pairing. Only an identifier can skip the scan, so the ThinkDiag costs
about a second more to find — the price of not depending on an identifier that
changes with every SideStore resign.

`ElmSession` takes `makeAdapter` rather than `makeTransport`: there are two
kinds of adapter now and only the caller knows which a config means. Nothing
below that line can tell them apart.

In `AdapterSheet`, a segmented control picks the type. Choosing ThinkDiag
selects the adapter outright — there is one and nothing to pick from a list —
so the scan list is replaced by the activation section. The ELM verdict line
and its recheck button are hidden for it, because `ElmProbe` asks in ELM327
text and a ThinkDiag does not answer that.

**The activation script is imported, not file-dropped.** It cannot be in the
app: it is the adapter's own licence, and this repository is public. The first
plan was to have it placed in Documents by hand, which was worse for a reason
that matters — a file wrong by one digit looks exactly like a file that is
right, and it would only reveal itself at the car, on a 525-byte licence step
nobody can check by eye. So `ThinkDiagScriptStore` takes a file the user picks,
parses it before writing anything, and the settings screen says what is loaded
and what is wrong with what was not.

It is kept in **Application Support, not Documents**: `UIFileSharingEnabled`
exposes Documents so the drive logs can be pulled off, and the licence has no
business being visible there. The imported copy is also excluded from backup,
so it does not travel to iCloud. Documents is still read as a fallback, because
dropping the file there over a cable is the shortest route from a Windows
machine.

Without a script the adapter still runs the six opening queries and reports the
identity before failing with `noScript` — the link carrying `55aa` and the
right model answering are worth knowing on their own, and that is exactly what
the first minutes at the car want to establish.

**The opening report reaches the screen.** `Adapter` gained
`openingReport: [String]`, empty by default and so unchanged for `ElmAdapter`;
`ElmSession` publishes it after `open()` succeeds *or* throws, and the
activation section shows it as «Последняя попытка», expanded already when the
session failed. The status line names the step, the list shows all eight. This
is the instrument W6 is run with: without it the only evidence of a failed
attempt would be one line of error text.

**W4 — the framing. Done.** `ios/Sources/ThinkDiagFrame.swift`:
`55aa | tag(2) | len(2) | seq(1) | cmd(1) | payload | cksum(1)`; `f0f8` out,
`f8f0` back, a reply echoes the request's `seq` with `cmd | 0x40`, and `cksum`
is the XOR from `tag` through the payload — a rule the earlier notes did not
have, now derived and checked.

Two things this plan had wrong. Replies do **not** all arrive whole in one
notification: 672 of the 12 040 captured frames are wider than the 93 bytes
this link delivers, the widest by a factor of seventeen. And a reader cannot
resynchronise on the preamble, because 7778 payload positions in the capture
contain `55aa` themselves. So `ThinkDiagFrameReader` accumulates strictly
against `len`, and treats a preamble as a candidate only when the tag is one of
the two real ones and the checksum agrees.

Proof: 21 tests in `ios/Tests/ThinkDiagFrameTests.swift`, four of them against
frames copied out of the capture, plus `tools/thinkdiag/verify_frames.py` over
the whole corpus — which cannot run in CI, because the captures stay local.

**W5 — the handshake. Done, as a plan the transport will run.**
`ios/Sources/ThinkDiagIdentity.swift` decodes the `len(2) | bytes` strings that
`61/03` and `61/05` answer with — five and four of them, NUL-terminated inside
their own length. `ios/Sources/ThinkDiagHandshake.swift` holds the six-query
opening, the judgement of a reply, and the loader for everything after it.

**Split in two, because half of it cannot be committed.** The opening is six
one-byte queries with nothing secret in them, so it is compiled in. The licence
and activation frames are 2564 bytes of the adapter's own credentials, so they
are loaded at runtime from `thinkdiag_script.json` in the app's Documents
folder — the same folder the drive logs come out of, reachable from the Files
app. `tools/thinkdiag/make_script.py` produces that file from a local capture;
`tools/thinkdiag/data/` is git-ignored.

**And it turned up a correction that matters more than the code.** The
activation is *not* a pure replay. See the correction in
`out/thinkdiag_protocol.md`: one `27/01` step carries 32 session-unique bytes,
and the earlier "licence is static" check had looked only at the `61/18`
answer. The licence blobs themselves — 2469 of those 2564 bytes — do replay.

Every step carries a label for one reason: so the app can name the step the
adapter stopped answering at. That is the whole instrument W6 needs.

**W5b — bytes through the transport. Done.** The plan was wrong to say there
is no transport work: `ByteBuffer` accumulated a `String` and converted on the
way in, so every byte above 0x7f became U+FFFD and could never be recovered.
Fine while every adapter on this link answered in ELM327 ASCII, fatal for
binary `55aa`.

It now holds bytes and makes text on the way out. `ElmTransport` is
`LinkTransport` (`ios/Sources/LinkTransport.swift`) — the link is the same for
both adapters, only the meaning of the bytes differs — `read(until:timeout:)`
is `readText(until:timeout:)`, and `readBytes(timeout:)` is the binary read:
greedy and unframed, because a frame's extent is `ThinkDiagFrameReader`'s
business and nothing else's.

A side effect worth naming: the old conversion was chunk-dependent, so one
UTF-8 sequence split across a notification boundary became two replacement
characters instead of one. The ELM path never noticed because `Frames.clean`
strips everything that is not a hex digit — but it means the buffer was
lossy in a way that depended on BLE timing, which is not a property anything
should have.

**W6 — addressing.** Requests ride `27/01` as
`64 00 01 ff | len(2) | 61 01 | n | link(2) | reqlen | request`, with link
`2905` for the engine. **The first experiment of the build**, and it now has
two questions rather than one:

1. Does the adapter accept the replayed activation response — the step with 32
   session-unique bytes? If not, the response has to be computed, and the
   algorithm is in the ThinkDiag APK.
2. If the prologue completes, does handle `2905` work on its own, or does a
   setup exchange have to be replayed to create it? No CAN identifier ever
   crosses the wire, so there is nothing else to try if it does not.

Both are answered in one attempt: run the plan and read off the step it stopped
at.

**W7 — translation. Done.** `ios/Sources/ThinkDiagAdapter.swift` is an
`actor` conforming to `Adapter`, so the session cannot tell which kind of
adapter it holds. The AT vocabulary is acknowledged with `OK` and never
reaches the link — `?` would have made all fourteen configuration commands
look like faults in the technical log. `applyHeader` looks up a link handle
and costs **no exchange at all**, where the ELM path pays two writes.
Everything else is hex and rides `27/01`.

`ios/Sources/ThinkDiagRequest.swift` is the request and reply codec, and the
shapes in it were derived from the capture rather than documented, so
`tools/thinkdiag/verify_requests.py` re-checks them against **all 438**
single-request exchanges:

    request  01 64 00 01 ff 02 | L | 61 01 | n | link(2) | reqlen | request
             L = 6 + reqlen, n = 1 + reqlen
    reply    01 00 nn nn | 55aa | ? ? | module(2) | length | answer

Zero violations. The reply length comes in two widths — one byte, or two with
**bit 12 set** and the count in the low twelve — and the wide form has to be
tried first: on one of the 438 answers a byte in that position happened to
equal the count of everything after it, and the narrow reading swallowed the
first byte of a `62 21 02 …` reply.

The answer is handed to the session as hex, whole, and `Frames.extract` counts
its offsets from the marker exactly as on the ELM path. That is safe because
the same script checks it: the header the codec strips never contains the
marker the extraction goes looking for, in any of the 438. A bare `01ff…`
status becomes `NO DATA`, which `Frames.isError` already reads.

Proof: 15 tests in `ios/Tests/ThinkDiagAdapterTests.swift`, driven against a
fake that speaks the real framing in both directions — parsing what the
adapter writes and answering with `cmd | 0x40` and the same sequence id. The
bytes on both sides are the captured ones, so the strongest of them asserts
that asking for engine page CB puts *exactly* the official app's payload on
the wire.

**W8 — the measurement stays honest.** Report `LinkStats` — notifications,
bytes, largest — exactly as `BleTransport` does, so `TechLog` and `tools/tech`
keep working. That is how the 2.15x gets proved rather than assumed.

## Milestone and proof

One `21CB8001` answering the right bytes over the ThinkDiag link. Then a full
cycle measured against the 721 ms model and the 755 ms observed, with the same
pages and periods, so the comparison means something.

## Kill condition — reached, 2026-09-11

The second of the two named conditions is what happened: **the activation
response has to be computed, not replayed.** Proven on the car over three
drives, recorded in `out/drives/2026-09-10_thinkdiag_first_attempt.md`.

Step 10 of the opening is a challenge — the adapter returns a fresh ten-byte
nonce on every connection (`0100890b…` in the capture, `0100190b…` on the car,
to the same request). Step 11 is our reply, computed by the official app for
the capture's nonce, so a fresh nonce refuses it (`01ff02`), and the module
never activates (the link open returns `04`). `response = f(nonce, secret)`
with `f` and the key inside the ThinkDiag APK; a replay satisfies exactly one
nonce and that nonce never returns.

Everything up to the challenge is complete and correct, proven on hardware:
framing, checksum, transport, identity, the replayable licence, the ELM
translation, the link-setup sequence. The wall is a vendor cryptographic gate,
not our code. **This line of work stops here.** The capture keeps its
documentary value; the fallback for the same order of gain is the poll-period
work in `out/engine_stream_pages.md`.

## Deliberately out of scope

- The web and Android clients.
- The BSI and every other module. The DID sweep is documented in
  `out/thinkdiag_protocol.md` and waits.
- Poll optimisation — deferred by decision, not forgotten:
  `out/engine_stream_pages.md`.
