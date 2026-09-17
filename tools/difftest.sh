#!/usr/bin/env bash
# Дифференциальный тест: выход Mojo-компилятора против C#-эталонов (tests/golden).
#
#   tools/difftest.sh expand    — ~<Имя>.bp  (стадии 1-2 + линковка)
#   tools/difftest.sh lmsb      — <Имя>.lmsb (стадия 3)
#   tools/difftest.sh rbf       — <Имя>.rbf  (стадия 4, побайтово)
#
# Требует собранный CLI: uv run mojo build src/bp/main.mojo -o tools/bp
set -uo pipefail

ROOT="/home/ssssq/Projects/clev3r_mojo"
STAGE="${1:-expand}"
BP="$ROOT/tools/bp"
CORPUS="$ROOT/tests/corpus"
GOLD="$ROOT/tests/golden"
WORK="$ROOT/tests/.diff_work"

if [[ ! -x "$BP" ]]; then
    echo "нет CLI: $BP — собери: cd $ROOT && uv run mojo build src/bp/main.mojo -o tools/bp"
    exit 2
fi

rm -rf "$WORK"; mkdir -p "$WORK"
cp -r "$CORPUS/." "$WORK/"

pass=0; fail=0; skip=0
cd "$WORK" || exit 1
mapfile -d '' FILES < <(find . -name '*.bp' -print0 | sort -z)

for bp in "${FILES[@]}"; do
    rel="${bp#./}"
    name="$(basename "${bp%.bp}")"
    dir="$(dirname "$bp")"
    gdir="$GOLD/$(dirname "$rel")/~$name"
    [[ -d "$gdir" ]] || { skip=$((skip+1)); continue; }

    "$BP" expand "$bp" "$(realpath "$dir")" >/dev/null 2>&1

    case "$STAGE" in
        expand)
            "$BP" compile "$bp" "$(realpath "$dir")" >/dev/null 2>&1
            got="$dir/~$name/~$name.bp"; ref="$gdir/~$name.bp"
            ;;
        lmsb)
            got="$dir/~$name/$name.lmsb"; ref="$gdir/$name.lmsb"
            ;;
        rbf)
            got="$dir/~$name/$name.rbf"; ref="$gdir/$name.rbf"
            ;;
        *) echo "неизвестная стадия: $STAGE"; exit 2 ;;
    esac

    if [[ ! -f "$got" ]]; then
        fail=$((fail+1)); echo "FAIL(нет выхода) $rel"
    elif [[ "$STAGE" == "rbf" ]] && cmp -s "$got" "$ref"; then
        pass=$((pass+1))
    elif [[ "$STAGE" != "rbf" ]] && diff -q "$got" "$ref" >/dev/null 2>&1; then
        pass=$((pass+1))
    else
        fail=$((fail+1))
        echo "FAIL $rel"
        if [[ "${VERBOSE:-0}" == "1" ]]; then
            if [[ "$STAGE" == "rbf" ]]; then
                cmp "$got" "$ref" | head -3
                echo "  ожидалось $(stat -c%s "$ref") б, получено $(stat -c%s "$got") б"
            else
                diff "$ref" "$got" | head -15
            fi
        fi
    fi
done

echo "== $STAGE: pass=$pass fail=$fail skip=$skip"
[[ "$fail" -eq 0 ]]