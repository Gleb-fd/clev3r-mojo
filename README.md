# Clev3r Mojo

Порт компилятора **Clev3r / Basic Plus** (язык для LEGO MINDSTORMS EV3) с C# на **Mojo**, плюс
анализатор/LSP и нативная интеграция с редактором **Zed**.

## Зачем

Оригинальный Clev3r — Windows/.NET-приложение. Здесь тот же язык и тот же байткод, но:

* компилятор и анализатор написаны на Mojo (один статический бинарник, без .NET);
* LSP-сервер (`bp lsp`) даёт диагностику, автодополнение и hover прямо в Zed
  (переходы к определению пока не реализованы — см. `docs/port-audit.md`);
* заливка на кирпич из CLI: USB (hidraw), Bluetooth (SPP) и Wi-Fi (TCP :5555);
* tree-sitter грамматика даёт нативную подсветку и outline.

## Установка

Linux (x86-64). Нужны `git`, `python3` (≥ 3.11 — инсталлер расширения использует
`tomllib`; проектный `pyproject.toml` требует ≥ 3.14) и `curl`; Mojo ставится сам.

```bash
git clone https://github.com/Gleb-fd/clev3r-mojo.git
cd clev3r-mojo
./install.sh              # соберёт tools/bp и прогонит смоук-тест
./install.sh --with-zed   # + расширение Basic Plus для Zed (пребилд, rust не нужен)
```

После `--with-zed` перезапусти Zed: файлы `.bp/.bpi/.bpm` откроются как Basic Plus.
LSP найдёт компилятор сам, если открыт проект с `tools/bp` внутри или `bp` есть в PATH.

Быстрая проверка без Zed:

```bash
tools/bp compile tests/corpus/Functions/Test1.bp
```

Рядом с исходником появится `tests/corpus/Functions/~Test1/Test1.rbf` — тот самый
байткод EV3.

## Быстрый старт: заливка на кирпич

```bash
tools/bp flash prog.bp                        # USB-кабель (автовыбор hidraw)
tools/bp flash prog.bp wifi:192.168.1.42      # Wi-Fi (IP виден на экране кирпича)
tools/bp flash prog.bp bt:00:16:53:XX:XX:XX   # Bluetooth (кирпич должен быть спарен)
tools/bp flash prog.bp dry                    # напечатать кадры, ничего не отправляя
```

`.bp` при заливке компилируется сам. Для Wi-Fi включи Wi-Fi в меню кирпича и
подключи его к той же сети, что и компьютер. Для Bluetooth спарь кирпич
(`bluetoothctl pair XX:XX:...`) или используй `/dev/rfcommN` после `rfcomm bind`.

В Zed те же действия оформлены как задачи (`.zed/tasks.json`): сборка, `check`,
`compile`, прошивка по USB/Wi-Fi/Bluetooth. **Готовых привязок клавиш в репозитории
нет** — клавиши вы назначаете сами в своём `~/.config/zed/keymap.json`, сославшись на
нужную задачу. Адреса кирпича (Wi-Fi/Bluetooth) задаются в `.zed/tasks.json`.

## Сравнение с оригиналом

Корректность: компилятор сверяется с C#-оракулом дифференциальными тестами
(`tools/difftest.sh`) по сохранённым эталонам `tests/golden`: развёртка, листинг и
байткод совпадают побайтово на корпусе независимых программ. Это проверка
**поддерживаемого кода на корпусе**, а не доказательство полного паритета языка:
непортированные валидаторы, каталог текстов ошибок и кодировки C# перечислены в
`docs/port-audit.md`.

Скорость (сведённая сборка `main`, один сеанс, warmup 3 / 9 замеров, медианы на
одной машине Linux x86-64; источник — `bash tools/verify_port.sh …`, отчёт
`tests/.verify_port_work/run_*/report.json`, подробно — `docs/port-audit.md` §10.2):

| Кейс | C# оракул | Mojo current | baseline `8bf3621` |
|---|---:|---:|---:|
| small Test1 | 129 мс | 23 мс | 21 мс |
| BrickBench (274 стр.) | 136 мс | 32 мс | 30 мс |
| Generated3000 (3052 стр.) | 256 мс | 57 мс | 57 мс |
| include | 121 мс | 23 мс | 22 мс |
| module | 133 мс | 22 мс | 22 мс |
| пустой вход (старт) | 89 мс | 22 мс | 21 мс |

