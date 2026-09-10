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
