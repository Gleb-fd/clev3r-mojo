#!/usr/bin/env bash
# Parse Basic Plus sources with the tree-sitter grammar and report ERROR/MISSING
# nodes per file.
#
# Usage:
#   tools/grammar/check_corpus.sh                 # tests/corpus (+ .bpi/.bpm)
#   tools/grammar/check_corpus.sh FILE [...]      # specific files
#
# Relative FILE arguments are resolved against the caller's working directory,
# so the script may be invoked from anywhere. The parser itself is always run
# with the grammar directory as its working directory (tree-sitter locates the
# generated parser relative to cwd).
#
# Requires a tree-sitter CLI that can load grammar/ (tree-sitter >= 0.25 with
# grammar/src/parser.c). Override the CLI with TREE_SITTER_CLI="...".
# No dependency is downloaded by this script.
#
# Exit status:
#   0  all files parsed, no ERROR/MISSING nodes
#   1  parse errors found (ERROR/MISSING nodes)
#   2  usage error / missing or non-regular input file / grammar not loadable
#   3  parser invocation failed (nonzero exit without a parse tree, empty or
#      invalid output) -- fails closed instead of reporting a false green
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GRAMMAR_DIR="$ROOT/grammar"
CALLER_PWD="$(pwd -P)"

if [ -n "${TREE_SITTER_CLI:-}" ]; then
  read -r -a CLI <<<"$TREE_SITTER_CLI"
else
  CLI=(tree-sitter)
fi

if [ ! -d "$GRAMMAR_DIR" ]; then
  echo "нет каталога грамматики: $GRAMMAR_DIR" >&2
  exit 2
fi

TMPDIR_PARSE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_PARSE"' EXIT

mapfile -t raw_files < <(
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@"
  else
    find "$ROOT/tests/corpus" \( -name '*.bp' -o -name '*.bpi' -o -name '*.bpm' \) -type f | sort
  fi
)

if [ "${#raw_files[@]}" -eq 0 ]; then
  echo "no input files" >&2
  exit 2
fi

files=()
bad_input=0
for f in "${raw_files[@]}"; do
  case "$f" in
    /*) abs="$f" ;;
    *)  abs="$CALLER_PWD/$f" ;;
  esac
  if [ ! -f "$abs" ]; then
    echo "нет файла или это не обычный файл: $f" >&2
    bad_input=1
    continue
  fi
  files+=("$abs")
done
[ "$bad_input" -eq 0 ] || exit 2

total=0; clean=0; total_err=0; total_miss=0; cli_fail=0
printf '%-62s %6s %7s\n' "FILE" "ERROR" "MISSING"
printf '%s\n' "$(printf '%.0s-' {1..78})"

for f in "${files[@]}"; do
  total=$((total + 1))
  out_file="$TMPDIR_PARSE/out"
  err_file="$TMPDIR_PARSE/err"
  ( cd "$GRAMMAR_DIR" && "${CLI[@]}" parse "$f" >"$out_file" 2>"$err_file" )
  rc=$?
  out="$(cat "$out_file")"
  err="$(cat "$err_file")"

  if ! grep -q '(source_file' <<<"$out"; then
    cli_fail=$((cli_fail + 1))
    short="${f#"$ROOT"/}"
    printf '%-62s %6s %7s\n' "$short" "CLI!" "-"
    echo "парсер не вернул дерево разбора (rc=$rc): $short" >&2
    if [ -n "$err" ]; then
      printf '%s\n' "$err" | sed 's/^/  /' >&2
    fi
    continue
  fi

  errs=$(grep -o '(ERROR' <<<"$out" | wc -l)
  miss=$(grep -o '(MISSING' <<<"$out" | wc -l)
  total_err=$((total_err + errs))
  total_miss=$((total_miss + miss))
  short="${f#"$ROOT"/}"

  # tree-sitter exits nonzero when the tree contains errors; a nonzero exit
  # with a tree but no ERROR/MISSING nodes is an unexpected CLI failure.
  if [ "$rc" -ne 0 ] && [ "$errs" -eq 0 ] && [ "$miss" -eq 0 ]; then
    cli_fail=$((cli_fail + 1))
    printf '%-62s %6s %7s\n' "$short" "CLI!" "-"
    echo "парсер завершился с ошибкой без узлов ERROR/MISSING (rc=$rc): $short" >&2
    if [ -n "$err" ]; then
      printf '%s\n' "$err" | sed 's/^/  /' >&2
    fi
    continue
  fi

  if [ "$errs" -eq 0 ] && [ "$miss" -eq 0 ]; then
    clean=$((clean + 1))
    printf '%-62s %6s %7s\n' "$short" "-" "-"
  else
    printf '%-62s %6s %7s\n' "$short" "$errs" "$miss"
  fi
done

printf '%s\n' "$(printf '%.0s-' {1..78})"
printf 'files: %d, clean: %d, ERROR nodes: %d, MISSING nodes: %d, CLI failures: %d\n' \
  "$total" "$clean" "$total_err" "$total_miss" "$cli_fail"

[ "$cli_fail" -eq 0 ] || exit 3
[ "$total_err" -eq 0 ] && [ "$total_miss" -eq 0 ]
