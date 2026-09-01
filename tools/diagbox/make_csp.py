"""Build a Car Scanner custom-PID profile from the Diagbox extraction.

    python make_csp.py --profile ../../data/diagbox/v46_21_profile.js \
        --out ../../out/custompids_v46_21_diagbox.csp

Only parameters that standard OBD-II does not already provide on this ECU are
emitted, so the profile complements the built-in PIDs instead of duplicating
them.

Car Scanner strips the two-byte positive-response header (`61 <lid>`) and then
exposes the payload as A, B, C ... AA, AB ... in the formula. Our byte offsets
are 0-based from the start of the whole answer, so payload letter index is
`offset - 1` (offset 2, the first payload byte, is A).
"""
import argparse
import json
import re

# Live pages worth polling as gauges. $C3 and $DB do not answer on this car,
# and $CF is a dealer service stamp rather than a live value.
PAGES = ('B0', 'C0', 'C1', 'C2', 'C4', 'CA', 'CB')

# Parameters a supported standard PID already covers on this ECU
# (its 0100 map is BE 3E B8 11, plus 0142 from the 0120 range).
STANDARD = {
    'REGIME_MOTEUR': '010C',
    'TENSION_ALIMENTATION_CALCULATEUR_CONTROLE_MOTEUR': '0142',
    'TEMPERATURE_D_EAU_MOTEUR_d': '0105',
    'TEMP_AIR_ADMISSION_SUP': '010F',
    'VITESSE_VEHICULE': '010D',
    'TENSION_SONDE_A_OXYGENE_AMONT': '0114',
    'TENSION_SONDE_A_OXYGENE_AVAL': '0115',
    'ANGLE_PAPILLON_MESURE': '0111',
    'AVANCE_ALLUMAGE_APPLIQUEE_A_CHAQUE_CYLINDRE': '010E',
    'PRESSIONTUBULURE': '010B',
}

# Confirmed absent on this car: the byte reads FF ("no data") in every sample
# of the recorded drive, so the electric vacuum pump is not fitted.
NOT_FITTED = {'ETAT_COMMANDE_POMPE_VIDE_ELECTRIQUE'}

# A working diagnostic set, chosen from the recorded drive rather than by
# taste. Parameters left out fall into three groups: never answered ($C3, $DB),
# always FF, or byte-identical to another one in every sample - this ECU sends
# the same value for all four injection times, for both mixture corrections,
# for optimal and maximum advance, for commanded and measured throttle angle,
# and for air torque and driver-demand torque.
CORE = [
    # Mixture, oxygen sensors, canister
    'TEMPS_INJECTION_CYLINDRE_01',
    'ETAT_SONDE_A_OXYGENE_AMONT',
    'ETAT_SONDE_A_OXYGENE_AVAL',
    'RCOAMONT',
    'RCOAVAL',
    'FACTEUR_CORRECTION_RICHESSE_AMONT',
    'CON_RICHESSE',
    'CHARGE_ESTIMEE_CANISTER',
    'CDERCOELECPURGE',
    # Ignition and knock
    'AVANCE_ALLUMAGE_OPTIMAL',
    'AVANCE_ALLUMAGE_MINIMUM',
    'RETRAIT_AVANCE_ALLUMAGE_CYLINDRE_01',
    'BRUIT_CAPTEUR_CLIQUETIS',
    # Intake and throttle
    'DEBIT_AIR',
    'DEBAIRCONS',
    'CONSIGNE_PRESSION_ADMISSION',
    'ANGLE_PAPILLON_CONSIGNE',
    'TENSION_RECOPIE_POSITION_PAPILLON_01',
    'TENSION_RECOPIE_POSITION_PAPILLON_02',
    # Inlet camshaft phaser
    'CONSIGNE_POSITION_DEPHASEUR_AAC_ADMISSION',
    'POS_DEPHASEUR_ACC_1',
    'RCO_ELECTROVANNE_DEPHASEUR_ACC_1',
    # Torque
    'COUPLE_MOTEUR_EFFECTIF_AIR',
    'COUPLE_MOTEUR_AVANCE',
    'COUPLE_RESISTANT_MOTEUR_ESTIME',
    # Supplies and sensors
    'TENSION_ALIMENTATION_CAPTEURS_01',
    'TENSION_ALIMENTATION_CAPTEURS_03',
    'PRESSION_HUILE_MOTEUR',
    # Vehicle systems
    'PRESSION_MASTERVAC',
    'PRESSION_CIRCUIT_REFRIGERANT_a',
    'REGMOTRALENTI',
    'NIVEAU_CARBURANT_AFFICHE',
]

