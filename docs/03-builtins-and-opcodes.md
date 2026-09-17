# 03 — Встроенные классы, методы и опкоды EV3 VM

Два независимых слоя:

1. **Basic → ассемблер**: `Interpreter/Compiler/Compiler.cs` + `Interpreter/Compiler/Resources/*.txt` — имена вида `lcd.text` превращаются в строки ассемблерного текста.
2. **Ассемблер → байты**: `Interpreter/Assembler/*.cs` + `Interpreter/Assembler/Resources/bytecodelist.txt`.

Ключевой факт для портирования: **встроенные методы — это не таблица «метод → опкод»**, а 31 текстовый модуль на EV3-Basic-подобном ассемблере. Компилятор их не разбирает по смыслу: он либо *инлайнит текст*, либо генерирует *subcall*. Список модулей — `Compiler.cs:73-105` (`readLibrary`). `c_BitMask.txt` в нём **отсутствует** — это справочная таблица масок моторов.

---

## 1. Механика встроенных объектов

### 1.1 Регистрация модулей

`readLibrary()` (`Compiler.cs:73-105`) вызывает `readLibraryModule(...)` для 31 ресурса. Разбор — `Compiler.cs:109-168`:

| Начало строки | Действие | Ссылка |
|---|---|---|
| `subcall <NAME>` | `LibraryEntry(inline=false)`, ключ `NAME.ToUpperInvariant()` | `Compiler.cs:150-152` |
| `inline <NAME>` | `LibraryEntry(inline=true)` | `Compiler.cs:150-152` |
| `init` | тело складывается в `runtimeinit` (отступ 4 пробела) | `Compiler.cs:142-147` |
| прочее вне блока | складывается в `runtimeglobals` (все `DATA*`/`ARRAY*` модулей) | `Compiler.cs:125-138` |
| `//` | обрезается до конца строки | `Compiler.cs:130-134` |

Дескриптор после имени: `// FFSV  REF1 REF2` — первая группа это сигнатура (`Compiler.cs:154-156`), остальные — зависимости (транзитивно через `memorize_reference`, `Compiler.cs:529-546`). Коды типов — `LibraryEntry.cs:61-72`: `F`→Number, `S`→Text, `A`→NumberArray, `X`→TextArray, `V`→Void. **Последний символ — тип возврата**, предыдущие — типы параметров (`LibraryEntry.cs:37-43`).

### 1.2 `inline` против `subcall`

| | `inline` | `subcall` |
|---|---|---|
| Код в `.lmsb` | подставляется текстом; тело вырезается от `{` до **первого** `}` (`LibraryEntry.cs:52-57`) | отдельный объект `subcall NAME {...}` в конце файла |
| Вызов | `CallExpression` с `function = libentry.programCode` (`Compiler.cs:1101`) | `CallExpression` с `"CALL " + NAME` (`Compiler.cs:1101`) |
| Локальные данные | `DATA8 x:#` — уникальный суффикс на каждый вызов | собственный `DataArea` (`LMSObject.cs:304-458`) |
| В `.lmsb` | только если вызван | только если вызван (`references`, `Compiler.cs:461-468`) |
| `init`-блок | — | попадает в `runtimeinit` **всегда**, даже если метод не используется |

`init`-блоки идут в `vmthread MAIN` в порядке регистрации (`Compiler.cs:334-337`). В `Program1.lmsb` это `MOVE32_32 0 STOPLCDUPDATE` (LCD), `MOVE32_32 0 NUMMAILBOXES` (Mailbox), `OUTPUT_RESET 0 15` + 16×`WRITE8 … FIRSTOF2` (Motor), `INPUT_DEVICE CLR_ALL -1` (Sensor), `ARRAY CREATE8 0 LOCKS` (Thread), `MOVE32_32 0 sNout1..3` (Sensor1-4), `MOVE32_32 0 timeMC1..9` (Time) — точно по списку `Compiler.cs:75-104`.

**Следствие:** даже программа `HelloWorld` несёт ~40 инструкций инициализации всех модулей.

### 1.3 Подстановка placeholder'ов

`CallExpression.Generate` (`Expression.cs:198-265`) собирает аргументы и вызывает `InjectPlaceholders` (`Expression.cs:267-311`):

| Placeholder | Значение |
|---|---|
| `:0` … `:9` | аргумент №0…№9 (`PreparedValue()` либо зарезервированная temp-переменная) |
| `:#` | уникальный числовой суффикс вызова (`GetLabelNumber()`, `Expression.cs:281-287`) — защита от коллизии `DATA8 x:#` при повторном инлайне |

**Критично:** использованные placeholder'ы помечаются `null` (`Expression.cs:305-308`) и **не** дописываются в конец; неиспользованные дописываются в порядке объявления (`Expression.cs:223-230`). Это механизм «выходной параметр в конец»: `MATH.ABS` (`c_Math.txt:8-11`) пишет `MATH ABS :0 :1` явно, а `MATH.FLOOR` (`c_Math.txt:44-47`) — только `MATH FLOOR`, получая операнды автоматически.

### 1.4 Временные переменные

`FunctionDefinition.reserveVariable` (`FunctionDefinition.cs:132-151`) выдаёт `F<fname>.<n>` / `S<fname>.<n>`; максимум (`getMaxReserved`) задаёт число `DATAF`/`DATAS` в объекте (`Compiler.cs:394-411`). В основной программе имя функции пустое → `F.0`, `F.1`, `S.0` (видно в `Program1.lmsb`); в sub `f_map_data_2` → `FF_MAP_DATA_2.<n>`. Basic-переменные получают префикс `V` (`Compiler.cs:722`, `Compiler.cs:861-863`). Точка внутри имени допустима — токенизатор ассемблера разрешает `.` в токене (`Assembler.cs:684`).

### 1.5 `DefaultObjectList` — независимый каталог

`DefaultObjectList.cs:47-408` используется **только** препроцессором/парсерами ошибок (`Preprocessor.cs:25` → `Install()`; потребители `MethodErrorParser.cs:31,37`, `LogicErrorParser.cs:395`, `ForLineErrorParser.cs:212`, `VariableErrorParser.cs:471`, `ArrayIndexErrorParser.cs:126`). `Compiler.cs` его **не** использует. Расхождения между двумя каталогами:

| Имя | `DefaultObjectList` | Модуль | Комментарий |
|---|---|---|---|
| `ev3.nativecode` | **отсутствует** | `c_EV3.txt:117` `SF` | вызывается только из `ev3file.tablelookup` |
| `byte.and_`, `byte.or_` | суффикс `_` | `c_Byte.txt:16,32` | `_` обязателен: `and`/`or` — ключевые слова |
| `program.argumentcount` | METHOD 0 → NUMBER | `c_Program.txt:3` `F` | оба согласованы, но реализация — заглушка |
| `row.init` | NUMBER (не массив) | `c_Row.txt:6` `FFF` | handle — обычное число |
| `motor.*`, `sensor1..4.*`, `math.*`, `lcd.*` | полные списки | `c_*.txt` | расхождений не найдено |

---

## 2. Каталог встроенных классов

Регистр имён не важен (`parse_id` + `ToUpperInvariant`). Формат: **сигнатура → семантика → File:line**.

### 2.1 ASSERT — `c_Assert.txt`

- `Assert.Failed` `SV` → LCD: `UI_DRAW CLEAN`, `SELECT_FONT 1`, `TEXT 1 0 16 'ASSERT FAILED'`, затем текст по 22 символа на строку (3-30).
- `Assert.Equal` `SSSV` → `STRINGS COMPARE`; при расхождении клеит `' ('`,`a`,`'<>'`,`b`,`')'` → `Assert.Failed` (32-51). `Assert.NotEqual` `SSSV` → обратное (53-65).
- Сравнения `FFSV`: `Assert.Less` → `JR_LTF a b isok` (89-98) · `Assert.Greater` → `JR_GTF` (67-76) · `Assert.LessEqual` → `JR_LTEQF` (100-109) · `Assert.GreaterEqual` → `JR_GTEQF` (78-87).
- `Assert.Near` `FFSV` → eps = `1.0/5000000.0`; `b-eps < a < b+eps` (111-132).

Зависимости (3, 32): `Failed`→`TEXT.GETSUBTEXT`,`TEXT.GETSUBTEXTTOEND`; `Equal`→`ASSERT.FAILED`,`TEXT.APPEND`.

### 2.2 BUTTONS — `c_Buttons.txt`

- `Buttons.GetClicks` `S` → строка нажатых за клик в порядке `U`,`E`,`D`,`R`,`L` (200-230).
- `Buttons.Wait` `V` → `UI_BUTTON WAIT_FOR_PRESS` (inline, 232-235). `Buttons.Flush` `V` → `UI_BUTTON FLUSH` (inline, 237-240).
- `Buttons.Current` — **property** `S`: дерево из 31 `UI_BUTTON PRESSED`, возвращает подмножество `UEDRL` или `''` (3-198).

### 2.3 BYTE — `c_Byte.txt`

Все результаты — 8-битные беззнаковые (`AND16 … 255`), кроме `ToBinary`/`ToHex`/`ToLogic` (строки).

- `Byte.Not` `FF` побитовое НЕ в 16 бит, маска 255 (3-14) · `Byte.And_` `FFF` (16-30) · `Byte.Or_` `FFF` (32-46) · `Byte.Xor` `FFF` (48-62).
- `Byte.Bit` `FFF` бит `index & 255` (64-81) · `Byte.Shl` `FFF` сдвиг влево, маска 255 (83-98) · `Byte.Shr` `FFF` сдвиг вправо, `distance > 7` → `0` (100-121).
- `Byte.ToHex` `FS` → `NUMBER_FORMATTED '%02X'` (123-133) · `Byte.ToBinary` `FS` → «растягивание» битов в нибблы, `%08X` (135-157) · `Byte.ToLogic` `FS` → `> 0.0` = `'True'`, иначе `'False'` (159-169).
- `Byte.H` `SF` hex-строка (0-9,A-F,a-f) → число, маска 255 (171-213) · `Byte.B` `SF` бинарная строка → число (215-244) · `Byte.L` `SF` `'TRUE'` после upcase → `1`, иначе `0` (246-258).

### 2.4 EV3 — `c_EV3.txt`

