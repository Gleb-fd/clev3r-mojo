# 07. Аудит порта: карта проверки, статусы и ограничения

Документ описывает, **что именно из поддерживаемого кода Mojo-порта проверено,
чем именно проверено и что осталось непроверенным**. Это не спецификация языка
(они в `docs/01`–`docs/06`), а карта доказательств и честная граница утверждений.

Источник истины для сравнения — C#-проект `/home/ssssq/Projects/clev3r_linux/Clev3r-1`
(коммит `906fc6913dd810470651641fce1ba1f82a4e112e`, рабочее дерево с
пользовательскими изменениями — **не изменялось**). Порт — этот репозиторий.

> **Главное.** На момент составления документа **сведённого (combined) прогона
> ворот после интеграции всех патчей ещё не было**. Поэтому здесь нет и не может
> быть утверждений вида «полный паритет», «всё проверено», «GUI/железо проверено».
> Ниже разделены: (а) то, что реально измерено на baseline, (б) то, что доказано
> автотестами в ветках патчей, (в) то, что установлено только чтением кода, (г) то,
> что не проверено вовсе. Итоговые измерения и финальный статус ворот внесёт
> интеграционный исполнитель после реального combined-прогона (§11).

---

## 1. Терминология статусов

| Статус | Что означает |
|---|---|
| **автотест (baseline)** | команда запускалась, результат зафиксирован в логах t10 (§2) на HEAD `8bf3621` |
| **автотест (ветка, pending)** | тест существует и, по отчёту исполнителя ветки, проходит; в combined-прогон ещё не входил |
| **статически** | проверено чтением кода/сравнением с C#; исполнения не было |
| **непроверено (GUI)** | требует живого Zed; недоступно в этой среде |
| **непроверено (hardware)** | требует живого EV3 и кабеля/радиоканала |
| **намеренное отличие** | поведение Mojo сознательно отличается от C#, причина задокументирована |
| **missing feature** | функциональность C# не портирована; это не «неверный перевод», а отсутствие |

Статусы **не** взаимозаменяемы: «есть модуль» ≠ «есть тест» ≠ «тест проходил в
сведённой сборке».

---

## 2. Доказательная база (артефакты, на которые ссылается документ)

Каталог прогона baseline: `tests/.oracle_work/t10_20261118T100051/` (gitignored,
в репозиторий не входит). Использованы только эти файлы (не JSONL-сессии и не
временные отчёты поиска):

| Артефакт | Содержание |
|---|---|
| `logs/VERDICTS.md` | вердикты A–K по дефектам (подтверждён/опровергнут) с ссылками на код |
| `logs/GATES.md` | что запускалось на baseline и с каким кодом возврата |
| `logs/provenance.txt` | HEAD, версии инструментов, SHA артефактов, состояние оригинала |
| `logs/measurements.json`, `logs/measurements.log` | замеры baseline Mojo и C#-оракула (warmup 3, 9 замеров) |
| `logs/clean_baseline.json/.log` | чистый прогон корпуса без сгенерированных `~`-каталогов |
| `logs/repro_*.json/.log`, `logs/scanner_probe.log`, `logs/flash_probe.log`, `logs/lsp_repro.json` | точечные репродукции дефектов |
| `logs/difftest_{expand,lmsb,rbf}.log` | дифференциальные стадии на baseline |
| `logs/final_mojo_head.txt`, `logs/final_mojo_git_status.txt` | HEAD и чистота дерева Mojo на момент прогона |
| `logs/original_git_status.txt` | 18 грязных записей исходного C#-дерева (пользовательские) |
| `cs_mirror/`, `cs_mirror.sha256` | копия исходников C# (449 файлов) и их хеши; проверено `sha256sum -c` — 449/449 OK, 0 drift |
| `baseline/bp` | сохранённый Mojo-бинарник baseline |

Зафиксированные идентификаторы (из `provenance.txt`):

| Что | Значение |
|---|---|
| Mojo HEAD baseline | `8bf3621f36439337f78f6ced129c57508b82afb9` (ветка `main`, дерево чистое) |
| Mojo binary SHA-256 | `b37d4dfca521efdae469d422b7b3094ff5ada4dd616f9b918efd4487946a1004` |
| C# DLL (оракул) SHA-256 | `39d03dfaf2ff6306316cd7b635041d3f11c3cd067c6cf1840b4104d8431b5771` |
| C# source HEAD | `906fc6913dd810470651641fce1ba1f82a4e112e`, **dirty, 18 записей** |
| Версии | Mojo 1.1.0, .NET runtime 9.0.21/10.0.13, Python 3.15.2, tree-sitter 0.26.9, rustc 1.98.1 |

### 2.1. Baseline и after — разные вещи

* **Baseline** = HEAD `8bf3621`, бинарник `b37d4dfc…`. Все цифры §10 — это baseline.
* **After** = сведённая сборка после интеграции патчей (§8). Замеров after **нет**.
* Таблица в §10 помечена как исходная и не должна попадать в итоговый отчёт как
  результат текущего порта.

