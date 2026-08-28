#!/usr/bin/env python3
"""
calibrate.py — solve byte offset + linear formula for each FAP parameter by aligning
the ELM transcript (from parse_btsnoop.py) with the FAP CSV export, then verifying the
known calibration.

Two modes:
  verify   (default): check the known mapping (KNOWN_CALIB) reproduces the CSV -> R^2, MAE.
  discover           : brute-force search page/offset/width/endian/sign for each CSV column
                       (use this on a NEW drive to solve the still-unknown params).

Requires numpy:  python -m pip install numpy

Usage:
  python calibrate.py <transcript.json> <fap_export.csv> [verify|discover]

CSV format (FAP export): ';'-separated, '.' decimals, cols Date;Time;<params...>.
Alignment: btsnoop clock == FAP local clock; a small offset is auto-found via RPM correlation.
Fit is done at the ELM response timestamps (CSV interpolated to them, gaps >1s excluded).

Full method & results table: ../../out/fap_calib_from_btsnoop.md
"""
import sys, json, re
from datetime import datetime, timezone
try:
    import numpy as np
except ImportError:
    raise SystemExit("needs numpy:  python -m pip install numpy")

PAGES = ['21CA8001', '21C08001', '21CB8001', '21C18001', '21C28001']
PLEN  = {'21CA8001': 0x2B, '21C08001': 0x48, '21CB8001': 0x3B, '21C18001': 0x20, '21C28001': 0x48}

# Known mapping recovered 2026-08-27 (see out/fap_calib_from_btsnoop.md).
# tuple: (param_csv_name, page, byte_offset, width, endian, scale, add)
KNOWN_CALIB = [
    ('Revs','21CB8001',2,2,'be',1,0), ('Speed','21CA8001',8,1,'be',1,0),
    ('Coolant','21CB8001',6,1,'be',1,-50), ('AirManifold','21C28001',5,1,'be',1,-50),
    ('ExternalTemp','21CB8001',40,1,'be',1,-40), ('Battery','21CB8001',4,1,'be',0.1,0),
    ('AtmosphPress','21CB8001',56,1,'be',1,756), ('AccelPedalPos','21CA8001',13,2,'be',0.1,0),
    ('Inj.1Time','21C08001',6,2,'be',0.01,0), ('Inj.2Time','21C08001',8,2,'be',0.01,0),
    ('Inj.3Time','21C08001',10,2,'be',0.01,0), ('Inj.4Time','21C08001',12,2,'be',0.01,0),
    ('Cyl.Adv','21C18001',12,1,'be',1,-100), ('UpO2Heat','21C08001',38,2,'be',0.1,0),
    ('DownO2Heat','21C08001',42,2,'be',0.1,0), ('UpO2Volt','21C08001',26,2,'be',1,0),
    ('DownO2Volt','21C08001',34,2,'be',1,0), ('CanisterValve','21C08001',57,1,'be',1,0),
    ('UpMixCorr','21C08001',46,2,'be',7.53e-6,-0.246), ('DownMixCorr','21C08001',50,2,'be',7.53e-6,-0.246),
    ('AirFlow','21C28001',11,2,'be',0.1,0), ('AirFlowInstr','21C28001',51,2,'be',0.1,0),
    ('IntakeAirPress','21C28001',14,2,'be',0.08,0), ('IntakeAirPressInstr','21C28001',13,2,'be',0.08,0),
    ('InCamDephaserInstr','21C28001',21,1,'be',1,-100), ('InCamDephaser','21C28001',23,1,'be',1,-100),
    ('InCamDephaserValve','21C28001',25,1,'be',1,0), ('KnockSensor','21CB8001',43,2,'be',0.1,0),
    ('AirCPress','21CB8001',22,1,'be',0.1,0), ('BR','21CA8001',23,1,'be',1,0), ('CL','21CA8001',24,1,'be',1,0),
    ('FanSpeed','21CB8001',12,1,'be',1,0), ('FuelLevel','21CA8001',35,1,'be',1,0),
]
# Params still unsolved (constant/low-variance in the 2026-08-27 drive) -> run 'discover' on a
# targeted drive (AC on, brake presses, load): Cyl.1-4AdvCorr, Gear, Errors, FanSpeed, FuelLevel, BrakePress.

