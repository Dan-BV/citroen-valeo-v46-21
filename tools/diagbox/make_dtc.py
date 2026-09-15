"""Render the fault-code dictionary of every ECU on one platform.

The scan profile (make_scan.py) says how to talk to each module; this says what
the codes it answers with mean. One entry per fault code: the Diagbox label,
plus the per-code meaning of the failure-type byte - the third byte of a UDS
fault record, which turns "$8001" into "$8001-11, short to ground".

    python make_dtc.py --platform B7 --work ./work --fbdir ./fb25 \
        --trans C:/AWRoot/dtrd/trans --out ../../data/diagbox/dtc_B7.js \
        --inject ../../index.html

Codes repeat heavily across ECUs of the same family and the two enumerations
repeat across codes, so both are stored once in shared tables and referenced by
index; the whole platform then costs a fraction of the naive layout.
"""
import argparse
import collections
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dbxlib import Thesaurus, connect, fix_ru, rows  # noqa: E402

LANG = ('ru_RU', 'en_GB')

# An ECU shows up once per family it belongs to, and the TELE_* families - the
# entry Diagbox uses to reach it for telecoding - carry an empty fault group.
# Take the richest group per ECU so those stand-ins cannot mask the real one.
ECU_SQL = """
select e.ECUID, e.I_ECUGRPDTCID, e.ECUNBRDTC, t.ECUNAME, ft.FAMNAME
from ECU e
join ECUTYPE t on t.ECUTYID = e.ECUTYID
join FAMILY f on f.FAMID = e.FAMID
join FAMTYPE ft on ft.FAMTYID = f.FAMTYID
join VEHICULE v on v.VEHID = f.VEHID
where v.VEHCOMTYPE = ? and t.ECUCOMMENT <> 'ecu telechargement'
"""

DTC_SQL = """
select d.DTCID, d.DTCCODE, d.DTCLABEL, d.DTCNAME
from I_ECUDTC ie join DTC d on d.DTCID = ie.DTCID
where ie.I_ECUGRPDTCID = ? order by d.DTCCODE
"""

# The failure types hang off the fault code, not off the ECU: Diagbox lists the
# ones this particular code can report, with its own wording for each.
#
# The sibling property DTC_STATUS_1 is deliberately not read. Its value names
# write the status either as a hex byte or as a run of bits ("..._10" is 0x10
# in one ECU and bits 3,0 in another) and nothing in the database says which,
# so the app decodes the status byte by the ISO 14229 bit meanings instead of
# guessing here.
PROP_SQL = """
select dp.DTCID, pv.PROVALNAME, pv.PROVALLABEL
from I_DTCPRO dp
join DTCPROPERTY pr on pr.PROID = dp.PROID
join I_PROVAL i on i.PROID = pr.PROID
join DTCPROPERTYVALUE pv on pv.PROVALID = i.PROVALID
where pr.PRODSDNAME = 'DTC_FAULT_TYPE'
"""

# Value names read DTC_FAULT_TYPE_<byte>, sometimes with the owning fault code
# in front ("..._12EC_96") and now and then with a word behind
# ("..._CC_PYROTECHNIQUE"). The byte is the last token that looks like one;
# a name with no such token names no byte at all, and is dropped rather than
# guessed at.
HEX_KEY = re.compile(r'^[0-9A-F]{2}$')


