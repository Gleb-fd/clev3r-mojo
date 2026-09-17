# 02. Препроцессор, include/import (.bpi/.bpm) и линковка

Спецификация для порта на Mojo. Источник: C# проект `/home/ssssq/Projects/clev3r_linux/Clev3r-1` (только чтение).
Ссылки вида `File.cs:NN` — файл и строка в этом репозитории. Метки **(гипотеза)** / **(проверено)** — статус верификации.

---

## 1. Место этапа в конвейере

Полный конвейер консольной сборки (`Builder.BPStart`, Builder.cs:59-140):

| № | Этап | Класс | Вход → Выход |
|---|------|-------|--------------|
| 1 | Препроцессор | `Interpreter.Utils.Preprocessor` (Preprocessor.cs:11) | текст main .bp → `Data.Project` (Includes, Modules, размеченные `Line`) |
| 2 | Линковка | `Interpreter.Utils.Linker` (Linker.cs:11) | те же структуры → `MainText/MainFuncText/MainSubText/ModuleMethodsText/Propertys` + переименованные слова |
| 3 | «Интерпретатор» (развёртка) | `Interpreter.Utils.Interpreter` (Interpreter.cs:11) | листы Linker → `Data.Project.OutputLines` |
| 4 | Компилятор / Ассемблер | вне этого документа | `OutputLines` → .lmsb → .rbf |

Вызовы: `new Preprocessor().Start(...)` (Builder.cs:83), `new Utils.Interpreter().Start()` (Builder.cs:93).
Ошибки копятся в глобальном `Data.Errors` (Data.cs:13); **любая** непустая ошибка прерывает весь этап, в котором она возникла (проверка `if (Data.Errors.Count > 0) return;` после каждого шага, Preprocessor.cs:29/34/39/44).

## 2. CLI, расширения, глобальные настройки

| Элемент | Значение | Ссылка |
|---|---|---|
| Аргумент 1 CLI | путь к main .bp; `/` и `\` нормализуются в `Path.DirectorySeparatorChar` | InterpreterConsole/Program.cs:14 |
| Аргумент 2 CLI | `moduleLibPath` — корень библиотеки; может отсутствовать/быть пустым → `""` | InterpreterConsole/Program.cs:23,43 |
| Проверки CLI | файл не найден → `File: X - not found.`; каталог arg2 не найден → `Directory: X - not found.` | InterpreterConsole/Program.cs:19,28 |
| `Builder` ctor | расширения: `BPProgram=".bp"`, `BPInclude=".bpi"`, `BPModule=".bpm"`, `LMSProgram=".lms"`; язык `ru` (консоль всегда RU) | Builder.cs:26-29,34 |
| `Data.Project.ModuleLibPath` | `arg2 + separator` | InterpreterConsole/Program.cs:35, Builder.cs:75 |
| `Data.Project.Path` | каталог main-файла + separator | InterpreterConsole/Program.cs:35, Builder.cs:76 |
| `Data.Project.MainName` | имя файла с расширением | Builder.cs:77 |
| `mainName` для препроцессора | имя БЕЗ расширения | Builder.cs:73,83 |
| IDE-вариант | `Builder.StartInterpreter(lines, path, name, appPath, mainExt, includeExt, moduleExt, pref, language, ...)` — расширения и префикс передаются параметрами, `ModuleLibPath = appPath` | Builder.cs:142-207 |

`Data.Project` — singleton со всеми полями (Project.cs:41-75). Ключевые для этапа:

| Поле | Тип | Смысл |
|---|---|---|
| `Main` | `Program` | main-файл: `Name`, `Path`, `Ext`, `Lines`, `OldText` (Program.cs:56-60) |
| `Includes` | `Dictionary<int, Include>` | ключ — **номер строки** include в main (Preprocessor.cs:91-92) |
| `Modules` | `Dictionary<string, Module>` | ключ — **lowercase имя модуля** (ImportErrorParser.cs:111) |
| `MainText` | `List<Line>` | main + include-контент после склейки |
| `MainFuncText`, `MainSubText` | `List<Line>` | функции/процедуры main, вырезанные из MainText |
| `ModuleMethodsText` | `List<Line>` | тела используемых методов модулей |
| `Functions`, `Subs` | `Dictionary<string, Function|Sub>` | ключи — **уже переименованные** имена |
| `Propertys` | `List<Line>` | сгенерированные строки инициализации `pr_*` |
| `Variables` | `Dictionary<string, Variable>` | все переменные (регистрация — VariableErrorParser.cs:652-662) |
| `Folder`, `ProjectName` | `string` | из директивы `folder` (Preprocessor.cs:77-78), дефолт `Folder="prjs"` (Project.cs:36) |
| `ModuleLibPath`, `Path`, `MainName`, `Type`, `IsFolder`, `BreakPoint` | — | см. выше/ниже |

Шаблоны: `Include` — Name (без расширения), Path, Ext, Lines, OldText (Include.cs:10-31); `Module` — то же + `Methods: Dictionary<string,(List<Line>,bool)>` и `Propertys: Dictionary<string,(Line,bool)>`, bool = private (Module.cs:17-18); `Line` — `Words`, `NewLine` (слова через пробел, Line.cs:25), `OldLine`, `OutLines`, `Number` (1-based), `FileName`, `Type` (Line.cs:41-52); `Word` — `Text`, `OriginText`, `Token` (Word.cs:16-28); `Function` — `Lines`, `Name`, `Parameters: Dictionary<string,(VariableType varType, ParameterType paramType)>` (Function.cs:14-19); `Sub` — только `Lines` (Sub.cs:11-16).

## 3. Разметка строк, нужная препроцессору

`LineBuilder.GetWords` (LineBuilder.cs:11-292): комментарий — всё от `'` (если `'` не в позиции 0; при `'` в позиции 0 строка становится пустой, LineBuilder.cs:18-31); строковые литералы `"..."` не режутся; одиночные спецсимволы разбиваются, но `string[`/`number[` склеиваются (LineBuilder.cs:112-121); `@` клеится со следующим словом (LineBuilder.cs:227-232); пары `<= >= <> ++ -- && || () {} []` склеиваются (LineBuilder.cs:146-232). Идентификаторы-слова (VARIABLE, SUBNAME, FUNCNAME, LABELNAME, LABEL) переводятся в **UPPERCASE** (LineBuilder.cs:251-255).

`TokenBuilder.GetToken` (TokenBuilder.cs:17-265), существенное:

