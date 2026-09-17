# 01. Лексер и грамматика Basic Plus (Clev3r → Mojo)

Все ссылки вида `File.cs:N` — на репозиторий `/home/ssssq/Projects/clev3r_linux/Clev3r-1`.
Пометки: **(проверено)** — выведено прямо из кода/корпуса; **(гипотеза)** — вывод, не подтверждённый запуском.

## 0. Пайплайн и два уровня языка

Компилятор трёхстадийный: `Builder.BPStart` (`Builder.cs:59-140`) запускает
Preprocessor → Interpreter → Compiler → Assembler. Язык существует в **двух уровнях**:

| Уровень | Чем разбирается | Вход | Ключевые особенности |
|---|---|---|---|
| BP-уровень («Basic Plus») | `Utils/LineBuilder.cs` + `Utils/TokenBuilder.cs` + `Parsers/*` | исходники `.bp/.bpi/.bpm` (UTF-8, построчно) | `Function/in/out`, `@`-глобалы, модули, `break/continue/return`, `++/--/+=`, типы NUMBER/STRING |
| Компиляторный уровень (наследие EV3-Basic) | `Compiler/Scanner.cs` + `Compiler/Compiler.cs` | развёрнутый файл `~Name.bp` | только `SUB`, без FUNCTION/BREAK/RETURN (уже развёрнуты), `F.*` legacy, вещественная арифметика |

Развёртка BP→компиляторный видна на сквозном примере: `/home/ssssq/Windows/Program1.bp` →
`/home/ssssq/Windows/~Program1/~Program1.bp` (появляются `gv_*`/`lv_*`, `Sub f_map_data_2`,
инициализация переменных нулями в начале MAIN). Стадия 3 «не знает» про `Function`, `in/out`,
`break` и т.п. — она получает уже плоский текст (`Builder.cs:106-122`).

Расширения: `.bp`, `.bpi` (include), `.bpm` (module), `.lms` (`Builder.cs:26-29`).
Кодировка входа стадии 3: UTF-8 (`Compiler/Scanner.cs:43`), строки читаются `ReadLine` до конца потока (`Compiler/Scanner.cs:46-49`).

Языковые варианты `ru/en/ua`: **влияют только на тексты сообщений об ошибках**
(`Builder.cs:40-54` → `Language.Type`, `CommonData/Data.cs:19-31` → `ErrorsCodeList.SetRU/SetEN/SetUA`).
Ключевых слов ru/ua в коде нет — все ключевые слова английские. Гипотеза из ТЗ об алиасах
опровергнута **(проверено)**: единственные локализованные строки — справка IDE
(`Clever/Model/Intellisense/IntellisenseInfo.cs:658,666`) и списки ошибок.

Файл `Clever/Model/Bplus/BpLexer.cs` (1637 строк) — это **только подсветка/автодополнение IDE**
(Scintilla-стили, `BpLexer.cs:78,250-253`); в компиляцию не входит. Портить его не нужно.

## 1. Перечисления с числовыми значениями

### 1.1 Tokens, `Interpreter/Enums/Tokens.cs:3-29` (стадии 1-2)

Значения = порядковый индекс (0-based):

| # | Имя | Смысл |
|---|-----|-------|
| 0 | METHOD | встроенный метод/свойство объекта (`lcd.text`, `ev3.brickname`) |
| 1 | STRING | строковый литерал (вместе с кавычками, `"..."`) |
| 2 | VARIABLE | переменная (Text всегда ВЕРХНИЙ регистр) |
| 3 | EQU | `=` |
| 4 | SUBNAME | имя процедуры (ВЕРХНИЙ регистр) |
| 5 | NUMBER | числовой литерал |
| 6 | KEYWORD | ключевое слово |
| 7 | LABEL | метка-определение `name:` (с двоеточием) |
| 8 | LABELNAME | имя в `goto name` |
| 9 | MATHOPERATOR | `+ - * /` |
| 10 | MODULEMETHOD | `mod.method` — метод пользовательского модуля |
| 11 | MODULEPROPERTY | `mod.prop` — свойство модуля |
| 12 | DOUBLEMATH | `++` / `--` |
| 13 | EQUMATH | `+= -= *= /=` |
| 14 | BOOLOPERATOR | `<> <= >= < >` |
| 15 | BRACKETLEFT | `(` |
| 16 | BRACKETRIGHT | `)` |
| 17 | BRACKETLEFTARRAY | `[` |
| 18 | BRACKETRIGHTARRAY | `]` |
| 19 | DOUBLEBRACKET | `()` |
| 20 | DOUBLEBRACKETARRAY | `[]` |
| 21 | COMMA | `,` |
| 22 | FUNCNAME | имя функции в строке `Function ...` |
| 23 | PREPROCESSOR | слово `#` |
| 24 | NON | не классифицировано |

IDE-версия `Clever/Model/Bplus/BPInterpreter/Tokens.cs:9-35` отличается: нет `MODULEPROPERTY`/`PREPROCESSOR`,
добавлен `COMMENT`; из-за смещений значения 10+ другие (MODULEMETHOD=10, DOUBLEMATH=11, …, COMMENT=22, NON=23).

### 1.2 LineType, `Interpreter/Enums/LineType.cs:7-38`

| # | Имя | # | Имя | # | Имя |
|---|-----|---|-----|---|-----|
| 0 | VARINIT | 10 | MODULEPROPERTY | 20 | IMPORT |
| 1 | VARDOUBLEMATH | 11 | ONEKEYWORD | 21 | EMPTY |
| 2 | VAREQUMATH | 12 | LABELINIT | 22 | NUMBERINIT |
| 3 | VARARRAYINIT | 13 | LABELCALL | 23 | NUMBERARRAYINIT |
| 4 | SUBINIT | 14 | FORINIT | 24 | STRINGINIT |
| 5 | SUBCALL | 15 | IFINIT | 25 | STRINGARRAYINIT |
| 6 | FUNCINIT | 16 | ELSEIFINIT | 26 | OLDFUNC |
| 7 | FUNCCALL | 17 | WHILEINIT | 27 | PREPROCESSOR |
| 8 | METHODCALL | 18 | INCLUDE | 28 | NON |
| 9 | MODULEMETHODCALL | 19 | FOLDER | | |

