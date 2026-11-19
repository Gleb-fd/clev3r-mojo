#!/usr/bin/env bash
# Полная верификация проекта: сборка CLI, юнит-тесты Mojo, негативные тесты
# собственных ворот, Python-хуки CLI/LSP/инсталлера, грамматика и
# дифференциальные стадии против C#-эталонов.
#
#   bash tools/verify_all.sh
#
# Изоляция: CLI собирается в УНИКАЛЬНЫЙ scratch (не tools/bp), путь
# экспортируется как BP_BINARY для difftest*.sh и Python-хуков; параллельные
# прогоны verify_all в одном checkout не гоняются за общим бинарём.
# tools/bp этим гейтом не публикуется (финальный общий бинарь собирает
# отдельный executor).
#
# ВАЖНО: в ветке одного worker'а часть тестов создаётся другими worker'ами
# (util_test/compiler3_test/preproc_test/asm_test, tools/tests/test_lsp.py,
# test_cli_flash.py, test_editor_install.py и т.д.). Отсутствие такого теста —
# это FAIL("MISSING"), а не молчаливый skip: зелёный результат полного
# прогона возможен только после интеграции.
#
# Fail-closed: любая стадия проверяет свой код возврата; дифференциальные
# стадии работают на свежем уникальном scratch (см. tools/difftest.sh).
# Mandatory: грамматический CLI (tree-sitter) должен быть установлен; npx-
# загрузка не используется (TREE_SITTER_CLI=tree-sitter), отсутствие CLI —
# явный FAIL.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT" || { echo "FAIL: не удалось перейти в $ROOT"; exit 2; }

FIXTURES="$ROOT/tools/tests/fixtures"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/bp_verify_all.XXXXXX")" || exit 2
trap 'rm -rf "$SCRATCH"' EXIT
BIN_DIR="$SCRATCH/bin"
mkdir -p "$BIN_DIR" "$SCRATCH/selftest" "$SCRATCH/buildcmd"

fail=0

note_fail() {
    echo "FAIL $*"
    fail=1
}

echo "== сборка CLI (уникальный scratch; tools/bp не публикуется) =="
if uv run mojo build src/bp/main.mojo -o "$BIN_DIR/bp" >"$SCRATCH/build.log" 2>&1; then
    export BP_BINARY="$BIN_DIR/bp"
    echo "OK   $BP_BINARY ($(stat -c%s "$BP_BINARY") b)"
else
    echo "FAIL сборка CLI"
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
# Все существующие src/bp/*_test.mojo (а также selftest/flash_test/buildcmd_test
# ниже); отсутствие любого из них — FAIL, а не молчаливый skip.
run_mojo_test lexer_test
run_mojo_test util_test
run_mojo_test compiler3_test
run_mojo_test preproc_test
run_mojo_test asm_test
run_mojo_test json_test
run_mojo_test lsp_test

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

run_python_test() {
    local name="$1"
    local required="${2:-required}"
    local path="tools/tests/$name"
    local log="$SCRATCH/${name%.py}.log"
    if [[ ! -f "$path" ]]; then
        if [[ "$required" == "required" ]]; then
            note_fail "$name: MISSING $path (обязательный hook; до интеграции полный прогон зелёным не считается)"
        else
            echo "SKIP $name: нет $path (условный hook)"
        fi
        return
    fi
    if python3 "$path" >"$log" 2>&1; then
        echo "OK   $name"
    else
        echo "FAIL $name (rc=$?)"
        tail -40 "$log" | sed 's/^/    /'
        fail=1
    fi
}

# test_cli_flash.py печатает фактическую сводку
#   passed=N failed=N skipped=N strict=<0|1>
# и в strict-режиме (BP_CLI_FLASH_STRICT=1) превращает любой mandatory skip в
# rc != 0. Гейт запускает тест именно в strict-режиме и дополнительно сверяет
# фактическую сводку: обязательны failed=0, skipped=0, strict=1 и строка
# CLI_FLASH_TEST OK. Отсутствие сводки (fake success) — FAIL.
run_cli_flash_test() {
    local path="tools/tests/test_cli_flash.py"
    local log="$SCRATCH/test_cli_flash.log"
    if [[ ! -f "$path" ]]; then
        note_fail "test_cli_flash.py: MISSING $path (обязательный hook; до интеграции полный прогон зелёным не считается)"
        return
    fi
    # rc сохраняется явно: после `if ! cmd` значение $? — это статус отрицания,
    # а не код самого теста.
    BP_CLI_FLASH_STRICT=1 python3 "$path" >"$log" 2>&1
    local rc=$?
    if (( rc != 0 )); then
        echo "FAIL test_cli_flash.py (rc=$rc, strict-режим)"
        tail -40 "$log" | sed 's/^/    /'
        fail=1
        return
    fi
    local summary
    summary="$(grep -E '^passed=[0-9]+ failed=[0-9]+ skipped=[0-9]+ strict=[01]$' "$log" | tail -1)"
    if [[ -z "$summary" ]]; then
        echo "FAIL test_cli_flash.py: нет итоговой строки passed/failed/skipped/strict"
        tail -20 "$log" | sed 's/^/    /'
        fail=1
    elif [[ "$summary" != *"failed=0"* || "$summary" != *"skipped=0"* || "$summary" != *"strict=1"* ]]; then
        echo "FAIL test_cli_flash.py: сводка не строгая ($summary); требуются failed=0 skipped=0 strict=1"
        fail=1
    elif ! grep -q '^CLI_FLASH_TEST OK$' "$log"; then
        echo "FAIL test_cli_flash.py: нет CLI_FLASH_TEST OK"
        tail -20 "$log" | sed 's/^/    /'
        fail=1
    else
        echo "OK   test_cli_flash.py ($summary)"
    fi
}