Как читать: Mojo-порт быстрее C#-оракула в 4.0–6.1× на этих шести кейсах, при
этом `current` относительно `baseline` — в пределах шума (−2.5%…+8.9%), т.е.
интеграция исправлений **не замедлила** компилятор заметно и не «ускорила всё».
Выходы `current` и C# совпадают побайтно на всех шести кейсах.

Исторический сеанс t10 давал другие **абсолютные** числа (например, C# на small —
305 мс): машина была медленнее, сравнивать абсолютные значения между сеансами
нельзя, поэтому все три инструмента перемерены в одном сеансе (см. §10.1/§10.2
`docs/port-audit.md`).

## Платформы

**Фактически тестировано только на Linux x86-64** (компилятор, гейты, тесты,
замеры). Другие платформы не проверялись и не заявляются как поддерживаемые.

Компилятор (`lex/expand/compile/check/lmsb/rbf/lsp`) — чистая обработка файлов и
не содержит raw syscall'ов (атомарная публикация `.rbf` — через libc + stdlib),
поэтому теоретически собирается везде, где есть Mojo, но это **не проверено**.
Заливка (`bp flash`) завязана на Linux: сканирование `/sys/class/hidraw`,
RFCOMM-сокеты BlueZ, raw-termios и номера syscall'ов x86-64.

* **Windows** — компилятор, вероятно, работает в WSL2; заливка по Wi-Fi тоже
  (сеть общая с Windows), USB-кирпич предполагается пробрасывать через
  `usbipd-win`. **Не проверялось.**
* **macOS / Windows нативно** — нужен свой транспортный слой вместо hidraw/BlueZ
  (IOKit/HID, hid.dll, WinSock RFCOMM). Логика команд и кадров в `flash.mojo`
  отделена от транспорта и переиспользуется как есть. **Не проверялось.**

## Пайплайн (как в оригинале — и это важно)

```
Program.bp ──Preprocessor──► (include .bpi, module .bpm)
           ──Interpreter───► ~Program.bp   развёрнутый исходник (gv_/lv_/f_-имена)
           ──Compiler──────► Program.lmsb  ассемблер-листинг (текст)
           ──Assembler─────► Program.rbf   байткод EV3 (бинарник)
```

Каждая стадия — с текстовым или бинарным эталоном, поэтому паритет проверяется поэтапно.

## Эталоны (golden)

`tools/make_golden.sh` прогоняет C#-оракул (`InterpreterConsole`) по корпусу `tests/corpus`
и складывает результат в `tests/golden/<путь>/~<Имя>/`:

| Файл | Что это | Целевая стадия Mojo |
|---|---|---|
| `~<Имя>.bp` | развёрнутый исходник | `bp expand` |
| `<Имя>.lmsb` | ассемблер-листинг | `bp compile` (стадия 3) |
| `<Имя>.rbf` | байткод | `bp compile` (стадия 4) |

Дифференциальный тест: `tools/difftest.sh [stage]`, где stage ∈ `expand | lmsb | rbf`.

Важно про числа: в `tests/golden` **46 каталогов эталонов**, но три из них — вложенные
повторные развёртки (`~~Test1` и т.п.), а не независимые программы. Независимых
входов с эталоном — **40**, плюс 1 известный skip (`New_Path_Examples`: у оракула
нет эталона из-за его собственного бага с `..`). Подробнее — `docs/port-audit.md`.

## CLI (контракт)

| Команда | Смысл |
|---|---|
| `bp lex <file>` | стадии 1-2: канонические строки (для отладки лексера) |
| `bp expand <file.bp> [outdir]` | препроцессор + линковка → `~<Имя>.bp` (outdir = путь библиотек модулей) |
| `bp compile <file.bp> [outdir]` | полный цикл → `~<Имя>.bp` + `.lmsb` + `.rbf` |
| `bp check <file.bp>` | диагностики (текст; код 3000 = маркер стадии lmsb) |
| `bp flash <file.bp\|file.rbf> [target]` | компиляция (для `.bp`) + заливка: USB `usb[:dev]` (по умолчанию), Bluetooth `bt:MAC`, Wi-Fi `wifi:IP`, `/dev/rfcommN`, `dry` |
| `bp lsp` | LSP-сервер (stdio): диагностика/hover/completion (без переходов к определению) |

## Окружение

```bash
uv run mojo --version        # Mojo 1.1.0 из uv-окружения проекта
uv run mojo run src/bp/lexer_test.mojo
uv run mojo build src/bp/main.mojo -o tools/bp
```

