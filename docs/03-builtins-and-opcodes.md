# 03 — Встроенные классы, методы и опкоды EV3 VM

Документ описывает **два независимых слоя**:

1. **Слой трансляции Basic → ассемблер** (`Interpreter/Compiler/Compiler.cs` + `Interpreter/Compiler/Resources/*.txt`) — здесь встроенные имена (`lcd.text`, `motor.start`, ...) превращаются в строки ассемблерного текста.
2. **Слой ассемблирования** (`Interpreter/Assembler/*.cs` + `Interpreter/Assembler/Resources/bytecodelist.txt`) — здесь ассемблерный текст превращается в байты `.rbf`.

Ключевой факт для портирования: **встроенные методы — это не таблица «метод → опкод»**, а набор текстовых модулей на самом себе (EV3-Basic-подобный ассемблер). Компилятор их не разбирает по смыслу, он их *инлайнит как текст* или *вызывает как subcall*. Поэтому портирование кодогенерации = портирование (а) парсера вызовов, (б) механизма подстановки placeholder'ов `:0..:9` и `:#`, (в) 31 текстового модуля, (г) ассемблера.

Полный список модулей читается в `Compiler.cs:73-105` (`readLibrary`). Обратите внимание: `c_BitMask.txt` в списке **отсутствует** — это справочная таблица битовых масок моторов, в код не попадает.

---

## 1. Механика встроенных объектов

### 1.1 Регистрация модулей

`readLibrary()` (`Compiler.cs:73-105`) вызывает `readLibraryModule(...)` для 31 ресурса. Разбор одного модуля — `Compiler.cs:109-168`:

| Строка модуля начинается с | Что делает компилятор | Ссылка |
|---|---|---|
| `subcall <NAME>` | создаёт `LibraryEntry(inline=false, ...)`, ключ `NAME.ToUpperInvariant()` | `Compiler.cs:150-152` |
| `inline <NAME>` | создаёт `LibraryEntry(inline=true, ...)` | `Compiler.cs:150-152` |
| `init` | текст тела складывается в `runtimeinit` со сдвигом 4 пробела | `Compiler.cs:142-147` |
| всё прочее (вне блока) | складывается в `runtimeglobals` (глобальные `DATA*/ARRAY*` всех модулей) | `Compiler.cs:125-138` |
| `//` | обрезается до конца строки | `Compiler.cs:130-134` |

Дескриптор после имени: `// FFSV  REF1 REF2` — первая группа это сигнатура (`Compiler.cs:154-156`), остальные — имена требуемых библиотечных функций (транзитивные зависимости через `memorize_reference`, `Compiler.cs:529-546`).

Коды типов сигнатуры — `LibraryEntry.cs:61-72`: `F`→Number, `S`→Text, `A`→NumberArray, `X`→TextArray, `V`→Void. **Последний символ — тип возврата**, все предыдущие — типы параметров (`LibraryEntry.cs:37-43`).

### 1.2 Два режима: `inline` и `subcall`

| | `inline` | `subcall` |
|---|---|---|
| Код в `.lmsb` | подставляется как текст в место вызова, тело вырезается из `{`…`}` (`LibraryEntry.cs:52-57`) | генерируется отдельный объект `subcall NAME {...}` в конце файла |
| Вызов в коде | `CallExpression` с `function = libentry.programCode` (`Compiler.cs:1101`) | `CallExpression` с `function = "CALL " + NAME` (`Compiler.cs:1101`) |
| Локальные данные | через `DATA8 x:#` — уникальный суффикс `#` на каждый вызов | собственный DataArea subcall'а (`LMSObject.cs:304-458`) |
| Попадает в `.lmsb` всегда | только если метод реально вызван | только если реально вызван (`references`, `Compiler.cs:461-468`) |
| `init`-блок | — | код из `init` попадает в `runtimeinit` **всегда**, независимо от использования |

`init`-блоки попадают в `vmthread MAIN` в порядке регистрации модулей (`Compiler.cs:334-337`). В `Program1.lmsb` это видно: `MOVE32_32 0 STOPLCDUPDATE` (LCD), `MOVE32_32 0 NUMMAILBOXES` (Mailbox), `OUTPUT_RESET 0 15` + 16×`WRITE8 ... FIRSTOF2` (Motor), `INPUT_DEVICE CLR_ALL -1` (Sensor), `ARRAY CREATE8 0 LOCKS` (Thread), `MOVE32_32 0 sNout1..3` (Sensor1-4), `MOVE32_32 0 timeMC1..9` (Time). Соответствует списку `Compiler.cs:75-104`.

### 1.3 Подстановка placeholder'ов

`CallExpression.Generate` (`Expression.cs:198-265`) собирает список аргументов и вызывает `InjectPlaceholders` (`Expression.cs:267-311`):

| Placeholder | Значение |
|---|---|
| `:0` … `:9` | аргумент №0…№9 (строка того, что вернул `PreparedValue()`, либо зарезервированная temp-переменная) |
| `:#` | уникальный числовой суффикс вызова (`compiler.GetLabelNumber()`, `Expression.cs:281-287`) — защита от коллизии имён локальных `DATA8 x:#` при повторном инлайне |

**Критично:** использованные placeholder'ы помечаются `null` (`Expression.cs:305-308`) и **не** дописываются в конец. Неиспользованные — дописываются в порядке объявления (`Expression.cs:223-230`). Это и есть механизм «выходной параметр в конец»: в модулях `MATH.ABS` (`c_Math.txt:8-11`) тело `MATH ABS :0 :1` использует оба, а `MATH.FLOOR` (`c_Math.txt:44-47`) — ни одного, поэтому реальный код будет `MATH FLOOR :0 :1`.

**Внимание:** `MATH.FLOOR`/`MATH.LOG`/`MATH.NATURALLOG`/`MATH.POWER`/`MATH.REMAINDER`/`MATH.ROUND`/`MATH.SQUAREROOT` в `c_Math.txt` **не упоминают** `:0/:1` вообще — они полагаются на авто-дописывание. Аналогично `TEXT.GETCHARACTERCODE` и др.

### 1.4 Резервирование временных переменных

`FunctionDefinition.reserveVariable` (`FunctionDefinition.cs:132-151`) выдаёт имена `F<fname>.<n>` / `S<fname>.<n>`; максимум (`getMaxReserved`) определяет, сколько `DATAF`/`DATAS` попадёт в объект (`Compiler.cs:394-411`). Имя функции в основной программе — пустое, поэтому в `Program1.lmsb` видны `F.0`, `F.1`, `S.0`. Для subcall `f_map_data_2` — `FF_MAP_DATA_2.<n>`. Имена **не** совпадают с basic-именами: глобальные basic-переменные получают префикс `V` (`Compiler.cs:722`, `Compiler.cs:861-863`).

Разделитель `.` в имени переменной допустим: ассемблерный токенизатор разрешает `.` внутри токена (`Assembler.cs:684`, `Assembler.cs:689`).

### 1.5 Обработка `DefaultObjectList`

`DefaultObjectList.cs:47-408` — **отдельный, независимый** каталог, используемый только препроцессором/парсерами ошибок (`Interpreter/Utils/Preprocessor.cs:25` вызывает `Install()`; потребители — `Interpreter/Parsers/MethodErrorParser.cs:31,37`, `LogicErrorParser.cs:395`, `ForLineErrorParser.cs:212`, `VariableErrorParser.cs:471`, `ArrayIndexErrorParser.cs:126`). Компилятор (`Compiler.cs`) его **не** использует.

Следствие: каталог в `DefaultObjectList` может расходиться с реальными сигнатурами в `*.txt`. Обнаруженные расхождения:

| Имя | `DefaultObjectList` | Реальный модуль | Комментарий |
|---|---|---|---|
| `assert.failed` | 1 арг. `ANY` → NON | `c_Assert.txt:3` `SV` (1 S) | согласовано |
| `assert.equal` | 3 арг. `ANY,ANY,ANY` → NON | `c_Assert.txt:32` `SSSV` | OK |
| `math.floor` | METHOD, 1 | `c_Math.txt:44` `FF` | OK |
| `math.getdegrees` / `getradians` | METHOD 1 → NUMBER | `c_Math.txt:48,52` `FF` | OK |
| `ev3.nativecode` | **отсутствует** | `c_EV3.txt:117` `SF` | вызывается только из `ev3file.tablelookup` |
| `motor.<*>`, `motora..motord.<*>` | полный список | `c_Motor*.txt` | OK |
| `sensor1..4.raw1/raw3` | 0/3 арг. | `c_Sensor1..4.txt` | OK |
| `program.directory` | METHOD 0 → STRING | `c_Program.txt:9` `S` (0 арг.) | OK |
| `byte.and_`, `byte.or_` | суффикс `_` | `c_Byte.txt:16,32` `BYTE.AND_`, `BYTE.OR_` | OK — `_` нужен, т.к. `and`/`or` — ключевые слова |

---

## 2. Каталог встроенных классов

Ниже: имя в Basic (регистр не важен — `parse_id`+`ToUpperInvariant`), сигнатура, семантика, файл:строка реализации.

### 2.1 ASSERT (`c_Assert.txt`, `LibraryEntry`-независимый; реализован как subcall)

| Метод | Сигнатура | Семантика | Реализация |
|---|---|---|---|
| `Assert.Failed` | `SV` | Рисует на LCD «ASSERT FAILED» + текст по строкам по 22 символа | `c_Assert.txt:3-30` |
| `Assert.Equal` | `SSSV` | `STRINGS COMPARE`; при несовпадении дописывает `' ('`, `a`, `'<>'`, `b`, `')'` и вызывает `Assert.Failed` | `c_Assert.txt:32-51` |
| `Assert.NotEqual` | `SSSV` | Обратное к `Equal` | `c_Assert.txt:53-65` |
| `Assert.Less` | `FFSV` | `JR_LTF a b isok` | `c_Assert.txt:89-98` |
| `Assert.Greater` | `FFSV` | `JR_GTF a b isok` | `c_Assert.txt:67-76` |
| `Assert.LessEqual` | `FFSV` | `JR_LTEQF` | `c_Assert.txt:100-109` |
| `Assert.GreaterEqual` | `FFSV` | `JR_GTEQF` | `c_Assert.txt:78-87` |
| `Assert.Near` | `FFSV` | epsilon = `1/5000000`; `b-eps < a < b+eps` | `c_Assert.txt:111-132` |

Зависимости: `Assert.Failed` требует `TEXT.GETSUBTEXT`, `TEXT.GETSUBTEXTTOEND` (`c_Assert.txt:3`); `Assert.Equal` — `ASSERT.FAILED`, `TEXT.APPEND` (`c_Assert.txt:32`).

### 2.2 BUTTONS (`c_Buttons.txt`)

| Метод/свойство | Сигнатура | Семантика | Реализация |
|---|---|---|---|
| `Buttons.GetClicks` | `S` (0 арг.) | Строка из нажатых за клик кнопок в порядке `U`,`E`,`D`,`R`,`L` | `c_Buttons.txt:200-230` |
| `Buttons.Wait` | `V` (0) | `UI_BUTTON WAIT_FOR_PRESS` — блокирует до нажатия | `c_Buttons.txt:232-235` |
| `Buttons.Flush` | `V` (0) | `UI_BUTTON FLUSH` | `c_Buttons.txt:237-240` |
| `Buttons.Current` | **property** `S` (0) | Дерево из 31 `UI_BUTTON PRESSED`; возвращает подмножество `UEDRL` или `''` | `c_Buttons.txt:3-198` |

### 2.3 BYTE (`c_Byte.txt`)

Все значения трактуются как 8-битные беззнаковые (маска `AND16 ... 255`).

| Метод | Сигнатура | Семантика | Реализация |
|---|---|---|---|
| `Byte.Not` | `FF` | Побитовое НЕ в 16 бит, маска 255 | `c_Byte.txt:3-14` |
| `Byte.And_` | `FFF` | И, маска 255 | `c_Byte.txt:16-30` |
| `Byte.Or_` | `FFF` | ИЛИ | `c_Byte.txt:32-46` |
| `Byte.Xor` | `FFF` | XOR | `c_Byte.txt:48-62` |
| `Byte.Bit` | `FFF` | Бит `index` (маска 255) | `c_Byte.txt:64-81` |
| `Byte.Shl` | `FFF` | Логический сдвиг влево, маска 255 | `c_Byte.txt:83-98` |
| `Byte.Shr` | `FFF` | Сдвиг вправо; если `distance > 7` → `0` | `c_Byte.txt:100-121` |
| `Byte.ToHex` | `FS` | `STRINGS NUMBER_FORMATTED '%02X'` | `c_Byte.txt:123-133` |
| `Byte.ToBinary` | `FS` | Растягивание битов в нибблы, `%08X` | `c_Byte.txt:135-157` |
| `Byte.ToLogic` | `FS` | `>0.0` → `'True'`, иначе `'False'` | `c_Byte.txt:159-169` |
| `Byte.H` | `SF` | Hex-строка → число (0-9, A-F, a-f), маска 255 | `c_Byte.txt:171-213` |
| `Byte.B` | `SF` | Бинарная строка → число, маска 255 | `c_Byte.txt:215-244` |
| `Byte.L` | `SF` | `'TRUE'` (после upcase через `AND8888_32`) → `1`, иначе `0` | `c_Byte.txt:246-258` |

### 2.4 EV3 (`c_EV3.txt`)

