#!/usr/bin/env bash
# Полная верификация проекта: юнит-тесты Mojo + дифференциальные стадии против C#-эталонов.
set -uo pipefail
cd /home/ssssq/Projects/clev3r_mojo || exit 1

fail=0

echo "== сборка CLI =="
if uv run mojo build src/bp/main.mojo -o tools/bp >/dev/null 2>&1; then
    echo "OK   tools/bp"
else
    echo "FAIL сборка"; exit 1
fi

echo "== юнит-тесты =="
uv run mojo run src/bp/lexer_test.mojo >/dev/null 2>&1 && echo "OK   lexer_test" || { echo "FAIL lexer_test"; fail=1; }
uv run mojo run src/bp/selftest.mojo  >/dev/null 2>&1 && echo "OK   selftest"  || { echo "FAIL selftest";  fail=1; }

echo "== дифференциальные стадии против C#-оракула =="
bash tools/difftest.sh expand || fail=1
bash tools/difftest.sh lmsb   || fail=1
bash tools/difftest.sh rbf    || fail=1

exit $fail