Недостижимые значения: `FUNCCALL` (токен FUNCNAME не бывает первым словом — `Utils/TokenBuilder.cs:109-113`
требует `prevWord == "function"`), `OLDFUNC`, `PREPROCESSOR` (используется только `EMPTY`,
`Utils/LineBuilder.cs:413-416`). «Проскакивающие» значения (не обрабатываются парсерами стадий 1-2,
уходят в выходной файл и роняют стадию 3, если встретятся в MAIN): `NUMBERINIT/NUMBERARRAYINIT/
STRINGINIT/STRINGARRAYINIT`. Исключение: такие строки валидны **внутри .bpm как декларации свойств
модуля** — их отдельно читает Linker (`Utils/Linker.cs:788-855`).

### 1.3 SymType, `Interpreter/Compiler/Scanner.cs:26` (стадия 3)

`byte`-enum: `ID=0, NUMBER=1, STRING=2, KEYWORD=3, SPECIAL=4, EOL=5, EOF=6, PRAGMA=7`.

### 1.4 Прочие перечисления

| Enum | Файл | Значения |
|---|---|---|
| VariableType | `Enums/VariableType.cs:3-10` | `STRING, STRING_ARRAY, NUMBER, NUMBER_ARRAY, ANY, NON` |
| ParameterType | `Enums/ParameterType.cs:5-9` | `INPUT, OUTPUT, NON` |
| ObjectType | `Enums/ObjectType.cs:5-10` | `METHOD, EVENT, PROPERTY, NON` |
| ExpressionType | `Compiler/Expression.cs:25-32` | `Number` (double!), `Text`, `NumberArray`, `TextArray`, `Void` |
| LanguageType | `Enums/LanguageType.cs:5-9` | `RU, EN, UA` |

## 2. Построчная модель, комментарии, строки

- **Один оператор = одна строка.** Нет символа продолжения, нет `:` как разделителя
  (двоеточие — только признак метки). Несколько операторов в строке невозможны:
  стадия 3 требует EOL после оператора (`Compiler/Compiler.cs:627,1692-1699`).
- Пустые строки и строки из одних пробелов допустимы: стадия 1 даёт `LineType.EMPTY`
  (`Utils/LineBuilder.cs:418-421`), стадия 3 пропускает EOL (`Compiler/Compiler.cs:603-607`).
- Отступы (пробелы/табы) значимы только как разделители, семантики блоков нет — блоки
  закрываются `End…`-словами (`Compiler/Compiler.cs:631-792`).
- **Комментарий** — от первого `'` до конца строки, в любом месте (`Utils/LineBuilder.cs:17-31`,
  `Compiler/Scanner.cs:160-165`). Многострочных комментариев нет.
  ⚠ Комментарий режется **до** разбора строковых литералов: `'` внутри `"..."` обрежет
  строку (`"it's"` → `"it"`) **(проверено по коду, гипотеза о реальном поведении)**.
- `#…`-строки: слово `#` → `Tokens.PREPROCESSOR` (`Utils/TokenBuilder.cs:23-26`) → `LineType.EMPTY`,
  т.е. любые `#...`-директивы на стадиях 1-2 просто игнорируются (реальные препроцессорные
  директивы IDE читает отдельно; см. док препроцессора). Пример: `'#main ../Program1`
  в `tests/corpus/New_Path_Examples/Includes/Include1.bpi:1`.
- `'PRAGMA ` **(только стадия 3, только с колонки 0)**: строка, начинающаяся с `'PRAGMA `,
  даёт `SymType.PRAGMA` с содержимым `line.Substring(8).Trim()` (`Compiler/Scanner.cs:151-159`).
  Допустимые прагмы: `NOBOUNDSCHECK`, `BOUNDSCHECK`, `NODIVISIONCHECK`, `DIVISIONCHECK`
  (`Compiler/Compiler.cs:578-601`), прочие — ошибка `Unknown PRAGMA`.
  Пример: `tests/corpus/Other/BrickBench.bp:12-13`.
- Строки файла нумеруются с 1 (`DataTemplates/Program.cs:33`); перенос строки `\n`/`\r\n` — средствами `ReadLine`.

## 3. Алгоритм разбиения строки на слова (стадии 1-2)

`Utils/LineBuilder.GetWords` (`Utils/LineBuilder.cs:11-292`). Три шага:

**Шаг 1. Обрезать комментарий.** `int comment = strLine.IndexOf("'")`; если `-1` — берём всю строку,
если `>0` — часть до `'`; если `==0` — строка пустая (`Utils/LineBuilder.cs:17-31`). Затем `Trim()`.

**Шаг 2. Разделить по пробелам с учётом кавычек.** Если в строке есть `"`, текст вне кавычек
делится по `' '`, а фрагменты в кавычках (включая сами `"` ) остаются одним словом
(`Utils/LineBuilder.cs:35-101`). Разделитель — только пробел (не таб! таб внутри слова сохранится).

**Шаг 3. Порезать спецсимволы.** Множество спецсимволов (`Utils/LineBuilder.cs:108`):

```
+ - / * ( ) { } , = < > ! | & [ ] # ; % ^ @
```

Каждый такой символ становится отдельным словом, кроме пар `number[`/`string[`/`bool[` + `]`
(для IDE-версии ещё `bool`; компиляторная версия — только `number`/`string`,
`Utils/LineBuilder.cs:112-121`). Слово, содержащее `"`, не режется вовсе (`Utils/LineBuilder.cs:100-104`).

**Шаг 4. Склейка пар** (`Utils/LineBuilder.cs:142-235`), только для соседних слов:

| Первый | Второй | Результат |
|---|---|---|
| `< > = ! + - / *` | `=` | `<= >= == != += -= *= /=` |
| `&` | `&` | `&&` |
| `\|` | `\|` | `\|\|` |
| `(` | `)` | `()` |
| `{` | `}` | `{}` |
| `[` | `]` | `[]` |
| `+` | `+` | `++` |
| `-` | `-` | `--` (только если пара — последние слова строки, `Utils/LineBuilder.cs:209-217`) |
| `<` | `>` | `<>` |
| `@` | любое слово | `@word` |

