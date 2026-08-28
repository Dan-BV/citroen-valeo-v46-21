# FAP connect -> session -> live-read sequence (Citroen C4 2013, Valeo V46.21 engine ECU)

All AT/command literals below were **decrypted** from the app's obfuscated tables (DES/CBC, IV=0,
drop-2-char prefix). Comm layer = `c.java`; strings decrypted by `c.y0()` (key
`{223,191,202,5,193,142,43,161}`). Live-read requests decrypted by `k1.I()` key
`{223,191,202,5,193,131,36,161}`.

## *** CORRECTION 2 (definitive): V46.21 engine is on K-LINE, not CAN ***

The bus type is `c.f1166b`, auto-detected and cached in prefs `prot_<f1165a>`. `c.G0()` (the
retry/cycler) proves the design:
```
G0(): i = f1166b + 1;  if (f1165a != 0) f1166b = i % 2;  else f1166b = i % 4;
```
- **Every non-engine ECU (`f1165a != 0`) can only be `f1166b` 0 or 1 = CAN.**
- **The engine (`f1165a == 0`) cycles 0->1->2->3**, i.e. it may fall back to K-line.

Bus meaning (from `c.a.run()`):
| f1166b | branch | protocol | notes |
|---|---|---|---|
| 0 | CAN | `ATSP6` + `ATV0` | 11-bit CAN, header 6A8/688 (see below) |
| 1 | CAN | `ATSP6` + `ATV1` | CAN, variable DLC |
| 2 | **K-line** | `ATSP5` (KWP **fast** init) + `ATFI` | ISO 14230-4 |
| 3 | **K-line** | `ATSP4` (KWP **5-baud** init) | ISO 14230-4 |

On the real car the CAN attempts (0/1) returned NO DATA on every line, so V46.21 resolves to
**f1166b = 2 or 3 = K-LINE, ISO 14230-4 KWP2000.** This is consistent with a 2013 EC5 Valeo V46 on
the pre-CAN PSA diagnostic K-line, and with the `ATSW00` + `81` StartCommunication handling.

### K-line connect sequence for V46.21 (decrypted, in order)
Common reset (`c.a.run` 133-159): `ATZ ATWS ATD ATE0 ATL0 ATH0 ATS0 ATAL`
K-line branch (`c.a.run` 163-290, f1166b 2/3):
```
ATSP5            ; c.g  KWP fast init      (f1166b==2)   |  ATSP4 = c.f for 5-baud (f1166b==3)
ATSH8110F1       ; c.t  KWP header  = 81 10 F1  (fmt/target/source F1=tester)
ATFI             ; c.R  force fast init     (sent only when f1166b==2)
ATSW00           ; hard-coded: disable ELM periodic wakeup (app sends 3E itself)
81               ; c.U  StartCommunication      -> positive "C1.."  (sets k0)
1003             ; c.W  StartDiagnosticSession 03 -> "50.."          (sets m0, extended)
10C0             ; c.Y  StartDiagnosticSession C0 -> "50.."          (sets l0)
10A4             ; c.O  StartDiagnosticSession A4
2180 / 21FE      ; c.Q / c.P  static ECU-ID blocks
```
Keep-alive: `c.b` sends **`3E`** (or `3E00` if 1003 succeeded) every ~2.9 s; without it the KWP
link times out (~5 s) and reads go NO DATA.
Live reads: identical to CAN - bare service-21 pages `21CB 21CA 21C0 21C1 21C2` via `MainActivity.g1()`.

Notes:
- **No `ATIIA` / `ATWM` anywhere in the app** (searched all classes). Fast init (`ATSP5`) needs no
  init address; for 5-baud (`ATSP4`) ELM uses its default init address unless you set `ATIIA`.
- **`ATFCSH/ATFCSD/ATFCSM` (flow control) are CAN-only** - not used on K-line; KWP framing is
  length-byte based, so multi-message reads just come back as consecutive KWP frames.
- Car Scanner: set protocol to ISO 14230-4 KWP (fast init), header **8110F1**; the `.csp` `HDR`
  field has been set to `8110F1`.

### Adapter caveat (honest)
K-line fast init is timing-sensitive. Genuine ELM327 v1.4+ and STN-based adapters (OBDLink SX/MX)
do it reliably, but **many cheap "ELM327 v1.5" clones have weak/absent K-line transceivers and fail
ISO 14230 init even when CAN works fine**. If both fast- and 5-baud options return NO DATA on a
clone, suspect the adapter, not the sequence.

---

## (Superseded) CAN hypothesis - kept for reference / other model years

