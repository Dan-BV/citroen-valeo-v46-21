# ThinkDiag, first attempt on the car — 2026-09-10, 22:08

App 1.0.39, commit `f66b44c`. Adapter `9TFD20257708` in the OBD port, ignition
on, engine off. Activation script imported: `CITROEN V46.21 · 6 шагов · 2564 Б`,
taken from the 13:02 capture.

## What happened

    1. идентификация: 71 Б
    2. идентификация (повтор): 71 Б
    3. версии: 42 Б
    4. запрос 2a: 2 Б
    5. запрос 25/05: 2 Б
    6. запрос 11: нет ответа

    Ошибка: Адаптер молчит на шаге 6 из 12: «запрос 11»

## What it proves

Five exchanges answered, and **every one of them with the byte count predicted
from the capture** — 71, 71, 42, 2, 2. Nothing about that could be a
coincidence, so the whole reconstruction holds on real hardware:

- the adapter is found and connected to by its **advertised name**, with no
  CoreBluetooth identifier involved (W2, W3);
- our `55aa` frames are **accepted**: the tag, the big-endian length, and the
  XOR checksum are all what the adapter expects, or it would not answer at all
  (W4);
- its replies **parse**, including a 71-byte binary payload arriving whole —
  which is also the first proof that the byte-clean transport works, since
  under the old `String` buffer those bytes could not have survived (W5b);
- the reply is **matched to its request** by echoed sequence id and
  `cmd | 0x40` (W4);
- the identity decodes: `diagmini`, `V1.23.004`, `V1.00.000` (W5).

So the protocol work is done and correct. What remains is behaviour we have
never observed, which is exactly what a drive is for.

## What it does not tell us, and the fix

The opening stopped at `21/11`, and the report said only «нет ответа». That
covers two diagnoses with nothing in common:

- the adapter said nothing;
- it answered, and our reader rejected the frame — which would be our bug, not
  its behaviour.

The report could not tell them apart, and neither could the technical log,
which only starts once `open()` has succeeded. That is a gap in the instrument
rather than in the protocol, and it is the first thing fixed: every step now
reports what the link delivered — notifications, bytes, the largest piece,
anything discarded, anything left half-assembled, and any link failure.

## What was changed for the next attempt

**Silence on a status query no longer ends the opening.** Three of the six
opening queries — `21/2a`, `25/05`, `21/11` — answer with a two-byte status
nobody reads. Whether the adapter needs them asked at all is not something the
capture can say: the official app asked them, so we ask them. But stopping on
one was the worse of the two guesses, because carrying on either reaches the
licence or fails there, and both outcomes say more than never having tried.

The identity queries stay required. Without them there is no telling this
adapter from any other device that answers `55aa`, and the licence is not
something to send into an unknown box.

**One retry, after silence only.** It is what separates a dead step from a
flaky one, and this drive could say neither. The status queries also get a
1.5-second timeout instead of five, since silence on them is now survivable and
every capture has them answering in milliseconds.

## Why `21/11` might be silent — untested guesses, in order

1. **It is genuinely conditional.** The captures were taken with the official
   app, which had already chosen CITROEN and had the vehicle software active.
   Our app never tells the adapter which application it is: the licence blob at
   step 7 is per-application data, and `21/11` may belong to a state the app
   sets up before the frames we saw.
2. **It answered and we rejected it.** The next report will say, in the same
   line: notifications above zero with bytes discarded means this.
3. **The link dropped.** Also visible now — the evidence line carries any
   `linkFailure`.

Guess 1 is the interesting one, and it is not answerable from the capture. If
the next attempt gets past `21/11` to the licence, the question is moot.

## Next

Reconnect with the new build and read the report. The two questions it can now
answer in one attempt are the same two W6 was always for — whether the replayed
activation response at step 11 is accepted, and whether the engine handle
`2905` works once the prologue is through — with the difference that a silent
status query no longer stops it short of asking them.


---

# Second attempt — 22:38, app 1.0.40 (`6a51ba5`)

All twelve steps ran.

    1. идентификация: 71 Б, 223 мс
    2. идентификация (повтор): 71 Б, 55 мс
    3. версии: 42 Б, 59 мс
    4. запрос 2a: 2 Б, 59 мс
    5. запрос 25/05: 2 Б, 61 мс
    6. запрос 11: нет ответа — 1510 мс, 0 увед., 0 Б
    6. запрос 11: 2 Б, 34 мс
    7. лицензия: 8 Б, 135 мс
    8. активация: 2 Б, 68 мс
    9. сведения об адаптере: 24 Б, 30 мс
    10. запрос активации: 10 Б, 30 мс
    11. ответ на запрос активации: 5 Б, 26 мс
    12. блок активации: неожиданный ответ 01ff020200000004
    адаптер: diagmini · V1.23.004 · V1.00.000 · 979865497037

## `21/11` is flaky, not conditional

The first attempt got nothing in 1510 ms — **zero notifications, zero bytes**,
so the adapter genuinely said nothing rather than answering something we
rejected. The retry answered in 34 ms. The guess that it was conditional on an
application state the official app sets up was wrong; it simply drops one
sometimes. The retry earns its place.

## The licence replays