- `EV3.SetLEDColor` `SSV` → color GREEN/RED/ORANGE, effect NORMAL/FLASH/PULSE, `UI_WRITE LED col` (7-54). Кодирование (28-53): `'GREEN'`→1, `'RED'`→2, `'ORANGE'`→3; `+3` при `'FLASH'`, `+6` при `'PULSE'`. `'OFF'` не обрабатывается — `col` остаётся `0`.
- `EV3.SystemCall` `SF` → shell `SYSTEM`, результат = `result01 & 255` (95-111). `EV3.QueueNextCommand` `V` → **пустой inline**, no-op (113-115).
- `EV3.NativeCode` `SF` → `/tmp/nativecode` через named pipes (117-166); не в `DefaultObjectList`.
- Свойства: `BatteryLevel` `F` = `UI_READ GET_LBATT` (68-75) · `BatteryVoltage` `F` = `UI_READ GET_VBATT` (77-81) · `BatteryCurrent` `F` = `UI_READ GET_IBATT` (83-87) · `Time` `F` = `TIMER_READ` мс от старта VM (56-65) · `BrickName` `S` = `COM_GET GET_BRICKNAME 18 result` (89-93).

### 2.5 EV3FILE — `c_EV3File.txt`

Не-абсолютный путь получает префикс `/home/root/lms2012/prjs/` (3-18, 20-35, 37-53).

- `OpenWrite` `SF` → `FILE OPEN_WRITE` (3-18). `OpenAppend` `SF` → `FILE OPEN_APPEND` (20-35). `OpenRead` `SF` → `FILE OPEN_READ` (37-53). `Close` `FV` → проверка `1.0 ≤ handle ≤ 32767.0`, `FILE CLOSE` (55-65).
- `WriteLine` `FSV` → `FILE WRITE_TEXT handle16 6 text` (67-78). `WriteByte` `FFV` → `FILE WRITE_BYTES handle16 1 byte8` (80-93). `WriteNumberArray` `FFAV` → блоками по 4 байта, выход за размер → нули (173-210).
- `ReadLine` `FS` → `FILE READ_TEXT handle16 6 127 text` (95-109). `ReadByte` `FF` → `FILE READ_BYTES handle16 1 byte8` (111-127). `ReadNumberArray` `FFA` → блоками по 4000 байт через `ARRAY WRITE_CONTENT` (129-171).
- `ConvertToNumber` `SF` → `STRINGS STRING_TO_VALUE` (213-219). `TableLookup` `SFFFF` → shell-команда `tablelookup …` → `EV3.NativeCode` (221-254).

### 2.6 LCD — `c_LCD.txt`

Все методы, кроме `Clear`/`Update`/`StopUpdate`, заканчиваются `JR_NEQ32 0 STOPLCDUPDATE skipupdate` + `UI_DRAW UPDATE`.

- `StopUpdate`/`Update` `V` → `MOVE32_32 1`/`0` `STOPLCDUPDATE` (+ `UI_DRAW UPDATE`) (10-19).
- `Clear` `V` → `UI_DRAW(TOPLINE,0)`, `UI_DRAW(CLEAN)` (21-29).
- `Rect`/`Line` `FFFFFV` → `UI_DRAW RECT`/`LINE`: col,x,y,w,h (для `Line` — col,x1,y1,x2,y2) (31-81).
- `Text` `FFFFSV` / `Write` `FFSV` → `SELECT_FONT` + `UI_DRAW TEXT col x y text`; у `Write` font = 1 жёстко (83-125).
- `Circle`/`FillCircle` `FFFFV` → `UI_DRAW CIRCLE`/`FILLCIRCLE` (127-172).
- `FillRect` `FFFFFV` → `UI_DRAW FILLRECT` (174-198). `InverseRect` `FFFFV` → `UI_DRAW INVERSERECT` (x,y,w,h) (200-222).
- `Pixel` `FFFV` → `UI_DRAW PIXEL` (224-242). `BmpFile` `FFFSV` → префикс `/home/root/lms2012/prjs/`, суффикс `.rgf`, `UI_DRAW BMPFILE` (244-271).

### 2.7 MAILBOX — `c_Mailbox.txt`

- `Mailbox.Create` `SF` → `MAILBOX_OPEN id8 boxname 4 0 0` (текст); ≥30 ящиков → `-1.0` (11-28). `CreateForNumber` `SF` → то же, тип 3 (30-47).
- `Mailbox.IsAvailable` `FS` → `MAILBOX_TEST` → `'True'`/`'False'` (50-67).
- `Mailbox.Receive` `FS` → `MAILBOX_READY` + `MAILBOX_READ no 252 1 :1` (inline, 69-75). `ReceiveNumber` `FF` → `MAILBOX_READ no 3 1 :1` (inline, 77-83).
- `Mailbox.Send` `SSSV` → `MAILBOX_WRITE brickname 0 boxname 4 1 message` (86-93). `SendNumber` `SSFV` → `MAILBOX_WRITE … 3 1 message` (95-102). `Connect` `SV` → `COM_SET SET_CONNECTION 2 brickname 1` (inline, 105-110).

### 2.8 MATH — `c_Math.txt`

- `Math.Pi` prop `F` → `MOVEF_F 3.1415926535897932384 :0` (3-6) · `Math.Abs` `FF` → `MATH ABS :0 :1` (8-11) · `Math.Floor` `FF` → `MATH FLOOR` (44-47) · `Math.Round` `FF` → `MATH ROUND` (96-99) · `Math.SquareRoot` `FF` → `MATH SQRT` (106-109) · `Math.Log` `FF` → `MATH LOG` (68-71) · `Math.NaturalLog` `FF` → `MATH LN` (84-87).
- Тригонометрия в **градусах**: `Math.Sin` `FF` → `MULF :0 57.295779513082 tmp` + `MATH SIN tmp :1` (100-105) · `Math.Cos` (38-43) · `Math.Tan` (110-115). Обратные: `Math.ArcSin` `FF` → `MATH ASIN :0 tmp` + `DIVF tmp 57.295779513082 :1` (18-23) · `Math.ArcCos` (12-17) · `Math.ArcTan` (24-29).
- `Math.GetDegrees` `FF` → `MULF :0 57.295779513082 :1` (48-51) · `Math.GetRadians` `FF` → `DIVF` (52-55).
- `Math.Ceiling` `FF` → `MATH CEIL`; `CP_EQF tmp 0.0 flag`; `SELECTF flag 0.0 tmp :1` (30-37).
- `Math.Max` `FFF` → `CP_GTF` + `SELECTF` (72-77) · `Math.Min` `FFF` → `CP_LTF` + `SELECTF` (78-83).
- `Math.Power` `FFF` → `MATH POW` (88-91) · `Math.Remainder` `FFF` → `MATH MOD` float (92-95).
- `Math.GetRandomNumber` `FF` → `RANDOM 1 range_16 value` (subcall, 56-67).

**Опасная инверсия:** `Sin/Cos/Tan` принимают **градусы** (умножают на 57.29… перед вызовом), а `ArcSin/ArcCos/ArcTan` возвращают **градусы** (делят радианы). VM работает в радианах.

### 2.9 MOTOR — порт-дескрипторный API — `c_Motor.txt`

Порты — **строка**: `"A"`, `"AB"`, `"1A"` (цифра 1..4 = слой). Декодер `MOTORDECODEPORTSDESCRIPTOR` (`c_Motor.txt:34-73`): `'A'..'D'`/`'a'..'d'` → бит `(c-65)`/`(c-97)` в `nos`; `'1'..'4'` → `layer = c-49`. Пустой `nos` → метод становится no-op (все начинаются с `JR_EQ8 nos 0 noport`). Одиночный порт — `MOTORDECODEPORTDESCRIPTOR` (`c_Motor.txt:75-112`).

| Метод | Сиг. | Ключевые опкоды / ограничения | Стр. |
|---|---|---|---|
| `Motor.Stop` | `SSV` | `brake` сравнивается с `'TRUE'` после upcase → `OUTPUT_STOP layer nos brk` | 114-131 |
| `Motor.Start` | `SFV` | speed clamp [-100,100] → `OUTPUT_TIME_SPEED layer nos spd 0 2147483647 0 0` | 134-157 |
| `Motor.StartPower` | `SFV` | power clamp → `OUTPUT_TIME_POWER …` | 159-182 |
| `Motor.StartSteer` | `SFFV` | clamp, `turn *= 2.0` → `OUTPUT_STEP_SYNC layer nos spd trn 0 0` | 240-261 |
| `Motor.StartSync` | `SFFV` | clamp; turn из отношения | 263-306 |
| `Motor.GetSpeed` | `SF` | `OUTPUT_READ layer no speed tacho`; знак инвертируется | 310-338 |
| `Motor.IsBusy` | `SS` | `OUTPUT_TEST layer nos busy` → `'True'`/`'False'` | 340-358 |
| `Motor.Schedule` | `SFFFFSV` | steps через `MATH ABS` → `OUTPUT_STEP_SPEED layer nos spd stp1 stp2 stp3 brk` | 361-393 |
| `Motor.SchedulePower` | `SFFFFSV` | → `OUTPUT_STEP_POWER …` | 395-427 |
| `Motor.ScheduleSteer` | `SFFFSV` | clamp, `turn *= 2.0` → `OUTPUT_STEP_SYNC layer nos spd trn cnt brk` | 496-519 |
| `Motor.ScheduleSync` | `SFFFSV` | clamp; turn из отношения | 521-566 |
| `Motor.ResetCount` | `SV` | `OUTPUT_CLR_COUNT layer nos` | 568-579 |
| `Motor.GetCount` | `SF` | `OUTPUT_GET_COUNT layer no tacho`; знак инвертируется | 599-626 |
| `Motor.Invert` | `SV` | `OUTPUT_POLARITY layer nos -1` + правка `MOTORISINVERTED` | 581-597 |
| `Motor.Move` | `SFFSV` | `CALL MOTOR.SCHEDULE :0 :1 0.0 :2 0.0 :3` + ожидание через `OUTPUT_TEST`/`SLEEP` | 649-664 |
| `Motor.MovePower` | `SFFSV` | `CALL MOTOR.SCHEDULEPOWER …` + ожидание | 666-681 |
| `Motor.MoveSteer` | `SFFFSV` | `CALL MOTOR.SCHEDULESTEER …` + ожидание | 683-698 |
| `Motor.MoveSync` | `SFFFSV` | `CALL MOTOR.SCHEDULESYNC …` + ожидание | 700-715 |
| `Motor.Wait` | `SV` | цикл `OUTPUT_TEST` + `SLEEP` до `busy == 0` | 718-730 |
| `Motor.GetCountFast` | `FF` | порт-число 0..3 → `OUTPUT_GET_COUNT 0 no tacho` (знак **не** инвертируется) | 628-639 |
| `Motor.GetCountFastA` | `F` | `OUTPUT_GET_COUNT 0 0 outTachoA` | 641-646 |