### 2.2. Статус SDK/DLL — почему нет «свежей» сборки оракула

* .NET **SDK отсутствует** (`dotnet_sdk=` пусто в `provenance.txt`), есть только
  runtime. Поэтому оракул — **заранее собранный**
  `InterpreterConsole/bin/Release/net6.0/InterpreterConsole.dll` (`39d03dfa…`),
  запускается с `DOTNET_ROLL_FORWARD=LatestMajor`.
* «Свежая сборка C# из исходников» **не доказана** и в этом аудите не заявляется.
  Проверено только: DLL побайтно совпадает с тем, на который ссылаются
  `tools/port_verify.py` и `measurements.json`, а smoke-прогон Test1 даёт файлы,
  побайтно равные `tests/golden`.
* Копия исходников C# (`cs_mirror`, 449 файлов) соответствует **рабочему дереву**
  пользователя (то есть и его локальным правкам), а не чистому git-снимку
  `906fc691`. Это ограничение происхождения, а не дефект порта.

---

## 3. Подробная карта поддерживаемого кода: `src/bp/*.mojo`

Все строки ниже — поддерживаемый код порта (не generated, кроме явно
помеченного). Колонка «Проверка» — по §1.

| Файл | Строк | Роль | C#-соответствие | Проверка |
|---|---:|---|---|---|
| `src/bp/__init__.mojo` | 0 | пакет-маркер | — | не требует проверки |
| `src/bp/util.mojo` | 106 | чтение/запись UTF-8, BOM, CRLF/LF/CR, пути, `usage` | `Program.cs:35,43`, `File.ReadAllLines`, `Path.*` | **автотест (ветка, pending)**: `util_test.mojo` (13f23b4 — 152 стр., 176d4a6 — +47) |
| `src/bp/diag.mojo` | 53 | накопление и печать диагностик | `DataTemplates/Errore.cs`, `ErrorShow.cs` | статически |
| `src/bp/json.mojo` | 610 | минимальный JSON-парсер/сериализатор для LSP | нет (новая функциональность) | статически + косвенно `lsp_test` |
| `src/bp/lexer.mojo` | 788 | стадии 1–2: `LineBuilder` + `TokenBuilder` | `Utils/LineBuilder.cs`, `Utils/TokenBuilder.cs` | **автотест (baseline)**: `lexer_test` OK; точечные репро в VERDICTS A/C/D |
| `src/bp/preproc.mojo` | 859 | include/import, `CreateFullPath`, модули | `Parsers/IncludeErrorParser.cs`, `ImportErrorParser.cs`, `Utils/Preprocessor.cs` | **автотест (ветка, pending)**: `preproc_test.mojo` (381 стр., e628834) + regression fixtures |
| `src/bp/expand.mojo` | 2034 | развёртка BP → `~Имя.bp`, линковка | `Utils/Interpreter.cs`, `Utils/Linker.cs`, `Utils/MediaBuilder.cs` | **автотест (baseline)**: `difftest.sh expand` 43/0/1; чистый корпус 40/0/1; pending-правки e628834 |
| `src/bp/builtins.mojo` | 169 | имена/типы builtin-классов | `DataTemplates/DefaultObjectList.cs` | статически + сверка 284/284 в t10 (VERDICTS K) |
| `src/bp/compiler3.mojo` | 3008 | стадия 3: сканер+компилятор → `.lmsb` | `Compiler/Scanner.cs`, `Compiler/Compiler.cs`, `Expression.cs`, `FunctionDefinition.cs` | **автотест (baseline)**: `difftest_lmsb` 46/46; **pending**: `compiler3_test.mojo` (13f23b4/176d4a6) |
| `src/bp/compiler3_resources.mojo` | 5176 | **generated**: тексты 33 `c_*.txt` как константы | `Compiler/Resources/c_*.txt` | generated, руками не правится; сверка хешей 33/33 в t10 |
| `src/bp/asm.mojo` | 1776 | стадия 4: `.lmsb` → `.rbf` | `Assembler/*.cs` | **автотест (baseline)**: `difftest_rbf` 46/46; **pending**: `asm_test.mojo` (502 стр., 3fde3bc) |
| `src/bp/buildcmd.mojo` | 126 | `bp compile` / `bp check` | `Builder.cs:79-140` | **автотест (baseline)**: `buildcmd_test` OK только с фикстурами (см. §9) |
| `src/bp/flash.mojo` | 1118 | USB hidraw / BT / Wi-Fi, кадры, заливка | `Clever/Brick/Communication/EV3Connection*.cs`, `CleverDeploy/EV3Connection.cs` | **автотест (baseline)**: `flash_test` OK; e2e на заглушках; **hardware — непроверено**; pending 71982b3/63e6675 |
| `src/bp/lsp.mojo` | 604 | LSP-сервер (stdio, JSON-RPC) | нет (новая функциональность; идеи из `Clever/Model/Intellisense`, но не порт) | **автотест (baseline)**: `lsp_test.mojo` (19 стр.) — только поднимает сервер до EOF; дефекты найдены ручными репро (`lsp_repro.json`), переработка — в ветке t16 (**pending**); **GUI — непроверено** |
| `src/bp/main.mojo` | 163 | CLI-диспетчер команд | `InterpreterConsole/Program.cs` | **автотест (baseline)**: используется всеми гейтами; rc-дефекты подтверждены в VERDICTS E |