echo "== негативные тесты собственных ворот =="
if [[ -f tools/tests/test_port.py ]]; then
    if python3 tools/tests/test_port.py >"$SCRATCH/test_port.log" 2>&1; then
        echo "OK   tools/tests/test_port.py"
    else
        echo "FAIL tools/tests/test_port.py"
        tail -60 "$SCRATCH/test_port.log" | sed 's/^/    /'
        fail=1
    fi
else
    note_fail "tools/tests/test_port.py: MISSING"
fi

echo "== Python-хуки CLI/LSP/инсталлера =="
run_cli_flash_test
run_python_test test_editor_install.py required
run_python_test test_lsp.py required
# После интеграции t30 (атомарная публикация .rbf) writer-тесты обязательны:
# они проверяют rc!=0 при сбое записи и сохранность старого .rbf.
run_python_test test_asm_write.py required

echo "== грамматика tree-sitter =="
if ! command -v tree-sitter >/dev/null 2>&1; then
    note_fail "tree-sitter CLI MISSING: грамматический гейт обязателен (npx-загрузка не допускается)"
else
    if TREE_SITTER_CLI=tree-sitter bash tools/grammar/check_corpus.sh >"$SCRATCH/grammar_corpus.log" 2>&1; then
        echo "OK   grammar check_corpus: $(grep -E '^files:' "$SCRATCH/grammar_corpus.log" | tail -1)"
    else
        echo "FAIL grammar check_corpus.sh"
        tail -30 "$SCRATCH/grammar_corpus.log" | sed 's/^/    /'
        fail=1
    fi
    if ( cd grammar && tree-sitter test ) >"$SCRATCH/grammar_tree_sitter_test.log" 2>&1; then
        echo "OK   grammar tree-sitter test (cwd grammar)"
    else
        echo "FAIL grammar tree-sitter test"
        tail -30 "$SCRATCH/grammar_tree_sitter_test.log" | sed 's/^/    /'
        fail=1
    fi
fi

echo "== целостность tests/golden (без удалений) =="
# Учёт честный и полный: 40 независимых верхнеуровневых программ + 6 вложенных
# повторных развёрток (два уровня по 3) = 46 каталогов '~*', 46 .lmsb, 46 .rbf.
# Вложенные варианты — настоящие эталоны C#, они не отбрасываются.
GOLDEN_DIRS="$(find tests/golden -type d -name '~*' | wc -l)"
GOLDEN_TOP="$(find tests/golden -type d -name '~*' -not -path 'tests/golden/*/~*/*' | wc -l)"
GOLDEN_NESTED=$(( GOLDEN_DIRS - GOLDEN_TOP ))
GOLDEN_LMSB="$(find tests/golden -name '*.lmsb' | wc -l)"
GOLDEN_RBF="$(find tests/golden -name '*.rbf' | wc -l)"
GOLDEN_EXPECTED=46
GOLDEN_TOP_EXPECTED=40
GOLDEN_NESTED_EXPECTED=6
if (( GOLDEN_DIRS == GOLDEN_EXPECTED && GOLDEN_LMSB == GOLDEN_EXPECTED && GOLDEN_RBF == GOLDEN_EXPECTED \
      && GOLDEN_TOP == GOLDEN_TOP_EXPECTED && GOLDEN_NESTED == GOLDEN_NESTED_EXPECTED )); then
    echo "OK   tests/golden: $GOLDEN_EXPECTED каталогов '~*' ($GOLDEN_TOP верхнеуровневых + $GOLDEN_NESTED вложенных), $GOLDEN_EXPECTED .lmsb, $GOLDEN_EXPECTED .rbf"
else
    note_fail "tests/golden: ожидалось $GOLDEN_EXPECTED каталогов '~*' ($GOLDEN_TOP_EXPECTED+$GOLDEN_NESTED_EXPECTED), $GOLDEN_EXPECTED .lmsb, $GOLDEN_EXPECTED .rbf, получено $GOLDEN_DIRS ($GOLDEN_TOP+$GOLDEN_NESTED)/$GOLDEN_LMSB/$GOLDEN_RBF (не применять make_golden --apply: он теряет вложенные ~~X)"
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