`MOTORDECODEPORTSDESCRIPTOR`, `MOTORDECODEPORTDESCRIPTOR`, `MOTORSTARTSTEERIMPL`, `MOTORSCHEDULESTEERIMPL` — внутренние subcall'ы, из Basic не адресуемы (нет в `DefaultObjectList`). Состояние инверсии — `ARRAY8 MOTORISINVERTED 4`, инициализируется в `init` (`c_Motor.txt:8-32`).

### 2.10 MOTORA/B/C/D — `c_Motor{A,B,C,D}.txt`

Все 14 методов — `inline`, порт зашит. Различие между файлами — **одна цифра**: порт-индекс X = A:0, B:1, C:2, D:3; `nos = X+1` (битовая маска), `layer = 0`. Ссылки ниже — по `c_MotorA.txt`.

- `.GetTacho` `F` → `OUTPUT_GET_COUNT 0 X getTachoX` + `MOVE32_F` (9-13). `.GetSpeed` `F` → `OUTPUT_READ 0 X getSpeedX tmpTachoX` + `MOVE8_F` (15-19).
- `.ResetCount` `V` → `OUTPUT_CLR_COUNT 0 X+1` (21-24). `.SetDirectPolarity` `V` → `OUTPUT_POLARITY 0 X+1 1` (26-29). `.SetReversPolarity` `V` → `OUTPUT_POLARITY 0 X+1 -1` (31-34).
- `.Off` `V` → `OUTPUT_POWER 0 X+1 0` + `OUTPUT_STOP 0 X+1 0` (36-40). `.OffAndBrake` `V` → `… OUTPUT_STOP 0 X+1 1` (42-46).
- `.IsLarge` `V` → `OUTPUT_SET_TYPE 0 X 7` (nos = 0, **не** маска!) (48-51). `.IsMedium` `V` → `OUTPUT_SET_TYPE 0 X 8` (53-56).
- `.SetSpeed` `FV` → `MOVEF_8 :0 setSpeedX` + `OUTPUT_SPEED 0 X+1 setSpeedX` (58-62). `.SetPower` `FV` → то же, `OUTPUT_POWER` (64-68).
- `.StartSpeed` `FV` → `OUTPUT_SPEED` + `OUTPUT_START` (70-75). `.StartPower` `FV` → `OUTPUT_POWER` + `OUTPUT_START` (77-82). `.Start` `V` → `OUTPUT_START 0 X+1` (84-87).

`IsLarge`/`IsMedium` **не возвращают значение**, несмотря на имя — только шлют `OUTPUT_SET_TYPE` (7 = large, 8 = medium).

### 2.11 MOTORAB/AC/AD/BC/BD/CD — `c_Motor{AB,AC,AD,BC,BD,CD}.txt`

7 методов, все `inline`, без собственных переменных — используют глобальные `setSpeedA`/`setPowerA`. `nos` = маска пары; AB=3, AC=5, AD=9, BC=6, BD=10, CD=12 (таблица — `c_BitMask.txt`).

- `.Off` `V` → `OUTPUT_POWER 0 nos 0` + `OUTPUT_STOP 0 nos 0` (`c_MotorAB.txt:3-8`). `.OffAndBrake` `V` → `… OUTPUT_STOP 0 nos 1` (9-14).
- `.SetSpeed` `FV` → `MOVEF_8 :0 setSpeedA` + `OUTPUT_SPEED 0 nos setSpeedA` (15-20). `.SetPower` `FV` → `OUTPUT_POWER 0 nos setPowerA` (21-26).
- `.StartSpeed` `FV` → `OUTPUT_SPEED` + `OUTPUT_START` (27-33). `.StartPower` `FV` → `OUTPUT_POWER` + `OUTPUT_START` (34-40). `.Start` `V` → `OUTPUT_START 0 nos` (41-45).

**Квирк:** `MotorAB.SetSpeed` пишет в `setSpeedA` — **ту же ячейку**, что `MotorA.SetSpeed`. Порядок вызовов влияет на результат; аналогично `setPowerA`.

### 2.12 PROGRAM — `c_Program.txt`

- `Program.Delay` `FV` → `TIMER_WAIT ms timer` + `TIMER_READY timer` (inline, 23-30). `Program.End` `V` → `PROGRAM_STOP -1` (32-35).
- `Program.Directory` `S` → `FILENAME(GET_FOLDERNAME,127,result)` (9-13).
- `Program.ArgumentCount` `F` → **заглушка: всегда `0`** (`MOVE8_F 0 result`, 3-7). `Program.GetArgument` `FS` → **заглушка: всегда `''`** (15-20).

Аргументы командной строки в этой ветке кода не реализованы — считать заглушками.

### 2.13 ROW — `c_Row.txt`

Handle — это `number`, не массив (`DefaultObjectList.cs:279`); запись `arr[i]` для handle **не работает** (`Row/Row.bp:2-3`).

- `Row.Init` `FFF` → `ARRAY CREATEF size` + `ARRAY FILL value`, возвращает handle (6-12). `Row.Delete` `FV` → `ARRAY DELETE handle` (14-18).
- `Row.Read` `FFF` → `ARRAY_READ handle index value` (20-25). `Row.Write` `FFFV` → `ARRAY_WRITE handle index value` (27-32).
- `Row.Size` `FF` → `ARRAY SIZE`; после `Delete` вернёт 0, не падает (34-39). `Row.Resize` `FFV` → `ARRAY RESIZE`, новые элементы нулятся (41-46).

### 2.14 SENSOR — порт-дескрипторный API — `c_Sensor.txt`

Порт — **число 1..4**. Везде `layer = (port-1)/4` (`DIV8`), `no = (port-1) mod 4` (`MATH MOD8`), см. 16-19.

- `GetName` `FS` → `INPUT_DEVICE GET_NAME layer no 32 result` + `STRINGS STRIP` (8-23).
- `GetType` / `GetMode` `FF` → `INPUT_DEVICE GET_TYPEMODE layer no type mode` → `MOVE8_F type`/`mode` (25-61).
- `GetDataFormat` `FS` → `INPUT_DEVICE GET_FORMAT` → строка `datasets,format,modes` (63-96).
- `SetMode` `FFV` / `Wait` `FV` → `INPUT_DEVICE READY_RAW layer no 0 mode8 0` / `INPUT_READY layer no` (inline; 98-112, 137-146).
- `IsBusy` `FS` → `INPUT_TEST layer no busy` → `'True'`/`'False'` (114-135).
- `ReadPercent` `FF` → `INPUT_READ layer no 0 -1 percentage`; отрицательное → `0` (149-170).
- `ReadRaw` `FFA` / `ReadRawValue` `FFF` → `INPUT_READEXT layer no 0 -1 18 8` + 8×`DATA32`; `READ32 rawvalue0 index8` (172-267).
- `CommunicateI2C` `FFFFAA` → `INPUT_DEVICE SETUP layer no 1 0 wrt8 outdata rd8 indata` (269-360).
- `ReadI2CRegister` `FFF` / `ReadI2CRegisters` `FFFFA` → `SETUP … 2 outdata 1 indata` (+ побайтовое чтение) (362-452).
- `WriteI2CRegister` `FFFFV` / `WriteI2CRegisters` `FFFFAV` → `SETUP` с 3 / N байтами outdata (454-548).
- `SendUartData` `FFAV` → `INPUT_WRITE layer no wrt8 outdata` (551-607).

`ReadPercent`/`ReadRaw` возвращают `0.0`, если `rawtmp < -1000000000` (214, 260) — маркер «нет данных».

### 2.15 SENSOR1..4 — `c_Sensor{1,2,3,4}.txt`

- `SensorN.Raw1` `F` → `INPUT_READEXT 0 (N-1) 0 -1 18 1 sNout1` + `MOVE32_F sNout1 :0` (inline, `c_Sensor1.txt:14-18`).
- `SensorN.Raw3` `FFFV` → `INPUT_READEXT 0 (N-1) 0 -1 18 3 sNout1 sNout2 sNout3` + 3×`MOVE32_F` (20-26).

`DATA32 sNout1..3` объявлены в каждом файле (3-5) и нулятся в `init` (7-12). `layer` зашит `0` — «быстрый» путь работает только с первой цепочкой (4 порта).

### 2.16 SPEAKER — `c_Speaker.txt`

- `Speaker.Stop` `V` → `SOUND BREAK` (inline, 3-6). `Speaker.Wait` `V` → `SOUND_READY` (inline, 72-75).
- `Speaker.Tone` `FFFV` → volume→I8, tone→I16, duration→I16, `SOUND TONE vol tne dur` (8-22). `Speaker.Note` `FSFV` → `NOTE_TO_FREQ note tne` + `SOUND TONE` (24-38).
- `Speaker.Play` `FSV` → `STRINGS ADD '../../../..' filename fullname`; при не-абсолютном пути `'../prjs/' filename`; `SOUND PLAY vol fullname` (40-56).
- `Speaker.IsBusy` `S` → `SOUND_TEST busy` → `'True'`/`'False'` (58-70).

### 2.17 TEXT — `c_Text.txt`

| Метод | Сиг. | Семантика | Стр. |
|---|---|---|---|
| `Text.Append` | `SSS` | `STRINGS GET_SIZE`; при сумме > 251 возвращает только `a` | 3-23 |
| `Text.ConvertToLowerCase` | `SS` | побайтово через `MEMORY_READ`/`MEMORY_WRITE`; ASCII + Latin-1 | 25-57 |
| `Text.ConvertToUpperCase` | `SS` | аналогично | 59-91 |
| `Text.EndsWith` | `SSS` | `MEMORY_READ` по **абсолютному** адресу 512 | 93-136 |
| `Text.GetIndexOf` | `SSF` | индекс с 1; не найдено → `0` | 138-182 |
| `Text.IsSubText` | `SSS` | `'True'`/`'False'` | 184-227 |
| `Text.StartsWith` | `SSS` | `MEMORY_WRITE` по адресу 512 | 230-266 |
| `Text.GetSubText` | `SFFS` | start с 1; `sublength` в (0,1] трактуется как 1 | 299-350 |
| `Text.GetSubTextToEnd` | `SFS` | start с 1 | 352-381 |
| `Text.GetLength` | `SF` | `STRINGS GET_SIZE` | 383-391 |
| `Text.GetCharacter` | `FS` | код 1..255 → 1-байтовая строка; иначе `chr(1)` | 268-285 |
| `Text.GetCharacterCode` | `SF` | первый байт строки, маска 255 | 287-297 |

**Опасное место.** Шесть методов (`EndsWith`, `StartsWith`, `IsSubText`, `GetIndexOf`, `GetSubText`, `GetSubTextToEnd`) используют `MEMORY_READ/WRITE` с жёсткими адресами 508/512 и комментарием `// assumes that the current program runs in slot 1` (`c_Text.txt:124-127`). Из другого slot'а они читают чужую память.