def load_csv(path):
    raw = open(path, encoding='latin1').read().splitlines()
    header, rows = None, []
    for ln in raw:
        if not ln.strip():
            continue
        p = ln.rstrip(';').split(';')
        if p[0] == 'Date':
            header = p; continue
        if header is None or len(p) < len(header):
            continue
        rows.append(p)
    def epoch(ds, ts):
        d = ds.split('.'); t = ts.split(':'); s = float(t[2])
        return datetime(int(d[0]), int(d[1]), int(d[2]), int(t[0]), int(t[1]),
                        int(s), int((s % 1) * 1e6), tzinfo=timezone.utc).timestamp()
    csv_t = np.array([epoch(r[0], r[1]) for r in rows])
    def pv(s):
        s = s.strip()
        if s in ('-', '', '---'): return np.nan
        try: return float(s)
        except: return np.nan
    data = {c: np.array([pv(r[i]) for r in rows]) for i, c in enumerate(header) if i >= 2}
    return csv_t, data

def load_pages(transcript):
    tr = json.load(open(transcript))
    pd = {p: {'t': [], 'b': []} for p in PAGES}
    for e in tr:
        c = e['cmd']
        if c in PAGES and len(e['hex']) // 2 == PLEN[c]:
            pd[c]['t'].append(e['t'])
            pd[c]['b'].append([int(e['hex'][i:i + 2], 16) for i in range(0, len(e['hex']), 2)])
    for p in PAGES:
        pd[p]['t'] = np.array(pd[p]['t'])
        pd[p]['b'] = np.array(pd[p]['b'], dtype=np.int64)
    return pd

def find_delta(pd, csv_t, revs):
    """global clock offset (CSV vs snoop) via RPM correlation on 21C2 o2 u16be."""
    p2 = pd['21C28001']
    rpm = p2['b'][:, 2] * 256 + p2['b'][:, 3]
    best = (None, 0)
    for d in np.arange(-3, 3, 0.02):
        y = interp(revs, csv_t, p2['t'] + d)
        m = np.isfinite(y)
        if m.sum() < 100: continue
        c = np.corrcoef(rpm[m], y[m])[0, 1]
        if best[0] is None or c > best[0]:
            best = (c, d)
    return best[1], best[0]

def interp(y, csv_t, times):
    good = np.isfinite(y); xt = csv_t[good]; yv = y[good]
    if len(xt) < 5: return np.full(len(times), np.nan)
    out = np.interp(times, xt, yv, left=np.nan, right=np.nan)
    idx = np.clip(np.searchsorted(xt, times), 1, len(xt) - 1)
    gap = np.minimum(np.abs(xt[idx] - times), np.abs(xt[idx - 1] - times))
    out[gap > 1.0] = np.nan
    return out

def rawv(pd, page, off, w, endian):
    B = pd[page]['b']
    if w == 1: return B[:, off].astype(float)
    hi = B[:, off].astype(float); lo = B[:, off + 1].astype(float)
    return hi * 256 + lo if endian == 'be' else lo * 256 + hi

def r2mae(pd, csv_t, data, param, page, off, w, endian, scale, add, delta):
    if param not in data: return None
    x = rawv(pd, page, off, w, endian); y = interp(data[param], csv_t, pd[page]['t'] + delta)
    pred = x * scale + add
    m = np.isfinite(x) & np.isfinite(y)
    if m.sum() < 30: return None
    ss = np.sum((y[m] - y[m].mean()) ** 2)
    r2 = 1 - np.sum((y[m] - pred[m]) ** 2) / ss if ss > 0 else float('nan')
    return r2, np.mean(np.abs(y[m] - pred[m])), m.sum()