| Метод/свойство | Сигнатура | Семантика | Реализация |
|---|---|---|---|
| `EV3.SetLEDColor` | `SSV` | `color` ∈ GREEN/RED/ORANGE/OFF, `effect` ∈ NORMAL/FLASH/PULSE → `UI_WRITE LED col` | `c_EV3.txt:7-54` |
| `EV3.SystemCall` | `SF` | `SYSTEM` через shell, возвращает код (`result01` << 0 & 255) | `c_EV3.txt:95-111` |
| `EV3.QueueNextCommand` | `V` (0) | **Пустой inline** — no-op | `c_EV3.txt:113-115` |
| `EV3.BatteryLevel` | property `F` | `UI_READ GET_LBATT` | `c_EV3.txt:68-75` |
| `EV3.BatteryVoltage` | property `F` | `UI_READ GET_VBATT` | `c_EV3.txt:77-81` |
| `EV3.BatteryCurrent` | property `F` | `UI_READ GET_IBATT` | `c_EV3.txt:83-87` |
| `EV3.Time` | property `F` | `TIMER_READ` (мс с запуска VM) | `c_EV3.txt:56-65` |
| `EV3.BrickName` | property `S` | `COM_GET GET_BRICKNAME 18 result` | `c_EV3.txt:89-93` |
| `EV3.NativeCode` | `SF` | Запуск `/tmp/nativecode` через named pipes; **не** в `DefaultObjectList` | `c_EV3.txt:117-166` |

`EV3.SetLEDColor`: `'GREEN'`→1, `'RED'`→2, `'ORANGE'`→3; `+3` при `'FLASH'`, `+6` при `'PULSE'` (`c_EV3.txt:28-53`). `'OFF'` не обрабатывается явно — `col` остаётся `0`.

### 2.5 EV3FILE (`c_Ev3File.txt`)

| Метод | Сигнатура | Семантика | Реализация |
|---|---|---|---|
| `EV3File.OpenWrite` | `SF` | Путь без `/` → префикс `/home/root/lms2012/prjs/`; `FILE OPEN_WRITE` | `c_EV3File.txt:3-18` |
| `EV3File.OpenAppend` | `SF` | То же, `FILE OPEN_APPEND` | `c_EV3File.txt:20-35` |
| `EV3File.OpenRead` | `SF` | `FILE OPEN_READ` | `c_EV3File.txt:37-53` |
| `EV3File.Close` | `FV` | Проверка `1.0 ≤ handle ≤ 32767.0` | `c_EV3File.txt:55-65` |
| `EV3File.WriteLine` | `FSV` | `FILE WRITE_TEXT handle16 6 text` | `c_EV3File.txt:67-78` |
| `EV3File.WriteByte` | `FFV` | `FILE WRITE_BYTES handle16 1 byte8` | `c_EV3File.txt:80-93` |
| `EV3File.WriteNumberArray` | `FFAV` | Порциями по 4 байта из массива; выравнивание нулями при выходе за размер | `c_EV3File.txt:173-210` |
| `EV3File.ReadLine` | `FS` | `FILE READ_TEXT handle16 6 127 text` | `c_EV3File.txt:95-109` |
| `EV3File.ReadByte` | `FF` | `FILE READ_BYTES handle16 1 byte8` | `c_EV3File.txt:111-127` |
| `EV3File.ReadNumberArray` | `FFA` | Читает блоками по 4000 байт, `ARRAY WRITE_CONTENT` | `c_EV3File.txt:129-171` |
| `EV3File.ConvertToNumber` | `SF` | `STRINGS STRING_TO_VALUE` | `c_EV3File.txt:213-219` |
| `EV3File.TableLookup` | `SFFFF` | Строит shell-команду `tablelookup …` и вызывает `EV3.NativeCode` | `c_EV3File.txt:221-254` |

### 2.6 LCD (`c_LCD.txt`)

| Метод | Сигнатура | Семантика | Реализация |
|---|---|---|---|
| `LCD.StopUpdate` | `V` | `MOVE32_32 1 STOPLCDUPDATE` — подавляет `UI_DRAW UPDATE` | `c_LCD.txt:10-13` |
| `LCD.Update` | `V` | `STOPLCDUPDATE=0` + `UI_DRAW UPDATE` | `c_LCD.txt:15-19` |
| `LCD.Clear` | `V` | `UI_DRAW(TOPLINE,0)`, `UI_DRAW(CLEAN)` | `c_LCD.txt:21-29` |
| `LCD.Rect` | `FFFFFV` | `UI_DRAW RECT` (col,x,y,w,h) | `c_LCD.txt:31-55` |
| `LCD.Line` | `FFFFFV` | `UI_DRAW LINE` (col,x1,y1,x2,y2) | `c_LCD.txt:57-81` |
| `LCD.Text` | `FFFFSV` | `UI_DRAW SELECT_FONT font`, `UI_DRAW TEXT col x y text` | `c_LCD.txt:83-106` |
| `LCD.Write` | `FFSV` | То же, но font = 1 жёстко | `c_LCD.txt:108-125` |
| `LCD.Circle` | `FFFFV` | `UI_DRAW CIRCLE` | `c_LCD.txt:127-148` |
| `LCD.FillCircle` | `FFFFV` | `UI_DRAW FILLCIRCLE` | `c_LCD.txt:150-172` |
| `LCD.FillRect` | `FFFFFV` | `UI_DRAW FILLRECT` | `c_LCD.txt:174-198` |
| `LCD.InverseRect` | `FFFFV` | `UI_DRAW INVERSERECT` (x,y,w,h) | `c_LCD.txt:200-222` |
| `LCD.Pixel` | `FFFV` | `UI_DRAW PIXEL` | `c_LCD.txt:224-242` |
| `LCD.BmpFile` | `FFFSV` | Добавляет `'/home/root/lms2012/prjs/'` если путь не абсолютный; приписывает `.rgf`; `UI_DRAW BMPFILE` | `c_LCD.txt:244-271` |

Все методы, кроме `Clear`/`Update`/`StopUpdate`, заканчиваются `JR_NEQ32 0 STOPLCDUPDATE skipupdate` + `UI_DRAW UPDATE`.

### 2.7 MAILBOX (`c_Mailbox.txt`)

| Метод | Сигнатура | Семантика | Реализация |
|---|---|---|---|
| `Mailbox.Create` | `SF` | `MAILBOX_OPEN id8 boxname 4 0 0` (тип 4 = текст); ≥30 ящиков → `-1.0` | `c_Mailbox.txt:11-28` |
| `Mailbox.CreateForNumber` | `SF` | То же, тип 3 (число) | `c_Mailbox.txt:30-47` |
| `Mailbox.IsAvailable` | `FS` | `MAILBOX_TEST` → `'True'`/`'False'` | `c_Mailbox.txt:50-67` |
| `Mailbox.Receive` | `FS` | `MAILBOX_READY` затем `MAILBOX_READ no 252 1 :1` (inline) | `c_Mailbox.txt:69-75` |
| `Mailbox.ReceiveNumber` | `FF` | `MAILBOX_READ no 3 1 :1` | `c_Mailbox.txt:77-83` |
| `Mailbox.Send` | `SSSV` | `MAILBOX_WRITE brickname 0 boxname 4 1 message` | `c_Mailbox.txt:86-93` |
| `Mailbox.SendNumber` | `SSFV` | `MAILBOX_WRITE ... 3 1 message` | `c_Mailbox.txt:95-102` |
| `Mailbox.Connect` | `SV` | `COM_SET SET_CONNECTION 2 brickname 1` (inline) | `c_Mailbox.txt:105-110` |

### 2.8 MATH (`c_Math.txt`)

| Метод/свойство | Сигнатура | Реализация | Примечание |
|---|---|---|---|
| `Math.Pi` | property `F` | `c_Math.txt:3-6` | `MOVEF_F 3.1415926535897932384` |
| `Math.Abs` | `FF` | `c_Math.txt:8-11` | `MATH ABS` |
| `Math.ArcCos` | `FF` | `c_Math.txt:12-17` | `MATH ACOS` + `/57.295779513082` |
| `Math.ArcSin` | `FF` | `c_Math.txt:18-23` | `MATH ASIN` + /57.295… |
| `Math.ArcTan` | `FF` | `c_Math.txt:24-29` | `MATH ATAN` + /57.295… |
| `Math.Ceiling` | `FF` | `c_Math.txt:30-37` | `MATH CEIL`, `CP_EQF tmp 0.0 flag`, `SELECTF flag 0.0 tmp :1` |
| `Math.Cos` | `FF` | `c_Math.txt:38-43` | `MULF :0 57.295779513082` затем `MATH COS` (градусы!) |
| `Math.Floor` | `FF` | `c_Math.txt:44-47` | тело `MATH FLOOR`, аргументы дописываются автоматически |
| `Math.GetDegrees` | `FF` | `c_Math.txt:48-51` | `MULF :0 57.295779513082 :1` |
| `Math.GetRadians` | `FF` | `c_Math.txt:52-55` | `DIVF :0 57.295779513082 :1` |
| `Math.GetRandomNumber` | `FF` | `c_Math.txt:56-67` | `RANDOM 1 range_16 value` (subcall) |
| `Math.Log` | `FF` | `c_Math.txt:68-71` | Тело `MATH LOG` — **аргументы не упомянуты** |
| `Math.Max` | `FFF` | `c_Math.txt:72-77` | `CP_GTF` + `SELECTF` |
| `Math.Min` | `FFF` | `c_Math.txt:78-83` | `CP_LTF` + `SELECTF` |
| `Math.NaturalLog` | `FF` | `c_Math.txt:84-87` | `MATH LN` |
| `Math.Power` | `FFF` | `c_Math.txt:88-91` | `MATH POW` |
| `Math.Remainder` | `FFF` | `c_Math.txt:92-95` | `MATH MOD` (float) |
| `Math.Round` | `FF` | `c_Math.txt:96-99` | `MATH ROUND` |
| `Math.Sin` | `FF` | `c_Math.txt:100-105` | `MULF :0 57.295779513082` затем `MATH SIN` |
| `Math.SquareRoot` | `FF` | `c_Math.txt:106-109` | `MATH SQRT` |
| `Math.Tan` | `FF` | `c_Math.txt:110-115` | `MULF :0 57.295779513082` затем `MATH TAN` |

**Осторожно:** `arcsin/arccos/arctan` возвращают **градусы** (делят радианы), а `sin/cos/tan` принимают **градусы** (умножают на 57.29… перед вызовом) — VM работает в радианах. Это инверсия интуиции и источник ошибок при портировании.

### 2.9 MOTOR — порт-дескрипторный API (`c_Motor.txt`)

Порты задаются **строкой**: `"A"`, `"B"`, `"AB"`, `"1A"` (layer 1 = десятичная цифра 1..4 в строке). Разбор — `MOTORDECODEPORTSDESCRIPTOR` (`c_Motor.txt:34-73`), одиночный порт — `MOTORDECODEPORTDESCRIPTOR` (`c_Motor.txt:75-112`).

Алгоритм декодирования (`c_Motor.txt:46-69`): `'A'..'D'`/`'a'..'d'` → бит `(c-65)`/`(c-97)` в `nos`; `'1'..'4'` → `layer = c - 49`. Если ни одного порта — `nos == 0` и метод становится no-op (все методы начинаются с `JR_EQ8 nos 0 noport`).

| Метод | Сигнатура | Ограничения аргументов | Опкоды | Реализация |
|---|---|---|---|---|
| `Motor.Stop` | `SSV` | `brake` сравнивается с `'TRUE'` после upcase | `OUTPUT_STOP layer nos brk` | `c_Motor.txt:114-131` |
| `Motor.Start` | `SFV` | speed ∈ [-100,100] clamp | `OUTPUT_TIME_SPEED layer nos spd 0 2147483647 0 0` | `c_Motor.txt:134-157` |
| `Motor.StartPower` | `SFV` | power ∈ [-100,100] clamp | `OUTPUT_TIME_POWER layer nos pwr 0 2147483647 0 0` | `c_Motor.txt:159-182` |
| `Motor.StartSteer` | `SFFV` | speed, turn clamp [-100,100]; `turn *= 2.0` | → `OUTPUT_STEP_SYNC layer nos spd trn 0 0` | `c_Motor.txt:240-261` |
| `Motor.StartSync` | `SFFV` | оба speed clamp; turn вычисляется из отношения | → `OUTPUT_STEP_SYNC` | `c_Motor.txt:263-306` |
| `Motor.GetSpeed` | `SF` | — | `OUTPUT_READ layer no speed tacho` | `c_Motor.txt:310-338` |
| `Motor.IsBusy` | `SS` | — | `OUTPUT_TEST layer nos busy` → `'True'`/`'False'` | `c_Motor.txt:340-358` |
| `Motor.Schedule` | `SFFFFSV` | steps берутся `MATH ABS` | `OUTPUT_STEP_SPEED layer nos spd stp1 stp2 stp3 brk` | `c_Motor.txt:361-393` |
| `Motor.SchedulePower` | `SFFFFSV` | steps `MATH ABS` | `OUTPUT_STEP_POWER ...` | `c_Motor.txt:395-427` |
| `Motor.ScheduleSteer` | `SFFFSV` | speed/turn clamp, `turn *= 2.0` | → `OUTPUT_STEP_SYNC layer nos spd trn cnt brk` | `c_Motor.txt:496-519` |
| `Motor.ScheduleSync` | `SFFFSV` | clamp, turn из отношения | → `OUTPUT_STEP_SYNC` | `c_Motor.txt:521-566` |
| `Motor.ResetCount` | `SV` | — | `OUTPUT_CLR_COUNT layer nos` | `c_Motor.txt:568-579` |
| `Motor.GetCount` | `SF` | — | `OUTPUT_GET_COUNT layer no tacho` | `c_Motor.txt:599-626` |
| `Motor.Invert` | `SV` | — | `OUTPUT_POLARITY layer nos -1` + правка `MOTORISINVERTED` | `c_Motor.txt:581-597` |
| `Motor.Move` | `SFFSV` | `CALL MOTOR.SCHEDULE :0 :1 0.0 :2 0.0 :3`, затем ожидание | `OUTPUT_TEST` + `SLEEP` | `c_Motor.txt:649-664` |
| `Motor.MovePower` | `SFFSV` | `CALL MOTOR.SCHEDULEPOWER ...` + ожидание | — | `c_Motor.txt:666-681` |
| `Motor.MoveSteer` | `SFFFSV` | `CALL MOTOR.SCHEDULESTEER ...` + ожидание | — | `c_Motor.txt:683-698` |
| `Motor.MoveSync` | `SFFFSV` | `CALL MOTOR.SCHEDULESYNC ...` + ожидание | — | `c_Motor.txt:700-715` |
| `Motor.Wait` | `SV` | ожидание сброса busy (`SLEEP` в цикле) | `OUTPUT_TEST` | `c_Motor.txt:718-730` |
| `Motor.GetCountFast` | `FF` | порт как число 0..3 | `OUTPUT_GET_COUNT 0 no tacho` | `c_Motor.txt:628-639` |
| `Motor.GetCountFastA` | `F` | — | `OUTPUT_GET_COUNT 0 0 outTachoA` | `c_Motor.txt:641-646` |