Результат: `List<Word>`, где `Word.Text` = слово после склейки, `Word.OriginText` = исходное
(**идентичны**, отличия появляются позже в Linker), `Word.Token` (см. §4), `Word.Number` = 1-based
номер слова в строке (`DataTemplates/Line.cs:34`).
Важно: `x<=y`, `x=-1`, `i=0`, `a[1]` без пробелов корректно режутся — см.
`tests/corpus/HiTechnic Sensors/Compass.bp:14` (`x=-1-znach`), `tests/corpus/Other/Threads.bp:28` (`For i=0 to 3`).

Из слов собирается `Line`: `NewLine = string.Join(" ", Text…)` — **канонический текст
с одиночными пробелами**, он идёт в выходной `~Name.bp` (`DataTemplates/Line.cs:25-30`).
Имена (`VARIABLE|SUBNAME|FUNCNAME|LABELNAME|LABEL`) приводятся к ВЕРХНЕМУ регистру в `Word.Text`
(`Utils/LineBuilder.cs:250-264`) — идентификаторы нечувствительны к регистру **(проверено)**.

## 4. Классификация слов (стадии 1-2)

`Utils/TokenBuilder.GetToken(word, prevWord, follWord, line)` (`Utils/TokenBuilder.cs:17-265`),
проверки **по порядку** (все сравнения слов — `ToLower()`):

| № | Условие | Токен |
|---|---|---|
| 1 | есть ≥2 кавычки `"` (первая < последняя) | STRING |
| 2 | слово `#` | PREPROCESSOR |
| 3 | содержит `.` | все символы из `[0-9.]` → NUMBER; иначе первый сегмент до `.` в списке классов → METHOD; иначе follWord == `(` или `()` → MODULEMETHOD, иначе MODULEPROPERTY |
| 4 | слово в списке ключевых слов | KEYWORD |
| 5 | строка начинается с `sub ` (`line[0..3]=="sub"` и `line[3]==' '`) | prevWord `sub` → SUBNAME; `(`/`)`/`()` → скобки; слово из `[0-9a-zA-Z]+` при prevWord `sub` → SUBNAME; `,` → COMMA |
| 6 | строка начинается с `function ` | prevWord `function` → FUNCNAME; prevWord ∈ {`number`,`number[]`,`string`,`string[]`} и первый символ — буква → VARIABLE; скобки/COMMA аналогично |
| 7 | содержит `:` | LABEL |
| 8 | содержит цифру | все цифры → NUMBER; начинается с `@` и длина>1 → VARIABLE; слово из `[0-9a-zA-Z_]+`: follWord содержит `(` → SUBNAME; особый случай `thread.run = name` (индексы: `i1<i2<i3` по `line`) → SUBNAME; prevWord `goto` → LABELNAME; иначе VARIABLE |
| 9 | содержит `+ - * /` | `++`/`--` → DOUBLEMATH; `+= -= *= /=` → EQUMATH; иначе MATHOPERATOR |
| 10 | `<> <= >= < >` | BOOLOPERATOR |
| 11 | скобки | `() [] ( ) [ ]` → DOUBLEBRACKET/DOUBLEBRACKETARRAY/BRACKETLEFT/BRACKETRIGHT/BRACKETLEFTARRAY/BRACKETRIGHTARRAY |
| 12 | `,` | COMMA |
| 13 | `=` | EQU |
| 14 | длина>1 и начинается с `@` | VARIABLE |
| 15 | слово из `[0-9a-zA-Z_]+` | как в п.8 (SUBNAME/thread.run/LABELNAME/VARIABLE) |
| 16 | иначе | NON |

Список классов (п.3) — 31 имя, `Utils/TokenBuilder.cs:267-300`:
`assert, buttons, byte, ev3, ev3file, lcd, mailbox, math, motor, motora, motorab, motorac, motorad,
motorb, motorbc, motorbd, motorc, motorcd, motord, program, row, sensor, sensor1, sensor2, sensor3,
sensor4, speaker, text, thread, time, vector`.

**Ключевые слова** (п.4, `Utils/TokenBuilder.cs:51`): `for, endfor, if, then, endif, else, elseif,
while, endwhile, and, or, sub, endsub, goto, step, to, import, include, folder, in, out, function,
endfunction, number, number[], string, string[], private, region, endregion, break, continue, return`.
Список IDE-справки идентичен (`Clever/Model/Intellisense/IntellisenseParser.cs:680-715`);
группы подсветки IDE — `BpLexer.cs:250-253`. Ключевые слова стадии 3 (отдельный, более узкий набор) — §8.

## 5. Определение типа строки

`Utils/LineBuilder.GetType(Line)` (`Utils/LineBuilder.cs:295-424`) смотрит **только на первое слово**
(сравнение `ToLower()`):

| Первое слово (KEYWORD) | LineType | | Первое слово (прочий токен) | LineType |
|---|---|---|---|---|
| `include` | INCLUDE | | LABEL (содержит `:`) | LABELINIT |
| `folder` | FOLDER | | METHOD (`obj.x`) | METHODCALL |
| `import` | IMPORT | | SUBNAME | SUBCALL |
| `sub` | SUBINIT | | FUNCNAME | FUNCCALL (мёртвый) |
| `function` | FUNCINIT | | MODULEMETHOD | MODULEMETHODCALL |
| `for` | FORINIT | | MODULEPROPERTY | MODULEPROPERTY |
| `if` | IFINIT | | VARIABLE + next EQU | VARINIT |
| `elseif` | ELSEIFINIT | | VARIABLE + next EQUMATH | VAREQUMATH |
| `while` | WHILEINIT | | VARIABLE + next DOUBLEMATH | VARDOUBLEMATH |
| `goto` | LABELCALL | | VARIABLE + next BRACKETLEFTARRAY | VARARRAYINIT |
| `number` / `number[]` / `string` / `string[]` | NUMBERINIT / NUMBERARRAYINIT / STRINGINIT / STRINGARRAYINIT | | PREPROCESSOR (`#`) | EMPTY |
| `endfor endif endwhile endsub endfunction else private break continue return` | ONEKEYWORD | | пустая строка | EMPTY |

Прочее → `NON` (ошибка 1032 при проверке, `Parsers/LineErrorParser.cs:108-112`).
⚠ `VARIABLE` + любой другой второй токен (например `x [0] += 1` или `x[1]++`) попадает в `NON`/не
распознаётся — см. квирки §11.

## 6. Грамматика операторов BP-уровня (стадии 1-2)

