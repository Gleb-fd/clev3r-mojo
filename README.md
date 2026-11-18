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

Скорость: исходный срез (baseline, коммит `8bf3621`, warmup 3 / 9 замеров,
медианы на одной машине x86-64 из `tests/.oracle_work/.../logs/measurements.json`):

| Кейс | C# оракул | Mojo (baseline) |
|---|---:|---:|
| small Test1 | 305 мс | 22 мс |
| BrickBench | 318 мс | 36 мс |
| Generated3000 (3052 строки) | 599 мс | 104 мс |
| include | 267 мс | 22 мс |
| module | 276 мс | 22 мс |
| пустой вход (старт) | 204 мс | 21 мс |

Это **исходные** (baseline) числа, не результат текущей сведённой сборки:
сведённого прогона после интеграции патчей ещё не было. Финальная таблица
«baseline → after» будет внесена в `docs/port-audit.md` после реального
combined-прогона `tools/verify_port.sh`.

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
* `docs/port-audit.md` — **карта проверки порта**: что проверено и чем, статусы
  патчей (принято/pending), ограничения и итоговая таблица замеров

## Статус

Статусы ниже — про **наличие и характер проверки**, а не «всё зелёное»: сведённого
(combined) прогона после интеграции всех патчей ещё не было. Подробная карта —
`docs/port-audit.md`.

* [x] Спецификации извлечены из C#: 01 лексер/грамматика, 02 препроцессор/линковка, 03 builtins+опкоды, 04 форматы, 05 диагностики, 06 hidraw-заливка
* [x] Golden-корпус: `tools/difftest.sh` на baseline — expand/lmsb/rbf: **43 pass, 0 fail, 1 skip** со сгенерированными `~`-входами (чистый корпус: 40/0/1); skip = `New_Path_Examples` (у оракула нет эталона, его баг с `..`). Baseline-версия `difftest` не проверяет коды стадий — ужесточение в pending-ветке
* [x] Лексер стадий 1-2 — проверен против C#-оракула на корпусе и точечных репро (`tools/difftest.sh expand`, `lexer_test`). Числа «146 кейсов / 8000 фаззинг» из более ранних ручных прогонов **историчны и не воспроизводимы из репозитория** — здесь они не повторяются
* [x] Развёртка/линковка → `~Name.bp` байт-в-байт, включая include (`.bpi`) и import (`.bpm`): `src/bp/preproc.mojo` + модульная линковка в `expand.mojo`; квирки break_N/continue_N, порядок init-переменных, медиа-пути — по C# (docs/notes-expansion-questions.md закрыт). Но: полные `ModuleErrorParser`/`StructErrorParser` и каталог имён **не портированы** — это не полный паритет диагностик (docs/port-audit.md §8.3)
* [x] Стадия 3 (`.lmsb`, компилятор) — побайтно против C#-оракула на 46 **каталогах эталонов** (из них 3 — вложенные повторные развёртки, не независимые программы); второй контур — свой `.lmsb` → `bp rbf` → совпадение с эталонными `.rbf`
* [x] Стадия 4 (`.rbf`, ассемблер) — побайтно против C#-оракула на тех же 46 каталогах. Ассемблер теперь не пишет/не портит `.rbf` при ошибках (pending-ветка 3fde3bc)
* [x] `bp compile` (сцепка expand→lmsb→rbf) и `bp check` (диагностики expand + стадии 3, код 3000 = маркер lmsb). Известные пробелы `check` (дубль zero-arg `Function`, скобки в `.bpm`, неразрешённый sub) закрываются в pending-ветке e628834
* [x] LSP-сервер (`src/bp/json.mojo` + `src/bp/lsp.mojo`): initialize, didOpen/didChange → publishDiagnostics реальным конвейером (expand + стадия 3), hover по builtin-классам, completion из 30 ключевых слов + 31 класса; smoke-тест поднимает сервер через stdin/stdout. **Переходы к определению не реализованы.** Переработка LSP (приватный temp, include по URI, `id:null`, UTF-16-позиции, честные ошибки I/O) — в работе, статус pending; GUI Zed — только ручная проверка
* [x] tree-sitter грамматика (`grammar/`) + Zed-расширение (`zed-extension/`: подсветка/скобки/отступы/outline, LSP на `tools/bp lsp`, tasks). Baseline-версия проверки корпуса могла давать **ложный зелёный** при нерабочем CLI — fail-closed версия в pending-ветке. Реальный Zed GUI/WASM-хост — **не проверен**
* [x] Заливка на кирпич из CLI (`bp flash`, `src/bp/flash.mojo`): три транспорта — USB (hidraw), Bluetooth (RFCOMM-сокет или `/dev/rfcommN` в raw-режиме), Wi-Fi (TCP :5555 с handshake `Accept:EV340`); ответы кирпича разбираются с эхом команды и payload с offset 4 (как C#); фиксы кадров/rc/fd — в pending-ветке 71982b3. Framing-тесты и сквозные тесты на заглушках (`tools/fake_ev3.py`, `tools/fake_ev3_serial.py`) доказывают **алгоритм кадров, а не реальный обмен**; **живой обмен требует проверки на железе** (docs/06 §7)
* [x] Установка: `install.sh` (сборка + смоук-тест) и `tools/install_zed_extension.sh` (пребилд расширения Zed без rust; pending-ветка переводит его на XDG и `rev` из манифеста): для инсталлера нужен **Python ≥ 3.11** (`tomllib`), в проекте — `>=3.14`

Полная проверка: `bash tools/verify_all.sh`.
**Статус:** единого зелёного combined-прогона после интеграции патчей ещё не было; часть тестов находится в worker-ветках. Карта статусов — `docs/port-audit.md`.

### Команды полной проверки (когда собран сведённый порт)

```bash
bash tools/verify_all.sh                                             # сборка + юнит-тесты + difftest
bash tools/verify_port.sh /home/ssssq/Projects/clev3r_linux/Clev3r-1 # живой C#-оракул + benchmark
git diff --check                                                     # пробелы/маркеры конфликтов
```

`verify_port.sh` требует baseline: либо `BP_BASELINE_BINARY=/path/to/bp` (с
необязательным `BP_BASELINE_SHA256`), либо сохранённый артефакт известного прогона
t10 с проверкой SHA-256. В репозиторий baseline-бинарник не входит (gitignored);
как его получить и указать — `docs/port-audit.md` §11.

## Известно и отложено

* Модули `.bpm` покрыты оракулом лишь косвенно: единственный модульный кейс (`New_Path_Examples`) — skip без эталона.
* Не портированы: каталог текстов ошибок `ErrorsCodeList` (RU/UA/EN) — порт выдаёт коды и краткие сообщения; полные валидаторы модулей/структур; кодировки входа C# кроме UTF-8 (байтовые колонки, UTF-16LE/BE не автодетектятся).
* LSP: переходы к определению (`definitionProvider`) не реализованы; GUI Zed и WASM-хост проверяются только вручную.
* Заливка нового `Program1.rbf` от Mojo-конвейера на живой кирпич и сравнение поведения — отдельный шаг (нет железа); устойчивость к отключению питания/атомарность записи не гарантируется.
* `zed-extension/extension.toml` пинит грамматику по `rev` (`76081a6…`): после коммитов в `grammar/` обновить хеш и пересобрать пребилды (`zed-extension/prebuilt/*.wasm`).