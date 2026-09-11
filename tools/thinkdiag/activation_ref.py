#!/usr/bin/env python3
"""Reference for the ThinkDiag activation response, reversed from the vehicle libs.

The activation (the `016028` "DBS Car Security Certificate" exchange) computes the
step-11 response entirely on the phone, from the adapter's nonce and a fixed
"software certificate". Reversed out of the downloaded CITROEN V10.34 package:

- `Send_DBSCarSecurCertf` (libSTD.so) is the orchestrator.
- `STD_SetSoftwareCert(cert, dlicenseName)` (libSTD.so) fills the global `g_stsc`
  from a 190-byte cert: bytes [0..3] index the nonce, [4..7] are key bytes,
  [0x18..0x37] is string 1, [0x38..] string 2, [0x40..0xbd] a second key and
  trailer, with [0x4c],[0x4d] the two bytes appended to the response.
- The cipher is `ExpandKey`/`Encrypt` — AES-128 with the standard S-box and Rcon,
  reduced to **two rounds** (key schedule for 3 round keys, cipher does
  AddRoundKey, one full round, one final round).

Response construction, per `Send_DBSCarSecurCertf`:
    key      = nonce[cert[0]], nonce[cert[1]], nonce[cert[2]], nonce[cert[3]],
               cert[4], cert[5], cert[6], cert[7], then 8 zero bytes   (16-byte AES key)
    text     = "<str1>+1+<str2>"  (str1 = cert@0x18, str2 = cert@0x38),
               zero-padded to a multiple of 16
    cipher   = AES2(key) ECB over text
    response = cipher + cert[0x4c] + cert[0x4d]

The trailer is constant: all three captured responses end in `b3ab`, so
cert[0x4c],[0x4d] = b3,ab. Validate the whole thing against the three captured
(nonce -> response) pairs; the cert (`g_stsc` contents) is the last missing
input, read from the libCITROEN*.so caller of STD_SetSoftwareCert.
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


def _key_expansion(key16):
    """AES-128 key schedule, truncated to 3 round keys (48 bytes) as ExpandKey does."""
    w = list(key16)
    for i in range(4, 12):                       # words 4..11 -> round keys 1,2
        t = w[(i - 1) * 4:(i - 1) * 4 + 4]
        if i % 4 == 0:
            t = [SBOX[t[1]] ^ RCON[i // 4], SBOX[t[2]], SBOX[t[3]], SBOX[t[0]]]
        prev = w[(i - 4) * 4:(i - 4) * 4 + 4]
        w += [prev[j] ^ t[j] for j in range(4)]
    return bytes(w)                              # 48 bytes = round keys 0,1,2


def _xtime(a):
    a <<= 1
    return (a ^ 0x1b) & 0xff if a & 0x100 else a


def _mix_column(c):
    t = c[0] ^ c[1] ^ c[2] ^ c[3]
    r = list(c)
    r[0] ^= t ^ _xtime(c[0] ^ c[1])
    r[1] ^= t ^ _xtime(c[1] ^ c[2])
    r[2] ^= t ^ _xtime(c[2] ^ c[3])
    r[3] ^= t ^ _xtime(c[3] ^ c[0])
    return r


def _aes2_block(pt16, rk):
    """AES-128 reduced to two rounds, standard column-major state."""
    s = [pt16[i] ^ rk[i] for i in range(16)]     # AddRoundKey(0)

    def sub_shift(s):
        # SubBytes then ShiftRows (row r shifted left by r), column-major indexing.
        b = [SBOX[x] for x in s]
        out = [0] * 16
        for r in range(4):
            for c in range(4):
                out[r + 4 * c] = b[r + 4 * ((c + r) % 4)]
        return out

    # Round 1: SubBytes, ShiftRows, MixColumns, AddRoundKey(1)
    s = sub_shift(s)
    mixed = []
    for c in range(4):
        mixed += _mix_column(s[4 * c:4 * c + 4])
    s = [mixed[i] ^ rk[16 + i] for i in range(16)]
    # Round 2 (final): SubBytes, ShiftRows, AddRoundKey(2)
    s = sub_shift(s)
    s = [s[i] ^ rk[32 + i] for i in range(16)]
    return bytes(s)


def response(nonce16, cert):
    """The step-11 response bytes for a given 16-byte nonce and the 190-byte cert."""
    key = bytes([nonce16[cert[0]], nonce16[cert[1]], nonce16[cert[2]], nonce16[cert[3]],
                 cert[4], cert[5], cert[6], cert[7]]) + bytes(8)
    rk = _key_expansion(key)

    def cstr(off):
        end = cert.index(0, off)
        return cert[off:end]
    text = cstr(0x18) + b"+1+" + cstr(0x38)
    if len(text) % 16:
        text += bytes(16 - len(text) % 16)
    cipher = b"".join(_aes2_block(text[i:i + 16], rk) for i in range(0, len(text), 16))
    return cipher + bytes([cert[0x4c], cert[0x4d]])


# The three captured pairs. Nonce = the 8-byte challenge the adapter returned
# (67/01 reply payload after the 0100 status), stored into g_stsc+8; the high 8
# bytes of the 16-byte key area are whatever else the reply carried / zero.
# Response = the 32-byte ciphertext the app sent (before the b3ab trailer).
PAIRS = [
    ("890bef0a034c2508", "c85bb75126d4ca6182128967ae28737d79b7c99c3d458bb3774568be2818cdb1"),
    ("0d0be90a0362e708", "aaeb0e727120b715f2d86057901670b712776c17ab31feb256b5bcd2e13d74e6"),
    ("000b770a0346f408", "215cc94d9ca8d9abd59a1272bdea00501b6fab83e922e15d18a2e2e1f2cb7dd0"),
]


def validate(cert):
    ok = True
    for non_hex, resp_hex in PAIRS:
        non = bytes.fromhex(non_hex)
        nonce16 = non + bytes(16 - len(non))
        got = response(nonce16, cert)
        want = bytes.fromhex(resp_hex) + bytes([cert[0x4c], cert[0x4d]])
        match = got == want
        ok = ok and match
        print("  nonce %s -> %s  %s" % (non_hex, got.hex(), "OK" if match else "MISMATCH"))
    return ok


if __name__ == "__main__":
    import sys
    if len(sys.argv) > 1:
        cert = open(sys.argv[1], "rb").read()
        print("cert %d bytes; validating against %d pairs:" % (len(cert), len(PAIRS)))
        print("ALL MATCH" if validate(cert) else "no match - check cert layout / nonce framing")
    else:
        print(__doc__)
