#!/usr/bin/env python3
"""
gen_csp.py - generate a Car Scanner custom-PID (.csp) file for V46.21 proprietary params.

Uses the plain 21CX request form (Car Scanner strips SID+1 PID byte -> letter A = byte2),
with the FAP-calibrated byte offsets/formulas (payload from byte2 is identical between the
plain 21CX and FAP's 21CX8001 forms; corroborated by RPM/Coolant/Battery matching).

offset o (0-indexed from response byte0=0x61) -> Car Scanner letter index (o-1); A=byte2.
"""
import json

def L(k):  # 1-based letter index -> Car Scanner column letter (A,B,..,Z,AA,AB,..)
    s = ""
    while k > 0:
        k -= 1
        s = chr(65 + k % 26) + s
        k //= 26
    return s

def fmt_scale(s):
    if s == 1: return None
    if s == 7.53e-6: return "0.00000753"
    return ("%g" % s)

def fr(off, width, scale, add):
    base = L(off - 1) if width == 1 else "(%s*256+%s)" % (L(off - 1), L(off))
    sc = fmt_scale(scale)
    expr = base if sc is None else "%s*%s" % (base, sc)
    if add:
        expr = "%s%s" % (expr, ("+%g" % add) if add > 0 else ("%g" % add))
    return expr

# (SNM, NM_ru, unit, cmd, offset, width, scale, add, min, max, bool)
# Names aligned to standard OBD-II wording where an equivalent exists (2026-08-28).
PIDS = [
 ("Обороты",      "Обороты двигателя",              "об/мин", "21CB", 2, 2, 1,      0,    0, 7000, False),
 ("Скорость",     "Скорость",                       "км/ч",   "21CA", 8, 1, 1,      0,    0,  255, False),
 ("Т ОЖ",         "Темп. ОЖ",                       "°C",     "21CB", 6, 1, 1,    -50,  -50,  130, False),
 ("Т впуска",     "Темп. впуск. воздуха",           "°C",     "21C2", 5, 1, 1,    -50,  -50,  120, False),
 ("Т наружн",     "Темп. наружного воздуха",        "°C",     "21CB",40, 1, 1,    -40,  -40,   60, False),
 ("U ЭБУ",        "Напряжение ЭБУ",                 "В",      "21CB", 4, 1, 0.1,    0,    0,   16, False),
 ("P атм",        "Атм. давление",                  "мбар",   "21CB",56, 1, 1,    756,  600, 1100, False),
 ("Педаль газа",  "Педаль газа",                    "%",      "21CA",13, 2, 0.1,    0,    0,  100, False),
 ("Впрыск 1",     "Форсунка 1",                     "мс",     "21C0", 6, 2, 0.01,   0,    0,   25, False),
 ("Впрыск 2",     "Форсунка 2",                     "мс",     "21C0", 8, 2, 0.01,   0,    0,   25, False),
 ("Впрыск 3",     "Форсунка 3",                     "мс",     "21C0",10, 2, 0.01,   0,    0,   25, False),
 ("Впрыск 4",     "Форсунка 4",                     "мс",     "21C0",12, 2, 0.01,   0,    0,   25, False),
 ("УОЗ",          "Опережение зажигания",           "°",      "21C1",12, 1, 1,   -100,  -30,   60, False),
 ("Нагрев B1S1",  "Подогрев лямбда B1S1",           "%",      "21C0",38, 2, 0.1,    0,    0,  100, False),
 ("Нагрев B1S2",  "Подогрев лямбда B1S2",           "%",      "21C0",42, 2, 0.1,    0,    0,  100, False),
 ("Лямбда B1S1",  "Лямбда B1S1",                    "мВ",     "21C0",26, 2, 1,      0,    0, 1100, False),
 ("Лямбда B1S2",  "Лямбда B1S2",                    "мВ",     "21C0",34, 2, 1,      0,    0, 1100, False),
 ("Адсорбер",     "Клапан адсорбера",               "%",      "21C0",57, 1, 1,      0,    0,  100, False),
 ("Корр.смеси 1", "Коррекция смеси B1S1",           "",       "21C0",46, 2, 7.53e-6,-0.246,-0.3,0.3, False),
 ("Корр.смеси 2", "Коррекция смеси B1S2",           "",       "21C0",50, 2, 7.53e-6,-0.246,-0.3,0.3, False),
 ("Расход возд",  "Массовый расход воздуха",        "кг/ч",   "21C2",11, 2, 0.1,    0,    0,  600, False),
 ("Расход зад",   "Расход воздуха (задание)",       "кг/ч",   "21C2",51, 2, 0.1,    0,    0,  600, False),
 ("P впуск",      "Давл. во впуске (MAP)",          "мбар",   "21C2",14, 2, 0.08,   0,    0, 3000, False),
 ("P впуск зад",  "Давл. во впуске (задание)",      "мбар",   "21C2",13, 2, 0.08,   0,    0, 3000, False),
 ("Фаза зад",     "Угол фазовращателя (задание)",   "°",      "21C2",21, 1, 1,   -100,  -20,   60, False),
 ("Фаза факт",    "Угол фазовращателя (факт)",      "°",      "21C2",23, 1, 1,   -100,  -20,   60, False),
 ("Клапан фазы",  "Клапан фазовращателя",           "%",      "21C2",25, 1, 1,      0,    0,  100, False),
 ("Детонация",    "Датчик детонации",               "мВ",     "21CB",43, 2, 0.1,    0,    0, 5000, False),
 ("P хладаг",     "Давл. хладагента (кондиц.)",     "бар",    "21CB",22, 1, 0.1,    0,    0,   30, False),
 ("Вентилятор",   "Вентилятор охлаждения",          "%",      "21CB",12, 1, 1,      0,    0,  100, False),
 ("Тормоз",       "Педаль тормоза",                 "",       "21CA",23, 1, 1,      0,    0,    1, True),
 ("Сцепление",    "Педаль сцепления",               "",       "21CA",24, 1, 1,      0,    0,    1, True),
 ("Топливо",      "Уровень топлива",                "л",      "21CA",35, 1, 1,      0,    0,   80, False),
]