# Three cheap reads on three different pages: enough to tell whether the
# transport works at all without loading a dashboard.
TEST = ['CHARGE_ESTIMEE_CANISTER', 'DEBIT_AIR', 'PRESSION_MASTERVAC']

# Tile names for the core set. Auto-shortening is fine for 85 rarely-used
# entries but these are the ones that end up on a dashboard.
CORE_NAMES = {
    'TEMPS_INJECTION_CYLINDRE_01': 'Впрыск',
    'ETAT_SONDE_A_OXYGENE_AMONT': 'Лямбда до кат.',
    'ETAT_SONDE_A_OXYGENE_AVAL': 'Лямбда после кат.',
    'RCOAMONT': 'Подогрев л. до кат.',
    'RCOAVAL': 'Подогрев л. после кат.',
    'FACTEUR_CORRECTION_RICHESSE_AMONT': 'Коррекция смеси',
    'CON_RICHESSE': 'Задание смеси',
    'CHARGE_ESTIMEE_CANISTER': 'Засорение адсорбера',
    'CDERCOELECPURGE': 'Клапан адсорбера',
    'AVANCE_ALLUMAGE_OPTIMAL': 'УОЗ оптимальный',
    'AVANCE_ALLUMAGE_MINIMUM': 'УОЗ минимальный',
    'RETRAIT_AVANCE_ALLUMAGE_CYLINDRE_01': 'Отмена УОЗ цил.1',
    'BRUIT_CAPTEUR_CLIQUETIS': 'Шум детонации',
    'DEBIT_AIR': 'Расход воздуха',
    'DEBAIRCONS': 'Расход возд. задание',
    'CONSIGNE_PRESSION_ADMISSION': 'Задание P впуска',
    'ANGLE_PAPILLON_CONSIGNE': 'Задание дросселя',
    'TENSION_RECOPIE_POSITION_PAPILLON_01': 'U дросселя 1',
    'TENSION_RECOPIE_POSITION_PAPILLON_02': 'U дросселя 2',
    'CONSIGNE_POSITION_DEPHASEUR_AAC_ADMISSION': 'Фазовр. задание',
    'POS_DEPHASEUR_ACC_1': 'Фазовр. факт',
    'RCO_ELECTROVANNE_DEPHASEUR_ACC_1': 'Клапан фазовр.',
    'COUPLE_MOTEUR_EFFECTIF_AIR': 'Момент по воздуху',
    'COUPLE_MOTEUR_AVANCE': 'Момент по УОЗ, факт',
    'COUPLE_RESISTANT_MOTEUR_ESTIME': 'Момент сопротивл.',
    'TENSION_ALIMENTATION_CAPTEURS_01': 'Питание датчиков 1',
    'TENSION_ALIMENTATION_CAPTEURS_03': 'Питание датчиков 3',
    'PRESSION_HUILE_MOTEUR': 'Давление масла',
    'PRESSION_MASTERVAC': 'Вакуум усилителя',
    'PRESSION_CIRCUIT_REFRIGERANT_a': 'P кондиционера',
    'REGMOTRALENTI': 'Задание Х.Х.',
    'NIVEAU_CARBURANT_AFFICHE': 'Уровень топлива',
}

