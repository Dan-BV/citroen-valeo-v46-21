# ThinkDiag fast channel — on-car result (2026-09-12)

Three back-to-back stationary runs at idle (~750 rpm), same 7-page engine plan,
same car, minutes apart. The one variable was the adapter and the fast-channel
toggle. Fast channel = the ISO-TP separation time in the engine channel-open
frame rewritten from STmin 0x0a (10 ms) to 0x00, see ThinkDiagFastChannel.

## Per-page latency (median ms of the tech log `ms` column)

| page | reply B | ELM | TD fast ON | TD fast OFF | ON vs OFF |
|------|---------|-----|-----------|-------------|-----------|
| C0   | 183 | 125 | 116 | 248 | 2.14x |
| C2   | 183 | 148 | 123 | 243 | 1.98x |
| CB   | 151 | 118 | 108 | 198 | 1.83x |
| CA   | 113 | 117 |  92 | 154 | 1.67x |
| C1   |  85 |  87 |  63 | 107 | 1.70x |
| C4   |  66 |  87 |  62 |  92 | 1.48x |
| B0   |  15 | 169 |  46 |  31 | -     |

Samples: ELM 435 reads, TD fast ON 464, TD fast OFF 88 (short run). All 100% ok
(435/435, 464/464, 88/88) — the fast channel introduced no refusals or errors.

## End-to-end cycle (median interval between full sample rows, param log)

| config           | cycle ms |
|------------------|----------|
| TD fast OFF      | 930 |
| ELM              | 600 |
| TD fast ON       | 555 |

## Verdict

- The adapter **honours** the STmin we send: the big pages halve (C0 248->116,
  C2 243->123). This is the mechanism proven on the car.
- Fast channel speeds ThinkDiag up **1.68x** end to end (930 -> 555 ms).
- ThinkDiag with the fast channel is now **faster than the ELM327** (555 vs 600
  ms) — reversing the earlier "works but not faster" finding.

The earlier ~40 ms/page projection was too optimistic: the ECU keeps its own
separation-time floor (~4 ms/frame), so a 183-byte page bottoms out near 116 ms,
not 40. The win is ~2x on multi-frame pages, not ~7x — but it is real and it
puts ThinkDiag ahead.

Recommendation: keep the fast channel on by default.
