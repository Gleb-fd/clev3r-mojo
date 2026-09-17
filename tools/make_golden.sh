#!/usr/bin/env bash
# Собирает эталонные артефакты (golden) для дифференциального тестирования
# Mojo-компилятора против C#-оракула (Clev3r InterpreterConsole).
#
# Для каждого tests/corpus/**/*.bp оракул создаёт рядом папку ~<Name>/ с:
#   ~<Name>.bp   — развёрнутый исходник (вывод интерпретатора, gv_/lv_/f_-имена)
#   <Name>.lmsb  — ассемблер-листинг (текстовый, вход ассемблера)
#   <Name>.rbf   — бинарный байткод EV3
# Всё это складывается в tests/golden/<относительный путь>/.
set -uo pipefail

SRC="/home/ssssq/Projects/clev3r_linux/Clev3r-1"
ROOT="/home/ssssq/Projects/clev3r_mojo"
DLL="$SRC/InterpreterConsole/bin/Release/net6.0/InterpreterConsole.dll"
WORK="$ROOT/tests/.oracle_work"
GOLD="$ROOT/tests/golden"
LOG="$ROOT/tests/golden_report.txt"

[[ -f "$DLL" ]] || { echo "нет оракула: $DLL"; exit 1; }

rm -rf "$WORK" "$GOLD"
mkdir -p "$WORK" "$GOLD"
cp -r "$ROOT/tests/corpus/." "$WORK/"

: > "$LOG"
cd "$WORK" || exit 1
ok=0; fail=0
mapfile -d '' BPS < <(find . -name '*.bp' -print0 | sort -z)
for bp in "${BPS[@]}"; do
    rel="${bp#./}"
    name="$(basename "${bp%.bp}")"
    dir="$(dirname "$bp")"
    out="$(DOTNET_ROLL_FORWARD=LatestMajor dotnet "$DLL" "$bp" "$(realpath "$dir")" 2>&1)"
    if [[ -f "$dir/~$name/$name.rbf" ]]; then
        ok=$((ok+1)); echo "OK   $rel ($(stat -c%s "$dir/~$name/$name.rbf") b)" >> "$LOG"
    else
        fail=$((fail+1)); echo "FAIL $rel" >> "$LOG"; echo "$out" >> "$LOG"; echo "---" >> "$LOG"
    fi
done < <(cd "$WORK" && find . -name '*.bp' -print0 | sort -z)

# переносим все каталоги вывода в golden с сохранением структуры
while IFS= read -r -d '' d; do
    rel="${d#./}"
    mkdir -p "$GOLD/$(dirname "$rel")"
    cp -r "$d" "$GOLD/$rel"
done < <(cd "$WORK" && find . -type d -name '~*' -print0)

{
    echo "ok=$ok fail=$fail"
    echo "rbf files: $(find "$GOLD" -name '*.rbf' | wc -l)"
    echo "lmsb files: $(find "$GOLD" -name '*.lmsb' | wc -l)"
} | tee -a "$LOG"
