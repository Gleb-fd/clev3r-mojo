#!/usr/bin/env bash
# Установка dev-расширения Basic Plus в Zed без сборки из исходников.
#
# Кладёт пребилд-артефакты из zed-extension/prebuilt/ в каталог расширений Zed
# и регистрирует расширение в index.json (как делает "Install Dev Extension").
# После установки перезапусти Zed.
#
# Каталог данных Zed:
#   ZED_DATA_DIR (если задан) иначе ${XDG_DATA_HOME:-$HOME/.local/share}/zed
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

if [ -n "${ZED_DATA_DIR:-}" ]; then
    ZED_DATA="$ZED_DATA_DIR"
else
    ZED_DATA="${XDG_DATA_HOME:-$HOME/.local/share}/zed"
fi
DST="$ZED_DATA/extensions/installed/basic_plus"
INDEX="$ZED_DATA/extensions/index.json"

# Проверяем существующий index.json ДО любых изменений: повреждённый файл не
# должен быть перезаписан (иначе потеряются чужие расширения).
python3 - "$INDEX" <<'EOF'
import json, os, sys

p = sys.argv[1]
if not os.path.exists(p):
    sys.exit(0)
try:
    with open(p, encoding="utf-8") as f:
        data = json.load(f)
except (OSError, ValueError) as e:
    print(f"не удалось прочитать {p}: {e}", file=sys.stderr)
    print("index.json не изменён; установка прервана", file=sys.stderr)
    sys.exit(1)
if not isinstance(data, dict):
    print(f"неожиданный формат {p}: ожидался JSON-объект", file=sys.stderr)
    print("index.json не изменён; установка прервана", file=sys.stderr)
    sys.exit(1)
EOF

mkdir -p "$DST/grammars" "$DST/languages"
cp "$SRC/extension.toml" "$DST/"
cp "$SRC/prebuilt/extension.wasm" "$DST/extension.wasm"
cp "$SRC/prebuilt/grammars/basic_plus.wasm" "$DST/grammars/"
cp -r "$SRC/languages/basic_plus" "$DST/languages/"
# Свежие метки времени, чтобы Zed не пересобирал грамматику (иначе он полезет
# качать wasi-sdk с GitHub).
touch "$DST/extension.wasm" "$DST/grammars/basic_plus.wasm"

python3 - "$DST" "$SRC/extension.toml" "$SRC/Cargo.toml" <<'EOF'
import json, os, sys, tempfile, tomllib

dst, manifest_path, cargo_path = sys.argv[1:4]
p = os.path.normpath(os.path.join(dst, "..", "..", "index.json"))

with open(manifest_path, "rb") as f:
    manifest = tomllib.load(f)
with open(cargo_path, "rb") as f:
    cargo = tomllib.load(f)


def fail(msg):
    print(msg, file=sys.stderr)
    print("index.json не изменён; установка прервана", file=sys.stderr)
    sys.exit(1)


try:
    grammar = manifest["grammars"]["basic_plus"]
    rev = grammar["rev"]
except (KeyError, TypeError):
    fail(f"в {manifest_path} нет [grammars.basic_plus].rev")

if not isinstance(rev, str) or not rev.strip():
    fail(f"пустой rev грамматики в {manifest_path}")

# lib-зависимость берём из Cargo.toml, если она там есть.
lib_version = "0.7.0"
dep = cargo.get("dependencies", {}).get("zed_extension_api")
if isinstance(dep, str):
    lib_version = dep.lstrip("^~=")
elif isinstance(dep, dict) and isinstance(dep.get("version"), str):
    lib_version = dep["version"].lstrip("^~=")

manifest_languages = manifest.get("languages") or ["languages/basic_plus"]
language_dirs = []
for lang in manifest_languages:
    lang_dir = os.path.normpath(os.path.join(dst, lang))
    if os.path.isdir(lang_dir):
        language_dirs.append(lang)
if not language_dirs:
    language_dirs = ["languages/basic_plus"]

language_servers = {}
for server_id, server in (manifest.get("language_servers") or {}).items():
    langs = server.get("languages") or []
    language_servers[server_id] = {
        "language": langs[0] if langs else manifest.get("name", server_id),
        "languages": list(langs),
        "language_ids": {},
        "code_action_kinds": None,
    }

entry = {
    "manifest": {
        "id": manifest.get("id", "basic_plus"),
        "name": manifest.get("name", "Basic Plus"),
        "version": manifest.get("version", "0.1.0"),
        "schema_version": manifest.get("schema_version", 1),
        "repository": manifest.get("repository", ""),
        "authors": list(manifest.get("authors") or []),
        "description": manifest.get("description", ""),
        "lib": {"kind": "Rust", "version": lib_version},
        "themes": [],
        "icon_themes": [],
        "languages": language_dirs,
        "grammars": {
            "basic_plus": {
                "repository": grammar.get("repository", manifest.get("repository", "")),
                "rev": rev,
                "path": grammar.get("path", "grammar"),
            }
        },
        "language_servers": language_servers,
        "context_servers": {},
        "slash_commands": {},
        "snippets": [],
    },
    "dev": True,
}

data = {"extensions": {}}
if os.path.exists(p):
    try:
        with open(p, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError) as e:
        fail(f"не удалось прочитать {p}: {e}")
    if not isinstance(data, dict):
        fail(f"неожиданный формат {p}: ожидался JSON-объект")
    backup = p + ".bak"
    try:
        with open(backup, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
    except OSError as e:
        fail(f"не удалось записать бэкап {backup}: {e}")
    print("бэкап старого index.json:", backup)

extensions = data.get("extensions")
if not isinstance(extensions, dict):
    extensions = {}
    data["extensions"] = extensions
# Сохраняем все остальные ключи и чужие расширения как есть.
extensions[entry["manifest"]["id"]] = entry

parent = os.path.dirname(p)
os.makedirs(parent, exist_ok=True)
tmp_fd, tmp_path = tempfile.mkstemp(prefix=".index.", suffix=".json", dir=parent)
try:
    with os.fdopen(tmp_fd, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    os.replace(tmp_path, p)
except BaseException:
    try:
        os.unlink(tmp_path)
    except OSError:
        pass
    raise
print("зарегистрировано в", p)
EOF

echo
echo "Расширение Basic Plus установлено в: $DST"
echo "Перезапусти Zed: файлы .bp/.bpi/.bpm откроются как Basic Plus"
echo "(подсветка, outline, LSP-диагностики через tools/bp lsp)."
