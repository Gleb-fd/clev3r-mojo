#!/usr/bin/env bash
# Пересборка эталонных артефактов (tests/golden) оракулом C# (Clev3r).
#
#   bash tools/make_golden.sh --oracle-root /path/to/Clev3r-1           # dry-run
#   bash tools/make_golden.sh --oracle-root /path/to/Clev3r-1 --apply   # замена
#
# Безопасность:
#   * по умолчанию НИЧЕГО не меняет в tests/golden: оракул отрабатывает в
#     свежем уникальном staging-каталоге, результат сравнивается с текущим
#     golden (read-only);
#   * tests/golden заменяется только при явном --apply И только после того,
#     как ВСЕ входы успешно собраны (fail=0, ok=expected); старый golden
#     сохраняется в staging до успешной подмены и восстанавливается при сбое;
#   * успех входа = код возврата оракула 0 И все три выхода (~<Имя>.bp,
#     <Имя>.lmsb, <Имя>.rbf) на месте: артефакты при rc!=0 или частичный
#     вывод не считаются успехом и блокируют --apply (старый golden цел);
#   * сгенерированные каталоги '~*' из корпуса в staging не копируются —
#     входы берутся только из исходников;
#   * известные входы, которые оракул не поддерживает, пропускаются по
#     явному allowlist и не считаются успехом/провалом сверки.
#
# Переменные: BP_ORACLE_ROOT (альтернатива --oracle-root),
#             BP_ORACLE_DLL  (по умолчанию .../InterpreterConsole.dll).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

ORACLE_ROOT="${BP_ORACLE_ROOT:-}"
DLL="${BP_ORACLE_DLL:-}"
APPLY=0

usage() {
    cat >&2 <<EOF
Использование: bash tools/make_golden.sh --oracle-root DIR [--apply]
  --oracle-root DIR  корень C#-проекта Clev3r (или BP_ORACLE_ROOT)
  --apply            заменить tests/golden после полного успеха (явное подтверждение)
Без --apply выполняется только staging + сравнение, tests/golden не меняется.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --oracle-root) ORACLE_ROOT="${2:-}"; shift 2 ;;
        --oracle-root=*) ORACLE_ROOT="${1#*=}"; shift ;;
        --apply) APPLY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "неизвестный аргумент: $1" >&2; usage; exit 2 ;;
    esac
done

[[ -n "$ORACLE_ROOT" ]] || { usage; exit 2; }
[[ -n "$DLL" ]] || DLL="$ORACLE_ROOT/InterpreterConsole/bin/Release/net6.0/InterpreterConsole.dll"

CORPUS="$ROOT/tests/corpus"
GOLD="$ROOT/tests/golden"
REPORT="$ROOT/tests/golden_report.txt"

die() { echo "FAIL(make_golden): $*" >&2; exit 2; }

[[ -f "$DLL" ]] || die "нет оракула: $DLL"
command -v dotnet >/dev/null 2>&1 || die "нет dotnet в PATH"
[[ -d "$CORPUS" ]] || die "нет корпуса: $CORPUS"

# Входы, которые C#-оракул не поддерживает (include/import с '..'):
# golden для них не создаётся; Mojo обрабатывает их намеренно лучше.
KNOWN_ORACLE_UNSUPPORTED=(
    "New_Path_Examples/Program1.bp"
)

is_unsupported() {
    local rel="$1" k
    for k in "${KNOWN_ORACLE_UNSUPPORTED[@]}"; do
        [[ "$k" == "$rel" ]] && return 0
    done
    return 1
}

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/bp_golden_stage.XXXXXX")" || die "mktemp"
trap 'rm -rf "$STAGE"' EXIT

WORK="$STAGE/corpus"
OUT="$STAGE/golden"
mkdir -p "$WORK" "$OUT"

if ! { (cd "$CORPUS" && find . -type d -name '~*' -prune -o -type f -print0 \
        | tar --null -T - -cf -) | (cd "$WORK" && tar -xf -); }; then
    die "не удалось скопировать корпус в staging"
fi