BCM = "ATCRA688;ATFCSH6A8;ATFCSD300000;ATFCSM1;81"
out = []
for i, (snm, nm, unit, cmd, off, w, sc, add, mn, mx, isbool) in enumerate(PIDS):
    name = nm + (", " + unit if unit else "")
    out.append({
        "CMD": cmd, "SBI": 0, "DL": 1, "MUL": 1.0, "DIV": 1.0, "OFS": 0.0,
        "SIG": False, "TP": 0, "BIT": 0, "FHID": False, "RBS": False, "ORD": -1,
        "TVV": None, "FR": fr(off, w, sc, add), "UN": 0, "BCM": BCM, "ACM": "",
        "ACT": False, "TRNS": [], "NM": name, "SNM": snm, "HDR": "6A8", "RL": 0,
        "MAX": float(mx), "MIN": float(mn), "Id": 1001 + i, "VIS": True,
        "SkipCycles": 0, "ABRPRole": 0,
    })

path = r"C:\_CAR_APP\out\custompids_v46_21_can.csp"
with open(path, "w", encoding="utf-8") as f:
    json.dump(out, f, ensure_ascii=False, indent=1)
print(f"wrote {len(out)} PIDs (full) -> {path}")

# Car Scanner already reads standard OBD PIDs natively — emit a UNIQUE-only profile that
# drops the proprietary params duplicating a native standard sensor, so nothing doubles up.
DUP = {"Обороты", "Скорость", "Т ОЖ", "Т впуска", "U ЭБУ", "P атм",
       "УОЗ", "P впуск", "Лямбда B1S1", "Лямбда B1S2"}   # by SNM
uniq = [p for p in out if p["SNM"] not in DUP]
path2 = r"C:\_CAR_APP\out\custompids_v46_21_unique.csp"
with open(path2, "w", encoding="utf-8") as f:
    json.dump(uniq, f, ensure_ascii=False, indent=1)
print(f"wrote {len(uniq)} PIDs (unique, no standard dups) -> {path2}")
print("  dropped as native-standard duplicates: " + ", ".join(sorted(DUP)))