def do_verify(pd, csv_t, data, delta):
    print(f"{'param':22}{'page':9}{'off':>4}{'w':>2}{'formula':>22}{'R2':>9}{'MAE':>10}")
    ok = 0
    for name, page, off, w, en, sc, ad in KNOWN_CALIB:
        r = r2mae(pd, csv_t, data, name, page, off, w, en, sc, ad, delta)
        if r is None:
            print(f"{name:22} (not in this CSV)"); continue
        r2, mae, n = r
        f = ('raw' if sc == 1 else f'{sc:g}*raw') + (f'{ad:+g}' if ad else '')
        print(f"{name:22}{page.replace('8001',''):9}{off:>4}{w:>2}{f:>22}{r2:>9.4f}{mae:>10.3g}")
        if r2 >= 0.97: ok += 1
    print(f"\nR2>=0.97: {ok}/{len(KNOWN_CALIB)}  (low-R2 params are near-constant in this drive, not wrong)")

def do_discover(pd, csv_t, data, delta):
    """Brute-force best (page,offset,width,endian,sign) per CSV column. Use on a new drive."""
    def cands(B):
        n = B.shape[1]; out = []
        for o in range(n):
            col = B[:, o].astype(float)
            out.append((f'{o}.u8', col, 'x')); out.append((f'{o}.s8', np.where(col > 127, col - 256, col), 'x'))
        for o in range(n - 1):
            hi = B[:, o].astype(float); lo = B[:, o + 1].astype(float)
            be = hi * 256 + lo; le = lo * 256 + hi
            out += [(f'{o}.u16be', be, 'x'), (f'{o}.u16le', le, 'x'),
                    (f'{o}.s16be', np.where(be > 32767, be - 65536, be), 'x'),
                    (f'{o}.s16le', np.where(le > 32767, le - 65536, le), 'x')]
        return out
    def fit(y, x):
        m = np.isfinite(x) & np.isfinite(y)
        if m.sum() < 50 or np.std(x[m]) < 1e-9 or np.std(y[m]) < 1e-9: return None
        A = np.vstack([x[m], np.ones(m.sum())]).T
        (a, b), *_ = np.linalg.lstsq(A, y[m], rcond=None)
        pred = a * x[m] + b
        return a, b, 1 - np.sum((y[m] - pred) ** 2) / np.sum((y[m] - y[m].mean()) ** 2), m.sum()
    print(f"{'param':22}{'R2':>8}  page.off.fmt          formula")
    for name, y in sorted(data.items()):
        yfin = np.isfinite(y)
        if yfin.sum() < 30 or np.nanstd(y[yfin]) < 1e-9:
            print(f"{name:22}  constant/empty in this drive"); continue
        best = None
        for p in PAGES:
            yt = interp(y, csv_t, pd[p]['t'] + delta)
            for cn, x, _ in cands(pd[p]['b']):
                r = fit(yt, x)
                if r and (best is None or r[2] > best[0]):
                    best = (r[2], p, cn, r[0], r[1], r[3])
        if best:
            r2, p, cn, a, b, n = best
            print(f"{name:22}{r2:8.4f}  {p.replace('8001','')}.{cn:12} y={a:.6g}*raw{b:+.5g}")

def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    transcript, csvpath = sys.argv[1], sys.argv[2]
    mode = sys.argv[3] if len(sys.argv) > 3 else 'verify'
    csv_t, data = load_csv(csvpath)
    pd = load_pages(transcript)
    for p in PAGES:
        print(f"[page] {p}: {len(pd[p]['t'])} responses")
    if 'Revs' not in data:
        raise SystemExit("CSV has no 'Revs' column - cannot auto-align clock")
    delta, corr = find_delta(pd, csv_t, data['Revs'])
    print(f"[align] clock offset {delta:+.3f}s (RPM corr {corr:.4f})\n")
    (do_discover if mode == 'discover' else do_verify)(pd, csv_t, data, delta)

if __name__ == '__main__':
    main()
