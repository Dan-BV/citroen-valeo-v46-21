"""Decode V46.21 responses using the byte map extracted from Diagbox.

Two uses:
  * as a library - `decode_page(doc, 'CB', '61FF04...')` returns named values;
  * as a script  - replay a recorded ELM transcript and print the values, which
    is how the extracted map was checked against a real car.

    python decode.py --ecu-json ../../data/diagbox/V46_21_B7.json \
        --transcript ../btsnoop/data/transcript_2026-08-27.json --limit 3
"""
import argparse
import json
import os
import re
import sys


def clean_hex(s):
    """Strip ELM formatting: frame indices, length prefixes, whitespace."""
    out = []
    for line in re.split(r'[\r\n]+', s or ''):
        line = line.strip()
        if not line or line in ('OK', 'NO DATA', 'SEARCHING...'):
            continue
        line = re.sub(r'^[0-9A-Fa-f]{1,3}:', '', line.strip())
        out.append(re.sub(r'[^0-9A-Fa-f]', '', line))
    h = ''.join(out)
    return h[:-1] if len(h) % 2 else h


def units_by_lid(doc):
    """Map the LID byte of each read page to its response field list."""
    pages = {}
    for svc in doc['services']:
        for u in svc['units']:
            req = u['frames'].get('REQUEST') or []
            if len(req) < 2 or (req[0].get('const_hex') or '') != '21':
                continue
            lid = req[1].get('const_hex')
            if not lid:
                continue
            pages.setdefault(lid.upper(), []).append(u)
    return pages


def read_int(data, pos, length):
    """MSB-first unsigned integer at 1-based byte position `pos`."""
    i = pos - 1
    if i < 0 or i + length > len(data):
        return None
    v = 0
    for b in data[i:i + length]:
        v = (v << 8) | b
    return v


def decode_fields(data, fields):
    out = []
    for f in fields:
        if not f['name'] or f['name'] in ('SID', 'LID'):
            continue
        pos = f['byte_pos']
        if f.get('bit_mask'):
            raw = read_int(data, pos, 1)
            if raw is None:
                continue
            mask = int(f['bit_mask'], 2)
            shift = (mask & -mask).bit_length() - 1
            raw = (raw & mask) >> shift
            length = 1
        else:
            length = f['byte_len'] or 1
            raw = read_int(data, pos, length)
            if raw is None:
                continue
        value, unit = raw, ''
        if not f.get('states') and f.get('data_type') == 'BINARY' \
                and f.get('factor') is None:
            # Identification fields are packed decimal digits, not numbers:
            # 0x98 04 43 62 80 is PSA part number 9804436280.
            value = '%0*X' % (length * 2, raw)
        elif f.get('states'):
            hit = [s for s in f['states'] if s['raw'] == raw]
            value = (hit[0]['label'] or {}).get('en_GB', str(raw)) if hit \
                else '?%d' % raw
        elif f.get('factor') is not None or f.get('offset') is not None:
            value = raw * (f.get('factor') or 1.0) + (f.get('offset') or 0.0)
            value = round(value, 4)
            unit = (f.get('unit') or {}).get('en_GB', '') if f.get('unit') \
                else ''
        out.append({
            'byte': pos, 'name': f['name'],
            'label': (f.get('label') or {}).get('en_GB', ''),
            'raw': raw, 'value': value, 'unit': unit,
        })
    return out


def decode_page(doc, lid, hexstr, pages=None):
    """Decode one `61 FF ...` answer for the read page `lid` (e.g. 'CB')."""
    pages = pages or units_by_lid(doc)
    units = pages.get(lid.upper())
    if not units:
        return None
    data = bytes.fromhex(clean_hex(hexstr))
    best = None
    for u in units:
        fields = u['frames'].get('ANSWEROK') or []
        got = decode_fields(data, fields)
        if best is None or len(got) > len(best[1]):
            best = (u, got)
    return {'unit': best[0]['SERUNSNAME'], 'fields': best[1]} if best else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--ecu-json', required=True)
    ap.add_argument('--transcript', required=True)
    ap.add_argument('--limit', type=int, default=1,
                    help='how many samples per page to print')
    a = ap.parse_args()

    with open(a.ecu_json, encoding='utf-8') as fh:
        doc = json.load(fh)
    with open(a.transcript, encoding='utf-8') as fh:
        entries = json.load(fh)
    pages = units_by_lid(doc)

    seen = {}
    for e in entries:
        cmd = (e.get('cmd') or '').upper().replace(' ', '')
        m = re.match(r'^21([0-9A-F]{2})', cmd)
        if not m:
            continue
        lid = m.group(1)
        if seen.get(lid, 0) >= a.limit:
            continue
        got = decode_page(doc, lid, e.get('hex'), pages)
        if not got or not got['fields']:
            continue
        seen[lid] = seen.get(lid, 0) + 1
        print('\n=== $%s via %s   request %s' % (lid, got['unit'], cmd))
        for f in got['fields']:
            print('  b%-3d %-52s %-22s %s'
                  % (f['byte'], f['label'] or f['name'],
                     f['value'], f['unit']))
    if not seen:
        sys.exit('no 21xx exchanges found in %s' % os.path.basename(
            a.transcript))


if __name__ == '__main__':
    main()