Отдельные `MOTORDECODEPORTSDESCRIPTOR`, `MOTORDECODEPORTDESCRIPTOR`, `MOTORSTARTSTEERIMPL`, `MOTORSCHEDULESTEERIMPL` — **не** адресуемы из Basic (нет соответствующей записи в `DefaultObjectList`), только внутренние subcall'ы.

Состояние инверсии хранится в `ARRAY8 MOTORISINVERTED 4` (слой → биты), инициализируется в `init` (`c_Motor.txt:8-32`). `Motor.GetCount`/`GetSpeed` **меняют знак** результата для инвертированных моторов, а `Motor.GetCountFast` — нет.

### 2.10 MOTORA / MOTORB / MOTORC / MOTORD (`c_Motor{A,B,C,D}.txt`)

Все 14 методов каждого класса — `inline`, порт зашит константой. Различие между файлами — **только одна цифра порта** (0/1/2/3). Порт-индекс: A=0, B=1, C=2, D=3 (`OUTPUT_* layer nos ...` с `layer=0`).

| Метод | Сигнатура | Опкоды (для порта X) | Ссылка |
|---|---|---|---|
| `.GetTacho` | `F` | `OUTPUT_GET_COUNT 0 X getTachoX` + `MOVE32_F` | `c_MotorA.txt:9-13` |
| `.GetSpeed` | `F` | `OUTPUT_READ 0 X getSpeedX tmpTachoX` + `MOVE8_F` | `c_MotorA.txt:15-19` |
| `.ResetCount` | `V` | `OUTPUT_CLR_COUNT 0 X+1` | `c_MotorA.txt:21-24` |
| `.SetDirectPolarity` | `V` | `OUTPUT_POLARITY 0 X+1 1` | `c_MotorA.txt:26-29` |
| `.SetReversPolarity` | `V` | `OUTPUT_POLARITY 0 X+1 -1` | `c_MotorA.txt:31-34` |
| `.Off` | `V` | `OUTPUT_POWER 0 X+1 0` + `OUTPUT_STOP 0 X+1 0` | `c_MotorA.txt:36-40` |
| `.OffAndBrake` | `V` | `... OUTPUT_STOP 0 X+1 1` | `c_MotorA.txt:42-46` |
| `.IsLarge` | `V` | `OUTPUT_SET_TYPE 0 X 7` | `c_MotorA.txt:48-51` |
| `.IsMedium` | `V` | `OUTPUT_SET_TYPE 0 X 8` | `c_MotorA.txt:53-56` |
| `.SetSpeed` | `FV` | `MOVEF_8 :0 setSpeedX` + `OUTPUT_SPEED 0 X+1 setSpeedX` | `c_MotorA.txt:58-62` |
| `.SetPower` | `FV` | аналогично `OUTPUT_POWER` | `c_MotorA.txt:64-68` |
| `.StartSpeed` | `FV` | `OUTPUT_SPEED` + `OUTPUT_START` | `c_MotorA.txt:70-75` |
| `.StartPower` | `FV` | `OUTPUT_POWER` + `OUTPUT_START` | `c_MotorA.txt:77-82` |
| `.Start` | `V` | `OUTPUT_START 0 X+1` | `c_MotorA.txt:84-87` |

**Важно:** `nos` в этих модулях = `X+1` (битовая маска порта), а `layer` = 0. То есть `MOTORA.OFF` → `OUTPUT_POWER 0 1 0`. `MOTORA.ISLARGE` использует `nos = 0` (не маску!).

`IsLarge`/`IsMedium` **не возвращают значение**, несмотря на имя — они лишь посылают `OUTPUT_SET_TYPE` (тип 7 = large, 8 = medium).

### 2.11 MOTORAB / AC / AD / BC / BD / CD (`c_Motor{AB,AC,AD,BC,BD,CD}.txt`)

7 методов, все `inline`, **без** `setSpeedA`-переменных (используют глобальные `setSpeedA`/`setPowerA`):

| Метод | Сигнатура | Опкоды (для пары, `nos` = маска) | Ссылка |
|---|---|---|---|
| `.Off` | `V` | `OUTPUT_POWER 0 nos 0` + `OUTPUT_STOP 0 nos 0` | `c_MotorAB.txt:3-8` |
| `.OffAndBrake` | `V` | `... OUTPUT_STOP 0 nos 1` | `c_MotorAB.txt:9-14` |
| `.SetSpeed` | `FV` | `MOVEF_8 :0 setSpeedA` + `OUTPUT_SPEED 0 nos setSpeedA` | `c_MotorAB.txt:15-20` |
| `.SetPower` | `FV` | `OUTPUT_POWER 0 nos setPowerA` | `c_MotorAB.txt:21-26` |
| `.StartSpeed` | `FV` | `OUTPUT_SPEED` + `OUTPUT_START` | `c_MotorAB.txt:27-33` |
| `.StartPower` | `FV` | `OUTPUT_POWER` + `OUTPUT_START` | `c_MotorAB.txt:34-40` |
| `.Start` | `V` | `OUTPUT_START 0 nos` | `c_MotorAB.txt:41-45` |

Маски `nos`: AB=3, AC=5, AD=9, BC=6, BD=10, CD=12 (см. `c_BitMask.txt`, таблица справочная).

**Баг/квирк:** `MororAB.SetSpeed` записывает в **`setSpeedA`** — ту же переменную, что `MOTORA`. Поэтому `MotorA.SetSpeed(50)` и `MotorAB.SetSpeed(70)` делят одну ячейку; порядок вызовов влияет на результат. Аналогично `setPowerA`.

### 2.12 PROGRAM (`c_Program.txt`)

| Метод | Сигнатура | Семантика | Реализация |
|---|---|---|---|
| `Program.Delay` | `FV` | `TIMER_WAIT ms timer` + `TIMER_READY timer` (inline) | `c_Program.txt:23-30` |
| `Program.End` | `V` | `PROGRAM_STOP -1` | `c_Program.txt:32-35` |
| `Program.ArgumentCount` | `F` | **Заглушка: всегда `0`** (`MOVE8_F 0 result`) | `c_Program.txt:3-7` |
| `Program.Directory` | `S` | `FILENAME(GET_FOLDERNAME,127,result)` — имя папки программы | `c_Program.txt:9-13` |
| `Program.GetArgument` | `FS` | **Заглушка: всегда `''`** | `c_Program.txt:15-20` |

`Program.ArgumentCount` и `Program.GetArgument` в этой ветке кода не реализованы — аргументы командной строки не передаются. Считать заглушками.

### 2.13 ROW (`c_Row.txt`)

| Метод | Сигнатура | Семантика | Реализация |
|---|---|---|---|
| `Row.Init` | `FFF` | `ARRAY CREATEF size` + `ARRAY FILL value`; возвращает handle | `c_Row.txt:6-12` |
| `Row.Delete` | `FV` | `ARRAY DELETE handle` | `c_Row.txt:14-18` |
| `Row.Read` | `FFF` | `ARRAY_READ handle index value` | `c_Row.txt:20-25` |
| `Row.Write` | `FFFV` | `ARRAY_WRITE handle index value` | `c_Row.txt:27-32` |
| `Row.Size` | `FF` | `ARRAY SIZE` (после `Delete` вернёт 0, не падает) | `c_Row.txt:34-39` |
| `Row.Resize` | `FFV` | `ARRAY RESIZE` (новые элементы зануляются) | `c_Row.txt:41-46` |

Handle — это `number` (не массив!). В Basic ROW-объект хранится в обычной переменной и передаётся по значению; `arr[i]` для handle **не работает** (комментарий в `Row/Row.bp:2-3`). `Row.Init` возвращает `number`, а не `NumberArray` (`DefaultObjectList.cs:279` — `VariableType.NUMBER`).

### 2.14 SENSOR — порт-дескрипторный API (`c_Sensor.txt`)

Порт: **число 1..4** (не строка). Layer = `(port-1)/4`, `no = (port-1) mod 4` (`c_Sensor.txt:16-19` и далее во всех методах).

| Метод | Сигнатура | Опкоды | Реализация |
|---|---|---|---|
| `Sensor.GetName` | `FS` | `INPUT_DEVICE GET_NAME layer no 32 result` + `STRINGS STRIP` | `c_Sensor.txt:8-23` |
| `Sensor.GetType` | `FF` | `INPUT_DEVICE GET_TYPEMODE layer no type mode` → `MOVE8_F type` | `c_Sensor.txt:25-42` |
| `Sensor.GetMode` | `FF` | То же, возвращает `mode` | `c_Sensor.txt:44-61` |
| `Sensor.GetDataFormat` | `FS` | `INPUT_DEVICE GET_FORMAT` → `datasets,format,modes` | `c_Sensor.txt:63-96` |
| `Sensor.SetMode` | `FFV` | `INPUT_DEVICE READY_RAW layer no 0 mode8 0` (inline) | `c_Sensor.txt:98-112` |
| `Sensor.IsBusy` | `FS` | `INPUT_TEST layer no busy` → `'True'`/`'False'` | `c_Sensor.txt:114-135` |
| `Sensor.Wait` | `FV` | `INPUT_READY layer no` (inline) | `c_Sensor.txt:137-146` |
| `Sensor.ReadPercent` | `FF` | `INPUT_READ layer no 0 -1 percentage`; отрицательное → `0` | `c_Sensor.txt:149-170` |
| `Sensor.ReadRaw` | `FFA` | `INPUT_READEXT layer no 0 -1 18 8 …` (8×DATA32) | `c_Sensor.txt:172-226` |
| `Sensor.ReadRawValue` | `FFF` | `INPUT_READEXT … 18 8`, `READ32 rawvalue0 index8` | `c_Sensor.txt:228-267` |
| `Sensor.CommunicateI2C` | `FFFFAA` | `INPUT_DEVICE SETUP layer no 1 0 wrt8 outdata rd8 indata` | `c_Sensor.txt:269-360` |
| `Sensor.ReadI2CRegister` | `FFF` | `INPUT_DEVICE SETUP layer no 1 0 2 outdata 1 indata` | `c_Sensor.txt:362-395` |
| `Sensor.ReadI2CRegisters` | `FFFFA` | SETUP + побайтовое чтение | `c_Sensor.txt:397-452` |
| `Sensor.WriteI2CRegister` | `FFFFV` | SETUP с 3 байтами outdata | `c_Sensor.txt:454-480` |
| `Sensor.WriteI2CRegisters` | `FFFFAV` | SETUP с N байтами | `c_Sensor.txt:482-548` |
| `Sensor.SendUartData` | `FFAV` | `INPUT_WRITE layer no wrt8 outdata` | `c_Sensor.txt:551-607` |

Константа `-1000000000` в `INPUT_READEXT`-путях (`c_Sensor.txt:214, 260`) — маркер «нет данных»: значение `< -1e9` превращается в `0.0`.

### 2.15 SENSOR1 / SENSOR2 / SENSOR3 / SENSOR4 (`c_Sensor{1,2,3,4}.txt`)

| Метод | Сигнатура | Опкоды (порт N-1) | Реализация |
|---|---|---|---|
| `SensorN.Raw1` | `F` | `INPUT_READEXT 0 (N-1) 0 -1 18 1 sNout1` + `MOVE32_F sNout1 :0` (inline) | `c_Sensor1.txt:14-18` |
| `SensorN.Raw3` | `FFFV` | `INPUT_READEXT 0 (N-1) 0 -1 18 3 sNout1 sNout2 sNout3` + 3×`MOVE32_F` | `c_Sensor1.txt:20-26` |

