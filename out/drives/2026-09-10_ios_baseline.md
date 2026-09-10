# iOS engine-stream baseline, 2026-09-10

The measurement the ThinkDiag plan (`out/thinkdiag_transport_plan.md`, S1) was
waiting on: what the engine stream actually costs on the current BLE adapter.
Source: `data/logs/fap_tech_20260910_153442.csv` and `…_153558.csv`, 1338 healthy
page reads on an ELM327 v1.5 clone (`ATZ` answers `E32715`).

## The numbers

| page | reply bytes | notifications | ms (median) |
|------|-------------|---------------|-------------|
| `21C08001` | 183 | 10 | 146 |
| `21C28001` | 183 | 10 | 145 |
| `21CB8001` | 151 | 8 | 118 |
| `21CA8001` | 113 | 6 | 117 |
| `21C18001` | 85 | 5 | 111 |
| `21C48001` | 66 | 4 | 89 |
| `21B08001` | 15 | 2 | 178 |

All pages together: median **118 ms**, mean 121 ms, median **6 notifications**.

## The bottleneck, confirmed and quantified

**`largest` is 20 bytes in every single healthy read, across both sessions.**
That is the floor of the ATT MTU — 23 bytes minus the 3-byte header — so this
adapter never negotiated anything larger, and `link_bytes / notifications`
lands at 18-20 throughout.

The cost of a page therefore tracks its length, not the ECU: 183 bytes cost 10
notifications and 146 ms, while 66 bytes cost 4 and 89 ms. The stream is
**notification-bound**, exactly the hypothesis the plan set out to test.

What follows: a link that carried a whole page in one or two notifications
instead of ten would cut the cycle several-fold, and nothing about the ECU or
the request form has to change to get it. That is the case for testing an
adapter with a larger MTU — ThinkDiag or otherwise. It is also why shaving
bytes off a page is worth as much as shaving milliseconds.

iOS negotiates the MTU itself; an app cannot ask for more. So on this adapter
there is no software fix for the 20-byte ceiling.

## The defect these logs also caught

Both sessions show the same failure, and it explains all three symptoms
reported from the car — parameters vanishing while timings keep updating,
having to reconnect, and the cycle degrading to ~1500 ms.

    session 153442:  … healthy … | 11.5 s gap | every page -> NO DATA (117x)
    session 153558:  … healthy … | 41.3 s gap | every page -> NO DATA
                     … manual reconnect at 15:38:29 …
                     … healthy … |  7.1 s gap | every page -> NO DATA (99x)

A gap with no exchanges at all is the app being suspended — the screen went
off. During it the ECU drops the diagnostic session, and every `21xx8001`
afterwards answers `NO DATA` (`DAA` after `Frames.clean`).

The adapter is fine throughout: those failing reads still show
`notifications=1`, `link_bytes=10`, `ms≈178`. It answers promptly; it is the
ECU that has nothing to say.

The app never recovers on its own, because `initEcu` — and the `81` that opens
the session — runs only on connect. Recovery in the log is a full manual
reconnect: at 15:38:29 the whole handshake reappears, `ATZ` through `ATFCSM1`,
then `81` → `C1D08F`.

Why the symptoms look the way they do: `lastMs[page]` is recorded for every
attempt, before the error check, while values are only written when the reply
parses. So timings keep updating over a dead session and readings do not. And
the cycle stretches because a page that answers `NO DATA` still costs its round
trip, with the occasional full timeout on top — one 1200 ms read closes session
153442.

## What was changed in response

- **The screen is held awake while a session runs** (`DeviceAwake`, held from
  `connect` and released on either teardown path). This removes the cause
  rather than recovering from it. The hold is dropped again once a session has
  been quiet for a minute: nothing to read means nothing to look at.
- **A dropped ECU session is re-opened** (`ElmSession.reopen`). Two consecutive
  poll cycles in which every page asked came back an error is unambiguous, so
  `81` is re-sent, and the full handshake follows if that does not take.
- **The stream keeps running in the background** — `UIBackgroundModes:
  [bluetooth-central]`, central role only.
- **A reminder fires when the car goes quiet** (`StallReminder`): one condition,
  no valid reading for 60 s, which covers ignition off, the adapter losing
  power with the port, and walking out of range without having to tell them
  apart. First reminder at a minute, then every ten, three at most, with a
  "Остановить" button that ends the session from the lock screen. It fires
  whatever state the app is in, because with the screen held awake the app is
  usually still in the foreground when this happens.

Still open, and it matters for background operation: `BleTransport.read` waits
by polling a buffer every 2 ms. In the foreground that is a deliberate trade -
the comment there explains why a continuation was avoided - but as a background
busy-wait it burns CPU continuously and is the kind of thing iOS terminates for
energy use. Worth replacing with a signalled wait before trusting long
background sessions.

