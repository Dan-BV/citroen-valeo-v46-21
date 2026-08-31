# How the Diagbox diagnostic model was extracted

Written up so the same pipeline can be pointed at any other ECU or vehicle,
and so the results below can be checked rather than trusted.

Source: a local Diagbox 9.85 installation (data version 2006.02 build 1003,
runtime 06.39.06). Everything is read from copies; the installation is never
written to, and no part of this talks to a car.

## 1. Where Diagbox keeps its knowledge

Diagbox spreads itself over `C:\AWRoot` (runtime + data), `C:\APP` and
`C:\APPLIC` (the older Lexia application). Almost everything useful is under
`AWRoot\dtrd`:

| Path | What it is |
|---|---|
| `dtrd\comm\data\GPC.FDB` | 484 MB. ECUs, CAN addressing, screens, 201k DTCs, actuator tests, telecoding screens, connector pinouts |
| `dtrd\comm\data\DSD.FDB` | 380 MB. The ODX-style model: services, request/response frames, byte positions, lengths, scaling, enumerations |
| `dtrd\database\DLPR.FDB` | Parameter mnemonics per ECU family |
| `dtrd\database\RTODX.FDB` | vehicle + ECU + version to ODX id |
| `dtrd\trans\*.DU8` | String dictionaries; every label in the UI is a reference into these |
| `dtrd\comm\Cal<n>.dll` | One communication library per ECU family; holds the security-access key algorithm |
| `dtrd\comm\XMLTLCD\*.xml` | 471 telecoding definition files |
| `dtrd\tree\**\*.s` | The diagnostic decision trees, as XML |

The other `.FDB` files are less interesting: `MEASURE.FDB` is oscilloscope
setups, `PORTAL.FDB` the vehicle menu, `BASEMOTR.FDB` licensing and country
data.

## 2. Opening the databases

Both big databases are Firebird with ODS 11.2, that is Firebird 2.5. Diagbox
ships two Firebird builds and neither is directly usable from 64-bit Python:

- `C:\APP\firebird` is Firebird 2.1 (ODS 11.1). It refuses ODS 11.2 with
  `unsupported on-disk structure`.
- `C:\AWRoot\bin\lib\firebird250\fbclient.dll` is Firebird 2.5, but 32-bit -
  it is actually `fbembed.dll` renamed (3.7 MB, far larger than a real client).

The fix is the official Firebird 2.5.9 **x64 embedded** package plus the pure
Python `fdb` driver. `tools/diagbox/prepare.py` downloads it. Credentials are
the Firebird defaults, `SYSDBA` / `masterkey`.

## 3. The `.DU8` string dictionaries

Every label in `GPC.FDB` is a reference such as `@P7917-POLUXDATA`, not text.
The dictionaries live in `dtrd\trans` as `<BOOK><lang>.DU8`, 26 languages,
`POLUXDATA` being the big one (57 077 strings).

Format, little-endian:

```
u32  magic          0x23142314
u32  table_offset   always 100
u32  data_offset    end of the offset table
u32  count          number of entries
u32  offsets[count] absolute file offsets of NUL-terminated UTF-8 strings
```

References are **1-based**: `@P7917` is `offsets[7916]`. Getting this wrong by
one returns a plausible but completely unrelated sentence, which is the easiest
way to produce confident nonsense here.

A field may concatenate several segments:

- `@<letter><number>-<BOOK>` - dictionary lookup. The letter (P, L, F, T) is
  decorative; all of them index the same table.
- `@T<text>` - literal text, appended as is.
- `@\*<text>` - an *argument*, not text. It fills the `*1`, `*2` slots inside
  the looked-up sentence.

So `@P9833-POLUXDATA@\* 1` resolves to "cylinder *1 injection time" with
argument "1", giving "cylinder 1 injection time"; and `@P27687-POLUXDATA@\*`
gives the unit "deg. C" rather than the raw "*1 deg. C".

## 4. Finding one ECU

```
GPC.ECUTYPE       ECUNAME = 'V46_21'  -> ECUTYID, ECULIBNAME (= Cal458.dll)
GPC.ECU           by ECUTYID          -> one row per vehicle platform
GPC.FAMILY        FAMIDCANE / FAMIDCANR = CAN request / response ids
GPC.VEHICULE      VEHCOMTYPE = PSA platform code (B7 = C4 / C4 Sedan)
```