Порядок проверки строк: структура блоков (`Parsers/StructErrorParser.cs`) → баланс скобок
(`Parsers/BracketErrorParser.cs:19-57`) → вызовы/функции (`Utils/Interpreter.cs:28-104`) →
переменные и операторы (`Parsers/VariableErrorParser.cs`, `Parsers/LineErrorParser.cs`).

### 6.1 Структурные блоки (StructErrorParser)

| Правило | Ссылка |
|---|---|
| `else endif endfor endwhile endsub endfunction` — строка из ровно 1 слова | `Parsers/StructErrorParser.cs:41-48` |
| `goto NAME` — ровно 2 слова, в имени нет `:` | `Parsers/StructErrorParser.cs:50-62` |
| `if`/`for`/`while` кладут в стек ожидание `endif`/`endfor`/`endwhile`; стеки отдельные для main / sub / function | `Parsers/StructErrorParser.cs:63-110` |
| вложенный `sub` → ошибка; `sub` внутри `function` → ошибка; `function` внутри `sub` → ошибка; повторный `function` → ошибка | `Parsers/StructErrorParser.cs:309-382` |
| незакрытые `sub`/`function`/блок в конце файла — ошибки | `Parsers/StructErrorParser.cs:458-495` |
| метка `name:` — единственное слово в строке (COUNT=1) | `Parsers/StructErrorParser.cs:410-415` |

### 6.2 Директивы файлов

| Оператор | Формат | Ограничения | Ссылка |
|---|---|---|---|
| `folder` | `folder "prjs"\|"sd" "ИмяПроекта"` | ровно 3 слова, оба STRING; имя проекта ≤32 символов, `[A-Za-z][0-9a-zA-Z_]*`; только в `.bp` (в .bpi запрещён) | `Parsers/FolderErrorParser.cs:24-70`, `Parsers/IncludeErrorParser.cs:175-180` |
| `include` | `include "путь/имя"` | ровно 2 слова, второй — STRING; к файлу добавляется `.bpi`; вложенный `include` в .bpi запрещён; пути: `Clev3r://`/`Clever://` → библиотека `Lib/Includes/`, `..` — подъём, `/` и `\` эквивалентны | `Parsers/IncludeErrorParser.cs:19-56,80-154,169-174` |
| `import` | `import "путь/имя"` | аналогично, `.bpm` (модули); разрешён в .bpi | `Parsers/ImportErrorParser.cs` (см. док препроцессора/линковки) |
| `#region/#endregion` | любые | на стадии 1-2 → EMPTY (игнорируются) | `Utils/LineBuilder.cs:413-416` |

Пример: `folder "prjs" "test123"` (`/home/ssssq/Windows/Program1.bp:1`).

### 6.3 Процедуры и функции

| Конструкция | Формат | Правила | Ссылка |
|---|---|---|---|
| SUB | `Sub Имя` … `EndSub` | 2-е слово — SUBNAME; имя уникально (сравнение в lowercase, с учётом файла); в модулях `.bpm` SUB запрещён | `Parsers/StructErrorParser.cs:309-345`, `Parsers/ModuleErrorParser.cs:32-35` |
| FUNCTION | `Function Имя ( [in\|out Тип Имя [, in\|out Тип Имя]*] )` … `EndFunction` | конечный автомат по словам: состояние 0 — ждём `in`/`out`; 1 — ждём тип; 2 — ждём имя; 3 — ждём `,` или `)`. Типы: `number`→NUMBER, `number[]`→NUMBER_ARRAY, `string`→STRING, `string[]`→STRING_ARRAY. Имя параметра: VARIABLE, не может начинаться с `gv_`; уникально в функции. `()` (пустые) допустимы. `)` обязана быть последним словом | `Parsers/FunctionsInitErrorParser.cs:17-384` |
| вызов процедуры | `Имя ( [арг [, арг]*] )` или `Имя()` | имя из Subs, иначе из Functions (тогда вызов функции), иначе ошибка; число аргументов = числу параметров | `Utils/Interpreter.cs:654-754,200-343` |
| вызов функции | `Имя ( [арг [, арг]*] )` | разворачивается: для каждого `in`-параметра — присваивание `param = арг` перед вызовом, для каждого `out` — `арг = param` после; затем `Имя()` | `Utils/Interpreter.cs:200-343` |
| `return` | строка из 1 слова `return` | только внутри Sub/Function; разворачивается в `goto return_N` + метка `return_N:` перед `EndSub` | `Parsers/LineErrorParser.cs:328-343,205-271` |

Квирки FUNCTION: запятая в состоянии 2 (после типа без имени) **молча пропускается** — параметр
теряется без ошибки (`Parsers/FunctionsInitErrorParser.cs:335-338`) **(проверено по коду)**.
Аргументы вызова делятся по запятым верхнего уровня скобок (`Utils/Interpreter.cs:489-536`);
`out`-аргумент обязан быть переменной или элементом массива, иначе ошибка 1405
(`Utils/Interpreter.cs:260-317`).
Примеры: `tests/corpus/Functions/Test1.bp:4`, `/home/ssssq/Windows/Program1.bp:11`
(`Function map_data(in number n, out number data)`), `tests/corpus/Functions/Test2.bp:1` (вызов `Math (10, 20, c)`).

### 6.4 Переменные и присваивания

| LineType | Формат | Правила | Развёртка | Ссылка |
|---|---|---|---|---|
| VARINIT | `x = выражение` | тип определяется первым присваиванием (NUMBER/STRING); смешение типов в одном присваивании — ошибка, кроме конкатенации `+` (строка+число → STRING); чтение до инициализации — ошибка 1405 | без изменений (тип уже выведен) | `Parsers/VariableErrorParser.cs:60-673` |
| VARDOUBLEMATH | `x++` / `x--` | ровно 2 слова; только NUMBER-переменная | `x = x + 1` / `x = x - 1` | `Parsers/VariableErrorParser.cs:702-770` |
| VAREQUMATH | `x += e`, `-=`, `*=`, `/=` | `x` — NUMBER/STRING (тип проверен) | `x = x OP e` (остаток строки переносится) | `Parsers/VariableErrorParser.cs:806-875` |
| VARARRAYINIT | `x [ i ] = e` | `i` — числовое выражение (парсер индекса `Parsers/ArrayIndexErrorParser.cs`); если `x` уже NUMBER/STRING (не массив) — ошибка; тип массива выводится из правой части | без изменений | `Parsers/VariableErrorParser.cs:772-805` |

