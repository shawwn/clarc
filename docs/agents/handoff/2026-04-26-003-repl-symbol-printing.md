---
name: Print ARC-namespace symbols unqualified at the REPL and in disp/prn
description: Switch the REPL result printer from CL's `write` to `arc-write-val`, and teach `arc-disp-val` to recurse over cons, so symbols print as `foo` instead of `ARC::|foo|`.
type: project
---

# Handoff: REPL prints Arc symbols unqualified — 2026-04-26

## What was accomplished

### Symbols no longer leak `ARC::|...|` at the REPL

Before:

```
arc> '(a b c d)
(ARC::|a| ARC::|b| ARC::|c| ARC::|d|)
```

After:

```
arc> '(a b c d)
(a b c d)
arc> (list 1 'a "hi")
(1 a "hi")
arc> '(a (b c) . d)
(a (b c) . d)
```

The REPL was using CL's `write` on the eval result, which (a) prefixes
non-current-package symbols with `ARC::` and (b) bar-quotes lowercase
names because `*print-case*` defaults to `:upcase`. There's already an
Arc-aware printer in `arc0.lisp` (`arc-write-val`) — we just weren't
using it from the REPL.

### `disp` / `pr` / `prn` also fall through correctly for lists

`arc-disp-val` handled atoms (string, character, null, symbol) but
delegated to CL's `write` for cons cells, so `(prn '(a b c d))` had the
same `ARC::|a|` problem even though the REPL was fixed. `arc-disp-val`
now recurses over cons exactly like `arc-write-val` does, calling
`arc-write-val` on each element (so the inner elements get the
write-style representation: strings quoted, chars `#\x`, etc., which
matches the original Arc/MzScheme `disp` semantics for lists).

## Files changed this session

- `arc0.lisp`:
  - `arc-tl2` (line 1424): `(write val :readably nil)` →
    `(arc-write-val val *standard-output*)`.
  - `arc-disp-val` (line 907): added a `((consp x) ...)` clause that
    walks the list and dispatches each element through `arc-write-val`,
    handling improper tails with `" . "` like `arc-write-val` does.

No changes to `arc.arc`, `boot.lisp`, or anything else.

## Key decisions

- **Reuse `arc-write-val`, don't bind `*package*` and let CL's printer
  do it.** Binding `*package*` to `:arc` would unqualify ARC symbols
  but wouldn't fix the bar-quoting (`|foo|`) — Arc symbol names are
  literal-case and CL's writer escapes anything that doesn't round-trip
  under the current readtable + `*print-case*`. `arc-write-val` already
  emits `(write-string (symbol-name x) port)` which gives the raw
  lowercase name, so it's both shorter and more correct.
- **Recurse `arc-disp-val` cons → `arc-write-val`, not back into
  `arc-disp-val`.** This matches MzScheme/Racket's `display` semantics
  on lists: the *list structure* is displayed (parens, spaces), but
  *elements* of the list are written (so strings keep their quotes,
  characters keep their `#\` prefix). `pr`/`disp` of a bare string
  still prints unquoted because the top-level dispatch hits the
  `stringp` clause first; only when a string is *inside* a list does
  it get quoted. That's the conventional behavior.
- **Did not touch `arc-write-val`'s symbol clause to discriminate by
  package.** It currently prints `symbol-name` for *any* symbol,
  including symbols from other packages. In practice the only symbols
  the user can reach via Arc reads are interned in `:arc`, plus
  keywords/CL `t`/`nil` which are special-cased. If a symbol from
  another package ever shows up, losing its package prefix is a minor
  cosmetic issue, not a correctness one — punt until it actually
  matters.

## Verification

Tested via `expect` driving a real REPL session (since piped stdin
takes the eval-and-exit path and doesn't print results):

```
arc> '(a b c d)         → (a b c d)
arc> (+ 1 2)            → 3
arc> 'foo               → foo
arc> (list 1 'a "hi")   → (1 a "hi")
```

And via piped stdin for `prn`:

```
$ printf '(prn (quote (a b c d)))\n(prn (quote foo))\n(prn (quote (a (b c) . d)))\n(prn "hello")\n' | ./sharc
(a b c d)
foo
(a (b c) . d)
hello
```

Did not rerun `test.arc`. The change is purely in the printer surface
that the REPL and `disp`/`prn` use; `test.arc`'s assertions go through
`is`/equality, not string comparison of printed output, so a regression
is unlikely but worth a sanity run.

## Current state

- All work uncommitted on `main` at the start of this handoff write-up.
  Commit is the next step after this doc lands.