### 2.18 THREAD — `c_Thread.txt`

| Метод/событие | Сиг. | Семантика | Стр. |
|---|---|---|---|
| `Thread.Yield` | `V` | `SLEEP` (inline) | 54-57 |
| `Thread.CreateMutex` | `F` | `ARRAY SIZE LOCKS idx` + `ARRAY_APPEND LOCKS zero`; возвращает индекс | 59-71 |
| `Thread.Lock` | `FV` | цикл `CALL GETANDSETLOCK :0 1 previous:#`, пока `previous != 0`; иначе `SLEEP` | 73-82 |
| `Thread.Unlock` | `FV` | `CALL GETANDSETLOCK :0 0 dummy:#` | 84-88 |
| `Thread.Run` | **EVENT** | `Thread.Run = SUBNAME`; см. ниже | `Compiler.cs:960-979` |

`Thread.Run` — не метод, а присваивание свойства. Генерируется (`Compiler.cs:960-979`):

```
    DATA32 tmp<L>
    CALL GETANDINC32 RUNCOUNTER_<ID> 1  RUNCOUNTER_<ID> tmp<L>
    JR_NEQ32 0 tmp<L> alreadylaunched<L>
    OBJECT_START T<ID>
  alreadylaunched<L>:
```

Один sub не запускается дважды: счётчик `RUNCOUNTER_<ID>` инкрементируется атомарно через subcall `GETANDINC32` — VM гарантирует, что subcall не выполняется параллельно в двух потоках (`c_Thread.txt:11-25`). Генерация потоков — `Compiler.cs:352-378` (`vmthread T<ID>` с `JR_GT32 tmp 1 launch` для перезапуска); `Compiler.cs:390-441` создаёт `subcall PROGRAM_MAIN` + `subcall PROGRAM_<ID>` с общей реализацией (alias через `subcall NAME`) и `IN_32 SUBPROGRAM` как селектор входа.

### 2.19 TIME — `c_Time.txt`

9 таймеров; глобальные `DATA32 timeMC1..9` и `timeMC1..9tmp`. Единица — миллисекунды (float).

- `Time.GetN` `F` → `TIMER_READ timeMCNtmp`; `SUB32 tmp timeMCN tmp`; `MOVE32_F tmp :0` (`c_Time.txt:34-95`).
- `Time.ResetN` `V` → `TIMER_READ timeMCN` (97-138).

### 2.20 VECTOR — `c_Vector.txt`

| Метод | Сиг. | Семантика | Стр. |
|---|---|---|---|
| `Vector.Init` | `FFA` | `ARRAY RESIZE a size32` + `ARRAY FILL a value`; size ≤ 0 → resize 0 | 3-19 |
| `Vector.Data` | `FSA` | парсит числа, разделённые пробелами, через 8-битные буферы `d0`/`d1` и `STRINGS STRING_TO_VALUE` | 21-77 |
| `Vector.Add` | `FAAA` | поэлементная сумма; отсутствующие = 0 | 79-118 |
| `Vector.Sort` | `FAA` | QuickSort (порт Darel Rex Finley); допускает `a == arr` | 121-250 |
| `Vector.Multiply` | `FFFAAA` | умножение матриц N×K на K×M; `C == A` или `C == B` → временный буфер | 252-… |

`Vector.Sort` использует `ARRAY32 beg 128` / `ARRAY32 end 128` — при >128 элементов стек переполняется и портит локальные данные; проверки нет.

### 2.21 Внутренние `F.*`

Не в `DefaultObjectList`; распознаются до обращения к `library`, поэтому валидны.

| Имя | Тип | Назначение | Ссылка |
|---|---|---|---|
| `F.START` | присваивание | распознаётся и **игнорируется** (обработано в 1-м проходе) | `Compiler.cs:981-984` |
| `F.FUNCTION` | вызов | игнорируется | `Compiler.cs:996-1000` |
| `F.SET` | метод | `F.SET("NAME", value)` — запись параметра функции | `Compiler.cs:1004-1019` |
| `F.GET` | метод | `F.GET("NAME")` — чтение параметра | `Compiler.cs:1555-1570` |
| `F.RETURN` / `F.RETURNNUMBER` / `F.RETURNTEXT` | метод | `JR RETSUB_<sub>`; только в первичном sub функции | `Compiler.cs:1021-1052` |
| `F.CALL` / `F.CALLNUMBER` / `F.CALLTEXT` | метод | вызов user-функции | `Compiler.cs:1053-1083`, `Compiler.cs:1571-1594` |

---

## 3. Отображение Basic → ассемблер (вне встроенных методов)

### 3.1 Операторы

| Basic | Генерация | Ссылка |
|---|---|---|
| числовой литерал | inline-константа, `*.0` если целое | `Expression.cs:111-122` |
| текст `"…"` | `'…'` | `Compiler.cs:1692-1724` |
| переменная `a` | `V<A>` | `Compiler.cs:1500`, `Compiler.cs:1537` |
| `a + b` (обе константы) | свёртка на этапе компиляции | `Compiler.cs:1334-1341` |
| `a + b` (числа) | `ADDF a b out` | `Compiler.cs:1344` |
| `a - b` | `SUBF` | `Compiler.cs:1364-1374` |
| `a * b` | `MULF` | `Compiler.cs:1389` |
| `a / b` | `DATAF tmpf:#` / `DATA8 flag:#` / `DIVF` / `CP_EQF 0.0 :1 flag:#` / `SELECTF` (деление на 0 → 0) | `Compiler.cs:1406-1415` |
| `a / b` при `PRAGMA NODIVISIONCHECK` | `DIVF a b out` | `Compiler.cs:1402` |
| `-a` | `MATH NEGATE a out` | `Compiler.cs:1443` |
| строка + число | число → `STRINGS VALUE_FORMATTED :0 '%g' 99`, затем `CALL TEXT.APPEND` | `Compiler.cs:1300-1311` |
| `=` (числа) | `CALL EQ_FLOAT` либо `JR_EQF`/`JR_NEQF` | `Compiler.cs:1211` |
| `=` (строки) | `CALL EQ_STRING` | `Compiler.cs:1213` |
| `<>` | `CALL NEQ_FLOAT` / `CALL NE_STRING` | `Compiler.cs:1233-1237` |
| `<` | `JR_LTF` / `JR_GTEQF` | `Compiler.cs:1249` |
| `>` | `JR_GTF` / `JR_LTEQF` | `Compiler.cs:1257` |
| `<=` | `JR_LTEQF` / `JR_GTF` | `Compiler.cs:1265` |
| `>=` | `JR_GTEQF` / `JR_LTF` | `Compiler.cs:1273` |

`AND`/`OR` в позиции условия **не** генерируют вызов: `AndExpression` (`Expression.cs:367-381`) и `OrExpression` (`Expression.cs:390-404`) раскрываются в короткое замыкание через метки `and<L>`/`or<L>`. Как значение — `CALL AND` / `CALL OR` (`Expression.cs:364,386`).

### 3.2 Условие → переход

`Expression.GenerateJumpIfCondition` (`Expression.cs:76-88`) для произвольной текстовой строки:

```
    AND8888_32 <v> -538976289 <v>      // upcase 4 буквы, маска 0xDFDFDFDF
    STRINGS COMPARE <v> 'TRUE' <v>
    JR_EQ8 <v> 0 <label>               // JR_NEQ8 при jumpIfTrue
```

`AtomicExpression` со строковым литералом проверяется на этапе компиляции (`Expression.cs:149-161`): `'TRUE'` → безусловный `JR`; иной литерал → переход не генерируется вовсе.

### 3.3 Присваивание, массивы, вызовы

| Конструкция | Генерация | Ссылка |
|---|---|---|
| `v = expr` | `expr.Generate` в `V<v>`; тип `V<v>` фиксируется при первом присваивании | `Compiler.cs:859-891` |
| `a[i] = num` (boundscheck) | `CALL ARRAYSTORE_FLOAT :0 :1 V<a>` | `Compiler.cs:931-934` |
| `a[i] = num` (NOBOUNDSCHECK, const i ≥ 0) | `ARRAY_WRITE V<a> <i> :0`; при i < 0 — ничего | `Compiler.cs:915-924` |
| `a[i] = num` (NOBOUNDSCHECK, runtime i) | `MOVEF_32 :0 INDEX` + `ARRAY_WRITE V<a> INDEX :1` | `Compiler.cs:926-930` |
| `a[i] = str` | `CALL ARRAYSTORE_STRING :0 :1 V<a>` | `Compiler.cs:909-911` |
| `a[i]` (num, boundscheck) | `CALL ARRAYGET_FLOAT :0 :1 V<a>` | `Compiler.cs:1528` |
| `a[i]` (num, NOBOUNDSCHECK) | `ARRAY_READ V<a> i out` | `Expression.cs:419-452` |
| `a[i]` (str) | `CALL ARRAYGET_STRING :0 :1 V<a>` | `Compiler.cs:1524` |
| `SUBNAME()` | `WRITE32 ENDSUB_<N>:CALLSUB<L> STACKPOINTER RETURNSTACK` / `ADD8 STACKPOINTER 1 STACKPOINTER` / `JR SUB_<N>` / `CALLSUB<L>:` | `Compiler.cs:840-848` |
| `GOTO L` | `JR L<label>` | `Compiler.cs:794-809` |
| `L:` | `L<label>:` | `Compiler.cs:850-853` |

Конец каждого sub (`Compiler.cs:561-570`):

```
RETSUB_<NAME>:
    SUB8 STACKPOINTER 1 STACKPOINTER
    READ32 RETURNSTACK STACKPOINTER INDEX
    JR_DYNAMIC INDEX
ENDSUB_<NAME>:
```

`ENDSUB_<NAME>` — адрес (разница меток), а не инструкция. Стек — `ARRAY32 RETURNSTACK 128` + `ARRAY32 RETURNSTACK2 128` (`Compiler.cs:399-401`), адресация 8-битная со скольжением.

### 3.4 Управляющие структуры

| Структура | Метки | Ссылка |
|---|---|---|
| `IF cond THEN … ELSEIF … ELSE … ENDIF` | `else<L>_1`, `else<L>_2`, …, `endif<L>` | `Compiler.cs:631-690` |
| `WHILE cond … ENDWHILE` | `while<L>`, `whilebody<L>`, `endwhile<L>`; условие генерируется **дважды** | `Compiler.cs:692-714` |
| `FOR v = a TO b STEP s … ENDFOR` | `for<L>`, `forbody<L>`, `endfor<L>` | `Compiler.cs:716-792` |

