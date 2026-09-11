# Activation — what the ThinkDiag APK actually does

Reversing `ThinkDiag_3.2.9.apk` (jadx + native strings) to answer one question:
the per-connection activation that refuses our replay — is it a cloud secret, a
local computation, or something the account binding provisions? This is the
follow-up to the kill condition in
`out/drives/2026-09-10_thinkdiag_first_attempt.md`, reopened because the adapter
is bound to a real account we can log into.

## The two things the account gates — and we already have both

The account (`apicloud.mythinkcar.com` / `.cn`) is touched for **downloads**,
not during a diagnosis:

- **Licence.** `encryptInfo/getNewSmallLicence`, `getAppTcNewDiagLicence`,
  `v1/getDLicence`, and the PSA-specific `renault/getConfigList`. This is the
  step-7/8 blob (`21/18`, `21/17`). We proved on the car that **it replays** —
  525 bytes out, the captured answer back. So the licence half of the binding
  is already in hand.
- **Vehicle software.** `zyPublicSoft/...`, `getModelPage`. Not our concern —
  the profile is reverse-engineered already.

Launch/ThinkDiag tools are known to diagnose **offline** once licensed. That
alone says the per-connection activation is computed **on the phone**, not
fetched per-session. There is no cloud call in the activation loop to intercept.

## So the activation response is local. Where it is computed

Two native crypto subsystems in the APK, and it matters which one owns our
step 10/11:

| lib | Java surface | what it is |
|-----|--------------|------------|
| `libLICENSE.so` | `MakeLicense.autoMakeLicense`, `DecryptLicens`, `/LAUNCH_SIGNATURE.DAT` | the Launch **licence** blob — the step-7 material |
| `libencrypted.so` | `com.feasycom.encrypted.EncryptAlgorithm.{parseRandomNumber, randomNumberMatches}`, `EncryptInfo.gen` | the **Feasycom BLE module's** challenge-response: `create_random_number` → `random_number_encrypt` → `randomNumberMatches` |
| `libStdBusiness.so` | `JsonSTD_EX1_GET_DEVICE_ADAPTER_LICENSE`, `Verify_maintenance` | the diagnostic engine that drives the `55aa`/`27/01` stream |

The step 10/11 shape — adapter issues a fresh 10-byte random, app returns a
32-byte value, adapter verifies — is exactly the Feasycom
`create_random_number` / `random_number_encrypt` / `randomNumberMatches`
contract. The response is `f(nonce, key)`; `f` is native (small: `libencrypted.so`
is 18 KB), and `EncryptInfo` carries a `mPassword` field — the key input.

The Java layer is only JNI declarations (`EncryptAlgorithm` methods are all
`native`; `EncryptInfo.gen(str, str2)` returns `[password, randomNumber, algo]`).
The real work is in the `.so`, and the caller inside the Feasycom SDK
(`FscBleCentralApiImp`) supplies the password/key. **The unknown is the key and
where it comes from.**

## Why replay is dead, restated precisely

The nonce is `create_random_number` on the adapter, fresh every connection
(proven: identical request → `0100890b…` in the capture, `0100190b…` on the
car). A captured response satisfies exactly the one nonce it was recorded
against, and that nonce never returns. No capture makes it replayable. The only
way through is to **compute** `f(nonce, key)` ourselves.

## The plan, and the one cheap test that picks the branch

