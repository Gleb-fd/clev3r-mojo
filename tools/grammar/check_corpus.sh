#!/usr/bin/env bash
# Parse Basic Plus sources with the tree-sitter grammar and report ERROR/MISSING
# nodes per file.
#
# Usage:
#   tools/grammar/check_corpus.sh                 # tests/corpus (+ .bpi/.bpm)
#   tools/grammar/check_corpus.sh FILE [...]      # specific files
#
# Requires: node/npx (tree-sitter-cli is fetched on first use) and a C compiler
# (cc) to build the parser. Override the CLI with TREE_SITTER_CLI="...".
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GRAMMAR_DIR="$ROOT/grammar"
CLI="${TREE_SITTER_CLI:-npx --yes tree-sitter-cli@0.25.10}"

mapfile -t files < <(
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@"
  else
    find "$ROOT/tests/corpus" \( -name '*.bp' -o -name '*.bpi' -o -name '*.bpm' \) -type f | sort
  fi
)

if [ "${#files[@]}" -eq 0 ]; then
  echo "no input files" >&2
  exit 2
fi

total=0; clean=0; total_err=0; total_miss=0
printf '%-62s %6s %7s\n' "FILE" "ERROR" "MISSING"
printf '%s\n' "$(printf '%.0s-' {1..78})"

for f in "${files[@]}"; do
  total=$((total + 1))
  out="$("$CLI" parse "$f" 2>/dev/null)"
  errs=$(grep -o '(ERROR' <<<"$out" | wc -l)
  miss=$(grep -o '(MISSING' <<<"$out" | wc -l)
  total_err=$((total_err + errs))
  total_miss=$((total_miss + miss))
  short="${f#"$ROOT"/}"
  if [ "$errs" -eq 0 ] && [ "$miss" -eq 0 ]; then
    clean=$((clean + 1))
    printf '%-62s %6s %7s\n' "$short" "-" "-"
  else
    printf '%-62s %6s %7s\n' "$short" "$errs" "$miss"
  fi
done

printf '%s\n' "$(printf '%.0s-' {1..78})"
printf 'files: %d, clean: %d, ERROR nodes: %d, MISSING nodes: %d\n' \
  "$total" "$clean" "$total_err" "$total_miss"

[ "$total_err" -eq 0 ] && [ "$total_miss" -eq 0 ]
