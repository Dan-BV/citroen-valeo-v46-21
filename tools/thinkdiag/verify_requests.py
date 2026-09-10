#!/usr/bin/env python3
"""Check the `27/01` request and reply codec against the ThinkDiag app's logs.

The counterpart of verify_frames.py, one layer up. That one checks the frame a
byte stream is cut into; this one checks what a frame carries when it is a
diagnostic request - the part `ios/Sources/ThinkDiagRequest.swift` has to get
right, and the part that was derived from the capture rather than documented.

Two rules, re-implemented here and run over every single-request exchange:

    request  01 64 00 01 ff 02 | L | 61 01 | n | link(2) | reqlen | request
             with L = 6 + reqlen and n = 1 + reqlen

    reply    01 00 nn nn | 55aa | ? ? | module(2) | length | answer
             length being one byte, or two with bit 12 set and the count in
             the low twelve - and the two-byte form must be tried FIRST, or
             one of the 438 answers loses its first byte to a coincidence

It also checks what the codec relies on downstream: that every answer opens
with the request's service byte plus 0x40 (or 0x7f for a refusal), and that
the header it strips never contains the marker the field extraction will go
looking for - which is what makes handing the answer straight to
`Frames.extract` safe.

The captures stay local (they carry the adapter's serial and licence blob -
see .gitignore), so this is not a CI test. Run it after touching the codec:

    python tools/thinkdiag/verify_requests.py
"""
import binascii
import collections
import glob
import hashlib
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
LOGS = os.path.join(HERE, '..', 'btsnoop', 'data')

sys.path.insert(0, HERE)
from verify_frames import logged_frames          # noqa: E402

PROLOGUE = bytes.fromhex('01640001ff02')


def exchanges(path):
    """(cmd, payload, reply) triples, the app's duplicate logging collapsed."""
    frames, prev = [], None
    for raw in logged_frames(path):
        if raw[8:] == prev:
            continue
        prev = raw[8:]
        frames.append((raw[2:4] == b'\xf0\xf8', raw[7], raw[8:-1]))
    out, i = [], 0
    while i < len(frames):
        outgoing, cmd, payload = frames[i]
        if not outgoing:
            i += 1
            continue
        reply = None
        if i + 1 < len(frames) and not frames[i + 1][0]:
            reply = frames[i + 1][2]
            i += 1
        out.append((cmd, payload, reply))
        i += 1
    return out


def parse_request(payload):
    """(link, request) or a reason it does not fit the rule."""
    if not payload.startswith(PROLOGUE):
        return None, 'not a single-request 27/01'
    if len(payload) < 14:
        return None, 'too short'
    declared = payload[6]
    body = payload[7:]
    if len(body) != declared:
        return None, 'outer length %d, body %d' % (declared, len(body))
    if body[:2] != b'\x61\x01':
        return None, 'no 6101'
    n, link, reqlen, request = body[2], body[3:5], body[5], body[6:]
    if len(request) != reqlen:
        return None, 'reqlen %d, request %d' % (reqlen, len(request))
    if n != reqlen + 1:
        return None, 'n is %d, expected %d' % (n, reqlen + 1)
    if declared != 6 + reqlen:
        return None, 'L is %d, expected %d' % (declared, 6 + reqlen)
    return (int.from_bytes(link, 'big'), request), None


def parse_reply(payload):
    """(answer, how) - `how` is 'wide', 'narrow', 'status' or a failure."""
    if len(payload) >= 2 and payload[0] == 0x01 and payload[1] == 0xff:
        return None, 'status'
    at = payload.find(b'\x55\xaa')
    if at < 0 or len(payload) < at + 7:
        return None, 'no usable nested 55aa'
    rest = payload[at + 6:]
    # Wide first. See the module docstring.
    if len(rest) >= 2:
        wide = int.from_bytes(rest[:2], 'big')
        if wide & 0x1000 and len(rest) - 2 == (wide & 0x0fff):
            return rest[2:], 'wide'
    if rest and len(rest) - 1 == rest[0]:
        return rest[1:], 'narrow'
    return None, 'length field resolves neither way'


def main():
    try:
        sys.stdout.reconfigure(encoding='utf-8')
    except (AttributeError, OSError):
        pass

    found = sorted(
        p for p in glob.glob(os.path.join(LOGS, '*'))
        if 'thinkdiag' in os.path.basename(p)
        and not p.endswith(('.dat', '.zip', '.curf'))
    )
    if not found:
        print('no frame logs in %s - they are kept local, see .gitignore' % LOGS)
        return 1

    # Some sessions were pulled off the phone twice under different names.
    # Counting one exchange twice would inflate the evidence, so skip a log
    # whose contents we have already seen.
    paths, seen, duplicates = [], set(), 0
    for path in found:
        with open(path, 'rb') as fh:
            digest = hashlib.sha256(fh.read()).hexdigest()
        if digest in seen:
            duplicates += 1
            continue
        seen.add(digest)
        paths.append(path)
    if duplicates:
        print('skipped %d log(s) byte-identical to another' % duplicates)

    how = collections.Counter()
    links = collections.Counter()
    total = failures = clashes = 0
    for path in paths:
        for cmd, payload, reply in exchanges(path):
            if cmd != 0x27 or not payload.startswith(PROLOGUE) or reply is None:
                continue
            total += 1
            parsed, why = parse_request(payload)
            if parsed is None:
                failures += 1
                print('  request: %s in %s' % (why, binascii.hexlify(payload).decode()[:60]))
                continue
            link, request = parsed
            links[('%04x' % link, request.hex().upper())] += 1

            answer, kind = parse_reply(reply)
            how[kind] += 1
            if answer is None:
                if kind != 'status':
                    failures += 1
                    print('  reply: %s in %s'
                          % (kind, binascii.hexlify(reply).decode()[:60]))
                continue

            want = (request[0] + 0x40) & 0xff
            if answer[0] not in (want, 0x7f):
                failures += 1
                print('  reply to %s opens %02x, expected %02x or 7f'
                      % (request.hex().upper(), answer[0], want))
            # What Frames.extract will search for. A hit inside the stripped
            # header would make the field extraction read the wrong offset.
            marker = bytes([want]) + request[1:2]
            if marker in reply[:len(reply) - len(answer)]:
                clashes += 1
                print('  marker %s appears in the stripped header of a reply to %s'
                      % (marker.hex().upper(), request.hex().upper()))

    print()
    print('single-request exchanges  %d' % total)
    print('rule violations           %d' % failures)
    print('marker clashes in headers %d' % clashes)
    print('answers by length form    %s'
          % ', '.join('%s %d' % (k, v) for k, v in how.most_common()))
    print()
    print('the requests that were seen, by link handle:')
    for (link, request), n in links.most_common(20):
        print('   %s  %-12s x%d' % (link, request, n))
    return 1 if failures or clashes else 0


if __name__ == '__main__':
    sys.exit(main())