**Settled from the btsnoop, no test needed.** Parsing the RFCOMM stream of the
13:00 session (`tools/btsnoop/parse_activation_timing` inline) timestamps the
activation exchange:

    t=0        out  запрос активации (step 10 request)
    +41.5 ms   in   nonce 0100890bef0a034c2508 (adapter's challenge)
    +50.3 ms   out  the 32-byte response (step 11)

Between receiving the nonce and sending the response the app took **8.8 ms**.
That is a local computation, not a network round-trip (which would be
100–800 ms). So the response is `f(nonce, key)` computed on the phone, and the
"requires internet" the vendor advertises is the app's login / subscription /
download gate — **not** the activation crypto. Our own client needs neither
login nor subscription: only the licence (have it) and the key.

**If local (expected), the work is:**

1. Reverse `random_number_encrypt` in `libencrypted.so` (and confirm whether
   `libStdBusiness.so` wraps it) with a disassembler. Small function, and we
   have a **three-pair oracle** — captured (nonce → response) from three
   sessions — to validate any reconstruction offline, no car needed.
2. Find the **key**: it is on the phone, because the bound adapter works
   offline. Either a constant in the `.so`, a value derived from the adapter's
   BLE MAC (`DC:0D:30:51:4E:36`), or a per-adapter secret the account cached
   into the ThinkDiag app's data. Pulling the app's data folder settles it.
3. Reimplement `f` in Swift, drop it in at step 11 in place of the replayed
   bytes, validate against the three pairs, then one confirming drive.

## Honest read on effort

This is native crypto reverse-engineering. It is tractable — the function is
small, and the three captured pairs make it verifiable without guesswork — but
it is real work with no guarantee the key is extractable if it turns out to be
locked in the adapter's own secure element rather than cached on the phone. The
account binding's role is now clear: it provisions the licence (have it) and
possibly the key (on the phone). Logging in mainly lets those be re-downloaded;
they are already on the device.

## What is needed next

- the airplane-mode test result (picks the branch);
- if local: the ThinkDiag app's data from the phone (licence + any cached key),
  and a disassembler set up here (Ghidra) to read `libencrypted.so`.

## Update — deeper reverse (Ghidra), and the architecture it revealed

Set up Ghidra 11.3.2 and reversed the crypto libs. Findings, in order:

- **The Feasycom auth is not our gate.** `libencrypted.so`'s
  `random_number_encrypt` is **XTEA** (delta `0x9e3779b9`), 8-byte block, with a
  **constant 16-byte key baked in the `.so`**: `c5bae868223f9f50968717b24021c511`
  (extracted from `.rodata` at vaddr `0x2764`). But it operates on 8 bytes and
  our diagnostic response is 32; tested against all three captured pairs — no
  match. This is the BLE module's own beacon auth, and it never gated us (we
  got identity and licence through without it).

- **The diagnostic activation is custom crypto, and not in fixed APK code.**
  `libStdBusiness.so` (the diagnostic engine) contains **no** standard crypto
  constants (no AES S-box, no SHA/MD5 init, no XTEA delta) — searched every
  native lib. And the activation's own fingerprints — the constant step-10
  request `30020006050a090c…`, the `diagmini` model, the `016028` opcode — are
  **nowhere** in any lib or dex, as static bytes.

- **Why: ThinkDiag runs downloadable, vehicle-specific software.** The adapter
  fetches a per-vehicle diagnostic package (the account's `getConfigList` /
  `zyPublicSoft` / vehicle-software endpoints) and `libStdBusiness` is the VM
  that runs it. The `55aa`/`27/01` protocol, including the `016028` activation,
  is generated by that downloaded software, not by hardcoded APK logic. So the
  activation's `f(nonce, secret)` lives in the **downloaded CITROEN package
  and/or the VM's crypto opcodes**, keyed by material the account provisioned.

`libLICENSE.so` is only a thunk wrapper (every function jumps through a pointer);
the real licence code is inside `libStdBusiness` too.

## Honest status and the fork

The account binding's role is now fully clear, and it is real: it provisions
(a) the **licence** — we have it, it replays — and (b) the **downloaded CITROEN
diagnostic software**, which is where the activation `f` and its secret live.
Everything is local to the phone once downloaded, which is why the response is
computed in 9 ms.

But "use the binding" no longer means a small key extraction. It means one of:

- **A — pull the phone's ThinkDiag app data** (the downloaded CITROEN package +
  licence + any cached secret) and reverse the activation from *that*, which may
  be data-driven (a script/table) rather than deep native crypto. Bounded and
  cheap for the user (copy a folder); best next step if we continue.
