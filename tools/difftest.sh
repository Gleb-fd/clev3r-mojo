#!/usr/bin/env bash
# Дифференциальный тест: выход Mojo-компилятора против C#-эталонов (tests/golden).
#
#   tools/difftest.sh expand    — ~<Имя>.bp  (стадии 1-2 + линковка)
#   tools/difftest.sh lmsb      — <Имя>.lmsb (стадия 3)
#   tools/difftest.sh rbf       — <Имя>.rbf  (стадия 4, побайтово)
#
# Требует собранный CLI: из корня репозитория
#   uv run mojo build src/bp/main.mojo -o tools/bp
#
# Свойства (fail-closed):
#   * ROOT выводится из расположения самого скрипта (работает из worktree);
#   * каждый запуск — свежий уникальный scratch, корпус копируется БЕЗ
#     сгенерированных каталогов '~*' (устаревшие артефакты не участвуют);
#   * код возврата каждой стадии и наличие каждого выходного файла проверяются;
#   * вход без эталона — FAIL, кроме явного allowlist известных случаев;
#   * эталон без входа — FAIL;
#   * пустой набор входов — FAIL; отсутствие хотя бы одного сверенного
#     входа — FAIL (нельзя получить зелёный результат на пустом множестве).
#
# Переопределения для негативных тестов (tools/tests/test_port.py):
#   DIFFTEST_BP, DIFFTEST_CORPUS, DIFFTEST_GOLD
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

STAGE="${1:-expand}"
case "$STAGE" in
    expand|lmsb|rbf) ;;
    *) echo "неизвестная стадия: $STAGE (expand|lmsb|rbf)" >&2; exit 2 ;;
esac

BP="${DIFFTEST_BP:-$ROOT/tools/bp}"
CORPUS="${DIFFTEST_CORPUS:-$ROOT/tests/corpus}"
GOLD="${DIFFTEST_GOLD:-$ROOT/tests/golden}"

# Входы, для которых эталон заведомо отсутствует по документированной причине:
# C#-оракул не разрешает include/import с '..' (New_Path_Examples), Mojo
# разрешает — это намеренное исправление, golden для него не создаётся.
# Любое другое расхождение "вход без эталона" обязано валить тест.
KNOWN_NO_GOLDEN=(
    "New_Path_Examples/Program1.bp"
)

die() { echo "FAIL(difftest): $*" >&2; exit 2; }

is_known_no_golden() {
    local rel="$1" k
    for k in "${KNOWN_NO_GOLDEN[@]}"; do
        [[ "$k" == "$rel" ]] && return 0
    done
    return 1
}

[[ -x "$BP" ]] || die "нет CLI: $BP — собери: uv run mojo build src/bp/main.mojo -o tools/bp"
[[ -d "$CORPUS" ]] || die "нет каталога корпуса: $CORPUS"
[[ -d "$GOLD" ]] || die "нет каталога эталонов: $GOLD"

# Для штатного корпуса репозитория зафиксирован согласованный набор:
# 41 вход = 40 сверяемых + 1 известный skip (New_Path_Examples '..').
# Переопределение DIFFTEST_CORPUS/DIFFTEST_GOLD (негативные тесты) отключает
# проверку точного набора, но не отключает fail-closed проверки ниже.
DEFAULT_SUITE=0
if [[ -z "${DIFFTEST_CORPUS:-}" && -z "${DIFFTEST_GOLD:-}" ]]; then
    DEFAULT_SUITE=1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/bp_diff_${STAGE}.XXXXXX")" || die "mktemp"
trap 'rm -rf "$WORK"' EXIT

# Копируем только исходники корпуса: каталоги '~*' — сгенерированный вывод,
# они не должны попадать ни в список входов, ни в рабочие артефакты.
if ! { (cd "$CORPUS" && find . -type d -name '~*' -prune -o -type f -print0 \
        | tar --null -T - -cf -) | (cd "$WORK" && tar -xf -); }; then
    die "не удалось скопировать корпус $CORPUS"
fi