# Run before each read. Two rules matter here:
#   * no ATCRA. A receive filter set for 688 stays set, so Car Scanner's next
#     standard PID waits for 7E8 and never sees it - which looks like the whole
#     app hanging, not like one custom PID failing.
#   * 81 opens the KWP session; without it the ECU answers nothing to 21xx.
# Flow control has to be forced for the multi-frame page replies, so it is put
# back to automatic afterwards for the same reason as the filter.
BEFORE = 'ATFCSH6A8;ATFCSD300000;ATFCSM1;81'
AFTER = 'ATFCSM0'

# Abbreviations, longest first. They shorten rather than delete, so a
# truncated name still says what it is.
SHORT = [
    ('регулятора фаз газораспределения впускного распредвала', 'фазовр. впуска'),
    ('механизма регулирования фаз газораспределения распредвала впускных клапанов', 'фазовр. впуска'),
    ('Опережение зажигания', 'УОЗ'), ('опережения зажигания', 'УОЗ'),
    ('кислородного датчика', 'лямбды'), ('лямбда-зонда', 'лямбды'),
    ('дроссельной заслонки', 'дросселя'), ('дроссельной заслонк', 'дросселя'),
    ('электровентилятора', 'вентил.'), ('вентилятора', 'вентил.'),
    ('педали акселератора', 'педали газа'),
    ('Крутящий момент', 'Момент'), ('крутящий момент', 'момент'),
    ('Температура', 'Т'), ('температура', 'Т'),
    ('Напряжение', 'U'), ('напряжение', 'U'),
    ('Давление', 'P'), ('давление', 'P'),
    ('Состояние', 'Сост.'), ('состояние', 'сост.'),
    ('Значение', 'Знач.'), ('значение', 'знач.'),
    ('Информация', 'Инф.'), ('информация', 'инф.'),
    ('регулирования', 'рег.'), ('регулирование', 'рег.'),
    ('двигателя', 'двиг.'), ('двигателем', 'двиг.'),
    ('цилиндре', 'цил.'), ('цилиндр', 'цил.'),
    ('Counter', 'Счётчик'), ('Счетчик', 'Счёт.'),
]


def letters(n):
    """1 -> A, 26 -> Z, 27 -> AA, 54 -> BB (spreadsheet column scheme)."""
    out = ''
    while n > 0:
        n, r = divmod(n - 1, 26)
        out = chr(65 + r) + out
    return out


def term(offset, length):
    """The formula term reading `length` bytes at `offset`, MSB first."""
    ls = [letters(offset - 1 + i) for i in range(length)]
    if length == 1:
        return ls[0], False
    parts = []
    for i, l in enumerate(ls):
        mul = 256 ** (length - 1 - i)
        parts.append('%s*%d' % (l, mul) if mul > 1 else l)
    return '+'.join(parts), True


def formula(f):
    expr, compound = term(f['o'], f['n'])
    z, d = f.get('z', 1.0), f.get('d', 0.0)
    if z != 1.0:
        expr = ('(%s)' % expr if compound else expr) + '*' + fmt(z)
        compound = True
    if d:
        expr = ('(%s)' % expr if compound and z != 1.0 else expr)
        expr += ('+' + fmt(d)) if d > 0 else ('-' + fmt(-d))
    return expr


def fmt(v):
    s = ('%.10f' % v).rstrip('0').rstrip('.') if abs(v) < 1 else ('%g' % v)
    return s or '0'


def abbrev(label):
    s = label
    for a, b in SHORT:
        s = s.replace(a, b)
    return re.sub(r'\s+', ' ', s).strip(' ,')


def short_name(label, limit=22):
    """A tile-sized name. Cut on a word boundary unless that throws most of
    the name away, in which case cut hard and mark it."""
    s = abbrev(label)
    if len(s) <= limit:
        return s
    cut = s[:limit].rsplit(' ', 1)[0].strip(' ,')
    return cut if len(cut) >= limit - 10 else s[:limit - 1].strip() + '…'


