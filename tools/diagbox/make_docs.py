"""Render the extracted Diagbox JSON into Markdown reference documents.

Usage:
    python make_docs.py --ecu-json ../../data/diagbox/V46_21_B7.json \
        --vehicle-json ../../data/diagbox/vehicle_B7.json --out ../../out
"""
import argparse
import json
import os

LANG = 'en_GB'

# Read pages that carry live measurements, in the order Lexia shows them.
LIVE_ORDER = ['RDBLID_LID_B0', 'RDBLID_LID_C0', 'RDBLID_LID_C1',
              'RDBLID_LID_C2', 'RDBLID_LID_C3', 'RDBLID_LID_C4',
              'RDBLID_LID_CA', 'RDBLID_LID_CB', 'RDBLID_LID_CF',
              'RDBLID_LID_DB']
IDENT_UNITS = ['ZA', 'ZI', 'ZF']

# The databases store service-unit descriptions in French. Translate the ones
# this ECU actually uses so the reference stays in one language.
FR_EN = {
    'Effacements des défauts': 'Clear fault codes',
    'Réinitialisation de l?UC par logiciel': 'Software reset of the ECU',
    'Reset apprentissage BPM':
        'Reset motorised-throttle (BPM) learned values',
    'Reset apprentissage VVT': 'Reset variable-valve-timing learned values',
    'Recentrage de tous les apprentissages': 'Re-centre all learned values',
    'lancement': 'start',
    'arret': 'stop',
    'demande de status': 'status request',
    'Read VA': 'Read freeze frame (conditions at fault occurrence)',
    'Lecture télécodage $A0': 'Read configuration $A0',
    'MESURES PARAMETRES $B0: Alimentations électriques et antidémarrage':
        '$B0 - Electrical supplies and immobiliser',
    'MESURES PARAMETRES $C0: RICHESSE': '$C0 - Mixture and fuelling',
    'MESURES PARAMETRES $C1: Allumage': '$C1 - Ignition',
    'MESURES PARAMETRES $C2: CIRCUIT ADMISSION': '$C2 - Intake circuit',
    'MESURES PARAMETRES $C3: Apprentissage et adaptatifs':
        '$C3 - Learned and adaptive values',
    'MESURES PARAMETRES $C4: COUPLE MOTEUR': '$C4 - Engine torque',
    'MESURES PARAMETRES $CA: Roulage': '$CA - Driving data',
    'MESURES PARAMETRES $CB: ENVIRONNEMENT MOTEUR':
        '$CB - Engine environment',
    'LECTURE TRAME CF': '$CF - read frame',
    'STRUCT_RDBLID_DB_ADAPT': '$DB - adaptation structure',
    'Identification $80': 'Identification $80 (PSA hardware reference)',
    'Tracabilité': 'Traceability $82',
    'Identification $FE': 'Identification $FE (software)',
    'Lecture Defauts': 'Read fault codes',
    'Ecriture Télécodage $A0': 'Write configuration $A0',
    "Trame d'écriture temporaire utilisée pour le télécodage AUTO":
        'Temporary write frame used by automatic configuration',
    'Programmation CMM': 'Engine ECU programming',
    'Ecriture Télécodage Référence Homologation':
        'Write homologation reference',
    'Ecriture Télécodage ZAPV': 'Write ZAPV configuration',
    'Initialisation de la communication': 'Start of communication',
    'Fin de la communication': 'End of communication',
    'inhiber le diagnostique safety niveau 2':
        'Inhibit level-2 safety diagnostics',
    'inhiber le diagnostique safety niveau 2 STATUS':
        'Inhibit level-2 safety diagnostics - status',
    'Régénération forcée B3 start': 'Forced regeneration $B3 - start',
    'Régénération forcée B8 start': 'Forced regeneration $B8 - start',
    'Régénération forcée B8 statut': 'Forced regeneration $B8 - status',
    'Régénération forcée B8 arret': 'Forced regeneration $B8 - stop',
    'Appairage A lancemant': 'Immobiliser pairing - start',
    'Appairage A status': 'Immobiliser pairing - status',
    "Ce service permet au testeur d'indiquer à l'UCE qu'il est présent":
        'Tells the ECU the tester is still connected',
}


