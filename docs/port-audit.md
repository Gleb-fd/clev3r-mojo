# 07. Аудит порта: карта проверки, статусы и ограничения

Документ описывает, **что именно из поддерживаемого кода Mojo-порта проверено,
чем именно проверено и что осталось непроверенным**. Это не спецификация языка
(они в `docs/01`–`docs/06`), а карта доказательств и честная граница утверждений.

Источник истины для сравнения — C#-проект `/home/ssssq/Projects/clev3r_linux/Clev3r-1`
(коммит `906fc6913dd810470651641fce1ba1f82a4e112e`, рабочее дерево с
пользовательскими изменениями — **не изменялось**). Порт — этот репозиторий.

> **Главное.** Патчи интегрированы в `main` одной сведённой сборкой, и
> combined-прогон ворот **выполнен** (2026-11-19 UTC):
> `bash tools/verify_all.sh` → `VERIFY_ALL OK` (rc 0) и
> `bash tools/verify_port.sh /home/ssssq/Projects/clev3r_linux/Clev3r-1` →
> `VERIFY_PORT PASS` (rc 0). Поэтому статусы ниже — про **проверенное на
> сведённой сборке**, а не про «ветки». При этом здесь по-прежнему нет и не может
> быть утверждений вида «полный паритет языка», «GUI проверен», «железо
> проверено»: границы утверждений — §8, §9, §11. Историческая таблица baseline
> (§10.1) и итоговая таблица after (§10.2) разделены намеренно.

---

## 1. Терминология статусов

| Статус | Что означает |
|---|---|
| **автотест (baseline)** | команда запускалась на HEAD `8bf3621`, результат зафиксирован в логах t10 (§2) |
| **автотест (integrated)** | тест входит в сведённую сборку и пройден в combined-прогоне `verify_all` (§7.1) |
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

* **Baseline** = HEAD `8bf3621`, бинарник `b37d4dfc…`. Это §7 и таблица §10.1.
* **After** = сведённая сборка после интеграции всех принятых патчей. Это §7.1,
  §8 и таблица §10.2. Baseline-бинарник SHA-256 не менялся (тот же файл), C# DLL
  тоже — их хеши в §2.
* Итоговый JSON combined-прогона: `tests/.verify_port_work/run_*/report.json`
  (gitignored).

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
| `src/bp/util.mojo` | 130 | чтение/запись UTF-8, BOM, CRLF/LF/CR, пути, `usage` | `Program.cs:35,43`, `File.ReadAllLines`, `Path.*` | **автотест (integrated)**: `util_test.mojo` (199 стр.) |
| `src/bp/diag.mojo` | 53 | накопление и печать диагностик | `DataTemplates/Errore.cs`, `ErrorShow.cs` | статически |
| `src/bp/json.mojo` | 638 | минимальный JSON-парсер/сериализатор для LSP | нет (новая функциональность) | **автотест (integrated)**: `json_test.mojo` (276 стр.) + `tools/tests/test_lsp.py` |
| `src/bp/lexer.mojo` | 788 | стадии 1–2: `LineBuilder` + `TokenBuilder` | `Utils/LineBuilder.cs`, `Utils/TokenBuilder.cs` | **автотест (integrated)**: `lexer_test` OK |
| `src/bp/preproc.mojo` | 938 | include/import, `CreateFullPath`, модули | `Parsers/IncludeErrorParser.cs`, `ImportErrorParser.cs`, `Utils/Preprocessor.cs` | **автотест (integrated)**: `preproc_test.mojo` (415 стр.) + `tests/regression/expansion/**` |
| `src/bp/expand.mojo` | 2130 | развёртка BP → `~Имя.bp`, линковка | `Utils/Interpreter.cs`, `Utils/Linker.cs`, `Utils/MediaBuilder.cs` | **автотест (integrated)**: `difftest.sh expand` 40 pass/0 fail/1 known-skip; `preproc_test` (вкл. root-level путь) |
| `src/bp/builtins.mojo` | 169 | имена/типы builtin-классов | `DataTemplates/DefaultObjectList.cs` | статически + сверка 284/284 в t10 (VERDICTS K) |
| `src/bp/compiler3.mojo` | 3078 | стадия 3: сканер+компилятор → `.lmsb` | `Compiler/Scanner.cs`, `Compiler/Compiler.cs`, `Expression.cs`, `FunctionDefinition.cs` | **автотест (integrated)**: `difftest_lmsb` 46/46 + `compiler3_test.mojo` (264 стр.) |
| `src/bp/compiler3_resources.mojo` | 5176 | **generated**: тексты 33 `c_*.txt` как константы | `Compiler/Resources/c_*.txt` | generated, руками не правится; сверка хешей 33/33 в t10 |
| `src/bp/asm.mojo` | 1957 | стадия 4: `.lmsb` → `.rbf`, атомарная публикация | `Assembler/*.cs` | **автотест (integrated)**: `difftest_rbf` 46/46, `asm_test.mojo` (746 стр.), `tools/tests/test_asm_write.py` |
| `src/bp/buildcmd.mojo` | 126 | `bp compile` / `bp check` | `Builder.cs:79-140` | **автотест (integrated)**: `buildcmd_test` OK на self-contained фикстурах |
| `src/bp/flash.mojo` | 1223 | USB hidraw / BT / Wi-Fi, кадры, заливка | `Clever/Brick/Communication/EV3Connection*.cs`, `CleverDeploy/EV3Connection.cs` | **автотест (integrated)**: `flash_test` OK, `test_cli_flash.py` 93/93 strict; **hardware — непроверено** |
| `src/bp/lsp.mojo` | 1156 | LSP-сервер (stdio, JSON-RPC) | нет (новая функциональность; идеи из `Clever/Model/Intellisense`, но не порт) | **автотест (integrated)**: `tools/tests/test_lsp.py` 15/15; `lsp_test.mojo` (21 стр.) — smoke; **GUI — непроверено** |
| `src/bp/main.mojo` | 183 | CLI-диспетчер команд | `InterpreterConsole/Program.cs` | **автотест (integrated)**: используется всеми гейтами; rc-контракт — `test_cli_flash.py`/`test_asm_write.py` |