def unique_names(entries):
    """Car Scanner shows the short name on the tile, so two gauges must not
    read the same. Where truncation collides, keep the head and the tail -
    these labels differ at the end ('...by air' vs '...by advance')."""
    by = {}
    for e in entries:
        by.setdefault(e['SNM'], []).append(e)
    for name, group in by.items():
        if len(group) < 2:
            continue
        for e in group:
            s = abbrev(e['_label'])
            head = s[:12].rsplit(' ', 1)[0]
            if len(head) < 8:
                head = s[:12].strip()
            e['SNM'] = (head + '…' + s[-11:].lstrip(' ,')).strip()
    seen = {}
    for e in entries:
        n = e['SNM']
        if n in seen:
            seen[n] += 1
            e['SNM'] = '%s %d' % (n[:20], seen[n])
        else:
            seen[n] = 1
    for e in entries:
        e.pop('_label', None)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--profile', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--core', action='store_true',
                    help='emit only the working diagnostic set')
    ap.add_argument('--test', action='store_true',
                    help='emit three PIDs, one per page, to prove the setup')
    a = ap.parse_args()

    txt = open(a.profile, encoding='utf-8').read()
    prof = json.loads(txt.split('= ', 1)[1].strip().rstrip(';'))

    out, skipped_std, skipped_bits, pid = [], [], [], 2001
    for pg in prof['pages']:
        if pg['id'] not in PAGES:
            continue
        for f in pg['params']:
            if f['k'] in NOT_FITTED:
                continue
            if a.test and f['k'] not in TEST:
                continue
            if a.core and not a.test and f['k'] not in CORE:
                continue
            if f['k'] in STANDARD:
                skipped_std.append(f['k'])
                continue
            if 'm' in f:
                # Bit-addressed; Car Scanner's expression support for masks
                # varies by version, so leave these out rather than ship a
                # formula that may not evaluate.
                skipped_bits.append(f['k'])
                continue
            unit = f.get('u') or ''
            states = f.get('st') or {}
            name = f['l']
            if unit:
                name += ', ' + unit
            if states:
                legend = ', '.join('%s=%s' % (k, v)
                                   for k, v in sorted(states.items(),
                                                      key=lambda kv: int(kv[0])))
                name += ' (' + legend + ')'
            lo, hi = f.get('lo', 0.0), f.get('hi', 255.0)
            if states:
                lo, hi = 0.0, float(max(int(k) for k in states))
            out.append({
                'CMD': '21' + pg['id'], 'SBI': 0, 'DL': 1,
                'MUL': 1.0, 'DIV': 1.0, 'OFS': 0.0,
                'SIG': False, 'TP': 0, 'BIT': 0,
                'FHID': False, 'RBS': False, 'ORD': -1, 'TVV': None,
                'FR': formula(f), 'UN': 0,
                'BCM': BEFORE, 'ACM': AFTER, 'ACT': False, 'TRNS': [],
                'NM': name,
                'SNM': CORE_NAMES.get(f['k']) or short_name(f['l']),
                '_label': f['l'],
                'HDR': '6A8', 'RL': 0,
                'MAX': float(hi), 'MIN': float(lo),
                'Id': pid, 'VIS': True, 'SkipCycles': 0, 'ABRPRole': 0,
            })
            pid += 1

    unique_names(out)
    with open(a.out, 'w', encoding='utf-8') as fh:
        json.dump(out, fh, ensure_ascii=False, indent=1)
        fh.write('\n')
    print('%d PIDs -> %s' % (len(out), a.out))
    print('  skipped, covered by standard OBD (%d): %s'
          % (len(skipped_std), ', '.join(sorted(skipped_std))))
    if skipped_bits:
        print('  skipped, bit-addressed (%d): %s'
              % (len(skipped_bits), ', '.join(skipped_bits)))


if __name__ == '__main__':
    main()
