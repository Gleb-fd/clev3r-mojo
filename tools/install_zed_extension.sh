#!/usr/bin/env bash
# Установка dev-расширения Basic Plus в Zed без сборки из исходников.
#
# Кладёт пребилд-артефакты из zed-extension/prebuilt/ в каталог расширений Zed
# и регистрирует расширение в index.json (как делает "Install Dev Extension").
# После установки перезапусти Zed.
#
# Пересборка пребилдов (нужен rust с таргетом wasm32-wasip2 и tree-sitter CLI):
#   cd zed-extension && cargo build --release --target wasm32-wasip2 \
#       && cp target/wasm32-wasip2/release/basic_plus.wasm prebuilt/extension.wasm
#   cd grammar && tree-sitter build --wasm -o ../zed-extension/prebuilt/grammars/basic_plus.wasm .
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/zed-extension"

if ! command -v python3 >/dev/null 2>&1; then
    echo "нужен python3 для регистрации расширения в index.json"
    exit 1
fi

for f in "$SRC/extension.toml" "$SRC/prebuilt/extension.wasm" \
         "$SRC/prebuilt/grammars/basic_plus.wasm" "$SRC/languages/basic_plus/config.toml"; do
    [[ -f "$f" ]] || { echo "нет файла: $f"; exit 1; }
done

if pgrep -x zeditor >/dev/null 2>&1 || pgrep -x zed >/dev/null 2>&1; then
    echo "Zed сейчас запущен: после установки его нужно перезапустить."
fi

DST="${ZED_DATA_DIR:-$HOME/.local/share/zed}/extensions/installed/basic_plus"
mkdir -p "$DST/grammars" "$DST/languages"
cp "$SRC/extension.toml" "$DST/"
cp "$SRC/prebuilt/extension.wasm" "$DST/extension.wasm"
cp "$SRC/prebuilt/grammars/basic_plus.wasm" "$DST/grammars/"
cp -r "$SRC/languages/basic_plus" "$DST/languages/"
# Свежие метки времени, чтобы Zed не пересобирал грамматику (иначе он полезет
# качать wasi-sdk с GitHub).
touch "$DST/extension.wasm" "$DST/grammars/basic_plus.wasm"

python3 - "$DST" <<'EOF'
import json, os, sys

dst = sys.argv[1]
p = os.path.join(os.path.dirname(dst), "..", "index.json")
p = os.path.normpath(p)

entry = {
    "manifest": {
        "id": "basic_plus",
        "name": "Basic Plus",
        "version": "0.1.0",
        "schema_version": 1,
        "repository": "https://github.com/Gleb-fd/clev3r-mojo",
        "authors": ["clev3r-mojo contributors"],
        "description": (
            "Basic Plus language support (.bp/.bpi/.bpm): highlighting, "
            "brackets, auto-indent, outline, LSP."
        ),
        "lib": {"kind": "Rust", "version": "0.7.0"},
        "themes": [],
        "icon_themes": [],
        "languages": ["languages/basic_plus"],
        "grammars": {
            "basic_plus": {
                "repository": "https://github.com/Gleb-fd/clev3r-mojo",
                "rev": "master",
                "path": "grammar",
            }
        },
        "language_servers": {
            "basic-plus": {
                "language": "Basic Plus",
                "languages": [],
                "language_ids": {},
                "code_action_kinds": None,
            }
        },
        "context_servers": {},
        "slash_commands": {},
        "snippets": [],
    },
    "dev": True,
}

data = {"extensions": {}}
if os.path.exists(p):
    with open(p) as f:
        data = json.load(f)
    backup = p + ".bak"
    with open(backup, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    print("бэкап старого index.json:", backup)

data.setdefault("extensions", {})["basic_plus"] = entry
with open(p, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
print("зарегистрировано в", p)
EOF

echo
echo "Расширение Basic Plus установлено в: $DST"
echo "Перезапусти Zed: файлы .bp/.bpi/.bpm откроются как Basic Plus"
echo "(подсветка, outline, LSP-диагностики через tools/bp lsp)."
