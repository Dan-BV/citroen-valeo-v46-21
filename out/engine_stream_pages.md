# Engine stream: what each page costs and what it carries

Cost from the 2026-09-10 technical logs (1338 healthy reads); movement from
the two full drives of 2026-09-06 (18 949 cycles). A parameter counts as
moving if it took more than one distinct value across both drives.

Measured cycle on that drive: **755 ms**. The model below sums to 721 ms;
the rest is loop overhead and the keep-alive.

| page | request | ms | notif | bytes | params | moving | static |
|------|---------|-----|-------|-------|--------|--------|--------|
| `B0` | `21B08001` | 180 | 2 | 15 | 4 | 0 | 4 |
| `C0` | `21C08001` | 144 | 10 | 183 | 20 | 19 | 1 |
| `C1` | `21C18001` | 90 | 5 | 85 | 11 | 11 | 0 |
| `C2` | `21C28001` | 146 | 10 | 183 | 18 | 16 | 2 |
| `C4` | `21C48001` | 88 | 4 | 66 | 5 | 5 | 0 |
| `CA` | `21CA8001` | 117 | 6 | 113 | 25 | 14 | 11 |
| `CB` | `21CB8001` | 118 | 8 | 151 | 18 | 12 | 6 |
| `CF` | `21CF00` | not polled | — | — | 6 | 0 | 6 |


## CA — Движение  (117 ms)

Moving, by how many distinct values it took:

- Положение педали акселератора, дорожка 1 — 669
- Положение педали акселератора, дорожка 2 — 607
- Напряжение датчика педали акселератора 1 — 277
- Напряжение датчика педали акселератора 2 — 152
- Скорость автомобиля — 121
- Заданные обороты холостого хода — 120
- Отображаемый уровень топлива — 40
- Заданная скорость для круиз-контроля — 13

Static across both drives (11): Заданная скорость ограничителя скорости авто; Состояние ограничения скорости автомобиля (L; Состояние основного контактора тормоза; Информация датчика точки упора педали акселе; Включенная передача; Тип коробки передач; Состояние ДВС; Состояние "пробуждения" ЭБУ; Температура охлаждающей жидкости при последн; Запуск разрешен ЭБУ коробки передач; Состояние силового агрегата

## CB — Окружение двигателя  (118 ms)

Moving, by how many distinct values it took:

- Значение уровня шума, измеренного датчиком детонации — 3682
- Оценка мощности, потребляемой компрессором кондиционера — 233
- Давление в тормозном усилителе — 207
- Атмосферное давление — 81
- Запрошенная скорость электровентилятора системы охлаждения — 55
- Давление хладагента кондиционера — 45
- Температура наружного воздуха — 15
- Напряжение питания датчиков 3 — 5

Static across both drives (6): Состояние реле большой скорости электровенти; Давление моторного масла; Управление силовым реле; Состояние включения стартера; Информация о обнаружении удара; Состояние управления электрическим вакуумным

## C0 — Смесеобразование  (144 ms)

Moving, by how many distinct values it took:

- Фактор коррекции обогащения смеси на выходе — 9649
- Фактор коррекции обогащения смеси на входе — 9649
- Время впрыска в цилиндре 4 — 1140
- Время впрыска в цилиндре 3 — 1140
- Время впрыска в цилиндре 2 — 1140
- Время впрыска в цилиндре 1 — 1140
- Обороты двигателя — 1073
- Заданное значение обогащения смеси — 342

Static across both drives (1): Состояние регулирования кислородного датчика

## C2 — Впуск  (146 ms)

Moving, by how many distinct values it took:

- Расход воздуха — 1657
- Запрошенный расход воздуха — 1653
- Напряжение датчика положения заслонки 2 — 372
- Напряжение датчика положения заслонки 1 — 365
- Запрошенный угол заслонки — 98
- Измеренный угол заслонки — 90
- Сигнал RCO электромагнитного клапана регулятора фаз газораспределения впускного распредвала — 85
- Измеренное значение наполнения — 74

Static across both drives (2): Состояние соответствия между положением впус; Счетчик числа холодных запусков двигателя

## C1 — Зажигание  (90 ms)

Moving, by how many distinct values it took:

- Применённый УОЗ, цил. 4 (не подтверждено) — 78
- Применённый УОЗ, цил. 3 (не подтверждено) — 78
- Применённый УОЗ, цил. 2 (не подтверждено) — 78
- Применённый УОЗ, цил. 1 — 78
- Минимальное опережение зажигания — 53
- Максимальное опережение зажигания — 48
- Оптимальное опережение зажигания — 43
- Отмена опережения цилиндр 3 — 8

## C4 — Момент двигателя  (88 ms)

Moving, by how many distinct values it took:

- Крутящий момент, полученный путем регулировки расхода воздуха (запрос) — 3209
- Крутящий момент, соответствующий требованию водителя — 3043
- Крутящий момент, полученный путем регулировки опережения зажигания (реальный) — 2586
- Крутящий момент, полученный путем регулировки опережения зажигания (запрос) — 2585
- Рассчитанный момент сопротивления — 523

## What choosing periods is actually worth

`PagePlan` already reads each page every *n*th cycle — default 1, or 10 for a
page marked `slow`, which today is only `B0`. So `B0`'s 180 ms already costs
18 ms amortised, and the arithmetic below starts from that.

| period set | cycle | vs now |
|------------|-------|--------|
| as it stands | 721 ms | 1.00x |
| `B0` off entirely | 703 ms | 1.03x |
| `B0` off, `CA` and `C4` every 3rd | 566 ms | 1.27x |
| knock and ignition focus: `C1`+`CB` every cycle, `C0`+`C2` every 2nd, `C4`+`CA` every 3rd | 421 ms | 1.71x |
| mixture focus: `C0`+`C2` every cycle, `C1` every 2nd, `C4`+`CA`+`CB` every 3rd | 443 ms | 1.63x |
| `C0`+`C1` only | 234 ms | 3.08x |

## The honest reading of this

There is no free page to drop. `B0` is the one page that carries nothing —
all four of its parameters are static across 18 949 cycles — and it is already
slowed to every 10th, so removing it buys 18 ms. Everything else carries
something that moves, and the two pages that look most cuttable do not survive
a look at their contents:

- `CA` has 11 static parameters out of 25, but the movers include **accelerator
  pedal position** at 669 distinct values and vehicle speed at 121. Slow it down
  and driver input gets coarse.
- `CB` has 6 static out of 18, but one of the movers is the **knock sensor noise
  level** at 3682 distinct values — the fastest-moving parameter in the whole
  profile, and the one the fuel-quality work turns on.

So the gain does not come from finding waste. It comes from **deciding what a
given drive is for** and slowing the pages that drive does not need. A knock and
ignition drive does not need mixture at full rate; a mixture drive does not need
the pedal. Either way the cycle roughly halves, which is the same order as the
2.15x a wider adapter would give — and it needs no new hardware, no new
protocol, and no code, because the screen for setting periods is already in the
app.

The static parameters are worth a second look for a different reason: several
are not "slow", they are **dead on this ECU**. `CA` reports gear = 8 and gearbox
type = 0 for 18 949 cycles; `B0` never moves at all. Those are candidates for
dropping from the profile rather than for a longer period.