## Документы

Спецификации, извлечённые из C#-исходников (каждый факт со ссылкой `File.cs:line`):

* `docs/01-lexer-and-grammar.md` — лексер, грамматика, развёртка, квирки
* `docs/02-preprocessor-includes-modules.md` — include/module, линковка, имена
* `docs/03-builtins-and-opcodes.md` — каталог встроенных методов и opcode'ов
* `docs/04-formats-lmsb-rbf.md` — форматы `.lmsb` и `.rbf` побайтово
* `docs/05-diagnostics.md` — каталог диагностик для компилятора и LSP
* `docs/06-hidraw-usb-notes.md` — транспорты заливки: USB, Bluetooth, Wi-Fi (`bp flash`)
* `docs/port-audit.md` — **карта проверки порта**: что проверено и чем, границы
  утверждений, ограничения и итоговые таблицы замеров (§10.1 baseline, §10.2 after)

## Статус

Статусы ниже — про **наличие и характер проверки**. Сведённый (`combined`) прогон
выполнен на интегрированном `main`: `bash tools/verify_all.sh` → `VERIFY_ALL OK`
(rc 0), `bash tools/verify_port.sh /home/ssssq/Projects/clev3r_linux/Clev3r-1`
→ `VERIFY_PORT PASS` (rc 0). Ниже — итоги; карта доказательств и границы
утверждений — `docs/port-audit.md`.