Тесты в `src/bp/` (входят в дерево, не production):

| Файл | Строк | Статус |
|---|---:|---|
| `lexer_test.mojo` | 473 | baseline OK |
| `selftest.mojo` | 58 | baseline OK (с фикстурой; старый вариант читал `/home/ssssq/Windows/Program1.bp`) |
| `buildcmd_test.mojo` | 42 | baseline OK только с подготовленными фикстурами |
| `flash_test.mojo` | 318 | baseline OK |
| `lsp_test.mojo` | 19 | baseline OK, но проверяет лишь «сервер стартует и доходит до EOF» (создаёт глобальный `/tmp/bp_lsp_docs` — см. §8.7) |
| `util_test.mojo` | 199 | **ветка 13f23b4+176d4a6, pending** |
| `compiler3_test.mojo` | 264 | **ветка 13f23b4+176d4a6, pending** |
| `preproc_test.mojo` | 381 | **ветка e628834, pending** |
| `asm_test.mojo` | 502 | **ветка 3fde3bc, pending** |

### 3.1. Ресурсы `src/bp/resources/c_*.txt`

34 файла (204 КБ), все — байт-в-байт копии
`Clev3r-1/Interpreter/Compiler/Resources/c_*.txt`. Перечень:

```
c_Assert      c_Buttons   c_Byte      c_EV3       c_EV3File   c_LCD
c_Mailbox     c_Math      c_Motor     c_MotorA    c_MotorAB   c_MotorAC
c_MotorAD     c_MotorB    c_MotorBC   c_MotorBD   c_MotorC    c_MotorCD
c_MotorD      c_NativeCode c_Program  c_Row       c_runtimelibrary
c_Sensor      c_Sensor1   c_Sensor2   c_Sensor3   c_Sensor4   c_Speaker
c_Text        c_Thread    c_Time      c_Vector    c_BitMask
```

* **33 из 34** попадают в `compiler3_resources.mojo`: 32 модуля в порядке
  `readLibrary` (`Compiler.cs:73-105`) плюс `c_NativeCode.txt` отдельной
  константой (нужен для `EV3.NativeCode`). `c_BitMask.txt` **не читается
  компилятором** — это справочная таблица масок моторов (`docs/03` §1); он
  намеренно не генерируется.
* Генератор: `tools/gen_compiler3_resources.py`; результат —
  `src/bp/compiler3_resources.mojo`. Константы — **generated**, ручные правки
  запрещены. В t10 сверены хеши всех 33 файлов; drift не найден.

### 3.2. Generated и vendor — не поддерживается вручную

Эти файлы не являются предметом ревью как код; их правят только регенерацией.

| Путь | Происхождение | Как обновлять |
|---|---|---|
| `src/bp/compiler3_resources.mojo` | `tools/gen_compiler3_resources.py` из `src/bp/resources/c_*.txt` | прогнать генератор, проверить `git diff` (t10: diff пуст) |
| `grammar/src/grammar.json`, `grammar/src/node-types.json`, `grammar/src/parser.c` | `tree-sitter generate` из `grammar/grammar.js` | `cd grammar && tree-sitter generate` |
| `grammar/src/tree_sitter/{alloc,array,parser}.h` | vendor tree-sitter (заголовки рантайма) | обновлять вместе с CLI/грамматикой |
| `zed-extension/prebuilt/extension.wasm`, `zed-extension/prebuilt/grammars/basic_plus.wasm` | собраны из `zed-extension/src/lib.rs`/`grammar/` (wasi-sdk + `cargo build --target wasm32-wasip2` + `tree-sitter build --wasm`) | пересобрать по рецепту в `zed-extension/README.md`; **в этой среде пересборка не воспроизводилась** |
| `uv.lock` | `uv lock` | `uv lock` |

Исключения из «поддерживаемого кода» также: `tools/probe_stdlib.mojo`
(исследовательский пробник), `src/clev3r_mojo/__init__.py` (заготовка
Python-упаковки, к компилятору не относится).

---

## 4. Инструменты, установка, гейты

