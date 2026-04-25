# Handoff: |...| symbol literals and atstrings default — 2026-04-25

## What was accomplished

### `|...|` verbatim symbol syntax in the Arc reader

The Arc reader did not recognize `|...|`, so `'|(|` (a symbol whose name is
the literal character `(`) failed with `Unexpected EOF in list` — the `|`
fell through to the generic token path, then the embedded `(` opened a
real list.

Two changes in `arc0.lisp`:

1. New `arc-read-vbar-segment` (arc0.lisp:39) reads characters verbatim
   up to a closing `|`, with `\` escaping the next char. Errors on EOF
   inside `|...|` or after a trailing `\`.
2. `arc-read-token` (arc0.lisp:54) now dispatches to that helper when it
   peeks a `|`, then resumes normal token reading. This means segments
   compose mid-token: `foo|bar baz|qux` reads as a single symbol named
   `foobar bazqux`, matching the MzScheme/Racket behavior Arc inherits.

`arc-read-1` did not need a top-level `|` clause — it falls through to
the symbol/number path, which now handles vbar segments correctly.

Verified: `(is '|(| '|(|)` → `t`; `(tostring:write '|(|)` → `"("`.

### `atstrings` defaults to `t`

`*arc-atstrings*` (arc0.lisp:269) flipped from `nil` to `t` so `"x is @x"`
interpolation works without an explicit `(declare 'atstrings t)` at the
top of every file. Existing `(declare 'atstrings ...)` calls still work
both directions.

## Key decisions

- **Vbar in `arc-read-token`, not `arc-read-1`.** Putting the dispatch in
  the token reader is what enables mid-symbol segments. A top-level-only
  handler would only support `|...|` standalone, missing the
  `foo|bar|baz` case.
- **`arc-intern-token` left alone.** It still maps `""`, `"nil"`, `"t"`
  to their special values, so `||` reads as `nil` and `|nil|`/`|t|` are
  not distinguished from bare `nil`/`t`. CL distinguishes them; Arc
  doesn't have a use for that distinction, and matching CL would
  silently break the empty-token guard `arc-read-token` already relies
  on.
- **Atstrings default flip is a behavior change.** Files written
  assuming `@` is just a character in strings will now interpolate. None
  of the bundled `.arc` files in this repo break (test.arc still 93
  passing); downstream code may need `(declare 'atstrings nil)`.

## Files changed this session

- `arc0.lisp:39-64` — `arc-read-vbar-segment` + updated `arc-read-token`.
- `arc0.lisp:269` — `*arc-atstrings*` initial value `nil` → `t`.

## Current state

- Committed on `main`.
- `test.arc` (untracked scratch) still present; not part of this commit.
