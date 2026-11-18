#!/usr/bin/env bash
# Полная верификация проекта: сборка CLI, юнит-тесты Mojo, негативные тесты
# собственных ворот и дифференциальные стадии против C#-эталонов.
#
#   bash tools/verify_all.sh
#
# ВАЖНО: в ветке одного worker'а часть тестов создаётся другими worker'ами
# (util_test/compiler3_test/preproc_test/asm_test, tools/tests/test_lsp.py и
# т.д.). Отсутствие такого теста — это FAIL("MISSING"), а не молчаливый skip:
# зелёный результат полного прогона возможен только после интеграции.
#
# Fail-closed: любая стадия проверяет свой код возврата; дифференциальные
# стадии работают на свежем уникальном scratch (см. tools/difftest.sh).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT" || { echo "FAIL: не удалось перейти в $ROOT"; exit 2; }

FIXTURES="$ROOT/tools/tests/fixtures"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/bp_verify_all.XXXXXX")" || exit 2
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/selftest" "$SCRATCH/buildcmd"

fail=0

note_fail() {
    echo "FAIL $*"
    fail=1
}

echo "== сборка CLI =="
if uv run mojo build src/bp/main.mojo -o tools/bp >"$SCRATCH/build.log" 2>&1; then
    echo "OK   tools/bp ($(stat -c%s tools/bp) b)"
else
    echo "FAIL сборка tools/bp"
    tail -20 "$SCRATCH/build.log" | sed 's/^/    /'
    exit 1
fi

run_mojo_test() {
    local name="$1"
    local src="src/bp/$name.mojo"
    local log="$SCRATCH/$name.log"
    if [[ ! -f "$src" ]]; then
        note_fail "$name: MISSING $src (тест создаётся другим worker'ом; до интеграции полный прогон зелёным не считается)"
        return
    fi
    if uv run mojo run "$src" >"$log" 2>&1; then
        echo "OK   $name"
    else
        echo "FAIL $name (rc=$?)"
        tail -20 "$log" | sed 's/^/    /'
        fail=1
    fi
}

echo "== юнит-тесты Mojo =="
run_mojo_test lexer_test
run_mojo_test util_test
run_mojo_test compiler3_test
run_mojo_test preproc_test
run_mojo_test asm_test

if [[ -f src/bp/selftest.mojo ]]; then
    if BP_SELFTEST_FIXTURE="$FIXTURES/selftest/Program1.bp" \
       BP_SELFTEST_SCRATCH="$SCRATCH/selftest" \
       uv run mojo run src/bp/selftest.mojo >"$SCRATCH/selftest.log" 2>&1; then
        echo "OK   selftest (hermetic fixture)"
    else
        echo "FAIL selftest"
        tail -20 "$SCRATCH/selftest.log" | sed 's/^/    /'
        fail=1
    fi
else
    note_fail "selftest: MISSING src/bp/selftest.mojo"
fi

if [[ -f src/bp/flash_test.mojo ]]; then
    if uv run mojo run src/bp/flash_test.mojo >"$SCRATCH/flash_test.log" 2>&1; then
        echo "OK   flash_test (без железа)"
    else
        echo "FAIL flash_test"
        tail -20 "$SCRATCH/flash_test.log" | sed 's/^/    /'
        fail=1
    fi
else
    note_fail "flash_test: MISSING src/bp/flash_test.mojo"
fi

if [[ -f src/bp/buildcmd_test.mojo ]]; then
    if BP_BUILDCMD_FIXTURES="$FIXTURES" \
       BP_BUILDCMD_SCRATCH="$SCRATCH/buildcmd" \
       uv run mojo run src/bp/buildcmd_test.mojo >"$SCRATCH/buildcmd_test.log" 2>&1; then
        echo "OK   buildcmd_test (self-contained fixtures)"
    else
        echo "FAIL buildcmd_test"
        tail -20 "$SCRATCH/buildcmd_test.log" | sed 's/^/    /'
        fail=1
    fi
else
    note_fail "buildcmd_test: MISSING src/bp/buildcmd_test.mojo"
fi

echo "== негативные тесты собственных ворот =="
if [[ -f tools/tests/test_port.py ]]; then
    if python3 tools/tests/test_port.py >"$SCRATCH/test_port.log" 2>&1; then
        echo "OK   tools/tests/test_port.py"
    else
        echo "FAIL tools/tests/test_port.py"
        tail -40 "$SCRATCH/test_port.log" | sed 's/^/    /'
        fail=1
    fi
else
    note_fail "tools/tests/test_port.py: MISSING"
fi

echo "== дифференциальные стадии против C#-эталонов (tests/golden) =="
for stage in expand lmsb rbf; do
    if bash tools/difftest.sh "$stage" >"$SCRATCH/difftest_$stage.log" 2>&1; then
        echo "OK   difftest $stage: $(grep -E '^== ' "$SCRATCH/difftest_$stage.log" | tail -1)"
    else
        echo "FAIL difftest $stage"
        tail -20 "$SCRATCH/difftest_$stage.log" | sed 's/^/    /'
        fail=1
    fi
done

for script in difftest_lmsb difftest_rbf; do
    if bash "tools/$script.sh" >"$SCRATCH/$script.log" 2>&1; then
        echo "OK   $script: $(grep -E '^(=== |== )' "$SCRATCH/$script.log" | tail -1)"
    else
        echo "FAIL $script"
        tail -20 "$SCRATCH/$script.log" | sed 's/^/    /'
        fail=1
    fi
done

echo
if (( fail == 0 )); then
    echo "VERIFY_ALL OK"
else
    echo "VERIFY_ALL FAIL (см. строки FAIL/MISSING выше)"
fi
exit "$fail"
