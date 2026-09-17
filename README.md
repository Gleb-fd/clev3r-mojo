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
| `bp expand <file> <outdir>` | препроцессор + линковка → `~<Имя>.bp` |
| `bp compile <file> <outdir>` | полный цикл → `.lmsb` + `.rbf` |
| `bp check <file>` | диагностики (текст/JSON) |
| `bp flash <file>` | компиляция + заливка на EV3 |
| `bp lsp` | LSP-сервер (stdio) |

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
* `docs/06-hidraw-usb-notes.md` — транспорт USB через hidraw

## Статус

* [x] Спецификации извлечены из C# (01, 02, 04)
* [x] Golden-корпус: 43/44 примера, 46 `.rbf` + 46 `.lmsb` эталонов
* [ ] Лексер стадий 1-2 (Mojo)
* [ ] Развёртка/линковка → `~Name.bp` байт-в-байт
* [ ] Стадия 3 (`.lmsb`) и стадия 4 (`.rbf`)
* [ ] LSP-сервер
* [ ] tree-sitter + расширение Zed
* [ ] Заливка на кирпич из CLI