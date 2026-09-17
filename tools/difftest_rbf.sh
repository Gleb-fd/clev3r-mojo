#!/usr/bin/env bash
# Дифференциальный тест СТАДИИ 4 (ассемблер): <Имя>.lmsb -> <Имя>.rbf, побайтово.
#
# Цикл по всем эталонам tests/golden/**/~<Имя>/<Имя>.lmsb:
#   1) копия .lmsb кладётся во временную рабочую папку (эталоны не трогаем);
#   2) запускается `bp rbf <копия>.lmsb` -> <копия>.rbf рядом;
#   3) cmp с эталоном tests/golden/.../<Имя>.rbf.
# Печатает pass/fail-список; для неудач — размеры и первое байтовое расхождение.
#
# Использование: bash tools/difftest_rbf.sh [-v]
# Переменные: BP_BIN — путь к CLI (по умолчанию $ROOT/tools/bp).
set -uo pipefail

ROOT="/home/ssssq/Projects/clev3r_mojo"
BP="${BP_BIN:-$ROOT/tools/bp}"
GOLD="$ROOT/tests/golden"
WORK="$ROOT/tests/.rbf_work"
VERBOSE="${2:-}"

if [[ ! -x "$BP" ]]; then
    echo "нет CLI: $BP — собери: cd $ROOT && uv run mojo build src/bp/main.mojo -o tools/bp"
    exit 2
fi

rm -rf "$WORK"; mkdir -p "$WORK"

pass=0; fail=0; skip=0
declare -a FAIL_LIST

while IFS= read -r -d '' lmsb; do
    rel="${lmsb#./}"                       # путь относительно golden
    dir="$(dirname "$rel")"
    name="$(basename "$rel" .lmsb)"
    ref="$GOLD/$dir/$name.rbf"
    if [[ ! -f "$ref" ]]; then
        skip=$((skip+1)); echo "SKIP (нет эталона .rbf) $rel"
        continue
    fi

    wdir="$WORK/$dir"; mkdir -p "$wdir"
    cp "$GOLD/$rel" "$wdir/$name.lmsb"

    err="$("$BP" rbf "$wdir/$name.lmsb" 2>&1)"
    if [[ $? -ne 0 ]]; then
        fail=$((fail+1)); FAIL_LIST+=("$rel")
        echo "FAIL (ошибка ассемблера) $rel"
        echo "$err" | head -5 | sed 's/^/    /'
        continue
    fi

    got="$wdir/$name.rbf"
    if cmp -s "$got" "$ref"; then
        pass=$((pass+1))
        echo "pass $rel ($(stat -c%s "$ref") b)"
    else
        fail=$((fail+1)); FAIL_LIST+=("$rel")
        echo "FAIL $rel"
        echo "    размеры: эталон $(stat -c%s "$ref") б, получено $(stat -c%s "$got" 2>/dev/null || echo 0) б"
        cmp "$got" "$ref" 2>&1 | head -1 | sed 's/^/    /'
        if [[ "$VERBOSE" == "-v" ]]; then
            cmp -l "$got" "$ref" 2>/dev/null | head -5 | sed 's/^/    /'
        fi
    fi
done < <(cd "$GOLD" && find . -name '*.lmsb' -print0 | sort -z)

echo
echo "== rbf: pass=$pass fail=$fail skip=$skip"
if [[ "$fail" -gt 0 ]]; then
    echo "неудачи:"
    for f in "${FAIL_LIST[@]}"; do echo "  $f"; done
fi
[[ "$fail" -eq 0 ]]
