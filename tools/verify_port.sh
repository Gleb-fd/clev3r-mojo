#!/usr/bin/env bash
# Утверждённая воротная команда порта: живой C#-оракул + точечные регрессии +
# benchmark Mojo baseline/current и C# на одной машине.
#
#   bash tools/verify_port.sh /home/ssssq/Projects/clev3r_linux/Clev3r-1
#
# Всё обязательное выполняется без opt-in флагов:
#   * сборка СВЕЖЕГО текущего CLI в уникальном scratch (не stale tools/bp);
#   * parity по корпусу (40 входов), include/module fixtures, ошибки по кодам;
#   * намеренные отличия (empty-source newline, '..' include) проверяются явно;
#   * benchmark: small, BrickBench, Generated3000 (3052 строки), include,
#     module, empty — warmup 3 / 9 замеров, медианы baseline/current/oracle;
#   * baseline Mojo обязателен: BP_BASELINE_BINARY или известный сохранённый
#     артефакт t10 с проверкой sha256; отсутствие baseline — ненулевой exit.
# JSON-отчёт остаётся в tests/.verify_port_work/<run>/report.json (gitignored).
#
# Переопределения:
#   BP_ORACLE_DLL        — путь к InterpreterConsole.dll
#   BP_BASELINE_BINARY   — baseline Mojo CLI (sha проверяется при BP_BASELINE_SHA256)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

ORACLE_ROOT="${1:-${BP_ORACLE_ROOT:-}}"
if [[ -z "$ORACLE_ROOT" ]]; then
    echo "Использование: bash tools/verify_port.sh /path/to/Clev3r-1" >&2
    echo "  (или BP_ORACLE_ROOT=/path/to/Clev3r-1)" >&2
    exit 2
fi
DLL="${BP_ORACLE_DLL:-$ORACLE_ROOT/InterpreterConsole/bin/Release/net6.0/InterpreterConsole.dll}"
[[ -f "$DLL" ]] || { echo "FAIL(verify_port): нет оракула: $DLL" >&2; exit 2; }

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
WORK="$ROOT/tests/.verify_port_work/run_${STAMP}_$$"
mkdir -p "$WORK" || exit 2

echo "== verify_port: сборка текущего CLI =="
cd "$ROOT" || exit 2
if ! uv run mojo build src/bp/main.mojo -o "$WORK/bp" >"$WORK/build.log" 2>&1; then
    echo "FAIL(verify_port): сборка текущего CLI"
    tail -30 "$WORK/build.log" | sed 's/^/    /'
    exit 1
fi
echo "OK   $WORK/bp ($(stat -c%s "$WORK/bp") b, sha256 $(sha256sum "$WORK/bp" | cut -d' ' -f1))"

echo "== verify_port: живой оракул, регрессии, benchmark =="
python3 tools/port_verify.py \
    --root "$ROOT" \
    --bp "$WORK/bp" \
    --oracle-dll "$DLL" \
    --work "$WORK/data" \
    --json "$WORK/report.json"
rc=$?
echo "verify_port exit=$rc; scratch: $WORK"
exit "$rc"
