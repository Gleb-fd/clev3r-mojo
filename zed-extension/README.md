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

## Состав

- `extension.toml` — `id = "basic_plus"`, грамматика (локальный `file://` +
  `path = "grammar"` для монорепо), блок `[language_servers.basic-plus]`.
- `languages/basic_plus/config.toml` — `path_suffixes = bp/bpi/bpm`,
  `line_comments = ["' "]`, `tab_size = 2` (как в корпусе), скобки `()/[]`.
- `languages/basic_plus/{highlights,brackets,indents,outline}.scm`.
- `src/lib.rs` + `Cargo.toml` — `language_server_command` на dev-бинарник
  `/home/ssssq/Projects/clev3r_mojo/tools/bp` + args `["lsp"]`.
- `tasks.json` — шаблон задач: скопировать в `<repo>/.zed/tasks.json`
  (сборка `tools/bp`, `verify_all.sh`, `check_corpus.sh`).

## LSP: статус и ограничения

- `tools/bp lsp` сейчас **заглушка** (`bp lsp: ещё не реализовано`), поэтому
  сервер упадёт при старте до реализации LSP. Подсветка/отступы/outline
  от этого не зависят.
- Rust-шим требует сборки расширения в wasm (`wasm32-wasip2`), см. ниже.

## wasm-сборка без rustup: ограничение

- Системный `rustc/cargo 1.98` (Arch) содержит **только** хост-таргет
  `x86_64-unknown-linux-gnu`; `wasm32-wasip2` отсутствует, `rustup` нет.
  `cargo build --target wasm32-wasip2` падает с `E0463: can't find crate for std`.
- Sysroot `/usr/lib/rustlib` **не доступен на запись** без sudo, так что
  вручную распаковать `rust-std` туда нельзя без повышения привилегий.
- Варианты починить (на выбор):
  1. `rustup toolchain add stable --target wasm32-wasip2` (нужна установка
     rustup; Zed дальше подтянет таргет сам);
  2. `sudo tar -x ... rust-std-1.98.1-wasm32-wasip2.tar.gz -C /` с
     https://static.rust-lang.org/dist/ (проверено: тарболл для 1.98.1 существует);
  3. Без Rust вообще: удалить/отложить `Cargo.toml`+`src/` (тогда грамматика,
     подсветка, отступы, outline ставятся без wasm), а LSP на время dev
     прописать в пользовательских настройках Zed:
     ```json
     {
       "lsp": {
         "basic-plus": {
           "binary": {
             "path": "/home/ssssq/Projects/clev3r_mojo/tools/bp",
             "args": ["lsp"]
           }
         }
       }
     }
     ```
- Известный риск (zed#51352, март 2026): `checkout_repo` требует у грамматики
  git-remote `origin`; у этого репо remote **не настроен**. Если Install Dev
  Extension упадёт на checkout грамматики — добавить origin
  (`git remote add origin <url>`) либо дождаться/проверить PR #51471
  ("support for local grammars during development") в вашей версии Zed.

## Валидация без Zed GUI

```bash
python3 -c "import tomllib; tomllib.load(open('zed-extension/extension.toml','rb')); tomllib.load(open('zed-extension/languages/basic_plus/config.toml','rb')); print('TOML OK')"
python3 -c "import json; json.load(open('zed-extension/tasks.json')); print('tasks.json OK')"
TREE_SITTER_CLI="tree-sitter" bash tools/grammar/check_corpus.sh  # из grammar/
```
