"""Extract the ECU inventory of one PSA platform from a Diagbox install.

This is what a scanner needs to enumerate every module on the car: for each
ECU family, its CAN request/response identifiers, the wake-up / start-session
frame, the recognition request that identifies the ECU, and the fault-read
service.

Usage:
    python extract_vehicle.py --platform M3_M4 --work ... --fbdir ... \
        --trans ... --out ...
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dbxlib import Thesaurus, connect, rows  # noqa: E402


ECU_SQL = """
select e.ECUID, e.ECUCODE, e.ECUNBRDTC, e.ECUEDOFILENAME,
       e.ECUP2TIMEOUT, e.ECUP3TIMEOUT, e.ECUSTMIN, e.I_ECUGRPDTCID,
       t.ECUNAME, t.ECULIBNAME, t.ECUSERVICELAYER, t.ECUTMOUT,
       t.ECUCOMMENT, t.ECUTYPEINIT, t.ECUREVEIL,
       f.FAMIDCANR, f.FAMIDCANE, f.FAMCANBUS, f.FAMCANLINE,
       f.FAMCANADDRESSTYPE, f.FAMCANIDTYPE, f.FAMCANPADDING,
       f.FAMCODETARGET, f.FAMSOURCECODE, f.FAMNETWORK, f.FAMMUX,
       ft.FAMNAME, ft.FAMSELCODE, ft.FAMGATEWAY,
       pt.PROTNAME
from ECU e
join ECUTYPE t on t.ECUTYID = e.ECUTYID
join FAMILY f on f.FAMID = e.FAMID
join FAMTYPE ft on ft.FAMTYID = f.FAMTYID
join VEHICULE v on v.VEHID = f.VEHID
left join PROTOCOL p on p.PROTID = t.PROTID
left join PROTTYPE pt on pt.PROTTYID = p.PROTTYID
where v.VEHCOMTYPE = ?
order by ft.FAMNAME, t.ECUNAME
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--platform', required=True)
    ap.add_argument('--work', required=True)
    ap.add_argument('--fbdir', required=True)
    ap.add_argument('--trans', required=True)
    ap.add_argument('--langs', default='en_GB,ru_RU')
    ap.add_argument('--out', required=True)
    a = ap.parse_args()

    langs = [x for x in a.langs.split(',') if x]
    th = {l: Thesaurus(a.trans, l) for l in langs}
    gpc = connect(a.fbdir, os.path.join(a.work, 'GPC.FDB'))
    dsd = connect(a.fbdir, os.path.join(a.work, 'DSD.FDB'))

    # One recognition/init frame set per ECU name (identical across variants).
    reco = {}
    for r in rows(dsd, """
        select ECUNAME, REQUESTRECOFRAME, ANSWEROKRECOFRAME,
               REQUESTINITFRAME, ANSWEROKINITFRAME,
               REQUESTFINDIAGFRAME, ANSWEROKFINDIAGFRAME
        from RECO"""):
        reco.setdefault(r['ECUNAME'], {
            'reco_request': r['REQUESTRECOFRAME'],
            'reco_answer': r['ANSWEROKRECOFRAME'],
            'init_request': r['REQUESTINITFRAME'],
            'init_answer': r['ANSWEROKINITFRAME'],
            'stop_request': r['REQUESTFINDIAGFRAME'],
            'stop_answer': r['ANSWEROKFINDIAGFRAME'],
        })

    ecus = []
    for r in rows(gpc, ECU_SQL, a.platform):
        if r['ECUCOMMENT'] == 'ecu telechargement':
            continue          # bootloader entry, not a diagnostic session
        family = r['FAMNAME']
        ecus.append({
            'family': family,
            'family_label': {l: t.resolve('@P0-POLUXDATA') for l, t in ()},
            'ecu': r['ECUNAME'],
            'ecuid': r['ECUID'],
            'comm_library': r['ECULIBNAME'],
            'protocol': r['PROTNAME'],
            'service_layer': r['ECUSERVICELAYER'],
            'can': {
                'request_id': r['FAMIDCANE'],
                'response_id': r['FAMIDCANR'],
                'bus': r['FAMCANBUS'],
                'line': r['FAMCANLINE'],
                'id_type': r['FAMCANIDTYPE'],
                'addressing': r['FAMCANADDRESSTYPE'],
                'padding': r['FAMCANPADDING'],
            },
            'is_gateway': bool(r['FAMGATEWAY']),
            'timing': {
                'p2_ms': r['ECUP2TIMEOUT'],
                'p3_ms': r['ECUP3TIMEOUT'],
                'st_min_ms': r['ECUSTMIN'],
                'ecu_timeout_ms': r['ECUTMOUT'],
            },
            'dtc_count': r['ECUNBRDTC'],
            'odx_file': r['ECUEDOFILENAME'],
            'frames': reco.get(r['ECUNAME']),
        })

    for e in ecus:
        e.pop('family_label', None)

    doc = {
        'platform': a.platform,
        'source': 'Diagbox GPC.FDB + DSD.FDB',
        'ecu_count': len(ecus),
        'ecus': ecus,
    }
    os.makedirs(os.path.dirname(a.out) or '.', exist_ok=True)
    with open(a.out, 'w', encoding='utf-8') as fh:
        json.dump(doc, fh, ensure_ascii=False, indent=1)
    print('%s: %d ECUs -> %s' % (a.platform, len(ecus), a.out))
    for e in ecus:
        print('  %-14s %-22s CAN %s/%s  %s'
              % (e['family'], e['ecu'], e['can']['request_id'],
                 e['can']['response_id'], e['protocol'] or ''))
    del th


if __name__ == '__main__':
    main()
