#!/usr/bin/env python3
"""Build the parity fixture: recorded frames plus the values they must decode to.

The point is to keep three independent implementations of the same byte maps -
index.html, the Android app and the iOS app - from drifting apart. The expected
values are taken from the **raw** Diagbox database rather than from the
generated profile, so the fixture also checks tools/diagbox/make_profile.py
itself: a wrong offset or factor in the generator shows up as a mismatch here
instead of as a wrong number on a phone in a car.

    python tools/parity/make_golden.py --every 25

Writes data/parity/golden.json, which the Swift and Kotlin tests replay.
"""

import argparse
import collections
import hashlib
import json
import os
import sys
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, 'tools', 'diagbox'))

import decode  # noqa: E402  (needs the path above)

ECU_JSON = os.path.join(ROOT, 'data', 'diagbox', 'V46_21_B7.json')
PROFILE = os.path.join(ROOT, 'android', 'app', 'src', 'main', 'assets',
                       'v46_21_profile.json')
TRANSCRIPT = os.path.join(ROOT, 'tools', 'btsnoop', 'data',
                          'transcript_2026-08-27.json')
OUT = os.path.join(ROOT, 'data', 'parity', 'golden.json')
DEVIATIONS = os.path.join(HERE, 'deviations.json')


def kind_of(field):
    """How a raw value turns into something displayable."""
    if field.get('states'):
        return 'state'
    if field.get('data_type') == 'BINARY' and field.get('factor') is None:
        return 'hex'
    return 'num'


def db_fields(doc, lid):
    """The answer fields of read page `lid`, in wire order, prefix stripped."""
    units = decode.units_by_lid(doc).get(lid.upper()) or []
    best = None
    for u in units:
        fields = [f for f in (u['frames'].get('ANSWEROK') or [])
                  if f['name'] and f['name'] not in ('SID', 'LID')]
        if best is None or len(fields) > len(best):
            best = fields
    return best or []


def name_of(field):
    """The generator drops the MP_ (measured parameter) prefix."""
    n = field['name']
    return n[3:] if n.startswith('MP_') else n


def db_decode(field, data, kind=None):
    """Mirror of tools/diagbox/decode.py, kept to raw + typed value.

    `kind` overrides the database's own classification, for the deviations the
    generator is allowed to have.
    """
    pos = field['byte_pos']
    kind = kind or kind_of(field)
    if field.get('bit_mask'):
        raw = decode.read_int(data, pos, 1)
        if raw is None:
            return None, None
        mask = int(field['bit_mask'], 2)
        raw = (raw & mask) >> ((mask & -mask).bit_length() - 1)
        length = 1
    else:
        length = field['byte_len'] or 1
        raw = decode.read_int(data, pos, length)
        if raw is None:
            return None, None
    if kind == 'hex':
        return raw, '%0*X' % (length * 2, raw)
    if kind == 'state':
        return raw, None
    factor = field.get('factor')
    offset = field.get('offset')
    if factor is None and offset is None:
        return raw, float(raw)
    return raw, round(raw * (factor or 1.0) + (offset or 0.0), 4)