| Файл | Роль | Проверка |
|---|---|---|
| `install.sh` | `uv sync` + сборка `tools/bp` + smoke `bp check`; `--with-zed` | статически; запуск в этой среде не производился |
| `tools/verify_all.sh` | «полная» проверка: сборка + юнит-тесты + difftest | baseline-версия 23 строки, **не** fail-closed; **pending** версия fd112e2 (145 стр.) |
| `tools/difftest.sh` | стадии expand/lmsb/rbf против `tests/golden` | baseline: 43 pass / 0 fail / 1 skip (со сгенерированными входами) |
| `tools/difftest_lmsb.sh`, `tools/difftest_rbf.sh` | два контура стадии 3/4 по 46 эталонам | baseline: 46/46 и 46/46; **известные дефекты гейта** (§9) |
| `tools/make_golden.sh` | перегенерация эталонов оракулом | baseline: без `--apply` не меняет golden; **дефекты** (§9) |
| `tools/gen_compiler3_resources.py` | генератор ресурсов | сверка «генерация не даёт git diff» в t10 |
| `tools/install_zed_extension.sh` | установка dev-расширения Zed из пребилдов | baseline: ставит в `$HOME/.local/share/zed`, игнорирует XDG, rev `master`; **pending** 6e23cd0/677003d |
| `tools/grammar/check_corpus.sh` | tree-sitter разбор корпуса | baseline: **false green** при нерабочем CLI; **pending** 6e23cd0 (fail-closed, rc 0/1/2/3) |
| `tools/fake_ev3.py` | TCP :5555 заглушка кирпича | baseline: требует доработки эха (71982b3 делает это) |
| `tools/fake_ev3_serial.py` | pty-заглушка RFCOMM | то же |
| `tools/probe_stdlib.mojo` | **исследовательский** пробник stdlib Mojo 1.1 | не часть продукта и не часть гейтов; читает `/home/ssssq/...` — в гейты не включать |
| `tools/verify_port.sh` + `tools/port_verify.py` | **ветка fd112e2, pending**: живой C#-оракул, 40 входов, benchmark | автотест ветки: `VERIFY_PORT PASS` у исполнителя; в combined не входил |
| `tools/tests/test_port.py` | **pending**: 18 негативных/позитивных тестов самих ворот | автотест ветки (t11 подтвердил 18/18) |
| `tools/tests/test_cli_flash.py` | **pending**: CLI rc + TCP/pty e2e + негативы протокола | автотест ветки 71982b3+63e6675 |
| `tools/tests/test_editor_install.py` | **pending**: XDG/manifest/rev/index-режим/symlink | автотест ветки 6e23cd0+677003d |
| `tools/tests/fixtures/**` | **pending**: фикстуры гейтов (broken/empty/errors/include/module/selftest/small) | используются `verify_all`/`test_port` |

`grammar/`:

| Файл | Роль | Проверка |
|---|---|---|
| `grammar/grammar.js` | исходник грамматики (530 стр.) | `check_corpus` (pending fail-closed) |
| `grammar/package.json`, `grammar/tree-sitter.json` | манифесты грамматики | статически (`tomllib`/`json` в zed README) |
| `grammar/queries/{highlights,brackets,indents,outline}.scm` | запросы (4) | статически; копии в расширении сверяются глазами |
| `grammar/test/corpus/basic_plus.txt` | корпус грамматики (214 стр.) | `tree-sitter test` — отдельно, не в `check_corpus` |
| `grammar/src/{grammar.json,node-types.json,parser.c}`, `grammar/src/tree_sitter/*.h` | **generated/vendor** (`tree-sitter generate`) | руками не править; происхождение — генератор CLI |
| `zed-extension/prebuilt/*.wasm` | **vendor binary**: пребилд расширения и грамматики | в репозитории, пересборка не воспроизводилась (§8.5) |

`zed-extension/` (Rust-шим и манифесты):

| Файл | Роль | Проверка |
|---|---|---|
| `zed-extension/extension.toml` | id, грамматика (`rev = 76081a6…`), `[language_servers.basic-plus]` | статически; `rev` пинится, менять не нужно |
| `zed-extension/Cargo.toml`, `Cargo.lock` | Rust-шим, `zed_extension_api 0.7.0` | Cargo.lock фиксирует полную версию `0.7.0` |
| `zed-extension/src/lib.rs` | `language_server_command`: `tools/bp lsp`, команда `args = ["lsp"]` | статически |
| `zed-extension/languages/basic_plus/config.toml` | суффиксы, комментарии, tab_size, скобки | статически |
| `zed-extension/languages/basic_plus/{highlights,brackets,indents,outline}.scm` | 4 запроса (копии `grammar/queries`) | статически |
| `zed-extension/tasks.json` | шаблон задач (3 задачи) | статически; **не** привязки клавиш |
| `.zed/tasks.json` | задачи репозитория (6 задач) | статически; **не** keymap — хоткеи пользователь назначает сам |

Упаковка/прочее:

* `pyproject.toml` — `requires-python = ">=3.14"`, зависимость `mojo>=1.1.0`,
  скрипт `clev3r-mojo = "clev3r_mojo:main"`; `.python-version` = `3.14`.
* `src/clev3r_mojo/__init__.py` — **заготовка упаковки** (2 строки, `main()`
  печатает приветствие). К компилятору не относится, не выдавать за CLI.
* `uv.lock` — зафиксированное окружение.
* Файлов инструкций для агентов (AGENTS/CLAUDE/CONTRIBUTING) в репозитории нет.