- **B — reverse `libStdBusiness`'s diagnostic VM and its custom crypto.** Large,
  stripped, uncertain — a real multi-session RE project.
- **C — real-time relay:** our app forwards each nonce to the official app /
  phone acting as a co-processor that computes the response. Works without
  cracking anything, but needs the phone online beside the car every drive.
- **D — stop, take the deferred poll-period optimisation** (`out/engine_stream_pages.md`),
  which reaches the same ~2.15× with certainty and no crypto.

Recommendation: if we push on, do **A** next — it is the one bounded step that
could still turn this into a quick win, and it uses the binding directly. If A
shows the activation is deep VM crypto, **D** is the rational fallback.

## Breakthrough — the phone's data + the exact function chain (2026-09-11)

Pulled the ThinkDiag app's CITROEN package from the phone (adb, package
`com.us.thinkdiag.plus`, at
`/sdcard/Android/data/.../ThinkDiag/9TFD20257708/64/DIAGNOSTIC/VEHICLES/CITROEN/V10.34`).
Kept local under `tools/thinkdiag/data/phone/` (git-ignored). The named vehicle
libs — unlike the stripped app libs — carry symbols, and they map the activation
exactly:

- **The activation IS the "DBS Car Security Certificate" exchange.**
  `DBSCarSecurCertf(mode, data, len, …)` in `libCOMM_ABSTRACT_LAYER.so` builds a
  buffer `60 28 <mode> <len> <data>` — our `016028` — and sends it. So:
  - `016028 01` (step 10) mode 1 → adapter returns the 10-byte **nonce**;
  - `016028 00` (step 11) mode 0 → app sends the 32-byte **response = g(nonce, secret)**;
  - `016028 02` (step 12) mode 2 → app sends the 1627-byte **dlicense block**.
- **The secret comes from `CITROEN_dlicense.bin`** (1620 B, pulled) via
  `PSA_Dlicense_Fun` → `AES_DBSCarSecurCertf` — AES over the dlicense.
- **`lx`** (pulled) is the licence blob that replays as step 7 (`02 00 60 7d ab 90 …`),
  visibly ECB (a repeating ciphertext block), so an AES/block key encrypts it.

Files now local (all git-ignored): `CITROEN_dlicense.bin`, `EOBD2_dlicense.bin`,
`LICENSE.DAT`, `lx`, `d`, `deviceInfo` (confirms `id=2e2d5335373636134e383632`),
`libDEVICEID.so`, `libDIAG.so`, `libSTD.so`, `libCOMM_ABSTRACT_LAYER.so`.

### The one remaining unknown

`g` — how the 32-byte response is computed from the nonce and the dlicense-derived
secret. It lives in the orchestrator that calls `DBSCarSecurCertf` — `libSTD.so`'s
`Send_DBSCarSecurCertf` / `SendDlicense` (both exported there). Reverse that plus
`AES_DBSCarSecurCertf`'s key, and we can reimplement `g` in Swift and validate
against the three captured (nonce → response) pairs offline.

This is no longer a kill condition. It is a bounded reverse with **every input
already on disk**: the dlicense, the licence, the four named libs, and the
three-pair oracle. What remains is decompiling `g` and the AES key out of
`libSTD.so` — a focused continuation, not a search.

## Tooling now installed on this machine

- Temurin JRE 17 + JDK 21 (winget).
- jadx 1.5.6 (winget) — APK → Java.
- Ghidra 11.3.2 at `%TEMP%/ghidra_11.3.2_PUBLIC`, projects under `%TEMP%/ghproj`
  (`enc`, `std`, `lic`, `diag`, `comm`). Headless: `analyzeHeadless <proj> <name>
  -import <so> -postScript <py> -scriptPath <dir>` with `JAVA_HOME` = the JDK 21.
