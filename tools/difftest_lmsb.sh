#!/usr/bin/env bash
# Дифференциальный тест стадии 3: .lmsb против C#-оракула (tests/golden).
#
# Для каждого каталога tests/golden/**/~<Имя>/ (содержащего ~<Имя>.bp):
#   1. копируем развёрнутый исходник во временную папку (не трогаем golden);
#   2. запускаем `tools/bp lmsb <копия>` (пишет <Имя>.lmsb рядом);
#   3. сравниваем с оракулом <Имя>.lmsb (или ~<Имя>.lmsb во вложенных
#      re-развёртках — там проект назывался ~<Имя>.bp);
#   4. второй контур: прогоняем СВОЙ .lmsb через `tools/bp rbf` и сравниваем
#      с эталонным <Имя>.rbf (чувствительный индикатор адресов/инструкций).
#
# Использование:
#   tools/difftest_lmsb.sh [путь-к-CLI]     # по умолчанию tools/bp
#
# Коды выхода: 0 — все pass; 1 — есть fail.
set -uo pipefail

ROOT="/home/ssssq/Projects/clev3r_mojo"
BP="${1:-$ROOT/tools/bp}"
GOLD="$ROOT/tests/golden"
WORK="$(mktemp -d /tmp/bp_lmsb_diff.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

if [[ ! -x "$BP" ]]; then
    echo "нет CLI: $BP — собери: cd $ROOT && uv run mojo build src/bp/main.mojo -o tools/bp"
    exit 2
fi

pass=0; fail=0; skip=0; rbf_pass=0; rbf_fail=0
failed_list=()
skipped_list=()

# все каталоги развёрток на любой глубине
mapfile -d '' DIRS < <(find "$GOLD" -type d -name '~*' -print0 | sort -z)

for gdir in "${DIRS[@]}"; do
    rel="${gdir#"$GOLD"/}"
    # исходник развёртки: <имя-каталога>.bp (~X.bp в ~X/, ~~X.bp в ~~X/)
    srcname="$(basename "$gdir").bp"
    bpfile="$gdir/$srcname"
    [[ -f "$bpfile" ]] || { continue; }

    # оракул: <Имя>.lmsb, где <Имя> = имя каталога без ведущих '~'
    plainname="$(basename "$gdir" | sed 's/^~*//')"
    oracle=""
    for cand in "$gdir/$plainname.lmsb" "$gdir/~$plainname.lmsb"; do
        [[ -f "$cand" ]] && { oracle="$cand"; break; }
    done
    if [[ -z "$oracle" ]]; then
        skip=$((skip+1)); skipped_list+=("$rel: нет оракула .lmsb")
        continue
    fi

    wdir="$WORK/$rel"
    mkdir -p "$wdir"
    cp "$bpfile" "$wdir/"

    out="$("$BP" lmsb "$wdir/$srcname" 2>&1)"
    rc=$?
    nameonly="${srcname#\~}"
    produced="$wdir/${nameonly%.bp}.lmsb"   # <Имя>.lmsb (без ведущего ~)
    if [[ $rc -ne 0 || ! -f "$produced" ]]; then
        fail=$((fail+1)); failed_list+=("$rel: КОМАНДА УПАЛА (rc=$rc): $out")
        continue
    fi

    if diff -q "$produced" "$oracle" >/dev/null 2>&1; then
        pass=$((pass+1))
    else
        fail=$((fail+1))
        firstdiff="$(diff "$produced" "$oracle" | head -6 | tr '\n' ' | ')"
        failed_list+=("$rel: РАСХОЖДЕНИЕ .lmsb: $firstdiff")
    fi

    # --- второй контур: мой .lmsb → мой .rbf против эталонного .rbf ---
    plainrbf="$gdir/$plainname.rbf"
    tilderbf="$gdir/~$plainname.rbf"
    if [[ -f "$plainrbf" || -f "$tilderbf" ]]; then
        if "$BP" rbf "$produced" >/dev/null 2>&1; then
            myrbf="${produced%.lmsb}.rbf"
            if diff -q "$myrbf" "$plainrbf" >/dev/null 2>&1 || diff -q "$myrbf" "$tilderbf" >/dev/null 2>&1; then
                rbf_pass=$((rbf_pass+1))
            else
                rbf_fail=$((rbf_fail+1))
                failed_list+=("$rel: РАСХОЖДЕНИЕ .rbf (мой .lmsb → .rbf)")
            fi
        else
            rbf_fail=$((rbf_fail+1))
            failed_list+=("$rel: `bp rbf` упал на моём .lmsb")
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