Модель «выражения» на BP-уровне — **последовательная валидация, а не приоритетный парсер**:
чередование «операнд оператор операнд», операнды: NUMBER, STRING, VARIABLE (+`[i]`), METHOD
(встроенный вызов, разбирается `MethodErrorParser`), скобки пропускаются без проверки вложенности
(`Parsers/VariableErrorParser.cs:88-640`). Приоритеты вычисляет только стадия 3 (§8).
Строковая конкатенация — только через `+`; `-` со строками — ошибка
(`Parsers/VariableErrorParser.cs:617-623`).

`@`-префикс — доступ к **глобальной** переменной из FUNCTION: при линковке
`@name` → `gv_name`, имя без `@` внутри `Function … EndFunction` → `lv_name_N`
(N — номер функции), в MAIN всё → `gv_*`; метки: main → `gl_*`, в функции → `ll_*_N`;
свойства модулей → `pr_*` (`Utils/Linker.cs:448-520`). В модулях `.bpm` `@` запрещён
(`Utils/Linker.cs:566-573`). Пример: `@d1_min` в `/home/ssssq/Windows/Program1.bp:13`
→ `gv_d1_min` в `~Program1.bp`.

### 6.5 Условия и циклы

| Конструкция | Формат | Правила | Ссылка |
|---|---|---|---|
| IF | `If усл Then` … [`ElseIf усл Then` …] [`Else` …] `EndIf` | последнее слово — `then`; слов ≥3; условие валидируется `LogicErrorParser` до слова `then`/`and`/`or` | `Parsers/LineErrorParser.cs:22-43` |
| WHILE | `While усл` … `EndWhile` | слов ≥2; условие — все слова после `while` | `Parsers/LineErrorParser.cs:44-60` |
| FOR | `For v = нач TO стоп [STEP шаг]` … `EndFor` | слов ≥6; ищется слово `to` (последнее вхождение перед `step`); `v` — NUMBER; `нач` — слова между `=` и `to`; `шаг` — после `step`, может начинаться с `-` | `Parsers/ForLineErrorParser.cs:17-89` |
| BREAK/CONTINUE | строка из 1 слова | только внутри `For…EndFor`/`While…EndWhile`; разворачиваются в `goto break_N`/`continue_N` + метки перед `EndFor`/`EndWhile` | `Parsers/LineErrorParser.cs:273-354,205-271` |

Условие — цепочка сравнений через `and`/`or` (`Parsers/LogicErrorParser.cs:435-461`):
сравнения `= < > <= >= <>` (EQU/BOOLOPERATOR, `LogicErrorParser.cs:29-49`), операнды NUMBER/STRING/
VARIABLE/METHOD; смешение NUMBER и STRING в одном сравнении — ошибка 1407; оба операнда сравнения
должны быть одного типа **(проверено по коду; НЕКВАЛИФИЦИРОВАННОЕ «строковое сравнение»
регистрозависимо — см. §8.4)**. Скобки в условиях допустимы и пропускаются
(`LogicErrorParser.cs:431-434`). Логические значения — строковые литералы: `While "True"`
(`/home/ssssq/Windows/Program1.bp:21`), `While "true"` (`tests/corpus/Other/Threads.bp:46`).
Также `tests/corpus/Other/Threads.bp:28-30` (`For i=0 to 3` / `Endfor` — регистр и пробелы).

Примеры: `tests/corpus/BreakAndContinue/BreakAndContinueTest.bp` (For+Step, Break, Continue, y++),
`tests/corpus/HiTechnic Sensors/Seeker.bp:7` (`ElseIf direction<>0 Then`),
`tests/corpus/Other/ClickTest.bp:16` (`elseIf` — смешанный регистр).

### 6.6 Вызовы встроенных методов и модулей

| LineType | Формат | Правила | Ссылка |
|---|---|---|---|
| METHODCALL | `объект.метод(арг…)`, `объект.свойство`, `thread.run = ИМЯ` | `объект` из 31 класса (§4); метод: последний токен `)`/`()`; число и типы аргументов — по сигнатуре `DataTemplates/DefaultObjectList.cs` (строгий InputCount, ошибка 1304); свойство как оператор: ровно 1 слово; `thread.run`: ровно 3 слова `thread.run = SUBNAME` | `Parsers/LineErrorParser.cs:61-107`, `Utils/Interpreter.cs:726-752` |
| MODULEMETHODCALL / MODULEPROPERTY | `модуль.метод(…)`, `модуль.свойство` | разворачиваются линкером в вызовы `f_модуль_метод_N` | `Utils/Linker.cs:324-446` |

Медиа-директивы: строки `lcd.bmpfile`, `speaker.play`, `ev3file.openwrite/openappend/openread/
tablelookup` со строковым аргументом переписываются `MediaBuilder.ParseMedia`: к имени файла
добавляется префикс папки — `prjs` → `"{Проект}/Media/"`, `sd` → `"SD_Card/{Проект}/Media/"`
(для `ev3file.*` — `/Files/`), файл регистрируется в `Project.ImageList/SoundList/FileList`
(`Utils/MediaBuilder.cs:14-107,201-296`; вызов из `Parsers/MethodErrorParser.cs:412-422`).
Примеры: `tests/corpus/Other/GraphicsAndSounds.bp:16,19`, `tests/corpus/Other/Media_PRJS_folder.bp:4-6`.

## 7. Литералы и спецсимволы

