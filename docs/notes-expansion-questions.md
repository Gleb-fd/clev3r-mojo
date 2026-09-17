# Открытые вопросы по развёртке (стадия 1-2 → `~Name.bp`)

Наблюдения сделаны сравнением `tests/corpus/**` и `tests/golden/**/~Name.bp`.
Каждый пункт закрыт по C#-исходнику и подтверждён byte-паритетом `tools/difftest.sh expand`
(42/44: fail = Include/Main — include вне задачи; skip = New_Path_Examples — у оракула
нет эталона из-за бага с `..`).

## 1. Нумерация `break_N` / `continue_N` — ЗАКРЫТО

Алгоритм — `LineErrorParser.Start` (LineErrorParser.cs:115-118) + `ParseJumpOperators`
(131-203) + `ParseBrakeAndContinue` (205-271); работает по ПЛОСКОМУ списку вывода
(после RewriteOutLines), вызывается трижды подряд:

1. `ParseJumpOperators(lines, FORINIT)` — по всем For-блокам;
2. `ParseJumpOperators(lines, WHILEINIT)` — по всем While-блокам;
3. `ParseJumpOperators(lines, SUBINIT)` — по всем Sub/Function-блокам (только `return`).

Внутри одного вызова блоки обрабатываются в порядке появления НАЧАЛА блока в плоском
списке (снаружи внутрь: внешний For находит свой парный EndFor раньше внутреннего,
внутренний обрабатывается на следующей итерации внешнего цикла). **Поэтому все For-блоки
получают номера раньше всех While-блоков, а While — раньше return'ов**, что и объясняет
наблюдение (b=4 до while=5). Внутри блока сначала обрабатываются `continue`, потом
`break` (два вызова ParseBrakeAndContinue подряд).

Счётчик `Data.Project.BreakPoint` сквозной, инкрементируется ОДИН раз на пару
(блок, тип jump) при наличии хотя бы одного jump: метка = `jumpWord_N`. Несколько
`break`/`continue` в одном блоке → одна и та же метка. `return` игнорирует вложенность
циклов (`flagLoop == 0 || jumpWord == "return"`, cs:218).

Размещение меток (cs:245-269): `continue`/`return` — метка ПЕРЕД end-строкой
(`[метка, EndFor]`), `break` — ПОСЛЕ (`[EndFor, метка]`; если у end-строки уже есть
OutLines от continue — просто дописывается в конец). Сам end-строка добавляется в свой
собственный OutLines (самоссылка — рекурсии при выводе нет: GetOutFile не рекурсивный).
`Goto <метка>` — с заглавной буквы, токен KEYWORD/LABELNAME; метки НЕ получают `gl_`
(создаются после VarsAndLabelsRename).

## 2. Порядок инициализации переменных — ЗАКРЫТО

Секции 1-2 вывода (`CreateProjectOutputLines`, Interpreter.cs:345-446):

1. **`varInit` = параметры функций** (временные `lv_*`): словарь `variables`
   из `ParseOneCall`, порядок вставки = порядок обхода листов main → subs → funcs →
   methods, внутри листа — порядок строк-вызовов, внутри вызова — порядок параметров
   (in и out вперемешку, как в сигнатуре). Тип init-строки — тип ПАРАМЕТРА из сигнатуры.
2. **`varInit` += остальные переменные** (`OtherVarsAddToMain`, Interpreter.cs:606-652):
   обход `Data.Project.Variables` в порядке вставки. Порядок регистрации:
   - сначала out-цели вызовов (Interpreter.cs:278-281 — `gv_c` и т.п., тип = тип
     out-параметра) — ParseCalls идёт ДО SubVarsInit;
   - затем тело main (SubVarsInit, Interpreter.cs:538-604): VARINIT/VARARRAYINIT/FORINIT
     регистрируют переменную при первом присваивании (VariableErrorParser.cs:641-666);
     строка SUBCALL рекурсивно раскрывает тело sub (один раз на имя, набор
     `tmpSubCalls` сквозной) — переменные sub'а встают в позицию ПЕРВОГО вызова;
   - переменные тел Function НЕ регистрируются вообще (Interpreter.cs:54-56 — код
     «пропарсить все функции» не написан): параметров хватает (их init — секция 1),
     остальные локальные переменные функций init-строк НЕ получают.