Глобальные `DATA32 sNout1..3` (для N=1..4) объявлены в каждом файле (`c_Sensor1.txt:3-5`, аналогично `c_Sensor2..4.txt`) и зануляются в `init` (`c_Sensor1.txt:7-12`). Схема с `RAW1`/`RAW3` — «быстрый» путь без повторного чтения типа/режима; результат **не** конвертируется из «сырого» формата автоматически.

`Layer` зашит 0 — то есть `sensor1..4` работают **только** с первой цепочкой (всего 4 порта на brick).

### 2.16 SPEAKER (`c_Speaker.txt`)

| Метод | Сигнатура | Семантика | Реализация |
|---|---|---|---|
| `Speaker.Stop` | `V` | `SOUND BREAK` (inline) | `c_Speaker.txt:3-6` |
| `Speaker.Tone` | `FFFV` | volume→I8, tone→I16, duration→I16; `SOUND TONE vol tne dur` | `c_Speaker.txt:8-22` |
| `Speaker.Note` | `FSFV` | `NOTE_TO_FREQ note tne` затем `SOUND TONE` | `c_Speaker.txt:24-38` |
| `Speaker.Play` | `FSV` | префикс `'../../../..'`, если путь не абсолютный → `'../prjs/'`; `SOUND PLAY vol fullname` | `c_Speaker.txt:40-56` |
| `Speaker.IsBusy` | `S` | `SOUND_TEST busy` → `'True'`/`'False'` | `c_Speaker.txt:58-70` |
| `Speaker.Wait` | `V` | `SOUND_READY` (inline) | `c_Speaker.txt:72-75` |

Note-имена — те, что понимает `NOTE_TO_FREQ` (опкод `0x63`): `C4`, `D#5` и т.п.

### 2.17 TEXT (`c_Text.txt`)

| Метод | Сигнатура | Семантика | Реализация |
|---|---|---|---|
| `Text.Append` | `SSS` | `STRINGS GET_SIZE` обоих, при сумме > 251 возвращает только `a` | `c_Text.txt:3-23` |
| `Text.ConvertToLowerCase` | `SS` | Побайтовый проход через `MEMORY_READ`/`MEMORY_WRITE`, ASCII + Latin-1 | `c_Text.txt:25-57` |
| `Text.ConvertToUpperCase` | `SS` | Аналогично | `c_Text.txt:59-91` |
| `Text.EndsWith` | `SSS` | Реализовано через `MEMORY_READ` по абсолютному адресу 512 (**предполагает slot 1**) | `c_Text.txt:93-136` |
| `Text.GetIndexOf` | `SSF` | Индекс с 1; не найдено → `0` | `c_Text.txt:138-182` |
| `Text.IsSubText` | `SSS` | `'True'`/`'False'` | `c_Text.txt:184-227` |
| `Text.StartsWith` | `SSS` | `MEMORY_WRITE` по адресу 512 | `c_Text.txt:230-266` |
| `Text.GetSubText` | `SFFS` | start с 1; `sublength` в (0,1] трактуется как 1 | `c_Text.txt:299-350` |
| `Text.GetSubTextToEnd` | `SFS` | start с 1 | `c_Text.txt:352-381` |
| `Text.GetLength` | `SF` | `STRINGS GET_SIZE` | `c_Text.txt:383-391` |
| `Text.GetCharacter` | `FS` | Код 1..255 → 1-байтовая строка; иначе `chr(1)` | `c_Text.txt:268-285` |
| `Text.GetCharacterCode` | `SF` | Первый байт строки, маска 255 | `c_Text.txt:287-297` |

**Опасное место:** `Text.EndsWith`, `Text.StartsWith`, `Text.IsSubText`, `Text.GetIndexOf`, `Text.GetSubText`, `Text.GetSubTextToEnd` используют `MEMORY_READ/WRITE` с **жёстко зашитыми адресами** 508/512 и комментарием «assumes that the current program runs in slot 1». При работе из другого slot'а эти функции читают чужую память.

### 2.18 THREAD (`c_Thread.txt`)

| Метод/событие | Сигнатура | Семантика | Реализация |
|---|---|---|---|
| `Thread.Yield` | `V` | `SLEEP` (inline) | `c_Thread.txt:54-57` |
| `Thread.CreateMutex` | `F` | `ARRAY SIZE LOCKS idx`, `ARRAY_APPEND LOCKS zero`, возвращает индекс | `c_Thread.txt:59-71` |
| `Thread.Lock` | `FV` | Цикл `CALL GETANDSETLOCK :0 1 previous:#`, пока `previous != 0` | `c_Thread.txt:73-82` |
| `Thread.Unlock` | `FV` | `CALL GETANDSETLOCK :0 0 dummy:#` | `c_Thread.txt:84-88` |
| `Thread.Run` | **EVENT**, присваивание `Thread.Run = SUBNAME` | См. ниже | `Compiler.cs:960-979` |

`Thread.Run` — **не** метод, а свойство-присваивание: `Thread.Run = BLINKER`. Обрабатывается специально в `compile_procedure_call_or_property_set` (`Compiler.cs:960-979`):

```
    DATA32 tmp<L>
    CALL GETANDINC32 RUNCOUNTER_<ID> 1  RUNCOUNTER_<ID> tmp<L>
    JR_NEQ32 0 tmp<L> alreadylaunched<L>
    OBJECT_START T<ID>
  alreadylaunched<L>:
```

`<ID>` — имя sub'а в верхнем регистре. Один sub не запускается дважды: счётчик `RUNCOUNTER_<ID>` инкрементируется атомарно через subcall `GETANDINC32` (VM гарантирует, что subcall не выполняется параллельно в двух потоках — `c_Thread.txt:11-25`).

Генерация потоков — `Compiler.cs:352-378`: на каждый `threadname` пишется `vmthread T<ID> { ... CALL PROGRAM_<ID> <i> ... }` с `JR_GT32 tmp 1 launch` для перезапуска. `Compiler.cs:390-441` создаёт `subcall PROGRAM_MAIN` + `subcall PROGRAM_<ID>` с общей реализацией (alias через `subcall NAME`), где `IN_32 SUBPROGRAM` выбирает точку входа.

`EV3.NATIVECODE` требует особой обработки: `Compiler.cs:340-344` вставляет `CreateNativeCodeDownload()` в `MAIN`, если `EV3.NATIVECODE` попал в `references`.

### 2.19 TIME (`c_Time.txt`)

9 независимых таймеров, глобальные `DATA32 timeMC1..9` и `timeMC1..9tmp`.

| Метод | Сигнатура | Опкоды | Реализация |
|---|---|---|---|
| `Time.GetN` | `F` | `TIMER_READ timeMCNtmp`, `SUB32 tmp timeMCN tmp`, `MOVE32_F tmp :0` | `c_Time.txt:34-95` |
| `Time.ResetN` | `V` | `TIMER_READ timeMCN` | `c_Time.txt:97-138` |

Единица — миллисекунды. `Time.GetN` возвращает `number` (float), точность ограничена 32-битным счётчиком.

### 2.20 VECTOR (`c_Vector.txt`)

Все методы работают с **handle массива** (`NumberArray`), но `vector.init`/`vector.data`/`vector.add`/`vector.sort` возвращают `NumberArray` (см. `DefaultObjectList.cs:373-377`), тогда как в сигнатуре модуля стоит `A` (NumberArray = I16-handle).

| Метод | Сигнатура | Семантика | Реализация |
|---|---|---|---|
| `Vector.Init` | `FFA` | `ARRAY RESIZE a size32` + `ARRAY FILL a value`; size ≤ 0 → resize 0 | `c_Vector.txt:3-19` |
| `Vector.Data` | `FSA` | Парсит разделённые пробелами числа из строки (8-битный диапазон `d0`/`d1`), `STRINGS STRING_TO_VALUE` | `c_Vector.txt:21-77` |
| `Vector.Add` | `FAAA` | Поэлементная сумма, отсутствующие элементы = 0 | `c_Vector.txt:79-118` |
| `Vector.Sort` | `FAA` | QuickSort (порт Darel Rex Finley); `output_is_same_array` — допускает `a == arr` | `c_Vector.txt:121-250` |
| `Vector.Multiply` | `FFFAAA` | Умножение матриц N×K на K×M; `C == A` или `C == B` → временный буфер | `c_Vector.txt:252-…` |

`Vector.Sort` использует `ARRAY32 beg 128` / `ARRAY32 end 128` — максимальная глубина стека 128, при большем числе элементов переполнение (порча локальных данных). Документация модуля этого не проверяет.

### 2.21 Прочие имена

| Имя | Тип | Примечание |
|---|---|---|
| `F.START` | свойство-присваивание | Распознаётся и **игнорируется** (`Compiler.cs:981-984`) — обработано в первом проходе |
| `F.FUNCTION` | вызов | Игнорируется (`Compiler.cs:996-1000`) — обработано в первом проходе |
| `F.SET` | метод | `F.SET("NAME", value)` — присваивание локальному параметру функции (`Compiler.cs:1004-1019`) |
| `F.GET` | метод | `F.GET("NAME")` — чтение параметра (`Compiler.cs:1555-1570`) |
| `F.RETURN` / `F.RETURNNUMBER` / `F.RETURNTEXT` | метод | `JR RETSUB_<sub>`; проверка, что это первичный sub функции (`Compiler.cs:1021-1052`) |
| `F.CALL` / `F.CALLNUMBER` / `F.CALLTEXT` | метод | Вызов user-функции (`Compiler.cs:1053-1083`, выражение — `Compiler.cs:1571-1594`) |

Эти имена **не** в `DefaultObjectList`; они валидны только потому, что `parse_function_call_or_property` разбирает их до обращения к `library` (`Compiler.cs:996`, `Compiler.cs:1556`).

---

## 3. Отображение Basic → ассемблер (не встроенные методы)

### 3.1 Операторы выражений

| Basic | Генерация | Ссылка |
|---|---|---|
| числовой литерал | inline-константа (`*.0` если целое) | `Expression.cs:111-122` |
| текст `"..."` | `'...'` (экранирование `EscapeString`) | `Compiler.cs:1692-1699`, `Compiler.cs:1701-1724` |
| `a` (переменная) | `V<A>` | `Compiler.cs:1500`, `Compiler.cs:1537` |
| `a + b` (числа, оба константы) | свёртка на этапе компиляции | `Compiler.cs:1334-1341` |
| `a + b` (числа) | `ADDF a b out` | `Compiler.cs:1344` |
| `a - b` | `SUBF` | `Compiler.cs:1364-1374` |
| `a * b` | `MULF` | `Compiler.cs:1389` |
| `a / b` | `DATAF tmpf:#` / `DATA8 flag:#` / `DIVF` / `CP_EQF 0.0 :1 flag:#` / `SELECTF` (проверка деления на 0 → 0) | `Compiler.cs:1406-1415` |
| `a / b` при `PRAGMA NODIVISIONCHECK` | `DIVF a b out` | `Compiler.cs:1402` |
| `-a` | `MATH NEGATE a out` | `Compiler.cs:1443` |
| `a + b` (строка + что-то) | `CALL TEXT.APPEND` (число сначала `STRINGS VALUE_FORMATTED :0 '%g' 99`) | `Compiler.cs:1300-1311` |
| `a = b` (числа) | `CALL EQ_FLOAT` или `JR_EQF`/`JR_NEQF` | `Compiler.cs:1211` |
| `a = b` (строки) | `CALL EQ_STRING` | `Compiler.cs:1213` |
| `a <> b` | `CALL NEQ_FLOAT` / `CALL NE_STRING` | `Compiler.cs:1233-1237` |
| `a < b` | `JR_LTF` / `JR_GTEQF` | `Compiler.cs:1249` |
| `a > b` | `JR_GTF` / `JR_LTEQF` | `Compiler.cs:1257` |
| `a <= b` | `JR_LTEQF` / `JR_GTF` | `Compiler.cs:1265` |
| `a >= b` | `JR_GTEQF` / `JR_LTF` | `Compiler.cs:1273` |

Логические `AND`/`OR` **не** генерируют вызов, если результат используется как условие: `AndExpression.GenerateJumpIfCondition` (`Expression.cs:367-381`) и `OrExpression` (`Expression.cs:390-404`) раскрываются в короткое замыкание через метки `and<L>`/`or<L>`. Если результат нужен как значение — `CALL AND` / `CALL OR` (`Expression.cs:364`, `Expression.cs:386`).

### 3.2 Условие → переход

`Expression.GenerateJumpIfCondition` (`Expression.cs:76-88`) для произвольной текстовой строки:

```
    AND8888_32 <v> -538976289 <v>      // upcase 4 буквы: маска 0xdfdfdfdf
    STRINGS COMPARE <v> 'TRUE' <v>
    JR_EQ8 <v> 0 <label>               // или JR_NEQ8 при jumpIfTrue
```

Оптимизация: `AtomicExpression` со строковым литералом `'TRUE'` проверяется на этапе компиляции (`Expression.cs:149-161`); `'X'` не равный `'TRUE'` — переход не генерируется вообще.

### 3.3 Присваивание, массивы, sub-вызовы