`FOR` со STEP (`Compiler.cs:745-760`): положительный литерал → `JR_LTEQF`; отрицательный → `JR_GTEQF`; неопределённый знак → `CALL LE_STEP`. Приращение всегда `ADDF`. `WHILE` генерирует условие дважды (`Compiler.cs:704`, `Compiler.cs:712`) — удваивает побочные эффекты и расход временных переменных.

---

## 4. Таблица опкодов EV3 VM

Источник — `Interpreter/Assembler/Resources/bytecodelist.txt`. Формат: `XXYY NAME_SUB NAME P1 P2 …`; `XXYY` — 1 или 2 байта опкода. Суффиксы параметров: `8/16/32/F` — тип, `L` — метка, `T` — thread id, `S` — subcall id, `P` — счётчик параметров, `?` — неопределённый. `*` = запись, `+` = чтение массива/строки, без суффикса = чтение.

### 4.1 Программы и объекты

`00 ERROR` · `01 NOP` · `02 PROGRAM_STOP 16` (остановить программу, `-1` = текущая) · `03 PROGRAM_START 16 32 32 8` · `04 OBJECT_STOP T` · `05 OBJECT_START T` · `06 OBJECT_TRIG T` · `07 OBJECT_WAIT T` · `08 RETURN` · `09 CALL subcall-id numpar …` · `0A OBJECT_END` · `0B SLEEP`.

`CALL` (`0x09`) **не описан** в `bytecodelist.txt` — обрабатывается жёстко в `Assembler.cs:345-375`: `0x09`, `AddConstant(sc.id)`, `AddConstant(numpar)`, затем аргументы. Терминаторы дописываются автоматически: subcall — `0x08` + `0x0A` (`LMSObject.cs:431-433`), thread — только `0x0A` (`LMSObject.cs:300`).

### 4.2 PROGRAM_INFO, метки, отладка

`0C00 PROGRAM_INFO OBJ_STOP 16 16` · `0C04 PROGRAM_INFO OBJ_START 16 16` · `0C16 PROGRAM_INFO GET_STATUS 16 8*` · `0C17 PROGRAM_INFO GET_SPEED 16 32*` · `0C18 PROGRAM_INFO GET_PRGRESULT 16 8*` · `0D LABEL 8` · `0E PROBE 16 16 32 32` · `0F DO 16 32 32`.

### 4.3 Арифметика и логика

`10/11/12/13 ADD8/ADD16/ADD32/ADDF`, `14/15/16/17 SUB8/SUB16/SUB32/SUBF`, `18/19/1A/1B MUL8/MUL16/MUL32/MULF`, `1C/1D/1E/1F DIV8/DIV16/DIV32/DIVF` — все `t t t*`.

`20/21/22 OR8/OR16/OR32`, `24/25/26 AND8/AND16/AND32` — `t t t*`. `26 AND8888_32 8+ 32 8*` — AND над 4 байтами строки с маской `-538976289` = `0xDFDFDFDF` (upcase). `28/29/2A XOR8/XOR16/XOR32` — `t t t*`. `2C/2D/2E RL8/RL16/RL32` — `t t t*` (сдвиг влево). `2F INIT_BYTES 8* P 8`.

### 4.4 Пересылки

`30 MOVE8_8 8 8*` · `30 EXTRACTLOWBYTE 32 8*` (младший байт как знаковый, даёт `-128`) · `30 INJECTLOWBYTE 8* 32` (байт → беззнаковый int) · `31/32/33 MOVE8_16/MOVE8_32/MOVE8_F 8 X*` · `34/35/36/37 MOVE16_8/MOVE16_16/MOVE16_32/MOVE16_F 16 X*` · `38/39/3A/3B MOVE32_8/MOVE32_16/MOVE32_32/MOVE32_F 32 X*` · `3C/3D/3E/3F MOVEF_8/MOVEF_16/MOVEF_32/MOVEF_F F X*`.

### 4.5 Переходы

`40 JR L` (безусловный) · `40 JR_DYNAMIC 32` (косвенный — возврат из sub) · `41 JR_FALSE 8 L` (если 0) · `42 JR_TRUE 8 L` (если ≠0) · `43 JR_NAN F L`.

`64`-`67 JR_LT8/16/32/F` · `68`-`6B JR_GT8/16/32/F` · `6C`-`6F JR_EQ8/16/32/F` · `70`-`73 JR_NEQ8/16/32/F` · `74`-`77 JR_LTEQ8/16/32/F` · `78`-`7B JR_GTEQ8/16/32/F` — все `t t L`.

### 4.6 Сравнения и выбор

`44`-`47 CP_LT8/16/32/F` · `48`-`4B CP_GT8/16/32/F` · `4C`-`4F CP_EQ8/16/32/F` · `50`-`53 CP_NEQ8/16/32/F` · `54`-`57 CP_LTEQ8/16/32/F` · `58`-`5B CP_GTEQ8/16/32/F` — все `t t 8*`.

`5C/5D/5E/5F SELECT8/SELECT16/SELECT32/SELECTF` — `8 t t t*`.

**Квирк:** `CP_LT32` объявлен как `16 16 8*` (а не `32 32 8*`) — `bytecodelist.txt:79`. Вероятная опечатка исходного списка; воспроизвести для побайтовой совместимости.

### 4.7 Системные, порты, звук

`60 SYSTEM 8+ 8*` (shell-команда) · `61 PORT_CNV_OUTPUT 32 8* 8* 8*` · `62 PORT_CNV_INPUT 32 8* 8*` · `63 NOTE_TO_FREQ 8 16*` (нотное имя → частота) · `7C01 INFO SET_ERROR 8` · `7C02 INFO GET_ERROR 8*` · `7C03 INFO ERRORTEXT 8 8 8*` · `7C04/7C05 INFO GET_VOLUME 8*`/`SET_VOLUME 8` · `7C06/7C07 INFO GET_MINUTES 8*`/`SET_MINUTES 8`.

### 4.8 Строки (`7D`)

`7D01 GET_SIZE 8+ 16*` (длина) · `7D02 ADD 8+ 8+ 8*` (конкатенация) · `7D03 COMPARE 8+ 8+ 8*` (`0` = равны) · `7D05 DUPLICATE 8+ 8*` (копирование) · `7D06 VALUE_TO_STRING F 8 8 8*` · `7D07 STRING_TO_VALUE 8+ F*` · `7D08 STRIP 8+ 8*` · `7D09 NUMBER_TO_STRING 16 8 8*` · `7D0A SUB 8+ 8+ 8*` · `7D0B VALUE_FORMATTED F 8+ 8 8*` · `7D0C NUMBER_FORMATTED 32 8+ 8 8*`. Все — `STRINGS`.

### 4.9 Память и UI

`7E MEMORY_WRITE 16 S 32 32 8+` (запись в память другого slot) · `7F MEMORY_READ 16 S 32 32 8*` · `80 UI_FLUSH`.

`8101`-`811F UI_READ` (`bytecodelist.txt:158-181`): `8101 GET_VBATT`, `8102 GET_IBATT`, `8103 GET_OS_VERS`, `8104 GET_EVENT`, `8105 GET_TBATT`, `8106 GET_IINT`, `8107 GET_IMOTOR`, `8108 GET_STRING`, `8109 GET_HW_VERS`, `810A GET_FW_VERS`, `810B GET_FW_BUILD`, `810C GET_OS_BUILD`, `810D GET_ADDRESS`, `810E GET_CODE`, `810F KEY`, `8110 GET_SHUTDOWN`, `8111 GET_WARNING`, `8112 GET_LBATT`, `8115 TEXTBOX_READ`, `811A GET_VERSION`, `811B GET_IP`, `811D GET_POWER`, `811E GET_SDCARD`, `811F GET_USBSTICK`.

`8201`-`821F UI_WRITE` (183-203): `8201 WRITE_FLUSH`, `8202 FLOATVALUE`, `8203 STAMP`, `8208 PUT_STRING`, `8209 VALUE8`, `820A VALUE16`, `820B VALUE32`, `820C VALUEF`, `820F DOWNLOAD_END`, `8210 SCREEN_BLOCK`, `8215 TEXTBOX_APPEND`, `8216 SET_BUSY`, `8218 SET_TESTPIN`, `8219 INIT_RUN`, `821A UPDATE_RUN`, `821B LED`, `821D POWER`, `821E GRAPH_SAMPLE`, `821F TERMINAL`.

`8301`-`830F UI_BUTTON` (205-219): `8301 SHORTPRESS`, `8302 LONGPRESS`, `8303 WAIT_FOR_PRESS`, `8304 FLUSH`, `8305 PRESS`, `8306 RELEASE`, `8307 GET_HORZ`, `8308 GET_VERT`, `8309 PRESSED`, `830A SET_BACK_BLOCK`, `830B GET_BACK_BLOCK`, `830C TESTSHORTPRESS`, `830D TESTLONGPRESS`, `830E GET_BUMBED`, `830F GET_CLICK`.

`8400`-`8420 UI_DRAW` (221-253): `8400 UPDATE`, `8401 CLEAN`, `8402 PIXEL`, `8403 LINE`, `8404 CIRCLE`, `8405 TEXT`, `8406 ICON`, `8407 PICTURE`, `8408 VALUE`, `8409 FILLRECT`, `840A RECT`, `840B NOTIFICATION`, `840C QUESTION`, `840D KEYBOARD`, `840E BROWSE`, `840F VERTBAR`, `8410 INVERSERECT`, `8411 SELECT_FONT`, `8412 TOPLINE`, `8413 FILLWINDOW`, `8415 DOTLINE`, `8416 VIEW_VALUE`, `8417 VIEW_UNIT`, `8418 FILLCIRCLE`, `8419 STORE`, `841A RESTORE`, `841B ICON_QUESTION`, `841C BMPFILE`, `841F GRAPH_DRAW`, `8420 TEXTBOX`. Форматы операндов — в `bytecodelist.txt:221-253`.

### 4.10 Таймеры, математика, случайные

`85 TIMER_WAIT 32 32*` (пауза, выводит id таймера) · `86 TIMER_READY 32` · `87 TIMER_READ 32*` (мс) · `88`-`8B BP0`-`BP3` (breakpoint) · `8C BP_SET 16 8 32` · `8E RANDOM 16 16 16*` · `8F TIMER_READ_US 32*` (мкс) · `90 KEEP_ALIVE 8`.

