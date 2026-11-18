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

# Проверяем index.json и манифест ДО копирования файлов и любых изменений:
# повреждённый index не перезаписывается, а неполный манифест не оставляет
# осиротевший установленный каталог. Если index.json — пользовательский
# symlink, резолвим его цель один раз здесь и дальше пишем только в неё
# (сама ссылка не заменяется и не удаляется).
PLAN="$(mktemp)"
trap 'rm -f "$PLAN"' EXIT
python3 - "$INDEX" "$SRC/extension.toml" "$SRC/Cargo.lock" "$PLAN" <<'EOF'
import json, os, re, stat, sys, tomllib

index_arg, manifest_path, lock_path, plan_path = sys.argv[1:5]


def fail(msg):
    print(msg, file=sys.stderr)
    print("index.json не изменён; установка прервана", file=sys.stderr)
    sys.exit(1)


# Резолвим цель index.json один раз. Для обычного файла это он сам, для
# symlink — его конечный существующий regular file (цепочка допустима).
index = os.path.abspath(index_arg)
try:
    index_lstat = os.lstat(index)
except FileNotFoundError:
    target = index
    existed = False
    mode = None
except OSError as e:
    fail(f"не удалось проверить {index}: {e}")
else:
    if stat.S_ISLNK(index_lstat.st_mode):
        try:
            target = os.path.realpath(index, strict=True)
        except OSError as e:
            fail(f"не удалось разрешить symlink {index}: {e}; ссылка не изменена")
        if not os.path.exists(target):
            fail(
                f"index.json — висячий symlink {index} -> {target}; "
                "ссылка не изменена"
            )
        try:
            target_stat = os.stat(target)
        except OSError as e:
            fail(f"не удалось прочитать цель symlink {target}: {e}")
        if not stat.S_ISREG(target_stat.st_mode):
            fail(f"цель symlink {target} не обычный файл; установка прервана")
        existed = True
        mode = stat.S_IMODE(target_stat.st_mode)
    elif stat.S_ISREG(index_lstat.st_mode):
        target = index
        existed = True
        mode = stat.S_IMODE(index_lstat.st_mode)
    else:
        fail(f"{index} не обычный файл; установка прервана")

data = {"extensions": {}}
if existed:
    try:
        with open(target, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError) as e:
        fail(f"не удалось прочитать {target}: {e}")
    if not isinstance(data, dict):
        fail(f"неожиданный формат {target}: ожидался JSON-объект")
else:
    # Новый index.json создаём как старый установщик: 0666 & ~umask.
    umask = os.umask(0)
    os.umask(umask)
    mode = 0o666 & ~umask

with open(manifest_path, "rb") as f:
    manifest = tomllib.load(f)

try:
    grammar = manifest["grammars"]["basic_plus"]
    rev = grammar["rev"]
except (KeyError, TypeError):
    fail(f"в {manifest_path} нет [grammars.basic_plus].rev")

if not isinstance(rev, str) or not rev.strip():
    fail(f"пустой rev грамматики в {manifest_path}")

# Формы языковых секций проверяем здесь же: иначе ошибка всплыла бы уже
# после копирования установленного каталога.
manifest_languages = manifest.get("languages") or ["languages/basic_plus"]
if not isinstance(manifest_languages, list) or not all(
    isinstance(lang, str) for lang in manifest_languages
):
    fail(f"в {manifest_path} поле languages должно быть списком строк")

servers = manifest.get("language_servers") or {}
if not isinstance(servers, dict):
    fail(f"в {manifest_path} [language_servers] должен быть таблицей")
for server_id, server in servers.items():
    if not isinstance(server, dict):
        fail(f"в {manifest_path} [language_servers.{server_id}] должен быть таблицей")
    langs = server.get("languages") or []
    if not isinstance(langs, list) or not all(isinstance(lang, str) for lang in langs):
        fail(
            f"в {manifest_path} language_servers.{server_id}.languages "
            "должен быть списком строк"
        )

# lib.version в index.json — полная SemVer из уже зафиксированного Cargo.lock
# (0.7.0), а не диапазон из Cargo.toml ("0.7"): Zed проверяет именно ABI,
# с которым собран пребилд.
try:
    with open(lock_path, "rb") as f:
        lock = tomllib.load(f)