| Категория | Правило | Ссылка |
|---|---|---|
| Числа | `[0-9]([0-9.])*` — десятичные с необязательной точкой, знак в лексер не входит (унарный минус — часть грамматики); парсинг стадии 3: `double.TryParse(NumberStyles.Float, InvariantCulture)` | `Compiler/Scanner.cs:171-191`, `Compiler/Compiler.cs:1467-1475` |
| Дробные | `2.5`, `0.5`; форма `.5` НЕВЕРНА (лексер требует цифру в начале); форма `5.` парсится как 5.0; `1.2.3` даёт токен NUMBER, но падает на `double.TryParse` («Can not decode number») | `Compiler/Scanner.cs:184`, `Compiler/Compiler.cs:1470-1473` |
| Hex-литералы | **не поддерживаются** ни на одном уровне; hex-строки конвертирует встроенный `byte.h("ff")` | `DataTemplates/DefaultObjectList.cs:44` |
| Строки | `"текст"`, предел 251 символ («Text is longer than 251 letters»); кавычка внутри строки удваивается: `"a""b"` → содержимое `a""b` → `a"b` (правило «дополнительная " продолжает строку») | `Compiler/Compiler.cs:1460-1465`, `Compiler/Scanner.cs:192-221` |
| Незакрытая строка | ошибка `Nonterminated string at: L:C` — обычный Exception, не CompileException | `Compiler/Scanner.cs:196-201` |
| Экранирование на выходе (стадия 3) | символы `<32`, `>127`, `'`, `\` → `\DDD` (3 восьмеричные цифры); код `≤0` или `>255` заменяется на 1 | `Compiler/Compiler.cs:1701-1723` |
| Комментарий | `'` … конец строки (см. §2) | `Utils/LineBuilder.cs:17-31` |
| Логические литералы | строковые: `"True"`/`"true"`/`"TRUE"` — истина (сравнение первых 4 букв в верхнем регистре, §8.4) | `Compiler/Expression.cs:76-88` |

## 8. Стадия 3: Scanner и грамматика Compiler

### 8.1 Scanner: лексемы

`Compiler/Scanner.cs:125-295`. Лексемы читаются посимвольно, `columnnumber` после `GetSym`
указывает **за** конец лексемы. Пробелы/табы пропускаются (`Scanner.cs:166-170`).

| Лексема | Правило | Ссылка |
|---|---|---|
| ID | `[A-Za-z_][A-Za-z0-9_]*`, содержимое → `ToUpperInvariant()` | `Scanner.cs:222-257` |
| KEYWORD | ID, совпадающий с одним из: `AND ELSE ELSEIF ENDFOR ENDIF ENDSUB ENDWHILE FOR GOTO IF OR STEP SUB THEN TO WHILE` (17 слов; **нет** FUNCTION/BREAK/CONTINUE/RETURN) | `Scanner.cs:249-255` |
| NUMBER | `[0-9]([0-9.])*` без знака | `Scanner.cs:171-191` |
| STRING | `"…"`, `""` внутри продолжает строку; содержимое без кавычек | `Scanner.cs:192-221` |
| SPECIAL | любой иной символ — 1 слово; двухсимвольные только `<=`, `>=`, `<>` (проверяются сразу) | `Scanner.cs:258-283` |
| EOL/EOF | конец строки / конца потока | `Scanner.cs:134-150` |
| PRAGMA | строка с колонки 0, начинается с `'PRAGMA ` (см. §2) | `Scanner.cs:151-159` |
| PushBack | стек на 1+ отложенных лексем (look-ahead по первому слову оператора) | `Scanner.cs:289-295` |

### 8.2 Грамматика операторов (Compiler.cs)

```
программа   → { оператор } до EOF
оператор    → PRAGMA | EOL | IF… | WHILE… | FOR… | GOTO… | атомарный_оператор EOL
IF          → IF условие THEN EOL {оператор | ELSEIF усл THEN EOL {оператор} | ELSE EOL {оператор}} ENDIF EOL
WHILE       → WHILE условие EOL {оператор} ENDWHILE EOL
FOR         → FOR id = выр TO выр [STEP выр] EOL {оператор} ENDFOR EOL
GOTO        → GOTO id EOL          ; метка — `id:` (см. атомарный)
атомарный   → id = выр | id [ выр ] = выр | id ( ) | id : | объект . метод (арг…) | объект . свойство = выр
```

| Особенность | Детали | Ссылка |
|---|---|---|
| Переменные | имя → `V<ИМЯ>` (верхний регистр), тип фиксируется первым присваиванием, смена типа — ошибка | `Compiler/Compiler.cs:859-891` |
| FOR-счётчик | всегда Number, создаётся неявно | `Compiler/Compiler.cs:722-732` |
| Направление STEP | константный `step > 0` → тест `<=`; `step < 0` → `>=`; иначе runtime `CALL LE_STEP` | `Compiler/Compiler.cs:744-773` |
| Метки | `id:` → `L<id>:`; `GOTO id` → `JR L<id>`; проверок существования нет (только структурный парс линковки выше) | `Compiler/Compiler.cs:794-809,848-852` |
| Вызов SUB | `Имя()` → возвратный адрес в RETURNSTACK, `JR SUB_<имя>` | `Compiler/Compiler.cs:837-847` |
| Свойства | присваивание свойству разрешено только `thread.run = id` (запуск потока) и `f.start = id` (игнорируется); прочее — «Unknown property to set» | `Compiler/Compiler.cs:950-987` |
| Методы | аргументы по сигнатуре библиотеки; `CALL <Obj.Method>` либо inline-подстановка | `Compiler/Compiler.cs:988-1112` |

### 8.3 F.* — legacy-механика EV3-Basic (стадия 3, недостижима из BP-фронтенда — гипотеза,
подтверждена отсутствием `f.` в `DataTemplates/DefaultObjectList.cs`)

| Конструкция | Смысл | Ссылка |
|---|---|---|
| `F.Start <sub>` + следующая строка `F.Function("ИМЯ","F:S…" )` | объявление функции: дескриптор — по букве на параметр (`F` число, `S` строка), опционально `имя:значение` — значение по умолчанию (число или строка) | `Compiler/Compiler.cs:1872-1891`, `Compiler/FunctionDefinition.cs:209-239` |
| `F.GET("имя")` | чтение параметра в выражении | `Compiler/Compiler.cs:1556-1569` |
| `F.SET("имя", выр)` | запись параметра | `Compiler/Compiler.cs:1005-1020` |
| `F.CALL("имя", арг…)` / `F.CALL…` (любой префикс) | вызов функции; в выражении возвращает значение | `Compiler/Compiler.cs:1053-1079,1571-1595` |
| `F.RETURN` / `F.RETURNNUMBER(выр)` / `F.RETURNTEXT(выр)` | возврат (тип фиксируется первым `F.RETURN*` в sub) | `Compiler/Compiler.cs:1021-1051,1900-1913` |

Переменные функций: параметры `F<имя>.<параметр>` / `S<имя>.<параметр>`, возвращаемое значение
`F<имя>.` / `S<имя>.`, темпы `F<имя>.<n>` (`Compiler/FunctionDefinition.cs:96-151`).

### 8.4 Грамматика выражений (стадия 3) и приоритеты