---

## 5. Корпус, эталоны и классификация фикстур

* `tests/corpus` — **41 настоящий** `*.bp` (без сгенерированных) + 3 файла внутри
  `~`-каталогов (артефакты прежних прогонов, не независимые программы).
  Итого 44 `*.bp`. Плюс include/module-файлы: `Include/MotorMove.bpi`,
  `Include/SensorRGB.bpi`, `New_Path_Examples/Includes/Include{1,2}.bpi`,
  `New_Path_Examples/Modules/Module{1,2}.bpm`, а также медиа-фикстуры
  `Other/GraphicsAndSounds/emerald.rsf`, `yamyam.rgf`.
* `tests/golden` — **46** каталогов `~<Имя>/` с `.lmsb` + `.rbf` + `~<Имя>.bp`.
  Из них 3 — **вложенные повторные развёртки** (`Functions/~Test1/~~Test1`,
  `Other/~Battery/~~Battery`, `Other/~ButtonsAndMotors/~~ButtonsAndMotors`).
  Поэтому «46/46» — это 46 **каталогов эталонов**, а не 46 независимых программ;
  независимых входов с эталоном — 40 (плюс 1 намеренный skip).
* `New_Path_Examples/Program1.bp` — **известный skip**: у оракула нет эталона из-за
  его собственного бага с путями (`tests/golden_report.txt`). Это не «зелёный» тест.
* `tests/golden_report.txt` — исторический отчёт `make_golden.sh` (43 ok, 1 fail).

---

## 6. Сопоставление слоёв C# и модулей порта

| Слой C# | Где | Модуль Mojo |
|---|---|---|
| `Utils/LineBuilder.cs`, `Utils/TokenBuilder.cs` | стадии 1–2 | `lexer.mojo` |
| `Parsers/IncludeErrorParser.cs`, `ImportErrorParser.cs`, `Utils/Preprocessor.cs` | include/import | `preproc.mojo` |
| `Utils/Linker.cs`, `Utils/Interpreter.cs`, `Parsers/*ErrorParser.cs` (валидаторы) | линковка/развёртка | `expand.mojo` (+ `preproc.mojo` для модулей) |
| `Compiler/Scanner.cs`, `Compiler/Compiler.cs`, `Compiler/Expression.cs`, `FunctionDefinition.cs`, `LibraryEntry.cs` | стадия 3 | `compiler3.mojo` (+ `compiler3_resources.mojo`) |
| `Compiler/Resources/c_*.txt`, `DataTemplates/DefaultObjectList.cs` | данные/сигнатуры | `resources/c_*.txt` → `compiler3_resources.mojo`; `builtins.mojo` |
| `Assembler/{Assembler,LMSObject,DataArea,DataWriter,VMCommand}.cs` | стадия 4 | `asm.mojo` |
| `Builder.cs`, `InterpreterConsole/Program.cs` | сцепка/CLI | `buildcmd.mojo`, `main.mojo` |
| `Clever/Brick/Communication/EV3Connection{,USB,Bluetooth,WiFi}.cs`, `ByteCodeBuffer.cs`, `CleverDeploy/EV3Connection.cs` | заливка | `flash.mojo` |
| `DataTemplates/ErrorsCodeList.cs` | тексты ошибок RU/UA/EN | **не портировано** (missing feature, §8.1) |
| `Clever/Model/Intellisense/*`, `BpLexer.cs` | подсветка IDE | не портируется; заменено tree-sitter + `lsp.mojo` |
| — | JSON/LSP/грамматика/расширение | **новая функциональность** (`json.mojo`, `lsp.mojo`, `grammar/`, `zed-extension/`) |

---

## 7. Что реально проверено на baseline (HEAD `8bf3621`)

Из `logs/GATES.md` (повторяю дословно статусы, без округления в «всё зелёное»):

| Команда | rc | Результат |
|---|---:|---|
| сборка `src/bp/main.mojo` → `baseline/bp` | 0 | SHA `b37d4dfc…`, идентичен `tools/bp` на старте |
| `lexer_test.mojo` | 0 | pass |
| `difftest.sh expand|lmsb|rbf` | 0 | 43 pass / 0 fail / 1 skip каждая (со сгенерированными входами) |
| чистый корпус без `~`-каталогов (`cleanbaseline.py`) | 0 | 40 pass / 0 fail / 1 skip |
| `flash_test.mojo` | 0 | `FLASH_TEST OK` |
| `lsp_test.mojo` | 0 | pass (создаёт глобальный `/tmp/bp_lsp_docs`) |
| `selftest.mojo` | 0 | OK только при чтении внешнего `/home/ssssq/Windows/Program1.bp` |
| `buildcmd_test.mojo` без фикстур | **1** | нет предусловия `/tmp/bp_work` |
| `buildcmd_test.mojo` с фикстурами (bwrap) | 0 | `BUILDCMD SELFTEST OK` |
| smoke оракула Test1 | 0 | 3 файла, побайтно равны `tests/golden` |
| `TREE_SITTER_CLI=/bin/false check_corpus.sh` | **0** | **ложный зелёный**: 50/50 clean |
| `install_zed_extension.sh` с temp HOME+XDG | 0 | ставит в `HOME/.local/share/zed`, XDG игнорируется, rev `master` |