except (OSError, tomllib.TOMLDecodeError) as e:
    fail(f"не удалось прочитать {lock_path}: {e}")

packages = lock.get("package")
if not isinstance(packages, list):
    fail(f"в {lock_path} нет списка [[package]]")
resolved = [
    p for p in packages
    if isinstance(p, dict) and p.get("name") == "zed_extension_api"
]
if len(resolved) != 1:
    fail(f"в {lock_path} ожидалась ровно одна package zed_extension_api")
lib_version = resolved[0].get("version")
if not isinstance(lib_version, str) or not re.fullmatch(r"\d+\.\d+\.\d+", lib_version):
    fail(
        f"в {lock_path} у zed_extension_api неполная версия {lib_version!r}; "
        "нужна полная SemVer"
    )

try:
    with open(plan_path, "w", encoding="utf-8") as f:
        json.dump(
            {
                "target": target,
                "existed": existed,
                "mode": mode,
                "manifest": manifest,
                "rev": rev,
                "lib_version": lib_version,
            },
            f,
            ensure_ascii=False,
        )
except OSError as e:
    fail(f"не удалось записать план установки {plan_path}: {e}")
EOF

mkdir -p "$DST/grammars" "$DST/languages"
cp "$SRC/extension.toml" "$DST/"
cp "$SRC/prebuilt/extension.wasm" "$DST/extension.wasm"
cp "$SRC/prebuilt/grammars/basic_plus.wasm" "$DST/grammars/"
cp -r "$SRC/languages/basic_plus" "$DST/languages/"
# Свежие метки времени, чтобы Zed не пересобирал грамматику (иначе он полезет
# качать wasi-sdk с GitHub).
touch "$DST/extension.wasm" "$DST/grammars/basic_plus.wasm"

python3 - "$DST" "$PLAN" <<'EOF'
import json, os, stat, sys, tempfile

dst, plan_path = sys.argv[1:3]
with open(plan_path, encoding="utf-8") as f:
    plan = json.load(f)

target = plan["target"]
existed = plan["existed"]
mode = plan["mode"]
manifest = plan["manifest"]
rev = plan["rev"]
lib_version = plan["lib_version"]


def fail(msg):
    print(msg, file=sys.stderr)
    print("index.json не изменён; установка прервана", file=sys.stderr)
    sys.exit(1)


# Цель уже резолвлена до копирования; проверяем, что за это время её не
# подменили на symlink (иначе os.replace заменил бы ссылку, а не файл).
if os.path.islink(target):
    fail(f"цель index.json {target} стала symlink; установка прервана")

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

grammar = manifest["grammars"]["basic_plus"]

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
if existed:
    try:
        with open(target, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError) as e:
        fail(f"не удалось прочитать {target}: {e}")
    if not isinstance(data, dict):
        fail(f"неожиданный формат {target}: ожидался JSON-объект")
    try:
        target_stat = os.stat(target)
    except OSError as e:
        fail(f"не удалось прочитать {target}: {e}")
    if not stat.S_ISREG(target_stat.st_mode):
        fail(f"{target} не обычный файл; установка прервана")
    # mkstemp создаёт 0600, поэтому перед replace возвращаем ровно те биты,
    # что были у существующего index.json (0644/0640/0600 и т.п.).
    mode = stat.S_IMODE(target_stat.st_mode)
    backup = target + ".bak"
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

parent = os.path.dirname(target)
try:
    os.makedirs(parent, exist_ok=True)
except OSError as e:
    fail(f"не удалось создать каталог {parent}: {e}")
try:
    tmp_fd, tmp_path = tempfile.mkstemp(prefix=".index.", suffix=".json", dir=parent)
except OSError as e:
    fail(f"не удалось создать временный файл в {parent}: {e}")
try:
    with os.fdopen(tmp_fd, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    os.chmod(tmp_path, mode)
    os.replace(tmp_path, target)
except BaseException:
    try:
        os.unlink(tmp_path)
    except OSError:
        pass
    raise
print("зарегистрировано в", target)
EOF

echo
echo "Расширение Basic Plus установлено в: $DST"
echo "Перезапусти Zed: файлы .bp/.bpi/.bpm откроются как Basic Plus"
echo "(подсветка, outline, LSP-диагностики через tools/bp lsp)."