3. Тип выводится из RHS: NUMBER/STRING-литерал, тип переменной, элемент массива
   (NUMBER_ARRAY→NUMBER, STRING_ARRAY→STRING), OutputType встроенного метода
   (DefaultObjectList, см. src/bp/builtins.mojo), целая массивная переменная →
   NUMBER_ARRAY/STRING_ARRAY; смешение через `+` → STRING (флаг badString,
   VariableErrorParser.cs:643-646). VARARRAYINIT-регистрация маппит
   NUMBER/NUMBER_ARRAY → NUMBER_ARRAY, STRING/STRING_ARRAY → STRING_ARRAY.

Порядок подтверждён дампом `Data.Project.Variables` оракула (reflection) на
TowersOfHanoi: `gv_tower(строка 4), gv_i, gv_j, gv_w (sub draw на строке вызова 46-48),
gv_a, gv_b, gv_n (sub solve), gv_l, gv_newb` — совпадает с Mojo-выводом байт-в-байт.

## 3. Пустая строка в конце файла — ЗАКРЫТО

`Builder.GetOutFile` (Builder.cs:486-506) собирает List<string>, пишет
`File.WriteAllLines` → `\n` после КАЖДОЙ строки, включая последнюю. В Mojo это
`util.lines_to_text`. Проверено `cmp`-размерами golden-файлов.

## 4. Баг с `..` в путях include/import (C#)

`tests/corpus/New_Path_Examples`: `Includes/Include1.bpi` содержит `import "../Modules/Module1"`.
C# `IncludeErrorParser.CreateFullPath` при подъёме на уровень вверх собирает путь из сегментов
`mainWords[j] + separator`, теряя ведущий `/`, из-за чего абсолютный путь превращается
в относительный и файл не находится:
`Файл не найден home/ssssq/.../New_Path_Examples/Modules/Module1.bpm`.
Это единственный пример корпуса, который оракул не скомпилировал (43/44 успешных).
Решение: воспроизводить баг не нужно, но и не «исправлять» молча — задокументировано;
программа исключена из difftest (skip=1, эталона нет).

## 5. `thread.run = ИМЯ` — ЗАКРЫТО

`Thread.Run = BLINKER` — LineType.METHODCALL; слово после `=` — SUBNAME (эвристика
лексера по позициям в исходной строке). FuncRename (Linker.cs:380-394) даёт
`f_blinker_0` (GetParamCount: первое слово `thread.run` → 0 параметров). Строка
остаётся `Thread.Run = f_blinker_0`; имя добавляется в `callsSub` (Interpreter.cs:726-751),
поэтому sub сохраняется от удаления. Подтверждено на Other/Threads.bp (byte-parity).

## 6. Медиа-пути — ЗАКРЫТО

`MediaBuilder.ParseMedia` (MediaBuilder.cs:14-124) вызывается из MethodErrorParser
(дедуп по `FileName_Number`), только если `Data.Project.IsFolder` (успешная директива
`folder`). Для `lcd.bmpfile`/`speaker.play`/`ev3file.openwrite|openappend|openread`
строка переписывается: `play + '"' + <Префикс><имя> + '")'` — хвост строки ЗАМЕНЯЕТСЯ
на `")` (квирк: строка должна быть последним аргументом); для `ev3file.tablelookup`
хвост после закрывающей кавычки сохраняется и добавляется лишняя `)`.
Префикс: `prjs` → `<Проект>/Media/` (ev3file → `/Files/`), `sd` → `SD_Card/<Проект>/Media/`;
без имени проекта/без folder — строка не меняется. Переписанный текст заново
прогоняется через LineBuilder.GetWords (слова и токены пересоздаются). Регистрация
в ImageList/SoundList/FileList влияет только на стадию 4 (.lmsb), не на ~Name.bp.
Подтверждено: Other/Media_PRJS_folder.bp, Other/Media_SD_folder.bp (byte-parity).