| Конструкция | Генерация | Ссылка |
|---|---|---|
| `v = expr` | expr.Generate в `V<v>`; тип `V<v>` фиксируется при первом присваивании | `Compiler.cs:859-891` |
| `a[i] = num` (boundscheck) | `CALL ARRAYSTORE_FLOAT :0 :1 V<a>` | `Compiler.cs:931-934` |
| `a[i] = num` (NOBOUNDSCHECK, const i ≥ 0) | `ARRAY_WRITE V<a> <i> :0` | `Compiler.cs:915-924` |
| `a[i] = num` (NOBOUNDSCHECK, runtime i) | `MOVEF_32 :0 INDEX` + `ARRAY_WRITE V<a> INDEX :1` | `Compiler.cs:926-930` |
| `a[i] = str` | `CALL ARRAYSTORE_STRING :0 :1 V<a>` | `Compiler.cs:909-911` |
| `a[i]` (num, boundscheck) | `CALL ARRAYGET_FLOAT :0 :1 V<a>` | `Compiler.cs:1528` |
| `a[i]` (num, NOBOUNDSCHECK) | `UnsafeArrayGetExpression` → `ARRAY_READ V<a> i out` | `Expression.cs:419-452` |
| `a[i]` (str) | `CALL ARRAYGET_STRING :0 :1 V<a>` | `Compiler.cs:1524` |
| `SUBNAME()` | `WRITE32 ENDSUB_<N>:CALLSUB<L> STACKPOINTER RETURNSTACK` / `ADD8 STACKPOINTER 1 STACKPOINTER` / `JR SUB_<N>` / `CALLSUB<L>:` | `Compiler.cs:840-848` |
| `GOTO L` | `JR L<label>` | `Compiler.cs:794-809` |
| `L:` | `L<label>:` | `Compiler.cs:850-853` |

Каждый sub заканчивается (`Compiler.cs:561-570`):

```
RETSUB_<NAME>:
    SUB8 STACKPOINTER 1 STACKPOINTER
    READ32 RETURNSTACK STACKPOINTER INDEX
    JR_DYNAMIC INDEX
ENDSUB_<NAME>:
```

`ENDSUB_<NAME>` — не инструкция, а адрес, вычисляемый ассемблером для `WRITE32 ENDSUB_X:CALLSUBL` (разница меток, `LMSObject.cs:192-197`, `LMSObject.cs:232-243`).

`RETURNSTACK` — `ARRAY32 RETURNSTACK 128` + `ARRAY32 RETURNSTACK2 128` (`Compiler.cs:399-401`), адресация 8-битная со скольжением.

### 3.4 `IF` / `WHILE` / `FOR`

| Структура | Генерируемые метки | Ссылка |
|---|---|---|
| `IF cond THEN ... ELSEIF ... ELSE ... ENDIF` | `else<L>_1`, `else<L>_2`, …, `endif<L>` | `Compiler.cs:631-690` |
| `WHILE cond ... ENDWHILE` | `while<L>`, `whilebody<L>`, `endwhile<L>`; условие генерируется **дважды** (до и после тела) | `Compiler.cs:692-714` |
| `FOR v = a TO b STEP s` | `for<L>`, `forbody<L>`, `endfor<L>` | `Compiler.cs:716-792` |

`FOR` со STEP: положительный литерал → `LE`/`JR_LTEQF`; отрицательный → `GE`/`JR_GTEQF`; неопределённый знак → `CALL LE_STEP` (`Compiler.cs:745-758`). Приращение всегда `ADDF` (`Compiler.cs:760`).

`WHILE` генерирует условие дважды — важно, потому что каждое вычисление условия резервирует/освобождает временные переменные; счётчик `maxreservedtemporaries` учитывает оба.

---

## 4. Таблица опкодов EV3 VM

Источник — `Interpreter/Assembler/Resources/bytecodelist.txt`. Формат записи: `XXYY NAME_SUB NAME P1 P2 ...`, где `XXYY` — 1 или 2 байта опкода; суффиксы параметров: `8/16/32/F` — тип, `L` — метка перехода, `T` — thread id, `S` — subcall id, `P` — счётчик числа параметров, `?` — неопределённый. `*` после типа = запись, `+` = чтение массива/строки, без суффикса = чтение.

### 4.1 Управление программами и объектами

| Опкод | Мнемоника | Параметры | Назначение |
|---|---|---|---|
| `00` | `ERROR` | — | Ошибка VM |
| `01` | `NOP` | — | Ничего |
| `02` | `PROGRAM_STOP` | 16 | Остановить программу (ID, `-1` = текущая) |
| `03` | `PROGRAM_START` | 16 32 32 8 | Запустить программу |
| `04` | `OBJECT_STOP` | T | Остановить поток |
| `05` | `OBJECT_START` | T | Запустить поток |
| `06` | `OBJECT_TRIG` | T | Триггер потока |
| `07` | `OBJECT_WAIT` | T | Ожидание потока |
| `08` | `RETURN` | — | Возврат из subcall |
| `09` | `CALL` | subcall-id, numpar, … | **Вызов subcall** (см. ниже) |
| `0A` | `OBJECT_END` | — | Конец объекта (терминатор) |
| `0B` | `SLEEP` | — | Отдать квант времени |

`CALL` (`0x09`) не описан в `bytecodelist.txt` — он обрабатывается жёстко в `Assembler.cs:345-375`: `0x09`, `AddConstant(sc.id)`, `AddConstant(numpar)`, затем аргументы. Терминаторы `RETURN`/`OBJECT_END` дописываются в subcall автоматически (`LMSObject.cs:431-433`), в thread — только `OBJECT_END` (`LMSObject.cs:300`).

### 4.2 PROGRAM_INFO, метки, отладка

| Опкод | Мнемоника | Параметры | Назначение |
|---|---|---|---|
| `0C00` | `PROGRAM_INFO OBJ_STOP` | 16 16 | Остановить объект программы |
| `0C04` | `PROGRAM_INFO OBJ_START` | 16 16 | Запустить объект |
| `0C16` | `PROGRAM_INFO GET_STATUS` | 16 8* | Статус |
| `0C17` | `PROGRAM_INFO GET_SPEED` | 16 32* | Скорость |
| `0C18` | `PROGRAM_INFO GET_PRGRESULT` | 16 8* | Результат |
| `0D` | `LABEL` | 8 | Метка (no-op) |
| `0E` | `PROBE` | 16 16 32 32 | Отладочный зонд |
| `0F` | `DO` | 16 32 32 | — |

### 4.3 Арифметика и логика (8/16/32/F)

| Опкод | Мнемоника | Параметры |
|---|---|---|
| `10`/`11`/`12`/`13` | `ADD8`/`ADD16`/`ADD32`/`ADDF` | `t t t*` |
| `14`/`15`/`16`/`17` | `SUB8`/`SUB16`/`SUB32`/`SUBF` | `t t t*` |
| `18`/`19`/`1A`/`1B` | `MUL8`/`MUL16`/`MUL32`/`MULF` | `t t t*` |
| `1C`/`1D`/`1E`/`1F` | `DIV8`/`DIV16`/`DIV32`/`DIVF` | `t t t*` |
| `20`/`21`/`22` | `OR8`/`OR16`/`OR32` | `t t t*` |
| `24`/`25`/`26` | `AND8`/`AND16`/`AND32` | `t t t*` |
| `26` | `AND8888_32` | `8+ 32 8*` — **спец. форма**: `AND 32-бит с маской над 4 байтами строки` (используется для upcase, маска `-538976289` = `0xDFDFDFDF`) |
| `28`/`29`/`2A` | `XOR8`/`XOR16`/`XOR32` | `t t t*` |
| `2C`/`2D`/`2E` | `RL8`/`RL16`/`RL32` | `t t t*` — сдвиг влево |
| `2F` | `INIT_BYTES` | `8* P 8` — инициализация массива байт |

`AND8888_32` определён дважды под опкодом `0x26` (`bytecodelist.txt:45-46`): парсер `VMCommand` берёт *последнее* вхождение в словаре, но `name` формируется из токенов, поэтому в словаре одновременно `AND32` и `AND8888_32` — коллизия имён разрешается по составному ключу `"AND8888_32"` (`Assembler.cs:391-406`). Равенство опкода `0x26` — кваirk, требующий аккуратности при портировании.

### 4.4 Пересылки

| Опкод | Мнемоника | Параметры | Примечание |
|---|---|---|---|
| `30` | `MOVE8_8` | `8 8*` | |
| `30` | `EXTRACTLOWBYTE` | `32 8*` | Спец. форма: извлечь младший байт как знаковый (даёт `-128`) |
| `30` | `INJECTLOWBYTE` | `8* 32` | Обратная операция: байт → беззнаковый int |
| `31`/`32`/`33` | `MOVE8_16`/`MOVE8_32`/`MOVE8_F` | `8 X*` | |
| `34`/`35`/`36`/`37` | `MOVE16_8`/`MOVE16_16`/`MOVE16_32`/`MOVE16_F` | `16 X*` | |
| `38`/`39`/`3A`/`3B` | `MOVE32_8`/`MOVE32_16`/`MOVE32_32`/`MOVE32_F` | `32 X*` | |
| `3C`/`3D`/`3E`/`3F` | `MOVEF_8`/`MOVEF_16`/`MOVEF_32`/`MOVEF_F` | `F X*` | |

Три имени делят опкод `0x30` — тот же приём, что с `0x26`.

### 4.5 Переходы

| Опкод | Мнемоника | Параметры | Назначение |
|---|---|---|---|
| `40` | `JR` | L | Безусловный переход |
| `40` | `JR_DYNAMIC` | 32 | Косвенный переход по адресу (используется для возврата из sub) |
| `41` | `JR_FALSE` | 8 L | Переход если 0 |
| `42` | `JR_TRUE` | 8 L | Переход если ≠0 |
| `43` | `JR_NAN` | F L | Переход если NaN |
| `64`-`67` | `JR_LT8/16/32/F` | `t t L` | Условные переходы |
| `68`-`6B` | `JR_GT8/16/32/F` | `t t L` | |
| `6C`-`6F` | `JR_EQ8/16/32/F` | `t t L` | |
| `70`-`73` | `JR_NEQ8/16/32/F` | `t t L` | |
| `74`-`77` | `JR_LTEQ8/16/32/F` | `t t L` | |
| `78`-`7B` | `JR_GTEQ8/16/32/F` | `t t L` | |

**Асимметрия типов:** `JR_LT8` — оба операнда 8-бит, `JR_LT16`/`JR_LT32` — оба 16/32, `JR_LTF` — float.

### 4.6 Сравнения (без перехода) и выбор

| Опкод | Мнемоника | Параметры |
|---|---|---|
| `44`-`47` | `CP_LT8/16/32/F` | `t t 8*` |
| `48`-`4B` | `CP_GT8/16/32/F` | `t t 8*` |
| `4C`-`4F` | `CP_EQ8/16/32/F` | `t t 8*` |
| `50`-`53` | `CP_NEQ8/16/32/F` | `t t 8*` |
| `54`-`57` | `CP_LTEQ8/16/32/F` | `t t 8*` |
| `58`-`5B` | `CP_GTEQ8/16/32/F` | `t t 8*` |
| `5C` | `SELECT8` | `8 8 8 8*` |
| `5D` | `SELECT16` | `8 16 16 16*` |
| `5E` | `SELECT32` | `8 32 32 32*` |
| `5F` | `SELECTF` | `8 F F F*` |

**Квирк:** `CP_LT32` определён как `16 16 8*` (а не `32 32 8*`) — `bytecodelist.txt:79`. Это, вероятно, опечатка в исходном списке; порт должен её воспроизвести, иначе несовпадение формата с оригинальным ассемблером.

### 4.7 Системные, порты, звук

| Опкод | Мнемоника | Параметры | Назначение |
|---|---|---|---|
| `60` | `SYSTEM` | `8+ 8*` | Shell-команда |
| `61` | `PORT_CNV_OUTPUT` | `32 8* 8* 8*` | Преобразование порта |
| `62` | `PORT_CNV_INPUT` | `32 8* 8*` | |
| `63` | `NOTE_TO_FREQ` | `8 16*` | Нотное имя → частота |
| `7C01` | `INFO SET_ERROR` | 8 | Установить код ошибки |
| `7C02` | `INFO GET_ERROR` | `8*` | |
| `7C03` | `INFO ERRORTEXT` | `8 8 8*` | |
| `7C04`/`7C05` | `INFO GET_VOLUME`/`SET_VOLUME` | `8*`/`8` | |
| `7C06`/`7C07` | `INFO GET_MINUTES`/`SET_MINUTES` | `8*`/`8` | |

### 4.8 Строки (`7D`)

| Опкод | Мнемоника | Параметры | Назначение |
|---|---|---|---|
| `7D01` | `STRINGS GET_SIZE` | `8+ 16*` | Длина |
| `7D02` | `STRINGS ADD` | `8+ 8+ 8*` | Конкатенация |
| `7D03` | `STRINGS COMPARE` | `8+ 8+ 8*` | Сравнение (0 = равны) |
| `7D05` | `STRINGS DUPLICATE` | `8+ 8*` | Копирование |
| `7D06` | `STRINGS VALUE_TO_STRING` | `F 8 8 8*` | Число → строка (формат) |
| `7D07` | `STRINGS STRING_TO_VALUE` | `8+ F*` | Строка → число |
| `7D08` | `STRINGS STRIP` | `8+ 8*` | Убрать пробелы |
| `7D09` | `STRINGS NUMBER_TO_STRING` | `16 8 8*` | Целое → строка |
| `7D0A` | `STRINGS SUB` | `8+ 8+ 8*` | Подстрока |
| `7D0B` | `STRINGS VALUE_FORMATTED` | `F 8+ 8 8*` | `printf`-формат |
| `7D0C` | `STRINGS NUMBER_FORMATTED` | `32 8+ 8 8*` | Форматирование целого |

### 4.9 Память и UI

