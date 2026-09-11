#!/usr/bin/env python3
"""The ThinkDiag activation response — SOLVED and validated (2026-09-11).

The `016028` "DBS Car Security Certificate" exchange computes the step-11
response on the phone from the adapter's nonce. Fully reversed from the
downloaded CITROEN V10.34 vehicle libs and validated byte-for-byte against every
captured pair.

The scheme (Send_DBSCarSecurCertf + ExpandKey/Encrypt in libSTD.so):

    nonce8 = the adapter's mode-1 reply with the 2-byte 0100 status stripped
    key    = nonce8[2], nonce8[0], nonce8[6], nonce8[5], 0a, 09, 0c, 08, then 8×00
    text   = "CITROEN+1+V42.01$" zero-padded to 32 bytes
    cipher = 2-round AES-128 (standard S-box and Rcon) in ECB over text
    resp   = cipher + b3 ab                          (the two constant trailer bytes)

The constants come from the vehicle software's "software cert" (g_stsc):
- indices [2,0,6,5] and key bytes 0a090c08 are g_stsc[0..7], which the app sends
  verbatim in the mode-1 request (so they are visible on the wire);
- "CITROEN" and "V42.01" are the two cert strings; "CITROEN" is 7 chars so the
  `%s+%d+%s$` variant adds the trailing `$`;
- b3ab is g_stsc[0x4c],[0x4d].

The cipher is AES-128 reduced to two rounds; the implementation below was
confirmed identical to the real libSTD.so `Encrypt` under Unicorn emulation on
random vectors (tools/thinkdiag/emu_cipher.py).
"""

SBOX = bytes.fromhex(
    "637c777bf26b6fc53001672bfed7ab76ca82c97dfa5947f0add4a2af9ca472c0"
    "b7fd9326363ff7cc34a5e5f171d8311504c723c31896059a071280e2eb27b275"
    "09832c1a1b6e5aa0523bd6b329e32f8453d100ed20fcb15b6acbbe394a4c58cf"
    "d0efaafb434d338545f9027f503c9fa851a3408f929d38f5bcb6da2110fff3d2"
    "cd0c13ec5f974417c4a77e3d645d197360814fdc222a908846eeb814de5e0bdb"
    "e0323a0a4906245cc2d3ac629195e479e7c8376d8dd54ea96c56f4ea657aae08"
    "ba78252e1ca6b4c6e8dd741f4bbd8b8a703eb5664803f60e613557b986c11d9e"
    "e1f8981169d98e949b1e87e9ce5528df8ca1890dbfe6426841992d0fb054bb16")
RCON = bytes.fromhex("0001020408102040801b360000000000")

# The CITROEN V10.34 software cert (g_stsc). Stable for this vehicle software;
# the indices/key bytes are also echoed in the mode-1 request on the wire.
INDICES = (2, 0, 6, 5)
KEY_BYTES = bytes.fromhex("0a090c08")
PLAINTEXT = b"CITROEN+1+V42.01$"
TRAILER = bytes.fromhex("b3ab")


def _key_expansion(key16):
    """AES-128 key schedule truncated to 3 round keys (48 bytes), as ExpandKey."""
    w = list(key16)
    for i in range(4, 12):
        t = w[(i - 1) * 4:(i - 1) * 4 + 4]
        if i % 4 == 0:
            t = [SBOX[t[1]] ^ RCON[i // 4], SBOX[t[2]], SBOX[t[3]], SBOX[t[0]]]
        prev = w[(i - 4) * 4:(i - 4) * 4 + 4]
        w += [prev[j] ^ t[j] for j in range(4)]
    return bytes(w)


def _xtime(a):
    a <<= 1
    return (a ^ 0x1b) & 0xff if a & 0x100 else a


def _mix_column(c):
    t = c[0] ^ c[1] ^ c[2] ^ c[3]
    return [c[0] ^ t ^ _xtime(c[0] ^ c[1]),
            c[1] ^ t ^ _xtime(c[1] ^ c[2]),
            c[2] ^ t ^ _xtime(c[2] ^ c[3]),
            c[3] ^ t ^ _xtime(c[3] ^ c[0])]


def _aes2_block(pt16, rk):
    """AES-128 reduced to two rounds, standard column-major state."""
    s = [pt16[i] ^ rk[i] for i in range(16)]

    def sub_shift(s):
        b = [SBOX[x] for x in s]
        return [b[r + 4 * ((c + r) % 4)] for c in range(4) for r in range(4)]

    s = sub_shift(s)
    mixed = []
    for c in range(4):
        mixed += _mix_column(s[4 * c:4 * c + 4])
    s = [mixed[i] ^ rk[16 + i] for i in range(16)]
    s = sub_shift(s)
    s = [s[i] ^ rk[32 + i] for i in range(16)]
    return bytes(s)


def activation_response(nonce8):
    """The step-11 response bytes for the adapter's 8-byte nonce (0100 stripped)."""
    key = bytes(nonce8[i] for i in INDICES) + KEY_BYTES + bytes(8)
    rk = _key_expansion(key)
    text = PLAINTEXT + bytes((-len(PLAINTEXT)) % 16)
    cipher = b"".join(_aes2_block(text[i:i + 16], rk) for i in range(0, len(text), 16))
    return cipher + TRAILER


# Captured (mode-1 reply, mode-0 response) pairs — the validation oracle.
PAIRS = [
    ("0100890bef0a034c2508", "c85bb75126d4ca6182128967ae28737d79b7c99c3d458bb3774568be2818cdb1b3ab"),
    ("0100000b770a0346f408", "215cc94d9ca8d9abd59a1272bdea00501b6fab83e922e15d18a2e2e1f2cb7dd0b3ab"),
]


def _selftest():
    ok = True
    for reply, resp in PAIRS:
        nonce8 = bytes.fromhex(reply)[2:]
        got = activation_response(nonce8)
        match = got.hex() == resp
        ok = ok and match
        print("  nonce %s -> %s  %s" % (nonce8.hex(), got.hex(), "OK" if match else "MISMATCH"))
    return ok


if __name__ == "__main__":
    print("validating against captured pairs:")
    print("ALL MATCH" if _selftest() else "MISMATCH")
