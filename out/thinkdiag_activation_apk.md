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

**Decisive test (2 minutes, phone only):** put the phone in **airplane mode**
and run the *official* ThinkDiag app against the car, reading live engine data.

- **Works offline** → the response is computed on the phone from material
  already there (licence + a key). Everything needed exists locally; the task
  is to reverse `f` and locate the key. Expected outcome.
- **Refuses without internet** → there is a per-session cloud step after all,
  and we capture it with an HTTPS proxy while the official app runs, then
  replicate it with the account. Different path, also workable.

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