Rows whose `ECUCOMMENT` is `ecu telechargement` are the bootloader entry, not a
diagnostic session; skip them.

## 5. The byte maps

```
DSD.ECUVER        ECUVEECUNAME = 'V46_21'  -> ECUVEID per software version
DSD.I_ECUSER      -> SERVICE          (RDBLID, RDSDTC, IOCBLID, REQDWN, ...)
DSD.SERVUNIT      -> one unit per page or command
DSD.SERVUNITFRAME -> REQUEST / ANSWEROK / ANSWERKO
DSD.I_SERPAR      -> ISPBYTEPOS (1-based), ISPVALUE for constant bytes
DSD.PARAM         -> PARSNAME, matches GPC.PARAM.PARNAME
DSD.ADDDATA       -> byte length, bit length, bit mask
DSD.CONVFORM      -> CONFACTOR, CONOFFSET  (value = raw * factor + offset)
GPC.I_PARDIS + GPC.DISCVAL -> enumerated states with labels
```

Two traps:

- **Byte order.** `ADDDATA.ADDBYTEORDER` says `LittleEndian` for this ECU, but
  the wire is MSB-first. Live data settles it: `04 4F` is 1103 rpm, and the
  three sensor supplies read `01 F4` / `01 F3` / `01 F2` times 10, that is
  5000 / 4990 / 4980 mV. Trust the car, not the column.
- **Dynamic blocks.** Some answers change layout depending on a key byte.
  `DSD.DYNAMICBLOCK` holds the block start (`DYNBYTEPOS`), the key field
  (`DYNKEYNAME`) and the group (`DYNVALUEGROUP`). Inside a block
  `ISPBYTEPOS` restarts at 1, so the absolute position is
  `block_start + pos - 1`. Two of them matter here: page `$87` (freeze frame,
  layout chosen by the DTC code, 24 groups) and page `$A0` (configuration,
  layout chosen by the configuration index, 5 layouts).

Group membership for `$87` is in `DSD.STATES` via `STAGROUPNAME`; for `$A0`
the group name carries the key value in its suffix (`..._07` means index
`0x07`).

## 6. Everything else

| Feature | Tables |
|---|---|
| Fault codes | `GPC.ECU.I_ECUGRPDTCID` -> `GPC.I_ECUDTC` -> `GPC.DTC` (+ `I_DTCPRO` / `DTCPROPERTY` for status and origin) |
| Actuator tests | `GPC.I_ECUTAM` -> `TAM` / `TAMCTRL` -> `I_CTRLSERV` -> `TAMSERV` -> `I_SERVPAR` / `TAMPARAM` |
| Telecoding | `GPC.TPMSCREEN` -> `I_TPMSCRPAR` -> `PARAM` / `PARAMTPM`, byte layout from the `$A0` frames in DSD |
| Measurement screens | `GPC.SCREEN` -> `I_SCRPAR` -> `PARAM` |
| ECU recognition | `DSD.RECO` - init, recognition and stop frames per ECU |

The actuator command bytes are not stored as numbers. `I_SERVPAR.ISERVPARVALUE`
holds a value *name* such as `NSP_51`, and the suffix is the hex byte. So
ignition coil 1 is actuator `0x51` and the frame is `30 51 00`. `NSP_B8`
confirms the suffix is hexadecimal.

## 7. Checking the result

`tools/diagbox/decode.py` replays a recorded ELM transcript through the
extracted map. Against the capture taken from this car on 2026-08-27, every
page produced sensible values on a cold engine at fast idle - see the
verification table in `diagbox_v46_21_reference.md`. The ECU identified itself
as PSA part 9804436280, supplier Valeo, software edition 0E18.

## 8. What is deliberately not here

- **The security-access key algorithm.** `27 83` returns a seed and `27 84`
  expects the derived key; the derivation lives in `Cal458.dll` as code, not
  as data, so it is not in these databases. Reading configuration does not
  need it, writing does.
- **Flashing.** `REQDWN` (`34`) frames for reprogramming are documented in the
  reference for completeness, but the firmware images and the transfer logic
  are a separate matter and nothing here attempts them.
