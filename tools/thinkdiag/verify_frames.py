#!/usr/bin/env python3
"""Check the `55aa` frame codec against the ThinkDiag app's own frame logs.

The logs are the ground truth for ios/Sources/ThinkDiagFrame.swift: they are
what the official app put on the wire, so a codec that disagrees with them is
wrong no matter how well it round-trips against itself. Every rule the Swift
reader enforces is re-implemented here and run over every frame:

    55aa | tag(2) | len(2) | seq(1) | cmd(1) | payload | cksum(1)

    len   counts seq..payload, so a frame is 7 + len bytes
    cksum is XOR of every byte from tag through the payload - the `55aa`
          preamble and the checksum byte itself excluded
    tag   is f0f8 phone->adapter, f8f0 back
    reply echoes the request's seq and answers cmd | 0x40

The captures stay local (they carry the adapter's serial and its licence blob -
see .gitignore), so this is not a CI test. Run it after touching the codec:

    python tools/thinkdiag/verify_frames.py

Also reports what the reader has to survive: how many frames are longer than
one BLE notification, and how often a `55aa` appears inside a payload.
"""
import binascii
import glob
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
LOGS = os.path.join(HERE, '..', 'btsnoop', 'data')

# What the LE link measured on the iPhone actually delivers per notification.
NOTIFICATION = 93


def logged_frames(path):
    """Frames as the app logged them - one per line, wrapped past 512 bytes."""
    buf = ''
    for line in open(path, errors='replace'):
        line = line.strip()
        if not line:
            continue
        buf = line if line.startswith('55aa') else buf + line
        if not buf.startswith('55aa'):
            continue
        try:
            raw = binascii.unhexlify(buf)
        except binascii.Error:
            continue
        if len(raw) < 9:
            continue
        if 7 + int.from_bytes(raw[4:6], 'big') != len(raw):
            continue          # a wrapped line: keep accumulating
        yield raw
        buf = ''


def check(raw):
    """The rules, one at a time, so a failure says which one."""
    declared = int.from_bytes(raw[4:6], 'big')
    if 7 + declared != len(raw):
        return 'length'
    if raw[2:4] not in (b'\xf0\xf8', b'\xf8\xf0'):
        return 'tag'
    xor = 0
    for byte in raw[2:-1]:
        xor ^= byte
    if xor != raw[-1]:
        return 'checksum'
    return None


def main():
    paths = sorted(
        p for p in glob.glob(os.path.join(LOGS, '*'))
        if 'thinkdiag' in os.path.basename(p) and not p.endswith(('.dat', '.zip', '.curf'))
    )
    if not paths:
        print('no frame logs in %s - they are kept local, see .gitignore' % LOGS)
        return 1

    total = bad = nested = oversize = 0
    unmatched = 0
    widest = 0
    for path in paths:
        seen = 0
        pending = {}          # seq -> cmd, for requests still awaiting a reply
        for raw in logged_frames(path):
            why = check(raw)
            if why:
                bad += 1
                print('  %s: bad %s in %s' % (os.path.basename(path), why,
                                              binascii.hexlify(raw[:16]).decode()))
                continue
            seen += 1
            payload = raw[8:-1]
            if b'\x55\xaa' in payload:
                nested += 1
            if len(raw) > NOTIFICATION:
                oversize += 1
            widest = max(widest, len(raw))
            seq, cmd = raw[6], raw[7]
            if raw[2:4] == b'\xf0\xf8':
                pending[seq] = cmd
            else:
                want = pending.pop(seq, None)
                # The app logs each frame twice from the licence onward, so a
                # reply can legitimately arrive with its request already
                # consumed; only a wrong cmd is a real mismatch.
                if want is not None and cmd != (want | 0x40):
                    unmatched += 1
        total += seen
        print('%-70s %5d frames' % (os.path.basename(path), seen))

    print()
    print('frames checked          %d' % total)
    print('rule violations         %d' % bad)
    print('reply cmd mismatches    %d' % unmatched)
    print('payloads holding 55aa   %d  (so the reader must trust len, not the preamble)' % nested)
    print('longer than one notify  %d of %d, widest %d bytes  (so it must reassemble)'
          % (oversize, total, widest))
    return 1 if bad or unmatched else 0


if __name__ == '__main__':
    sys.exit(main())