* [x] Спецификации извлечены из C#: 01 лексер/грамматика, 02 препроцессор/линковка, 03 builtins+опкоды, 04 форматы, 05 диагностики, 06 hidraw-заливка
* [x] Golden-корпус: `tools/difftest.sh` — expand/lmsb/rbf: **40 pass, 0 fail, 1 known skip** на каждой стадии (41 вход корпуса); skip = `New_Path_Examples` (у оракула нет эталона, его баг с `..`). Гейты проверяют коды стадий и падают на устаревших артефактах
* [x] Лексер стадий 1-2 — проверен против C#-оракула на корпусе и точечных репро (`tools/difftest.sh expand`, `lexer_test`). Числа «146 кейсов / 8000 фаззинг» из более ранних ручных прогонов **историчны и не воспроизводимы из репозитория** — здесь они не повторяются
* [x] Развёртка/линковка → `~Name.bp` байт-в-байт, включая include (`.bpi`) и import (`.bpm`): `src/bp/preproc.mojo` + модульная линковка в `expand.mojo`; квирки break_N/continue_N, порядок init-переменных, медиа-пути — по C# (docs/notes-expansion-questions.md закрыт). Но: полные `ModuleErrorParser`/`StructErrorParser` и каталог имён **не портированы** — это не полный паритет диагностик (docs/port-audit.md §8.3)
* [x] Стадия 3 (`.lmsb`, компилятор) — 46/46 побайтно против C#-оракула; учёт честный: **46 каталогов = 40 верхнеуровневых + 6 вложенных** (два уровня по 3), т.е. это не 46 независимых программ; второй контур — свой `.lmsb` → `bp rbf` → совпадение с эталонными `.rbf` (46/46, гейт падает на вакуумном наборе)
* [x] Стадия 4 (`.rbf`, ассемблер) — побайтно против C#-оракула на тех же 46 каталогах. При любой ошибке `.rbf` не создаётся и не портится; публикация атомарна (временный файл + `rename`), сбой записи → rc!=0, старый файл и sentinel целы (`tools/tests/test_asm_write.py`)
* [x] `bp compile` (сцепка expand→lmsb→rbf) и `bp check` (диагностики expand + стадии 3, код 3000 = маркер lmsb). Узкие пробелы закрыты (дубль zero-arg `Function` → 1809, скобки в `.bpm`/`.bpi` → 1001/1002, неразрешённые call/sub/thread → 1806/1606/1414); полные `ModuleErrorParser`/`StructErrorParser` по-прежнему не портированы
* [x] LSP-сервер (`src/bp/json.mojo` + `src/bp/lsp.mojo`): initialize, didOpen/didChange → publishDiagnostics реальным конвейером (expand + стадия 3), hover по builtin-классам, completion из **31** ключевого слова + **31** builtin-класса; приватный temp-каталог, include по URI документа, `id:null`, UTF-16-позиции, честные ошибки I/O, fail-closed фрейминг. `python3 tools/tests/test_lsp.py` — 15/15 OK. **Переходы к определению не реализованы.** GUI Zed — только ручная проверка
* [x] tree-sitter грамматика (`grammar/`): 50/50 файлов корпуса без ERROR/MISSING, `tree-sitter test` OK; проверка **fail-closed** — при нерабочем/отсутствующем CLI (`TREE_SITTER_CLI=/bin/false`) гейт возвращает rc 3, а не ложный зелёный. Zed-расширение (`zed-extension/`: подсветка/скобки/отступы/outline, LSP на `tools/bp lsp`, tasks). Реальный Zed GUI/WASM-хост — **не проверен**
* [x] Заливка на кирпич из CLI (`bp flash`, `src/bp/flash.mojo`): три транспорта — USB (hidraw), Bluetooth (RFCOMM-сокет или `/dev/rfcommN` в raw-режиме), Wi-Fi (TCP :5555 с handshake `Accept:EV340`); ответы кирпича разбираются с эхом команды и payload с offset 4 (как C#), счётчик команд — u16, CREATE_DIR fail-closed (только `00 SUCCESS`/`07 FILE_EXISTS`), ошибки использования → rc!=0. `tools/tests/test_cli_flash.py` — 93/93 в strict-режиме. Framing-тесты и сквозные тесты на заглушках (`tools/fake_ev3.py`, `tools/fake_ev3_serial.py`) доказывают **алгоритм кадров, а не реальный обмен**; **живой EV3 (USB/BT/Wi-Fi) требует проверки на железе** (docs/06 §7)
* [x] Установка: `install.sh` (сборка + смоук-тест) и `tools/install_zed_extension.sh` (пребилд расширения Zed без rust): уважает `XDG_DATA_HOME`/`ZED_DATA_DIR`, берёт `rev` из манифеста, сохраняет режим index-файла и пользовательский symlink; `tools/tests/test_editor_install.py` — 29/29 OK. Для инсталлера нужен **Python ≥ 3.11** (`tomllib`), в проекте — `>=3.14`.

Полная проверка: `bash tools/verify_all.sh` (на интегрированном `main`: `VERIFY_ALL OK`, rc 0).
**Границы:** живой EV3, Zed GUI/WASM-хост и не-Linux платформы **не проверялись**; карта доказательств — `docs/port-audit.md`.

### Команды полной проверки

```bash
bash tools/verify_all.sh                                             # сборка + юнит-тесты + difftest
bash tools/verify_port.sh /home/ssssq/Projects/clev3r_linux/Clev3r-1 # живой C#-оракул + benchmark
git diff --check                                                     # пробелы/маркеры конфликтов
```

`verify_port.sh` требует baseline: по умолчанию берётся сохранённый frozen-артефакт
известного прогона t10 (`tests/.oracle_work/t10_20261118T100051/baseline/bp`) с
обязательной проверкой SHA-256, либо явный `BP_BASELINE_BINARY=/path/to/bp` (с
необязательным `BP_BASELINE_SHA256`). Подмена baseline текущей сборкой
(self-comparison) отвергается как setup error. В репозиторий baseline-бинарник не
входит (gitignored); как его получить и указать — `docs/port-audit.md` §11.

## Известно и отложено

* Модули `.bpm` покрыты оракулом лишь косвенно: единственный модульный кейс (`New_Path_Examples`) — skip без эталона.
* Не портированы: каталог текстов ошибок `ErrorsCodeList` (RU/UA/EN) — порт выдаёт коды и краткие сообщения; полные валидаторы модулей/структур; кодировки входа C# кроме UTF-8 (байтовые колонки, UTF-16LE/BE не автодетектятся).
* LSP: переходы к определению (`definitionProvider`) не реализованы; GUI Zed и WASM-хост проверяются только вручную.
* Заливка нового `Program1.rbf` от Mojo-конвейера на живой кирпич и сравнение поведения — отдельный шаг (нет железа). Запись `.rbf` атомарна (при сбое старый файл цел), но **durability при отключении питания не гарантируется** (каталог не fsync'ится), и `rename` меняет inode: жёсткие ссылки/ACL/xattr/владелец не переносятся, режим сохраняется, symlink-цель отклоняется.
* `zed-extension/extension.toml` пинит грамматику по `rev` (`76081a6…`): после коммитов в `grammar/` обновить хеш и пересобрать пребилды (`zed-extension/prebuilt/*.wasm`).