Ограничения этого набора прямо перечислены в `GATES.md`: `difftest*` считают
сгенерированные `~*.bp` входами (43 вместо 40 на чистом корпусе) и **не проверяют
коды возврата стадий** в baseline-версии — устаревшие артефакты могут маскировать
провал. Именно это ремонтирует ветка fd112e2.

---

## 8. Статусы исправлений (что принято, что pending)

Ниже — по каждой группе патчей: суть, доказательство, что **нельзя** утверждать.

### 8.1. Unicode/числа: `13f23b4` + `176d4a6` — **принято**

* Лимит строки 251 считается в **UTF-16 code units** как `string.Length` в C#
  (BMP = 1, supplementary = 2). Проверено: 251/252 ASCII, 125/126 emoji,
  126 кириллических `ж`; ссылка C# `Compiler.cs:1457-1465`, порт
  `compiler3.mojo:2498`.
* BOM: снимается ровно один ведущий UTF-8 BOM (как `StreamReader`), второй
  остаётся содержимым; двойной BOM C# отвергает — порт тоже, не «молча
  компилирует».
* Переводы строк: CRLF, LF и CR — как `File.ReadAllLines`; CR-only файл больше не
  считается одной строкой.
* Длинные дроби: разбор через libc `strtod` с типизированным `char**`
  (pointer-sized out-слот, не 1 байт — иначе UB), NUL-терминированный буфер,
  проверка **полного** потребления строки; при частичном разборе — явный отказ.
* Осознанное отличие: переполнение Float64 в C# даёт `Infinity` → `INFINITY.0` и
  падение ассемблера; порт возвращает понятную ошибку. Это **намеренное отличие**,
  а не регрессия.
* Формат double: `.NET`-совместимая fixed-нотация для экспоненты `-4..16`
  (раньше граница была `< 15`, из-за чего `2^53` печаталось как
  `9.007199254740992E+15`). Проверены границы 1e14/1e15/1e16/1e17, `2^53`,
  отрицательные, round-trip.
* Ветка `c59b242` (head t10-unicode-repair) добавляет **6 сгенерированных файлов
  в `tests/corpus`** — **не приняты**; принимать нужно только код/тесты из
  13f23b4/176d4a6.

**Не портировано (не «перевод неверный»):** кодировки C# `Encoding.Default`
(байтовые колонки, UTF-16LE/BE автодетект) — вход документирован как UTF-8;
локализованные тексты `ErrorsCodeList` — **missing feature**.

### 8.2. Ассемблер: `3fde3bc` — **reviewed**

