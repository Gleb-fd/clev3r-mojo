# 05. Диагностики компилятора Clev3r (каталог сообщений, позиции, поведение)

Все ссылки вида `File.cs:N` — на репозиторий `/home/ssssq/Projects/clev3r_linux/Clev3r-1`
(сокращения путей: `Int/` = `Interpreter/`, `P/` = `Interpreter/Parsers/`, `DT/` = `Interpreter/DataTemplates/`).
Пометки: **(проверено)** — выведено из кода/корпуса; **(гипотеза)** — вывод, не подтверждённый запуском.

## 0. Главное для порта и LSP (выводы спереди)

1. Все диагностики стадий 1–2 — **только ошибки, предупреждений не существует** (проверено по
   всем `new Errore` — 149 мест, см. §5; grep `warning` по `Int/` — пусто).
2. Позиция диагностики = **пара (FileName, 1-based номер строки)**. Колонок/офсетов/длин нет:
   `DT/Errore.cs:14-17` (только `LineNumber`, `FileName`, `Code`, `Message`).
3. Соответствие исходным строкам **сохраняется после препроцессинга, но пофайлово**: каждый
   объект `Line` несёт свой `Number` (нумерация внутри своего файла) и `FileName`
   (`DT/Program.cs:32-33`, `P/IncludeErrorParser.cs:163-165`, `P/ImportErrorParser.cs:159-161`).
   Единой сквозной нумерации объединённого файла нет. Исключения — §2.3.
4. Соответствие строкам исходника **теряется на фазе компилятора** (стадия 3 получает
   развёрнутый текст без карты строк — `Builder.cs:106-122`, `Builder.cs:486-506`); у ассемблера
   позиций нет вообще (§2.5).
5. **Остановка на первой ошибке**: каждый парсер после `Data.Errors.Add(...)` немедленно
   `return`, и вся цепочка фазы проверяет `Data.Errors.Count > 0` после каждого шага.
   Максимум ошибок за прогон — 1 (единственное исключение — конец `StructErrorParser.Start`,
   до 3 ошибок, §4.3). Лимита «N ошибок» нет — лимит = 1 по построению.
