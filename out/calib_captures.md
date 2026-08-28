# V46.21 calibration captures (live, CAN 6A8/688)

## STATE = IDLE (2026-08-26)
Ground truth (mode 01): RPM=750(0BB8/4), Load=20.4%(0x34), Coolant=84C(0x7C), IAT=71C(0x6F),
MAP=34kPa(0x22), Throttle=12.2%(0x1F), Timing=1deg(0x82), Speed=0, STFT=+1.6%(0x82), LTFT=0(0x80),
Volt=14.1V(0x3714).

Raw 21Cx (ELM multiframe, includes 03B length + N: prefixes):
```
21CB: 03B|0:61CB02F28C78|1:86FFFFFF000133|2:0100000104FFFF|3:FF003701F401F3|4:01F2FFFFFFFFFF|5:01FFFFFF01004E|6:00FF3700FFFFFF|7:FF00000000FFFF|8:016800D1
21CA: 02B|0:61CA02EE02EE|1:8D860000270014|2:00000000FE1400|3:08FF00000000FF|4:08000441050104|5:00100005B69701|6:0000
21C0: 048|0:61C002EF8D86|1:00F300F300F300|2:F3FFFFFFFFFFFF|3:FFFF01FF01FF02|4:BFFFFF00FF00FF|5:0164FFFF035CFF|6:FF03B6FFFF8101|7:FFFF8101FFFF06|8:03E717FFFFFFFF|9:FFFFFFFFFFFFFF|A:FFFFFF
21C1: 020|0:61C102EE8D86|1:74745764646464|2:FFFF64646464FF|3:FF74FFFFFFFFFF|4:FFFFFFFFFF
21C2: 048|0:61C202F38D79|1:1414FFFFFF0052|2:10100202003C01|3:B664FF64FF0001|4:FFFFFF4BDCFFFF|5:FFFFFFFFFFFFFF|6:FFFFFFFFFFFFFF|7:FFFFFF0051FFFF|8:FFFFFFFFFFFFFF|9:FFFFFFFF79FFFF|A:010000
```

## STATE = REV (~2700 rpm held)
Ground truth: RPM=2706(2A48/4), Load=15.3%(0x27), MAP=24kPa(0x18), Throttle=15.7%(0x28),
Timing=33.5deg(0xC3), IAT=71C(0x6F).
```
21CB: 03B|0:61CB0A9E8D78|1:85FFFFFF000133|2:0100000100FFFF|3:FF003701F401F3|4:01F2FFFFFFFFFF|5:01FFFFFF01004E|6:00FFC350FFFFFF|7:FF00000000FFFF|8:016800D1
21CA: 02B|0:61CA0A9E02EE|1:8E8500007B003B|2:00F800E8FE1400|3:08FF00000000FF|4:08000441050204|5:00100005B69701|6:0000
21C0: 048|0:61C00A988E85|1:00C100C100C100|2:C1FFFFFFFFFFFF|3:FFFF00FF01FF00|4:49FFFF01FF00FF|5:0267FFFF0177FF|6:FF0352FFFF7DE4|7:FFFF7DE4FFFF02|8:03E718FFFFFFFF|9:FFFFFFFFFFFFFF|A:FFFFFF
21C1: 020|0:61C10A988E85|1:8E8E6885858585|2:FFFF64646464FF|3:FF8EFFFFFFFFFF|4:FFFFFFFFFF
21C2: 048|0:61C20A928E78|1:0E0FFFFFFF00E0|2:0B0B0606004E01|3:A364FF64FF0001|4:FFFFFF4BDCFFFF|5:FFFFFFFFFFFFFF|6:FFFFFFFFFFFFFF|7:FFFFFF00D6FFFF|8:FFFFFFFFFFFFFF|9:FFFFFFFF78FFFF|A:010000
```