def profile_decode(param, marker, hexstr):
    """The same reading, but driven by the generated profile - what the apps do."""
    at = hexstr.find(marker)
    if at < 0:
        return None, None
    start = at + param['o'] * 2
    end = start + param['n'] * 2
    if end > len(hexstr):
        return None, None
    raw = int(hexstr[start:end], 16)
    if param.get('m') is not None:
        # Shift first, then mask - `m` masks the shifted value. The database
        # side carries the unshifted bit pattern instead (0b11000000), so the
        # two agree only in this order.
        raw = (raw >> (param.get('sh') or 0)) & param['m']
    if param.get('hex'):
        return raw, hexstr[start:end].upper()
    if param.get('st'):
        return raw, None
    return raw, round(raw * param['z'] + param['d'], 4)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--every', type=int, default=25,
                    help='keep every Nth recorded frame per page')
    ap.add_argument('--transcript', default=TRANSCRIPT)
    ap.add_argument('--out', default=OUT)
    ap.add_argument('--deviations', default=DEVIATIONS)
    a = ap.parse_args()

    # Fields whose kind the generator deliberately reads differently from the
    # database. Listed explicitly so the fixture records them; see
    # tools/parity/deviations.json.
    allowed_kind = {}
    for entry in json.load(open(a.deviations, encoding='utf-8'))['kind']:
        for key in entry['keys']:
            allowed_kind[(entry['page'], key)] = entry['profile']

    doc = json.load(open(ECU_JSON, encoding='utf-8'))
    raw_profile = open(PROFILE, 'rb').read()
    profile = json.loads(raw_profile)
    transcript = json.load(open(a.transcript, encoding='utf-8'))

    prof_pages = {p['id']: p for p in profile['pages']}

    recorded = collections.OrderedDict()
    for e in transcript:
        cmd = e['cmd']
        if cmd.startswith('21') and len(cmd) >= 4:
            recorded.setdefault(cmd[2:4].upper(), []).append(e['hex'].upper())

    pages, samples, mismatches = {}, [], []
    for lid in sorted(recorded):
        page = prof_pages.get(lid)
        if page is None:
            continue  # identification blocks are not live pages
        marker = page['mk']
        by_key = {p['k']: p for p in page['params']}

        # Only the fields the generator kept, in the database's own wire order.
        fields = [f for f in db_fields(doc, lid) if name_of(f) in by_key]
        kinds = [allowed_kind.get((lid, name_of(f))) or kind_of(f)
                 for f in fields]
        pages[lid] = {
            'marker': marker,
            'fields': [
                {'k': name_of(f), 'kind': k,
                 **({'deviates': kind_of(f)} if k != kind_of(f) else {})}
                for f, k in zip(fields, kinds)
            ],
        }

        for hexstr in recorded[lid][::a.every]:
            data = bytes.fromhex(decode.clean_hex(hexstr))
            rs, vs = [], []
            for f, kind in zip(fields, kinds):
                key = name_of(f)
                raw, value = db_decode(f, data, kind)
                praw, pvalue = profile_decode(by_key[key], marker, hexstr)
                if (raw, value) != (praw, pvalue):
                    mismatches.append((lid, key, raw, value, praw, pvalue))
                rs.append(raw)
                vs.append(value)
            samples.append({'p': lid, 'h': hexstr, 'r': rs, 'v': vs})

    if mismatches:
        print('the generated profile disagrees with the raw database:')
        seen = set()
        for lid, key, raw, value, praw, pvalue in mismatches:
            if (lid, key) in seen:
                continue
            seen.add((lid, key))
            print('  %s %-44s db=(%s, %s) profile=(%s, %s)'
                  % (lid, key, raw, value, praw, pvalue))
        print('  %d field readings differ across %d fields'
              % (len(mismatches), len(seen)))
        return 1

    golden = {
        'source': os.path.relpath(a.transcript, ROOT).replace('\\', '/'),
        'generated': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
        'every': a.every,
        'profile_sha256': hashlib.sha256(raw_profile).hexdigest(),
        'deviations': json.load(open(a.deviations, encoding='utf-8'))['kind'],
        'pages': pages,
        'samples': samples,
    }
    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    with open(a.out, 'w', encoding='utf-8', newline='\n') as fh:
        json.dump(golden, fh, ensure_ascii=False, separators=(',', ':'))
        fh.write('\n')
    print('%s: %d pages, %d fields, %d samples -> %.0f kB'
          % (os.path.relpath(a.out, ROOT), len(pages),
             sum(len(p['fields']) for p in pages.values()), len(samples),
             os.path.getsize(a.out) / 1024))
    return 0


if __name__ == '__main__':
    sys.exit(main())