mapfile -d '' FILES < <(cd "$WORK" && find . -name '*.bp' -print0 | sort -z)
(( ${#FILES[@]} > 0 )) || die "пустой корпус (нет *.bp): $CORPUS"

declare -A INPUTS=()
for bp in "${FILES[@]}"; do
    INPUTS["${bp#./}"]=1
done

fail=0
pass=0
skip=0
processed=0

# --- проверка: эталон без соответствующего входа ---
while IFS= read -r -d '' gd; do
    grel="${gd#"$GOLD"/}"
    gparent="$(dirname "$grel")"
    # вложенные повторные развёртки (~X/~~X/...) — не входы корпуса
    case "/$gparent/" in
        */~*/) continue ;;
    esac
    gbase="$(basename "$grel")"
    name="${gbase#\~}"
    if [[ "$gparent" == "." ]]; then
        expected="$name.bp"
    else
        expected="$gparent/$name.bp"
    fi
    if [[ -z "${INPUTS[$expected]:-}" ]]; then
        echo "FAIL(эталон без входа) $grel"
        fail=$((fail + 1))
    fi
done < <(find "$GOLD" -type d -name '~*' -print0 | sort -z)

# --- основной проход по входам корпуса ---
cd "$WORK" || die "cd $WORK"
for bp in "${FILES[@]}"; do
    rel="${bp#./}"
    name="$(basename "${bp%.bp}")"
    dir="$(dirname "$bp")"
    gdir="$GOLD/$dir/~$name"
    processed=$((processed + 1))

    if [[ ! -d "$gdir" ]]; then
        if is_known_no_golden "$rel"; then
            skip=$((skip + 1))
            echo "SKIP(известный случай без эталона) $rel"
        else
            fail=$((fail + 1))
            echo "FAIL(нет эталона) $rel"
        fi
        continue
    fi

    log="$WORK/.log"
    if ! "$BP" expand "$bp" "$(realpath "$dir")" >"$log" 2>&1; then
        fail=$((fail + 1))
        echo "FAIL(expand rc) $rel"
        head -3 "$log" | sed 's/^/    /'
        continue
    fi
    expfile="$dir/~$name/~$name.bp"
    if [[ ! -f "$expfile" ]]; then
        fail=$((fail + 1))
        echo "FAIL(expand: нет выхода) $rel"
        continue
    fi

    case "$STAGE" in
        expand)
            got="$expfile"
            ref="$gdir/~$name.bp"
            ;;
        lmsb)
            if ! "$BP" lmsb "$expfile" >"$log" 2>&1; then
                fail=$((fail + 1))
                echo "FAIL(lmsb rc) $rel"
                head -3 "$log" | sed 's/^/    /'
                continue
            fi
            got="$dir/~$name/$name.lmsb"
            ref="$gdir/$name.lmsb"
            ;;
        rbf)
            if ! "$BP" lmsb "$expfile" >"$log" 2>&1; then
                fail=$((fail + 1))
                echo "FAIL(lmsb rc) $rel"
                head -3 "$log" | sed 's/^/    /'
                continue
            fi
            lmsb="$dir/~$name/$name.lmsb"
            if [[ ! -f "$lmsb" ]]; then
                fail=$((fail + 1))
                echo "FAIL(lmsb: нет выхода) $rel"
                continue
            fi
            if ! "$BP" rbf "$lmsb" >"$log" 2>&1; then
                fail=$((fail + 1))
                echo "FAIL(rbf rc) $rel"
                head -3 "$log" | sed 's/^/    /'
                continue
            fi
            got="$dir/~$name/$name.rbf"
            ref="$gdir/$name.rbf"
            ;;
    esac

    if [[ ! -f "$got" ]]; then
        fail=$((fail + 1))
        echo "FAIL(нет выхода $STAGE) $rel"
    elif [[ ! -f "$ref" ]]; then
        fail=$((fail + 1))
        echo "FAIL(нет эталона $STAGE) $rel"
    elif cmp -s "$got" "$ref"; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL $rel"
        if [[ "${VERBOSE:-0}" == "1" ]]; then
            if [[ "$STAGE" == "rbf" ]]; then
                cmp "$got" "$ref" 2>&1 | head -3 | sed 's/^/    /'
                echo "    ожидалось $(stat -c%s "$ref") б, получено $(stat -c%s "$got") б"
            else
                diff "$ref" "$got" 2>&1 | head -15 | sed 's/^/    /'
            fi
        fi
    fi
done

echo "== $STAGE: pass=$pass fail=$fail skip=$skip inputs=${#FILES[@]}"

if (( DEFAULT_SUITE == 1 )); then
    if (( ${#FILES[@]} != 41 || pass != 40 || skip != 1 || fail != 0 )); then
        echo "FAIL(difftest): ожидался согласованный набор inputs=41 pass=40 skip=1 fail=0, получено inputs=${#FILES[@]} pass=$pass skip=$skip fail=$fail" >&2
        fail=$((fail + 1))
    fi
fi

if (( processed != ${#FILES[@]} )); then
    echo "FAIL(difftest): внутренняя ошибка учёта ($processed != ${#FILES[@]})" >&2
    exit 2
fi
if (( pass == 0 )); then
    echo "FAIL(difftest): нет ни одного сверенного входа — зелёный результат запрещён" >&2
    exit 1
fi
(( fail == 0 ))