| Опкод | Мнемоника | Параметры | Назначение |
|---|---|---|---|
| `7E` | `MEMORY_WRITE` | `16 S 32 32 8+` | Запись в память другого slot'а |
| `7F` | `MEMORY_READ` | `16 S 32 32 8*` | Чтение |
| `80` | `UI_FLUSH` | — | Сброс UI |
| `8101`-`811F` | `UI_READ *` | см. `bytecodelist.txt:158-181` | `GET_VBATT`, `GET_IBATT`, `GET_LBATT`, `GET_ADDRESS`, `GET_SHUTDOWN`, `TEXTBOX_READ`, `GET_IP`, `GET_POWER`, … |
| `8201`-`821F` | `UI_WRITE *` | см. `bytecodelist.txt:183-203` | `WRITE_FLUSH`, `FLOATVALUE`, `PUT_STRING`, `VALUE8/16/32/F`, `TEXTBOX_APPEND`, `LED`, `POWER`, `TERMINAL`, … |
| `8301`-`830F` | `UI_BUTTON *` | см. `bytecodelist.txt:205-219` | `SHORTPRESS`, `LONGPRESS`, `WAIT_FOR_PRESS`, `FLUSH`, `PRESS`, `RELEASE`, `PRESSED`, `GET_CLICK`, … |
| `8400`-`8420` | `UI_DRAW *` | см. `bytecodelist.txt:221-253` | `UPDATE`, `CLEAN`, `PIXEL`, `LINE`, `CIRCLE`, `TEXT`, `ICON`, `PICTURE`, `FILLRECT`, `RECT`, `INVERSERECT`, `SELECT_FONT`, `TOPLINE`, `FILLCIRCLE`, `BMPFILE`, `TEXTBOX`, … |

### 4.10 Таймеры, математика, случайные

| Опкод | Мнемоника | Параметры | Назначение |
|---|---|---|---|
| `85` | `TIMER_WAIT` | `32 32*` | Пауза; выводит id таймера |
| `86` | `TIMER_READY` | 32 | Ожидание таймера |
| `87` | `TIMER_READ` | `32*` | Текущее время (мс) |
| `88`-`8B` | `BP0`-`BP3` | — | breakpoint |
| `8C` | `BP_SET` | `16 8 32` | |
| `8D01`-`8D15` | `MATH *` | `F F*` / `F F F*` / `F 8 F*` | `EXP`, `MOD`, `FLOOR`, `CEIL`, `ROUND`, `ABS`, `NEGATE`, `SQRT`, `LOG`, `LN`, `SIN`, `COS`, `TAN`, `ASIN`, `ACOS`, `ATAN`, `MOD8`, `MOD16`, `MOD32`, `POW`, `TRUNC` |
| `8E` | `RANDOM` | `16 16 16*` | Случайное в диапазоне |
| `8F` | `TIMER_READ_US` | `32*` | Микросекунды |
| `90` | `KEEP_ALIVE` | 8 | |

`MATH MOD` (float, `8D02`) определён как `F F F*` — 3 параметра. `MATH FLOOR`/`CEIL`/`ROUND`/`ABS`/`NEGATE`/`SQRT`/`LOG`/`LN`/`SIN`/`COS`/`TAN`/`ASIN`/`ACOS`/`ATAN`/`EXP` — 2 параметра `F F*`. `MATH TRUNC` — `F 8 F*` (знаковый/беззнаковый выбор).

### 4.11 Звук, ввод-вывод устройств

| Опкод | Мнемоника | Параметры | Назначение |
|---|---|---|---|
| `910E` | `COM_READ COMMAND` | `32 32* 32* 8*` | Чтение команд COM |
| `920E` | `COM_WRITE REPLY` | `32* 32*` | Ответ |
| `9400` | `SOUND BREAK` | — | Остановить звук |
| `9401` | `SOUND TONE` | `8 16 16` | Тон: volume, freq, duration |
| `9402` | `SOUND PLAY` | `8 8+` | Файл |
| `9403` | `SOUND REPEAT` | `8 8+` | |
| `95` | `SOUND_TEST` | `8*` | Занят? |
| `96` | `SOUND_READY` | — | Ожидание |
| `98` | `INPUT_DEVICE_LIST` | `8 8* 8*` | |
| `9902`-`991F` | `INPUT_DEVICE *` | см. `bytecodelist.txt:303-325` | `GET_FORMAT`, `GET_TYPEMODE`, `GET_NAME`, `SETUP`, `CLR_ALL`, `GET_RAW`, `SET_RAW`, `READY_PCT`, `READY_RAW`, `READY_SI`, `GET_MINMAX`, `GET_BUMPS`, … |
| `9A` | `INPUT_READ` | `8 8 8 8 8*` | Проценты |
| `9B` | `INPUT_TEST` | `8 8 8*` | Занят? |
| `9C` | `INPUT_READY` | `8 8` | Ожидание |
| `9D` | `INPUT_READSI` | `8 8 8 8 F*` | В SI-единицах |
| `9E` | `INPUT_READEXT` | `8 8 8 8 8 P ?*` | Сырые данные, P значений |
| `9F` | `INPUT_WRITE` | `8 8 8 8*` | UART-запись |

`INPUT_DEVICE READY_PCT/READY_RAW/READY_SI` и `INPUT_READEXT` используют `P` (число параметров) — ассемблер расширяет список аргументов (`Assembler.cs:483-497`).

### 4.12 Моторы (OUTPUT)

| Опкод | Мнемоника | Параметры | Назначение |
|---|---|---|---|
| `A1` | `OUTPUT_SET_TYPE` | `8 8 8` | Тип мотора (7=large, 8=medium) |
| `A2` | `OUTPUT_RESET` | `8 8` | Сброс слоя по маске |
| `A3` | `OUTPUT_STOP` | `8 8 8` | layer, nos, brake |
| `A4` | `OUTPUT_POWER` | `8 8 8` | |
| `A5` | `OUTPUT_SPEED` | `8 8 8` | |
| `A6` | `OUTPUT_START` | `8 8` | |
| `A7` | `OUTPUT_POLARITY` | `8 8 8` | |
| `A8` | `OUTPUT_READ` | `8 8 8* 32*` | speed, tacho |
| `A9` | `OUTPUT_TEST` | `8 8 8*` | busy |
| `AA` | `OUTPUT_READY` | `8 8` | |
| `AC` | `OUTPUT_STEP_POWER` | `8 8 8 32 32 32 8` | power, 3 шага, brake |
| `AD` | `OUTPUT_TIME_POWER` | `8 8 8 32 32 32 8` | |
| `AE` | `OUTPUT_STEP_SPEED` | `8 8 8 32 32 32 8` | speed, 3 шага, brake |
| `AF` | `OUTPUT_TIME_SPEED` | `8 8 8 32 32 32 8` | |
| `B0` | `OUTPUT_STEP_SYNC` | `8 8 8 16 32 8` | speed, turn, steps, brake |
| `B1` | `OUTPUT_TIME_SYNC` | `8 8 8 16 32 8` | |
| `B2` | `OUTPUT_CLR_COUNT` | `8 8` | |
| `B3` | `OUTPUT_GET_COUNT` | `8 8 32*` | |
| `B4` | `OUTPUT_PRG_STOP` | — | |

### 4.13 Файлы (`C0`)

| Опкод | Мнемоника | Параметры |
|---|---|---|
| `C000` | `FILE OPEN_APPEND` | `8+ 16*` |
| `C001` | `FILE OPEN_READ` | `8+ 16* 32*` |
| `C002` | `FILE OPEN_WRITE` | `8+ 16*` |
| `C003` | `FILE READ_VALUE` | `16 8 F*` |
| `C004` | `FILE WRITE_VALUE` | `16 8 F 8 8` |
| `C005` | `FILE READ_TEXT` | `16 8 16 8*` |
| `C006` | `FILE WRITE_TEXT` | `16 8 8+` |
| `C007` | `FILE CLOSE` | 16 |
| `C008` | `FILE LOAD_IMAGE` | `16 8+ 32* 32*` |
| `C009` | `FILE GET_HANDLE` | `8+ 16* 8*` |
| `C00A` | `FILE MAKE_FOLDER` | `8+ 8*` |
| `C00B` | `FILE GET_POOL` | `32 16* 32*` |
| `C00C` | `FILE SET_LOG_SYNC_TIME` | `32 32` |
| `C00D` | `FILE GET_FOLDERS` | `8+ 8*` |
| `C00E` | `FILE GET_LOG_SYNC_TIME` | `32* 32*` |
| `C00F` | `FILE GET_SUBFOLDER_NAME` | `8+ 8 8 8*` |
| `C010` | `FILE WRITE_LOG` | `16 32 8 F*` |
| `C011` | `FILE CLOSE_LOG` | `16 8+` |
| `C012` | `FILE GET_IMAGE` | `8+ 16 8 32*` |
| `C013` | `FILE GET_ITEM` | `8+ 8+ 8*` |
| `C014` | `FILE GET_CACHE_FILES` | `8*` |
| `C015` | `FILE PUT_CACHE_FILE` | `8+` |
| `C016` | `FILE GET_CACHE_FILE` | `8 8 8*` |
| `C017` | `FILE DEL_CACHE_FILE` | `8 8 8*` |
| `C018` | `FILE DEL_SUBFOLDER` | `8+ 8+` |
| `C019` | `FILE GET_LOG_NAME` | `8 8*` |
| `C01B` | `FILE OPEN_LOG` | `8+ 32 32 32 32 32 8 16*` |
| `C01C` | `FILE READ_BYTES` | `16 16 8*` |
| `C01D` | `FILE WRITE_BYTES` | `16 16 8*` |
| `C01E` | `FILE REMOVE` | 16 |
| `C01F` | `FILE MOVE` | `8+ 8+` |

### 4.14 Массивы (`C1`), память, имена файлов

| Опкод | Мнемоника | Параметры | Назначение |
|---|---|---|---|
| `C100` | `ARRAY DELETE` | 16 | Удалить массив |
| `C101` | `ARRAY CREATE8` | `32 16*` | Создать байтовый массив |
| `C102` | `ARRAY CREATE16` | `32 16*` | |
| `C103` | `ARRAY CREATE32` | `32 16*` | |
| `C104` | `ARRAY CREATEF` | `32 16*` | Float-массив |
| `C105` | `ARRAY RESIZE` | `16 32` | |
| `C106` | `ARRAY FILL` | `16 ?` | Заполнить значением |
| `C107` | `ARRAY COPY` | `16 16` | Копировать |
| `C108`-`C10B` | `ARRAY INIT8/16/32/F` | `16 32 P t` | Инициализация P значениями |
| `C10C` | `ARRAY SIZE` | `16 32*` | |
| `C10D` | `ARRAY READ_CONTENT` | `16 16 32 32 8*` | Чтение байтов |
| `C10E` | `ARRAY WRITE_CONTENT` | `16 16 32 32 8*` | Запись байтов |
| `C10F` | `ARRAY READ_SIZE` | `16 16 32*` | |
| `C2` | `ARRAY_WRITE` | `16 32 ?` | Запись элемента по индексу |
| `C3` | `ARRAY_READ` | `16 32 ?*` | Чтение элемента |
| `C4` | `ARRAY_APPEND` | `16 ?+` | Добавить элемент |
| `C5` | `MEMORY_USAGE` | `32* 32*` | |
| `C610`-`C617` | `FILENAME *` | см. `bytecodelist.txt:409-416` | `EXIST`, `TOTALSIZE`, `SPLIT`, `MERGE`, `CHECK`, `PACK`, `UNPACK`, `GET_FOLDERNAME` |
| `C8`-`CB` | `READ8/16/32/F` | `t* 8 t*` | Косвенное чтение по 8-битному индексу |
| `CC`-`CF` | `WRITE8/16/32/F` | `t 8 t*` | Косвенная запись |
| `D0` | `COM_READY` | `8 8*` | |

`FILENAME(GET_FOLDERNAME,127,result)` — синтаксис с круглыми скобками в ассемблере (`c_Program.txt:12`); токенизатор `TokenizeLine` просто пропускает `(`, `)`, `,` (`Assembler.cs:655-658`).

### 4.15 COM, MAILBOX

| Опкод | Мнемоника | Параметры |
|---|---|---|
| `D301`-`D314` | `COM_GET *` | см. `bytecodelist.txt:430-446` — `GET_BRICKNAME`, `GET_ID`, `GET_PRESENT`, `SEARCH_ITEMS`, `GET_NETWORK`, … |
| `D401`-`D40D` | `COM_SET *` | см. `bytecodelist.txt:448-459` — `SET_CONNECTION`, `SET_BRICKNAME`, `SET_PASSKEY`, `SET_SSID`, … |
| `D5` | `COM_TEST` | `8 8+ 8*` |
| `D6` | `COM_REMOVE` | `8 8+` |
| `D7` | `COM_WRITEFILE` | `8 8+ 8+ 8` |
| `D8` | `MAILBOX_OPEN` | `8 8+ 8 8 8` |
| `D9` | `MAILBOX_WRITE` | `8+ 8 8+ 8 8 ?+` |
| `DA` | `MAILBOX_READ` | `8 16 8 ?*` |
| `DB` | `MAILBOX_TEST` | `8 8*` |
| `DC` | `MAILBOX_READY` | 8 |
| `DD` | `MAILBOX_CLOSE` | 8 |

---

## 5. Кодирование операндов и данных

### 5.1 Константы (`LMSObject.cs:72-93`)

