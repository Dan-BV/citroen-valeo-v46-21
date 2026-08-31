# CAR_APP — состояние работы (resume-заметка)

Дата последней сессии: 2026-08-26. Машина: Citroën/Peugeot, движок Valeo **V46.21** (petrol EC5).

## ГЛАВНЫЙ ВЫВОД (меняет прежние заметки)
Прежний вывод «V46.21 только по K-LINE» — **неверен для реальной связки**. На живой машине
движок читается **по CAN, заголовок PSA `6A8/688`** (ISO 15765-4, 11-bit, 500k). Проверено вживую.

## Железо (адаптеры)
- **РАБОЧИЙ:** классический Bluetooth SPP-адаптер, в Windows виден как **"OBD II"**, порт **COM7**
  (BTHENUM ...AABBCC112233). Это **ELM327 v1.5**. `ATI→ELM327 v1.5`, `ATRV→14.6V`. CAN работает,
  K-line — тоже нет (BUS INIT ERROR), но CAN достаточно.
- **НЕ РАБОТАЕТ на Windows:** **KONNWEI** (BLE, addr `B100E003C0C9`, GATT service `FFF0`).
  - K-line трансивер мёртв (BUS INIT ERROR и fast, и 5-baud).
  - BLE GATT на Windows не читается: `chrome://bluetooth-internals` и Web Bluetooth возвращают
    пустые сервисы (стек Windows не отдаёт discovery этому донглу). Classic SPP KONNWEI (COM9)
    даёт "semaphore timeout". На iPhone KONNWEI работает (iOS BLE-стек ок).
- CH340 на COM5 — какой-то USB-адаптер, во время сессии не был воткнут.

## Рабочая последовательность CAN (проверена)
```
ATZ ATE0 ATL0 ATH0 ATS0 ATAL
ATSP6
ATSH6A8         ; запрос -> движок
ATCRA688        ; приём <- движок
ATFCSH6A8 ATFCSD300000 ATFCSM1   ; flow control
81              ; StartCommunication -> "C1 D0 8F" (ОБЯЗАТЕЛЬНО перед 21Cx!)
                ; 10C0/1003/10A4 -> 7F 10 12 (not supported) — НЕ нужны
21CB 21CA 21C0 21C1 21C2   ; live reads (работают ТОЛЬКО после 81)
```
Замечание: ELM отдаёт многокадровые ответы с префиксами кадров (`03B` длина, затем `0:`,`1:`...).
Парсер приложения это уже учитывает (cleanHex разбирает `N:`-префиксы и строку длины).

## Живой дамп (idle, прогретый двигатель) — для КАЛИБРОВКИ офлайн
Эталон (стандартные OBD mode-01, hdr 7DF/7E8), два замера:
| PID | замер1 | замер2 | значение |
|---|---|---|---|
| 010C RPM | 0BB8 | 0BB4 | 750 / 749 об/мин |
| 0105 Coolant | 86 | 85 | 94 / 93 °C |
| 010D Speed | 00 | 00 | 0 км/ч |
| 0111 Throttle | 1E | 1E | ~11.8 % |
| 010F IAT | 5B | 5D | 51 / 53 °C |
| 0142 Voltage | 375A | 3732 | 14.17 / 14.13 В |
| 0110 MAF, 012F Fuel | NO DATA | | недоступны стандартно |

Реассемблированные проприетарные страницы (начинаются с `61<page>`, idx: 0x61=0), замер2:
```
21CB(0x3B): 61CB 02ED 8D67 8FFF FFFF 0000 1E00 0000 0104 FFFF FF00 3401 F401 F301 F2FF FFFF FFFF 01FF FFFF 0100 4A00 FF32 64FF FFFF FF00 0000 00FF FF01 6000 D2
21CA(0x2B): 61CA 02F3 02EE 8E8F 0000 2700 1400 0000 00FE 1400 08FF 0000 0000 FF08 0004 4105 0104 0014 0009 7687 0100 00
21C0(0x48): 61C0 02E8 8D8F 00DD 00DD 00DD 00DD FFFF FFFF FFFF FFFF 01FF 01FF 0293 FFFF 01FF 00FF 02C4 FFFF 0361 FFFF 03A2 FFFF 6E18 FFFF 6E18 FFFF 0803 E717 FF...
21C1(0x20): 61C1 02E6 8E8F 7676 5A66 6666 66FF FF64 6464 64FF FF76 FF...
21C2(0x48): 61C2 02EC 8D67 1313 FFFF FF00 4E0F 0F02 0200 3B01 B764 FF64 FF00 01FF FFFF 4BDA FF... 004C FF... 67 000000
```
(замер1 21CB был: 61CB 02E8 8C60 8AFF... idx12=1C — тот же набор, значения дрейфуют на idle.)