| Условие | Токен |
|---|---|
| слово содержит `"` … `"` | STRING (TokenBuilder.cs:19-22) |
| слово == `#` | PREPROCESSOR (TokenBuilder.cs:23-26) |
| содержит `.` и не состоит из `[0-9.]`; первая часть входит в список встроенных классов (`assert, buttons, byte, ev3, ev3file, lcd, mailbox, math, motor, motora…motord, motorab…motorad, motorbc, motorbd, motorcd, program, row, sensor, sensor1-4, speaker, text, thread, time, vector`, TokenBuilder.cs:267-300) | METHOD (TokenBuilder.cs:33-36) |
| содержит `.`; первая часть не встроенный класс; следующее слово `(` или `()` | MODULEMETHOD (TokenBuilder.cs:40-41) |
| то же, но следующее слово не `(` | MODULEPROPERTY (TokenBuilder.cs:42-43) |
| список ключевых слов: `for endfor if then endif else elseif while endwhile and or sub endsub goto step to import include folder in out function endfunction number number[] string string[] private region endregion break continue return` | KEYWORD (TokenBuilder.cs:51) |
| в строке `Sub `…, предыдущее слово `sub`, слово `[0-9a-zA-Z_]+` | SUBNAME (TokenBuilder.cs:55-80) |
| в строке `Function `…, предыдущее слово `function` | FUNCNAME (TokenBuilder.cs:86-112) |
| в строке `Function`…, предыдущее слово `number|number[]|string|string[]`, слово `[A-Za-z][0-9a-zA-Z_]*` | VARIABLE (TokenBuilder.cs:115-118) |
| содержит `:` | LABEL (TokenBuilder.cs:126-129) |
| `[0-9a-zA-Z_]+`, следующее слово начинается с `(` | SUBNAME (TokenBuilder.cs:149-151, 239-241) |
| в строке есть `thread.run`, слово правее `=`, есть цифры в слове | SUBNAME (TokenBuilder.cs:153-163) |
| предыдущее слово `goto` | LABELNAME (TokenBuilder.cs:164-167) |
| `[0-9]+` | NUMBER; `@x` | VARIABLE (TokenBuilder.cs:130-173, 229-232) |

`LineBuilder.GetType` (LineBuilder.cs:295-424): `include→INCLUDE` (305), `folder→FOLDER` (309), `import→IMPORT` (313), `sub→SUBINIT` (317), `function→FUNCINIT` (321), `goto→LABELCALL` (341), `number|number[]|string|string[]→*INIT` (345-360), список `endfor endif endwhile endsub endfunction else private break continue return→ONEKEYWORD` (361), `LABEL→LABELINIT` (366), `METHOD→METHODCALL` (370), `SUBNAME→SUBCALL` (374), `FUNCNAME→FUNCCALL` (378), `MODULEMETHOD→MODULEMETHODCALL` (382), `MODULEPROPERTY→MODULEPROPERTY` (386), `VARIABLE`+`EQU/EQUMATH/DOUBLEMATH/BRACKETLEFTARRAY→VARINIT/VAREQUMATH/VARDOUBLEMATH/VARARRAYINIT` (390-411), `PREPROCESSOR→EMPTY` (413), нет слов → `EMPTY` (418-421).

**Следствия:** `#region`/`#endregion` дают первое слово `#` → EMPTY → строка исчезает из вывода. `'#main ../Program1` — строка-комментарий → EMPTY (директива используется только intellisense IDE, IntellisenseParser.cs:321; на компиляцию не влияет — проверено по коду).

## 4. Директива `include` (файлы .bpi)

Синтаксис в main .bp: ровно 2 слова: `include "имя"` — имя в кавычках (STRING).

| Проверка (IncludeErrorParser.Start, IncludeErrorParser.cs:16-56) | Ошибка |
|---|---|
| `line.Count == 1` (нет имени) | 1102 (IncludeErrorParser.cs:21) |
| `line.Count > 2` | 1103 (IncludeErrorParser.cs:26) |
| `Words[1].Token != STRING` | 1104 (IncludeErrorParser.cs:31) |
| файл `<полный путь>.bpi` не существует | 1101, Message = `<путь>.bpi` (IncludeErrorParser.cs:42-46) |

Алгоритм:
1. Полный путь: `CreateFullPath(Words[1].Text, Data.Project.Path)` — см. §6. База для `include` — **всегда каталог main-программы** (`Data.Project.Path`), даже если include стоит в .bpi… но include в .bpi запрещён (п.2).
2. Файл читается целиком (`File.ReadAllLines`), строки размечаются: `Number = i+1`, `FileName = <полный путь с .bpi>`, `Type = LineBuilder.GetType` (IncludeErrorParser.cs:162-167).
3. Внутри .bpi **запрещено**: `include` → 1105 (IncludeErrorParser.cs:171), `folder` → 1106 (IncludeErrorParser.cs:177). Т.е. вложенные include невозможны — это и есть защита от циклов include.
4. **Разрешено**: `import "..."` внутри .bpi — обрабатывается сразу через `ImportErrorParser.Start(line, <каталог .bpi>)` (IncludeErrorParser.cs:181-186): относительные пути import внутри .bpi резолвятся от каталога самого .bpi.
5. Каждая строка .bpi проверяется скобочным парсером (BracketErrorParser.cs:12-57; ошибки 1001/1002), затем добавляется в `Lines`/`OldText` (IncludeErrorParser.cs:189-194).
6. Результат — `Include(name, path, lines, oldText)`, ключ в `Data.Project.Includes` — номер строки include в main (Preprocessor.cs:89-92). Дедупликации нет: два `include` одного файла на разных строках → контент вставляется дважды.

## 5. Директива `import` (модули .bpm)

Синтаксис: ровно 2 слова `import "имя"`. Проверки (ImportErrorParser.Start, ImportErrorParser.cs:18-124): `count==1` → 2002 (23), `count>2` → 2003 (27), не STRING → 2004 (31), файл `.bpm` не найден → 2001, Message = `<путь>.bpm` (75).

Алгоритм загрузки модуля (ImportErrorParser.cs:33-123):
1. `fullPath = CreateFullPath(<имя без кавычек>, NewCallPath)`; `NewCallPath` — статическое поле: при старте препроцессора = каталог main (Preprocessor.cs:19), после каждого успешного import = каталог загруженного модуля (ImportErrorParser.cs:60). Так **вложенные import резолвятся от каталога импортирующего файла**.
2. `name = GetImportName` (имя файла без .bpm), `path = GetImportPath` (каталог + separator; оба через `FileInfo`, ImportErrorParser.cs:126-146).
3. Если `Data.Project.Modules` уже содержит `name.ToLower()` — **модуль молча пропускается** (ImportErrorParser.cs:79). Это же — защита от циклов: модуль добавляется в словарь (строка 111) **до** рекурсивной обработки его собственных import (строки 113-121), поэтому `import` самого себя или взаимные import не зацикливаются.
4. Текст читается, строки размечаются (`FileName = <полный путь .bpm>`, ImportErrorParser.cs:158-162), строки `IMPORT` и `EMPTY` **удаляются** из списка модуля (ImportErrorParser.cs:86-93).
5. Контент модуля валидируется (см. таблицу ниже), затем создаются: `Module`, реестр свойств (`ParseModulePropertys`), реестр методов (`ParseModule`), переименование (`RenameModleMethodsAndPropertys`).