## CONFIRMED MAPPINGS (idx: 0x61=0)
- Revs      = 21CB idx2, dl2, raw*1                 (750/2706 vs truth)
- Battery   = 21CB idx4, dl1, raw*0.1  V            (14.0 vs 14.1)
- IAT       = 21CB idx5, dl1, raw-50   C            (71 vs 71)
- Coolant   = 21CB idx6, dl1, raw-50   C            (84 vs 84)
- Cyl1-4Adv = 21C1 idx9,10,11,12, dl1, raw-100 deg  (0->33 vs timing 1->33.5)
Per-page trio after RPM: idx4=Battery(*0.1), idx5=IAT(-50), idx6=Coolant(-50) on 21CB.
LOCATED but scale unconfirmed (need more states/ground truth):
- Injectors 1-4 = 21C0 idx6,8,10,12 (2-byte): idle 0x00F3=243 -> rev 0x00C1=193 (scale ~? ms).
- Airflow-ish  = 21CB idx43 (2-byte): idle 0x3700 -> rev 0xC350 (rises with rpm).
- 21C2 idx12 (1-byte): 0x52->0xE0 rises with rpm (air/fuel qty?).
- 21CA idx10/14/16 rise strongly with rpm (airflow/injection qty?).

## STATE = IDLE O2/injector time-series (8×21C0) — findings
Ground truth O2: B1S1(0114) steady ~0.75V (0x95-97); B1S2(0115) rose 0.64->0.75V (0x81->0x96).
- Injectors CONFIRMED: 21C0 idx6,8,10,12 (2-byte). Idle oscillates ~0x00F3..0x0107 (243..263) in
  time with fuel correction. Scale tentative (~0.0125 -> ~3.0-3.2 ms). All 4 read identical.
- Mixture correction candidates (oscillate widely at idle): 21C0 idx27 (29..235) and idx35 (51..244)
  — likely UpMixCorr/DownMixCorr; scale/offset/sign NOT confirmed.
- Duplicated oscillating pairs: idx46==idx50, idx47==idx51 (possibly O2 mV instant/avg) — not confirmed.
- Upstream O2 didn't oscillate during capture, so couldn't be located by variance; needs a longer
  synchronous series or an open-loop condition.

## SESSION PAUSE STATUS (2026-08-26)
DONE & deployed (web app CAN-PSA table): Revs, Battery, IAT, Coolant, Cyl.1-4 ignition advance
(all ground-truth confirmed) + Injectors 1-4 (position confirmed, scale ~).
Standard OBD-II mode (default) fully correct and needs nothing.
PENDING (need car + more states): injector exact scale; Up/Down O2 proprietary mapping;
mixture corrections (idx27/35 on 21C0) scale/sign; AC pressure + fan (need AC-ON capture vs idle);
cam dephaser + airflow scale (need light-load driving). Method: free COM7 (app disconnected),
run per-state capture via PowerShell over COM7, diff vs idle baseline above.

## STATE = 10-min CITY DRIVE (drive_log3.txt, ATAL fix, 278 full-frame cycles, rpm 710-3400)
Correlation of each byte vs RPM over the drive:
- AirFlow: 21CB idx43-44 (2-byte) corr +0.90, idle 0x3700 -> load 0xC350. Units NOT calibrated.
- Intake cam phaser: 21C2 idx16 (actual) & idx15 (target), corr +0.75; idle ~2 -> ~20 under load (deg, scale ~1).
- Injectors 21C0 idx6/8/10/12 (2-byte) confirmed rising with load (0x00F3 idle -> 0x0127); scale ~0.0125 ms.
- Cyl advance 21C1 idx9-12 corr +0.56 (already mapped, raw-100).
- 21CA idx8/10/12/14/16 rise strongly with rpm (corr +0.74..0.79) — airflow/injection-qty family (unmapped).
- 21C0 idx46==idx50, idx47==idx51 oscillate (not rpm-linked) — likely O2 up/down mV (raw*5?) UNCONFIRMED.
- 21C2 idx20 corr -0.76 (drops with rpm), idx18 +0.75 — cam valve/pressure family (unmapped).
NOTE: multiframe needs ATAL in ELM init (without it only first frame returns — cost us drive_log/drive_log2).
