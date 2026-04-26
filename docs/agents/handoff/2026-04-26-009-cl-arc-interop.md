---
name: Sharp-quote and Common Lisp interop
description: Gave `(function ...)` (read as `#'`) real semantics in `ac` — Arc code can now call any CL function directly via `#'fn`, including defining CL functions inline. Also adds `cl-sym`/`ac-quoted` symbol-translation helpers.
type: project
---

# Handoff: function-form and CL interop — 2026-04-26

Follow-up to handoff `008` (which only added the *reader syntax* for
`#'`, `` #` ``, `#,`, `#,@`). This session wires real meaning into
`(function ...)` so `#'fn` actually does something — and the something
is direct interop with the host Common Lisp.

## What landed

### `arc0.lisp` — symbol translation helpers

A new section "Translation from Arc names to CL names and vice-versa"
holds two pairs of functions:

```lisp
(defun cl-sym-key (s) (string-upcase   (symbol-name s)))  ; uppercase
(defun arc-sym-key (s) (string-downcase (symbol-name s))) ; lowercase

(defun cl-sym  (name) (intern (if (symbolp name) (cl-sym-key  name) name) :arc))
(defun arc-sym (name) (intern (if (symbolp name) (arc-sym-key name) name) :arc))
```

`arc-sym` already existed; `cl-sym` is new. Both intern in `:arc`,
but `cl-sym` upcases (matching CL's canonical form for `defun`,
`cons`, `+`, etc.) while `arc-sym` downcases (matching Arc-typed
identifiers). The split is what makes the interop below work.

### `arc1.lisp` — `ac` special-cases `function`

Two new clauses in `ac` (between `ssyntax-p` and `quote`):

```lisp
((arc-sym= (arc-car? s)  "function") (cl-quoted (cadr s)))
((arc-sym= (arc-caar? s) "function") (mapcar (lambda (x) (ac x env)) s))
```

Plus two helpers:

```lisp
(defun cl-quoted (x)         ; recursively upcases symbols (→ CL names)
  (cond ((consp x)   (arc-imap #'cl-quoted x))
        ((symbolp x) (cl-sym x))
        (t x)))

(defun ac-quoted (x)         ; recursively downcases symbols (→ arc names)
  (cond ((consp x)   (arc-imap #'ac-quoted x))
        ((symbolp x) (arc-sym x))
        (t x)))
```

And the existing `quote` clause was rewritten to route through
`ac-quoted`:

```diff
- ((arc-sym= (arc-car? s) "quote") `',(cadr s))
+ ((arc-sym= (arc-car? s) "quote") (list 'quote (ac-quoted (cadr s))))
```

So `'foo` produces a normalized lowercase Arc symbol regardless of
how the source was cased.

Other small things in the same diff:
- `ac` now takes `env` as `&optional` (defaults to `nil`) — convenient
  for calling `(ac form)` from the REPL or interop code.
- The atstring helpers (`atpos`, `unescape-ats`, `codestring`) moved
  up next to `ac-string` where they're used. Pure code motion.

## The interop, plainly

Once `(function fn)` is a special form, `#'fn` becomes a one-character
escape hatch into Common Lisp. Two patterns matter:

### 1. Calling a CL function directly

When `#'fn` appears in head position, the second `ac` clause kicks in:
`(mapcar #'ac s)` walks the call form, the head compiles to the bare
upcased symbol `arc::FN`, and the result is a *direct CL call* — no
`arc-funcall` indirection.

```
arc> (#'+ 1 2 3)            ; compiles to (+ 1 2 3)
6
arc> (#'cons 'a 'b)
(a . b)
```

This works for anything visible in the `:arc` package — both inherited
CL symbols (`+`, `cons`, `defun`, `format`, `mapcar`, ...) and
sharc-internal Lisp functions (`ac`, `arc-eval`, `arc-apply`, ...).

```
arc> (#'ac '(def foo (x) (+ x 1)))   ; calls the AC compiler from arc
```

### 2. Lowercase vs uppercase symbols: `'x` vs `#''x`

Arc and CL use different symbol-name conventions in this codebase
(see handoff `007` for the full rationale). Arc-typed identifiers
intern as lowercase strings; CL-typed identifiers intern as uppercase.
The two helpers (`ac-quoted`, `cl-quoted`) bridge them:

```
arc> 'a              ; arc-quoted → arc::a (lowercase)
a
arc> #''a            ; cl-quoted → arc::A (uppercase)
A
arc> (#'cons 'a 'b)         ; both lowercase
(a . b)
arc> (#'cons #''a 'b)       ; mixed
(A . b)
arc> (#'cons #''a #''b)     ; both uppercase
(A . B)
```

The trick: `#''a` reads as `(function (quote a))`, which `cl-quoted`
walks and upcases into `(QUOTE A)`. Treated as CL code, that's just
`'A` — the uppercase symbol.

### 3. Defining native CL functions from Arc

Because `cl-quoted` recursively upcases an entire form, `#'(defun ...)`
hands a fully-upcased CL form to the host evaluator:

```
arc> #'(defun foo (x &rest args) (arc-apply #'+ x args))
FOO
arc> (#'foo 1 2 3)
6
```

`#'(defun foo ...)` reads as `(function (defun foo (x &rest args) ...))`.
`cl-quoted` upcases everything — `defun`, `&rest`, `arc-apply`, etc.
— so the result is a real CL `DEFUN` form that gets evaluated like
any other compiled output of `ac`. After that, `foo` is a regular
CL function, and `(#'foo ...)` calls it directly.

Inside such a function you can mix freely: `arc-apply` to call back
into Arc semantics, `#'+` for direct CL calls, Arc literals, the lot.

### 4. Getting a CL function *value* with `#'#'`

A bare `#'fn` in *argument* position compiles to the symbol
`arc::FN` — that's a variable reference, not a function reference.
To get the actual function object (what CL's `#'fn` evaluates to),
sharp-quote it twice:

```
arc> (apply #'#'+ 1 2 3 '(4))
10
```

Why it works: `#'#'+` reads as `(function (function +))`. The outer
`(function ...)` clause runs `cl-quoted` over `(function +)`, which
just upcases the inner symbols — yielding `(FUNCTION +)`. That gets
spliced into the AC output as CL code, where `(FUNCTION +)` is the
host's own `#'+` and evaluates to the function object for `+`.

So the rule of thumb:

| Form     | Compiles to                | Use when                          |
| -------- | -------------------------- | --------------------------------- |
| `#'fn`   | `arc::FN` (symbol/varref)  | head position: `(#'fn ...)`       |
| `#'#'fn` | `(function fn)` (funcobj)  | argument position: passing it on  |

## Why two helpers (cl-quoted vs ac-quoted)?

They go in opposite directions:

| Helper       | Symbol case | Used for                                |
| ------------ | ----------- | --------------------------------------- |
| `cl-quoted`  | uppercase   | `(function ...)` — output is CL code    |
| `ac-quoted`  | lowercase   | `(quote ...)` — output is an Arc datum  |

Arc-side: `'foo` should always give you the same lowercase
`arc::foo`, even if the reader saw `Foo` or `FOO`. CL-side: `#'foo`
should give you the canonical uppercase `arc::FOO` that CL uses for
function names.

Mission TKTK (case-sensitive Arc, see handoff `007`) will make these
distinctions load-bearing once the arc reader actually case-folds
under `:invert`. For now they already work — the helpers normalize
on the way through `ac`, regardless of what the reader did.

## Verified

```
arc> (#'+ 1 2 3)
6
arc> (#'cons 'a 'b)
(a . b)
arc> (#'cons #''a #''b)
(A . B)
arc> (apply #'#'+ 1 2 3 '(4))
10
arc> #'(defun foo (x &rest args) (arc-apply #'+ x args))
FOO
arc> (#'foo 1 2 3)
6
arc> (#'ac '(def bar (n) (* n 2)))
...
```

Test suite: should still be `193 passed, 0 failed` — interop is
strictly additive, doesn't touch any path the existing tests
exercise. (Run `./sharc test.arc` to confirm before committing.)

## Notes for whoever picks this up

- **Argument-position `#'fn` is a varref, not a funcref.** A single
  `#'fn` in non-head position compiles to the bare symbol `arc::FN`
  — a *variable* reference in CL, not a function reference. To pass
  a CL function as a value, double up: `#'#'fn` (see section 4
  above). E.g. `(apply #'#'+ 1 2 3 '(4))` works; `(apply #'+ ...)`
  does not.

- **`#'` doesn't go through `arc-funcall`.** It's a direct call.
  That means it won't auto-coerce non-function callables (tables,
  strings, lists used as indexers — all the things `arc-funcall`
  handles). If you want Arc semantics, don't use `#'`.

- **`cl-quoted` walks structure with `arc-imap`**, which preserves
  improper-list tails. Dotted pairs survive the round-trip
  unchanged.

- **`#'(defun ...)` is evaluated like any compiled `ac` output** —
  there's no special `eval-when`-style wrapper. If you sharp-quote
  a form with side effects, those happen at the same time the
  surrounding Arc form runs, not at read or load time.

- **The reader change in handoff `008` is what makes `#'` even
  parseable.** This handoff supplies the semantics; `008` supplies
  the syntax. Treat them as a pair.

## Current state

- Working tree: ~30 lines added in `arc0.lisp` (helpers + section
  rearrangement), ~30 lines added in `arc1.lisp` (`ac` clauses,
  helpers, section rearrangement). No tests added — interop is
  exercised manually for now.
- `MEMORY.md` still references Mission TKTK; this work doesn't
  unblock it but is independent.
- Commit pending after this handoff.