| Диапазон | Минимум байт | Кодирование |
|---|---|---|
| `-32 … 31` | ≤ 1 | 1 байт: `value & 0x3F` |
| `-128 … 127` | ≤ 2 | `0x81`, затем 1 байт |
| `-32768 … 32767` | ≤ 3 | `0x82`, затем 2 байта LE |
| иначе | — | `0x83`, затем 4 байта LE |

Параметр `minimumencodingbytes` используется при back-patching меток, чтобы гарантировать известную длину placeholder'а.

### 5.2 Переменные (`LMSObject.cs:95-120`)

| Индекс | Кодирование |
|---|---|
| `0 … 31` | 1 байт: `(local ? 0x40 : 0x60) | index` |
| `32 … 127` или `-127 … -1` | `local ? 0xC1 : 0xE1`, затем 1 байт |
| 16-битный | `local ? 0xC2 : 0xE2`, затем 2 байта LE |
| 32-битный | `local ? 0xC3 : 0xE3`, затем 4 байта LE |

Бит `0x40`/`0x60` различает локальную и глобальную область. Поиск: сначала локальные, потом глобальные (`Assembler.cs:552-566`); если не найдено — `AssemblerException("Unknown identifier ...")`.

Суффикс `+N` в имени (`p.IndexOf('+')`, `Assembler.cs:540-548`) добавляет смещение к позиции — используется в `c_runtimelibrary.txt:297` (`v+1`, `v+2`, …) для `ARRAY INIT8`.

### 5.3 Строки (`LMSObject.cs:122-135`)

`0x80`, затем байты строки, затем `0x00`. Только ASCII: символ вне `1..255` → `AssemblerException("String literal contains non-ascii character")` (`LMSObject.cs:128-131`).

**Ограничение:** Basic-строка ограничена 251 символом (`Compiler.cs:1467-1470`); `OUT_S result <N>` — не более 255 байт (`LMSObject.cs:351-354`). Внутренние буферы модулей: `252` для строк, `300` для полных имён файлов, `504`–`512` для MEMORY-областей.

### 5.4 Float-константы (`LMSObject.cs:137-148`)

Префикс `0x83`, затем 4 байта IEEE-754 single (`BitConverter.GetBytes((Single)fvalue)`). Поскольку `0x83` означает «32-битная константа», **float и int32 неразличимы на уровне кодирования** — различие обеспечивается типом параметра опкода (`DataType.F` vs `DataType.I32`).

### 5.5 Метки (`LMSObject.cs:150-202`)

Обратная ссылка (метка уже определена): вычисляется расстояние `target - program.Length`; кодируется с `minimumencodingbytes` = 1/2/3/5 в зависимости от величины (`LMSObject.cs:159-179`). Отличие от обычных констант: **смещение -1, -2, -3 или -5** — компенсация длины самого параметра, чтобы точка отсчёта была началом инструкции.

Прямая ссылка: placeholder `0x83 00 00 00 00`, позиция запоминается в `references[program.Length + 1]` (`LMSObject.cs:183-189`). При `WriteByteCodes` (`LMSObject.cs:214-262`) патчится `labels[label] - (i + 4)` — относительный переход.

Разница меток `A:B` (`LMSObject.cs:232-243`) патчится как `labels[B] - labels[A]` (32-битная константа) — используется для `WRITE32 ENDSUB_X:CALLSUBL STACKPOINTER RETURNSTACK`.

### 5.6 Формат `.rbf` (`Assembler.cs:596-635`)

```
'L' 'E' 'G' 'O'
u32 imgsize     = totalheadersize + len(allbytecodes)
u16 version     = 0x0068
u16 numobjects
u32 globals.TotalBytes()
[numobjects] { u32 offsetToInstructions; u16 owner(0); u16 triggercount(0=thread,1=subcall); u32 localbytes }
[allbytecodes]
```

`totalheadersize = 16 + numobjects * 12` (`Assembler.cs:605`). Объекты нумеруются в порядке появления (`objects.Count + 1`); ID в `CALL` — это этот номер. Заголовок subcall'а-алиаса указывает на `implementation.offsetToInstructions` (`LMSObject.cs:370-376`).

### 5.7 IO-дескрипторы subcall (`LMSObject.cs:378-447`)

Тело subcall'а начинается с числа параметров (1 байт) и по 1–2 байта на параметр:

| Байт | Значение |
|---|---|
| `0x80` + тип | вход |
| `0x40` + тип | выход |
| `0xC0` + тип | вход-выход |
| тип `0x00` | I8 (одиночный) |
| тип `0x01` | I16 |
| тип `0x02` | I32 |
| тип `0x03` | F |
| тип `0x04` + длина | строка I8 |

Тип `IN_S`/`OUT_S`/`IO_S` — это `DataType.I8` с `ioStringSizes[i] != 0` (`LMSObject.cs:349-358`). После кода автоматически дописываются `0x08` (RETURN) и `0x0A` (OBJECT_END) (`LMSObject.cs:431-433`).

При интеграции все вызовы проверяются на совпадение числа параметров и типов (`LMSObject.cs:436-446`); несовпадение → `AssemblerException`. Это **основной** источник ошибок «Detected use of CALL X with N parameters instead of M».

### 5.8 Выравнивание данных (`DataArea.cs:57-84`)

Элемент размещается по адресу, кратному его размеру; при необходимости добавляется padding. **Параметры (IN_/OUT_/IO_) не могут быть дополнены padding'ом** (`DataArea.cs:73-80`) и **не могут идти после DATA** (`DataArea.cs:64-71`) — иначе `AssemblerException`. Порядок объявлений в модулях поэтому жёстко фиксирован: сначала все `IN_*`/`OUT_*`, потом `DATA*`. Порт, генерирующий тот же `.rbf`, обязан воспроизвести этот порядок.

---

## 6. Медиа: звук и картинки

### 6.1 Синтаксис

| Конструкция | Требуемое расширение | Пример |
|---|---|---|
| `LCD.BmpFile(col,x,y,"имя")` | `.rgf` | `Other/GraphicsAndSounds.bp:19` |
| `Speaker.Play(vol,"имя")` | `.rsf` | `Other/GraphicsAndSounds.bp:22` |
| `EV3File.OpenWrite("имя")` | любой | `Other/File.bp:4` |
| `EV3File.OpenAppend("имя")` | любой | — |
| `EV3File.OpenRead("имя")` | любой | `Other/File.bp:15` |
| `EV3File.TableLookup("имя",bpr,row,col)` | любой | `c_EV3File.txt:221` |

### 6.2 `MediaBuilder.cs` — что и когда делает

`MediaBuilder.ParseMedia(Line)` (`MediaBuilder.cs:14-124`) вызывается препроцессором для каждой строки, **только если задана папка проекта** (`Data.Project.IsFolder`, `MediaBuilder.cs:16-19`). Правило срабатывания (`MediaBuilder.cs:22`, `39`, `56`, `73`, `90`, `107`):

```
text.ToLower().IndexOf("<метод>") != -1
  AND ( text.IndexOf("'") == -1 OR text.ToLower().IndexOf("<метод>") > text.IndexOf("'") )
  AND в строке есть две '"' (двойные кавычки), вторая правее первой
```

То есть: имя медиа-файла задаётся **двойными кавычками**, а одинарная кавычка (комментарий В Basic) левее вызова отключает обработку.

Действие: имя извлекается между первой и последней `"` (`MediaBuilder.cs:128-130`), переписывается вместе с путём, и строка **перестраивается заново** (`LineBuilder.GetWords`). Итоговое имя попадает в Basic-строку, а значит — в байткод как строковый литерал.

### 6.3 Что подставляется вместо имени (`MediaBuilder.cs:201-343`)

| `Folder` | `ProjectName` | Подставляемый путь (media) | В `ImageList`/`SoundList` |
|---|---|---|---|
| `prjs` | задан | `<ProjectName>/Media/<name>` | да |
| `prjs` | пусто | `<name>` | `mediaPath = "no"` |
| `sd` | задан | `SD_Card/<ProjectName>/Media/<name>` | да |
| `sd` | пусто | `<name>` | `mediaPath = "no"` |
| иначе | — | `<name>` | `mediaPath = "no"` |

В списки добавляется **с расширением**: `mediaName + ".rgf"` для картинок (`MediaBuilder.cs:136`), `mediaName + ".rsf"` для звуков (`MediaBuilder.cs:156`), без расширения — для файлов (`MediaBuilder.cs:176`, `MediaBuilder.cs:192`). Дедупликация по имени (`!Contains`).

Для `EV3File.TableLookup` хвост строки после закрывающей `"` сохраняется как есть (`MediaBuilder.cs:189`, `MediaBuilder.cs:305`).

### 6.4 Что попадает в байткод

`MediaBuilder` **не генерирует** отдельных опкодов — он лишь переписывает строковый аргумент в Basic-строке. В `.rbf` попадает:

- `LCD.BmpFile` → `UI_DRAW BMPFILE col_8 x_16 y_16 <fullname>` (`c_LCD.txt:266`). `c_LCD.txt:259-264` дополнительно: если имя не начинается с `/` (код 47), к нему приписывается `'/home/root/lms2012/prjs/'`; затем приписывается `'.rgf'`.
- `Speaker.Play` → `SOUND PLAY vol <fullname>` (`c_Speaker.txt:55`). `c_Speaker.txt:50-52`: при не-абсолютном пути префикс `'../../../..'`, затем **замена** на `'../prjs/'` (это два последовательных `STRINGS ADD`, второй перезаписывает результат первого — фактически всегда остаётся `'../prjs/'`).
- `EV3File.Open*` → `FILE OPEN_* <fullname>` — префикс `/home/root/lms2012/prjs/` при не-абсолютном пути (`c_EV3File.txt:11-15`, `28-32`, `46-50`).
- `EV3File.TableLookup` → строка shell-команды `tablelookup <path> <bpr> <row> <col>`, которая передаётся в `EV3.NativeCode` (`c_EV3File.txt:240-253`).

**Списки `ImageList`/`SoundList`/`FileList` в байткод не попадают** — они используются средой разработки для копирования файлов на brick.

### 6.5 Квирк медиа

`mediaName`/`mediaPath`/`mediaFullName` — **поля экземпляра** `MediaBuilder` (`MediaBuilder.cs:11-13`), обнуляемые в начале каждой ветки (`MediaBuilder.cs:26-28` и т.д.), но в `AddPathMedia`/`AddPathFile`/`AddPathTableLookupFile` **не обнуляются при пустом `ProjectName`** — они явно устанавливаются в `"no"`. Без явного `folder`-объявления проект попадает в `else`-ветку и путь не переписывается; при этом `mediaName` всё равно выставляется в имя файла.

---

## 7. Ошибки и диагностика

### 7.1 Два независимых канала ошибок

| Канал | Кто формирует | Куда пишет | Проверяемые свойства |
|---|---|---|---|
| **Препроцессор** | `Interpreter/Parsers/*.cs` + `DefaultObjectList` | `Data.Errors` (`List<Errore>`), коды из `ErrorsCodeList` | существование метода/свойства, число аргументов, грубая типизация |
| **Компилятор** | `Compiler.cs` через `Scanner.ThrowParseError` | `List<string> errorlist` | точные типы, неопределённые идентификаторы, структура управления |

`Builder.BPStart` (`Builder.cs:83-135`) останавливается на первой фазе с ошибками, поэтому при успешной компиляции препроцессор уже пропустил вызов.

### 7.2 Ошибки компилятора (строки)

Все — `CompileException` с суффиксом `at: <line>:<col>` (`Scanner.cs:85-88`), где line/col — 1-based:

