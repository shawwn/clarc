# Handoff: test.arc adapted from lumen test suite — 2026-04-25

## What was accomplished

Added `test.arc` at the repo root — a runnable arc test script adapted
from `test.l` in https://github.com/sctb/lumen. Executable shebang
`#!./klarc`, ends with `(run-tests)` so `./test.arc` runs the suite.

Three commits in this session:

- `630de64` — Add test.arc adapted from lumen test suite (392 lines).
  Defines the test harness (`test!`, `test?`, `define-test`,
  `run-tests`, `tests*` table) and ports the lumen tests for: `no`,
  `boolean`, `short` (short-circuit eval), `numeric`, `math`,
  `precedence`, `infix`, `string`, `atstrings`, `quote`, `list`,
  `quasiquote`, `quasiexpand`, `calls`, `names`, `=`, `wipe`, `do`.
- `c9ac29b` — `test.arc: define-test if` — adds an `if` define-test
  block exercising both `(macex '(if ...))` shapes and the n-ary
  cond-style `(if a b c d ...)` arc form, including nested forms.
- (uncommitted) — `define-test case` block exercising single- and
  list-keys, default branch, and no-multiple-eval of the test
  expression.

## Key decisions

### Harness

- `test!` returns early via `point return` to abort the current
  `define-test` body on the first failure (matching lumen's
  control-flow model). Failure increments `failed*`, success increments
  `passed*`.
- `equal?` compares via `(tostring (write x))` rather than structural
  equality, so two values are "equal" iff they print identically. This
  sidesteps gaps in arc's `iso`/`is` for nested structures and matches
  lumen's approach.
- `define-test name body...` defines `test-<name>` via `def` and
  registers it in `tests*` keyed by the bare name. `run-tests` iterates
  the table and prints `<name> <msg>` for any string return (failure),
  followed by a "<pass> passed, <fail> failed" line.
- `(= true 't false nil)` is set at the top so the lumen-style `true`
  / `false` literals work throughout. Don't rename — many tests assume
  these globals.

### What was intentionally left commented out

Roughly 60 test cases from the lumen suite are present but commented
with `;`. These exercise features klarc does not yet implement or
where behavior intentionally differs:

- `unset` / `(void)` — no equivalent in current arc runtime.
- `yes` predicate — not defined.
- standalone `%literal` form for embedded host code — not wired up.
- keyword args / colon-suffix table keys (`foo:`, `:foo`) on lists.
- `let-macro` local macro binding.
- a handful of quasiquote-splicing tests that depend on
  `join`/`%array` lowering specific to lumen.
- `(test? 'a "a")` and `(test? "x3" (cat "x" (+ 1 2)))` — symbol/string
  coercion semantics that differ.
- `(test? 1 (apply / ()))` and friends — arc errors on zero-arg
  variadic arithmetic where lumen returns identity elements.

These are kept (commented) so future agents can re-enable them as
features land rather than re-deriving the list. Don't delete them.

### Style notes

- Each `define-test` is a flat sequence of `test?` calls plus
  occasional `let`/`withs` for shared bindings. Keep that shape — the
  `point return` short-circuit means later assertions in the same
  block won't run after a failure, so ordering within a block matters.
- Tests assume `'t` reads as the symbol `t` (not the constant), and
  the suite uses both `t` and `true` interchangeably in places. The
  `(= true 't ...)` line at the top makes this consistent.

## Important context for future sessions

### Current state

- Branch: `main`, up to date with `origin/main` through `c9ac29b`.
- Uncommitted: `test.arc` has the `define-test case` block appended
  (see diff at end of session). Will be committed alongside this
  handoff.
- No other dirty files.

### Running the suite

```
./test.arc
```

prints one line per failing test (`<name> failed: expected ...`) then
a summary. A clean run prints only the summary line.

### Known gaps to be aware of

- Some tests depend on recently-landed work in this day's batch:
  `do` as `%do` (commit `9e9ec8c`, handoff 015), bracket/brace reader
  macros (`5861961`, handoff 013), nested quasiquote-splicing fix
  (`f3614d0`, handoff 014), `|...|` symbols and default atstrings
  (`4de1a09`, handoff 012). If you're bisecting a test failure,
  cross-reference those handoffs first.
- The `quasiquote` and `quasiexpand` blocks are the most likely to
  regress — they exercise edge cases that other tests don't.
- `case` test added this session relies on `case` being a multiple-
  eval-safe macro. If `case` is ever rewritten, keep the
  `(withs (n 0 f (fn () (++ n))) ...)` assertion green.

### Source

Original tests are at https://github.com/sctb/lumen — file `test.l`.
When porting more tests, keep block names identical to lumen's so
diffs against upstream stay readable.