def key_of(valname):
    for tok in reversed(valname.upper().split('_')):
        if HEX_KEY.match(tok):
            return tok
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--platform', required=True)
    ap.add_argument('--work', required=True)
    ap.add_argument('--fbdir', required=True)
    ap.add_argument('--trans', required=True)
    ap.add_argument('--scan-json', required=True,
                    help='vehicle_<platform>.json, to keep only scanned ECUs')
    ap.add_argument('--out', required=True)
    a = ap.parse_args()

    th = {l: Thesaurus(a.trans, l) for l in LANG}

    def lab(ref):
        """The label in the first language that has it, in the app's own
        vocabulary - the same substitutions `make_profile.py` applies, so the
        fault list and the parameter list do not call the ECU two things."""
        if not ref:
            return None
        for l in LANG:
            t = th[l].resolve(ref)
            if t and t != ref:
                return fix_ru(t.strip())
        return None

    gpc = connect(a.fbdir, os.path.join(a.work, 'GPC.FDB'))
    ref = connect(a.fbdir, os.path.join(a.work, 'REF_FAM_VEH.FDB'))

    with open(a.scan_json, encoding='utf-8') as fh:
        veh = json.load(fh)
    wanted = {e['ecu'] for e in veh['ecus']}
    fams = {e['family'] for e in veh['ecus']}

    # Readable family names, as Diagbox itself labels them in its ECU menu.
    famlab = {}
    for r in rows(ref, 'select FAMILYNAME, FAMILYLABEL from ECUINFO'):
        if r['FAMILYNAME'] in fams and r['FAMILYNAME'] not in famlab:
            t = lab(r['FAMILYLABEL'])
            if t:
                famlab[r['FAMILYNAME']] = t[:1].upper() + t[1:]

    ecus = {}
    for r in rows(gpc, ECU_SQL, a.platform):
        if r['ECUNAME'] not in wanted or not r['I_ECUGRPDTCID']:
            continue
        best = ecus.get(r['ECUNAME'])
        if best is None or (r['ECUNBRDTC'] or 0) > (best['ECUNBRDTC'] or 0):
            ecus[r['ECUNAME']] = r

    # One pass over the property table beats one query per fault code: the
    # platform has tens of thousands of codes and the table is small.
    props = collections.defaultdict(dict)
    for r in rows(gpc, PROP_SQL):
        k = key_of(r['PROVALNAME'])
        if not k:
            continue
        t = lab(r['PROVALLABEL'])
        if t:
            props[r['DTCID']].setdefault(k, t)

    tables, table_ix = [], {}

    def table(d):
        """Intern one failure-type table; -1 means "this code has none"."""
        if not d:
            return -1
        key = json.dumps(d, ensure_ascii=False, sort_keys=True)
        if key not in table_ix:
            table_ix[key] = len(tables)
            tables.append(d)
        return table_ix[key]

    groups, by_grp, by_body, by_ecu = [], {}, {}, {}
    for name in sorted(ecus):
        r = ecus[name]
        grp = r['I_ECUGRPDTCID']
        if grp not in by_grp:
            codes = {}
            for d in rows(gpc, DTC_SQL, grp):
                text = lab(d['DTCLABEL']) or d['DTCNAME'] or ''
                ft = table(props.get(d['DTCID']))
                codes[d['DTCCODE']] = text if ft < 0 else [text, ft]
            # Different DTC groups often hold the very same code set (the
            # variants of one family); store it once.
            key = json.dumps(codes, ensure_ascii=False, sort_keys=True)
            if key not in by_body:
                by_body[key] = len(groups)
                groups.append(codes)
            by_grp[grp] = by_body[key]
        by_ecu[name] = by_grp[grp]

    # The same sentence describes hundreds of codes across the platform, so
    # keep the texts in one pool and let the code sets point into it.
    pool, pool_ix = [], {}

    def text_ix(t):
        if t not in pool_ix:
            pool_ix[t] = len(pool)
            pool.append(t)
        return pool_ix[t]

    packed = []
    for g in groups:
        out = {}
        for code, v in g.items():
            out[code] = (text_ix(v) if isinstance(v, str)
                         else [text_ix(v[0])] + v[1:])
        packed.append(out)

    doc = {'platform': a.platform, 'fam': famlab, 'enum': tables,
           'lab': pool, 'groups': packed, 'ecus': by_ecu}
    body = json.dumps(doc, ensure_ascii=False, separators=(',', ':'))

    os.makedirs(os.path.dirname(a.out) or '.', exist_ok=True)
    with open(a.out, 'w', encoding='utf-8') as fh:
        fh.write(body)

    print('%d ECUs -> %d distinct code sets, %d codes, %d texts, '
          '%d failure-type tables, %d family names -> %.0f kB'
          % (len(by_ecu), len(groups), sum(len(g) for g in groups), len(pool),
             len(tables), len(famlab), len(body.encode('utf-8')) / 1024))


if __name__ == '__main__':
    main()