mapfile -d '' BPS < <(cd "$WORK" && find . -name '*.bp' -print0 | sort -z)
(( ${#BPS[@]} > 0 )) || die "пустой корпус: $CORPUS"

LOG="$STAGE/golden_report.txt"
: > "$LOG"
ok=0; fail=0; skipped=0
cd "$WORK" || die "cd $WORK"
for bp in "${BPS[@]}"; do
    rel="${bp#./}"
    name="$(basename "${bp%.bp}")"
    dir="$(dirname "$bp")"

    if is_unsupported "$rel"; then
        skipped=$((skipped + 1))
        echo "SKIP(известный неподдерживаемый оракулом вход) $rel" | tee -a "$LOG"
        continue
    fi

    out="$(DOTNET_ROLL_FORWARD=LatestMajor dotnet "$DLL" "$bp" "$(realpath "$dir")" 2>&1)"
    rc=$?
    outdir="$dir/~$name"
    # Полный успешный вход: оракул вернул 0 И создал все три артефакта.
    # Наличие .lmsb/.rbf само по себе не доказывает успех (оракул мог упасть,
    # оставив частичный/старый вывод).
    missing=()
    for required in "$outdir/~$name.bp" "$outdir/$name.lmsb" "$outdir/$name.rbf"; do
        [[ -f "$required" ]] || missing+=("$(basename "$required")")
    done
    if (( rc == 0 )) && (( ${#missing[@]} == 0 )); then
        ok=$((ok + 1))
        echo "OK   $rel ($(stat -c%s "$outdir/$name.rbf") b)" >> "$LOG"
    else
        fail=$((fail + 1))
        reason="oracle rc=$rc"
        (( ${#missing[@]} > 0 )) && reason="$reason, нет выходов: ${missing[*]}"
        echo "FAIL $rel ($reason)" >> "$LOG"
        echo "$out" >> "$LOG"
        echo "---" >> "$LOG"
        echo "FAIL $rel ($reason)" >&2
    fi
done

expected=$(( ${#BPS[@]} - skipped ))
{
    echo "ok=$ok fail=$fail skipped=$skipped inputs=${#BPS[@]}"
    echo "rbf files: $(find "$WORK" -name '*.rbf' | wc -l)"
    echo "lmsb files: $(find "$WORK" -name '*.lmsb' | wc -l)"
} | tee -a "$LOG"

if (( fail != 0 || ok != expected )); then
    echo "FAIL(make_golden): staging неполный (ok=$ok expected=$expected fail=$fail); tests/golden не изменён (публикация отменена)" >&2
    exit 1
fi

# Собираем только каталоги верхнего уровня '~<Имя>' (вложенные идут внутри них).
while IFS= read -r -d '' d; do
    rel="${d#./}"
    parent="$(dirname "$rel")"
    case "/$parent/" in
        */~*/) continue ;;
    esac
    mkdir -p "$OUT/$parent"
    cp -r "$d" "$OUT/$rel"
done < <(cd "$WORK" && find . -type d -name '~*' -print0 | sort -z)

staged=$(find "$OUT" -type d -name '~*' | wc -l)
(( staged > 0 )) || die "staging не содержит каталогов '~*'"

echo "staged golden dirs: $staged"

if [[ -d "$GOLD" ]]; then
    if diff -r -q "$OUT" "$GOLD" >"$STAGE/golden.diff" 2>&1; then
        echo "staged golden идентичен текущему tests/golden"
    else
        echo "staged golden отличается от текущего tests/golden:"
        head -20 "$STAGE/golden.diff" | sed 's/^/    /'
    fi
fi

if (( APPLY == 0 )); then
    echo "DRY-RUN: tests/golden не изменён (для замены нужен явный --apply)"
    exit 0
fi

# --- явный --apply: подмена только после полного успеха ---
BACKUP="$STAGE/golden.old"
if [[ -d "$GOLD" ]]; then
    mv "$GOLD" "$BACKUP" || die "не удалось отодвинуть старый golden"
fi
if ! mv "$OUT" "$GOLD"; then
    [[ -d "$BACKUP" ]] && mv "$BACKUP" "$GOLD"
    die "не удалось заменить tests/golden; старый golden восстановлен"
fi
cp "$LOG" "$REPORT" || echo "WARN: не удалось обновить $REPORT" >&2
echo "APPLIED: tests/golden заменён (ok=$ok skipped=$skipped)"
