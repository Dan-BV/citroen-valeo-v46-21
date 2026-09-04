"""Turn the extracted ECU JSON into the compact profile the web app embeds.

The full extraction is ~2 MB and carries far more than a live-data client
needs. This keeps only the live measurement pages, the identification pages
and the fault-code dictionary, in the shape index.html consumes.

    python make_profile.py --ecu-json ../../data/diagbox/V46_21_B7.json \
        --out ../../data/diagbox/v46_21_profile.js

Byte positions are converted from the database's 1-based position within the
response to the app's 0-based offset from the start of the marker.
"""
import argparse
import json
import os

LANG = ('ru_RU', 'en_GB')

# Live measurement pages, in the order the app should show them.
LIVE = [
    ('B0', 'RDBLID_LID_B0', 'Питание и иммобилайзер'),
    ('C0', 'RDBLID_LID_C0', 'Смесеобразование'),
    ('C1', 'RDBLID_LID_C1', 'Зажигание'),
    ('C2', 'RDBLID_LID_C2', 'Впуск'),
    ('C3', 'RDBLID_LID_C3', 'Обучение и адаптивы'),
    ('C4', 'RDBLID_LID_C4', 'Момент двигателя'),
    ('CA', 'RDBLID_LID_CA', 'Движение'),
    ('CB', 'RDBLID_LID_CB', 'Окружение двигателя'),
    ('CF', 'RDBLID_LID_CF', 'Кадр $CF'),
    ('DB', 'RDBLID_LID_DB', 'Адаптации $DB'),
]
# Pages worth reading once in a while rather than every cycle.
SLOW = {'B0', 'C3', 'CF', 'DB'}

IDENT = [
    ('ZA', 'Идентификация $80'),
    ('ZI', 'Идентификация $FE'),
    ('ZF', 'Прослеживаемость $82'),
]


# The Russian Diagbox dictionary carries a few translations that would be
# actively misleading in a live-data list: "regime moteur" became "режим
# работы двигателя" (mode, not speed) and "apprentissage" became "электронная
# загрузка" (download, not learning). Fix those, and shorten "компьютер" to the
# usual "ЭБУ". Longest patterns first so they win.
RU_SUBS = [
    ('Режим работы двигателя', 'Обороты двигателя'),
    ('Заданная частота холостого хода двигателя', 'Заданные обороты холостого хода'),
    ('Давление в системе охлаждения', 'Давление хладагента кондиционера'),
    ('компьютера управления двигателем', 'ЭБУ'),
    ('Электронная загрузка', 'Обучение'),
    ('электронной загрузки', 'обучения'),
    ('электронной загрузке', 'обучения'),
    ('электронную загрузку', 'обучение'),
    ('электронная загрузка', 'обучение'),
    ('Компьютер', 'ЭБУ'),
    ('компьютером', 'ЭБУ'),
    ('компьютера', 'ЭБУ'),
    ('компьютер', 'ЭБУ'),
]

# Fields the dictionary leaves untranslated or unlabelled altogether.
RU_NAMES = {
    'MP_AVANCE_ALLUMAGE_APPLIQUEE_A_CHAQUE_CYLINDRE': 'Применённый УОЗ, цил. 1',
    'MP_ETAT_CONTACTEUR_FREIN_PRINCIPAL': 'Состояние основного контактора тормоза',
    # $CF is the after-sales intervention stamp, $DB the raw adaptation block.
    'DONNES_ADAPT': 'Адаптивные данные',
    'ZAPVNUMBER': 'ZAPV: номер записи',
    'SIGNATURE': 'ZAPV: подпись инструмента',
    'DATE': 'ZAPV: дата вмешательства',
    'MILEAGE': 'ZAPV: пробег',
    'ERASETYPE': 'ZAPV: тип стирания',
    'NUMBERINTERVENTION': 'ZAPV: число вмешательств',
    'INFTYP': 'Тип записи прослеживаемости',
    'DATEFAB': 'Аппаратный реферанс / дата изготовления',
}


# Fields the databases leave unnamed but the raw data identifies.
#
# $C1 byte 10 is labelled "ignition advance applied to EACH cylinder" and bytes
# 11-13 are unnamed - yet in 3050 captured replies all four move as one group
# and are always equal, which is what a four-element per-cylinder array looks
# like when no cylinder is being corrected. Exposing 11-13 is what lets a
# per-cylinder retard be confirmed rather than assumed: during a knock event
# cylinder 1's applied advance should fall below the other three.
#
# Marked inferred, not from Diagbox. Same scaling as the advance fields.
EXTRA = {
    'C1': [
        (10, 'Применённый УОЗ, цил. 2 (не подтверждено)'),
        (11, 'Применённый УОЗ, цил. 3 (не подтверждено)'),
        (12, 'Применённый УОЗ, цил. 4 (не подтверждено)'),
    ],
}


def extra_fields(page_id):
    out = []
    for off, label in EXTRA.get(page_id, []):
        out.append({
            'k': 'AVANCE_APPLIQUEE_CYL_%d' % (off - 8),
            'l': label, 'o': off, 'n': 1,
            'z': 1.0, 'd': -100.0, 'u': '° коленвала',
            'dec': 0, 'lo': -100.0, 'hi': 155.0,
        })
    return out


def fix_ru(text):
    for a, b in RU_SUBS:
        text = text.replace(a, b)
    return text


def cap(text):
    """Diagbox writes some labels lower-case and some not; make them uniform."""
    return text[:1].upper() + text[1:] if text else text


def lab(d, fallback=''):
    if not d:
        return fallback
    for l in LANG:
        if d.get(l):
            return fix_ru(d[l])
    return next(iter(d.values()), fallback)