# Field descriptions that only exist in French in DSD.PARLNAME.
FR_EN_FIELD = {
    'Addresse de début de zone': 'Zone start address',
    'Taille des données utiles à charger': 'Payload length to write',
    'Indice de télécodage': 'Configuration layout index',
    'Lieu de télécodage': 'Configuration site code',
    'Nombre de télécodages': 'Number of configuration writes',
    'Régulation/limitation de vitesse véhicule':
        'Cruise control / speed limiter',
    'Type de traçabilité': 'Traceability record type',
    'données adaptatifs': 'adaptive data',
    'référence HARDWARE': 'hardware reference',
    'Carrosserie': 'Body type',
    'Chauffage additionnel': 'Additional heating',
    "Signature de l'outil": 'Tool signature',
    'Code de defauts': 'Fault code',
    'Statut': 'Status',
    'Code erreur': 'Negative response code',
}


def desc(unit):
    t = (unit.get('SERUNDESCRIPTION') or '').strip()
    return FR_EN.get(t, t) or unit['SERUNSNAME']


def lab(d, fallback=''):
    if not d:
        return fallback
    return d.get(LANG) or next(iter(d.values()), fallback)


def md_escape(s):
    return (s or '').replace('|', r'\|').replace('\n', ' ')


def req_hex(unit):
    parts = []
    for b in unit['frames'].get('REQUEST', []):
        if b['const_hex']:
            parts.append(b['const_hex'])
        else:
            parts.append('..' * (b['byte_len'] or 1))
    return ' '.join(parts)


def scaling(b):
    """Human-readable decode rule for one response field."""
    if b.get('states'):
        return 'enum'
    f, o = b.get('factor'), b.get('offset')
    if f is None and o is None:
        return 'raw'
    f = 1.0 if f is None else f
    o = 0.0 if o is None else o
    txt = 'raw'
    if f != 1.0:
        txt = 'raw x %g' % f
    if o:
        txt += ' %+g' % o
    return txt


def states_txt(b):
    out = []
    for s in b.get('states') or []:
        if s['raw'] is None:
            continue
        out.append('%d=%s' % (s['raw'], lab(s['label'], s['name'])))
    return ', '.join(out)


def field_text(b):
    t = lab(b.get('label')) or b.get('desc') or ''
    return FR_EN_FIELD.get(t, t)


def byte_table(fields, lines):
    lines.append('')
    lines.append('| Byte | Len | Mask | Parameter | Meaning | Decode | Unit '
                 '| States |')
    lines.append('|---:|---:|---|---|---|---|---|---|')
    for b in fields:
        if not b['name'] or (b['name'] in ('SID', 'LID') and b['const_hex']):
            continue
        lines.append('| %s | %s | %s | `%s` | %s | %s | %s | %s |' % (
            b['byte_pos'], b['byte_len'] or '', b['bit_mask'] or '',
            b['name'] or '',
            md_escape(field_text(b)),
            scaling(b), md_escape(lab(b.get('unit'))),
            md_escape(states_txt(b))))
    lines.append('')


def find_unit(doc, name):
    for s in doc['services']:
        for u in s['units']:
            if u['SERUNSNAME'] == name:
                return s, u
    return None, None


