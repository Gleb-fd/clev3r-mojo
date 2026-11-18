# Fixed expand/preproc regression fixtures (t3)

Small inputs for the confirmed defects from t10 `VERDICTS.md`
(G/Additional-1, duplicate zero-arg module `1809`, bracket mismatch `1001/1002`,
unresolved call/sub/thread `1806/1606/1414`, empty expansion).

Each directory is self-contained: copy it to a temp dir and run from inside it
(the fixtures are intentionally NOT wired into `tests/corpus`/`tests/golden`, and
must not be run with a hardcoded `ROOT`):

| dir | expectation |
|---|---|
| `bare/` | `bp compile Main.bp` (bare name) resolves sibling `Module1.bpm`; same result as `./Main.bp` and absolute path |
| `dup_zero/` | `.bpm` with two `Function A()` -> `1809` on the second declaration |
| `overloads/` | `A()`, `A(1)`, `A(1,2)` (distinct arities) is valid, no `1809` |
| `brackets/` | `bad_main.bp` -> `1001` from `Bad.bpm`; `inc_main.bp` -> `1001` from `Inc.bpi` |
| `unresolved/` | `missing_func.bp` -> `1806`, `missing_sub.bp` -> `1606`, `thread_*.bp` -> `1606`/`1414`; `valid.bp` stays clean |
| `empty/` | `empty.bp` expands to a zero-byte `~empty/~empty.bp` |

The authoritative automated checks are in `src/bp/preproc_test.mojo`
(`uv run mojo run src/bp/preproc_test.mojo`), which builds equivalent inputs in
private temp dirs.
