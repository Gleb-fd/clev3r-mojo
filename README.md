# Clev3r Mojo

Порт компилятора **Clev3r / Basic Plus** (язык для LEGO MINDSTORMS EV3) с C# на **Mojo**, плюс
анализатор/LSP и нативная интеграция с редактором **Zed**.

## Зачем

Оригинальный Clev3r — Windows/.NET-приложение. Здесь тот же язык и тот же байткод, но:

* компилятор и анализатор написаны на Mojo (один статический бинарник, без .NET);
* LSP-сервер даёт диагностику, автодополнение, hover и переходы прямо в Zed;
* заливка на кирпич идёт из CLI через `/dev/hidraw` (без docker и libusb);
* tree-sitter грамматика даёт нативную подсветку и outline.

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
| `bp flash <file.bp\|file.rbf> [device]` | компиляция (для `.bp`) + заливка на EV3 через `/dev/hidraw` |
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
* `docs/06-hidraw-usb-notes.md` — транспорт USB через hidraw (`bp flash`)

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
* [x] Заливка на кирпич из CLI (`bp flash`, `src/bp/flash.mojo`): hidraw-транспорт, кадры BEGIN/CONTINUE_DOWNLOAD + PROGRAM_START 1:1 со старым путём; framing-тесты (`FLASH_TEST OK`) + dry-run; **живой обмен требует проверки на железе** (docs/06 §7)

Полная проверка: `bash tools/verify_all.sh`.

## Известно и отложено

* Модули `.bpm` покрыты оракулом лишь косвенно: единственный модульный кейс (`New_Path_Examples`) — skip без эталона.
* Заливка нового `Program1.rbf` от Mojo-конвейера на живой кирпич и сравнение поведения — отдельный шаг (нет железа).
* `zed-extension/extension.toml` пинит грамматику по `rev`: после коммитов обновить хеш.