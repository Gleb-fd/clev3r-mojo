#!/usr/bin/env bash
# Дифференциальный тест СТАДИИ 4 (ассемблер): <Имя>.lmsb -> <Имя>.rbf, побайтово.
#
# Цикл по всем эталонам tests/golden/**/<Имя>.lmsb:
#   1) в СВЕЖЕМ уникальном scratch создаётся копия .lmsb (эталоны не трогаем);
#   2) запускается `<bp> rbf <копия>.lmsb` -> <копия>.rbf рядом;
#   3) код возврата и наличие .rbf проверяются, затем cmp с эталоном <Имя>.rbf.
#
# Использование: bash tools/difftest_rbf.sh [-v]
# Переменные: DIFFTEST_BP (приоритет), BP_BINARY/BP_BIN — путь к CLI;
#             DIFFTEST_GOLD — каталог эталонов.
# Коды выхода: 0 — все pass; 1 — есть fail; 2 — окружение/пустой набор.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

BP="${DIFFTEST_BP:-${BP_BINARY:-${BP_BIN:-$ROOT/tools/bp}}}"
GOLD="${DIFFTEST_GOLD:-$ROOT/tests/golden}"
VERBOSE="${1:-}"

die() { echo "FAIL(difftest_rbf): $*" >&2; exit 2; }

[[ -x "$BP" ]] || die "нет CLI: $BP — собери: uv run mojo build src/bp/main.mojo -o tools/bp"
[[ -d "$GOLD" ]] || die "нет каталога эталонов: $GOLD"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/bp_rbf_diff.XXXXXX")" || die "mktemp"
trap 'rm -rf "$WORK"' EXIT

mapfile -d '' LMSBS < <(cd "$GOLD" && find . -name '*.lmsb' -print0 | sort -z)
(( ${#LMSBS[@]} > 0 )) || die "в golden нет .lmsb: $GOLD"

pass=0; fail=0; skip=0
declare -a FAIL_LIST

for lmsb in "${LMSBS[@]}"; do
    rel="${lmsb#./}"
    dir="$(dirname "$rel")"
    name="$(basename "$rel" .lmsb)"
    ref="$GOLD/$dir/$name.rbf"
    if [[ ! -f "$ref" ]]; then
        skip=$((skip + 1)); echo "SKIP (нет эталона .rbf) $rel"
        continue
    fi

    wdir="$WORK/$dir"; mkdir -p "$wdir"
    cp "$GOLD/$rel" "$wdir/$name.lmsb"

    err="$("$BP" rbf "$wdir/$name.lmsb" 2>&1)"
    rc=$?
    if [[ $rc -ne 0 ]]; then
        fail=$((fail + 1)); FAIL_LIST+=("$rel")
        echo "FAIL (ошибка ассемблера, rc=$rc) $rel"
        echo "$err" | head -5 | sed 's/^/    /'
        continue
    fi

    got="$wdir/$name.rbf"
    if [[ ! -f "$got" ]]; then
        fail=$((fail + 1)); FAIL_LIST+=("$rel")
        echo "FAIL (rc=0, но нет .rbf) $rel"
    elif cmp -s "$got" "$ref"; then
        pass=$((pass + 1))
        echo "pass $rel ($(stat -c%s "$ref") b)"
    else
        fail=$((fail + 1)); FAIL_LIST+=("$rel")
        echo "FAIL $rel"
        echo "    размеры: эталон $(stat -c%s "$ref") б, получено $(stat -c%s "$got") б"
        cmp "$got" "$ref" 2>&1 | head -1 | sed 's/^/    /'
        if [[ "$VERBOSE" == "-v" ]]; then
            cmp -l "$got" "$ref" 2>/dev/null | head -5 | sed 's/^/    /'
        fi
    fi
done

echo
echo "== rbf: pass=$pass fail=$fail skip=$skip"
if [[ "$fail" -gt 0 ]]; then
    echo "неудачи:"
    for f in "${FAIL_LIST[@]}"; do echo "  $f"; done
fi
(( pass > 0 )) || { echo "FAIL(difftest_rbf): нет ни одного сверенного .rbf" >&2; exit 1; }
[[ "$fail" -eq 0 ]]