Цепочка рекурсивного спуска (`Compiler/Compiler.cs:1144-1544`) — приоритеты от низшего к высшему,
все бинарные операции **лево-ассоциативны** (циклы `for(;;)` слева направо):

| Уровень | Операции | Типы | Ссылка |
|---|---|---|---|
| 1 OR | `or` | только Text-условия (bool как string) | `Compiler/Compiler.cs:1149-1169` |
| 2 AND | `and` | только Text | `Compiler/Compiler.cs:1171-1191` |
| 3 Сравнение | `= <> < > <= >=` | `=`/`<>` — одинаковые типы (Number или Text); `< > <= >=` — только Number; результат — Text | `Compiler/Compiler.cs:1193-1282` |
| 4 Сложение | `+ -` | `+`: Text+Text → конкатенация (`CALL TEXT.APPEND`); Number+Text/Text+Number → число форматируется `STRINGS VALUE_FORMATTED '%g' 99` и конкатенация; Number+Number → `ADDF`. `-` — только Number (`SUBF`) | `Compiler/Compiler.cs:1284-1360` |
| 5 Умножение | `* /` | только Number: `MULF`; `/` → `DIVF` | `Compiler/Compiler.cs:1362-1422` |
| 6 Унарный минус | `-выр` | рекурсивно, только Number; `MATH NEGATE`; унарного `+` нет | `Compiler/Compiler.cs:1424-1446` |
| 7 Атом | `(выр)`, STRING, NUMBER, `id`, `id[выр]`, `obj.метод(арг…)`, `obj.свойство` | | `Compiler/Compiler.cs:1448-1633` |

Дополнительно:
- **Деление вещественное** (DIVF); целочисленного деления и остатка в языке нет — используется
  `math.floor` (`/home/ssssq/Windows/Program1.bp:13`). При `NODIVISIONCHECK` — чистый `DIVF`,
  иначе генерируется защитный код: `DATAF tmpf / DATA8 flag / DIVF / CP_EQF 0.0 :1 flag / SELECTF flag 0.0 tmpf`
  → деление на 0 даёт **0.0** (`Compiler/Compiler.cs:1391-1412`); константное деление `a/0` тоже даёт 0.0
  (`Compiler/Compiler.cs:1391-1396`). `PRAGMA NOBOUNDSCHECK` отключает проверки границ массивов
  (чтение с индексом <0 даёт 0.0, `Compiler/Expression.cs:407-453`).
- **Константная свёртка** для `+ - * /` над двумя литералами (`Compiler/Compiler.cs:1317-1323,1344-1351,1375-1396`).
- **Условие IF/WHILE обязано иметь тип Text**: «Need a text as a boolean value here»
  (`Compiler/Compiler.cs:637,698`); значение истинности — сравнение с `'TRUE'`: значение
  приводится к верхнему регистру **первые 4 символа** (`AND8888_32 … -538976289` = 0xDFDFDFDF)
  и сравнивается с `'TRUE'` (`Compiler/Expression.cs:76-88`) → `"true"`, `"True"`, `"TRUE"` истинны;
  строки длиннее 4 символов сравниваются с учётом регистра остатка **(гипотеза по семантике `STRINGS COMPARE` EV3)**.
- **Сравнение строк** `=`/`<>` — `CALL EQ_STRING`/`CALL NE_STRING`, регистрозависимое
  (`Compiler/Compiler.cs:1213-1214,1235-1236`); массивы сравнивать нельзя.
- **Приведение типов**: неявное только Number→Text (аргументы методов и `+`); Text→Number нет —
  только встроенный `ev3file.converttonumber` (`DataTemplates/DefaultObjectList.cs:67`).
  Аргументы типов ANY принимают и то и другое (`DataTemplates/DefaultSignature.cs:15-20`).
- Литералы: NUMBER → `NumberExpression(double)`, при выводе всегда с `.0` для целых
  (`Compiler/Expression.cs:111-122`); STRING предел 251 (§7).

## 9. Позиции для диагностик

| Стадия | Что хранится | Формат | Ссылка |
|---|---|---|---|
| 1-2 (BP) | `Errore{LineNumber, FileName, Code, Message}`; **колонок нет** | `file: {FileName} line: {N} | code: {C} ===> {текст ошибки} {Message}` | `DataTemplates/Errore.cs:12-23` |
| 1-2 | номер строки — внутри **своего** файла (Program.Lines / include.Lines), 1-based; FileName = полный путь | | `DataTemplates/Program.cs:32-33`, `Parsers/IncludeErrorParser.cs:163-167` |
| 1-2 | `Word.Number` — 1-based номер слова в строке (после GetWords) | | `DataTemplates/Line.cs:34` |
| 3 (Compiler) | `linenumber`, `columnnumber` — 0-based внутренне; в сообщении +1 | `{message} at: L:C`, L:C — 1-based | `Compiler/Scanner.cs:85-89` |
| 3 | `Unexpected {SymType} {content}` / `Expected {X}` | | `Compiler/Scanner.cs:99-123` |
| 3 | CompileException → строка в списке ошибок | | `Compiler/CompileException.cs:5-9`, `Compiler/Compiler.cs:226-230` |

⚠ Квирк стадии 3: при ошибке на EOL лексер уже переключился на следующую строку
(`Scanner.cs:142-150` увеличивает `linenumber`), поэтому позиция в сообщении указывает
**на следующую строку, колонку 1**. Для Mojo-порта: диагностики стадии 3 считаются по строкам
**развёрнутого** `~Name.bp`, не по исходным файлам.

## 10. Развёртка BP → компиляторный вид (что должно уметь повторить Mojo)

Последовательность шагов `Utils/Interpreter.cs:17-123` (после Preprocessor):

1. `ParseAllCalls` — собрать имена вызовов; отсутствие sub/function — ошибки 1606/1806
   (`Utils/Interpreter.cs:654-754`).
2. `ParseFuncInitLine` — `Function …` → `Sub Имя`, `EndFunction` → `EndSub`
   (`Utils/Interpreter.cs:125-174`).
3. `ParseCalls` — вызовы функций/методов модулей → присваивания `in`-параметров, вызов `Имя()`,
   присваивания `out`-результатов (`Utils/Interpreter.cs:200-343`).