Тесты в `src/bp/` (входят в дерево, не production):

| Файл | Строк | Статус |
|---|---:|---|
| `lexer_test.mojo` | 473 | integrated OK |
| `selftest.mojo` | 85 | integrated OK на своей фикстуре (`tools/tests/fixtures/selftest/`); внешний путь больше не нужен |
| `buildcmd_test.mojo` | 79 | integrated OK с фикстурами (`BP_BUILDCMD_FIXTURES`) |
| `flash_test.mojo` | 594 | integrated OK |
| `lsp_test.mojo` | 21 | smoke: сервер стартует и доходит до EOF; глубокая проверка — `tools/tests/test_lsp.py` |
| `util_test.mojo` | 199 | integrated OK |
| `compiler3_test.mojo` | 264 | integrated OK |
| `preproc_test.mojo` | 415 | integrated OK |
| `asm_test.mojo` | 746 | integrated OK |
| `json_test.mojo` | 276 | integrated OK (`JSON_TEST OK`) |

### 3.1. Ресурсы `src/bp/resources/c_*.txt`

34 файла: ≈110 КиБ содержимого (≈204 КиБ занято на диске блоками), все —
байт-в-байт копии `Clev3r-1/Interpreter/Compiler/Resources/c_*.txt`
(34/34 `cmp` OK против `cs_mirror`). Перечень:

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
* Итого констант в `compiler3_resources.mojo` — **33** (32 `readLibrary` +
  `c_NativeCode`), не 34 и не 32.
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
| `install.sh` | `uv sync` + сборка `tools/bp` + smoke `bp check`; `--with-zed` | статически; запуск в этой среде не производился (сетевые загрузки не выполнялись) |
| `tools/verify_all.sh` | combined-ворота: сборка в уникальный scratch + все Mojo/Python-тесты + грамматика + golden-integrity + difftest | **integrated OK** (rc 0, `VERIFY_ALL OK`); `tools/bp` не перезаписывает |
| `tools/difftest.sh` | стадии expand/lmsb/rbf против `tests/golden` | **integrated**: 40 pass / 0 fail / 1 known-skip на каждой стадии |
| `tools/difftest_lmsb.sh`, `tools/difftest_rbf.sh` | два контура стадии 3/4 по 46 эталонам | **integrated**: 46/46 + rbf-контур 46/46; `pass==0`/вакуумный набор — FAIL |
| `tools/make_golden.sh` | перегенерация эталонов оракулом | dry-run по умолчанию; `--apply` только при полном успехе; в combined **не запускался** |
| `tools/gen_compiler3_resources.py` | генератор ресурсов | сверка «генерация не даёт git diff» в t10 |
| `tools/install_zed_extension.sh` | установка dev-расширения Zed из пребилдов | **integrated**: XDG/`ZED_DATA_DIR`, `rev` из манифеста, режим index и symlink; `test_editor_install.py` 29/29 |
| `tools/grammar/check_corpus.sh` | tree-sitter разбор корпуса | **integrated fail-closed**: rc 0/1/2/3, без npx; `TREE_SITTER_CLI=/bin/false` → rc 3 |
| `tools/fake_ev3.py` | TCP :5555 заглушка кирпича | эхо команды + ctr/type/статус; используется `test_cli_flash.py` |
| `tools/fake_ev3_serial.py` | pty-заглушка RFCOMM | то же |
| `tools/probe_stdlib.mojo` | **исследовательский** пробник stdlib Mojo 1.1 | не часть продукта и не часть гейтов; читает `/home/ssssq/...` — в гейты не включать |
| `tools/verify_port.sh` + `tools/port_verify.py` | живой C#-оракул, 41 вход корпуса, targeted/errors, benchmark 6 кейсов | **integrated PASS**; baseline — frozen-артефакт с проверкой SHA (self-alias — setup error) |
| `tools/tests/test_port.py` | **40** негативных/позитивных тестов самих ворот | **integrated OK** (40/40), включая вакуумный корпус, чужой baseline, producer rc!=0 |
| `tools/tests/test_cli_flash.py` | CLI rc + TCP/pty e2e + негативы протокола | **integrated OK** `passed=93 failed=0 skipped=0 strict=1` |
| `tools/tests/test_editor_install.py` | XDG/manifest/rev/index-режим/symlink | **integrated OK** (29/29) |
| `tools/tests/test_lsp.py` | LSP/JSON: изоляция tmp, URI, UTF-16, фрейминг, квадратичность | **integrated OK** (15/15) |
| `tools/tests/test_asm_write.py` | атомарная публикация `.rbf` под RLIMIT_FSIZE/EACCES | **integrated OK**: rc!=0 + sentinel сохранён + нет новых outputs/temp |
| `tools/tests/fixtures/**` | фикстуры гейтов (broken/empty/errors/include/large/module/selftest/small) | используются `verify_all`/`test_port`/`port_verify` |

