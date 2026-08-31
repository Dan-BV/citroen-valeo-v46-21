"""Set up a working copy of the Diagbox databases plus a Firebird engine.

Diagbox 9.x stores its diagnostic model in Firebird 2.5 databases (ODS 11.2).
The Firebird that ships with Diagbox is a 32-bit 2.1 build, which cannot open
them from 64-bit Python, so this script fetches the official 2.5.9 x64
embedded package once and copies the databases out of the installation.

    python prepare.py --diagbox C:/AWRoot --work ./work

Nothing is written back into the Diagbox installation.
"""
import argparse
import os
import shutil
import sys
import urllib.request
import zipfile

FB_URL = ('https://github.com/FirebirdSQL/firebird/releases/download/R2_5_9/'
          'Firebird-2.5.9.27139-0_x64_embed.zip')

# Only the databases the extractors actually read.
DBS = [
    'dtrd/comm/data/GPC.FDB',     # ECUs, screens, DTCs, tests, telecoding
    'dtrd/comm/data/DSD.FDB',     # services, frames, byte maps, formulas
    'dtrd/database/DLPR.FDB',     # parameter mnemonics
    'dtrd/database/RTODX.FDB',    # vehicle/ECU -> ODX id
]


def fetch_firebird(dest):
    if os.path.exists(os.path.join(dest, 'fbembed.dll')):
        print('firebird: already present in %s' % dest)
        return
    os.makedirs(dest, exist_ok=True)
    zpath = os.path.join(dest, 'fb25.zip')
    print('firebird: downloading %s' % FB_URL)
    urllib.request.urlretrieve(FB_URL, zpath)
    with zipfile.ZipFile(zpath) as z:
        z.extractall(dest)
    os.remove(zpath)
    print('firebird: unpacked into %s' % dest)


def copy_dbs(diagbox, work):
    os.makedirs(work, exist_ok=True)
    for rel in DBS:
        src = os.path.join(diagbox, *rel.split('/'))
        if not os.path.exists(src):
            print('missing (skipped): %s' % src)
            continue
        dst = os.path.join(work, os.path.basename(rel))
        if os.path.exists(dst) and os.path.getsize(dst) == \
                os.path.getsize(src):
            print('%-12s already copied' % os.path.basename(rel))
            continue
        print('%-12s %6.1f MB ...' % (os.path.basename(rel),
                                      os.path.getsize(src) / 1e6))
        shutil.copy2(src, dst)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--diagbox', default='C:/AWRoot',
                    help='Diagbox AWRoot directory')
    ap.add_argument('--work', default='./work',
                    help='where to put the database copies')
    ap.add_argument('--fbdir', default='./fb25',
                    help='where to put the Firebird 2.5 x64 embedded engine')
    a = ap.parse_args()

    if not os.path.isdir(a.diagbox):
        sys.exit('Diagbox not found at %s' % a.diagbox)
    try:
        import fdb  # noqa: F401
    except ImportError:
        sys.exit('missing dependency: pip install fdb')

    fetch_firebird(a.fbdir)
    copy_dbs(a.diagbox, a.work)
    trans = os.path.join(a.diagbox, 'dtrd', 'trans')
    print('\nready. Next:')
    print('  python extract_ecu.py --ecu V46_21 --work %s --fbdir %s '
          '--trans %s --out ../../data/diagbox' % (a.work, a.fbdir, trans))


if __name__ == '__main__':
    main()