def find_unit(doc, name):
    for s in doc['services']:
        for u in s['units']:
            if u['SERUNSNAME'] == name:
                return u
    return None


def req_hex(unit):
    out = []
    for b in unit['frames'].get('REQUEST', []):
        if b['const_hex']:
            out.append(b['const_hex'])
    return ''.join(out)


def marker(unit):
    """The constant leading bytes of a positive answer, used to locate it."""
    out = []
    for b in unit['frames'].get('ANSWEROK', []):
        if b['byte_pos'] in (1, 2) and b['const_hex']:
            out.append((b['byte_pos'], b['const_hex']))
    out.sort()
    return ''.join(h for _, h in out)


def decimals(factor, states):
    if states:
        return 0
    f = abs(factor or 1.0)
    if f >= 1:
        return 0
    if f >= 0.1:
        return 1
    if f >= 0.01:
        return 2
    return 3


def field(b):
    """One response field in the app's shape, or None if it carries no data."""
    if not b['name'] or b['name'] in ('SID', 'LID') or b['const_hex']:
        return None
    length = b['byte_len'] or 1
    shift, mask = 0, None
    if b['bit_mask']:
        m = int(b['bit_mask'], 2)
        if not m:
            return None
        shift = (m & -m).bit_length() - 1
        mask = m >> shift
        length = 1
    factor = b['factor'] if b['factor'] is not None else 1.0
    offset = b['offset'] if b['offset'] is not None else 0.0
    states = {}
    for s in b.get('states') or []:
        if s['raw'] is not None:
            states[str(s['raw'])] = lab(s['label'], s['name'])
    lo = offset
    hi = offset + factor * ((1 << (8 * length)) - 1)
    if mask is not None:
        hi = offset + factor * mask
    out = {
        'k': b['name'][3:] if b['name'].startswith('MP_') else b['name'],
        'l': cap(RU_NAMES.get(b['name'])
                 or lab(b.get('label')) or b.get('desc') or b['name']),
        'o': b['byte_pos'] - 1,          # 0-based offset from the marker
        'n': length,
        'z': round(factor, 10),
        'd': round(offset, 6),
        'u': lab(b.get('unit')),
        'dec': decimals(factor, states),
        'lo': round(min(lo, hi), 3),
        'hi': round(max(lo, hi), 3),
    }
    if mask is not None:
        out['sh'] = shift
        out['m'] = mask
    if states:
        out['st'] = states
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--ecu-json', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--json-out', help='write bare JSON, for the Android assets')
    ap.add_argument('--inject', help='index.html to splice the profile into')
    a = ap.parse_args()
    with open(a.ecu_json, encoding='utf-8') as fh:
        doc = json.load(fh)

    seen, pages = set(), []
    for pid, unit_name, title in LIVE:
        u = find_unit(doc, unit_name)
        if not u:
            continue
        params = []
        for b in u['frames'].get('ANSWEROK', []):
            f = field(b)
            if not f or f['k'] in seen:
                continue          # engine speed and voltage repeat on every page
            seen.add(f['k'])
            params.append(f)
        params.extend(extra_fields(pid))
        params.sort(key=lambda f: f['o'])
        if params:
            pages.append({'id': pid, 'req': req_hex(u), 'mk': marker(u),
                          'title': title, 'params': params,
                          # Immobiliser status, learned values and the
                          # after-sales stamp do not move while driving.
                          'slow': pid in SLOW})

    ident = []
    for unit_name, title in IDENT:
        u = find_unit(doc, unit_name)
        if not u:
            continue
        fields = [f for f in (field(b) for b in u['frames'].get('ANSWEROK', []))
                  if f]
        for f in fields:
            f['hex'] = True       # identification fields are packed digits
        ident.append({'req': req_hex(u), 'mk': marker(u), 'title': title,
                      'params': fields})

    dtc = {}
    for d in doc['dtcs']:
        dtc[d['code']] = lab(d['label'], d['name'] or '')

    profile = {
        'ecu': doc['ecu'], 'platform': doc['platform'],
        'can': {'req': doc['can']['request_id'],
                'res': doc['can']['response_id']},
        'pages': pages, 'ident': ident, 'dtc': dtc,
    }

    body = json.dumps(profile, ensure_ascii=False, separators=(',', ':'))
    os.makedirs(os.path.dirname(a.out) or '.', exist_ok=True)
    decl = 'const V4621 = %s;\n' % body
    with open(a.out, 'w', encoding='utf-8') as fh:
        fh.write(decl)

    if a.json_out:
        os.makedirs(os.path.dirname(a.json_out) or '.', exist_ok=True)
        with open(a.json_out, 'w', encoding='utf-8') as fh:
            fh.write(body)
        print('wrote %s' % a.json_out)

    if a.inject:
        head = '/* === V46.21 PROFILE (generated by tools/diagbox/' \
               'make_profile.py - do not edit by hand) === */\n'
        tail = '/* === END PROFILE === */'
        with open(a.inject, encoding='utf-8') as fh:
            page = fh.read()
        i, j = page.index(head), page.index(tail)
        page = page[:i] + head + decl + page[j:]
        with open(a.inject, 'w', encoding='utf-8', newline='\n') as fh:
            fh.write(page)
        print('injected into %s' % a.inject)
    print('%d pages, %d live params, %d ident fields, %d DTCs -> %.0f kB'
          % (len(pages), sum(len(p['params']) for p in pages),
             sum(len(i['params']) for i in ident), len(dtc),
             len(body.encode('utf-8')) / 1024))


if __name__ == '__main__':
    main()