`grammar/`:

| Файл | Роль | Проверка |
|---|---|---|
| `grammar/grammar.js` | исходник грамматики (530 стр.) | `tree-sitter test` + `check_corpus` (fail-closed) |
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
  Это **40 верхнеуровневых + 6 вложенных** повторных развёрток (два уровня по 3):
  `Functions/~Test1/~~Test1`, `Functions/~Test1/~~Test1/~~Test1`,
  `Other/~Battery/~~Battery`, `Other/~Battery/~~Battery/~~Battery`,
  `Other/~ButtonsAndMotors/~~ButtonsAndMotors`,
  `Other/~ButtonsAndMotors/~~ButtonsAndMotors/~~ButtonsAndMotors`.
  Поэтому «46/46» — это 46 **каталогов эталонов**, а не 46 независимых программ;
  независимых входов с эталоном — **40** (плюс 1 намеренный skip).
  `verify_all` проверяет именно такое разложение: 46 = 40 + 6, 46 `.lmsb`,
  46 `.rbf`; уменьшение набора (например, после `make_golden --apply`, который
  теряет вложенные `~~X`) — FAIL, а не «новый согласованный набор».
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
провал. Именно это исправлено в интегрированной версии ворот (§7.1).

### 7.1. Combined-прогон на сведённой сборке (after)

Выполнен на интегрированном `main` (все принятые патчи в одном дереве), CLI
собран в уникальный scratch, а не в `tools/bp`:

