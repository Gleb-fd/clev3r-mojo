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
# Fail-closed:
#   * отсутствие .lmsb-оракула — FAIL (а не skip): каталог эталона без
#     оракула означает неполный набор;
#   * отсутствие .rbf-оракула — FAIL: второй контур обязателен для каждого
#     сверяемого входа (иначе «pass=1, rbf pass=0, rc=0» — ложный зелёный);
#   * pass==0 или rbf_pass==0 — FAIL (нельзя получить зелёный на пустом
#     множестве сравнений);
#   * для штатного tests/golden (DIFFTEST_GOLD не задан) ожидается полный
#     согласованный набор: 46 каталогов развёрток = 46 .lmsb + 46 .rbf
#     (40 верхнеуровневых программ + вложенные варианты ~~X). Уменьшение
#     набора (например, после make_golden --apply, который теряет вложенные
#     каталоги) — FAIL, а не «новый согласованный набор».
#
# Использование:
#   tools/difftest_lmsb.sh [путь-к-CLI]     # по умолчанию $BP_BINARY или <ROOT>/tools/bp
#
# Переопределения (негативные тесты): DIFFTEST_BP, DIFFTEST_GOLD
# Коды выхода: 0 — все pass; 1 — есть fail/неполный набор; 2 — окружение.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

BP="${DIFFTEST_BP:-${BP_BINARY:-${1:-$ROOT/tools/bp}}}"
GOLD="${DIFFTEST_GOLD:-$ROOT/tests/golden}"

# Полный набор tests/golden фиксирован: 40 верхнеуровневых программ +
# вложенные повторные развёртки (46 каталогов '~*', по .lmsb и .rbf в каждом).
EXPECTED_DIRS=46

die() { echo "FAIL(difftest_lmsb): $*" >&2; exit 2; }

[[ -x "$BP" ]] || die "нет CLI: $BP — собери: uv run mojo build src/bp/main.mojo -o tools/bp"
[[ -d "$GOLD" ]] || die "нет каталога эталонов: $GOLD"

# Штатный набор проверяем по точному размеру; переопределение DIFFTEST_GOLD
# (негативные тесты) отключает проверку размера, но не fail-closed проверки.
DEFAULT_SUITE=0
if [[ -z "${DIFFTEST_GOLD:-}" ]]; then
    DEFAULT_SUITE=1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/bp_lmsb_diff.XXXXXX")" || die "mktemp"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0; skip=0; rbf_pass=0; rbf_fail=0
missing_lmsb=0; missing_rbf=0; no_source=0
failed_list=()

mapfile -d '' DIRS < <(find "$GOLD" -type d -name '~*' -print0 | sort -z)
(( ${#DIRS[@]} > 0 )) || die "в golden нет каталогов развёрток: $GOLD"

for gdir in "${DIRS[@]}"; do
    rel="${gdir#"$GOLD"/}"
    srcname="$(basename "$gdir").bp"
    bpfile="$gdir/$srcname"
    if [[ ! -f "$bpfile" ]]; then
        no_source=$((no_source + 1))
        failed_list+=("$rel: нет исходника $srcname в каталоге эталона")
        continue
    fi

    plainname="$(basename "$gdir" | sed 's/^~*//')"
    oracle=""
    for cand in "$gdir/$plainname.lmsb" "$gdir/~$plainname.lmsb"; do
        [[ -f "$cand" ]] && { oracle="$cand"; break; }
    done
    if [[ -z "$oracle" ]]; then
        missing_lmsb=$((missing_lmsb + 1))
        failed_list+=("$rel: нет оракула .lmsb — неполный набор эталонов")
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

    # --- второй контур (rbf) обязателен для каждого сверяемого входа ---
    rbf_oracle=""
    for cand in "$gdir/$plainname.rbf" "$gdir/~$plainname.rbf"; do
        [[ -f "$cand" ]] && { rbf_oracle="$cand"; break; }
    done
    if [[ -z "$rbf_oracle" ]]; then
        missing_rbf=$((missing_rbf + 1))
        failed_list+=("$rel: нет оракула .rbf — контур rbf обязателен, не skip")
        continue
    fi

    if "$BP" rbf "$produced" >/dev/null 2>&1; then
        myrbf="${produced%.lmsb}.rbf"
        if [[ -f "$myrbf" ]] && cmp -s "$myrbf" "$rbf_oracle"; then
            rbf_pass=$((rbf_pass + 1))
        else
            rbf_fail=$((rbf_fail + 1))
            failed_list+=("$rel: РАСХОЖДЕНИЕ .rbf (мой .lmsb → .rbf)")
        fi
    else
        rbf_fail=$((rbf_fail + 1))
        failed_list+=("$rel: bp rbf упал на моём .lmsb")
    fi
done

echo "=== difftest_lmsb: pass=$pass fail=$fail skip=$skip | контур rbf: pass=$rbf_pass fail=$rbf_fail | нет .lmsb: $missing_lmsb, нет .rbf: $missing_rbf, без исходника: $no_source"
if [[ ${#failed_list[@]} -gt 0 ]]; then
    echo "--- fail (первые строки расхождения):"
    for f in "${failed_list[@]}"; do echo "  FAIL $f"; done
fi

if (( pass == 0 )); then
    echo "FAIL(difftest_lmsb): нет ни одного сверенного .lmsb — зелёный результат запрещён" >&2
    exit 1
fi
if (( rbf_pass == 0 )); then
    echo "FAIL(difftest_lmsb): контур rbf не сверен ни для одного входа — зелёный результат запрещён" >&2
    exit 1
fi
if (( DEFAULT_SUITE == 1 )); then
    if (( ${#DIRS[@]} != EXPECTED_DIRS || pass != EXPECTED_DIRS || rbf_pass != EXPECTED_DIRS \
          || fail != 0 || rbf_fail != 0 || missing_lmsb != 0 || missing_rbf != 0 || no_source != 0 )); then
        echo "FAIL(difftest_lmsb): ожидался полный набор dirs=$EXPECTED_DIRS lmsb_pass=$EXPECTED_DIRS rbf_pass=$EXPECTED_DIRS без пропусков, получено dirs=${#DIRS[@]} lmsb_pass=$pass rbf_pass=$rbf_pass fail=$fail rbf_fail=$rbf_fail missing_lmsb=$missing_lmsb missing_rbf=$missing_rbf no_source=$no_source" >&2
        exit 1
    fi
fi
if (( fail != 0 || rbf_fail != 0 || missing_lmsb != 0 || missing_rbf != 0 || no_source != 0 )); then
    exit 1
fi
exit 0