`8D01`-`8D15 MATH`: `8D01 EXP`, `8D02 MOD`, `8D03 FLOOR`, `8D04 CEIL`, `8D05 ROUND`, `8D06 ABS`, `8D07 NEGATE`, `8D08 SQRT`, `8D09 LOG`, `8D0A LN`, `8D0B SIN`, `8D0C COS`, `8D0D TAN`, `8D0E ASIN`, `8D0F ACOS`, `8D10 ATAN` — все `F F*`; `8D11 MOD8`, `8D12 MOD16`, `8D13 MOD32` — `t t t*`; `8D14 POW` — `F F F*`; `8D15 TRUNC` — `F 8 F*`. Исключение: `8D02 MOD` — `F F F*` (3 параметра), а не 2.

### 4.11 Звук и устройства ввода

`910E COM_READ COMMAND 32 32* 32* 8*` · `920E COM_WRITE REPLY 32* 32*` · `9400 SOUND BREAK` · `9401 SOUND TONE 8 16 16` (volume, freq, duration) · `9402 SOUND PLAY 8 8+` · `9403 SOUND REPEAT 8 8+` · `95 SOUND_TEST 8*` · `96 SOUND_READY` · `98 INPUT_DEVICE_LIST 8 8* 8*`.

`9902`-`991F INPUT_DEVICE` (303-325): `9902 GET_FORMAT`, `9903 CAL_MINMAX`, `9904 CAL_DEFAULT`, `9905 GET_TYPEMODE`, `9906 GET_SYMBOL`, `9907 CAL_MIN`, `9908 CAL_MAX`, `9909 SETUP`, `990A CLR_ALL`, `990B GET_RAW`, `990C GET_CONNECTION`, `990D STOP_ALL`, `9915 GET_NAME`, `9916 GET_MODENAME`, `9917 SET_RAW`, `9918 GET_FIGURES`, `9919 GET_CHANGES`, `991A CLR_CHANGES`, `991B READY_PCT`, `991C READY_RAW`, `991D READY_SI`, `991E GET_MINMAX`, `991F GET_BUMPS`.

`9A INPUT_READ 8 8 8 8 8*` (проценты) · `9B INPUT_TEST 8 8 8*` · `9C INPUT_READY 8 8` · `9D INPUT_READSI 8 8 8 8 F*` · `9E INPUT_READEXT 8 8 8 8 8 P ?*` (сырые, P значений) · `9F INPUT_WRITE 8 8 8 8*` (UART).

`READY_PCT`/`READY_RAW`/`READY_SI`/`READEXT` используют `P` — ассемблер расширяет список аргументов (`Assembler.cs:483-497`).

### 4.12 Моторы (OUTPUT)

`A1 SET_TYPE 8 8 8` (7 = large, 8 = medium) · `A2 RESET 8 8` (сброс слоя по маске) · `A3 STOP 8 8 8` (layer, nos, brake) · `A4 POWER 8 8 8` · `A5 SPEED 8 8 8` · `A6 START 8 8` · `A7 POLARITY 8 8 8` · `A8 READ 8 8 8* 32*` (speed, tacho) · `A9 TEST 8 8 8*` (busy) · `AA READY 8 8`.

`AC STEP_POWER`, `AD TIME_POWER`, `AE STEP_SPEED`, `AF TIME_SPEED` — все `8 8 8 32 32 32 8` (величина + 3 шага + brake). `B0 STEP_SYNC`, `B1 TIME_SYNC` — `8 8 8 16 32 8` (speed, turn, steps, brake). `B2 CLR_COUNT 8 8` · `B3 GET_COUNT 8 8 32*` · `B4 PRG_STOP`.

### 4.13 Файлы (`C0`)

`C000 OPEN_APPEND 8+ 16*` · `C001 OPEN_READ 8+ 16* 32*` · `C002 OPEN_WRITE 8+ 16*` · `C003 READ_VALUE 16 8 F*` · `C004 WRITE_VALUE 16 8 F 8 8` · `C005 READ_TEXT 16 8 16 8*` · `C006 WRITE_TEXT 16 8 8+` · `C007 CLOSE 16` · `C008 LOAD_IMAGE 16 8+ 32* 32*` · `C009 GET_HANDLE 8+ 16* 8*` · `C00A MAKE_FOLDER 8+ 8*` · `C00B GET_POOL 32 16* 32*` · `C00C SET_LOG_SYNC_TIME 32 32` · `C00D GET_FOLDERS 8+ 8*` · `C00E GET_LOG_SYNC_TIME 32* 32*` · `C00F GET_SUBFOLDER_NAME 8+ 8 8 8*` · `C010 WRITE_LOG 16 32 8 F*` · `C011 CLOSE_LOG 16 8+` · `C012 GET_IMAGE 8+ 16 8 32*` · `C013 GET_ITEM 8+ 8+ 8*` · `C014 GET_CACHE_FILES 8*` · `C015 PUT_CACHE_FILE 8+` · `C016 GET_CACHE_FILE 8 8 8*` · `C017 DEL_CACHE_FILE 8 8 8*` · `C018 DEL_SUBFOLDER 8+ 8+` · `C019 GET_LOG_NAME 8 8*` · `C01B OPEN_LOG 8+ 32 32 32 32 32 8 16*` · `C01C READ_BYTES 16 16 8*` · `C01D WRITE_BYTES 16 16 8*` · `C01E REMOVE 16` · `C01F MOVE 8+ 8+` (все — `FILE`).

### 4.14 Массивы, память, имена файлов

`C100 ARRAY DELETE 16` · `C101 ARRAY CREATE8 32 16*` · `C102 CREATE16` · `C103 CREATE32` · `C104 CREATEF` · `C105 RESIZE 16 32` · `C106 FILL 16 ?` · `C107 COPY 16 16` · `C108 ARRAY INIT8 16 32 P t` · `C109 INIT16` · `C10A INIT32` · `C10B INITF` · `C10C ARRAY SIZE 16 32*` · `C10D READ_CONTENT 16 16 32 32 8*` · `C10E WRITE_CONTENT 16 16 32 32 8*` · `C10F READ_SIZE 16 16 32*`.

`C2 ARRAY_WRITE 16 32 ?` (запись элемента) · `C3 ARRAY_READ 16 32 ?*` (чтение) · `C4 ARRAY_APPEND 16 ?+` · `C5 MEMORY_USAGE 32* 32*`.

`C610`-`C617 FILENAME` (409-416): `C610 EXIST`, `C611 TOTALSIZE`, `C612 SPLIT`, `C613 MERGE`, `C614 CHECK`, `C615 PACK`, `C616 UNPACK`, `C617 GET_FOLDERNAME`.

`C8 READ8 8* 8 8*` · `C9 READ16 16* 8 16*` · `CA READ32 32* 8 32*` · `CB READF F* 8 F*` (косвенное чтение) · `CC WRITE8 8 8 8*` · `CD WRITE16 16 8 16*` · `CE WRITE32 32 8 32*` · `CF WRITEF F 8 F*` (косвенная запись) · `D0 COM_READY 8 8*`.

`FILENAME(GET_FOLDERNAME,127,result)` (`c_Program.txt:12`) — синтаксис с круглыми скобками; `TokenizeLine` пропускает `(`, `)`, `,` (`Assembler.cs:655-658`).

### 4.15 COM и MAILBOX

`D301`-`D314 COM_GET` (430-446): `D301 GET_ON_OFF`, `D302 GET_VISIBLE`, `D304 GET_RESULT`, `D305 GET_PIN`, `D306 SEARCH_ITEMS`, `D309 SEARCH_ITEM`, `D30A FAVOUR_ITEMS`, `D30B FAVOUR_ITEM`, `D30C GET_ID`, `D30D GET_BRICKNAME`, `D30E GET_NETWORK`, `D30F GET_PRESENT`, `D310 GET_ENCRYPT`, `D311 CONNEC_ITEMS`, `D312 CONNEC_ITEM`, `D313 GET_INCOMING`, `D314 GET_MODE2`.

`D401`-`D40D COM_SET` (448-459): `D401 SET_ON_OFF`, `D402 SET_VISIBLE`, `D403 SET_SEARCH`, `D405 SET_PIN`, `D406 SET_PASSKEY`, `D407 SET_CONNECTION`, `D408 SET_BRICKNAME`, `D409 SET_MOVEUP`, `D40A SET_MOVEDOWN`, `D40B SET_ENCRYPT`, `D40C SET_SSID`, `D40D SET_MODE2`.

`D5 COM_TEST 8 8+ 8*` · `D6 COM_REMOVE 8 8+` · `D7 COM_WRITEFILE 8 8+ 8+ 8` · `D8 MAILBOX_OPEN 8 8+ 8 8 8` · `D9 MAILBOX_WRITE 8+ 8 8+ 8 8 ?+` · `DA MAILBOX_READ 8 16 8 ?*` · `DB MAILBOX_TEST 8 8*` · `DC MAILBOX_READY 8` · `DD MAILBOX_CLOSE 8`.

Форматы операндов `COM_GET *` и `COM_SET *` — в `bytecodelist.txt:430-459`.

---

## 5. Кодирование операндов и данных

### 5.1 Константы (`LMSObject.cs:72-93`)

| Диапазон | min байт | Кодирование |
|---|---|---|
| `-32 … 31` | ≤ 1 | 1 байт: `value & 0x3F` |
| `-128 … 127` | ≤ 2 | `0x81`, 1 байт |
| `-32768 … 32767` | ≤ 3 | `0x82`, 2 байта LE |
| иначе | — | `0x83`, 4 байта LE |

Параметр `minimumencodingbytes` нужен при back-patching меток, чтобы гарантировать известную длину placeholder'а.

### 5.2 Переменные (`LMSObject.cs:95-120`)

| Индекс | Кодирование |
|---|---|
| `0 … 31` | 1 байт: `(local ? 0x40 : 0x60) \| index` |
| `32 … 127` или `-127 … -1` | `local ? 0xC1 : 0xE1`, 1 байт |
| 16-битный | `local ? 0xC2 : 0xE2`, 2 байта LE |
| 32-битный | `local ? 0xC3 : 0xE3`, 4 байта LE |

Биты `0x40`/`0x60` различают локальную и глобальную область. Поиск: сначала локальные, затем глобальные (`Assembler.cs:552-566`); не найдено → `AssemblerException("Unknown identifier …")`.

Суффикс `+N` в имени (`Assembler.cs:540-548`) добавляет смещение к позиции — используется в `c_runtimelibrary.txt:297` (`v+1`, `v+2`, …) для `ARRAY INIT8`.

### 5.3 Строки (`LMSObject.cs:122-135`)

`0x80`, байты строки, `0x00`. Только ASCII: символ вне `1..255` → `AssemblerException("String literal contains non-ascii character")` (`LMSObject.cs:128-131`).

Ограничения: Basic-строка ≤ 251 символа (`Compiler.cs:1467-1470`); `OUT_S` ≤ 255 байт (`LMSObject.cs:351-354`). Внутренние буферы модулей: `252` для строк, `300` для полных имён файлов, `504`–`512` для MEMORY-областей.