| Команда | rc | Результат |
|---|---:|---|
| `bash tools/verify_all.sh` | **0** | `VERIFY_ALL OK`; 10 Mojo-тестов + 4 Python-хука + `test_port` (40) + grammar (50/50 clean, `tree-sitter test`) + golden 46 (40+6) + difftest 40/0/1 + 46/46 + 46/46 |
| `bash tools/verify_port.sh /home/ssssq/Projects/clev3r_linux/Clev3r-1` | **0** | `VERIFY_PORT PASS`: corpus 40 pass/1 intentional/0 fail, targeted include/module/errors OK, benchmark 6 кейсов + parity |
| `git diff --check` | 0 | пробелов/маркеров конфликтов нет |
| `python3 tools/tests/test_port.py` | 0 | `Ran 40 tests ... OK` |
| `BP_CLI_FLASH_STRICT=1 python3 tools/tests/test_cli_flash.py` | 0 | `passed=93 failed=0 skipped=0 strict=1` |
| `python3 tools/tests/test_lsp.py` | 0 | `test_lsp: OK (15/15)` |
| `python3 tools/tests/test_editor_install.py` | 0 | `Ran 29 tests ... OK` |
| `python3 tools/tests/test_asm_write.py` | 0 | `ASM WRITE OK` (rc!=0 + sentinel/нет outputs/нет temp) |
| `TREE_SITTER_CLI=/bin/false tools/grammar/check_corpus.sh <file>` | **3** | fail-closed (нельзя получить зелёный без работающего парсера) |

Что этим **не** доказано: GUI Zed, WASM-хост и живой EV3 (нет среды/железа);
полный паритет языка (missing features — §8); свежая сборка C# из исходников
(нет SDK — используется существующий DLL с `DOTNET_ROLL_FORWARD=LatestMajor`).

---

## 8. Статусы исправлений (интегрировано)

Ниже — по каждой группе патчей: суть, доказательство, что **нельзя** утверждать.
Все перечисленные группы уже влиты в `main` и пройдены combined-прогоном (§7.1).

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

### 8.2. Ассемблер: `3fde3bc` + `cceac61` + `7abcada` — **интегрировано**