Валидация содержимого .bpm (`GetAllLines`, ImportErrorParser.cs:148-277 + `ModuleErrorParser.Start`, ModuleErrorParser.cs:12-91):

| Правило | Ошибка | Ссылка |
|---|---|---|
| `include` в модуле | 2005 | ImportErrorParser.cs:166; ModuleErrorParser.cs:50 |
| `folder` в модуле | 2006 | ImportErrorParser.cs:171; ModuleErrorParser.cs:55 |
| `Sub`/`EndSub` в модуле | 2007 | ImportErrorParser.cs:201; ModuleErrorParser.cs:45 |
| вложенный `Function` / `endfunction` без начала / незакрытая `Function` (до EOF) | 1026 / 1027 / 1028 | ImportErrorParser.cs:178,191,272 |
| объявление свойства внутри функции | 2015 | ImportErrorParser.cs:220 |
| объявление свойства не из 2 слов | 2011 | ImportErrorParser.cs:227 |
| первое слово не KEYWORD/VARIABLE | 2012 | ImportErrorParser.cs:233 |
| тип не из `number, number[], string, string[]` | 2013 | ImportErrorParser.cs:239 |
| дубликат имени свойства | 2014 | ImportErrorParser.cs:245 |
| любой другой оператор **вне** функции (кроме EMPTY, IMPORT, комментария `'…`, ONEKEYWORD) | 2008 | ImportErrorParser.cs:255-258 |
| `private` с чем-то ещё в строке | 2016 | ModuleErrorParser.cs:64 |
| нераспознанная строка (NON) | 1032 | ModuleErrorParser.cs:75 |
| дубликат zero-арг функции | 1809 | ModuleErrorParser.cs:123-127 |
| скобочный баланс каждой строки | 1001/1002 | ImportErrorParser.cs:263 |

Прочее допустимое в .bpm: `private` (одно слово, ONEKEYWORD), определения `Function … EndFunction`, объявления свойств `number x` / `number[] x` / `string x` / `string[] x` (строка типа `*INIT` переквалифицируется в `LineType.MODULEPROPERTY`, ImportErrorParser.cs:204-206), комментарии, пустые строки, import других модулей.

### 5.1 Реестры модуля

**Свойства** (`ParseModulePropertys`, ImportErrorParser.cs:279-301): ключ = `<module.Name.ToLower()>_<Words[1].ToLower()>`, значение = (строка объявления, private). Флаг `private` — «липкий»: включается строкой `private` и **не выключается до конца файла** (нет слова `public`), ImportErrorParser.cs:286-289 и 314-317.

**Методы** (`ParseModule`, ImportErrorParser.cs:303-362): ключ = `<Words[1].ToLower()>_<GetParamCount(line)>` — **без префикса модуля** (ImportErrorParser.cs:330); значение = (строки тела от FUNCINIT до endfunction включительно, private). Дубликат метода с ≥1 параметром **молча пропускается** (`if (!module.Methods.ContainsKey(name))`, ImportErrorParser.cs:340); ошибка 1809 выдаётся только за дубликат zero-арг функции (ModuleErrorParser.cs:121-131). Перед добавлением: имена параметров FUNCINIT не должны совпадать с именами свойств модуля → 2019 (`ParsePropertyInFuncInit`, ModuleErrorParser.cs:605-620).

Полная проверка параметров FUNCINIT в модуле — `ModuleErrorParser.ParseFuncInit` (ModuleErrorParser.cs:93-426), конечный автомат `vars` 0→1(in/out)→2(тип)→3(имя); типы: `number→NUMBER, number[]→NUMBER_ARRAY, string→STRING, string[]→STRING_ARRAY`; ошибки: 1801 (count<3 / пустой заголовок), 1803 (нет FUNCNAME), 1802 (нет скобок), 1809 (дубль zero-arg), 1810 (дубль параметра), 1811 (два подряд параметра без запятой), 1812 (запятая без переменной), 1813 (после in/out не тип), 1814 (нет типа), 1816 (тип без in/out), 1817 (после типа не имя), 1818 (переменная без in/out+типа), 1819 (тип не определён), 1804 (неизвестное ключевое слово), 1805 (лишний токен), 1822 (`@var` в параметрах).

### 5.2 Переименование внутри модуля (до линковки)

`RenameModleMethodsAndPropertys` (ImportErrorParser.cs:364-426):

| Что | Становится | Ссылка |
|---|---|---|
| VARIABLE-слово, совпадающее со свойством модуля (ключ `<mod>_<name>`) | Token=`MODULEPROPERTY`, Text=`<mod>_<name>` (lowercase) | ImportErrorParser.cs:375-383 |
| MODULEPROPERTY с точкой | точки → `_` | ImportErrorParser.cs:385-389 |
| строки SUBCALL/FUNCCALL | `Type=MODULEMETHODCALL`, слово → Token=`MODULEMETHOD`, Text=`<Module.Name>.<имя>` (регистр Module.Name оригинальный) | ImportErrorParser.cs:393-408 |
| FUNCNAME в FUNCINIT | Text=`<Module.Name>_<имя>` | ImportErrorParser.cs:410-424 |

После этого модуль (`Module`) кладётся в `Data.Project.Modules[<name.ToLower()>]` (ImportErrorParser.cs:111) и рекурсивно обрабатываются его import-строки (ImportErrorParser.cs:113-121).

## 6. Пути: `CreateFullPath`, moduleLibPath, поведение при ошибке

Алгоритм одинаков у include- и import-парсеров (различие — подкаталог библиотеки):
`ImportErrorParser.CreateFullPath` (ImportErrorParser.cs:473-547), `IncludeErrorParser.CreateFullPath` (IncludeErrorParser.cs:80-154).

