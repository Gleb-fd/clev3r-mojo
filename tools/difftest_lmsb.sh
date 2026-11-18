#!/usr/bin/env bash
# Дифференциальный тест стадии 3: .lmsb против C#-оракула (tests/golden).
#
# Для каждого каталога tests/golden/**/~<Имя>/ (содержащего ~<Имя>.bp):
#   1. копируем развёрнутый исходник во временную папку (не трогаем golden);
#   2. запускаем `<bp> lmsb <копия>` (пишет <Имя>.lmsb рядом);
#   3. сравниваем с оракулом <Имя>.lmsb (или ~<Имя>.lmsb во вложенных
#      re-развёртках — там проект назывался ~<Имя>.bp);
#   4. второй контур: прогоняем СВОЙ .lmsb через `<bp> rbf` и сравниваем
#      с эталонным <Имя>.rbf (чувствительный индикатор адресов/инструкций).
#
# Использование:
#   tools/difftest_lmsb.sh [путь-к-CLI]     # по умолчанию <ROOT>/tools/bp
#
# Переопределения (негативные тесты): DIFFTEST_BP, DIFFTEST_GOLD
# Коды выхода: 0 — все pass; 1 — есть fail; 2 — окружение/пустой набор.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

BP="${DIFFTEST_BP:-${1:-$ROOT/tools/bp}}"
GOLD="${DIFFTEST_GOLD:-$ROOT/tests/golden}"

die() { echo "FAIL(difftest_lmsb): $*" >&2; exit 2; }

[[ -x "$BP" ]] || die "нет CLI: $BP — собери: uv run mojo build src/bp/main.mojo -o tools/bp"
[[ -d "$GOLD" ]] || die "нет каталога эталонов: $GOLD"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/bp_lmsb_diff.XXXXXX")" || die "mktemp"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0; skip=0; rbf_pass=0; rbf_fail=0
failed_list=()
skipped_list=()

mapfile -d '' DIRS < <(find "$GOLD" -type d -name '~*' -print0 | sort -z)
(( ${#DIRS[@]} > 0 )) || die "в golden нет каталогов развёрток: $GOLD"

for gdir in "${DIRS[@]}"; do
    rel="${gdir#"$GOLD"/}"
    srcname="$(basename "$gdir").bp"
    bpfile="$gdir/$srcname"
    [[ -f "$bpfile" ]] || continue

    plainname="$(basename "$gdir" | sed 's/^~*//')"
    oracle=""
    for cand in "$gdir/$plainname.lmsb" "$gdir/~$plainname.lmsb"; do
        [[ -f "$cand" ]] && { oracle="$cand"; break; }
    done
    if [[ -z "$oracle" ]]; then
        skip=$((skip + 1)); skipped_list+=("$rel: нет оракула .lmsb")
        continue
    fi

    wdir="$WORK/$rel"
    mkdir -p "$wdir"
    cp "$bpfile" "$wdir/"

    out="$("$BP" lmsb "$wdir/$srcname" 2>&1)"
    rc=$?
    nameonly="${srcname#\~}"
    produced="$wdir/${nameonly%.bp}.lmsb"
    if [[ $rc -ne 0 ]]; then
        fail=$((fail + 1)); failed_list+=("$rel: КОМАНДА УПАЛА (rc=$rc): $out")
        continue
    fi
    if [[ ! -f "$produced" ]]; then
        fail=$((fail + 1)); failed_list+=("$rel: НЕТ ВЫХОДА .lmsb (rc=0)")
        continue
    fi

    if cmp -s "$produced" "$oracle"; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        firstdiff="$(diff "$produced" "$oracle" 2>&1 | head -6 | tr '\n' ' | ')"
        failed_list+=("$rel: РАСХОЖДЕНИЕ .lmsb: $firstdiff")
    fi

    plainrbf="$gdir/$plainname.rbf"
    tilderbf="$gdir/~$plainname.rbf"
    if [[ -f "$plainrbf" || -f "$tilderbf" ]]; then
        if "$BP" rbf "$produced" >/dev/null 2>&1; then
            myrbf="${produced%.lmsb}.rbf"
            if [[ -f "$myrbf" ]] && { cmp -s "$myrbf" "$plainrbf" || cmp -s "$myrbf" "$tilderbf"; }; then
                rbf_pass=$((rbf_pass + 1))
            else
                rbf_fail=$((rbf_fail + 1))
                failed_list+=("$rel: РАСХОЖДЕНИЕ .rbf (мой .lmsb → .rbf)")
            fi
        else
            rbf_fail=$((rbf_fail + 1))
            failed_list+=("$rel: bp rbf упал на моём .lmsb")
        fi
    fi
done

echo "=== difftest_lmsb: pass=$pass fail=$fail skip=$skip | контур rbf: pass=$rbf_pass fail=$rbf_fail"
if [[ ${#skipped_list[@]} -gt 0 ]]; then
    echo "--- skip:"
    for s in "${skipped_list[@]}"; do echo "  SKIP $s"; done
fi
if [[ ${#failed_list[@]} -gt 0 ]]; then
    echo "--- fail (первые строки расхождения):"
    for f in "${failed_list[@]}"; do echo "  FAIL $f"; done
    exit 1
fi
exit 0
