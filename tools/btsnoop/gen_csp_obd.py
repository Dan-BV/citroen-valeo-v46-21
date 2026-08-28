#!/usr/bin/env python3
"""
gen_csp_obd.py - supplementary Car Scanner .csp with standard OBD-II mode-01 PIDs
(torque / load / extra) that Car Scanner may not surface natively on this ECU.

Standard mode-01: request 01XX to engine (HDR 7E0), response "41 XX <data>" from 7E8.
Car Scanner strips "41XX" (2 bytes) -> letter A = first data byte. Same o->letter(o-1) rule.
These are standard formulas (no calibration). Any unsupported PID just returns NO DATA.
"""
import json, os
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))  # repo root

def L(k):
    s = ""
    while k > 0:
        k -= 1; s = chr(65 + k % 26) + s; k //= 26
    return s

def fr(width, formula_kind):
    A, B = L(1), L(2)  # first data byte = A (offset 2), second = B
    return {
        "A-125":   "%s-125" % A,
        "A256B":   "(%s*256+%s)" % (A, B),
        "loadabs": "(%s*256+%s)*0.392157" % (A, B),
        "A-40":    "%s-40" % A,
        "rate":    "(%s*256+%s)/20" % (A, B),
        "A":       A,
    }[formula_kind]

# (SNM, NM_ru, unit, cmd, width, kind, min, max)
PIDS = [
 ("Момент факт",  "Момент двигателя (фактический)",      "%",   "0162", 1, "A-125",  -100, 100),
 ("Момент запрос","Момент двигателя (запрос водителя)",  "%",   "0161", 1, "A-125",  -100, 100),
 ("Опорн. момент","Опорный момент двигателя",            "Нм",  "0163", 2, "A256B",     0, 1000),
 ("Абс. нагрузка","Абсолютная нагрузка двигателя",       "%",   "0143", 2, "loadabs",   0,  255),
 ("Т масла",      "Температура масла двигателя",          "°C",  "015C", 1, "A-40",    -40,  200),
 ("Расход топл",  "Расход топлива",                       "л/ч", "015E", 2, "rate",      0,  100),
 ("P атм (OBD)",  "Атмосферное давление (OBD)",           "кПа", "0133", 1, "A",         0,  255),
 ("Время работы", "Время работы двигателя",               "с",   "011F", 2, "A256B",     0, 65535),
]

BCM = "ATCRA7E8"   # accept engine ECU responses (7E8); HDR sends 01XX to 7E0
out = []
for i, (snm, nm, unit, cmd, w, kind, mn, mx) in enumerate(PIDS):
    out.append({
        "CMD": cmd, "SBI": 0, "DL": 1, "MUL": 1.0, "DIV": 1.0, "OFS": 0.0,
        "SIG": False, "TP": 0, "BIT": 0, "FHID": False, "RBS": False, "ORD": -1,
        "TVV": None, "FR": fr(w, kind), "UN": 0, "BCM": BCM, "ACM": "",
        "ACT": False, "TRNS": [], "NM": nm + ", " + unit, "SNM": snm, "HDR": "7E0",
        "RL": 0, "MAX": float(mx), "MIN": float(mn), "Id": 2001 + i, "VIS": True,
        "SkipCycles": 0, "ABRPRole": 0,
    })

path = os.path.join(ROOT, "out", "custompids_obd_standard.csp")
with open(path, "w", encoding="utf-8") as f:
    json.dump(out, f, ensure_ascii=False, indent=1)
print(f"wrote {len(out)} PIDs -> {path}")
for p in out:
    print(f"  {p['CMD']} HDR={p['HDR']} FR={p['FR']:<22} {p['NM']}")