## Калибровка — что уже установлено
- **RPM = 21CB idx2-3, scale 1, offset 0** (02ED=749 ↔ эталон). RPM продублирован на ВСЕХ
  страницах в idx2-3. В приложении уже исправлено.
- Кандидаты (по одному idle-замеру, НЕ подтверждены — нужен газ/прогрев):
  - Throttle/AccelPedal ≈ **21CB idx12**, formula `raw*100/255` (0x1E→11.76%).
  - Voltage/Battery ≈ **idx4** (=0x8D=141), formula `raw*0.1`→14.1В (стабилен на всех страницах).
  - Coolant 93°C в 21Cx НЕ найден стандартными формулами — вероятно другая страница/формула.
- Прежняя таблица `v46_21_params.md` по СМЕЩЕНИЯМ ненадёжна (offset UNCERTAIN подтвердилось).
  Scale/формулы из неё тоже под вопросом (RPM была raw*5 — оказалось scale 1).

## Хостинг (GitHub Pages) + имя
- Приложение переименовано: **Citroën Valeo V46.21** (заголовок вкладки + шапка).
- Живой URL: **https://dan-bv.github.io/citroen-valeo-v46-21/** (HTTPS, работает Web Bluetooth; iPhone — через Bluefy).
- Репозиторий: **Dan-BV/citroen-valeo-v46-21** (public). Локальная папка деплоя: `C:\_CAR_APP\fap_pages\` (git-repo,
  remote origin). В нём только `index.html` (копия fap_web/fap_live.html) + README + .nojekyll.
- Обновление: правим `fap_web/fap_live.html` → `cp fap_web/fap_live.html fap_pages/index.html` →
  `git -C fap_pages commit -am "..." && git -C fap_pages push` → Pages пересобирается ~1 мин.
- gh авторизован как Dan-BV (scopes repo, workflow). git/gh установлены.

## Приложение (веб, Web Serial/Bluetooth)
Файл: `C:\_CAR_APP\fap_web\fap_live.html` (single-file). Уже умеет:
- Транспорт: Serial (Web Serial) и BLE (Web Bluetooth). Для этой машины: **Serial → COM7**.
- Протокол: **CAN PSA (6A8/688)** [по умолчанию] и K-line KWP. CFG сохраняет выбор в localStorage.
- Список параметров со скролом → клик по числовому → масштабируемый график (колесо/драг/двойной клик).
- Булевы (BR/CL) как ON/OFF. CSV-лог + скачивание.
- Парсер многокадровости и RPM — исправлены. Остальные проприетарные offset — НЕ откалиброваны.
Android-версия ядра: `C:\_CAR_APP\fap_modern\` (Kotlin, пока с K-line; тоже нужен CAN + калибровка).
Car Scanner .csp: `C:\_CAR_APP\out\custompids_v46_21_carscanner.csp` (формулы в FR; offset тоже под калибровку).

## ОБНОВЛЕНИЕ (сделано офлайн): режим "CAN OBD-II стандарт"
Добавлен и **проверен** третий протокол в приложении — стандартные OBD-II mode-01 PID
(header 7DF/7E8), формулы стандартные, калибровка НЕ нужна. Это **протокол по умолчанию**.
Поддерживаемые PID декодированы из `0100 -> BE 3E B8 11`. Набор (13 шт), формулы проверены кодом:
RPM 010C (raw/4), Load 0104 (raw*100/255), Coolant 0105 (raw-40), IAT 010F (raw-40),
MAP 010B (raw), Throttle 0111 (raw*100/255), Timing 010E (raw/2-64), Speed 010D (raw),
STFT 0106 / LTFT 0107 ((raw-128)*100/128), O2 B1S1 0114 / B1S2 0115 (raw/200), Volt 0142 (raw/1000).
Проверка парсера (реальные ответы): 410C0BB4→749, 410585→93°C, 41111E→11.8%, 41423732→14.1В — верно.

Приложение теперь переключает набор параметров по протоколу (ACTIVE = OBD2 либо V46.21 PARAMS),
localStorage обёрнут в try/catch (не падает в data:/приватном режиме). Многокадровый парсер и RPM
(для проприетарного) — исправлены ранее.

**Как пользоваться (рабочий вариант СЕЙЧАС):** localhost → CFG: Тип=Serial, Протокол=CAN OBD-II
стандарт → Подключить → COM7. Все 13 значений корректны, клик → график.

## СЛЕДУЮЩИЙ ШАГ (выбор пользователя, ждём ответ)
- **A)** Добавить в приложение надёжные стандартные OBD-PID (mode 01): RPM, coolant, speed, throttle,
  IAT, MAP/boost, load, timing, fuel trims, O2, voltage, DTC. Работают сразу, без калибровки.
- **B)** Откалибровать проприетарные `21Cx` FAP-параметры. Нужны замеры в разных состояниях
  (idle → газ до ~2500 подержать → кондиционер вкл/выкл), чтобы по сдвигам байтов привязать каждый.
- Рекомендация: **A сейчас + B потом**. Часть B можно начать офлайн на уже снятых кадрах выше.

## Полезные факты для офлайн-работы без машины
- Калибровать RPM больше не нужно (готово).
- Для B офлайн: по кадрам выше можно искать байты, но одиночный idle-замер даёт неоднозначность —
  реально нужен ещё хотя бы один замер «газ ~2500». Без него B лучше не финализировать.
- Вариант A можно полностью сделать офлайн (стандартные PID и формулы известны).

## SESSION 3 END (2026-08-27) — калибровка по Bluetooth-снупу приложения FAP + внедрение
- **Метод-прорыв:** сняли btsnoop-лог живой сессии приложения FAP (`adb bugreport`) + его CSV-экспорт,
  восстановили ELM-диалог и регрессией привязали параметры. **30/31 решено с R²≥0.97.**
  Полная таблица/метод → **`out/fap_calib_from_btsnoop.md`** (главный документ сессии 3). Память: [[car-app-btsnoop-calibration]].
- **КРИТИЧНО:** FAP шлёт страницы в форме **`21CX8001`** (не голый `21CB`), ответ с префиксом **`61 FF 04…`**
  и ДРУГОЙ раскладкой байт. Найденные смещения годятся ТОЛЬКО под форму `21CX8001`.
- **Внедрено в приложение** (`fap_web/fap_live.html`, режим «CAN PSA»): 31 параметр, запросы `21CX8001`,
  marker `61FF`, `tryCan` проверяет `21CB8001`→`61FF`. Проверено офлайн парсером против CSV (значения сходятся)
  и в браузере на live-URL (рендерятся 31 строка). **Задеплоено** на GitHub Pages (2 коммита).
- Заодно **починен баг**: `lsGet/lsSet` вызывали сами себя (рекурсия) — настройки не сохранялись; теперь `localStorage.*`.
- **`.csp` НЕ обновлён** (Car Scanner): неясно, сколько байт заголовка он срезает для формы `21CX8001` —
  оффлайн не проверить. Делаем на следующем заезде за 1 мин (сверить Revs с тахометром, поправить оффсет).
- **Осталось 9 параметров** (не менялись в этом логе): Cyl.1–4AdvCorr (=0 на х.х.), Gear (был `-`; вероятно МКПП),
  Errors (нет DTC), FanSpeed/FuelLevel/BrakePress (мало вариации). Добор → второй целевой заезд с FAP+CSV
  (кондиционер ВКЛ, нажатия тормоза, нагрузка), снять так же через `adb bugreport`.

## SESSION 2 END (2026-08-26) — калибровка по CAN + покрытие FAP
- Подтверждено вживую (idle+rev+12-мин заезд): машина читается по CAN 6A8/688; реализовано 17 параметров.
- **Полный список параметров FAP V46.21 (~39) со статусом DONE/TODO + наши смещения + протокол добора → `out/fap_param_coverage.md`** (главный документ для продолжения).
- Живые дампы/находки: `out/calib_captures.md`. Car Scanner CAN PID (17): `out/custompids_v46_21_can.csp`.
- Осталось ~22 параметра — нужен структурированный ~15-мин заезд с синхронным эталоном (см. протокол в coverage-доке).
- Критично: `81` перед проприетарными чтениями + `ATAL` для многокадровых (иначе только первый фрейм).

## SESSION 4 END (2026-08-30) — Diagbox database extraction (supersedes the guesswork)

The Diagbox 9.85 installation on this machine was mined directly, so the V46.21
byte maps no longer come from regression on captures — they come from the same
data the official tool drives.

- **Where it is:** `AWRoot/dtrd/comm/data/GPC.FDB` + `DSD.FDB` (Firebird 2.5,
  needs the x64 embedded engine — the bundled one is 32-bit 2.1), labels in
  `AWRoot/dtrd/trans/*.DU8`. Method: `out/diagbox_extraction_method.md`.
- **Confirmed from the database:** CAN 6A8/688, KWP2000 on ISO 15765-2, `81`
  start of communication answering `C1 D0 8F`, request form `21 <LID> 80 01`
  answering `61 FF ...`. All of it matches what was found by hand.
- **New ground:** pages `$B0` (supplies + immobiliser), `$C3` (learned/adaptive),
  `$C4` (torque), `$CF`, `$DB`, identification `$80`/`$FE`/`$82`, freeze frames
  via `21 87 <DTC>`, 16 actuator tests (`30 <id> 00/01/11`), 14 learned-value
  resets (`11 C2`..`11 FF`), immobiliser pairing routines, and the full
  telecoding read `21 A0` / write `34 A0 ...` layout with bit masks.
- **Confirms the hand-derived offsets.** Spot-checked against the app's own
  regression-fitted table: engine speed, voltage, coolant (`raw - 50`), intake
  air, knock sensor, A/C pressure and fan setpoint all land on the same bytes
  and formulas. Two genuine corrections: atmospheric pressure is 2 bytes with
  offset `+500` (the app had 1 byte `+756`), and the `80 01` suffix does *not*
  change the byte layout — `21 CB` and `21 CB 80 01` put the payload at the
  same offsets, only the answer id differs (`61 CB` vs `61 FF`).
- **Verified:** `tools/diagbox/decode.py` replays `transcript_2026-08-27.json`
  through the extracted map; every page decodes sensibly. The ECU is PSA part
  **9804436280**, Valeo, software edition **0E18**, 19425 engine starts.
- **Docs:** `out/diagbox_v46_21_reference.md` (main), `..._dtc.md` (291 codes),
  `diagbox_b7_ecu_map.md` (112 modules with CAN ids + init/recognition frames).
  Machine-readable: `data/diagbox/V46_21_B7.json`, `vehicle_B7.json`.
- **Platform:** B7 (C4 / C4 Sedan), confirmed by the user. The same ODX
  definition covers all 11 platforms, so only the DTC list is platform-specific.

## SESSION 5 (2026-08-31) — the app now runs on the Diagbox data

Step 1 of the agreed order is done: `index.html` no longer carries hand-fitted
parameters.

- `tools/diagbox/make_profile.py` renders the extraction down to a 54 kB profile
  (10 read pages, 118 parameters, 13 identification fields, 291 fault codes) and
  splices it into `index.html` between the `V46.21 PROFILE` markers. Regenerate
  rather than edit by hand.
- The list is grouped by read page and shows enumerated states as text
  ("closed loop", "rich") instead of raw numbers.
- New buttons: **ОШИБКИ** reads `17 FF 00`, decodes `57 <count> [code status]`
  and names each code, with a confirm-gated clear via `14 FF 00`; **ЭБУ** reads
  `21 80` / `21 FE` / `21 82`.
- Adapter access is now serialised through `Session.lock()`, so the on-demand
  reads cannot interleave with the poll loop.
- Pages that hold still (`$B0`, `$C3`, `$CF`, `$DB`) are read every tenth cycle.
- Verified offline: the app's own parser was run over
  `transcript_2026-08-27.json` and decoded 89/89 fields present in that capture,
  matching `tools/diagbox/decode.py`. Panels checked in a browser with stubbed
  data. **Not yet tested on the car.**
- Known unknown: the meaning of the DTC status byte. The databases name three
  categories (permanent / intermittent / fleeting) but hold no numeric encoding
  for this ECU, so the app shows the raw byte. Resolve it against a real fault.

**Still to do, in the agreed order:** module scan across the 112 ECUs of B7
(`data/diagbox/vehicle_B7.json`, note KWP `81`/`2180` vs UDS `1001`/`22F080`),
actuator tests, adaptation resets, telecoding read.

**Not extracted:** the security-access key algorithm for `27 83`/`27 84` — it is
code inside `AWRoot/dtrd/comm/Cal458.dll`, not data in the databases. Needed for
writing configuration, not for reading anything.
