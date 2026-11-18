# Basic Plus — Zed extension (dev)

Tree-sitter грамматика: `../grammar/` (имя `basic_plus`, файлы `.bp/.bpi/.bpm`).
Запросы в `languages/basic_plus/*.scm` — копии `../grammar/queries/*.scm`.

## Установка (dev-режим)

1. Закоммитьте изменения в `grammar/` (Zed клонирует грамматику по `rev` из
   `extension.toml`; незакоммиченное он не увидит) и при необходимости
   обновите `rev` в `extension.toml` на новый HEAD.
2. Zed → Extensions → **Install Dev Extension** → выбрать каталог
   `zed-extension/` (подсветка/отступы/outline появятся сразу; грамматика
   соберётся через автоматически скачиваемый wasi-sdk, Rust для этого не нужен).
3. Проверка: открыть любой `tests/corpus/**/*.bp`, затем
   `zed: reload extensions` после правок `grammar.js` (`tree-sitter generate`)
   или `.scm`-файлов.

Альтернатива без Zed GUI — установка готовых пребилдов скриптом:

```bash
bash tools/install_zed_extension.sh
```

Скрипт уважает `ZED_DATA_DIR`, иначе `${XDG_DATA_HOME:-$HOME/.local/share}/zed`,
регистрирует расширение в `index.json` с `rev` из `extension.toml` и полной
версией `lib` из `Cargo.lock`. Требуется Python ≥ 3.11 (`tomllib`). Устанавливать
лучше при **закрытом** Zed: параллельная запись `index.json` самим Zed может
потерять обновление (сериализованная замена файла, без блокировок между
процессами) — гарантий конкурентной установки нет.

## Состав

- `extension.toml` — `id = "basic_plus"`, грамматика (`repository` + `rev` +
  `path = "grammar"`), блок `[language_servers.basic-plus]`. `rev` пинится на
  `76081a635ac2fa0dbb6d0727c043a996a599603d` — менять только вместе с коммитом
  грамматики.
- `languages/basic_plus/config.toml` — `path_suffixes = bp/bpi/bpm`,
  `line_comments = ["' "]`, `tab_size = 2` (как в корпусе), скобки `()/[]`.
- `languages/basic_plus/{highlights,brackets,indents,outline}.scm` — четыре запроса.
- `zed-extension/src/lib.rs` + `Cargo.toml`/`Cargo.lock` — `language_server_command`: ищет
  `tools/bp` в корне проекта, затем `bp` в `PATH`, затем типичные пути
  репозитория; запускает его с `args = ["lsp"]` (поле `zed::Command` называется
  `args`, не `arguments`).
- `tasks.json` — шаблон задач (сборка `tools/bp`, `verify_all.sh`,
  `check_corpus.sh`). Это **задачи, а не привязки клавиш**: горячие клавиши
  пользователь назначает сам в своём `~/.config/zed/keymap.json`.

## LSP: статус и ограничения

- Сервер реализован в `src/bp/lsp.mojo` и вызывается из `src/bp/main.mojo`
  как `bp lsp` (stdio, JSON-RPC 2.0 с `Content-Length`).
- Есть: `initialize`/`initialized`/`shutdown`/`exit`, `didOpen`/`didChange`/
  `didClose` → `publishDiagnostics` реальным конвейером (expand + стадия 3),
  `hover` по builtin-классам, `completion` (ключевые слова + классы).
- **Нет** `definitionProvider` / переходов к определению, диагностик уровня
  типов/модулей в полном объёме и каталога текстов ошибок C#.
- Переработка LSP (приватный temp-каталог на процесс, include относительно URI,
  корректный `id: null`, UTF-16-позиции hover, явные ошибки I/O, лимиты размера
  тела/глубины JSON) находится в worker-ветке и **ещё не влита**; статус
  «проверено» появится только после сведённого прогона.
- **GUI Zed и WASM-хост не проверены** в этой среде: подсветка/отступы/outline и
  запуск сервера требуют ручной проверки в живом редакторе.

## wasm-сборка без rustup: ограничение

- Системный `rustc/cargo 1.98` (Arch) содержит **только** хост-таргет
  `x86_64-unknown-linux-gnu`; `wasm32-wasip2` отсутствует, `rustup` нет.
  `cargo build --target wasm32-wasip2` падает с `E0463: can't find crate for std`.
- Sysroot `/usr/lib/rustlib` **не доступен на запись** без sudo, так что
  вручную распаковать `rust-std` туда нельзя без повышения привилегий.
- Варианты:
  1. `rustup toolchain add stable --target wasm32-wasip2` (нужна установка
     rustup; Zed дальше подтянет таргет сам);
  2. `sudo tar -x ... rust-std-1.98.1-wasm32-wasip2.tar.gz -C /` с
     https://static.rust-lang.org/dist/ (тарболл для 1.98.1 существует);
  3. Без Rust вообще: поставить только грамматику/запросы (пребилды из
     `prebuilt/`), а LSP во время разработки прописать в настройках Zed
     вручную. В конфиге сервера поле называется `arguments` (это схема
     пользовательских настроек Zed, не `Command` из `lib.rs`):
     ```json
     {
       "lsp": {
         "basic-plus": {
           "binary": {
             "path": "/home/ssssq/Projects/clev3r_mojo/tools/bp",
             "arguments": ["lsp"]
           }
         }
       }
     }
     ```
- Известный риск (zed#51352, март 2026): `checkout_repo` требует у грамматики
  git-remote `origin`; если Install Dev Extension упадёт на checkout грамматики —
  добавить origin (`git remote add origin <url>`) либо проверить PR #51471
  ("support for local grammars during development") в вашей версии Zed.

## Валидация без Zed GUI

```bash
python3 -c "import tomllib; tomllib.load(open('zed-extension/extension.toml','rb')); tomllib.load(open('zed-extension/languages/basic_plus/config.toml','rb')); print('TOML OK')"
python3 -c "import json; json.load(open('zed-extension/tasks.json')); print('tasks.json OK')"
bash tools/grammar/check_corpus.sh   # разбор tests/corpus; нужен tree-sitter CLI
```

Это проверяет **только** синтаксис манифестов и разбор корпуса грамматикой. Ни
одна из этих команд не доказывает работу расширения в Zed. Текущая версия
`check_corpus.sh` может требовать запуска из `grammar/` и не всегда честно
сообщает о нерабочем CLI (fail-closed версия — в worker-ветке).