### 5.4 Float-константы (`LMSObject.cs:137-148`)

Префикс `0x83`, затем 4 байта IEEE-754 single. Поскольку `0x83` означает «32-битная константа», **float и int32 неразличимы на уровне кодирования** — различие обеспечивает тип параметра опкода (`DataType.F` vs `DataType.I32`).

### 5.5 Метки (`LMSObject.cs:150-202`)

Обратная ссылка (метка определена): расстояние `target - program.Length`, `minimumencodingbytes` = 1/2/3/5 по величине (`LMSObject.cs:159-179`); смещение −1/−2/−3/−5 компенсирует длину самого параметра, чтобы точка отсчёта была началом инструкции.

Прямая ссылка: placeholder `0x83 00 00 00 00`, позиция в `references[program.Length + 1]` (`LMSObject.cs:183-189`). При `WriteByteCodes` (`LMSObject.cs:214-262`) патчится `labels[label] - (i + 4)`.

Разница меток `A:B` (`LMSObject.cs:232-243`) патчится как `labels[B] - labels[A]` (32-битная константа) — механизм `WRITE32 ENDSUB_X:CALLSUBL STACKPOINTER RETURNSTACK`.

### 5.6 Формат `.rbf` (`Assembler.cs:596-635`)

```
'L' 'E' 'G' 'O'
u32 imgsize        = totalheadersize + len(allbytecodes)
u16 version        = 0x0068
u16 numobjects
u32 globals.TotalBytes()
[numobjects] { u32 offsetToInstructions; u16 owner(0); u16 triggercount(0=thread,1=subcall); u32 localbytes }
[allbytecodes]
```

`totalheadersize = 16 + numobjects * 12` (`Assembler.cs:605`). Объекты нумеруются в порядке появления (`objects.Count + 1`); этот номер используется как ID в `CALL`. Заголовок subcall'а-алиаса указывает на `implementation.offsetToInstructions` (`LMSObject.cs:370-376`).

### 5.7 IO-дескрипторы subcall (`LMSObject.cs:378-447`)

Тело subcall'а начинается с числа параметров (1 байт) и по 1–2 байта на параметр:

| Биты | Значение |
|---|---|
| `0x80` + тип | вход |
| `0x40` + тип | выход |
| `0xC0` + тип | вход-выход |
| тип `0x00` / `0x01` / `0x02` / `0x03` | I8 (одиночный) / I16 / I32 / F |
| тип `0x04` + длина | строка I8 |

`IN_S`/`OUT_S`/`IO_S` — это `DataType.I8` с `ioStringSizes[i] != 0` (`LMSObject.cs:349-358`). После кода дописываются `0x08` (RETURN) и `0x0A` (OBJECT_END).

При интеграции все вызовы проверяются на число параметров и типы (`LMSObject.cs:436-446`); несовпадение → `AssemblerException`. Это основной источник ошибок «Detected use of CALL X with N parameters instead of M».

### 5.8 Выравнивание данных (`DataArea.cs:57-84`)

Элемент размещается по адресу, кратному размеру; при необходимости добавляется padding. **Параметры (IN_/OUT_/IO_) не могут быть дополнены padding'ом** (`DataArea.cs:73-80`) и **не могут идти после DATA** (`DataArea.cs:64-71`) — иначе `AssemblerException`. Отсюда жёсткий порядок в модулях: сначала все `IN_*`/`OUT_*`, затем `DATA*`. Порт, генерирующий тот же `.rbf`, обязан воспроизвести порядок.

---

## 6. Медиа: звук и картинки

### 6.1 Синтаксис

| Конструкция | Расширение | Пример |
|---|---|---|
| `LCD.BmpFile(col,x,y,"имя")` | `.rgf` | `Other/GraphicsAndSounds.bp:19` |
| `Speaker.Play(vol,"имя")` | `.rsf` | `Other/GraphicsAndSounds.bp:22` |
| `EV3File.OpenWrite("имя")` | любое | `Other/File.bp:4` |
| `EV3File.OpenAppend("имя")` | любое | — |
| `EV3File.OpenRead("имя")` | любое | `Other/File.bp:15` |
| `EV3File.TableLookup("имя",bpr,row,col)` | любое | `c_EV3File.txt:221` |

### 6.2 `MediaBuilder.cs`

`MediaBuilder.ParseMedia(Line)` (`MediaBuilder.cs:14-124`) вызывается препроцессором для каждой строки, **только если задана папка проекта** (`Data.Project.IsFolder`, `MediaBuilder.cs:16-19`). Условие срабатывания (`MediaBuilder.cs:22,39,56,73,90,107`):

```
text.ToLower().IndexOf("<метод>") != -1
  AND ( text.IndexOf("'") == -1 OR text.ToLower().IndexOf("<метод>") > text.IndexOf("'") )
  AND в строке не менее двух '"' (вторая правее первой)
```

Имя медиа-файла задаётся **двойными кавычками**; одинарная кавычка (комментарий Basic) левее вызова отключает обработку. Имя извлекается между первой и последней `"` (`MediaBuilder.cs:128-130`), путь переписывается, строка **перестраивается заново** (`LineBuilder.GetWords`). Итоговое имя попадает в Basic-строку, а значит — в байткод как строковый литерал.

### 6.3 Подстановка пути (`MediaBuilder.cs:201-343`)

| `Folder` | `ProjectName` | Путь (media) | `mediaPath` |
|---|---|---|---|
| `prjs` | задан | `<ProjectName>/Media/<name>` | `<ProjectName>/Media/` |
| `sd` | задан | `SD_Card/<ProjectName>/Media/<name>` | `SD_Card/<ProjectName>/Media/` |
| `prjs`/`sd` | пусто | `<name>` | `"no"` |
| иначе | — | `<name>` | `"no"` |

В списки добавляется **с расширением**: `+ ".rgf"` для картинок (`MediaBuilder.cs:136`), `+ ".rsf"` для звуков (`156`), без расширения — для файлов (`176`, `192`). Дедупликация по имени. Для `TableLookup` хвост строки после закрывающей `"` сохраняется как есть (`MediaBuilder.cs:189,305`).

### 6.4 Что попадает в байткод

`MediaBuilder` **не генерирует** отдельных опкодов — он лишь переписывает строковый аргумент. В `.rbf` попадает:

| Вызов | Итог |
|---|---|
| `LCD.BmpFile` | `UI_DRAW BMPFILE col_8 x_16 y_16 <fullname>` (`c_LCD.txt:266`); `c_LCD.txt:259-264` приписывает `'/home/root/lms2012/prjs/'` при не-абсолютном пути, затем `'.rgf'` |
| `Speaker.Play` | `SOUND PLAY vol <fullname>` (`c_Speaker.txt:55`); `c_Speaker.txt:50-52` — два `STRINGS ADD` в один буфер: сначала `'../../../..'`, затем `'../prjs/'`, то есть первый всегда перезаписывается |
| `EV3File.Open*` | `FILE OPEN_* <fullname>`; префикс `/home/root/lms2012/prjs/` при не-абсолютном пути (`c_EV3File.txt:11-15,28-32,46-50`) |
| `EV3File.TableLookup` | строка shell-команды `tablelookup <path> <bpr> <row> <col>` → `EV3.NativeCode` (`c_EV3File.txt:240-253`) |

Списки `ImageList`/`SoundList`/`FileList` в байткод **не попадают** — они нужны среде разработки для копирования файлов на brick.

---

## 7. Ошибки и диагностика

### 7.1 Два независимых канала

| Канал | Кто формирует | Куда | Проверяет |
|---|---|---|---|
| **Препроцессор** | `Interpreter/Parsers/*.cs` + `DefaultObjectList` | `Data.Errors` (`List<Errore>`), коды `ErrorsCodeList` | существование метода/свойства, число аргументов, грубая типизация |
| **Компилятор** | `Compiler.cs` через `Scanner.ThrowParseError` | `List<string> errorlist` | точные типы, неопределённые идентификаторы, структура управления |

`Builder.BPStart` (`Builder.cs:83-135`) останавливается на первой фазе с ошибками, поэтому при успешной компиляции препроцессор уже пропустил вызов.

### 7.2 Ошибки компилятора

Все — `CompileException` с суффиксом `at: <line>:<col>` (1-based; `Scanner.cs:85-88`). **Предупреждений компилятор не генерирует:** `errorlist` содержит только ошибки, успех — пустой список.

Неопределённые имена и вызовы: `Undefined command: <OBJ>.<ELEM>` — нет `library[cmdname]` при вызове как выражении (`Compiler.cs:1078`) · `Undefined command or property: <CMD>` — нет в `library` при чтении значения (1576) · `Unknown property to set: <OBJ>.<ELEM>` — `obj.elem = …`, кроме `THREAD.RUN` и `F.START` (987) · `Can not reference <CMD> as a property` — вызов без `(`, но есть параметры (1625) · `Reference to undefined function: <NAME>` — `memorize_reference` (534) · `Unknown PRAGMA: <NAME>` (601).

Возвращаемые значения: `Can not use command that returns nothing in an expression` — `returnType == Void` в позиции значения (1581) · `Return value that is an array must be directly stored in a variable` — результат-массив в temp (1096) · `Can only use RETURN from inside function` (1030) · `Can only use RETURN in primary SUB of a function` (1034) · `Return command must be of same type as function definiton` (1044).

Арность и типы: `Too few arguments to <CMD>` — `list.Count < paramTypes.Length` (1616) · `Too many arguments for function: <NAME>` — превышен `getParameterNumber()` (1071, 1594) · `Undefined function: <NAME>` — `F.CALL` по неизвестному имени (1060, 1587) · `Undefined local variable: <NAME>` — `F.SET`/`F.GET` (1012, 1565) · `Can not use this expression type here: <T>. Expected: <T2>` — несовпадение типа аргумента (1122) · `Need identical types on both sides of '='` / `'<>'` (1206, 1227) · `Can not compare arrays` (1215, 1239) · `Can not concat arrays` — `+` с массивом (1305, 1318, 1349, 1372).

Переменные и массивы: `Can not assign different types to <NAME>` — повторное присваивание другого типа (880) · `Can not use <NAME> as loop counter. Is already defined to contain non-number` — `FOR` по не-числовой (728) · `Can not use <NAME> as array to store this type` (906) · `Can only store numbers or strings into arrays` (900) · `can not use variable <NAME> before first assignment` (1544) · `can not use array <NAME> before first assignment` (1510) · `Need array to use with '[]'` — `[]` по скаляру (1518).