Псевдокод (все пути нормализуются: кавычки срезаются, trim, `\` и `/` → разделитель платформы):

```
fileName = часть name после последнего separator (или весь name)   # ImportErrorParser.cs:479-487
если name начинается с "Clev3r://" или "Clever://" (separator-зависимо!):
    base = Data.Project.ModuleLibPath
    rest = name после схемы, заменённой на "Lib"+sep+"Modules"+sep   # import (ImportErrorParser.cs:491-499)
                                     или "Lib"+sep+"Includes"+sep    # include (IncludeErrorParser.cs:98-107)
    return collapse("//", base + rest)                               # без fileName-логики
иначе:
    segs = name без пустых сегментов
    если segs.count > 1:
        down = число начальных сегментов ".."; nextPath = остальные сегменты + sep
        если down > 0: fullPath = первые (count(mainPathSegs) - down) сегментов mainPath + nextPath
        иначе:         fullPath = mainPath + sep + nextPath
    иначе: fullPath = mainPath + sep
    срезать все завершающие separator'ы fullPath
    return collapse("//", fullPath + sep + fileName)
```

| Случай | mainPath (база) | Пример (Linux, sep=`/`) | Результат |
|---|---|---|---|
| include из main | `Data.Project.Path` | `include "SensorRGB"`, Path=`/p/` | `/p/SensorRGB.bpi` |
| include с подпапкой | `Data.Project.Path` | `include "Includes/Include1"` | `/p/Includes/Include1.bpi` |
| import из main | `NewCallPath` = каталог main | `import "Modules/Module2"` | `/p/Modules/Module2.bpm` |
| import из .bpi | каталог .bpi | `import "../Modules/Module1"` из `/p/Includes/` | down=1 → `/p/Modules/Module1.bpm` (проверено на corpus New_Path_Examples) |
| import из .bpm | каталог родительского модуля (NewCallPath) | `import "Module1"` из `/p/Modules/` | `/p/Modules/Module1.bpm` |
| библиотечный | `ModuleLibPath` | `import "Clev3r://Foo"` | `<lib>/Lib/Modules/Foo.bpm` |
| библиотечный include | `ModuleLibPath` | `include "Clev3r://Foo"` | `<lib>/Lib/Includes/Foo.bpi` |

Особенности:
- `..` учитывается только как **начальные** сегменты имени; `..` в середине попадает в путь буквально (`A/../B` останется `A/../B`, разрешит файловая система) (ImportErrorParser.cs:510-521).
- Если `down` превышает глубину mainPath, цикл копирования не выполнится и путь станет относительным (ImportErrorParser.cs:522-529) — (гипотеза: приведёт к 2001/1101).
- Схема проверяется как `"Clev3r:" + sep + sep` — на Linux `Clev3r://`, на Windows `Clev3r:\\` (ImportErrorParser.cs:491-498) — платформозависимый квирк.
- Ненайденный файл: `GetImportPath/GetImportName` возвращают `""` → `tmpPath = name + ".bpm"` → `FileInfo.Exists == false` → ошибка 1101/2001, Message = ожидаемый полный путь с расширением (ImportErrorParser.cs:64-77, IncludeErrorParser.cs:42-46). Ошибки **фатальные** — конвейер останавливается.
- Повторный import модуля с тем же lowercase-именем (в т.ч. из другого каталога) — молча игнорируется (ImportErrorParser.cs:79).

## 7. Порядок работы Preprocessor

`Preprocessor.Start(mainName, mainPath, mainText)` (Preprocessor.cs:15-46):

| Шаг | Метод | Что делает | Ссылка |
|---|---|---|---|
| 0 | — | `MethodErrorParser.MediaLines = {}` (сброс реестра медиа-строк, см. док по builtins); `ImportErrorParser.NewCallPath = mainPath`; создаётся `Program` (все строки размечаются, `FileName = Path + Name + Ext`, Program.cs:29-35); `Data.Project.Main = program`; `DefaultObjectList.Install()` (словарь встроенных методов/свойств, DefaultObjectList.cs:12-14) | Preprocessor.cs:17-25 |
| 1 | `FirstFindFiles` | по всем строкам main: скобочный баланс (55); INCLUDE → `ParseInclude` (§4); IMPORT → `ImportErrorParser.Start(line, Data.Project.Path)` (97); FOLDER → `FolderErrorParser.Start` + `Data.Project.Folder = Words[1] без кавычек`, `ProjectName = Words[2] без кавычек` (77-78) | Preprocessor.cs:48-81 |
| 2 | `ParseStruct` | `StructErrorParser.Start` для main (107) и каждого include (113) — стеки структур if/for/while/sub/function; блок для модулей закомментирован (118-125) | Preprocessor.cs:105-126 |
| 3 | `ParseNames` | `StructErrorParser.ParseNames` для main (130), всех include (136), всех модулей (143) — уникальность sub/function/label | Preprocessor.cs:128-147 |
| 4 | `Linker.Start()` | §8 | Preprocessor.cs:43 |

После каждого шага — `if (Data.Errors.Count > 0) return;`. Модули, загруженные при import внутри .bpi (шаг 1) и внутри .bpm, к шагам 2-3 по include-ветке не попадают (их структура проверена при загрузке).

### 7.1 Проверки структур (StructErrorParser.Start, StructErrorParser.cs:13-496)

Три независимых стека (main/sub-контекст/function-контекст), элементы `(номерСтроки, ожидаемое END-слово, fileName)`. `if/for/while` кладут `endif/endfor/endwhile`; `sub`/`function` — флаги. Несоответствие END-слова ожидаемому → 1003/1005/1007 (по типу последнего открытого `tmpStruct`: 1=if, 2=for, 3=while); END без начала → 1004/1006/1008; вложенный `sub` → 1009; `endsub` без `sub` → 1010; незакрытые к EOF: sub → 1011, function → 1028, стеки → 1012/1013/1014 (StructErrorParser.cs:458-495). Служебные END-слова должны стоять в одиночестве: `endif→1015, endfor→1016, endwhile→1017, endsub→1018, endfunction→1029, else→1019` (StructErrorParser.cs:41-48, 594-620); `goto` — ровно 2 слова, без `:` → 1020 (50-62); строка метки — ровно 1 слово → 1021 (410-416); взаимные вложения: `sub` в `function` → 1030 (318), `function` в `sub` → 1031 (350), `endsub` в `function` → 1031 (338), `endfunction` в `sub` → 1030 (375), `function` в `function` → 1026 (355).

### 7.2 Уникальность имён (StructErrorParser.ParseNames, StructErrorParser.cs:757-918)

Вызывается **отдельно для каждого файла** (main, каждый .bpi, каждый .bpm) — уникальность соблюдается внутри файла, между файлами коллизии имён функций/субов допустимы (разруливаются префиксами/раскрытием).

| Правило | Ошибка | Ссылка |
|---|---|---|
| SUBINIT: слов 1 (нет имени) / 2-е слово не SUBNAME / слов >2 | 1603 / 1602 / 1601 | 780/785/790 |
| имя суба уже было | 1607 | 810 |
| имя суба совпало с именем функции | 1809 | 800 |
| FUNCINIT: слов 1 / 2-е не FUNCNAME / слов 2 (нет скобок) / последнее не `)` и не `()` | 1803 / 1805 / 1801 / 1802 | 820/825/830/835 |
| ключ функции = `Words[1].ToLower() + <paramcount>`; дубль ключа | 1809 | 839-857 |
| ключ функции совпал с субом | 1607 | 846 |
| метка (ключ `имя*текущаяФункция`): дубль вне функции / внутри | 1025 / 1024 | 872/877 |
| `goto` на несуществующую метку (вне функции / внутри) | 1036 / 1035 | 904/899 |
| метка без goto — НЕ ошибка | — | 914-917 |

## 8. Linker

`Linker.Start()` (Linker.cs:17-78) — последовательность шагов, каждый с проверкой ошибок:

### 8.1 AddIncludesToMain (Linker.cs:283-308)

Идём по строкам `Data.Project.Main.Lines`; `EMPTY`, `IMPORT`, `FOLDER` — выбрасываются (289); строка, являющаяся INCLUDE-местом (номер есть в `Includes`), заменяется на все строки .bpi, кроме `EMPTY` и `IMPORT` (297-304; условие `mLine.Type != LineType.FOLDER` на строке 300 всегда истинно — мёртвый код). Остальные строки копируются как есть. Результат — `Data.Project.MainText`. (FOLDER/IMPORT в output не попадают — проверено на ~Program1.bp.)

### 8.2 ParsePrivate (Linker.cs:860-960)

Проверка доступа к приватным членам модулей:
- В `MainText`: слово `MODULEPROPERTY` → ключ `GetModuleName(word)_GetMethodName(word)` (деление по первой точке, Linker.cs:80-98); если модуль существует и свойство private (`module.Propertys[key].Item2`) → **2017** (Linker.cs:883). Слово `MODULEMETHOD` → ключ `method + "_" + GetParamCount(line)`; приватный метод из main → **2018** (Linker.cs:901). Несуществующий модуль здесь молча пропускается.
- В текстах самих модулей: то же, но доступ к чужому модулю (`modName != tmpName`, Linker.cs:926/944) — обращение модуля к приватному свойству/методу другого модуля → 2017/2018. Обращение к своим приватным — разрешено.

### 8.3 Сбор вызовов методов модулей

`ParseModuleMethodsInMain` (Linker.cs:249-281): все слова `MODULEMETHOD` в MainText → `_modulesCalling[module.ToLower()].Add(method.ToLower() + "_" + GetParamCount(line))`; модуль = текст до первой точки, метод = после (Linker.cs:262-263).

`ParseModuleMethodsInModules(_modulesCalling, tmpCalling)` (Linker.cs:145-247) — рекурсивное замыкание: новые вызовы ищутся в `module.Methods` (ключ уже `method_paramcount`); найденные тела (списки строк) **добавляются в `Data.Project.ModuleMethodsText`** (Linker.cs:186-192); затем внутри добавленных строк ищутся слова `MODULEMETHOD` → новый набор вызовов → рекурсия (Linker.cs:199-236). `IsAdded` (Linker.cs:310-322) отсекает уже собранные вызовы. Если модуль вызван, но не импортирован — ветка else **пустая** (Linker.cs:241-245): ошибки нет на этом шаге; вызов ловится позже как 1806 (§9.2). Каждый метод добавляется в ModuleMethodsText **один раз** (tmpCalling).

### 8.4 Переименование FuncRename (Linker.cs:324-446)

Префиксы: `funcPref = "f_"`, `metPref = "m_"` (Linker.cs:329-330). Новое слово: `<префикс> + <текст> + "_" + GetParamCount(line)`, всё `.ToLower()`; затем `line.NewLine = join(" ", Words[].Text)`.

| Контекст (лист) | LineType | Токен слова | Новое имя | Ссылка |
|---|---|---|---|---|
| MainText | MODULEMETHODCALL | MODULEMETHOD | `m_<module>_<method>_<N>` (точки → `_`) | Linker.cs:344 |
| MainText | FUNCCALL, FUNCINIT | FUNCNAME | `f_<name>_<N>` | Linker.cs:359 |
| MainText | SUBCALL, SUBINIT | SUBNAME | `f_<name>_<N>` (процедуры получают f_) | Linker.cs:374 |
| MainText | METHODCALL (`thread.run = X`) | SUBNAME | `f_<name>_<N>` | Linker.cs:389 |
| ModuleMethodsText | MODULEMETHODCALL | MODULEMETHOD | `m_<module>_<method>_<N>` | Linker.cs:409 |
| ModuleMethodsText | FUNCINIT | FUNCNAME | `m_<module>_<method>_<N>` (текст уже `<Module>_<name>` с §5.2) | Linker.cs:424 |
| ModuleMethodsText | METHODCALL | SUBNAME | `f_<name>_<N>` | Linker.cs:439 |

`GetParamCount(line)` (Linker.cs:100-143): `comma = -1`, если первое слово `sub` или `thread.run` (`f.start` закомментирован, Linker.cs:108); слово `()` при глубине 0 → вернуть 0; скобки `(`/`)` меняют глубину; запятая на глубине 1 → `comma++`; результат `comma >= 0 ? comma + 1 : 0`. Примеры: `map_data(in number n, out number data)` → 2; `Foo()` → 0; `Sub Foo` → 0; `Foo(a,b,c)` → 3. Несовпадение числа аргументов вызова с определением → разные mangled-имена → вызов не найдётся → 1806.

Копия того же алгоритма в ImportErrorParser.cs:428-471 **дополнительно** считает `f.start` как `sub` (ImportErrorParser.cs:436) — расхождение с Linker.

### 8.5 Переименование переменных и меток VarsAndLabelsRename (Linker.cs:448-622)

Префиксы (Linker.cs:455-462): `gv_` (глобальные переменные), `gl_` (глобальные метки), `pr_` (свойства), `lv_`/`ll_` (локальные переменные/метки), счётчики `localVarsPrefNumber`/`localLabelsPrefNumber` стартуют с 0 и инкрементируются на **каждом** FUNCINIT (Linker.cs:475-476, 551-552), т.е. первая функция даёт суффикс `_1`. Счётчики **общие** для main-прохода и прохода по ModuleMethodsText (нумерация сквозная).

| Контекст | Слово | Результат | Ссылка |
|---|---|---|---|
| MainText, вне функции | VARIABLE | `gv_<имя>`, `@` срезается, lowercase | Linker.cs:490 |
| MainText, в функции, без `@` | VARIABLE | `lv_<имя>_<N>` | Linker.cs:496 |
| MainText, в функции, с `@` | VARIABLE | `gv_<имя>` (ссылка на глобальную) | Linker.cs:500 |
| MainText | LABEL (метка с `:`) | `gl_<имя>:` (вне ф.) / `ll_<имя>_<N>` (в ф.) | Linker.cs:508,514 + 522-526 |
| MainText | LABELNAME (goto-цель) | `gl_<имя>` / `ll_<имя>_<N>` | Linker.cs:508,514 |
| MainText | MODULEPROPERTY | в `_propertys[name]` кладётся строка; Token→VARIABLE; Text=`pr_<module>_<prop>` (точки → `_`) | Linker.cs:528-537 |
| ModuleMethodsText | VARIABLE с `@` | **ошибка 2009** | Linker.cs:567 |
| ModuleMethodsText, вне функции | VARIABLE | **ошибка 2008** | Linker.cs:574 |
| ModuleMethodsText, в функции | VARIABLE | `lv_<имя>_<N>` | Linker.cs:579 |
| ModuleMethodsText | LABEL/LABELNAME с `@` или вне функции | **ошибка 2008** (не 2010!) | Linker.cs:587,594 |
| ModuleMethodsText, в функции | LABEL/LABELNAME | `ll_<имя>_<N>` | Linker.cs:599 |
| Оба листа | MODULEPROPERTY | как выше, `pr_` | Linker.cs:608-617 |

`endfunction`-строки при этом пропускаются через `continue` (Linker.cs:478-482, 554-558) — их NewLine не пересобирается. После прохода `line.NewLine` пересобирается из слов (Linker.cs:540, 620).

### 8.6 Вырезание функций и процедур из main

`RemoveMainFunc` (Linker.cs:624-660): блоки `FUNCINIT … endfunction` переносятся из MainText в `MainFuncText` (FUNCINIT и endfunction включаются, endfunction добавляется отдельно, Linker.cs:640). `RemoveMainSub` (Linker.cs:662-698): `SUBINIT … endsub` → `MainSubText`. Выполняются последовательно: функции, затем субы.

### 8.7 Словари и свойства (Linker.cs:700-858)

- `CreateFunctionsDicionary(MainFuncText)` и `(ModuleMethodsText)` (Linker.cs:700-742): ключ — FUNCNAME-слово (уже mangled: `f_...`/`m_...`), значение `Function(name, Lines)`; словари **общие** (`Data.Project.Functions`).
- `CreateSubsDicionary(MainSubText)` (Linker.cs:744-786): ключ — SUBNAME (mangled `f_...`), `Data.Project.Subs`.
- `CreateCallingPropertyLines` (Linker.cs:788-858): для каждого использованного свойства (`_propertys`, ключ `<module>_<prop>`) ищется объявление в `module.Propertys` всех модулей; не найдено → **2020** (Linker.cs:855). Найдено — генерируется строка инициализации в `Data.Project.Propertys` по типу (Linker.cs:814-848):

| Тип объявления (`Words[0]` definition) | Строка инициализации | LineType | VariableType |
|---|---|---|---|
| `number` | `pr_<module>_<prop> = 0` | VARINIT | NUMBER |
| `number[]` | `pr_<module>_<prop> [ 0 ] = 0` | VARARRAYINIT | NUMBER_ARRAY |
| `string` | `pr_<module>_<prop> = ""` | VARINIT | STRING |
| `string[]` | `pr_<module>_<prop> [ 0 ] = ""` | VARARRAYINIT | STRING_ARRAY |

Первое слово — `pr_ + definitionLine.Words[1].ToLower()` (к моменту вызова это уже переименованное `<module>_<prop>`, см. §5.2 — проверено по порядку вызовов ImportErrorParser.cs:101→110). Строка получает `Number/FileName` строки-объявления модуля (Linker.cs:848); в `Data.Project.Variables` регистрируется `"pr_" + ключ` (Linker.cs:850-851).

## 9. Фаза Interpreter (формирование развёрнутого исходника)

### 9.1 Порядок секций вывода

`CreateProjectOutputLines` (Interpreter.cs:345-446) — итоговый `Data.Project.OutputLines`:

| # | Секция | Источник |
|---|---|---|
| 1 | Строки `pr_*` | `Data.Project.Propertys` |
| 2 | Инициализации переменных | `varInit` = `FuncVariablesInit` (врем. параметры функций, Interpreter.cs:448-487) + `OtherVarsAddToMain` (все переменные из `Data.Project.Variables`, у которых `Line != null`; свойства `pr_*` пропускаются, Interpreter.cs:613-616, 606-652) |
| 3 | Тело main | `MainText` |
| 4 | Процедуры | `MainSubText` |
| 5 | Функции | `MainFuncText` |
| 6 | Методы модулей | `ModuleMethodsText` |

Каждая строка выводится через `OutLines` (сгенерированные под-строки), если они есть, иначе `NewLine` (Interpreter.cs:355-367 и аналог для всех секций). Регистрация переменных в `Data.Project.Variables` происходит при разборе main-строк `SubVarsInit` (Interpreter.cs:538-604 → VariableErrorParser.cs:652-662) и при регистрация выходных параметров вызовов (Interpreter.cs:278-281) — **порядок init-строк = порядок вставки в словарь** (проверено на Program1: `gv_d1, gv_d2` из out-параметров раньше `gv_d1_min…` из main-строк).

### 9.2 Разрешение вызовов и ошибки

`ParseAllCalls/ParseFirstCall` (Interpreter.cs:654-754): для каждой строки SUBCALL/FUNCCALL/MODULEMETHODCALL первое слово (mangled) ищется в `Subs`, затем в `Functions`; не найдено → SUBCALL: `count > 2 ? 1806 : 1606` (Interpreter.cs:705,710), FUNCCALL/MODULEMETHODCALL → 1806 (Interpreter.cs:720). `thread.run = X`: форма `thread.run = SUBNAME` иначе 1414 (Interpreter.cs:730-734); неизвестный суб → 1606 (Interpreter.cs:747). Строки SUBINIT без последующих вызовов **удаляются** из вывода `RewriteOutLines` (Interpreter.cs:756-788).

Развёртка вызова функции с параметрами (`ParseOneCall`, Interpreter.cs:200-343): для вызова из `Data.Project.Functions` — каждый INPUT-параметр → строка `VARINIT <ключПараметра> = <аргумент>` в `OutLines` **до** вызова (Interpreter.cs:226-244); OUTPUT-параметр — единственный аргумент должен быть VARIABLE (иначе 1405, Interpreter.cs:264; допускается также элемент массива `<var>[i]`, Interpreter.cs:293-317); после вызова строка `VARINIT <аргумент> = <ключПараметра>` (Interpreter.cs:268-291). Сам вызов — строка `SUBCALL` из первого слова (Token сменяется на SUBNAME) + `()` (Interpreter.cs:249-258, 325-337).

### 9.3 Заголовки функций/модульных методов

`ParseFuncInitLine` (Interpreter.cs:125-174): строка FUNCINIT листов `MainFuncText`/`ModuleMethodsText` проверяется `FunctionsInitErrorParser.FuncInitLineParse` (FunctionsInitErrorParser.cs:16-384 — тот же конечный автомат параметров, что §5.1, но для main: коды 1801-1805, 1810-1819, 1822, плюс 1806 если функции нет в словаре, FunctionsInitErrorParser.cs:43) и заменяется в `OutLines` на `Sub <mangled FUNCNAME>` (Interpreter.cs:137-141); `endfunction` → `EndSub` (Interpreter.cs:143-149). Типы параметров заполняют `Function.Parameters` (FunctionsInitErrorParser.cs:270-298).

### 9.4 Прочее, влияющее на ~Name.bp

- `break`/`continue`/`return` превращаются в `Goto <jumpWord>_<K>` + метку `<jumpWord>_<K>:` у end-строки (LineErrorParser.cs:205-271; счётчик `Data.Project.BreakPoint`). Эти метки **не получают** `gl_`-префикс (создаются после VarsAndLabelsRename) — квирк.
- Строки меток goto-проверок и прочие грамматические проверки — см. док «диагностики».

## 10. Выходной файл `~Name.bp` и файлы сборки

| Файл | Имя | Ссылка |
|---|---|---|
| Каталог вывода | `Path.Combine(Data.Project.Path, _outFolder)`, создаётся при отсутствии; `_outFolder = "<prefix>" + MainName без ".bp"`; в CLI `prefix = "~"` (захардкожен) | Builder.cs:79, 366-370, 454-458 |
| Развёрнутый исходник | `<prefix> + MainName` → `~Program1.bp` | Builder.cs:460 |
| Листинг | `MainName.Replace(".bp", ".lmsb")` → `Program1.lmsb` | Builder.cs:379 |
| Бинарник | `…Replace(".bp", ".rbf")` → `Program1.rbf` | Builder.cs:425 |

Содержимое ~.bp (Builder.GetOutFile, Builder.cs:486-506): для каждой `OutputLines`-строки — `OutLines[i].NewLine`, иначе `NewLine`; каждая пишется `writer.WriteLine` (Builder.cs:327-343). Формат строк: слова через **один пробел** (`Line.NewLine`, Line.cs:25); комментарии отсутствуют (срезаны лексером); регистр: исходные имена — UPPERCASE (лексер) → финальные mangled-имена — lowercase; кавычки строковых литералов сохраняются (`While "True"`); метод-вызов сохраняет точку внутри первого слова и отделяет `()` пробелом (`LCD.Clear ()`). Кодировка — UTF-8 без BOM, разделитель строк — платформенный, завершающий перевод строки после последней строки **(гипотеза: дефолты .NET StreamWriter; текст файла это косвенно подтверждает)**.

Сквозной пример `/home/ssssq/Windows/Program1.bp` → `~Program1/~Program1.bp` (проверено):
- `folder "prjs" "test123"` → исчезает (данные в `Project.Folder/ProjectName`);
- `d1_min` → `gv_d1_min`; `@d1_min` внутри функции → `gv_d1_min`; `n`/`data` → `lv_n_1`/`lv_data_1`;
- `Function map_data(in number n, out number data)` → `Sub f_map_data_2`, `EndFunction` → `EndSub`; вызовы `map_data(2, d1)` → `lv_n_1 = 2` + `f_map_data_2 ()` + `lv_data_1 = d1` → `d1 = lv_data_1` (аргумент — переменная);
- init-строки в начале: сначала `lv_n_1 = 0`, `lv_data_1 = 0` (врем. параметры), затем `gv_…` в порядке регистрации;
- `.lmsb` 5505 б, `.rbf` 1015 б — вне этого документа.

## 11. Коды ошибок этапа (тексты SetRU, ErrorsCodeList.cs:19-202)

| Коды | Текст (RU) | Где генерируется |
|---|---|---|
| 1001 | Лишняя скобка | BracketErrorParser.cs:44,52 |
| 1002 | Неправильно закрыты скобки | BracketErrorParser.cs:38 |
| 1003/1005/1007 | Неправильно закрыта структура IF/FOR/WHILE | StructErrorParser.cs:121-125 и аналог |
| 1004/1006/1008 | У структуры IF/FOR/WHILE нет начала | StructErrorParser.cs:130,196,262 |
| 1009 | Структура SUB не может содержать в себе другую структуру SUB | StructErrorParser.cs:313 |
| 1010 | У структуры SUB нет начала | StructErrorParser.cs:333,370 |
| 1011 | Структура SUB не закрыта | StructErrorParser.cs:460 |
| 1012/1013/1014 | Структура IF/FOR/WHILE не закрыта | StructErrorParser.cs:470-474 |
| 1015/1016/1017/1018/1019/1029 | Недопустимый код, должно быть только слово EndIf/EndFor/EndWhile/EndSub/Else/EndFunction | StructErrorParser.cs:594-620 |
| 1020 | Недопустимый код, должно быть только goto и имя метки без двоеточия | StructErrorParser.cs:54-61 |
| 1021 | Недопустимый код, должно быть только имя метки и двоеточие | StructErrorParser.cs:412-415 |
| 1024/1025 | Метка с таким именем уже определена в данной функции/программе | StructErrorParser.cs:877/872 |
| 1026 | Структура FUNCTION не может содержать другую FUNCTION | ModuleErrorParser.cs:33; ImportErrorParser.cs:178; StructErrorParser.cs:355 |
| 1027 | У структуры FUNCTION нет начала | ImportErrorParser.cs:191 |
| 1028 | Структура FUNCTION не закрыта | ImportErrorParser.cs:272; StructErrorParser.cs:464 |
| 1030/1031 | SUB не может содержать FUNCTION / FUNCTION не может содержать SUB | StructErrorParser.cs:318,375 / 338,350 |
| 1032 | Строка не распознана | ModuleErrorParser.cs:75; LineErrorParser.cs:110 |
| 1035/1036 | Метка с таким именем не найдена в функции/программе | StructErrorParser.cs:899/904 |
| 1101 | Файл не найден | IncludeErrorParser.cs:45 |
| 1102 | Отсутствует имя подключаемого файла | IncludeErrorParser.cs:21 |
| 1103 | Неверное количество параметров | IncludeErrorParser.cs:26 |
| 1104 | Имя файла должно быть в виде строки | IncludeErrorParser.cs:31 |
| 1105 | Включаемые файлы не могут содержать своих включений | IncludeErrorParser.cs:171 |
| 1106 | Включаемые файлы не могут содержать ключевое слово folder | IncludeErrorParser.cs:177 |
| 1201-1208 | (folder) неверное число параметров / параметры-строки / первый параметр «prjs» или «sd» / >32 символов / пустое имя / начинается с буквы / только `[0-9a-zA-Z_]` / folder может быть только один раз | FolderErrorParser.cs:26,31,36,44,49,59,68,16 |
| 1209/1210 | folder нельзя в модулях / folder должен быть до основного кода | определены, но на этом этапе не используются (гипотеза: только IDE) |
| 1601/1602/1603 | Неверное определение процедуры / должно быть Sub и имя / отсутствует имя | StructErrorParser.cs:790/785/780 |
| 1606 | Процедура не найдена | Interpreter.cs:710,747 |
| 1607 | Процедура с таким именем уже определена | StructErrorParser.cs:810,846 |
| 1801/1802/1803/1804/1805 | Неверное определение функции / отсутствуют скобки / отсутствует имя / недопустимые ключевые слова / недопустимые выражения | ModuleErrorParser.cs:103,115,109,339,402; FunctionsInitErrorParser.cs:28,52,34,240,364; StructErrorParser.cs:830,835,820,825 |
| 1806 | Функция не найдена | Interpreter.cs:705,720; FunctionsInitErrorParser.cs:43,266 |
| 1809 | Функция с таким именем и количеством параметров уже определена | ModuleErrorParser.cs:125; StructErrorParser.cs:800,856 |
| 1810 | В определении функции есть переменные с одинаковыми именами | ModuleErrorParser.cs:168; FunctionsInitErrorParser.cs:276,296 |
| 1811-1819 | грамматика параметров (см. §5.1): 1811 два параметра без запятой, 1812 запятая без переменной, 1813 после in/out не тип, 1814 нет типа, 1816 тип без in/out, 1817 после типа не имя, 1818 переменная без in/out+типа, 1819 тип не определён | ModuleErrorParser.cs:201, 395, 191, 364, 244, 196, 359, 351; FunctionsInitErrorParser.cs:92-383 |
| 1820/1821/1822 | Параметр имеет другой тип / выходной параметр может быть только переменной / `@var` в параметрах | (1820/1821 — фаза компилятора, закомментированы); 1822: ModuleErrorParser.cs:156; FunctionsInitErrorParser.cs:251 |
| 2001 | Файл не найден | ImportErrorParser.cs:75 |
| 2002/2003/2004 | Отсутствует имя импортируемого файла / неверное количество параметров / имя должно быть строкой | ImportErrorParser.cs:23/27/31 |
| 2005/2006/2007 | В .bpm недопустимы include / folder / определение процедур | ImportErrorParser.cs:166/171/201 |
| 2008 | В .bpm допустимы только определения функций и свойств | ImportErrorParser.cs:257; ModuleErrorParser.cs:86; Linker.cs:574,587,594 |
| 2009 | Нельзя использовать ссылки на глобальные переменные в .bpm | Linker.cs:567 |
| 2010 | Нельзя использовать ссылки на глобальные метки в .bpm | определён (ErrorsCodeList.cs:192), **нигде не вызывается** |
| 2011/2012/2013/2014/2015 | объявление свойства: только тип и имя / тип и имя / тип из 4-х / дубликат имени / не внутри метода | ImportErrorParser.cs:227/233/239/245/220 |
| 2016 | В строке допустимо только одно ключевое слово — private | ModuleErrorParser.cs:64 |
| 2017/2018 | Вызов приватного свойства/метода допустим только в модуле-владельце | Linker.cs:883,933 / 901,951 |
| 2019 | Имя переменной в описании функции модуля совпадает с именем свойства модуля | ModuleErrorParser.cs:615 |
| 2020 | Свойство с таким именем не определено в модуле | Linker.cs:855 |
| 1405/1414 | (фаза развёртки) Переменная не определена / в строке недопустимые выражения | Interpreter.cs:264,313 / 732 |

Формат ошибки при выводе: `file: <FileName> line: <N> | code: <C> ===> <текст> <Message>` (Errore.cs:19-22); печать: `Errors: <count>` + по строке на ошибку (ErrorShow.cs:32-43). `Message` обычно `"( исходная строка )"` либо путь к файлу (1101/2001).

## 12. Квирки (важно для бит-в-бит совместимости)

1. **Циклы**: include не может вкладываться (1105); import защищён «add-before-recurse» (ImportErrorParser.cs:111 vs 113-121); повторный import — молча.
2. **2010 не используется**: глобальная метка `@x` в модуле даёт 2008 (Linker.cs:587).
3. `private` «липкий» до конца файла, слово `public` отсутствует (ImportErrorParser.cs:286-289, 314-317).
4. Дубликат метода модуля с ≥1 параметром — без ошибки, остаётся первое определение (ImportErrorParser.cs:340).
5. `AddIncludesToMain`: мёртвое условие `mLine.Type != LineType.FOLDER` (Linker.cs:300).
6. Два `include` одного файла — двойное раскрытие, ключ словаря — номер строки (Preprocessor.cs:91-92).
7. Схема `Clev3r://`/`Clever://` платформозависима (`sep+sep` в сравнении) (ImportErrorParser.cs:491-499).
8. `..` учитывается только начальными сегментами; «перекрут» `down > depth(mainPath)` даёт относительный путь (ImportErrorParser.cs:522-529).
9. `GetParamCount`: Linker не считает `f.start`, ImportErrorParser считает (Linker.cs:108 vs ImportErrorParser.cs:436); `thread.run`-строки всегда 0 параметров.
10. `#region`/`#endregion`/`'#…` → EMPTY → исчезают из вывода; `'#main` — только IDE (IntellisenseParser.cs:321).
11. Модульные ключи несимметричны: `Methods` без префикса модуля (`<method>_<N>`), `Propertys` с префиксом (`<module>_<prop>`) (ImportErrorParser.cs:330, 293).
12. Локальные счётчики `lv_/ll_` сквозные через main-функции и методы модулей (одни переменные, Linker.cs:459-462, 475, 552).
13. Модуль может быть пустым файлом (0 байт) — corpus New_Path_Examples/Modules/Module2.bpm (проверено).
14. Ключи `Functions/Subs` — уже mangled-имена; вызовы резолвятся только по mangled-имени (число аргументов входит в имя) → несовпадение арности = «функция не найдена» (1806), а не «неверное число параметров».
15. Метки `break_N`/`continue_N`/`return_N` без `gl_`-префикса (LineErrorParser.cs:226).
16. Строка `import`/`folder`/пустые не попадают в вывод; `.bpi`-строки вставляются «как есть» (с комментариями, вырезанными лексером).
17. Свойство модуля — обычная глобальная переменная `pr_*`; инициализация всегда в начале вывода; неинициализируемый тип (теоретический) дал бы строку без `= value` (Linker.cs:816-846 не имеет else) — недостижимо из-за 2013.
18. Методы/свойства несуществующего модуля: `ParsePrivate` молчит, `ParseModuleMethodsInModules` молчит (Linker.cs:241-245); реальная диагностика — 1806 на вызове и 2020 на свойстве.
19. Ошибки прерывают обработку **неглубоко**: `return` из текущего метода, но `Data.Errors` глобальный — первый же шаг с ошибками останавливает всю цепочку Start-методов.

## 13. Открытые вопросы

1. BOM/CRLF у .bpi/.bpm на Linux: `File.ReadAllLines` корректно режет CRLF, но BOM у первой строки (гипотеза) станет частью первого слова и сломает разбор. Требует теста на corpus.
2. Реальная структура каталога `Lib/Modules`, `Lib/Includes` относительно `moduleLibPath` в дистрибутиве — в репозитории отсутствует; уточнить по установленной Clev3r.
3. Преднамеренно ли отсутствие ошибки при дубликате метода модуля с параметрами (квирк 4) или баг — поведение нужно воспроизвести как есть.
4. Порядок init-строк при сложных программах (несколько модулей + out-параметры) определяется порядком вставки в `Data.Project.Variables`; на Program1 порядок подтверждён, для модульных свойств `pr_*` порядок фиксирован (секция 1). Пограничные случаи (переменная, впервые встреченная в sub, вызываемой из функции) требуют тестов.
5. `StartInterpreter` (IDE-путь) позволяет задать другие расширения файлов — влияет ли это на схему `Clev3r://`-путей и имена вывода, в консоли не проверяется.