* `assemble_file` больше не пишет `.rbf` при любой ошибке разбора/интеграции:
  образ собирается в памяти (`build_output`), файл пишется только при пустом
  списке ошибок; существующий `.rbf` при ошибке остаётся побайтно прежним
  (C#: `Assembler.cs:70-108`, `Builder.cs:113-137`).
* Тест `asm_test.mojo` — регрессии на bad opcode/unknown id/unclosed object/
  missing label/subcall/bad directive/sentinel, границы кодирования констант,
  метки назад/вперёд, квирк `UI_DRAW TEXTBOX = 84 81 20`.
* `t15` (атомарная запись на уровне ОС) — **pending**; **нельзя** заявлять
  устойчивость к отключению питания / полную durability.
* Квирк комментария одиночным `/` совпадает с C# — **не менялся**.

### 8.3. expand/preproc: `e628834` — **pending review**

* Bare-имя входа больше не резолвит include/import от `/`: `run_expansion`
  принимает необязательный `project_dir` (реальный родитель файла), как
  `Program.cs:35,43`; для LSP — тот же API.
* Пустая программа разворачивается в **точные 0 байт** (как `File.WriteAllLines`
  с пустым списком), а не в `"\n"`.
* Портированы узкие валидаторы: 1001/1002 (баланс скобок в main/.bpi/.bpm),
  1809 (дубль zero-arg `Function`), 1806/1606 (неразрешённые call/sub/thread),
  1414/1606 (`Thread.Run`).
* `'..'` в `create_full_path` — **намеренное отличие**: Mojo сохраняет ведущий
  `/` и корректно резолвит `Devices/../Sensors`, C# теряет ведущий `/`. Фикс не
  откатывать. Но: интерьерный `..` проверен **не полностью** — **нельзя**
  утверждать «все пути корректны».
* Полные `ModuleErrorParser`/`StructErrorParser` и каталог имён **не портированы**:
  остаются пробелы валидации. **Нельзя** называть это full parity.

### 8.4. CLI/flash: `71982b3` + `63e6675` — **pending review**

* Реальный system-reply: `[ctr u16][type 0x03|0x05][эхо команды][статус][payload]`,
  минимум **5** байт, payload с **offset 4** (C#: `EV3Connection.cs:66-117`,
  `Array.Copy(packet, 4, …)`). Старый возврат `packet[3:]` принимал эхо за статус
  (для BEGIN 0x92) — реальный кирпич не проходил. Заглушки теперь обязаны
  эхировать команду; прежние заглушки/`src/bp/flash.mojo` были неверны.
* BEGIN/CONTINUE_DOWNLOAD **не** ретраятся автоматически после неизвестного ACK
  (safety: повтор с новым счётчиком дублировал бы байты). CREATE_DIR/DELETE —
  идемпотентны и ретраятся.
* `PROGRAM_START`: `build_run_bytecode` — `opFILE LOAD_IMAGE` в слот 1 + `opPROGRAM_START`,
  `globals=10`, locals=0 (как в старом пути).
* fd закрывается при любом сбое setup (serial raw, connect, handshake);
  успешный fd не закрывается дважды.
* CLI: ненулевой rc у `lmsb`/`rbf`/`lex`/`expand`; неизвестная команда → 1;
  `help`/`-h`/`--help` и запуск без аргументов → usage + 0; `check` batа — 1.
* `docs/06` §2 в старом виде давал узкое (и вводящее в заблуждение) отображение
  ответа; исправлено на формат с эхом.
* **Hardware — непроверено.** Заглушки доказывают алгоритм кадров, а не реальный
  обмен с кирпичом.

### 8.5. Грамматика/инсталлер: `6e23cd0` + `677003d` — **accepted**

* `check_corpus.sh` fail-closed: rc 0/1/2/3, без скачивания зависимостей,
  разрешает относительные аргументы из любого cwd, работает из каталога
  грамматики.
* `install_zed_extension.sh`: уважает `ZED_DATA_DIR`/`XDG_DATA_HOME`; проверяет
  `index.json` и манифест **до** копирования; `rev` берётся из `extension.toml`
  (а не `master`); сохраняет режим index-файла и пользовательский symlink;
  `lib.version` — полная SemVer из `Cargo.lock` (`0.7.0`), без выдуманного
  диапазона `0.7`.
* Исходник `grammar/` и пребилды Rust **не изменялись**.
* **Не проверено:** реальный Zed GUI и WASM-хост (сборка/загрузка расширения).
* **Риск, задокументированный, а не устранённый:** index.json заменяется
  сериализованно; параллельная запись Zed может потерять обновление. Установку
  выполнять при закрытом Zed / эксклюзивно; гарантий конкурентности нет.
* `rev = 76081a635ac2fa0dbb6d0727c043a996a599603d` **не менять**.
* Инсталлер использует `tomllib` → требует **Python ≥ 3.11** (в проекте
  `pyproject.toml` — `>=3.14`); **не** обещать работу на старых python.

### 8.6. Ворота/харнесс: `fd112e2` — **pending repair (t18)**

* Fail-closed: свежий уникальный scratch, проверка rc стадий, копия корпуса без
  `~`-каталогов, явный allowlist известного `'..'`-кейса, падение при
  неожиданных/пропавших эталонах, без «пустого» pass.
* `make_golden.sh`: staging в temp, dry-run по умолчанию, `--apply` только после
  полного успеха, старый golden сохраняется/восстанавливается.
* `verify_port.sh`: живой C#-оракул, 40 входов, include/module,
  коды ошибок, намеренные отличия (empty newline, `'..'`), benchmark
  baseline/current/oracle (warmup 3, 9 замеров, median/min/max, сырые выборки,
  повтор при регрессии >10%).
* `verify_all.sh` (pending) связывает все Mojo- и Python-хуки + грамматику;
  отсутствующий тест — явный `FAIL("MISSING")`, а не skip.
* Известные дефекты t11 (adversarial review) **требуют починки до финального
  combined-прогона**: `difftest_lmsb` без `pass>0` guard и вакуумный rbf-контур;
  `make_golden` игнорирует rc оракула; `buildcmd_test` печатает FAIL, но
  возвращает 0; `port_verify.py` жёстко ждёт `b"\n"` для пустого входа (после
  фикса e628834 нужен `b""` или флаг); self-comparison baseline не отвергается;
  `verify_all` собирает в общий `tools/bp` (гонка двух прогонов).
* Текущие цифры для будущего отчёта: **40 валидных независимых входов + 1
  известный skip**; 46 эталонных каталогов включают вложенные повторные развёртки
  — это **не** 46 независимых программ. `ALL GOLDEN PRESERVED` (без `--apply`).
* Baseline-контракт `port_verify`: требует **явный** `BP_BASELINE_BINARY`
  (и/или известный run + SHA), иначе ненулевой exit; общего обещания «любой
  будущий клон найдёт baseline» нет — артефакт baseline gitignored (§11).

### 8.7. LSP: ветка `t16` от `e628834` — **в работе, pending**

Заявленный объём (по описанию ветки, не по combined-прогону):

* приватный process-temp каталог вместо общего `/tmp/bp_lsp_docs`;
* include резолвится относительно реального URI документа;
* `id: null` даёт валидный JSON;
* hover считает позиции в UTF-16;
* ошибки I/O публикуются явно, а не «пустым» списком;
* anchor раскрытых диагностик — 0 (честная строка, не выдуманная);
* фрейминг: тело ≤ 16 MiB, глубина JSON ≤ 128.

**Ещё не сделано / нельзя утверждать:**

* `definitionProvider` **не реализован** — убрать из README «переходы»;
* `zed-extension/README.md` со словами «lsp — заглушка» **устарел** (в `main.mojo`
  вызов `cmd_lsp` уже есть);
* если в настройках указывается сервер, используется поле `arguments`
  (у `Command` в `lib.rs` — `args`), не `args`;
* готовых хоткеев в репозитории нет: `.zed/tasks.json` и
  `zed-extension/tasks.json` — **задачи**, а не привязки клавиш; привязку делает
  пользователь в своём `keymap.json`;
* GUI Zed и WASM-хост — **только ручная проверка**.

---

## 9. Гейты: что именно можно и нельзя утверждать

| Утверждение | Можно? | Почему |
|---|---|---|
| «Движок компиляции совпадает с оракулом на корпусе» | да, для 40 независимых входов baseline | `clean_baseline.json`: 40/0/1, а также 46/46 по эталонным каталогам |
| «43 pass» | только как «43 входа, включая сгенерированные» | baseline-`difftest` считает `~*.bp` |
| «46 независимых программ» | **нет** | 46 — число каталогов эталонов; 3 из них вложенные повторные развёртки |
| «полный паритет» | **нет** | §8.1/8.3: missing validators, каталог ошибок, кодировки |
| «GUI/Zed проверен» | **нет** | нет живого Zed |
| «железо проверено» | **нет** | нет EV3 |
| «все тесты зелёные» | **нет** | combined-прогона не было; часть тестов в ветках |

---

## 10. Исходные измерения baseline (НЕ after)

Источник: `logs/measurements.json` (warmup 3, 9 замеров, медианы), машина одна.

| Кейс | Mojo, мс | C# оракул, мс | Отношение | Паритет `.lmsb`/`.rbf`/`~.bp` |
|---|---:|---:|---:|---|
| small_Test1 | 21.79 | 305.46 | 14.0× | да/да/да |
| large_BrickBench | 35.69 | 318.31 | 8.9× | да/да/да |
| large_Generated3000 (3052 строки) | 104.02 | 598.75 | 5.8× | да/да/да |
| include_Main | 21.93 | 267.17 | 12.2× | да/да/да |
| module_Main | 21.89 | 276.38 | 12.6× | да/да/да |
| startup_empty | 20.58 | 204.04 | 9.9× | да/да/**нет** (`\n` vs 0 байт — известное отличие, фикс e628834) |

Как читать: это **исходный** (baseline) срез до интеграции. `empty` показывает
именно тот дефект, который чинит ветка e628834; после интеграции значение
`~.bp` должно стать равным.

Данные харнесса `tools/port_verify.py` из ветки fd112e2 (`tests/.verify_port_work/run_*/report.json`,
gitignored) — **не** combined-after и в этот документ как результат не переносятся.

### Итоговые измерения: ещё не проведены

Сведённая таблица «baseline → after» с финальными числами будет внесена
интеграционным исполнителем **после реального combined-прогона**
`bash tools/verify_port.sh /home/ssssq/Projects/clev3r_linux/Clev3r-1` на
интегрированном дереве. До этого любые «финальные» цифры в README/отчётах
недопустимы.

---

## 11. Что должен сделать интеграционный исполнитель

1. Интегрировать ветки в согласованном порядке и получить **одну** сведённую
   сборку; прогнать `bash tools/verify_all.sh` (fail-closed версия).
2. Починить дефекты харнесса из t11 (§8.6), включая ожидание пустого выхода
   (`b""`) после фикса e628834.
3. Прогнать `bash tools/verify_port.sh /home/ssssq/Projects/clev3r_linux/Clev3r-1`
   с явным `BP_BASELINE_BINARY` (SHA `b37d4dfc…`) — и получить `report.json`.
4. Обновить §10 этого документа **фактическими** after-цифрами и §8 — снять
   пометки `pending` у принятых патчей и LSP.
5. Проверить `git diff --check` (пробелы) и отсутствие изменений в
   golden/config/коде при документационной правке.
6. Не менять `rev` грамматики и не выдавать GUI/железо за проверенные без
   ручного прогона.

Как предоставить baseline, если артефакт `b37d4dfc…` недоступен: собрать
бинарник из чистого коммита `8bf3621` (`uv run mojo build src/bp/main.mojo -o
baseline/bp`), проверить SHA-256, передать путь через `BP_BASELINE_BINARY`
(и `BP_BASELINE_SHA256`). Гарантии «клонируй и всё сойдётся» нет: baseline
намеренно не коммитится.