4. Инициализация всех переменных нулями/`""`/`[0]=0` в начале MAIN
   (`Utils/Interpreter.cs:448-652`).
5. `break/continue/return` → `goto break_N/continue_N/return_N` + метки
   (`Parsers/LineErrorParser.cs:205-271`).
6. Переименование: `gv_/lv_/gl_/ll_/pr_` и `имя_N` по числу параметров (`Utils/Linker.cs:324-520`).
7. Удаление неиспользуемых SUB (`Utils/Interpreter.cs:756-788`).
8. Повторная валидация: `VariableErrorParser.Start`, `LineErrorParser.Start`
   (`Utils/Interpreter.cs:91-98`).

Эталон: `/home/ssssq/Windows/Program1.bp` → `/home/ssssq/Windows/~Program1/~Program1.bp` →
`Program1.lmsb` (5505 б) → `Program1.rbf` (1015 б).

## 11. Квирки и опасности при портировании

1. **Апостроф внутри строки** обрезает строку как комментарий (`Utils/LineBuilder.cs:17-31`);
   в корпусе не встречается, но валидные программы пользователя ломаются **(гипотеза о частоте)**.
2. `--` склеивается только если пара — последние слова строки (`Utils/LineBuilder.cs:209-217`):
   `x = y - -1` — это два минуса (корректно), а `x = y - -1 ` (с хвостом) — тоже, но
   `--1` в середине выражения не соберётся в DOUBLEMATH — просто два оператора `-`.
3. `FOR`: проверка «строка содержит `to`» ищет подстроку во **всей строке**
   (`Parsers/ForLineErrorParser.cs:19-23`), а затем ищется слово `to` — расхождение даёт
   пропущенные ошибки; проверка `Words[1].Token != VARIABLE && Words[2].Token != EQU`
   срабатывает только когда **оба** условия неверны (баг `&&` вместо `||`,
   `Parsers/ForLineErrorParser.cs:31-35`) **(проверено по коду)**.
4. `!=`, `&&`, `||`, `not`, `%`, `^`, `;`, `{`, `}` не являются операторами: после склейки
   получают токен NON → `LineType.NON` → ошибка 1032. `==` тоже не поддержан (EQU — одиночный `=`;
   `==` склеивается, но TokenBuilder не знает такого слова → NON).
5. `x[1]++` / `x[1] += 2` не поддержаны: после индекса ожидается ровно `=`
   (`Parsers/VariableErrorParser.cs:797-805`).
6. Строка, начинающаяся с `number`/`string` (типизированная декларация), в MAIN проходит
   стадии 1-2 без проверки и падает на стадии 3 (`Unexpected ID NUMBER`) **(гипотеза: в main не
   валидна; в .bpm — валидна как декларация свойства)**.
7. Идентификаторы нечувствительны к регистру дважды: `Word.Text` → UPPER (§3), ключи словарей
   после линковки → LOWER (`Utils/Linker.cs:490-500`). В Mojo надо выбрать один канон.
8. `For i=0 to 3` / `Endfor` / `elseIf` — регистр произвольный везде
   (`tests/corpus/Other/Threads.bp:28`, `tests/corpus/Other/ClickTest.bp:16`).
9. Канонический текст `NewLine` переставляет пробелы: `LCD.Clear()` → `LCD.Clear ()`
   (сравни `tests/corpus/Functions/Test1.bp:5` и `tests/corpus/Functions/~Test1/~Test1.bp:14`),
   вызов функции → `f_writetoscreen_5 ()` (`~Test1.bp:11`) — байт-в-байт воспроизведение
   выходного `~.bp` требует того же правила `string.Join(" ", …)`.
10. `thread.run = ИМЯ` распознаётся эвристикой по индексам в **исходной** строке
    (`Utils/TokenBuilder.cs:153-163`) — слово после `=` получает SUBNAME только если
    `i1 < i2 < i3` (позиции `thread.run`, `=`, слова). Имя потока — SUBNAME, обращение к SUB.
11. Модули: `.bpm` не может содержать `Sub` (2007), `include` (2005), `folder` (2006), `@`-глобалы
    (2009); только `Function` и типизированные свойства (`Parsers/ModuleErrorParser.cs:23-60`,
    `Utils/Linker.cs:556-600`).
12. Имена функций различаются по числу параметров: `f_writetoscreen_5` = имя + `_` + count
    (`Utils/Linker.cs:380-386,455`); перегрузка по числу параметров допустима.
13. Пустая функция `()` допустима и на FUNCTION (`FunctionsInitErrorParser.cs:56-60`), и на вызове
    (`DOUBLEBRACKET`).
14. Стадия 3 не проверяет существование меток для `GOTO` — ошибки «нет такой метки» не будет,
    провалится только ассемблер **(гипотеза)**.
15. Возвращаемое значение функции в BP — только через `out`-параметры; `return` — просто выход
    из SUB. Никаких `Function = значение`.
16. Отрицательные индексы/границы массивов: чтение за границей при выключенной проверке даёт 0.0,
    при включённой — runtime-проверка `ARRAYSTORE_FLOAT/ARRAYGET_FLOAT`
    (`Compiler/Compiler.cs:918-948`, `Compiler/Expression.cs:407-453`).

## 12. Мини-шпаргалка соответствия (для Mojo-реализации)

| Задача в Mojo | Откуда брать точные данные |
|---|---|
| Лексер стадий 1-2 | §3-§5 (`Utils/LineBuilder.cs`, `Utils/TokenBuilder.cs`) |
| Ключевые слова стадий 1-2 | `Utils/TokenBuilder.cs:51` (32 слова) |
| Ключевые слова стадии 3 | `Compiler/Scanner.cs:249-252` (17 слов) |
| Приоритеты операторов | §8.4 (`Compiler/Compiler.cs:1144-1446`) |
| Развёртка операторов | §6.4, §10 (`Parsers/VariableErrorParser.cs`, `Parsers/LineErrorParser.cs:205-271`) |
| Прагмы | `Compiler/Compiler.cs:578-601` |
| Медиа-пути | `Utils/MediaBuilder.cs:201-340` |
| Сигнатуры встроенных объектов | `DataTemplates/DefaultObjectList.cs` (отдельный док по builtins) |
| Развёрнутый эталон | `/home/ssssq/Windows/~Program1/`, `tests/corpus/Functions/~Test1/`, `tests/corpus/Other/~Battery/` |