6. Из ~170 зарегистрированных кодов `ErrorsCodeList` **26 кодов — мёртвые** (никогда не
   возбуждаются живым кодом), §6. Ещё 3 (1807, 1820, 1821) возбуждаются только из
   закомментированного кода. Для порта их можно не реализовывать, но словарь текстов стоит
   сохранить целиком (нумерация должна совпадать с C#-словарём).
7. В UA-словаре **пропущен код 1912** (`DT/ErrorsCodeList.cs:377-380` — после 1911 сразу 1913):
   `GetError(1912)` вернёт пустую строку (§3.2).
8. `Resources.resx` к ошибкам отношения не имеет — это только шаблоны опкодов/байткода для
   ассемблера (`Int/Resources.resx:121-226`). Все тексты ошибок зашиты в
   `DT/ErrorsCodeList.cs` (три словаря SetRU/SetUA/SetEN, по 170 записей).

## 1. Устройство системы диагностик

### 1.1 Структура ошибки

`DT/Errore.cs:5-23` — struct `Errore`:

| Поле | Тип | Смысл |
|---|---|---|
| `LineNumber` | int | 1-based номер строки **внутри своего файла** |
| `FileName` | string | путь/имя файла (формат непоследователен, §2.2) |
| `Code` | int | числовой код из словаря `ErrorsCodeList.Errors` |
| `Message` | string | свободная подстановка-«хвост» (имя, слово, путь), может быть `""` |

Хранилище: статический `Data.Errors : List<Errore>` (`CommonData/Data.cs:13`), создаётся в
`Data.Install` (`Data.cs:14-34`), одновременно выбирается язык словаря по `Language.Type`.

### 1.2 Локализация

`DT/ErrorsCodeList.cs:9` — `Dictionary<int,string> Errors`; три загрузчика:
`SetRU()` (`:11-214`), `SetUA()` (`:216-418`), `SetEN()` (`:420-622`). Выбор:
- CLI `Builder(language)` → `Language.Type` (`Builder.cs:40-54`) → `Data.Install` (`Data.cs:19-33`), по умолчанию EN;
- IDE-путь `StartInterpreter(..., language, ...)` → `SetLanguage` (`Builder.cs:237-256`) вызывает
  `SetRU/SetUA/SetEN` напрямую; неизвестный язык печатает
  `Invalid language. Should be "ru", or "ua", or "en".` в консоль и прерывает работу (`Builder.cs:251-252`).

`GetError(code)` для отсутствующего кода возвращает `""` (`ErrorsCodeList.cs:624-634`).

### 1.3 Кем возбуждаются

| Фаза | Класс | Коды |
|---|---|---|
| Препроцессор, 1-й проход | `BracketErrorParser`, `IncludeErrorParser`, `ImportErrorParser`, `FolderErrorParser` | 1001–1002, 1101–1106, 1201–1208, 2001–2008, 2011–2015, 1026–1028 |
| Препроцессор, структуры/имена | `StructErrorParser.Start/ParseNames` | 1003–1014, 1015–1021, 1024–1025, 1029–1031, 1032, 1601–1603, 1607, 1801/1803/1805/1809 |
| Препроцессор, линкер | `Linker` | 2008–2009, 2017–2018, 2020 |
| Интерпретатор (2-й проход) | `Utils/Interpreter`, `FunctionsInitErrorParser` | 1405, 1414, 1606, 1806, 1801–1822 |
| Интерпретатор, выражения | `VariableErrorParser`, `MethodErrorParser`, `LogicErrorParser`, `ForLineErrorParser`, `ArrayIndexErrorParser` | 1301–1314, 1401–1428, 1901–1906 |
| Интерпретатор, строки | `LineErrorParser` | 1032, 1034, 1907–1918 |
| Компилятор | `CompileException` (Scanner/Expression/Compiler) | свои английские тексты, §5.13 |
| Ассемблер | `AssemblerException` | свои английские тексты, §5.14 |

Пайплайн вызовов: `Preprocessor.Start` (`Utils/Preprocessor.cs:15-46`) → 1-й проход
`FirstFindFiles` (`:48-81`), `ParseStruct` (`:105-126`), `ParseNames` (`:128-147`), `Linker.Start`
(`Utils/Linker.cs:17-78`); затем `Utils/Interpreter.Start` (`Utils/Interpreter.cs:17-123`).

## 2. Позиция диагностики

### 2.1 Номер строки и файл

`Line.Number` назначается в момент создания Line и больше не меняется:

| Источник Line | Number | FileName |
|---|---|---|
| Главный `.bp` | `i+1`, i — индекс строки файла (`DT/Program.cs:33`) | полный путь `Path+Name+Ext` (`DT/Program.cs:32`) |
| `.bpi` (include) | `i+1`, нумерация с 1 внутри .bpi (`P/IncludeErrorParser.cs:163`) | **полный путь** `.bpi` (`IncludeErrorParser.cs:165`) |
| `.bpm` (import) | `i+1`, нумерация с 1 внутри .bpm (`P/ImportErrorParser.cs:159`) | **полный путь** `.bpm` (`ImportErrorParser.cs:161`) |
| Сгенерированные OutLines | наследуются от родителя, проставляются явно (`Utils/Interpreter.cs:241,257,291,316`) | то же |
| Метки break/continue | **Number=0, FileName=""** — конструктор без присвоения (`P/LineErrorParser.cs:253,268`, сброс в `DT/Line.cs:37-38`) | |

`Errore` не содержит колонок, start/end, офсетов. `Word` хранит только `Text`, `OriginText`,
`Token`, `Length`, порядковый `Number` **внутри строки** (`DT/Word.cs:12-22`) — не смещение в
исходной строке. Восстановить столбец в редакторе можно только перетокенизировав `OldLine`
(`DT/Line.cs:19`, сохранённая исходная строка).

### 2.2 ВАЖНЫЙ вывод: сохраняется ли соответствие строкам после препроцессинга

**Сохраняется, но пофайлово, и с тремя искажениями (проверено):**

1. Включения не «склеиваются» в один файл с перенумерацией: `Linker.AddIncludesToMain`
   вставляет Line-объекты .bpi на место include-строки, не трогая их `Number/FileName`
   (`Utils/Linker.cs:283-308`). Ошибка в строке 3 файла `Include1.bpi` так и репортится:
   `FileName=.../Includes/Include1.bpi, Number=3` — подтверждено корпусом
   (`tests/golden_report.txt:12`, пример в §3.3). LSP-карта «(файл, строка) → позиция» строится
   напрямую, **если** имя файла нормализовать (п.2).
2. Формат `FileName` непоследователен: main/include/import — полный путь, но часть ошибок в
   .bpm ставится с коротким именем `имя.bpm`: 2005/2006/2007/1026/1027/2008/2011–2015/1028
   (`P/ImportErrorParser.cs:166,171,178,191,201,220,227,233,239,245,257,272`), тогда как
   bracket-ошибки тех же строк — с полным путём (`ImportErrorParser.cs:263`). Для LSP нужно
   сопоставление по basename.
3. Ошибки незакрытых структур 1003/1005/1007 ставятся со строкой **открывающей** структуры
   (`tmpTuple.Item1`), но с файлом **текущей** закрывающей строки (`line.FileName`) —
   `P/StructErrorParser.cs:121-125,138-147,159-167` и аналоги. При расхождении файлов
   (main/include) пара (строка, файл) может указывать на несуществующее место
   **(проверено по коду; практический кейс не воспроизводил — гипотеза о частоте)**.

### 2.3 Позиции, генерируемые трансформациями

- `break/continue/return` разворачиваются в `Goto label_N` + метки; строки-метки создаются
  без `Number/FileName` (`LineErrorParser.cs:230-268`). Ошибка в такой строке имела бы
  `line: 0, file: ` — в текущем коде метки не проверяются, риск только у наследников
  **(гипотеза)**.
- Инициализации параметров функций-вызовов (`param_i = ...`) наследуют `Number/FileName`
  строки вызова (`Interpreter.cs:241,291,316`) — ошибки в них указывают на строку вызова.
- Ошибки, где `Message = "( OldLine )"` (Interpreter.cs:264,313), указывают на строку вызова,
  хотя дефект — в конкретном параметре.

### 2.4 Привязка к фазам при ошибках «не в том файле»

`StructErrorParser` для include-файлов вызывается отдельно по каждому файлу
(`Preprocessor.cs:105-126`), модули исключены из структурной проверки (код закомментирован,
`Preprocessor.cs:118-125`) — их структуры проверяет `ImportErrorParser/ModuleErrorParser`.

### 2.5 Компилятор и ассемблер

- Компилятор читает **развёрнутый** текст (`Builder.GetOutFile`, `Builder.cs:486-506` →
  `WriteToStream` → `Compiler.Start`, `Builder.cs:106-122`). `Scanner` считает строки/столбцы
  заново (`Compiler/Scanner.cs:35-36,54-64`), сообщение формируется как
  `message + " at: " + (linenumber+1) + ":" + (columnnumber+1)` (`Scanner.cs:85-89`).
  **Соответствие строкам исходного .bp утрачено**: развёрнутый файл содержит добавленные
  строки (инициализация переменных, присваивания параметров, goto-метки, переименованные
  имена `f_*_N`, `gv_*`, `lv_*_N`). Для LSP диагностики фазы компилятора к исходнику
  привязать нельзя — только к развёрнутому файлу `~Name/~Name.bp`.
- Ассемблер работает с `.lmsb`-текстом; `AssemblerException` несёт только текст, позиций нет
  (`Assembler/Assembler.cs:194-750` — все `throw` без координат).

## 3. Формирование текста сообщения

### 3.1 Формат вывода

`DT/Errore.cs:19-22` — единственная точка форматирования:

```
"file: " + FileName + " line: " + LineNumber + " | code: " + Code + " ===> " + GetError(Code) + " " + Message
```

Вывод: `Errors: N` + по строке на ошибку (`Utils/ErrorShow.cs:32-43`); в IDE-пути каждая
строка складывается в `errors: List<string>` (`Builder.cs:172-191`).

### 3.2 Подстановки (Message)

| Шаблон | Коды | Место |
|---|---|---|
| `( слово )` — токен, имя переменной (в нижнем/UPPER регистре) | 1034, 1427, 1810, 1812, 1813, 1822, 1032, 1801, 1804, 1805, 2014 | `P/LineErrorParser.cs:72,85,93,98,104`, `P/ArrayIndexErrorParser.cs:73,96,102,147`, `P/FunctionsInitErrorParser.cs:34,240,276,332,341,350,358,364`, `P/ModuleErrorParser.cs:156,162,168,339,386,395,402,473,513,553` |
| `( метод )` — имя метода | 1302, 1303, 1304, 1307, 1301 | `P/MethodErrorParser.cs:42,393,401,407,496,508,514,521` |
| `( OriginText )` — слово в исходном регистре | 1405, 1406, 1412, 1413, 1822, 1806 | `P/VariableErrorParser.cs:680,685,721,739`, `P/ForLineErrorParser.cs:159`, `P/FunctionsInitErrorParser.cs:43,251,256,266,286` |
| `( вся строка )` — `line.NewLine`/`line.OldLine` | 1034, 1405, 1801 | `P/LineErrorParser.cs:85,93,98,104`, `Utils/Interpreter.cs:264,313`, `P/FunctionsInitErrorParser.cs:28` |
| `( имя (N) )` — имя функции и число параметров | 1809 | `P/ModuleErrorParser.cs:125` |
| ` OriginText` — пробел + слово (без скобок) | 1810, 1607, 2017, 2018, 1024, 1025 | `P/FunctionsInitErrorParser.cs:276,296`, `P/StructErrorParser.cs:800,810,846,856,872,877`, `Utils/Linker.cs:883,901,933,951` |
| ` имя` метки **с контекстом через `*`** (артефакт: `метка*функция_N`) | 1024, 1025 | `P/StructErrorParser.cs:862,872,877` |
| `имя` — чистое имя | 1024/1025 в переходах, 1035, 1036, 2020 | `P/StructErrorParser.cs:899,904`, `Utils/Linker.cs:855` |
| `путь` — вычисленный полный путь + расширение | 1101 (`.bpi`), 2001 (`.bpm`) | `P/IncludeErrorParser.cs:45`, `P/ImportErrorParser.cs:75` |
| `"2"` — строковый мусор-артефакт отладки | 1426 | `P/LogicErrorParser.cs:115` |
| `""` — без подстановки | большинство (структуры, циклы, break/continue) | повсеместно |

Регистр подстановок непоследователен: имена переменных/меток при токенизации переводятся в
UPPER (`Utils/LineBuilder.cs:251-255`), поэтому часть сообщений показывает `FOO` (подстановки
`Text`: 1425, 1423, 1906 — `P/ArrayIndexErrorParser.cs:96,102`, `P/LogicErrorParser.cs:272`),
часть — `Foo` (подстановки `OriginText`: 1405, 1406 — `P/VariableErrorParser.cs:680,685`).

Для кода 1912 в UA `GetError` вернёт `""` → текст будет `... | code: 1912 ===>  ( `+
операнд +` )` с двойным пробелом и без фразы (**проверено**: пропуска в
`ErrorsCodeList.cs:377-380`). Порт должен решить: восстановить текст или повторить дефект.

### 3.3 Примеры готовых сообщений

Реальный вывод из корпуса (`tests/golden_report.txt:10-12`):

```
Interpreter start ...
Errors: 1
file: /…/New_Path_Examples/Includes/Include1.bpi line: 3 | code: 2001 ===> Файл не найден /…/Modules/Module1.bpm
```

Синтетические примеры формата (по `Errore.cs:21`):

```
file: /prj/Program1.bp line: 12 | code: 1405 ===> Переменная не определена ( FOO )
file: /prj/Program1.bp line: 4  | code: 1003 ===> Неправильно закрыта структура IF
file: /prj/Program1.bp line: 31 | code: 1304 ===> Неверное количество параметров ( lcd.draw )
file: /prj/Program1.bp line: 3  | code: 1015 ===> Недопустимый код, Должно быть только слово EndIf
```

### 3.4 Ошибки фазы компилятора (другой формат)

`CompileException` → `errorlist.Add(e.Message)`; формат `текст at: L:C`
(`Compiler/Scanner.cs:87`), например `Unexpected NUMBER 5 at: 12:3`
(`Scanner.cs:109`), `Undefined command: foo at: 5:1` (`Compiler/Expression.cs:1085`).
Ассемблер: просто текст, например `Unknown opcode JMP` (`Assembler/Assembler.cs:402`).

## 4. Поведение компилятора после диагностики

### 4.1 Фазы и точки остановки

| Фаза | Точка проверки | Поведение при ошибке |
|---|---|---|
| Препроцессор | после каждого парсера/этапа (`Preprocessor.cs:29-30,34-35,39-40,44-45`) | выход из фазы; `Builder` печатает ошибки и прерывает всю сборку (`Builder.cs:85-91`) |
| Интерпретатор | после каждого из 8 шагов `Start` (`Interpreter.cs:31-98`) | выход; `Builder` печатает и прерывает (`Builder.cs:94-100`) |
| Компилятор | `catch (CompileException)` на 2 проходах (`Compiler/Compiler.cs:226-230,295-299`) | `errorlist.Add(e.Message); return;` — 1 сообщение, сборка прервана (`Builder.cs:113-119`) |
| Ассемблер | `catch (AssemblerException)` (`Assembler/Assembler.cs:85-102`) | 1 сообщение, прервано (`Builder.cs:128-135`) |
| IDE-путь | `try/catch` вокруг фаз 1-2 (`Builder.cs:155-198`) | любое исключение → `errors.Add(ex.Message)` (текст без кода/файла/строки) |

### 4.2 Инкрементальности нет

Внутри парсера после первой ошибки работа немедленно прекращается (`return` в каждом
`Data.Errors.Add`-блоке, например `P/BracketErrorParser.cs:38-46`, `P/VariableErrorParser.cs:79-81`).
Проверки `Data.Errors.Count > 0` после каждого подвызова не дают собрать вторую ошибку.
**Максимум ошибок = 1** (кроме §4.3). Порядок вывода = порядок добавления в `List` — по
порядку возникновения в единственном файле-источнике ошибки.

### 4.3 Единственное исключение: до 3 ошибок

`StructErrorParser.Start` в конце файла добавляет 1011 и 1028 без `return` между ними, затем
ошибку стека (1012/1013/1014) с `return` (`P/StructErrorParser.cs:458-495`) — максимум 3
записи за прогон.

### 4.4 Перезапуск и накопление

`Data.Errors` создаётся заново в `Data.Install` (`Data.cs:17`); между фазами не очищается, но
фаза при ошибке не стартует следующая, поэтому «хвостов» не бывает. Повторный вызов
`BPStart` переустанавливает `Status=true` и создаёт новый проект только через `Data.Install`
в конструкторе Builder — повторный вызов `BPStart` на том же Builder использует накопленный
`Data.Errors` **(гипотеза: в CLI Builder создаётся на прогон; в IDE — не проверено)**.

## 5. Полная таблица диагностик

Обозначения: Фаза — **ПП** (препроцессор), **ИН** (интерпретатор), **КОМ** (компилятор), **АСМ**
(ассемблер). Severity — везде `error`; отдельного поля severity в C# нет, его нет и вплане
вывода. Статус: ● — возбуждается живым кодом; ✕ — мёртвый (не возбуждается, §6).
Условия — с точными ссылками. Тексты — дословно из `DT/ErrorsCodeList.cs`
(RU `:19-213`, UA `:224-417`, EN `:428-621`); опечатки оригинала сохранены намеренно.

### 5.1 Структуры и первый проход (1001–1036) — фаза ПП, кроме 1034/1032 (ПП+ИН)

| Код | Условие (место возбуждения) | RU | EN | UA |
|---|---|---|---|---|
| 1001 ● | закрывающая скобка без открытой — `P/BracketErrorParser.cs:42-46`; незакрытые скобки к концу строки — `:50-54` | Лишняя скобка | Extra bracket | Зайва дужка |
| 1002 ● | закрывающая скобка не соответствует типу открытой (ждали `)`, встретили `]`) — `P/BracketErrorParser.cs:33-40` | Неправильно закрыты скобки | Brackets not closed properly | Неправильно закриті дужки |
| 1003 ● | при закрытии IF верх стека ждёт другой end-структуры; позиция = строка открытия IF — `P/StructErrorParser.cs:120-125` (+аналоги :139-147,:160-168) | Неправильно закрыта структура IF | IF structure not closed properly | Неправильно закрита структура IF |
| 1004 ● | end-слово при пустом стеке (для endif — все ветки :128-132,:148-153,:169-174; для endfor/endwhile — только ветка FUNCTION :215-219,:281-286; несоответствие кода/текста — см. §6.1) | У cтруктура IF нет начала | IF structure has no beginning | У cтруктури IF немає початку |
| 1005 ● | при закрытии FOR верх стека ждёт другой end-структуры — `P/StructErrorParser.cs:186-192` (+аналоги) | Неправильно закрыта структура FOR | FOR structure not closed properly | Неправильно закрита структура FOR |
| 1006 ● | EndFor при пустом стеке (main/sub) — `P/StructErrorParser.cs:193-199,:235-241` | У cтруктура FOR нет начала | FOR structure has no beginning | У cтруктури FOR немає початку |
| 1007 ● | при закрытии WHILE верх стека ждёт другой end-структуры — `P/StructErrorParser.cs:250-257` (+аналоги) | Неправильно закрыта структура WHILE | WHILE structure not closed properly | Неправильно закрита структура WHILE |
| 1008 ● | EndWhile при пустом стеке (main/sub) — `P/StructErrorParser.cs:258-264,:300-306` | У cтруктура WHILE нет начала | WHILE structure has no beginning | У cтруктури WHILE немає початку |
| 1009 ● | `Sub` внутри открытого Sub — `P/StructErrorParser.cs:309-315` | Структура SUB не может содержать в себе другую структуру SUB | SUB structure can not contain other SUB structure | Структура SUB не може містити у собі іншу структуру SUB |
| 1010 ● | `EndSub` без открытого Sub — `P/StructErrorParser.cs:329-335`; **также** `EndFunction` без открытого Function — `:366-372` (текст говорит только о SUB) | У cтруктуры SUB нет начала | SUB structure has no beginning | У cтруктури SUB немає початку |
| 1011 ● | незакрытый Sub в конце файла; позиция = строка `Sub` — `P/StructErrorParser.cs:458-461` | Структура SUB не закрыта | SUB structure is not closed | Структура SUB не є закритою |
| 1012 ● | незакрытый IF в конце файла; позиция = строка `If` — `P/StructErrorParser.cs:466-475` | Структура IF не закрыта | IF structure is not closed | Структура IF не є закритою |
| 1013 ● | незакрытый FOR в конце; позиция = строка `For` — `P/StructErrorParser.cs:469-472` | Структура FOR не закрыта | FOR structure is not closed | Структура FOR не є закритою |
| 1014 ● | незакрытый WHILE в конце; позиция = строка `While` — `P/StructErrorParser.cs:471-474` | Структура WHILE не закрыта | WHILE structure is not closed | Структура WHILE не є закритою |
| 1015 ● | строка `EndIf` содержит >1 слова — `P/StructErrorParser.cs:41-47` + `Code()` `:594-620` | Недопустимый код, Должно быть только слово EndIf | Invalid code. ‘EndIf’ must only be indicated | Неприпустимий код, має бути тільки слово EndIf |
| 1016 ● | строка `EndFor` содержит >1 слова — там же | Недопустимый код, Должно быть только слово EndFor | Invalid code. ‘EndFor’ must only be indicated | Неприпустимий код, має бути тільки слово EndFor |
| 1017 ● | строка `EndWhile` содержит >1 слова — там же | Недопустимый код, Должно быть только слово EndWhile | Invalid code. ‘EndWhile’ must only be indicated | Неприпустимий код, має бути тільки слово EndWhile |
| 1018 ● | строка `EndSub` содержит >1 слова — там же | Недопустимый код, Должно быть только слово EndSub | Invalid code. ‘EndSub’ must only be indicated | Неприпустимий код, має бути тільки слово EndSub |
| 1019 ● | строка `Else` содержит >1 слова — там же | Недопустимый код, Должно быть только слово Else | Invalid code. ‘Else’ must only be indicated | Неприпустимий код, має бути тільки слово Else |
| 1020 ● | `goto`: строка не из 2 слов, или второе слово содержит `:` — `P/StructErrorParser.cs:50-62` | Недопустимый код, Должно быть только слово goto и имя метки перехода (label) без двоеточия | Invalid code. ‘Goto’ and jump label name must only be indicated | Неприпустимий код, має бути тільки слово goto та ім’я мітки переходу (label) |
| 1021 ● | метка: строка не из 1 слова — `P/StructErrorParser.cs:410-416` | Недопустимый код, Должно быть только имя метки перехода (label) и двоеточие в конце | Invalid code. Jump label name and two-spot at the end must only be indicated | Неприпустимий код, має бути тільки ім’я мітки переходу (label) та двокрапка у кінці |
| 1022 ✕ | — | Модуль не найден | Module not found | Модуль не знайдено |
| 1023 ✕ | — | Процедура не найдена | Procedure not found | Процедуру не знайдено |
| 1024 ● | дубликат метки внутри функции — `P/StructErrorParser.cs:860-880`; Message = ` имя*контекст` | Метка (label) с таким именем уже определена в данной функции | Label with this name is already defined in this function | Мітка (label) з таким ім'ям вже визначена в даній функції |
| 1025 ● | дубликат метки вне функций — `P/StructErrorParser.cs:868-874`; Message = ` имя*контекст` | Метка (label) с таким именем уже определена в данной программе | Label with this name is already defined in this program | Метка (label) з таким ім'ям вже визначена в даній програмі |
| 1026 ● | `Function` внутри Function: `P/StructErrorParser.cs:353-357`; в модуле — `P/ImportErrorParser.cs:174-186`, `P/ModuleErrorParser.cs:29-35` | Структура FUNCTION не может содержать в себе другую структуру FUNCTION | FUNCTION structure can not contain other FUNCTION structure | Структура FUNCTION не може містити у собі іншу структуру FUNCTION |
| 1027 ● | `EndFunction` без открытой Function в модуле — `P/ImportErrorParser.cs:187-193` | У cтруктуры FUNCTION нет начала | FUNCTION has no beginning | У cтруктури FUNCTION немає початку |
| 1028 ● | незакрытая Function в конце: программы — `P/StructErrorParser.cs:462-465`; модуля — `P/ImportErrorParser.cs:270-274` | Структура FUNCTION не закрыта | FUNCTION structure is not closed | Структура FUNCTION не є закритою |
| 1029 ● | строка `EndFunction` содержит >1 слова — `P/StructErrorParser.cs:41-47` + `Code()` | Недопустимый код, Должно быть только слово EndFunction | Invalid code. ‘EndFunction’ must only be indicated | Неприпустимий код, має бути тільки слово EndFunction |
| 1030 ● | `Sub` внутри Function — `P/StructErrorParser.cs:316-320`; `EndFunction` внутри Sub — `:373-377` | Структура SUB не может содержать в себе другую структуру FUNCTION | SUB structure can not contain other FUNCTION structure | Структура SUB не може містити у собі іншу структуру FUNCTION |
| 1031 ● | `Function` внутри Sub — `P/StructErrorParser.cs:346-352`; `EndSub` внутри Function — `:336-340` | Структура FUNCTION не может содержать в себе другую структуру SUB | FUNCTION structure can not contain other SUB structure | Структура FUNCTION не може містити у собі іншу структуру SUB |
| 1032 ● | строка не распознана (LineType.NON): `P/LineErrorParser.cs:108-112`; в модуле — `P/ImportErrorParser.cs:73-77`, `P/ModuleErrorParser.cs:73-77`; токен NON в параметре — `P/MethodErrorParser.cs:379-383,:908-912` | Строка не распознана | Row not recognized | Рядок не розпізнаний |
| 1033 ✕ | — | Тип строки не распознан | Row type not recognized | Тип рядка не розпізнаний |
| 1034 ● | METHODCALL не соответствует шаблону (метод без `()` в конце — `P/LineErrorParser.cs:70-79`; property с доп. словами — `:81-88`; event не `Имя = Sub` — `:89-101`; прочее — `:102-106`); недопустимое слово в логическом выражении — `P/LogicErrorParser.cs:462-472` | Ошибки в строке | Errors in the row | Помилки у рядку |
| 1035 ● | goto на метку, которой нет в функции — `P/StructErrorParser.cs:893-901`; Message = ` имя` | Метка (label) с таким именем не найдена в функции | No label with this name found in the function | Мітку (label) з таким ім'ям не знайдено в функції |
| 1036 ● | goto на метку, которой нет в программе — `P/StructErrorParser.cs:901-906` | Метка (label) с таким именем не найдена в программе | No label with this name found in the program | Мітку (label) з таким ім'ям не знайдено в програмі |

### 5.2 Include (1101–1106) — фаза ПП

| Код | Условие | RU | EN | UA |
|---|---|---|---|---|
| 1101 ● | файл `.bpi` не существует по вычисленному пути — `P/IncludeErrorParser.cs:40-46`; Message = путь+`.bpi` | Файл не найден | File not found | Файл не знайдено |
| 1102 ● | в строке include нет имени (1 слово) — `P/IncludeErrorParser.cs:19-23` | Отсутствует имя подключаемого файла | Missing name of file being included | Відсутнє ім'я файлу, що підключається |
| 1103 ● | >2 слов — `P/IncludeErrorParser.cs:24-28` | Неверное количество параметров | Invalid number of parameters | Невірна кількість параметрів |
| 1104 ● | имя не строка (токен ≠ STRING) — `P/IncludeErrorParser.cs:29-33` | Имя файла должно быть в виде строки | File name must be a string | Им'я файла має бути у вигляді рядка |
| 1105 ● | include внутри include-файла — `P/IncludeErrorParser.cs:169-174` (FileName = `имя.bpi` без пути) | Включючаемые файлы не могут содержать своих включений | Files being included can not contain own inclusions | Файли, що включаються, не можуть містити своїх включень |
| 1106 ● | folder внутри include-файла — `P/IncludeErrorParser.cs:175-180` | Включючаемые файлы не могут содержать ключевое слово folder | Files being included can not contain keyword ‘folder’ | Файли, що включаються, не можуть містити ключове слово folder |

### 5.3 Folder (1201–1210) — фаза ПП

| Код | Условие | RU | EN | UA |
|---|---|---|---|---|
| 1201 ● | слов в строке folder ≠ 3 — `P/FolderErrorParser.cs:24-28` | Неверное количество параметров | Invalid number of parameters | Невірна кількість параметрів |
| 1202 ● | параметры не строки — `P/FolderErrorParser.cs:29-33` | Параметры должны быть в виде строки | Parameters must be indicated as a string | Параметри мають бути у вигляді рядка |
| 1203 ● | первый параметр ≠ `prjs`/`sd` — `P/FolderErrorParser.cs:34-38` | Первый параметр должен быть "prjs", или "sd" | The first parameter must be "prjs" or "sd" | Першим параметром має бути "prjs" або "sd" |
| 1204 ● | имя проекта > 32 символов — `P/FolderErrorParser.cs:42-46` | В имени проекта не может быть больше 32 символов | Project name can not contain more than 32 characters | Ім’я проекту не може складатися більш ніж з 32 символів |
| 1205 ● | пустое имя — `P/FolderErrorParser.cs:47-51` | Имя проекта не модеть быть пустым | Project name can not be void | Ім’я проекту не може бути порожнім |
| 1206 ● | первый символ не буква — `P/FolderErrorParser.cs:52-61` | Имя проекта должно начинаться с буквы A-Z, a - z | Project name must begin with A-Z, a - z | Ім’я проекту має починатися з літери A-Z, a - z |
| 1207 ● | символы вне `[0-9a-zA-Z_]` — `P/FolderErrorParser.cs:62-70` | Имя проекта может содержать только буквы A-Z и a-z, цифры 0 - 9 и знак нижнего подчеркивания _ | Project name can only contain letters A-Z and a-z, figures 0 - 9 and underscore character _ | Ім'я проекту може містити тільки літери A-Z та a-z, цифри 0 - 9 та знак нижнього підкреслення _ |
| 1208 ● | второй `folder` в проекте — `P/FolderErrorParser.cs:14-18` | Ключевое слово folder может быть объявлено только один раз | Keyword ‘folder’ can only be declared once | Ключове слово folder може бути оголошене тільки один раз |
| 1209 ✕ | — | Ключевое слово folder нельзя использовать в файлах модулей | Keyword ‘folder’ can not be used in module files | Ключове слово folder не можна використовувати у файлах модулів |
| 1210 ✕ | — | Ключевое слово folder должно быть до начала основного кода | Keyword ‘folder’ must be indicated before the beginning of main code | Ключове слово folder має бути до початку основного коду |

### 5.4 Методы (1301–1314) — фаза ИН (`P/MethodErrorParser.cs`), 1313 — ИН (`P/LogicErrorParser.cs`)

| Код | Условие | RU | EN | UA |
|---|---|---|---|---|
| 1301 ● | имя отсутствует в `DefaultObjectList.Objects` — `P/MethodErrorParser.cs:31-35,:373-377,:902-906`; в `GetMethodLastIndex` — `:519-523` (Message=`( метод )`) | Метод не найден | Method not found | Метод не знайдено |
| 1302 ● | скобки у property/event — `P/MethodErrorParser.cs:490-499` | В вызове метода лишние скобки | Extra brackets in method call | У виклику методу зайві дужки |
| 1303 ● | у method нет скобок после имени — `P/MethodErrorParser.cs:502-517` | В вызове метода отсутствуют скобки | Missing brackets in method call | У виклику методу відсутні дужки |
| 1304 ● | число параметров ≠ InputCount сигнатуры — `P/MethodErrorParser.cs:39-44` | Неверное количество параметров | Invalid number of parameters | Невірна кількість параметрів |
| 1305 ● | переменная в параметре не определена (`:185-193`) или не инициализирована (`:195-199`); `ParseOneParam` — `:692-706` | Переменной не присвоено значение | No value assigned to variable | Змінній не присвоєне значення |
| 1306 ● | метод-параметр без возвращаемого значения (OutputType==NON) — `P/MethodErrorParser.cs:335-339,:850-854` | Метод в качестве параметра не возвращает значений | Method does not return values ??as a parameter | Метод у якості параметру не повертає значень |
| 1307 ● | тип параметра ≠ InputType[i] сигнатуры — `P/MethodErrorParser.cs:386-410` (исключения: InputType ANY, `f.get`, `f.returnnumber/f.returnstring`) | Неверный тип параметра | Invalid parameter type | Невірний тип параметру |
| 1308 ● | между операндами параметра нет мат. оператора — `P/MethodErrorParser.cs:112-120,:144-154,:174-184,:620-633,:646-656,:680-691,:855-868` | Неверное количество параметров, либо отсутствует математический оператор | Invalid number of parameters or math operator missing | Невірна кількість аргументів, або відсутній математичний оператор |
| 1309 ● | первый оператор не `-` (`:62-74,:575-577`) или недопустимый символ оператора (`:78-83,:581-585`) | Недопустимый математический оператор | Invalid math operator | Неприпустимий математичний оператор |
| 1310 ● | смешение типов в выражении параметра (число/строка/массив) — `P/MethodErrorParser.cs:131-138,:160-167,:215-236,:254-276,:286-311,:639-643,:670-674,:725-751,:764-790,:801-828,:894-898` | Разные типы данных | Different data types | Різні типи даних |
| 1311 ● | два мат. оператора подряд (кроме `-` перед операндом) — `P/MethodErrorParser.cs:91-101,:599-615` | Лишние математические операторы | Excess math operators | Зайві математичні оператори |
| 1312 ● | пустой параметр (между запятыми) — `P/MethodErrorParser.cs:53-57` | Отсутствует параметр | Missing parameter | Відсутній параметр |
| 1313 ● | метод без возврата в логическом выражении — `P/LogicErrorParser.cs:395-401` | Метод не возвращает значений | Method does not return values | Метод не повертає значень |
| 1314 ● | `GetMethodLastIndex` вернул −1 без ошибки (скобки не закрыты) — `P/VariableErrorParser.cs:453-461` | Неправильное определение метода | Incorrect method definition | Неправильне визначення методу |

### 5.5 Переменные (1401–1428) — фаза ИН

| Код | Условие | RU | EN | UA |
|---|---|---|---|---|
| 1401 ● | нераспознанный токен в определении переменной — `P/VariableErrorParser.cs:626-630` (Message=`слово токен`); нет `= …` после `[i]` — `:790-798`; тип не определён — `:667-671` | Неправильное определение переменной | Incorrect variable definition | Неправильне визначення змінної |
| 1402 ✕ | — | Отсутствует имя переменной | Missing variable name | Відсутнє ім'я змінної |
| 1403 ✕ | — | В определении переменной недопустимые математические опрераторы | Invalid math operators in variable definition | У визначенні змінної неприпустимі математичні оператори |
| 1404 ✕ | — | В определении переменной недопустимые выражения | Invalid expressions in variable definition | У визначенні змінної неприпустимі вирази |
| 1405 ● | имя отсутствует в словаре переменных — `P/VariableErrorParser.cs:676-682`, `P/ArrayIndexErrorParser.cs:71-75`, `P/ForLineErrorParser.cs:157-161`, `P/LogicErrorParser.cs:237-241`; output-параметр вызова функции не переменная — `Utils/Interpreter.cs:260-266,:293-315` | Переменная не определена | Variable not defined | Змінну не визначено |
| 1406 ● | переменная есть, но `Init==false && Type==NON` — `P/VariableErrorParser.cs:683-687` | Переменная не инициализирована | Variable not initialized | Змінну не ініціалізовано |
| 1407 ● | несовпадение типа выражения с типом переменной/предыдущим типом — `P/VariableErrorParser.cs:121-124,:129-133,:206-208,:237-241,:281-285,:317,:354-358,:378-381,:416-419,:443-446,:508-512,:532-535,:564-567,:588-591,:832-836,:845-849,:880-885,:905-910`; в логических/For-выражениях — `P/LogicErrorParser.cs:159-163,:197-201,:259-263,:296-300,:319-323,:337-341,:419-423` | Переменная имеет другой тип | Variable has different type | Змінна має інший тип |
| 1408 ● | второй мат. оператор подряд (не `-`) в определении — `P/VariableErrorParser.cs:161-170` | После математического оператора ожидается какой-либо операнд (переменная, число, метод) | An operand (variable, number, method) is expected after math operator | Після математичного оператора очікується який-небудь операнд (змінна, число, метод) |
| 1409 ● | операнд перед оператором отсутствует — `P/VariableErrorParser.cs:143-158`; в лог. выражении — `P/LogicErrorParser.cs:76-85` | Перед математическим оператором ожидается какой-либо операнд (переменная, число, метод) | An operand (variable, number, method) is expected before math operator | Перед математичним оператором очікується який-небудь операнд (змінна, число, метод) |
| 1410 ✕ | — | После определения имени переменной отсутствует знак = | Character ’=’ missing after variable name definition | Після визначення імені змінної відсутній знак = |
| 1411 ● | строка присваивания короче 3 слов — `P/VariableErrorParser.cs:77-81` | После знака = должно быть выражение | Character ’=’ must be followed by an expression | Після знаку = має бути вираз |
| 1412 ● | `++` к не-числу — `P/VariableErrorParser.cs:717-723` | Математическое действие ++ можно применять только к числовым переменным | Mathematical operation ‘++’ can only be applied to numeric variables | Математичну дію ++ можна застосовувати тільки до числових змінних |
| 1413 ● | `--` к не-числу — `P/VariableErrorParser.cs:735-741` | Математическое действие -- можно применять только к числовым переменным | Mathematical operation ‘--’ can only be applied to numeric variables | Математичну дію -- можна застосовувати тільки до числових змінних |
| 1414 ● | лишние слова в `++/--` (Count>2) — `P/VariableErrorParser.cs:709-713`; лишнее в `+=`-строке — `:819-831,:838-843,:889-893,:912-916`; `thread.run` не `= имя` — `Utils/Interpreter.cs:728-734` | В строке недопустимые выражения | Invalid expressions in the row | В рядку неприпустимі вирази |
| 1415 ● | `var = -` без числа после (или у не-числовой переменной) — `P/VariableErrorParser.cs:96-141` | В переменную, со знаком минус можно записать только число | Only a number can be written to variable with minus sign | До змінної зі знаком мінус можна записати тільки число |
| 1416 ● | между операндами нет оператора — `P/VariableErrorParser.cs:172-181,:211-220,:251-260,:290-298,:331-339,:393-399,:478-488,:540-548` | Перед следующим операндом ожидается математический оператор | Math operator is expected after the next operand | Перед наступним операндом очікується математичний оператор |
| 1417 ● | строки складываются только через `+` — `P/VariableErrorParser.cs:631-638`; `P/LogicErrorParser.cs:175-179,:286-290,:327-331,:406-410`; `P/MethodErrorParser.cs:655-661,:719-723,:817-821,:869-875` | Строки допустимо складывать только через оператор + | Rows can only be added with ‘+’ operator | Рядки можна складати тільки через оператор + |
| 1418 ● | мат. операции над массивами — `P/VariableErrorParser.cs:368-372,:433-437,:522-526,:578-582`; `P/MethodErrorParser.cs:741-745,:780-784,:877-883` | Математические операции над масствами недопустимы | Mathematical operations can not be performed on arrays | Математичні операції над масивами неприпустимі |
| 1419 ✕ | — | Для индексации массива могут использоваться только целые числа | Only integers can be used for array indexing | Для індексації масиву можна використовувати тільки цілі числа |
| 1420 ✕ | — | Для индексации массива могут использоваться только числа | Only figures can be used for array indexing | Для індексації масиву можна використовувати тільки числа |
| 1421 ● | мат. действие (`+=` и т.п.) к массиву — `P/VariableErrorParser.cs:813-817` | Данное математическое действие нельзя применять к массивам | This mathematical operations can not be applied to arrays | Дану математичну дію не можна застосовувати до масивів |
| 1422 ✕ | — | Число индкса массива должно быть целым (без дробной части) | Array index number must be an integer (without fractional part) | Число індексу масиву має бути цілим (без дробової частини) |
| 1423 ● | переменная-индекс не числа (не NUMBER) — `P/ForLineErrorParser.cs:186-190`, `P/ArrayIndexErrorParser.cs:100-104` | Для индекса массива можно использовать переменные содержащие только целые числа | Variables containing only integers can be used for array indexing | Для індексу масиву можна використовувати змінні, що містять тільки цілі числа |
| 1424 ● | метод-индекс не возвращает число — `P/ForLineErrorParser.cs:214-221`, `P/ArrayIndexErrorParser.cs:128-135` (исключения ANY и `f.get`) | Для индекса массива можно использовать метод который возвращает число | Method that returns a number can be used for array indexing | Для індексу масиву можна використовувати метод, що повертає число |
| 1425 ● | массив как элемент массива (без `[`) — `P/ForLineErrorParser.cs:180-185`, `P/ArrayIndexErrorParser.cs:94-99`, `P/VariableErrorParser.cs:361-367,:426-432,:515-521,:571-577` | В элемент массива нельзя записать другой массив | Another array can not be written to an array element | До елементу масиву не можна записати інший масив |
| 1426 ● | между двумя мат. операторами нет операнда — `P/ForLineErrorParser.cs:120-129,:141-143,:153-155,:201-203`; `P/ArrayIndexErrorParser.cs:37-45,:55-57,:67-69,:115-117`; `P/LogicErrorParser.cs:59-70,:111-118 (Message="2"),:149-153,:187-191,:231-235,:382-386` | Между математическими операторами ожидается какой-либо операнд (переменная, число, метод) | An operand (variable, number, method) is expected between math operators | Між математичними операторами очікується який-небудь операнд (змінна, число, метод) |
| 1427 ● | недопустимый токен в индексе массива — `P/ForLineErrorParser.cs:229-233`, `P/ArrayIndexErrorParser.cs:143-149` | В индексе массива недопустимые значения | Invalid values in array index | Індекс масиву містить неприпустимі значення |
| 1428 ● | `+=,-=,*=,/= ` с методом/переменной, выдающей не число/строку — `P/VariableErrorParser.cs:875-879,:900-904` | С опрераторами +=, -=, *=, /=, могут использоваться только методы возвращающие числа, или строки | Only methods that return figures or rows can be used with operators +=, -=, *=, /= | З операторами +=, -=, *=, /=, можуть використовуватися тільки методи, що повертають числа або рядки |

### 5.6 Процедуры Sub (1601–1607) — фаза ПП (ParseNames) + ИН (1606)

| Код | Условие | RU | EN | UA |
|---|---|---|---|---|
| 1601 ● | в `Sub имя` >2 слов — `P/StructErrorParser.cs:788-792` | Неверное определение процедуры | Invalid procedure definition | Невірне визначення процедури |
| 1602 ● | второе слово не SUBNAME — `P/StructErrorParser.cs:783-787` | В определении процедуры должно быть ключевое слово Sub и имя процедуры | Procedure definition must contain keyword ‘Sub’ and procedure name | У визначенні процедури має бути ключове слово Sub та ім'я процедури |
| 1603 ● | строка состоит только из `Sub` — `P/StructErrorParser.cs:778-782` | В определении процедуры отсутствует имя процедуры | Missing procedure name in procedure definition | У визначенні процедури відсутнє ім'я процедури |
| 1604 ✕ | — | В определении процедуры недопустимые ключевые слова | Procedure definition contains invalid keywords | Визначення процедури містить неприпустимі ключові слова |
| 1605 ✕ | — | В определении процедуры недопустимые выражения | Procedure definition contains invalid expressions | Визначення процедури містить неприпустимі вирази |
| 1606 ● | вызов несуществующей процедуры — `Utils/Interpreter.cs:708-712` (короткий вызов), `:741-749` (`thread.run` на неизвестный Sub) | Процедура не найдена | Procedure not found | Процедуру не знайдено |
| 1607 ● | дубликат имени Sub — `P/StructErrorParser.cs:806-812`; имя Function совпало с Sub — `:844-848` | Процедура с таким именем уже определена | Procedure with this name is already defined | Процедуру з таким ім'ям вже визначено |

### 5.7 Функции (1801–1822) — фазы ПП (модули: `P/ModuleErrorParser.cs`; имена: `P/StructErrorParser.cs`) и ИН (`P/FunctionsInitErrorParser.cs`)

| Код | Условие | RU | EN | UA |
|---|---|---|---|---|
| 1801 ● | шапка Function короче 3 слов — `P/FunctionsInitErrorParser.cs:26-30`; 2 слова — `P/StructErrorParser.cs:828-832`; в модуле — `P/ModuleErrorParser.cs:101-105,:142-146` | Неверное определение функции | Invalid function definition | Невірне визначення функції |
| 1802 ● | после имени нет `(`/`()` — `P/FunctionsInitErrorParser.cs:50-54`; нет закрывающей `)` — `P/ModuleErrorParser.cs:113-117,:134-138`; `P/StructErrorParser.cs:833-837` | В определении функции отсутствуют скобки | Missing brackets in function definition | У визначенні функції відсутні дужки |
| 1803 ● | второе слово не FUNCNAME — `P/FunctionsInitErrorParser.cs:32-36`; нет имени — `P/ModuleErrorParser.cs:107-111`, `P/StructErrorParser.cs:818-822` | В определении функции отсутствует имя функции | Missing function name in function definition | У визначенні функції відсутнє ім'я функції |
| 1804 ● | ключевое слово ≠ in/out/тип — `P/FunctionsInitErrorParser.cs:238-242`, `P/ModuleErrorParser.cs:337-341` | В определении функции недопустимые ключевые слова | Invalid keywords in function definition | У визначенні функції неприпустимі ключові слова |
| 1805 ● | лишняя `(`; токен после `)`; прочие токены — `P/FunctionsInitErrorParser.cs:66-77,:346-366`; `P/ModuleErrorParser.cs:400-404`; `P/StructErrorParser.cs:823-827` | В определении функции недопустимые выражения | Invalid expressions in function definition | У визначенні функції неприпустимі вирази |
| 1806 ● | имя функции отсутствует в словаре функций при разборе шапки — `P/FunctionsInitErrorParser.cs:41-45,:262-268,:282-288`; при вызове — `Utils/Interpreter.cs:697-707,:716-723` | Функция не найдена | Function not found | Функцію не знайдено |
| 1807 ✕ | только в закомментированном `RenameSubName` — `P/StructErrorParser.cs:545` (блок `/*…*/` :498-592) | Имя не может быть использовано, так как уже определена функция с таким именем | Name can not be used because a function with this name is already defined | Не можна використати ім'я, тому що вже визначено функцію з таким ім'ям |
| 1808 ✕ | — | Имя не может быть использовано, так как уже определена процедура с таким именем | Name can not be used because a procedure with this name is already defined | Не можна використати ім'я, тому що вже визначено процедуру з таким ім'ям |
| 1809 ● | дубликат Function+число параметров — `P/ModuleErrorParser.cs:121-128` (в модуле, Message=`( имя (0) )`); имя/кол-во занято — `P/StructErrorParser.cs:852-858`; Sub занят функцией — `:796-802` | Функция с таким именем и количеством параметров уже определена | Function with this name and number of parameters is already defined | Функцію з таким ім'ям і кількістю параметрів вже визначено |
| 1810 ● | одинаковые имена параметров — `P/FunctionsInitErrorParser.cs:270-278,:290-298`; в модуле — `P/ModuleErrorParser.cs:166-170` | В определении функции есть переменные с одинаковыми именами | Function definition contains variables with the same name | У визначенні функції є змінні з однаковими іменами |
| 1811 ● | между определениями параметров не запятая (состояние vars==3 при in/out/типе) — `P/FunctionsInitErrorParser.cs:96-104,:125-133,:148-157,:176-183,:201-210,:226-234,:311-317`; `P/ModuleErrorParser.cs:194-203,:222-230,:249-256,:273-281,:296-303,:320-327,:345-352,:365-370` | В определении функции между определениями переменных должна быть запятая | Variable definitions in function definition must be separated with a comma | У визначенні функції між визначеннями змінних має бути кома |
| 1812 ● | запятая без переменной перед ней (vars==0) — `P/FunctionsInitErrorParser.cs:339-343`, `P/ModuleErrorParser.cs:393-397` | В определении функции перед запятой должна быть переменная | There must be a variable before the comma in function definition | У визначенні функції перед комою має бути змінна |
| 1813 ● | после in/out сразу ещё in/out/запятая (vars==1) — `P/FunctionsInitErrorParser.cs:88-94,:117-123,:330-334,:369-373`; `P/ModuleErrorParser.cs:189-193,:216-221,:384-388` | В определении функции после ключевого слова in/out должен быть тип переменной | There must be a variable type after keyword ‘in/out’ in function definition | У визначенні функції після ключового слова in/out має бути тип змінної |
| 1814 ● | переменная при vars==1 (нет типа) — `P/FunctionsInitErrorParser.cs:308-312,:374-377`; `P/ModuleErrorParser.cs:362-366,:415-418` | В определении функции после перед переменной должно быть указан тип переменной | Variable type must be indicated before the variable in function definition | У визначенні функції після перед змінною має бути вказаний тип змінної |
| 1815 ● | строка закончилась на запятой (vars==0 в конце) — `P/FunctionsInitErrorParser.cs:379-383` | В определении функции после запятой должно быть ключевое слово in/out | Keyword ‘in/out’ must be indicated after the comma in function definition | У визначенні функції після коми має бути ключове слово in/out |
| 1816 ● | тип без предшествующего in/out (vars==0 или 3) — `P/FunctionsInitErrorParser.cs:143-157,:169-183,:195-209,:221-234`; `P/ModuleErrorParser.cs:242-256,:268-283,:293-308,:319-334` | В определении функции перед типом переменной должно быть ключевое слово in/out | Keyword ‘in/out’ must be indicated before the variable type in function definition | У визначенні функції перед типом змінної має бути ключове слово in/out |
| 1817 ● | после типа нет переменной (vars==2) — `P/FunctionsInitErrorParser.cs:95-99,:122-126,:148-152,:174-178,:200-204,:226-230,:374-377`; `P/ModuleErrorParser.cs:194-198,:221-225,:419-423` | В определении функции после типа переменной должно быть имя переменной | Variable name must be indicated after the variable type in function definition | У визначенні функції після типу змінної має бути ім'я змінної |
| 1818 ● | переменная при vars==0 (нет in/out и типа) — `P/FunctionsInitErrorParser.cs:303-307`; `P/ModuleErrorParser.cs:357-361,:407-412` | В определении функции после перед переменной должно быть указано ключевое слово in/out и тип переменной | Keyword ‘in/out’ and variable type must be indicated before the variable in function definition | У визначенні функції після змінної має бути ключове слово in/out і тип змінної |
| 1819 ● | тип параметра не определён (tmpType==NON) — `P/FunctionsInitErrorParser.cs:254-258`, `P/ModuleErrorParser.cs:349-353` | В определении функции не определён тип переменной | Variable type not defined in function definition | У визначенні функції не визначено тип змінної |
| 1820 ✕ | только в закомментированном `GetFuncParamCountCalls` — `P/StructErrorParser.cs:679,:723` | Параметр имеет другой тип | Parameter has different type | Параметр має інший тип |
| 1821 ✕ | только там же — `P/StructErrorParser.cs:709,:715` | В вызове функции выходной параметр может быть только переменной | In function call, output parameter can only be a variable | У виклику функції вихідний параметр може бути тільки змінною |
| 1822 ● | глобальная переменная (`gv_`-префикс / `@`) в параметрах Function — `P/FunctionsInitErrorParser.cs:249-253`; `@` в параметрах модуля — `P/ModuleErrorParser.cs:152-158` | В определении функции в параметрах нельзя использовать ссылки на глобальные переменные | Parameters can not contain references to global variables in function definition | У визначенні функції в параметрах не можна використовувати посилання на глобальні змінні |

### 5.8 For / If / While / Break / Continue / Return (1901–1918) — фаза ИН

| Код | Условие | RU | EN | UA |
|---|---|---|---|---|
| 1901 ● | в строке For нет подстроки `to` (поиск по всей строке) — `P/ForLineErrorParser.cs:19-23` | Отсутствует ключевое слово To | Missing keyword ‘To’ | Відсутнє ключове слово To |
| 1902 ● | строка For короче 6 слов — `P/ForLineErrorParser.cs:25-29` | В строке инициализации For ошибки | Errrors in For initialization line | У рядку ініціалізації For є помилки |
| 1903 ● | слово[1] не VARIABLE **или** слово[2] не `=` — `P/ForLineErrorParser.cs:31-35` | После слова For должна быть переменная и присвоение ей значения | ’For’ must be followed by a variable and the value assigned to it | Після слова For має бути змінна та значення, що було їй привласнене |
| 1904 ● | переменная цикла не NUMBER — `P/ForLineErrorParser.cs:37-46,:68-75` | В цикле For в переменной должно быть число | In For cycle, variable must contain a number | У циклі For у змінній має бути число |
| 1905 ● | между операндами лог. выражения нет лог. оператора — `P/LogicErrorParser.cs:137-141,:169-173,:219-223,:370-374` | Между операндами должен быть логический оператор | There must be a logical operator between operands | Між операндами має бути логічний оператор |
| 1906 ● | в сравнении участвует массив/массив-строка без индекса или иной тип — `P/LogicErrorParser.cs:270-274,:305-311,:343-347` | Сравнивать можно только числа и строки | Numbers and lines can only be compared | Порівнювати можна тільки числа і рядки |
| 1907 ● | if/elseif не заканчивается на `then` — `P/LineErrorParser.cs:22-28` | В конце строки должно быть слово Then | ‘Then’ must be indicated at the end of the line | В кінці рядка має бути слово Then |
| 1908 ● | нет условия: if/elseif короче 3 слов — `P/LineErrorParser.cs:29-33`; while короче 2 — `:44-50` | Отсутствует логическое условие | Missing logical condition | Відсутня логічна умова |
| 1909 ● | два лог. оператора подряд (BOOLOPERATOR/EQU при logic==true) — `P/LogicErrorParser.cs:29-37` | Нельзя использовать два логических оператора подряд | You cannot use two logical operators in a row | Не можна використовувати два логічних оператора поспіль |
| 1910 ● | лог. оператор без левой части (firstOperand) — `P/LogicErrorParser.cs:39-43` | В логическом выражении отсутствует левая часть | Boolean expression missing left side | У логічному вираженні відсутня ліва частина |
| 1911 ● | лог. оператор без правой части — `P/LogicErrorParser.cs:447-457,:475-484` | В логическом выражении отсутствует правая часть | Boolean expression missing right side | У логічному вираженні відсутня права частина |
| 1912 ● | два операнда подряд без оператора — `P/LogicErrorParser.cs:45-49,:123-127,:205-209,:354-358`; `and/or/then` сразу после `and/or` — `:438-446`. **В UA словаре отсутствует** (§3.2) | В логическом выражении должно быть два операнда | Boolean expression missing both sides **(нет в EN-словаре: код не зарегистрирован в SetEN, `ErrorsCodeList.cs:571-589`)** | **отсутствует в UA** (`ErrorsCodeList.cs:377-380`) |
| 1913 ● | `break` с лишними словами — `P/LineErrorParser.cs:312-319` | В строке может быть только одно ключевое слово Break | There can only be one keyword "Break" per line | У рядку може бути лише одне ключове слово Break |
| 1914 ● | `break` вне For/While — `P/LineErrorParser.cs:321-326` | Ключевое слово Break можно использовать только внутри For...EndFor и While...EndWhile | Keyword "Break" can be used in the middle of For...EndFor and While...EndWhile | Ключове слово Break можна використовувати лише усередині For...EndFor і While...EndWhile |
| 1915 ● | `continue` с лишними словами — `P/LineErrorParser.cs:296-303` | В строке может быть только одно ключевое слово Continue | There can only be one keyword "Continue" per line | У рядку може бути лише одне ключове слово Continue |
| 1916 ● | `continue` вне For/While — `P/LineErrorParser.cs:305-310` | Ключевое слово Continue можно использовать только внутри For...EndFor и While...EndWhile | Keyword "Continue" can be used in the middle of For...EndFor and While...EndWhile | Ключове слово Continue можна використовувати лише усередині For...EndFor і While...EndWhile |
| 1917 ● | `return` с лишними словами — `P/LineErrorParser.cs:328-335` | В строке может быть только одно ключевое слово Return | There can only be one keyword "Return" per line | У рядку може бути лише одне ключове слово Return |
| 1918 ● | `return` вне Sub/Function — `P/LineErrorParser.cs:337-342` | Ключевое слово Return можно использовать только внутри Sub...EndSub и Function...EndFunction | Keyword "Return" can be used in the middle of Sub...EndSub and Function...EndFunction | Ключове слово Return можна використовувати лише усередині Sub...EndSub і Function...EndFunction |

**Примечание к 1912.** В EN-словаре код 1912 тоже не зарегистрирован (SetEN перескакивает с
1911 на 1913, `ErrorsCodeList.cs:581-584`) — текст из таблицы RU существует только в RU.
Для 1912 UA/EN дадут пустую фразу после `===>`. Мой перевод EN «Boolean expression missing
both sides» в таблице — **реконструкция, не факт оригинала** (помечено).

### 5.9 Модули/Import (2001–2020) — фаза ПП (`P/ImportErrorParser.cs`, `P/ModuleErrorParser.cs`) и линкер (`Utils/Linker.cs`)

| Код | Условие | RU | EN | UA |
|---|---|---|---|---|
| 2001 ● | файл `.bpm` не существует — `P/ImportErrorParser.cs:72-77`; Message = путь+`.bpm` | Файл не найден | File not found | Файл не знайдено |
| 2002 ● | import без имени (1 слово) — `P/ImportErrorParser.cs:21-24` | Отсутствует имя импортируемого файла модуля | Missing imported module file name | Відсутня ім'я файла модуля, що імпортується |
| 2003 ● | >2 слов — `P/ImportErrorParser.cs:25-28` | Неверное количество параметров | Invalid number of parameters | Невірна кількість параметрів |
| 2004 ● | имя не строка — `P/ImportErrorParser.cs:29-32` | Имя файла должно быть в виде строки | File name must be a string | Им'я файла має бути у вигляді рядка |
| 2005 ● | include внутри модуля — `P/ImportErrorParser.cs:164-168`, `P/ModuleErrorParser.cs:48-52` | Импортируемые файлы модулей не могут содержать включений include | Imported module files can not contain ‘include’ inclusions | Імпортовані файли модулів не можуть містити включень include |
| 2006 ● | folder внутри модуля — `P/ImportErrorParser.cs:169-173`, `P/ModuleErrorParser.cs:53-57` | Импортируемые файлы модулей не могут содержать ключевое слово folder | Imported module files can not contain keyword ‘folder’ | Імпортовані файли модулів не можуть містити ключове слово folder |
| 2007 ● | `Sub` в модуле — `P/ImportErrorParser.cs:199-203`, `P/ModuleErrorParser.cs:43-47` | В файлах модулей .bpm определение процедур недопустимо | Invalid procedure definition in .bpm module files | У файлах модулів .bpm визначення процедур непримустиме |
| 2008 ● | в модуле вне метода не свойство (не число/строка-объявление) — `P/ImportErrorParser.cs:253-260`; в линкере: переменная вне метода модуля — `Utils/Linker.cs:571-576`; `@`-метка — `:584-589`; метка вне метода — `:591-596` | В файлах модулей .bpm допустимы только определения функций и свойств | .bpm module files can only contain function definitions and properties | У файлах модулів .bpm можуть бути лише визначення функцій і властивостей |
| 2009 ● | `@`-переменная в модуле — `Utils/Linker.cs:562-569` | Нельзя использовать ссылки на глобальные переменные в модулях .bpm | References to global variables can not be used in .bpm modules | Не можна використовувати посилання на глобальні змінні в модулях .bpm |
| 2010 ✕ | `@`-метка в модуле даёт 2008, не 2010 (`Utils/Linker.cs:584-589`) | Нельзя использовать ссылки на глобальные метки перехода в модулях .bpm | References to global goto lables can not be used in .bpm modules | Не можна використовувати посилання на глобальні мітки переходу в модулях .bpm |
| 2011 ● | объявление свойства ≠ 2 слов — `P/ImportErrorParser.cs:224-229`, `P/ModuleErrorParser.cs:448-454,:488-494,:528-534,:568-574` | Объявление свойства модуля должно состоять только из типа и имени свойства | A module property declaration must only consist of the property type and name | Оголошення властивості модуля має складатися тільки з типу й імені властивості |
| 2012 ● | первое слово объявления не тип — `P/ImportErrorParser.cs:230-235`, `P/ModuleErrorParser.cs:460-466,:500-506,:540-546,:580-586` | Свойство модуля должно состоять из его типа и имени | A module property must consist of its type and name | Властивість модуля має складатися з його типу й імені властивості |
| 2013 ● | тип ≠ number/number[]/string/string[] — `P/ImportErrorParser.cs:236-241`, `P/ModuleErrorParser.cs:456-460,:496-500,:536-540,:576-580` | Тип свойства может быть только number, number[], string, или string[] | A property can only be of number, number[], string, or string[] type | Тип властивості може бути тільки number, number[], string, або string[] |
| 2014 ● | дубликат имени свойства — `P/ImportErrorParser.cs:242-247` (Message = OriginText), `P/ModuleErrorParser.cs:469-480,:509-519,:549-559,:589-599` (Message=`( OriginText )`) | Свойство с таким именем уже определено в модуле | A property with this name has already been defined in the module | Властивість із таким ім’ям вже визначена в модулі |
| 2015 ● | свойство внутри метода модуля — `P/ImportErrorParser.cs:216-222`, `P/ModuleErrorParser.cs:442-448,:482-488,:522-528,:562-568` | Свойство не может быть объявлено внутри метода (функции) модуля | A property cannot be declared inside a module method (function) | Властивість не може бути оголошена всередині методу (функції) модуля |
| 2016 ● | `private` с лишними словами — `P/ModuleErrorParser.cs:58-67` | В строке допустимо только одно ключевое слово - private | The ‘private’ keyword is the only one admissible keyword in the line | У рядку може бути тільки одне ключове слово - private |
| 2017 ● | вызов приватного свойства вне модуля-владельца — `Utils/Linker.cs:876-887` (из main), `:921-937` (из чужого модуля) | Вызов приватного свойства допустим только в модуле владельце этого свойства | Calling a private property is allowed only in the module that owns this property | Виклик приватного властивості допустимо тільки в модулі власника цієї властивості |
| 2018 ● | вызов приватного метода вне модуля-владельца — `Utils/Linker.cs:889-906,:939-956` | Вызов приватного метода допустим только в модуле владельце этого метода | Calling a private method is allowed only in the module owner of this method | Виклик приватного методу допустимо тільки в модулі власника цього методу |
| 2019 ● | имя параметра функции модуля совпало с именем свойства — `P/ModuleErrorParser.cs:605-620` | Имя переменной в описании функции модуля совпадает с именем свойства модуля | The variable name in the module function description is the same as the module property name | Ім'я змінної в описі функції модуля збігається з ім'ям властивості модуля |
| 2020 ● | использованное в main свойство не найдено в модуле — `Utils/Linker.cs:853-856`; Message = `pr_модуль_свойство` | Свойство с таким именем не определено в модуле | A property with this name is not defined in the module | Властивість з такою назвою не визначена в модулі |

### 5.10 Global / User method (1501–1503, 1701–1709) — ✕ все мёртвые

Ключевое слово `global` в живом коде не анализируется вовсе (grep по `Int/` — 0 вхождений вне
словаря). Группы «Global» и «User method» — наследие старой версии компилятора.

| Код | RU | EN | UA |
|---|---|---|---|
| 1501 | Ключевое слово global нельзя использовать в файлах модулей | Keyword ‘global’ can not be used in module files | Ключове слово global не можна використовувати у файлах модулів |
| 1502 | Глобальные переменные нельхя определять в теле процедуры | Global variables can not be defined in procedure body | Глобальні змінні не можна визначати в тілі процедури |
| 1503 | Глобальные переменные должны определяться до начала основного кода | Global variables must be defined before the beginning of main code. | Глобальні змінні мають бути визначені до початку основного коду |
| 1701 | Неверный синтаксис вызова процедуры из модуля | Invalid procedure call from module syntax | Невірний синтаксис виклику процедури з модуля |
| 1702 | В вызове процедуры отсутствуют скобки | Missing brackets in procedure call | У виклику процедури відсутні дужки |
| 1703 | В параметрах вызова процедуры ошибка | Error in procedure call parameters | В параметрах виклику процедури є помилка |
| 1704 | В параметрах вызова процедуры несколько запятых подряд | Several commas in a row in procedure call parameters | В параметрах виклику процедури вказано кілька ком поспіль |
| 1705 | В параметрах вызова процедуры недопустимые выражения | Invalid expressions in procedure call parameters | В параметрах виклику процедури містяться неприпустимі вирази |
| 1706 | В параметрах вызова процедуры недопустимые математические опрераторы | Invalid math operators in procedure call parameters | В параметрах виклику процедури містяться неприпустимі математичні оператори |
| 1707 | В вызове процедуры после запятой отсутствует параметр | Missing parameter after the decimal point in procedure call | У виклику процедури відсутній параметр після коми |
| 1708 | Модуль не найден | Module not found | Модуль не знайдено |
| 1709 | Модуль должен содержать только определения процедур | Module must only contain procedure definitions | Модуль має містити тільки визначення процедур |

### 5.11 Отладочные (4001–4009) — ✕ мёртвые, бесполезны для LSP

Все девять: `===> N <===` (RU `ErrorsCodeList.cs:204-213`, UA `:408-417`, EN `:612-621`).
Ни одного возбуждения в коде. Планировались как точки-маркеры, к диагностике отношения не имеют.

### 5.12 Мёртвые коды без групповой специфики

1022, 1023 (§5.1), 1033 (§5.1), 1209, 1210 (§5.3), 1402, 1403, 1404, 1410, 1419, 1420, 1422 (§5.5),
1604, 1605 (§5.6), 1808 (§5.7), 2010 (§5.9). Полный перечеркнутый список с текстами — в
соответствующих таблицах выше.

### 5.13 Сообщения фазы компилятора (КОМ) — английские, формат `текст at: L:C`

Возбуждаются `Scanner.ThrowParseError`/`ThrowUnexpectedSymbol`/`ThrowExpectedSymbol`
(`Compiler/Scanner.cs:85-123`) и парсером выражений. Полный уникальный список текстов
(grep по `Compiler/Expression.cs`, `Compiler/Compiler.cs`):

- `Unexpected {SymType} {содержимое}` — `Scanner.cs:109` (4 места `ThrowUnexpectedSymbol`);
- `Expected {содержимое|SymType}` — `Scanner.cs:112-123` (9 мест);
- `Reference to undefined function: {имя}` — `Expression.cs:534`;
- `Unknown PRAGMA: {имя}` — `Expression.cs:598`;
- `Can not use {имя} as loop counter. Is already defined to contain non-number` — `:731`;
- `Can not assign different types to {имя}` — `:881`;
- `Can only store numbers or strings into arrays` — `:904`;
- `Can not use {имя} as array to store this type` — `:915`;
- `Unknown property to set:  {объект}.{свойство}` — `:983` (два пробела в оригинале);
- `Undefined local variable: {имя}` — `:1012`;
- `Can only use RETURN from inside function` — `:1031`;
- `Can only use RETURN in primary SUB of a function` — `:1035`;
- `Return command must be of same type as function definiton` — `:1042` (опечатка «definiton» в оригинале);
- `Undefined function: {имя}` — `:1059`;
- `Too many arguments for function: {имя}` — `:1068`;
- `Undefined command: {имя}` — `:1085`;
- `Return value that is an array must be directly stored in a variable` — `:1106`;
- `Can not use this expression type here: {тип}. Expected: {тип}` — `:1124`;
- прочие типовые (текст целиком из грепа, места не выписывал построчно — **(проверено наличие, гипотеза о точных строках для части)**):
  `Can not compare arrays`; `Can not concat arrays`; `Can not decode number: {n}`;
  `Can not reference {…}`; `can not use array {…}`; `can not use variable {…}`;
  `Can not use command that returns nothing in an expression`;
  `Double function definition: {имя}`; `Mismatching returns in: {имя}`;
  `Need array to use with '[]'`; `Need identical types on both sides of '<>'/'='`;
  `need number after '-'`; `need number on left/right side of '*','-','/','<','<=','>','>='`;
  `need text on left/right side of AND/OR`; `Redefined Sub {имя}`;
  `Subroutine called from outside function context: {имя}`; `Text is longer than 251 letters`;
  `Too few arguments to {имя}`; `Undefined command or property: {имя}`.

Все — severity error, одна за прогон (§4.1). Локализации нет (только EN).

### 5.14 Сообщения фазы ассемблера (АСМ) — английские, без позиции

`Assembler/Assembler.cs` (все `throw new AssemblerException(...)` / `Exception`):
`Unknown command: {s}` (:194); `Can not add subcall alias to non-subcall object` (:214);
`Trying to call an object that is not defined as a SUBCALL` (:356); `Label must only have one
trailing ':'` (:386); `Unknown opcode {t}` (:402,:414); `Too few parameters for {cmd}` (:427);
`Trying to start an object that is not defined as a thread` (:447); `Trying to access an object
that is not defined as a subcall` (:476); `Can not decode parameter count specifier` (:494);
`Parameter count specifier out of range` (:498); `Invalid number of parameters for {cmd}` (:513);
`Unknown identifier {p}` (:556); `Can not decode number: {p}` (:578); `Invalid parameter value`
(:589); `Nonterminated string` (:658); `Unknown letter '{c}'` (:705); `Identifier expected` (:716);
`Too many elements for command` (:720,:738); `Identifer expected instead of {t}` (:727, опечатка);
`Number expected` (:734,:750); `Number ouf of range` (:745, опечатка); при верификации RBF:
`Missing LEGO header` (:796); `Encountered invalid triggercount value` (:825); `Can not have
local bytes for object with owner` (:832); `No object starts at position {n}` (:843);
`Can not decode subcall parameter list` (:890); `Invalid specifier for number of CALL
parameters` (:908); `Unrecognized opcode: {op}({p1})` (:977); `Can not decode parameter {b}` (:1077).

Эти проверки (компилятор/ассемблер) в редакторе **не нужны** — см. §8.

## 6. Мёртвые коды и несоответствия (сводка)

Мёртвые (зарегистрированы, никогда не возбуждаются — проверено grep по всем `*.cs`,
вне `ErrorsCodeList.cs` вхождений нет): **1022, 1023, 1033, 1209, 1210, 1402, 1403, 1404, 1410,
1419, 1420, 1422, 1501, 1502, 1503, 1604, 1605, 1701–1709, 1808, 2010, 4001–4009**; коды
**1807, 1820, 1821** возбуждаются только из закомментированного блока
(`P/StructErrorParser.cs:498-755`, внутри используется несуществующий уже `Builder.Errors`).

Несоответствия код↔текст/поведение (проверено по коду, важно при порте):

1. `EndFunction` без Function даёт код 1010 («У cтруктуры SUB нет начала») —
   `P/StructErrorParser.cs:366-372`.
2. `EndFor`/`EndWhile` при пустом стеке **внутри Function** дают 1004 («У cтруктура IF нет
   начала») вместо 1006/1008 — `P/StructErrorParser.cs:215-219,:281-286`.
3. `Sub` внутри Function даёт 1030 с текстом про «SUB не может содержать FUNCTION» — текст
   соответствует, но симметричный случай `EndSub` внутри Function (1030, `:336-340`) текстом
   не покрывается; аналогично 1031.
4. 1912 отсутствует в словарях EN и UA (§5.8).
5. 1426 в `P/LogicErrorParser.cs:115` передаёт Message="2" — в выводе будет
   `... ===> Между математическими операторами ... 2`.
6. 1024/1025 подставляют `метка*контекст` со звёздочкой (`P/StructErrorParser.cs:862,872,877`).
7. 2008 используется для трёх разных условий (§5.9), 2009 — «@-переменная», а заявленная в
   2010 ситуация «@-метка» фактически даёт 2008.

## 7. Что нужно LSP-серверу (Zed)

### 7.1 Проверки, возможные без полного конвейера (по одному файлу)

Синтаксис/структура (нужны только токены строки и стек структур):

| Коды | Что нужно |
|---|---|
| 1001, 1002 | баланс скобок в строке (`P/BracketErrorParser.cs`) |
| 1003–1014, 1029–1031, 1011, 1028 | стек структур If/For/While/Sub/Function — воспроизвести `StructErrorParser.Start` |
| 1015–1021 | число слов в однословных строках + goto/label |
| 1907, 1908, 1913–1918 | хвост `then`, непустое условие, позиция break/continue/return относительно стека структур (`P/LineErrorParser.cs:273-354`) |
| 1032 | нераспознанный первый токен (`Utils/LineBuilder.cs:295-424` + `TokenBuilder`) |
| 1102–1104, 2002–2004 | форма include/import (число слов, кавычки) |
| 1201–1208 | форма folder |
| 1601–1603, 1801–1805 (шапка) | число слов и токены в `Sub имя` / `Function имя(...)` |
| 2011–2013, 2015, 2016, 2005–2007 | форма свойств/запретов внутри `.bpm` |

Имена и уникальность (нужен словарь имён одного файла, без типов):

| Коды | Что нужно |
|---|---|
| 1024, 1025 | реестр меток per-функция (`P/StructErrorParser.cs:757-918`) |
| 1607, 1809 | реестр имён Sub/Function+число параметров |
| 1810 | реестр параметров шапки |

### 7.2 Проверки, требующие конвейера/контекста

| Коды | Требуемый контекст |
|---|---|
| 1101, 2001 | существование файла на диске + `ModuleLibPath` (корневая библиотека `Clev3r://`) — `P/IncludeErrorParser.cs:80-154`, `P/ImportErrorParser.cs:473-547` |
| 1301–1314 | сигнатуры встроенных методов (`CommonData/DefaultObjectList` — готовится в doc 03) **и** словарь переменных проекта |
| 1405–1409, 1411–1418, 1421, 1423–1428 | словарь переменных `Data.Project.Variables`, который наполняется **последовательно по ходу разбора** (`P/VariableErrorParser.cs:641-666`): переменная, объявленная ниже по тексту, «не определена» — семантика однопроходная; LSP обязан воспроизводить порядок строк, иначе ложные срабатывания |
| 1406 | флаг `Init` из того же однопроходного словаря |
| 1606, 1806 | словари вызовов после линковки (`Utils/Interpreter.cs:654-754`) — зависят от наличия `import` и результатa `Linker` |
| 1901–1906 | тип переменной цикла + словарь переменных (`P/ForLineErrorParser.cs`) |
| 2017, 2018, 2019, 2020, 2009, 2008 | разбор **всех** импортированных модулей и их приватности (`Utils/Linker.cs:860-960`) |
| 1026, 1027, 1028 в `.bpm`, 2014 | обход файлов модулей (`P/ImportErrorParser.cs:148-277`) |

Практическая схема для LSP: «быстрый уровень» = §7.1 (пересчёт за O(строка) при наборе,
диагностики publish по всему файлу), «медленный уровень» = §7.2 после паузы/сохранения —
прогнать мини-конвейер PP+Interpreter на буферах проекта (это дёшево: стадия 3 не нужна).

### 7.3 Рекомендации по позициям для LSP

- Диапазон выделения вычислять самостоятельно: у `Errore` его нет. Минимально — вся строка;
  лучше — повторный `LineBuilder.GetWords(OldLine)` и выбор слова, послужившего `Message`
  (сравнение с `OriginText`/`Text`).
- Отдельные коды указывают строку **открывающей** структуры (1003/1005/1007/1011/1012/1013/1014,
  1028) — в Zed такие ошибки подсвечивать и на строке закрытия (secondary) — см. §2.2 п.3.
- Файл в сообщении нормализовать: полный путь vs `имя.bpm` (§2.2 п.2).
- Коды 1022/1023/1501–1503/1701–1709 и пр. (§6) в LSP **не реализовывать**; словарь текстов
  держать полным для совместимости номеров.
- Локализация: тексты можно брать 1:1 из словарей `ErrorsCodeList` (ru/en/ua) — это
  контракт с пользователями Clev3r; дубли текстов между кодами (1201≡1103≡1304≡2003,
  «Файл не найден» 1101≡2001) — норма, различать по коду.

## 8. Бесполезные/невозможные для редактора диагностики

1. **4001–4009** — отладочные заглушки, никогда не возбуждаются (§5.11).
2. **Мёртвые коды** (§6) — условий нет, реализовывать нечего.
3. **Всё, что после препроцессинга меняет текст строк** (фаза КОМ: `Undefined command`,
   `need number on left side of '*'` и т.п.) — привязано к развёрнутому файлу `~Name.bp`
   (§2.5); в редакторе исходника показать нельзя. Полезно только как «/compiler output»
   в отдельной панели.
4. **Ошибки ассемблера** — позиций нет, текст про внутреннее представление (`Unknown opcode`,
   `Number ouf of range`); для пользователя редактора неинтерпретируемы, в LSP не переносить.
5. **1101/2001** в среде редактора могут быть ложными, пока не настроен `ModuleLibPath`
   (библиотека `Clev3r://…` существует только в установленной Clev3r) — помечать severity
   hint/warning на стороне LSP **(гипотеза/рекомендация)**.
6. **1024/1025 с подстановкой `метка*контекст`** — подстановка нечитаема для пользователя;
   LSP стоит формировать свой текст по коду.
7. **1414 из `Utils/Interpreter.cs:728-734`** — проверка `thread.run` идёт по строкам,
   прошедшим линковку (переименованные имена); простое сопоставление с исходником ненадёжно.
8. Диагностика 1405 из `Utils/Interpreter.cs:264,313` подставляет всю исходную строку —
   диапазон «слово» не восстановить без повторного разбора (§7.3).

## 9. Резюме

- Каталог: 170 кодов `ErrorsCodeList` (RU/UA/EN, `DT/ErrorsCodeList.cs`), из них возбуждаются
  ~141; 26 мёртвых + 3 только в закомментированном коде (§6). Все — ошибки; предупреждений нет.
- Формат вывода: `file: F line: N | code: C ===> ТЕКСТ ПОДСТАНОВКА` (`DT/Errore.cs:21`);
  подстановки — имя/слово/путь/вся строка (§3.2); примеры — §3.3, живой пример из корпуса.
- Позиция = (файл, строка 1-based), колонок нет. Соответствие исходным строкам сохраняется
  пофайлово после препроцессинга (include/import несут свои Number/FileName), но: часть
  ошибок .bpm репортится коротким именем файла; ошибки незакрытых структур указывают строку
  открытия с файлом закрытия; строки-метки break/continue теряют позицию (0, "").
- Фаза компилятора теряет привязку к исходнику (работает с развёрнутым файлом, формат
  `at: L:C`), ассемблер позиций не имеет.
- Остановка на первой ошибке; максимум 1 (исключение — до 3 в конце `StructErrorParser`);
  порядок = порядок добавления; лимитов и инкрементального сбора нет.
- LSP: быстрый уровень (структуры, скобки, формы строк, имена) — локально по файлу;
  медленный (типы, определённость, модули, приватность) — мини-конвейер PP+Interpreter с
  однопроходной семантикой словаря переменных; фазы КОМ/АСМ в редактор не переносить.
- Дефекты, которые порт может молча исправить или обязан сохранить (решить отдельно):
  пропуск 1912 в UA/EN, «2» в Message у 1426, 1010 для EndFunction, 1004 для endfor/endwhile
  в Function, UPPER/OriginText-непоследовательность подстановок, `метка*контекст` у 1024/1025.