* `assemble_file` больше не пишет `.rbf` при любой ошибке разбора/интеграции:
  образ собирается в памяти (`build_output`), файл пишется только при пустом
  списке ошибок; существующий `.rbf` при ошибке остаётся побайтно прежним
  (C#: `Assembler.cs:70-108`, `Builder.cs:113-137`).
* Тест `asm_test.mojo` — регрессии на bad opcode/unknown id/unclosed object/
  missing label/subcall/bad directive/sentinel, границы кодирования констант,
  метки назад/вперёд, квирк `UI_DRAW TEXTBOX = 84 81 20`.
* Публикация `.rbf` атомарна: временный файл в каталоге цели (`mkstemp`),
  `pwrite` всех байт, `fchmod`, `fsync`, `close`, затем `rename`; любой сбой до
  `rename` удаляет временный файл и оставляет старый `.rbf` побайтно прежним.
  `tools/tests/test_asm_write.py` на реальной golden-программе (1957 Б) под
  `RLIMIT_FSIZE` (0/1/512/1024) проверяет **rc != 0**, сохранённый sentinel
  (2057 Б), отсутствие нового `.rbf` и отсутствие `.tmp`-файлов; при 2000/4096 —
  rc 0 и побайтное равенство эталону. Permission-сценарии (read-only каталог,
  файл 0444) реально выполняются при euid != 0 (в этой среде euid 1000).
* `rename` меняет inode: жёсткие ссылки на старый файл продолжают указывать на
  старый inode; владелец/группа/ACL/xattr **не переносятся**; режим (mode)
  восстанавливается `fchmod`; symlink-цель явно отклоняется. Отдельного
  ACL-фреймворка нет — это осознанная цена атомарности.
* **Нельзя** заявлять устойчивость к отключению питания: каталог не fsync'ится.
* Портабельность: код без raw syscall и без чтения `struct stat` кроме `st_mode`,
  но **тестирован только Linux x86-64**; macOS/ARM не проверялись и не
  заявляются.
* Квирк комментария одиночным `/` совпадает с C# — **не менялся**.

### 8.3. expand/preproc: `e628834` + integration-фикс root-level — **интегрировано**

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
* Root-level абсолютный вход: `resolve_project_path("/Main.bp", "")` возвращает
  `/`, а не `./` (`dir_name("/Main.bp") == ""`, но реальный родитель — корень
  ФС, как `FileInfo.DirectoryName` в C#). Регрессия в `preproc_test` проверяет
  контракт чисто (без записи в корень); голое имя, `./`, подкаталог и явный
  `project_dir` не изменились.
* Полные `ModuleErrorParser`/`StructErrorParser` и каталог имён **не портированы**:
  остаются пробелы валидации. **Нельзя** называть это full parity.

### 8.4. CLI/flash: `71982b3` + `63e6675` + `9da6d30` — **интегрировано**

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
* CREATE_DIR — **fail-closed**, а не best-effort: принимается только `00 SUCCESS`
  или `07 FILE_EXISTS`, любой другой статус/чужое эхо/обрезка/молчание — abort до
  BEGIN (с заливкой ничего не отправлено). `03 FILE_EXISTS` не считается успехом.
* Провода: счётчик команд — **u16**; ошибки использования CLI (`missing operand`)
  → rc != 0; `help`/`-h`/`--help`/без аргументов → rc 0.
* `test_cli_flash.py` проходит в strict-режиме: `passed=93 failed=0 skipped=0
  strict=1`; `verify_all` запускает его с `BP_CLI_FLASH_STRICT=1` и принимает
  только такую сводку.
* **Hardware — непроверено.** Заглушки доказывают алгоритм кадров, а не реальный
  обмен с кирпичом; USB/Bluetooth на живом EV3 не проверялись.

### 8.5. Грамматика/инсталлер: `6e23cd0` + `677003d` — **интегрировано**

* `check_corpus.sh` fail-closed: rc 0/1/2/3, без скачивания зависимостей,
  разрешает относительные аргументы из любого cwd, работает из каталога
  грамматики.
* `install_zed_extension.sh`: уважает `ZED_DATA_DIR`/`XDG_DATA_HOME`; проверяет
  `index.json` и манифест **до** копирования; `rev` берётся из `extension.toml`
  (а не `master`); сохраняет режим index-файла и пользовательский symlink;
  `lib.version` — полная SemVer из `Cargo.lock` (`0.7.0`), без выдуманного
  диапазона `0.7`.
* Исходник `grammar/` и пребилды Rust **не изменялись**.
* Проверено в combined: `tools/grammar/check_corpus.sh` на корпусе — 50 файлов,
  50 clean, 0 ERROR/MISSING, 0 CLI failures; `cd grammar && tree-sitter test` OK;
  `TREE_SITTER_CLI=/bin/false` и несуществующий CLI → rc 3 (не ложный зелёный);
  `test_editor_install.py` — 29/29 OK.
* **Не проверено:** реальный Zed GUI и WASM-хост (сборка/загрузка расширения) —
  только ручная проверка, воротами не покрывается.
* **Риск, задокументированный, а не устранённый:** index.json заменяется
  сериализованно; параллельная запись Zed может потерять обновление. Установку
  выполнять при закрытом Zed / эксклюзивно; гарантий конкурентности нет.
* `rev = 76081a635ac2fa0dbb6d0727c043a996a599603d` **не менять**.
* Инсталлер использует `tomllib` → требует **Python ≥ 3.11** (в проекте
  `pyproject.toml` — `>=3.14`); **не** обещать работу на старых python.

### 8.6. Ворота/харнесс: `fd112e2` + `7b5bd0d` + integration-фиксы — **интегрировано**

* `verify_all.sh`: собирает CLI в **уникальный** scratch (не в `tools/bp`),
  экспортирует `BP_BINARY`; отсутствие любого теста — `FAIL("MISSING")`, а не
  молчаливый skip; проверяет rc каждой стадии и вызывает все Mojo-тесты
  (`lexer/util/compiler3/preproc/asm/json/lsp`), `selftest`, `flash_test`,
  `buildcmd_test`, все Python-хуки (`test_port`, `test_cli_flash`,
  `test_editor_install`, `test_lsp`, **обязательный** `test_asm_write`),
  грамматику и golden-integrity.
* `test_cli_flash` запускается с `BP_CLI_FLASH_STRICT=1`; wrapper принимает толькo
  фактическую сводку `passed=… failed=… skipped=… strict=1` при `failed=0
  skipped=0` и строке `CLI_FLASH_TEST OK`; отсутствие сводки (fake success) — FAIL.
* `make_golden.sh`: staging в temp, dry-run по умолчанию, `--apply` только после
  полного успеха и `rc==0` оракула, старый golden сохраняется/восстанавливается.
* `difftest_lmsb.sh`/`difftest_rbf.sh`: `pass==0` или вакуумный rbf-контур — FAIL;
  отсутствие `.lmsb`/`.rbf`-оракула у сверяемого входа — FAIL (не skip).
* `port_verify.py`: пустой вход — exact `b""` и у current, и у оракула;
  `b"\n"` разрешён **только** для старого baseline и классифицируется как
  `known-prefix-newline-only-baseline`. Это **не** намеренное отличие текущего
  порта: это зафиксированный PRE-fix дефект baseline (`e628834` его исправил).
  Любой другой пустой mismatch — FAIL.
* `port_verify.py`: self-comparison (baseline = current по пути) — setup error
  (rc 2); отсутствие baseline/фикстур/оракула — setup error без traceback.
* `verify_port.sh`: живой C#-оракул (существующий DLL, SDK не нужен), 41 вход
  корпуса (40 pass + 1 intentional), include/module/errors, benchmark
  baseline/current/oracle: **6 кейсов** (small, BrickBench, Generated3000 — 3052
  строки, include, module, empty), warmup 3 / 9 замеров, median/min/max + сырые
  выборки, повтор при регрессии >10% (§10.2).
* Дефекты t11 закрыты и подтверждены `tools/tests/test_port.py` (40 тестов):
  `difftest_lmsb` pass>0 guard и не-вакуумный rbf-контур; `make_golden` rc
  оракула; `buildcmd_test` → rc!=0 при семантическом FAIL; exact-empty;
  self-alias; setup-ошибки rc 2; уникальный scratch.
* **Границы:** baseline-артефакт gitignored; `verify_port` по умолчанию ищет
  известный сохранённый run t10 с проверкой SHA-256, при его отсутствии —
  ненулевой exit с требованием `BP_BASELINE_BINARY`. Обещания «любой будущий
  клон найдёт baseline» нет.

### 8.7. LSP/JSON: `b580bcc` + `6342e28` — **интегрировано**

* приватный process-temp каталог вместо общего `/tmp/bp_lsp_docs`;
  include резолвится относительно реального URI документа;
  `id: null` даёт валидный JSON; hover считает позиции в UTF-16;
  ошибки I/O публикуются явно, а не «пустым» списком; anchor раскрытых
  диагностик — 0 (честная строка, не выдуманная);
  фрейминг: тело ≤ 16 MiB, глубина JSON ≤ 128.
* `file://` URI percent-escape корректен (localhost и remote-хосты
  отвергаются по правилам).
* JSON-арена: append детей O(1) — квадратичность `JSON_link_child` устранена;
  тест на широких/вложенных фреймах: массив 204798 Б = ≈0.10 с, объект 122878 Б
  = ≈0.005 с (линейно, не >15 с). Подозрение на квадратичность `json_dump` —
  **опровергнуто**: отдельного дефекта нет, правки не потребовались.
* `json_test.mojo` — `JSON_TEST OK`; `tools/tests/test_lsp.py` — 15/15 OK
  (изоляция tmp двумя процессами, URI, UTF-16, framing fail-closed,
  анализ-ошибка не «чисто», без внутренних путей).
* Completion берётся из **31** ключевого слова + **31** builtin-класса
  (`grammar/grammar.js` — источник истины).

**Ещё не сделано / нельзя утверждать:**

* `definitionProvider` **не реализован** — переходы к определению в Zed не
  заявляются;
* GUI Zed и WASM-хост — **только ручная проверка**, воротами не покрыты;
* готовых хоткеев в репозитории нет: `.zed/tasks.json` и
  `zed-extension/tasks.json` — **задачи**, а не привязки клавиш; привязку делает
  пользователь в своём `keymap.json`.

---

## 9. Гейты: что именно можно и нельзя утверждать

| Утверждение | Можно? | Почему |
|---|---|---|
| «Движок компиляции совпадает с оракулом на корпусе» | да, для 40 независимых входов | `verify_port`: corpus 40 pass / 1 intentional / 0 fail; `difftest` 40/0/1 |
| «43 pass» | только как историческое «43 входа, включая сгенерированные» | baseline-`difftest` считал `~*.bp`; интегрированный гейт даёт 40/0/1 |
| «46/46 по эталонам» | да, с оговоркой | 46 = 40 верхнеуровневых + 6 вложенных вариантов; оба контура (lmsb и rbf) 46/46 |
| «46 независимых программ» | **нет** | 46 — число каталогов эталонов; 6 из них вложенные (два уровня по 3) |
| «полный паритет» | **нет** | §8.1/8.3: missing validators, каталог ошибок, кодировки |
| «GUI/Zed проверен» | **нет** | нет живого Zed; есть только hermetic-тесты инсталлера |
| «железо проверено» | **нет** | нет EV3; USB/BT/Wi-Fi — только заглушки |
| «все тесты зелёные» | да, **для combined-прогона** | `VERIFY_ALL OK` + `VERIFY_PORT PASS` (§7.1); но не покрывает GUI/железо/cross-OS |
| «все функции быстрее» | **нет** | §10.2: выигрыш к C# на всех 6 кейсах, но current vs baseline в пределах шума (±9%) |

---

## 10. Измерения

Обе таблицы сняты на одной машине (Linux x86-64), одним и тем же способом:
warmup 3, 9 замеров, `perf_counter` вокруг `subprocess.run`, выходы удаляются
перед каждым прогоном, сравнение байтов — вне timed-секции. В интегрированном
харнессе инструменты замеряются **interleaved с ротацией порядка** по итерациям:
на этой машине частота CPU чередует быстрый/медленный режимы, и фиксированный
порядок давал первому инструменту до ~40% форы (ложные >10% на 20-мс кейсах).
Пороги регрессии не менялись (`>10%` медианы и `>1 мс`), при срабатывании
делается повторный замер; в итоговом прогоне все три срабатывания опровергнуты
повтором (§10.2).

### 10.1. Исторический baseline-сеанс t10 (НЕ after, для сравнения не используется)

Источник: `tests/.oracle_work/t10_20261118T100051/logs/measurements.json`.

| Кейс | Mojo baseline, мс | C# оракул, мс | Отношение | Паритет `.lmsb`/`.rbf`/`~.bp` |
|---|---:|---:|---:|---|
| small_Test1 | 21.79 | 305.46 | 14.0× | да/да/да |
| large_BrickBench | 35.69 | 318.31 | 8.9× | да/да/да |
| large_Generated3000 (3052 строки) | 104.02 | 598.75 | 5.8× | да/да/да |
| include_Main | 21.93 | 267.17 | 12.2× | да/да/да |
| module_Main | 21.89 | 276.38 | 12.6× | да/да/да |
| startup_empty | 20.58 | 204.04 | 9.9× | да/да/**нет** (`b"\n"` vs `b""` — PRE-fix дефект baseline, исправлен интегрированным `e628834`) |

Абсолютные числа этого сеанса **несопоставимы** с §10.2: вся машина в том
сеансе была медленнее (например, C# на small — 305 мс против 129 мс сейчас).
Поэтому в §10.2 все три инструмента перемерены заново в одном сеансе.

### 10.2. Combined after: baseline / current / C# (warmup 3, 9 замеров)

Источник: итоговый combined-прогон `verify_port` на HEAD с исправлениями —
`tests/.verify_port_work/run_20261119T092554Z_3462283/report.json`
(`VERIFY_PORT PASS`, rc 0); предыдущий passing-прогон
`run_20261119T092311Z_3446414` дал те же порядки (см. ниже). `baseline` —
frozen-бинарник `b37d4dfc…` (SHA-256 проверен), `current` — свежая сборка
интегрированного `main` в scratch, `oracle` — существующий
`InterpreterConsole.dll` (`39d03dfa…`) с `DOTNET_ROLL_FORWARD=LatestMajor`
(SDK в среде нет — свежая сборка C# **не** доказывается).

| Кейс | baseline, мс | current, мс | C#, мс | current/baseline | C#/current | Паритет current vs C# |
|---|---:|---:|---:|---:|---:|---|
| small (Test1) | 15.30 | 17.01 | 131.06 | 1.112 (повтор 0.956) | 7.70× | равен |
| BrickBench (274 стр.) | 22.90 | 24.11 | 144.02 | 1.053 | 5.97× | равен |
| Generated3000 (3052 стр.) | 59.49 | 56.27 | 255.54 | 0.946 | 4.54× | равен |
| include (Main + 2 `.bpi`) | 15.32 | 19.51 | 124.20 | 1.273 (повтор 1.064) | 6.37× | равен |
| module (Main + `.bpm`) | 16.15 | 16.78 | 141.00 | 1.039 | 8.40× | равен |
| empty (старт) | 13.97 | 20.01 | 92.04 | 1.432 (повтор 1.064) | 4.60× | равен (exact `b""` у current и C#) |

Для сравнения, предыдущий passing-прогон (`…092311Z`): 15.18/16.26/132.25,
23.19/30.64/141.60, 55.81/55.77/251.65, 16.25/17.00/125.50, 15.56/21.42/136.94,
14.95/19.38/94.88 — тот же порядок, C#/current 4.51–8.13×.

Где исходные samples/median/min/max: `benchmark.<case>.timings.*` и
`benchmark.<case>.repeat.*` в `report.json`.

Как читать честно:

* Порядок величин: Mojo-порт быстрее C#-оракула в **4.5–8.4×** на всех шести
  кейсах (в двух passing-прогонах — 4.51–8.40×), это медианы по 9 замерам
  после 3 прогревочных, а не единичный удачный запуск.
* **Нельзя** говорить «всё ускорилось» и нельзя брать первый блок как истину:
  на этой машине частота CPU ходит между режимами, поэтому часть кейсов дала
  первый ratio 1.11–1.43, а повторный замер — 0.96–1.07
  (`noise-refuted-by-repeat`, пороги 10%/1 мс не менялись).
* Контрольный A/B с закреплённым CPU (`taskset -c 2`, ротация порядка,
  20–50 замеров на кейс) даёт устойчивое отношение current/baseline:
  empty 1.035, small 1.035, BrickBench 1.071, Generated3000 1.030 — т.е.
  интегрированная сборка медленнее frozen-baseline на ~3–7% на этих кейсах
  (бинарник вырос с 1 492 600 до 1 553 024 Б: добавлен код валидаторов,
  UTF-16-обработки и LSP/JSON). Это **меньше** порога 10%, но **не** «шум 0%»:
  стартово-связанные кейсы действительно чуть медленнее.
* `current == C#` по sha256 всех выходов на всех шести кейсах (включая `.lmsb`,
  `.rbf`, `~.bp`); для `empty` — exact `b""`.
* Старый baseline отличается от current только `~empty.bp` (`b"\n"` vs `b""`) —
  это PRE-fix дефект, а не намеренное отличие текущего порта.
* Бенчмарк ничего не «тюнил»: никаких спекулятивных оптимизаций в этой
  интеграции не делалось; менялась только методика замера (interleaved +
  ротация порядка), чтобы не выдавать дрейф частоты CPU за регрессию.

---

## 11. Что сделано при интеграции и что осталось за границей

Сделано (combined-прогон — §7.1):

1. 16 принятых коммитов интегрированы в `main` в порядке зависимостей
   (16 отдельных cherry-pick, без конфликтов); карта old→new — в постоянном
   отчёте интеграции `tests/.verify_port_work/`.
2. Починены дефекты харнесса (§8.6) и integration-дефекты: root-level
   `resolve_project_path` (§8.3), grammar-hook cwd/fail-closed в `verify_all`,
   strict-summary `test_cli_flash`, обязательные `json_test`/`preproc_test`/
   `test_asm_write.py`, честный учёт golden 40+6, `test_asm_write` с rc!=0.
3. `bash tools/verify_all.sh` → rc 0, `bash tools/verify_port.sh
   /home/ssssq/Projects/clev3r_linux/Clev3r-1` → rc 0 (frozen baseline найден по
   умолчанию и проверен по SHA-256), `git diff --check` → 0.
4. §10 содержит **фактические** after-цифры, §8 — без пометок `pending`.
5. golden/исходный C#/baseline-бинарник не изменялись; `make_golden --apply`
   не запускался.

**Что осталось за границей (и не должно заявляться как проверенное):**

* живой EV3 (USB/Bluetooth/Wi-Fi), реальный Zed GUI и WASM-хост;
* macOS/ARM и Windows-нативно (тестировано только Linux x86-64);
* свежая сборка C# из исходников (нет SDK — только существующий DLL);
* полный паритет языка: непортированные валидаторы, `ErrorsCodeList`,
  кодировки C# кроме UTF-8, `definitionProvider`;
* параллельная запись `index.json` установщиком и открытым Zed (гонка не
  устранена, только задокументирована).

Полный паритет и «всё проверено» по-прежнему **не** заявляются.

Как предоставить baseline, если артефакт `b37d4dfc…` недоступен: собрать
бинарник из чистого коммита `8bf3621` (`uv run mojo build src/bp/main.mojo -o
baseline/bp`), проверить SHA-256, передать путь через `BP_BASELINE_BINARY`
(и `BP_BASELINE_SHA256`). Гарантии «клонируй и всё сойдётся» нет: baseline
намеренно не коммитится.
