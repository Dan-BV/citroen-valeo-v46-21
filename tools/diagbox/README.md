# Diagbox data extraction

Pulls the diagnostic model out of a local Diagbox 9.x installation and turns it
into JSON plus Markdown references. Read-only: the installation is copied, never
modified, and nothing here talks to a car.

## Where the data lives

| File | Content |
|---|---|
| `AWRoot/dtrd/comm/data/GPC.FDB` | ECUs, CAN addressing, screens, DTCs, actuator tests, telecoding screens |
| `AWRoot/dtrd/comm/data/DSD.FDB` | Diagnostic services, request/response frames, byte positions, scaling, enums |
| `AWRoot/dtrd/trans/POLUX*<lang>.DU8` | String dictionaries for every label, in 26 languages |
| `AWRoot/dtrd/comm/Cal<n>.dll` | Per-ECU communication library (holds the security-access algorithm) |

Both `.FDB` files are Firebird 2.5 databases (ODS 11.2). The Firebird bundled
with Diagbox is a 32-bit 2.1 build and cannot open them from 64-bit Python, so
`prepare.py` fetches the official 2.5.9 x64 embedded engine.

`.DU8` dictionaries are a flat string table: `u32` magic, `u32` table offset,
`u32` data offset, `u32` count, then `count` absolute offsets of NUL-terminated
UTF-8 strings. References like `@P7917-POLUXDATA` are **1-based**, so id `N` is
entry `N-1`. `@T...` segments are literal text and `@\*...` segments are the
arguments that fill the `*1`, `*2` slots inside a sentence.

## Use

```bash
pip install fdb
python prepare.py --diagbox C:/AWRoot --work ./work --fbdir ./fb25
python extract_ecu.py --ecu V46_21 --work ./work --fbdir ./fb25 \
    --trans C:/AWRoot/dtrd/trans --out ../../data/diagbox
python extract_vehicle.py --platform B7 --work ./work --fbdir ./fb25 \
    --trans C:/AWRoot/dtrd/trans --out ../../data/diagbox/vehicle_B7.json
python make_docs.py --ecu-json ../../data/diagbox/V46_21_B7.json \
    --vehicle-json ../../data/diagbox/vehicle_B7.json --out ../../out
```

`extract_ecu.py` writes one file per vehicle platform the ECU is fitted to.
Any ECU name from `GPC.ECUTYPE.ECUNAME` works — `BSI2010`, `ESP90`,
`COMBINE_UDS`, `EDC17C10_BR2` and so on — so the same pipeline covers every
module on the car, not just the engine.

## Checking the result against a real car

`decode.py` replays a recorded ELM transcript through the extracted byte map:

```bash
python decode.py --ecu-json ../../data/diagbox/V46_21_B7.json \
    --transcript ../btsnoop/data/transcript_2026-08-27.json
```

It is also importable: `decode_page(doc, 'CB', '61FF04...')` returns the named
values for one answer.

## Files

- `dbxlib.py` - `.DU8` dictionary reader, thesaurus resolver, Firebird helper
- `prepare.py` - fetch Firebird, copy the databases
- `extract_ecu.py` - full model of one ECU
- `extract_vehicle.py` - ECU inventory of one platform, for scanning
- `make_docs.py` - Markdown references
- `decode.py` - decode live or recorded answers