| Сообщение | Условие | Ссылка |
|---|---|---|
| `Undefined command: <OBJ>.<ELEM>` | нет `library[cmdname]` (вызов-выражение, non-void) | `Compiler.cs:1078` |
| `Undefined command or property: <CMD>` | нет в `library` при чтении значения | `Compiler.cs:1576` |
| `Unknown property to set: <OBJ>.<ELEM>` | `obj.elem = ...`, кроме `THREAD.RUN` и `F.START` | `Compiler.cs:987` |
| `Can not use command that returns nothing in an expression` | `libentry.returnType == Void` в позиции значения | `Compiler.cs:1581` |
| `Can not reference <CMD> as a property` | вызов без `(`, но `paramTypes.Length != 0` | `Compiler.cs:1625` |
| `Can not use this expression type here: <T>. Expected: <T2>` | несовпадение типа аргумента | `Compiler.cs:1122` |
| `Too few arguments to <CMD>` | `list.Count < paramTypes.Length` | `Compiler.cs:1616` |
| `Undefined local variable: <NAME>` | `F.SET`/`F.GET` по неизвестному имени | `Compiler.cs:1012`, `Compiler.cs:1565` |
| `Can only use RETURN from inside function` | `F.RETURN` вне функции | `Compiler.cs:1030` |
| `Can only use RETURN in primary SUB of a function` | `F.RETURN` в не-первичном sub | `Compiler.cs:1034` |
| `Return command must be of same type as function definiton` | тип возврата не совпал | `Compiler.cs:1044` |
| `Undefined function: <NAME>` | `F.CALL` по неизвестному имени | `Compiler.cs:1060`, `Compiler.cs:1587` |
| `Too many arguments for function: <NAME>` | превышен `getParameterNumber()` | `Compiler.cs:1071`, `Compiler.cs:1594` |
| `Return value that is an array must be directly stored in a variable` | результат-массив в temp | `Compiler.cs:1096` |
| `Can not assign different types to <NAME>` | повторное присваивание другого типа | `Compiler.cs:880` |
| `Can not use <NAME> as loop counter. Is already defined to contain non-number` | `FOR` по не-числовой переменной | `Compiler.cs:728` |
| `Can not use <NAME> as array to store this type` | конфликт типа массива | `Compiler.cs:906` |
| `Can only store numbers or strings into arrays` | присваивание в массив массива | `Compiler.cs:900` |
| `can not use variable <NAME> before first assignment` | чтение до присваивания | `Compiler.cs:1544` |
| `can not use array <NAME> before first assignment` | `a[i]` до создания | `Compiler.cs:1510` |
| `Need array to use with '[]'` | `[]` по скалярной переменной | `Compiler.cs:1518` |
| `Text is longer than 251 letters` | строковый литерал > 251 | `Compiler.cs:1468` |
| `Need a text as a boolean value here` | условие `IF`/`WHILE` не текст | `Compiler.cs:639`, `Compiler.cs:700` |
| `Need identical types on both sides of '='` / `'<>'` | `=`/`<>` с разными типами | `Compiler.cs:1206`, `Compiler.cs:1227` |
| `Can not compare arrays` | `=`/`<>` на массивах | `Compiler.cs:1215`, `Compiler.cs:1239` |
| `Can not concat arrays` | `+` с массивом | `Compiler.cs:1305`, `Compiler.cs:1318`, `Compiler.cs:1349`, `Compiler.cs:1372` |
| `Unknown PRAGMA: <NAME>` | неизвестный `PRAGMA` | `Compiler.cs:601` |
| `Reference to undefined function: <NAME>` | `memorize_reference` по неизвестному имени | `Compiler.cs:534` |
| `Unexpected <TYPE> <CONTENT>` | `ThrowUnexpectedSymbol` | `Scanner.cs:109` |
| `Expected <TYPE>` / `Expected <TEXT>` | `ThrowExpectedSymbol` | `Scanner.cs:116`, `Scanner.cs:121` |

**Предупреждений компилятор не генерирует.** `errorlist` содержит только строки ошибок; успех — пустой список.

### 7.3 Ошибки препроцессора (коды)

Ключевые для встроенных объектов (`ErrorsCodeList.cs`, RU-версия):

| Код | Текст | Ссылка |
|---|---|---|
| 1301 | Метод не найден | `ErrorsCodeList.cs:74` |
| 1304 | Неверное количество параметров | `ErrorsCodeList.cs:77` |
| 1305 | Переменной не присвоено значение | `ErrorsCodeList.cs:78` |
| 1306 | Метод в качестве параметра не возвращает значений | `ErrorsCodeList.cs:79` |
| 1307 | Неверный тип параметра | `ErrorsCodeList.cs:80` |
| 1308 | Неверное количество параметров, либо отсутствует математический оператор | `ErrorsCodeList.cs:81` |
| 1309 | Недопустимый математический оператор | `ErrorsCodeList.cs:82` |
| 1310 | Разные типы данных | `ErrorsCodeList.cs:83` |
| 1311 | Лишние математические операторы | `ErrorsCodeList.cs:84` |
| 1312 | Отсутствует параметр | `ErrorsCodeList.cs:85` |
| 1313 | Метод не возвращает значений | `ErrorsCodeList.cs:86` |
| 1314 | Неправильное определение метода | `ErrorsCodeList.cs:87` |
| 1820 | Параметр имеет другой тип | `ErrorsCodeList.cs:159` |
| 1821 | В вызове функции выходной параметр может быть только переменной | `ErrorsCodeList.cs:160` |

Проверка числа аргументов — `MethodErrorParser.cs:39-42` (`signature.InputCount != param.Count` → 1304). Проверка типа — `MethodErrorParser.cs:43-60` (поэлементно, коды 1307/1310). Код 1301 — `MethodErrorParser.cs:31-32`.

### 7.4 Ошибки ассемблера

Ассемблер сообщает с номером строки: `"Error at line <N>: <msg>"` (`Assembler.cs:99-101`); ошибки этапа линковки — `"Error at subcall integration: <msg>"` (`Assembler.cs:104-106`). Источники (`AssemblerException`):

| Сообщение | Условие |
|---|---|
| `Unknown opcode <X>` | нет в `bytecodelist` |
| `Too few parameters for <NAME>` | меньше параметров, чем в дескрипторе |
| `Invalid number of parameters for <NAME>` | не совпало итоговое число |
| `Unknown identifier <NAME>` | переменная не найдена ни локально, ни глобально |
| `Identifier <NAME> already in use` | дубликат в DataArea |
| `Can not place IN,OUT,IO elements after DATA elements` | порядок объявлений |
| `Can not insert padding for propper alignment...` | невозможность выровнять параметр |
| `Duplicate definition of <NAME>` | два `vmthread`/`subcall` с одним именем |
| `Unresolved subcall: <NAME>` | subcall объявлен, но тело не сгенерировано |
| `Unresolved jump target: <LABEL>` | метка не определена |
| `Unresolved label distance: <A>:<B>` | одна из меток не определена |
| `Trying to call an object that is not defined as a SUBCALL` | `CALL` на `vmthread` |
| `Trying to start an object that is not defined as a thread` | `OBJECT_START` на subcall |
| `Detected use of CALL <NAME> with <N> parameters instead of <M>` | несовпадение числа аргументов при линковке |
| `Using variable of wrong type for call: <NAME>` | `DataTypeChecker` (`DataType.cs:56-64`) |
| `Using constant value as parameter where a variable reference is required` | константа в output-параметре |
| `Constant value <N> out of range of I8/I16` | выход за диапазон |
| `Can not use float literal '<F>' for this parameter type` | float туда, где не F |
| `Can not use string literal '<S>' for this parameter type` | строка не в I8-параметр |
| `Length of IO parameter must not exceed 255 bytes` | `IN_S x 300` |

---

## 8. Квирки и опасные места

| № | Квирк | Следствие для портирования |
|---|---|---|
| 1 | Встроенные методы — **текстовые модули**, а не таблица опкодов (`Compiler.cs:73-105`) | Порт обязан перенести 31 файл ресурсов и парсер `readLibraryModule` |
| 2 | `c_BitMask.txt` не в `readLibrary` | Не пытаться его «читать» |
| 3 | Placeholder'ы `:0..:9`, `:#` (`Expression.cs:267-311`) | Полноценный шаблонизатор с трекингом использованных аргументов |
| 4 | Неупомянутые аргументы дописываются в конец (`Expression.cs:223-230`) | Модули вроде `MATH FLOOR` без явных placeholder'ов работают только благодаря этому |
| 5 | `MOTORA` и `MOTORAB.SETSPEED` пишут в общую `setSpeedA` | Порядок вызовов меняет поведение |
| 6 | `Math.Sin/Cos/Tan` принимают **градусы** и умножают на 57.29…; `ArcSin/ArcCos/ArcTan` возвращают градусы | Легко перепутать при переносе на радианы |
| 7 | `CP_LT32` объявлен как `16 16 8*` (`bytecodelist.txt:79`) | Вероятная опечатка; порт должен её воспроизвести для побайтовой совместимости |
| 8 | Три опкода делят `0x30`, два — `0x26` | Разрешение имён в ассемблере по строке, не по опкоду (`Assembler.cs:391-406`) |
| 9 | `PROGRAM.ARGUMENTCOUNT`/`GETARGUMENT` — заглушки (`c_Program.txt:3-20`) | Не реализовывать «настоящие» аргументы без сверки |
| 10 | `TEXT.*` и `ASSERT.FAILED` используют `MEMORY_READ/WRITE` с абсолютными адресами 508/512 | Работает только из slot 1 — опасно при любом другом размещении |
| 11 | `Vector.Sort` использует `ARRAY32 beg 128` | Переполнение при >128 элементов в сортировке |
| 12 | `EV3.SetLEDColor` не обрабатывает `'OFF'` явно → `col = 0` | Недокументированное поведение |
| 13 | `Speaker.Play` дважды делает `STRINGS ADD` в один и тот же `fullname` | Первый префикс `'../../../..'` всегда перезаписывается |
| 14 | `DefaultObjectList` и `library` — **разные каталоги** | Кодогенерация должна опираться на `library` (`*.txt`), а не на `DefaultObjectList.cs` |
| 15 | `EV3.NATIVE CODE` требует вставки `CreateNativeCodeDownload()` в MAIN (`Compiler.cs:340-344`) | Особый случай, не сводится к обычному `CALL` |
| 16 | `Thread.Run` — присваивание, а не вызов (`Compiler.cs:960-979`) | Отдельная ветка парсера |
| 17 | Атомарность `Thread.Lock` опирается на гарантию VM «subcall не выполняется параллельно» (`c_Thread.txt:11-15`) | Нет прямого аналога без поддержки VM |
| 18 | `DataArea` требует параметры до данных и без padding (`DataArea.cs:57-84`) | Порядок объявлений в `.lmsb` критичен, генератор обязан его соблюсти |
| 19 | `WHILE` генерирует условие **дважды** (`Compiler.cs:704`, `Compiler.cs:712`) | Удваивает побочные эффекты и расход временных переменных |
| 20 | `FLOAT` и `I32` константы кодируются одинаково (`0x83` + 4 байта) | Различие только через `DataType` дескриптора |
| 21 | Строки только ASCII 1..255 (`LMSObject.cs:128-131`) | Unicode в литералах приведёт к ошибке ассемблера |
| 22 | `Builder.BPStart` останавливается на первой фазе с ошибками (`Builder.cs:85-100`) | Ошибки препроцессора скрывают ошибки компилятора |
| 23 | `Scanner.ThrowParseError` добавляет `at: line:col` (`Scanner.cs:85-88`) | Формат сообщений нужно сохранить для совместимости тестов |
| 24 | `LibraryEntry.programCode` для `inline` обрезается от `{` до **первого** `}` (`LibraryEntry.cs:54-56`) | Вложенные `{}` в inline-теле невозможны |
| 25 | `Sensor1..4` жёстко используют `layer = 0` (`c_Sensor1.txt:16`) | Дейзи-чейн для «быстрых» методов недоступен |
| 26 | `Motor.IsLarge`/`IsMedium` не возвращают значение, только шлют `OUTPUT_SET_TYPE` | Имя вводит в заблуждение |
| 27 | `Assert.Near` вычисляет epsilon как `1.0/5000000.0` (float) каждым вызовом | — |
| 28 | `Byte.ToBinary` использует «растягивание битов» магическими масками `983055`/`286331153` | Не заменять на цикл — результат должен совпасть побитово |

---

## 9. Резюме

1. **Архитектура кодогенерации двухслойная.** `Compiler.cs` транслирует Basic в *текст ассемблера* EV3-Basic-диалекта (верхний регистр, опкоды из `bytecodelist.txt`); `Assembler.cs` — в байты `.rbf`. Порт на Mojo должен воспроизвести оба слоя, а не только один.

2. **Встроенные методы — это не таблица, а 31 текстовый модуль-ресурс** (`Interpreter/Compiler/Resources/c_*.txt`), регистрируемых в `Compiler.cs:73-105`. Каждый объявляет себя как `inline` (код подставляется в место вызова) либо `subcall` (генерируется отдельный объект VM). `init`-блоки безусловно попадают в `vmthread MAIN`.

3. **Механизм placeholder'ов `:0..:9` и `:#` — сердце встроенных методов** (`Expression.cs:267-311`). Неиспользованные аргументы автоматически дописываются в конец — на этом построены модули без явных подстановок (`MATH FLOOR`, `MATH LOG` и др.).

4. **`DefaultObjectList.cs` — не источник истины для кодогенерации.** Он используется только препроцессором для проверки имён и арности (`MethodErrorParser.cs:31`). Реальные сигнатуры — в `library` (`LibraryEntry`, из `*.txt`). Расхождения возможны (например, `EV3.NATIVECODE` есть в `library`, но отсутствует в `DefaultObjectList`).

5. **Каталог: 25 классов** — `assert`, `buttons`, `byte`, `ev3`, `ev3file`, `lcd`, `mailbox`, `math`, `motor`, `motora..motord`, `motorab..motorcd`, `program`, `row`, `sensor`, `sensor1..sensor4`, `speaker`, `text`, `thread`, `time`, `vector`, плюс внутренние `F.*`. 20+ опкодных семейств: управление (00–0F), арифметика (10–2F), пересылки (30–3F), переходы (40–7B), строки (7D), UI (80–84), таймеры/математика (85–8F), звук/ввод (94–9F), моторы (A1–B4), файлы (C0), массивы (C1–C5), COM/mailbox (D3–DD).

6. **Главные риски портирования:** (а) воспроизведение `DataArea`-порядка с выравниванием без padding для параметров — иначе `.rbf` не соберётся; (б) кодирование констант/переменных 4 формами (`LMSObject.cs:72-120`); (в) back-patching меток с переменной длиной (`LMSObject.cs:150-202`); (г) `TEXT.*` и `ASSERT.FAILED`, читающие память по абсолютным адресам — они не переносимы без сохранения slot-семантики; (д) опечатка `CP_LT32 16 16 8*`, которую нужно воспроизвести; (е) `Motor*` делят `setSpeedA`/`setPowerA` между классами; (ж) `Vector.Sort` ограничен 128 элементами. Побайтовое сравнение с `Program1.rbf`/`~/Other/~Battery/Battery.rbf` — обязательный тест приёмки.