def doc_reference(doc, out):
    L = []
    A = L.append
    A('# Valeo V46.21 engine ECU - diagnostic reference')
    A('')
    A('Extracted from a Diagbox 9.85 installation (`GPC.FDB`, `DSD.FDB` and '
      'the `POLUXDATA` string dictionaries). This is the same model the '
      'Lexia/Diagbox application itself drives, so the frames below are what '
      'the official tool sends.')
    A('')
    A('- ECU: **%s**, platform **%s**' % (doc['ecu'], doc['platform']))
    A('- Transport: **%s** (%s)' % (doc['protocol'], doc['service_layer']
                                    or 'KWP2000 on ISO 15765-2'))
    A('- CAN request id **0x%s**, response id **0x%s**, 11-bit, 500 kbit/s'
      % (doc['can']['request_id'], doc['can']['response_id']))
    A('- Diagbox communication library: `Cal%s.dll`' % doc['comm_library'])
    A('')
    v = [x for x in doc['variants'] if x['platform'] == doc['platform']][0]
    timing = [('P2', v['p2_timeout_ms']), ('P3', v['p3_timeout_ms']),
              ('STmin', v['st_min_ms'])]
    timing = ', '.join('%s = %s ms' % t for t in timing if t[1] is not None)
    A('Timing: %s' % (timing or 'not overridden in the database, so the '
                      'ISO 15765-2 defaults apply.'))
    A('')
    A('This ECU is defined for %d PSA platforms (%s); they share one ODX '
      'definition (`%s`), so the frames are identical. Only the fault-code '
      'list differs slightly.'
      % (len(doc['variants']),
         ', '.join(x['platform'] for x in doc['variants']),
         doc['dsd_versions'][0]['odx'] if doc['dsd_versions'] else '?'))
    A('')

    A('## Verified against a live capture')
    A('')
    A('The map below is not a guess. `tools/diagbox/decode.py` replays the '
      'ELM transcript recorded from this car on 2026-08-27 through it; every '
      'page decodes to physically sensible values on a cold engine at fast '
      'idle:')
    A('')
    A('| Page | Field | Decoded |')
    A('|---|---|---|')
    for row in [
        ('$80', 'Equipment part number', '9804436280 (Valeo)'),
        ('$FE', 'Software edition', '0E18, 2 downloads'),
        ('$C0', 'Upstream oxygen sensor', '766 mV, rich, closed loop'),
        ('$C0', 'Injection time, all four cylinders', '5.0 ms'),
        ('$C1', 'Optimum / applied ignition advance', '19 deg / -7 deg'),
        ('$C2', 'Air flow, manifold pressure', '19.8 kg/h, 441 mBar'),
        ('$C2', 'Cam phaser reference / actual', '28 deg / 29 deg'),
        ('$C2', 'Engine start counter', '19425'),
        ('$CA', 'Fuel level, vehicle speed', '14 litre, 0 kph'),
        ('$CA', 'Coolant temperature at last stop', '95 deg C'),
        ('$CB', 'Sensor supply voltages 1/2/3', '5000 / 4990 / 4980 mV'),
        ('$CB', 'Engine speed, ECU supply', '1103 rpm, 14.3 V'),
    ]:
        A('| %s | %s | %s |' % row)
    A('')
    A('Two things this settles for anyone who reverse-engineered these pages '
      'by hand: coolant temperature on the live pages is `raw - 50`, not the '
      'usual `raw - 40`, and the `80 01` suffix does not change the byte '
      'layout - a bare `21 CB` answers `61 CB ...` with the payload at the '
      'same positions as `61 FF ...`.')
    A('')

    A('## Byte order')
    A('')
    A('`ADDDATA.ADDBYTEORDER` in the database reads `LittleEndian` for the '
      'multi-byte fields of this ECU, but on the wire the **most significant '
      'byte comes first**. Verified against live captures: engine speed '
      '`04 4F` = 1103 rpm and sensor supply `01 F4` x 10 = 5000 mV. Decode '
      'multi-byte integers MSB-first.')
    A('')

    A('## Session sequence')
    A('')
    A('```')
    A('ATSP6            ; ISO 15765-4, 11 bit, 500k')
    A('ATSH%s           ; request header' % doc['can']['request_id'])
    A('ATCRA%s          ; accept only the ECU answer' % doc['can']['response_id'])
    A('ATFCSH%s  ATFCSD300000  ATFCSM1' % doc['can']['request_id'])
    A('ATAL             ; allow long (multi-frame) messages')
    A('81               ; StartCommunication  -> C1 D0 8F')
    A('...              ; diagnostic requests')
    A('3E               ; TesterPresent, keep the session alive')
    A('82               ; StopCommunication   -> C2')
    A('```')
    A('')
    A('`81` is mandatory: the proprietary `21 xx` pages answer `7F 21 ..` '
      'until the session is started. There is no need for `10 C0` / `10 03`; '
      'this ECU answers `7F 10 12` (subfunction not supported) to those.')
    A('')

    A('## Service catalogue')
    A('')
    A('| Service | SID | Units | Purpose |')
    A('|---|---|---:|---|')
    for s in doc['services']:
        sid = ''
        for u in s['units']:
            for b in u['frames'].get('REQUEST', []):
                if b['name'] == 'SID' and b['const_hex']:
                    sid = '`%s`' % b['const_hex']
                    break
            if sid:
                break
        A('| `%s` | %s | %d | %s |' % (s['SERSNAME'], sid, len(s['units']),
                                       md_escape(s['SERLNAME'] or '')))
    A('')

    A('## Live measurement pages')
    A('')
    A('Every page is requested as `21 <LID> 80 01` and answered as '
      '`61 FF <data>`. The trailing `80 01` asks the ECU for the full record; '
      'the answer identifier is `FF` rather than the page id, so a reader '
      'must track which page it asked for. Byte 1 of the tables below is the '
      '`61`, byte 2 the `FF`, so payload starts at byte 3.')
    A('')
    for name in LIVE_ORDER:
        _s, u = find_unit(doc, name)
        if not u:
            continue
        fields = [b for b in u['frames'].get('ANSWEROK', [])
                  if b['name'] not in ('SID', 'LID')]
        if not fields:
            continue
        A('### %s' % desc(u))
        A('')
        A('Request `%s` -> `61 FF ...` (%d fields)'
          % (req_hex(u), len(fields)))
        byte_table(fields, L)

    A('## Identification')
    A('')
    for name in IDENT_UNITS:
        _s, u = find_unit(doc, name)
        if not u:
            continue
        A('### %s - %s' % (name, desc(u)))
        A('')
        A('Request `%s`' % req_hex(u))
        byte_table([b for b in u['frames'].get('ANSWEROK', [])
                    if b['name'] not in ('SID', 'LID')], L)

    A('## Fault codes')
    A('')
    _s, u = find_unit(doc, 'RDSDTC')
    if u:
        A('Read: `%s` -> `57 <count> [ <DTC hi> <DTC lo> <status> ] x N`'
          % req_hex(u))
        A('')
        A('Each record is 3 bytes: a 2-byte PSA fault code followed by a '
          'status byte. The full code list for this ECU is in '
          '`diagbox_v46_21_dtc.md` (%d codes).' % len(doc['dtcs']))
    _s, u = find_unit(doc, 'CLRDI')
    if u:
        A('')
        A('Clear: `%s` -> `54 FF 00`' % req_hex(u))
    A('')

    A('### Freeze frame (conditions when the fault was stored)')
    A('')
    _s, u = find_unit(doc, 'RDBLID_87')
    if u and u.get('dynamic'):
        dyn = u['dynamic']['ANSWEROK']
        A('Request `21 87 <DTC hi> <DTC lo>` -> `61 87 <DTC hi> <DTC lo> '
          '<block>`. The block layout depends on which of the %d groups the '
          'DTC belongs to; the block starts at byte %d. Group membership and '
          'all %d layouts are in the JSON under '
          '`services[].units[].dynamic`.'
          % (len(dyn['groups']), dyn['block_start'], len(dyn['groups'])))
        A('')
        A('Note the freeze-frame fields use their own scaling, different from '
          'the live pages: engine speed is `raw x 0.25` and coolant '
          'temperature `raw - 40`, whereas page $CB uses `raw x 1` and '
          '`raw - 50`.')
        A('')
        biggest = max(dyn['groups'].items(), key=lambda kv: len(kv[1]))
        A('Largest group `%s` (%d fields):' % (biggest[0], len(biggest[1])))
        byte_table(biggest[1], L)

    A('## Actuator tests')
    A('')
    A('All actuator tests use InputOutputControlByLocalIdentifier:')
    A('')
    A('```')
    A('30 <actuator> 00   start      -> 70 <actuator> <status>')
    A('30 <actuator> 01   read state -> 70 <actuator> <status>')
    A('30 <actuator> 11   stop       -> 70 <actuator> <status>')
    A('```')
    A('')
    A('| Actuator byte | Test | Max duration |')
    A('|---|---|---|')
    for t in sorted(doc['actuator_tests'], key=lambda x: x['name']):
        nsp = ''
        for s in t['services']:
            if s['role'] == 'ACTUATE' and s.get('args'):
                nsp = s['args'].get('NSP', '')
        dur = ('%d ms' % t['max_duration_ms']) if t['max_duration_ms'] else '-'
        A('| `%s` | %s | %s |' % (nsp, md_escape(lab(t['title'], t['name'])),
                                  dur))
    A('')

    A('## Resets and learned-value clearing')
    A('')
    A('| Frame | Meaning |')
    A('|---|---|')
    for s in doc['services']:
        if s['SERSNAME'] != 'ECURESET':
            continue
        for u in s['units']:
            A('| `%s` | %s |' % (req_hex(u), md_escape(desc(u))))
    A('')

    A('## Routines')
    A('')
    A('| Frame | Meaning |')
    A('|---|---|')
    for s in doc['services']:
        if s['SERSNAME'] not in ('SRBLID',):
            continue
        for u in s['units']:
            A('| `%s` | %s |' % (req_hex(u), md_escape(desc(u))))
    A('')

    A('## Security access')
    A('')
    _s, seed = find_unit(doc, 'GETSEED')
    _s, key = find_unit(doc, 'SENDKEY')
    if seed and key:
        A('`%s` returns a seed, `%s` sends the computed key. The key '
          'algorithm lives in the communication library `Cal%s.dll` and is '
          'not stored in the databases.'
          % (req_hex(seed), req_hex(key), doc['comm_library']))
    A('')
    A('Security access is required for writing configuration; reading '
      'configuration (`21 A0`) is not protected.')
    A('')

    A('## Telecoding (configuration)')
    A('')
    A('Read the whole configuration block with `21 A0`; write it back with '
      'a `34 A0 ...` Request Download frame. The write frames differ per '
      'configuration generation:')
    A('')
    _s, a0 = find_unit(doc, 'RDBLID_LID_A0')
    if a0 and a0.get('dynamic'):
        dyn = a0['dynamic']['ANSWEROK']
        A('### Reading: `21 A0`')
        A('')
        A('The answer is `61 A0 <index> <block>`. Byte 3 is '
          '`CONFIG_INDICE_TELECODAGE`, the configuration-layout index, and it '
          'selects which of the %d layouts applies. Group `..._07` means '
          'index `0x07`, and so on; `INDICE_TELECODAGE` is the fallback '
          'layout. Bit-addressed options carry a mask - the option is that '
          'bit of the byte at the given position.' % len(dyn['groups']))
        A('')
        for gname in sorted(dyn['groups']):
            fields = dyn['groups'][gname]
            A('#### Layout `%s` (%d options)' % (gname, len(fields)))
            A('')
            A('| Byte | Bit mask | Parameter | Meaning |')
            A('|---:|---|---|---|')
            for b in fields:
                A('| %s | %s | `%s` | %s |' % (
                    b['byte_pos'], b['bit_mask'] or '-', b['name'],
                    md_escape(field_text(b))))
            A('')
    _s, w = find_unit(doc, 'REQDWN_LID_A0_1')
    if w:
        A('### Writing: `34 A0 ...`')
        A('')
        A('One flat frame. Bytes 3-5 are the start address of the zone, byte '
          '6 its length and byte 7 the configuration index; the options then '
          'follow. Options with a mask share a byte, the rest take a whole '
          'byte each. `RESERVE*` entries mark the bits that must be left '
          'alone - read the block first and only flip the bits you mean to '
          'change.')
        byte_table([b for b in w['frames'].get('REQUEST', [])
                    if b['name'] not in ('SID', 'LID')], L)
    A('### Write-frame variants')
    A('')
    A('| Frame template | Purpose |')
    A('|---|---|')
    for s in doc['services']:
        if s['SERSNAME'] != 'REQDWN':
            continue
        for u in s['units']:
            tmpl = req_hex(u)
            if len(tmpl) > 90:
                tmpl = tmpl[:90] + ' ...'
            A('| `%s` | %s |' % (tmpl, md_escape(desc(u))))
    A('')
    for scr in doc['telecoding']:
        named = [p for p in scr['params']
                 if lab(p['label']) and not p['name'].startswith('RESERVE')]
        if not named:
            continue
        A('### Screen `%s`' % scr['screen'])
        A('')
        A('| Parameter | Meaning | Options |')
        A('|---|---|---|')
        for p in sorted(named, key=lambda x: x['name']):
            opts = ', '.join(
                '%s=%s' % (s['raw'], lab(s['label'], s['name']))
                for s in (p['states'] or []) if s['raw'] is not None)
            A('| `%s` | %s | %s |' % (p['name'], md_escape(lab(p['label'])),
                                      md_escape(opts)))
        A('')

    A('## Lexia measurement screens')
    A('')
    A('How the official tool groups the parameters on screen. Useful if you '
      'want the same layout in your own client.')
    A('')
    A('| Screen | Title | Parameters |')
    A('|---|---|---:|')
    for s in doc['screens']:
        A('| `%s` | %s | %d |' % (s['screen'], md_escape(lab(s['title'])),
                                  len(s['params'])))
    A('')

    write(out, 'diagbox_v46_21_reference.md', L)