The engine ECU is addressed with **PSA-proprietary 11-bit CAN IDs, not the OBD-II 7E0/7E8 pair**.
`c.java` selects the header from the ECU index `f1165a` (0..8, one per physical ECU).
**Engine = `f1165a == 0` = the default branch:**

| Role | AT command | CAN ID |
|---|---|---|
| Request header (tester -> ECU) | `ATSH6A8` (`c.k`) | 0x6A8 |
| Receive-address filter (ECU -> tester) | `ATCRA688` (`c.F`) | 0x688 |
| Flow-control header | `ATFCSH6A8` (`c.u`) | 0x6A8 |
| Flow-control data | `ATFCSD300000` (`c.M`) | FC = 30 00 00 |
| Flow-control mode | `ATFCSM1` (`c.N`) | user FC |

So: tester transmits on **0x6A8**, engine ECU replies on **0x688**. That is why `ATSH7E0` returned
`NO DATA` for every request - wrong CAN ID entirely.

(Full 9-ECU header table decrypted from `c.k..c.s` / `c.D..c.L` / `c.u..c.C`, selected by `f1165a`:
`0:6A8/688`, `1:76D/66D`, `2:765/665`, `3:6AD/68D`, `4:6B5/695`, `5:6C1/601`, `6:75F/65F`,
`7:760/660`, `8:6A9/689`. Engine is index 0.)

## Exact ordered command stream (from `c.java` a.run(), CAN path f1166b=0)

Common ELM reset/setup (lines 133-159):
```
ATZ        ; reset
ATWS       ; warm start
ATD        ; set defaults
ATE0       ; echo off
ATL0       ; linefeeds off
ATH0       ; headers OFF  (app relies on ATCRA filter; use ATH1 when capturing so you SEE 0x688)
ATS0       ; spaces off
ATAL       ; allow long messages
```
CAN engine session (lines 309-403):
```
ATV0            ; c.S  (variable DLC off; ATV1 if f1166b==1)
ATSP6           ; c.h  ISO 15765-4, CAN 11-bit, 500 kbaud
ATSH6A8         ; c.k  request header (ENGINE)
ATCRA688        ; c.F  receive filter (ENGINE response ID)
ATFCSH6A8       ; c.u  flow-control header
ATFCSD300000    ; c.M  flow-control data 30 00 00
ATFCSM1         ; c.N  flow-control mode = user
81              ; c.U  PSA StartCommunication -> expect positive "C1 ..."  (sets k0)
```
Session-start services the app uses (KWP branch + `B0()`; expect `50` = positive to a `10`):
```
10C0            ; c.Y  StartDiagnosticSession C0   -> "50 C0.." sets l0
1003            ; c.W  StartDiagnosticSession 03   -> "50 03.." sets m0 (extended)
10A4            ; c.O  StartDiagnosticSession A4    (used before DTC/adv reads in B0())
```
`c.f(str)` (lines 1009-1023) confirms the negotiation: `81->C1`=k0, `10C0->50`=l0, `1003->50`=m0.
On success of `1003` the keep-alive becomes `3E00`, otherwise `3E`.

TesterPresent keep-alive (`c.b` runnable, lines 411-431): sends **`3E`** (or `3E00` after 1003)
**every ~2.9 s** while connected. Without it the ECU drops the session in ~5 s and reads go `NO DATA`.

## One live read end-to-end (parameter "Revs", uses `j1.S[1]`)

1. `MainActivity.g1()` groups all visible params by request page and sends each verbatim:
   `e0.b("21CB\r", ...)` (a trailing frame-count digit may be appended for multiframe, e.g. `21CB<n>`).
   **The request is a bare KWP service-21 read `21CB` - NOT `21FF02xx` and NOT wrapped in any header byte.**
2. ECU answers on 0x688 as an ISO-TP (multi-frame) message; ELM auto-sends the flow-control frame
   configured above and reassembles. Response = `61 CB <data...>`.
3. `MainActivity.d2()` stores the reply as `req;label;RESPONSE`, `k1.G()` computes
   `value = parseInt(response.substring(u,v),16) * z + D` then an optional transform `M`.
   For Revs: `raw16 * 5` rpm.

Request pages used by the V46.21 profile (`o0.java`, all bare service-21/-17):
`21CA, 21CB, 21C0, 21C1, 21C2, 21FE` and `17FF00` (DTC). `21FE`/`2180` are static ECU-ID blocks.

## About the earlier `21FF02xx` capture

FAP for V46.21 sends bare `21Cx` pages (decrypted `j1.S[]`), never `21FF02xx`. The earlier
`61FF02xx` capture did not come from this profile's live-read path (different tool or a different
ECU/scan mode). Once the header/flow-control/session above are set, this car should answer the
`21Cx` pages directly.