Step 7 sent 525 bytes and got an 8-byte answer in 135 ms - the same length as
the captured `61/18`. Step 8 sent 317 and got 2, as captured. Step 9 got 24, as
captured. **The licence blobs replay, as the original verdict said.** 82-chunk
writes are not the problem either: 525 bytes went out in 27 chunks without
trouble.

## The activation does not

Two of the last three answers are the wrong length for an accepted activation:

| step | captured reply | this attempt |
|------|----------------|--------------|
| 10 запрос активации | 10 B | 10 B |
| 11 ответ на запрос активации | **18 B** | **5 B** |
| 12 блок активации | **`01ff00`** | **`01ff02 0200000004`** |

`01ff00` is this adapter saying yes; `01ff02` is what it answered 26 times in
the capture when a request could not be served. So step 12 was refused, and
step 11's 5 bytes are very likely a refusal too - the challenge–response is
real and a replayed response does not satisfy it.

**Not yet certain**, because the report recorded only counts for steps 10 and
11. Two things would settle it, and both are one line of report away:

1. **Step 10's ten bytes.** If they differ from the captured
   `0100890bef0a034c2508`, the challenge is per-session and a replay cannot
   work by construction. If they are identical, something else is wrong and
   replay is still on the table.
2. **Step 11's five bytes.** `01ff02…` means refused.

So `describe` now puts any reply of 24 bytes or fewer into the report whole.
The identity replies stay counts - 71 bytes of hex is not something to read on
a phone.

## The question this attempt does not answer

`open()` **succeeded**: `.unexpected` is not fatal, so the session went on to
initialise the ECU and ask for pages. Whether those answered is the second half
of W6, and it is not in this screenshot - it is in the status line and in the
technical log, which does start once the opening is through.

If the pages answered, step 12's refusal does not matter and the activation
exchange is about entitlement for something we do not use. If they did not, the
refusal is the blocker and the response has to be computed rather than replayed
- the algorithm being inside the ThinkDiag APK, which is the kill condition
this plan named.


---

# What the technical log settled

`fap_tech_20260910_223801.csv`, from the same 22:38 attempt. `open()` had
succeeded, so the log started, and it holds the answer the report could not
give.

    command       reply_chars  notif  link_bytes  largest  ms  ok  reply
    ATZ                    48      0           0        0   0   1  DA123004100000979865497037
    ATD … ATFCSM1           3      0           0        0   0   1
    81                      8      1          13       13  33   0  DAA
    21B08001                8      1          13       13  34   0  DAA
    21C08001                8      1          13       13  50   0  DAA
    21C18001                8      1          13       13  35   0  DAA

Two things, both decisive.

**The translation layer works exactly as designed.** All thirteen AT commands
were acknowledged with `OK` at zero notifications, zero bytes and zero
milliseconds - they never touched the link. `ATZ` answered with the adapter's
own identity. Nothing in the session had to know it was not talking to an
ELM327.

**And the adapter answered every request - with a refusal.** One notification,
13 bytes, in 33 to 50 ms. Thirteen bytes framed is a four-byte payload, and
`send` only returns `NO DATA` for a payload beginning `01 ff`. So this is not
silence and not a dead link: it is the adapter declining to run the request.

## Why, and it is not the activation

The capture says what we were missing. Before the app's first request on a
handle it sends a short run of configuration frames, ending in one that opens
the handle:

    -> 016004000000                                <- 01ff00
    -> 016001ffff020500ff01                        <- 01ff00
    -> 016105ff010855aa0460020003650003fc          <- 0100010555aa010001
    -> 016105ff010a55aa06600100012a470b0003fc      <- 0100010555aa010001
    -> 016105ff010755aa03600400670003fc            <- 0100010555aa010001
    -> 0160180c55aa08610103290530000a7d            <- 01ff00
    -> 01640001ff020761010229050181                <- …c1d08f   ← 81 answers

That last setup frame is `01 60 18 0c | 55aa 08 6101 03 2905 30 00 0a 7d` — the
nested checksum checks out, and it is plainly **the handle being opened**. We
were sending none of it and then naming handle `2905` in requests that had
never had one created. Of course they were refused.

The `2a470b` in the fourth frame is per-module, not per-session: the BSI's
version of the same frame carries `23f3b6`. So it replays.

## Changed

`make_script.py` now captures a second block - the link setup for one handle,
default `2905`, found by walking back from the open frame over exchanges the
adapter merely acknowledged. The script is 12 steps and 2648 bytes now, so the
opening is 18 steps.

And a refusal now carries its status code: `send` returns `NO DATA 01FF02xx`
rather than a bare `NO DATA`, so the technical log stops saying only `DAA` and
leaving the reason to guesswork. Safe to append - every marker test in the
session sits behind an `isError` check, and a four-byte `01ff02xx` cannot
contain a `61xx` marker.

## Still open

Step 6, the activation blob, was refused with `01ff02 0200000004`. Whether that
matters is now testable rather than guessable: if the link setup is accepted
and `81` answers, the activation exchange was about an entitlement we do not
use and the refusal is harmless. If the setup is refused too, then the
challenge-response has to be computed and the algorithm is in the APK - the
kill condition.

One attempt separates those.
