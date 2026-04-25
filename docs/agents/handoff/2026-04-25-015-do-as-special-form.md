# Handoff: do macro expands to %do special form — 2026-04-25

## What was accomplished

Replaced the previous `do` macro expansion `((fn () ,@body))` with a
direct `%do` special form recognized by the compiler. The `do` macro
in `arc.arc` now expands to `(%do ,@body)`, and `%do` is handled in
`ac` (`arc0.lisp`) by emitting a CL `progn`.

### Why

Wrapping every `do` body in `((fn () ...))` allocates a closure and
adds a call frame for what is just sequencing. Compiling `(%do ...)`
straight to `(progn ...)` keeps expression order and value semantics
identical while removing the wrapper overhead. It also makes the
expanded code easier to read when macroexpanding.

### Semantics

- `(%do)`        => `(progn)`    => `nil`
- `(%do x)`      => `(progn x)`  => value of `x`
- `(%do x y z)`  => `(progn x y z)` => value of last expr, prior
  expressions evaluated for effect

`ac-body*` already returns `(nil)` on an empty body, so the empty case
yields `(progn nil)` => `nil` — same as the old `((fn ()))` form.

### Files changed

- `arc.arc:31-32` — `do` macro expands to `(%do ,@args)`.
- `arc0.lisp:411-412` — added `%do` clause in `ac` that compiles each
  child with `ac-body*` and wraps in `progn`.

Note: `arc.arc` was also touched separately to rename the rest-arg
parameter in `%brackets` and `%braces` from `body` to `args` (cosmetic
rename only, no behavior change).

## Verification

Manual:

```
(prn (do))           ; => nil
(prn (do 1))         ; => 1
(prn (do (= x 99) x)) ; => 99
(prn (do 'a 'b 'c))  ; => c
```

All match expected values. Did not run the full `test.arc` suite;
worth doing before a release since `do` is used pervasively.

## Current state

- Uncommitted at start of this handoff; will be committed next.
- `test.arc` (untracked scratch) still present.
