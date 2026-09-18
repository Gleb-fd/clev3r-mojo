# Clev3r Mojo

Порт компилятора **Clev3r / Basic Plus** (язык для LEGO MINDSTORMS EV3) с C# на **Mojo**, плюс
анализатор/LSP и нативная интеграция с редактором **Zed**.

## Зачем

Оригинальный Clev3r — Windows/.NET-приложение. Здесь тот же язык и тот же байткод, но:

* компилятор и анализатор написаны на Mojo (один статический бинарник, без .NET);
* LSP-сервер даёт диагностику, автодополнение, hover и переходы прямо в Zed;
* заливка на кирпич из CLI: USB (hidraw), Bluetooth (SPP) и Wi-Fi (TCP :5555);
* tree-sitter грамматика даёт нативную подсветку и outline.

## Установка

Linux (x86-64). Нужны `git`, `python3`, `curl`; Mojo и всё остальное ставится само.

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
tools/bp compile tests/corpus/Functions/Functions.bp
```

Рядом с исходником появится `~Functions/Functions.rbf` — тот самый байткод EV3.

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

В Zed те же действия повешены на хоткеи (см. `.zed/tasks.json` + `~/.config/zed/keymap.json`):
Ctrl+Alt+F — USB, Ctrl+Alt+W — Wi-Fi, Ctrl+Alt+T — Bluetooth, Ctrl+Alt+M — только компиляция.
Адреса кирпича задаются в `.zed/tasks.json`.

## Сравнение с оригиналом

Замеры на одном ноутбуке x86-64, файл на 3768 строк (листинг 12 008 строк, байткод 84.7 КБ),
медиана нескольких прогонов:

| | C# оракул | Mojo |
|---|---|---|
| Полный цикл компиляции | 294 мс | 93 мс |
| Стартовая накладка (пустой вход) | ~102 мс | ~11 мс |

Корректность: компилятор верифицируется против C#-оракула дифференциальными тестами
(`tools/difftest.sh`): развёртка, листинг и байткод совпадают побайтово на всём корпусе,
включая сгенерированные стресс-файлы с плотной булевой логикой.

## Платформы

Компилятор (`lex/expand/compile/check/lmsb/rbf/lsp`) — чистая обработка файлов,
собирается везде, где есть Mojo. Заливка (`bp flash`) пока завязана на Linux:
сканирование `/sys/class/hidraw`, RFCOMM-сокеты BlueZ, raw-termios, номера
syscall'ов x86-64.

* **Windows** — компилятор работает в WSL2; заливка по Wi-Fi тоже (сеть общая
  с Windows), USB-кирпич пробрасывается через `usbipd-win`.
* **macOS / Windows нативно** — нужен свой транспортный слой вместо hidraw/BlueZ
  (IOKit/HID, hid.dll, WinSock RFCOMM). Логика команд и кадров в `flash.mojo`
  отделена от транспорта и переиспользуется как есть.

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

## CLI (контракт)

| Команда | Смысл |
|---|---|
| `bp lex <file>` | стадии 1-2: канонические строки (для отладки лексера) |
| `bp expand <file.bp> [outdir]` | препроцессор + линковка → `~<Имя>.bp` (outdir = путь библиотек модулей) |
| `bp compile <file.bp> [outdir]` | полный цикл → `~<Имя>.bp` + `.lmsb` + `.rbf` |
| `bp check <file.bp>` | диагностики (текст; код 3000 = маркер стадии lmsb) |
| `bp flash <file.bp\|file.rbf> [target]` | компиляция (для `.bp`) + заливка: USB `usb[:dev]` (по умолчанию), Bluetooth `bt:MAC`, Wi-Fi `wifi:IP`, `/dev/rfcommN`, `dry` |
| `bp lsp` | LSP-сервер (stdio): диагностика/hover/completion |

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

## Статус

* [x] Спецификации извлечены из C#: 01 лексер/грамматика, 02 препроцессор/линковка, 03 builtins+опкоды, 04 форматы, 05 диагностики, 06 hidraw-заливка
* [x] Golden-корпус: `tools/difftest.sh` — **expand/lmsb/rbf: 43 pass, 0 fail, 1 skip** (skip = New_Path_Examples — у оракула нет эталона, баг с `..`)
* [x] Лексер стадий 1-2 — верифицирован против C#-оракула: 0 расхождений (корпус + 146 кейсов + 8000 фаззинг)
* [x] Развёртка/линковка → `~Name.bp` байт-в-байт, включая include (`.bpi`) и import (`.bpm`): `src/bp/preproc.mojo` + модульная линковка в `expand.mojo`; квирки break_N/continue_N, порядок init-переменных, медиа-пути — по C# (docs/notes-expansion-questions.md закрыт)
* [x] Стадия 3 (`.lmsb`, компилятор) — побайтно против C#-оракула: 46/46 эталонов `.lmsb` + Program1 (5505 Б) байт-в-байт; второй контур — свой `.lmsb` → `bp rbf` → 46/46 эталонных `.rbf`
* [x] Стадия 4 (`.rbf`, ассемблер) — побайтно против C#-оракула: 46/46 эталонов + Program1 (1015 Б) байт-в-байт
* [x] `bp compile` (сцепка expand→lmsb→rbf, паритет с golden) и `bp check` (диагностики expand + стадии 3, код 3000 = маркер lmsb)
* [x] LSP-сервер (`src/bp/json.mojo` + `src/bp/lsp.mojo`): initialize, didOpen/didChange → publishDiagnostics реальным конвейером (expand + стадия 3), hover по builtin-классам, completion из 30 ключевых слов + 31 класса; smoke-тесты через stdin/stdout — OK
* [x] tree-sitter грамматика (`grammar/`, 0 ERROR на 50 файлах корпуса) + Zed-расширение (`zed-extension/`: подсветка/скобки/отступы/outline, LSP на `tools/bp lsp`, tasks); установка: Zed → Install Dev Extension → `zed-extension/`
* [x] Заливка на кирпич из CLI (`bp flash`, `src/bp/flash.mojo`): три транспорта — USB (hidraw), Bluetooth (RFCOMM-сокет или `/dev/rfcommN` в raw-режиме), Wi-Fi (TCP :5555 с handshake `Accept:EV340`); кадры BEGIN/CONTINUE_DOWNLOAD + PROGRAM_START 1:1 со старым путём; framing-тесты (`FLASH_TEST OK`), dry-run и сквозные тесты на заглушках кирпича (`tools/fake_ev3.py`, `tools/fake_ev3_serial.py`) — файл на кирпиче собирается байт в байт; **живой обмен требует проверки на железе** (docs/06 §7)
* [x] Установка: `install.sh` (сборка + смоук-тест) и `tools/install_zed_extension.sh` (пребилд расширения Zed без rust)

Полная проверка: `bash tools/verify_all.sh`.

## Известно и отложено

* Модули `.bpm` покрыты оракулом лишь косвенно: единственный модульный кейс (`New_Path_Examples`) — skip без эталона.
* Заливка нового `Program1.rbf` от Mojo-конвейера на живой кирпич и сравнение поведения — отдельный шаг (нет железа).
* `zed-extension/extension.toml` пинит грамматику по `rev`: после коммитов обновить хеш.