Прочее: `Text is longer than 251 letters` — литерал > 251 (1468) · `Need a text as a boolean value here` — условие `IF`/`WHILE` не текст (639, 700) · `Unexpected <TYPE> <CONTENT>` — `ThrowUnexpectedSymbol` (`Scanner.cs:109`) · `Expected <TYPE>` / `Expected <TEXT>` — `ThrowExpectedSymbol` (`Scanner.cs:116,121`).

### 7.3 Ошибки препроцессора

Ключевые для встроенных объектов (`ErrorsCodeList.cs`, RU):

| Код | Текст | Ссылка |
|---|---|---|
| 1301 | Метод не найден | `ErrorsCodeList.cs:74` |
| 1304 | Неверное количество параметров | 77 |
| 1305 | Переменной не присвоено значение | 78 |
| 1306 | Метод в качестве параметра не возвращает значений | 79 |
| 1307 | Неверный тип параметра | 80 |
| 1308 | Неверное количество параметров, либо отсутствует математический оператор | 81 |
| 1309 | Недопустимый математический оператор | 82 |
| 1310 | Разные типы данных | 83 |
| 1311 | Лишние математические операторы | 84 |
| 1312 | Отсутствует параметр | 85 |
| 1313 | Метод не возвращает значений | 86 |
| 1314 | Неправильное определение метода | 87 |
| 1820 | Параметр имеет другой тип | 159 |
| 1821 | В вызове функции выходной параметр может быть только переменной | 160 |

Число аргументов — `MethodErrorParser.cs:39-42` (`signature.InputCount != param.Count` → 1304); типы — `MethodErrorParser.cs:43-60` (1307/1310); неизвестное имя — `MethodErrorParser.cs:31-32` (1301).

### 7.4 Ошибки ассемблера

С номером строки: `"Error at line <N>: <msg>"` (`Assembler.cs:99-101`); этап линковки — `"Error at subcall integration: <msg>"` (`Assembler.cs:104-106`).

| Сообщение | Условие |
|---|---|
| `Unknown opcode <X>` | нет в `bytecodelist` |
| `Too few parameters for <NAME>` | меньше, чем в дескрипторе |
| `Invalid number of parameters for <NAME>` | итоговое число не совпало |
| `Unknown identifier <NAME>` | переменная не найдена нигде |
| `Identifier <NAME> already in use` | дубликат в `DataArea` |
| `Can not place IN,OUT,IO elements after DATA elements` | порядок объявлений |
| `Can not insert padding for propper alignment…` | невозможно выровнять параметр |
| `Duplicate definition of <NAME>` | два объекта с одним именем |
| `Unresolved subcall: <NAME>` | тело subcall не сгенерировано |
| `Unresolved jump target: <LABEL>` | метка не определена |
| `Unresolved label distance: <A>:<B>` | одна из меток не определена |
| `Trying to call an object that is not defined as a SUBCALL` | `CALL` на `vmthread` |
| `Trying to start an object that is not defined as a thread` | `OBJECT_START` на subcall |
| `Detected use of CALL <NAME> with <N> parameters instead of <M>` | несовпадение арности при линковке |
| `Using variable of wrong type for call: <NAME>` | `DataTypeChecker` (`DataType.cs:56-64`) |
| `Using constant value as parameter where a variable reference is required` | константа в output-параметре |
| `Constant value <N> out of range of I8/I16` | выход за диапазон |
| `Can not use float literal '<F>' for this parameter type` | float не в F-параметр |
| `Can not use string literal '<S>' for this parameter type` | строка не в I8-параметр |
| `Length of IO parameter must not exceed 255 bytes` | `IN_S x 300` |

---

## 8. Квирки и опасные места

| № | Квирк | Следствие для портирования |
|---|---|---|
| 1 | Встроенные методы — текстовые модули, а не таблица опкодов (`Compiler.cs:73-105`) | Перенести 31 файл ресурсов и парсер `readLibraryModule` |
| 2 | `c_BitMask.txt` не в `readLibrary` | Не читать его как модуль |
| 3 | Placeholder'ы `:0..:9`, `:#` (`Expression.cs:267-311`) | Нужен шаблонизатор с трекингом использованных аргументов |
| 4 | Неупомянутые аргументы дописываются в конец (`Expression.cs:223-230`) | `MATH FLOOR`, `MATH LOG` и др. работают только благодаря этому |
| 5 | `MOTORA` и `MOTORAB.SETSPEED` пишут в общую `setSpeedA` | Порядок вызовов меняет поведение |
| 6 | `Math.Sin/Cos/Tan` принимают градусы; `ArcSin/ArcCos/ArcTan` возвращают градусы | Легко перепутать при переносе |
| 7 | `CP_LT32` объявлен `16 16 8*` (`bytecodelist.txt:79`) | Вероятная опечатка; воспроизвести для побайтовой совместимости |
| 8 | Три опкода делят `0x30`, два — `0x26` | Разрешение имён по строке, не по опкоду (`Assembler.cs:391-406`) |
| 9 | `PROGRAM.ARGUMENTCOUNT`/`GETARGUMENT` — заглушки (`c_Program.txt:3-20`) | Не «дореализовывать» без сверки |
| 10 | `TEXT.*` и `ASSERT.FAILED` используют `MEMORY_READ/WRITE` с адресами 508/512 | Работает только из slot 1 |
| 11 | `Vector.Sort` использует `ARRAY32 beg 128` | Переполнение при >128 элементах |
| 12 | `EV3.SetLEDColor` не обрабатывает `'OFF'` явно → `col = 0` | Недокументированное поведение |
| 13 | `Speaker.Play` дважды пишет в один буфер `fullname` | Первый префикс всегда перезаписывается |
| 14 | `DefaultObjectList` и `library` — разные каталоги | Кодогенерация опирается на `library` (`*.txt`) |
| 15 | `EV3.NATIVECODE` требует вставки `CreateNativeCodeDownload()` в MAIN (`Compiler.cs:340-344`) | Не сводится к обычному `CALL` |
| 16 | `Thread.Run` — присваивание, а не вызов (`Compiler.cs:960-979`) | Отдельная ветка парсера |
| 17 | Атомарность `Thread.Lock` опирается на гарантию VM о непараллельности subcall (`c_Thread.txt:11-15`) | Нет прямого аналога без поддержки VM |
| 18 | `DataArea`: параметры до данных, без padding (`DataArea.cs:57-84`) | Порядок объявлений в `.lmsb` критичен |
| 19 | `WHILE` генерирует условие дважды (`Compiler.cs:704,712`) | Удваивает побочные эффекты и расход временных |
| 20 | FLOAT и I32 константы кодируются одинаково (`0x83` + 4 байта) | Различие только через `DataType` дескриптора |
| 21 | Строки только ASCII 1..255 (`LMSObject.cs:128-131`) | Unicode-литерал → ошибка ассемблера |
| 22 | `Builder.BPStart` останавливается на первой фазе (`Builder.cs:85-100`) | Ошибки препроцессора скрывают ошибки компилятора |
| 23 | `Scanner.ThrowParseError` добавляет `at: line:col` (`Scanner.cs:85-88`) | Формат сообщений нужно сохранить |
| 24 | `LibraryEntry.programCode` для inline режется до **первого** `}` (`LibraryEntry.cs:54-56`) | Вложенные `{}` в inline-теле невозможны |
| 25 | `Sensor1..4` жёстко используют `layer = 0` (`c_Sensor1.txt:16`) | Дейзи-чейн для «быстрых» методов недоступен |
| 26 | `Motor.IsLarge`/`IsMedium` не возвращают значение | Имя вводит в заблуждение |
| 27 | `Byte.ToBinary` использует магические маски `983055`/`286331153` | Не заменять на цикл — результат должен совпасть побитово |

---

## 9. Резюме

1. **Кодогенерация двухслойная.** `Compiler.cs` переводит Basic в *текст ассемблера* EV3-Basic-диалекта (верхний регистр, опкоды из `bytecodelist.txt`); `Assembler.cs` — в байты `.rbf`. Порт на Mojo должен воспроизвести оба слоя.
2. **Встроенные методы — это 31 текстовый модуль-ресурс** (`Interpreter/Compiler/Resources/c_*.txt`), регистрируемых в `Compiler.cs:73-105`. Каждый объявлен как `inline` (код подставляется) либо `subcall` (отдельный объект VM). `init`-блоки безусловно попадают в `vmthread MAIN`.
3. **Placeholder'ы `:0..:9` и `:#` — сердце механизма** (`Expression.cs:267-311`): неиспользованные аргументы автоматически дописываются в конец, на чём построены `MATH FLOOR`, `MATH LOG` и др.
4. **`DefaultObjectList.cs` — не источник истины для кодогенерации.** Он нужен только препроцессору для проверки имён и арности (`MethodErrorParser.cs:31`). Реальные сигнатуры — в `library` (`LibraryEntry` из `*.txt`); расхождения возможны (`EV3.NATIVECODE` есть в `library`, но отсутствует в `DefaultObjectList`).
5. **Каталог: 25 адресуемых классов** — `assert`, `buttons`, `byte`, `ev3`, `ev3file`, `lcd`, `mailbox`, `math`, `motor`, `motora..motord`, `motorab..motorcd`, `program`, `row`, `sensor`, `sensor1..sensor4`, `speaker`, `text`, `thread`, `time`, `vector`, плюс внутренние `F.*`. Опкоды: управление (00–0F), арифметика (10–2F), пересылки (30–3F), переходы (40–7B), строки (7D), UI (80–84), таймеры и математика (85–8F), звук и ввод (94–9F), моторы (A1–B4), файлы (C0), массивы (C1–C5), COM и mailbox (D3–DD).
6. **Главные риски портирования:** (а) воспроизведение `DataArea`-порядка с выравниванием и без padding для параметров — иначе `.rbf` не соберётся; (б) четыре формы кодирования констант и переменных (`LMSObject.cs:72-120`); (в) back-patching меток с переменной длиной (`LMSObject.cs:150-202`); (г) `TEXT.*` и `ASSERT.FAILED`, читающие память по абсолютным адресам, — непереносимы без slot-семантики; (д) опечатка `CP_LT32 16 16 8*`, которую нужно воспроизвести; (е) `Motor*` делят `setSpeedA`/`setPowerA` между классами; (ж) `Vector.Sort` ограничен 128 элементами; (з) `PROGRAM.ARGUMENTCOUNT`/`GETARGUMENT` — заглушки.
7. **Тест приёмки:** побайтовое сравнение с `~Program1/Program1.rbf`, `tests/corpus/Other/~Battery/Battery.rbf` и `tests/corpus/Other/~ButtonsAndMotors/ButtonsAndMotors.rbf`.