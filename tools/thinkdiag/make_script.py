#!/usr/bin/env python3
"""Extract the ThinkDiag licence and activation exchange from a local capture.

The iOS app needs to replay these frames to open a session, and they must not
be committed: they are the adapter's own licence blob and activation
credentials. So they live in a file the app reads at runtime -
`thinkdiag_script.json`, dropped into the app's Documents folder through the
Files app - and this script produces it from a capture that stays local.

    python tools/thinkdiag/make_script.py
    python tools/thinkdiag/make_script.py --log <path> --out <path>

What it takes: every phone->adapter frame from the first `21/18` up to and
including the `27/01` whose reply is `01ff00`. That is the activation exchange
and nothing else. What comes before is the six-query opening, which has nothing
secret in it and is compiled into the app (`ThinkDiagHandshake.opening`). What
comes after is per-module addressing, which is W6's problem, not the
handshake's.

One of the steps is known NOT to be a replay. The `27/01` request whose payload
starts `01 60 28 00` - the response to the activation challenge - is 32 bytes of
session-unique data in all three CITROEN captures, 16 in the EOBD2 one, with no
run of the challenge anywhere in it. So it is either computed with a key the
official app holds, or generated fresh. It is written out anyway, flagged,
because replaying it is the cheapest experiment available and the app reports
which step it stopped at.

Output is git-ignored. Check that before committing anything from here.
"""
import argparse
import binascii
import glob
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_OUT = os.path.join(HERE, 'data', 'thinkdiag_script.json')
LOGS = os.path.join(HERE, '..', 'btsnoop', 'data')

sys.path.insert(0, HERE)
from verify_frames import logged_frames          # noqa: E402

# The reply that ends the activation exchange, in both the CITROEN and the
# EOBD2 captures.
DONE = '01ff00'

# What each step is, matched on the hex of its payload prefix - the four
# `27/01` steps share a command and a sub-command, so the prefix is the only
# thing that tells them apart. Longest prefix wins, so the order here does not
# matter. These labels reach the user: the app names the step it stopped at, so
# they are Russian like the rest of the interface.
LABELS = {
    '18': 'лицензия',
    '17': 'активация',
    '016020': 'сведения об адаптере',
    '01602801': 'запрос активации',
    '01602800': 'ответ на запрос активации',
    '01602802': 'блок активации',
}

# The step whose payload starts with this is session-unique. Kept separate from
# the labels so the warning still fires if a label is renamed.
VARYING = '01602800'


def exchanges(path):
    """(cmd, payload, reply) triples, with the app's duplicate logging collapsed.

    Payload and reply are hex strings: everything downstream either compares
    prefixes or writes them out, and hex avoids carrying a second
    representation around.
    """
    frames, prev = [], None
    for raw in logged_frames(path):
        if raw[8:] == prev:
            continue                              # the app logs each frame twice
        prev = raw[8:]
        frames.append((raw[2:4] == b'\xf0\xf8', raw[7],
                       binascii.hexlify(raw[8:-1]).decode()))
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


def activation(path):
    """The steps between the opening and the first module addressed."""
    steps, started = [], False
    for cmd, payload, reply in exchanges(path):
        if not started:
            if cmd == 0x21 and payload.startswith('18'):
                started = True
            else:
                continue
        steps.append((cmd, payload, reply))
        if cmd == 0x27 and reply == DONE:
            return steps
    return None                                   # never reached the end


def label_for(payload, n, cmd):
    hits = [(len(prefix), name) for prefix, name in LABELS.items()
            if payload.startswith(prefix)]
    return max(hits)[1] if hits else 'шаг %d (%02x)' % (n, cmd)


def largest_log():
    found = [
        p for p in glob.glob(os.path.join(LOGS, '*CITROEN*'))
        if not p.endswith(('.dat', '.zip', '.curf'))
    ]
    # The largest is the session that got furthest, which is the one worth
    # taking the activation from.
    return max(found, key=os.path.getsize) if found else None


def main():
    # This machine's console is cp1252, and the step labels are Russian.
    try:
        sys.stdout.reconfigure(encoding='utf-8')
    except (AttributeError, OSError):
        pass

    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--log', help='ThinkDiag app frame log (default: the largest CITROEN one)')
    ap.add_argument('--out', default=DEFAULT_OUT)
    ap.add_argument('--application', default='CITROEN V46.21')
    args = ap.parse_args()

    path = args.log or largest_log()
    if not path:
        print('no CITROEN frame log in %s - the captures are kept local' % LOGS)
        return 1

    steps = activation(path)
    if steps is None:
        print('%s never reaches the end of the activation exchange (no %s reply).'
              % (os.path.basename(path), DONE))
        print('Capture a session that gets as far as reading a data stream.')
        return 1

    out = {
        'application': args.application,
        'capturedAt': os.path.basename(path),
        'note': 'Generated by tools/thinkdiag/make_script.py. NEVER COMMIT: this '
                'carries the adapter licence and activation credentials.',
        'steps': [],
    }
    varying = None
    for n, (cmd, payload, reply) in enumerate(steps, start=1):
        step = {
            'label': label_for(payload, n, cmd),
            'cmd': '%02x' % cmd,
            'payload': payload,
        }
        # Worth insisting on only when the reply is short enough to be a status
        # rather than data; a long reply differs legitimately between sessions.
        if reply is not None and len(reply) <= 8:
            step['expecting'] = reply
        if payload.startswith(VARYING):
            step['note'] = ('session-unique in every capture; replaying it is '
                            'the W6 experiment')
            varying = n
        out['steps'].append(step)

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, 'w', encoding='utf-8') as fh:
        json.dump(out, fh, ensure_ascii=False, indent=2)
        fh.write('\n')

    print('from %s' % os.path.basename(path))
    for n, step in enumerate(out['steps'], start=1):
        print('  %d. %-28s %s %5d bytes%s'
              % (n, step['label'], step['cmd'], len(step['payload']) // 2,
                 '   <- session-unique' if n == varying else ''))
    print('wrote %s' % args.out)
    if varying is None:
        print('WARNING: no session-unique step found. Either this capture differs '
              'from the four this was built against, or the activation shape has '
              'changed - look before trusting it.')
    print('Copy it into the app: Files -> On My iPhone -> Valeo V46.21.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