def doc_dtc(doc, out):
    L = ['# Valeo V46.21 - fault code list', '',
         'ECU `%s`, platform `%s`, %d codes. The code is the 2-byte PSA '
         'identifier returned by `17 FF 00`, not an SAE P-code.'
         % (doc['ecu'], doc['platform'], len(doc['dtcs'])), '',
         '| Code | Description |', '|---|---|']
    for d in doc['dtcs']:
        L.append('| `%s` | %s |' % (d['code'],
                                    md_escape(lab(d['label'], d['name'] or ''))))
    L.append('')
    write(out, 'diagbox_v46_21_dtc.md', L)


def doc_vehicle(veh, out):
    L = ['# ECU map for PSA platform %s' % veh['platform'], '',
         'Every module Diagbox knows about on this platform, with its '
         'diagnostic CAN identifiers. A scanner can walk this list: set the '
         'request/response headers, send the init frame, then the '
         'recognition frame; an answer means the module is fitted.', '',
         'Total: **%d** ECU definitions (several alternatives may share one '
         'address - only one is fitted).' % veh['ecu_count'], '',
         '| Family | ECU | Request | Response | Protocol | Init | Recognition |',
         '|---|---|---|---|---|---|---|']
    for e in veh['ecus']:
        f = e['frames'] or {}
        L.append('| %s | `%s` | `%s` | `%s` | %s | `%s` | `%s` |' % (
            e['family'], e['ecu'], e['can']['request_id'],
            e['can']['response_id'], e['protocol'] or '',
            f.get('init_request') or '', f.get('reco_request') or ''))
    L.append('')
    write(out, 'diagbox_%s_ecu_map.md' % veh['platform'].lower(), L)


def write(out, name, lines):
    p = os.path.join(out, name)
    with open(p, 'w', encoding='utf-8') as fh:
        fh.write('\n'.join(lines))
    print('%-40s %6d lines' % (name, len(lines)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--ecu-json', required=True)
    ap.add_argument('--vehicle-json')
    ap.add_argument('--out', required=True)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    with open(a.ecu_json, encoding='utf-8') as fh:
        doc = json.load(fh)
    doc_reference(doc, a.out)
    doc_dtc(doc, a.out)
    if a.vehicle_json:
        with open(a.vehicle_json, encoding='utf-8') as fh:
            doc_vehicle(json.load(fh), a.out)


if __name__ == '__main__':
    main()
