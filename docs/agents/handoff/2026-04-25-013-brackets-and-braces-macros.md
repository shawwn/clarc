# Handoff: `[...]` and `{...}` reader → `%brackets` / `%braces` macros — 2026-04-25

## What was accomplished

### Reader rewrite

`[…]` no longer expands to `(fn (_) …)` directly in the reader. It now
reads as `(%brackets …)`, and `{…}` reads as `(%braces …)`. The fn-shape
is produced by an Arc-level macro instead of being baked into the
tokenizer. This puts the meaning of bracket/brace forms in arc.arc where
it can be redefined.

`arc0.lisp` changes:
- `arc-delimiter-p` (arc0.lisp:37) — added `{` and `}` so they break
  tokens cleanly.
- `arc-read-1` (arc0.lisp:175-182) — `[` reads its body via
  `arc-read-list … #\]` and emits `(cons '%brackets body)`; `{` does the
  same with `#\}` and `%braces`.
- `arc-read-1` (arc0.lisp:222-223) — added "Unexpected }" error to mirror
  the existing `]` guard.

### `%brackets` macro (arc.arc:25-26)

```
(assign %brackets (annotate 'mac
                    (fn body `(fn (_) ,body))))
```

Defined via raw `assign`+`annotate` so it works before `mac` itself is
bootstrapped at line 86. With `body` as a rest param, `[+ _ 1]` reads as
`(%brackets + _ 1)`, body binds to `(+ _ 1)`, and the expansion is
`(fn (_) (+ _ 1))` — matching the previous reader-baked behavior
exactly.

### `%braces` macro (arc.arc:28-29) — added by user

```
(assign %braces (annotate 'mac
                  (fn body `(do ,@body))))
```

Composes with atstrings: `"@{x}bar"` reads as
`(string "" (%braces x) "bar")` = `(string "" (do x) "bar")` →
`"foobar"`. Lets atstrings interpolate arbitrary expressions inside
`@{…}` while a bare `@x` still works for single-symbol cases.

## Key decisions

- **Macro placement at the very top of arc.arc, before `do`.** Using
  `(assign %brackets (annotate 'mac …))` directly means the macro is
  available before `mac` itself is defined, so any `[…]` form anywhere in
  arc.arc / libs.arc / news.arc works. Lots of files use `[…]` (first
  hit is arc.arc:227).
- **`fn body` rest binding, not `fn (body)`.** With a single-symbol
  parameter, `body` collects all bracket-body forms as a list. The old
  reader wrapped the read list as a single body expression of the
  resulting `fn`; quasiquoting `,body` into the fn body slot reproduces
  that exactly. Don't change to `,@body` — that would splice and
  multiple-element bodies would re-shape.
- **`%braces` → `do`, not `fn`.** Braces aren't a function shorthand; in
  the user's intended use (`@{expr}` in atstrings) they need to evaluate
  to a value in place. `do` is the minimum wrapper that runs the forms
  and returns the last one.
- **Symbol names use `%` prefix.** `%` is not an ssyntax char (`:`, `~`,
  `&`, `.`, `!`), so `%brackets`/`%braces` interns as a plain symbol with
  no compose/get expansion interference.

## Verification

- `test.arc`: 94 passed, 0 failed (was 93; the user added a brace test).
- `[+ _ 1]`, `(map [* _ 2] '(1 2 3 4))`, `[list _ _]` all behave as
  before.
- `(let x 'foo "@{x}bar")` → `"foobar"`;
  `(let x 1 "result: @{(+ x 10)}!")` → `"result: 11!"`.

## Files changed this session

- `arc0.lisp:37` — `{` `}` added to delimiters.
- `arc0.lisp:175-182` — `[` and `{` dispatch in `arc-read-1`.
- `arc0.lisp:222-223` — unexpected-`}` guard.
- `arc.arc:25-29` — `%brackets` and `%braces` macros at the top.

## Current state

- Uncommitted on `main`.
- `test.arc` (untracked scratch) still present.
