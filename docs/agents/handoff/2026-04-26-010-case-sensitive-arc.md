---
name: Case-sensitive Arc via :invert + :arc-user package
description: Mission TKTK landed. Arc reader case-folds via :invert; arc-typed symbols live in a fresh :arc-user package so they can't collide with inherited CL exports. `Foo` and `foo` are now distinct, and symbols print without pipes.
type: project
---

# Handoff: Mission TKTK landed — case-sensitive Arc — 2026-04-26

Follow-up to handoffs 007 (readtable-case analysis) and 009 (CL interop).
This session finishes the work 007 deferred.

## What we wanted

`(def Foo (x) (+ x 1))` and `(def foo (x) (* x 2))` should bind two
different functions. Backtraces and `disp` should print symbols
without `|...|` escapes. Existing arc programs (HTML output, URL
routing, `(coerce 'foo 'string)`) should still see lowercase strings.

## The fix, in three pieces

### 1. Separate `:arc-user` package for arc-typed symbols

`arc0.lisp`:

```lisp
(defpackage :arc
  (:use :common-lisp))

(defpackage :arc-user
  (:use))                ; no inheritance
```

Implementation code stays in `:arc` (with `:use :common-lisp`, so all
the ordinary `defun`/`let`/`cons`/etc. resolve to CL). Arc-typed user
symbols intern in `:arc-user`. They can't collide with CL exports
because nothing is inherited.

This is the alternative to "drop `:use :common-lisp` from `:arc` and
manually `:import-from` everything CL" (Approach A in handoff 007).
Approach B (separate package) is much smaller and equivalent.

### 2. `:invert` readtable, set globally at load time

```lisp
(eval-when (:compile-toplevel :load-toplevel :execute)
  (setf (readtable-case *readtable*) :invert))
```

Right after `(in-package :arc)` in `arc0.lisp`. Affects how *both*
arc0/arc1 source and the SBCL REPL read tokens from there on. All
existing lowercase CL code keeps working because `:invert` upcases
all-lowercase tokens (so `defun` → `DEFUN` → `cl:defun`).

### 3. Arc reader applies `:invert` on intern; vbar opts out

`arc1.lisp` `arc-intern-token` now takes `had-vbar` and applies the
`arc-invert-case` transform when it's nil:

```lisp
(or n (intern (if had-vbar str (arc-invert-case str)) :arc-user))
```

`arc-read-token` already returned `had-vbar` as a second value; the
caller in `arc-read-1` now threads it through.

`arc-invert-case` is the standard :invert transform: all-upper →
all-lower, all-lower → all-upper, mixed unchanged. Defined in
`arc0.lisp`.

## Why arc-typed symbol-names are now uppercase

A user typing `car` produces the symbol `arc-user::CAR`. The reader
inverts on the way in, so the *stored* name is uppercase. The display
path (`arc-disp-val`, `arc-write-val`, `(coerce sym 'string)`)
re-inverts, so the user sees `car` again. Round-trip is clean.

| User types  | symbol-name  | displayed as |
|-------------|--------------|--------------|
| `foo`       | `"FOO"`      | `foo`        |
| `Foo`       | `"Foo"`      | `Foo`        |
| `FOO`       | `"foo"`      | `FOO`        |
| `\|foo\|`   | `"foo"`      | `FOO` *      |

\* `|foo|` opts out of the invert on input, but the display path
still inverts. So `|foo|` looks like `FOO`. Acceptable corner case;
the use of vbar quoting at the user level is rare and almost always
to inject names containing whitespace or punctuation, where the case
behavior doesn't matter.

## Display paths that needed updating

Any code that wrote `(symbol-name x)` directly bypasses the CL printer
and must apply `arc-invert-case` to match user-visible behavior:

- `arc-disp-val` and `arc-write-val` in `arc0.lisp`
- `(coerce sym 'string)` in `arc-coerce`
- Inverse: `(coerce string 'sym)` and `(coerce char 'sym)` apply
  invert before interning, matching what the reader would do.

`*arc-globals*` keys: `arc-sym-key` is now just `symbol-name` (no
case folding). That's required for case-sensitive globals — `(def Foo
...)` and `(def foo ...)` need distinct hash keys, which they get
because their symbol-names ("Foo" vs "FOO") differ.

## Things that needed updating, by category

### `(intern "lowercase" :arc)` / `(intern X (sym-pkg sym))`

These literal interns were assuming `:arc` was the home of arc-typed
symbols. Updated to use `(arc-sym 'name)` (which under :invert reads
as the right-cased name, then re-interns in `:arc-user`):

- `arc-type` in `arc0.lisp` — type tags (`'cons`, `'sym`, `'fn`, ...)
- `arc-coerce` string→sym and char→sym
- `expand-compose` / `expand-and` / `build-sexpr` in `arc1.lisp` —
  the ssyntax expanders. Previously interned in `(sym-pkg sym)`
  which under :invert + :use :common-lisp would have been
  `:common-lisp` (locked package error). Now hardcoded to
  `:arc-user` via `arc-sym`.
- `complement` clause in `ac` — same fix.
- `chars->value` — sub-tokens from a symbol-name that's already
  invert-canonical, so it passes `had-vbar=t` to skip a second
  invert. (Subtle: ssyntax splits a symbol-name into pieces, then
  re-interns each piece. Without `had-vbar=t` the pieces would get
  inverted *again*, breaking lookup.)

### Vbar-quoted globals

`'|that|`, `'|thatexpr|`, `'|script-file*|`, `'|main-file*|`. These
were vbar'd to preserve lowercase under the old `:upcase` reader. Now
that arc reader interns user-typed `that` as `arc-user::THAT`, the
saved global needs to be keyed under `"THAT"` to be findable. Easiest
fix: drop the vbars, let `:invert` do the right thing.

`boot.lisp` updated similarly for `main-file*`.

### One stale test expectation

`test.arc` had `(test? "T" "@t")` — expected "T" because under the
old `:upcase` reader, `(disp 't)` wrote `cl:t`'s symbol-name verbatim
("T"). Under `:invert`, `t` displays as "t" (cl:t's name "T" inverts
to "t"). Updated to `(test? "t" "@t")`.

## Verified

- `./sharc test.arc` → 207 passed, 0 failed.
- `(is 'Foo 'foo)` → nil; `(is 'Foo 'Foo)` → t. Case-sensitive.
- `(prn 'car)` → `car` (no pipes).
- `(prn 'arc--CAR)` → `arc--CAR` (mixed-case, no pipes).
- `(coerce 'Foo 'string)` → `"Foo"`.
- `(coerce "xyz" 'sym)` → arc-user::XYZ; round-trips through string
  to `"xyz"`.
- HTML output via `html.arc`: `(tag (a href "foo") (pr "click"))`
  still produces `<a href="foo">click</a>` (lowercase tag/attr).
- CL interop from handoff 009 still works: `(#'cons 'a 'b)`,
  `#'(defun foo () ...)`, etc. (`cl-quoted` walks via
  `cl-sym` which upcases — under invert + :arc-user that round-trips
  cleanly to inherited CL exports.)

## Notes for whoever picks this up

- **The two `arc-sym=` patterns are still case-insensitive.** ac and
  the runtime check `(arc-sym= sym "fn")` etc. via `string-equal`,
  which means `Fn` and `fn` would both match the special-form
  dispatcher. That's deliberate — special forms are matched by
  name, not by literal symbol — but if pure case-sensitivity
  becomes important even there, switch to `string=`. Most of the
  codebase relies on the loose comparison; tightening it would
  be a separate, larger change.

- **`:invert` is global.** `(setf (readtable-case *readtable*)
  :invert)` mutates the readtable that all CL code shares for the
  process. Side effects:
  - SBCL's own debug output prints `Unhandled simple-error` instead
    of `Unhandled SIMPLE-ERROR`. Cosmetic.
  - Any `read-from-string` call that expects classic upcase reads
    must use `with-standard-io-syntax` or rebind `*readtable*` to
    `(copy-readtable nil)`. `arc-intern-token`'s number-parse
    already does this; check anywhere else if reader bugs surface.

- **The `arc-report-error` local rebind from handoff 007 is now
  redundant** — the global readtable-case is already :invert. Left
  it in place defensively (cheap, and survives if anyone touches
  the global setting).

- **`cl-sym` / `cl-quoted` still work for CL interop.** `#'foo` in
  arc routes through `cl-sym` which upcases the name and interns
  in `:arc` (where CL is inherited). Under :invert, an arc-typed
  symbol like `arc-user::CAR` (name "CAR") goes through cl-sym to
  `(intern "CAR" :arc)` which finds the inherited `cl:car`. Same
  round-trip as before, just via different packages.

- **`(arc-sym 'foo)` under :invert is the canonical way to construct
  an arc-typed symbol from CL source.** `'foo` reads as the
  invert-canonical name (`"FOO"`), and `arc-sym` re-homes that into
  `:arc-user`. Don't write literal `(intern "foo" :arc-user)` from
  CL source unless you really want a literal lowercase name (i.e.
  the equivalent of vbar-quoting from arc).

## Follow-up: `cl-sym` upcase removed, CL keyword support added

After the initial TKTK landing, two interop fixes followed directly:

### `cl-sym` no longer upcases

Old `cl-sym` did `(intern (string-upcase (symbol-name x)) :arc)` —
load-bearing under `:upcase` (where you needed to upcase to find
canonical CL names) but actively harmful under `:invert`: it
collapsed `MyHelper` and `myhelper` to `MYHELPER` when crossing the
bridge, defeating case-preservation. Under `:invert` the arc reader
already produces canonical-cased names, so `cl-sym` just preserves
`(symbol-name x)` verbatim. `cl-sym-key` is removed.

### CL keyword args via leading-colon

`arc-intern-token` now recognizes a leading `:` (when not vbar-quoted)
and interns in the `:keyword` package. So `(#'open path :direction
:output :if-exists :supersede)` and CLOS slot specs like
`(x :initarg :x :accessor point-x)` work directly.

Three small supporting changes:
- `literal-p` includes `keywordp` (so keywords self-evaluate during
  `ac` compilation, instead of becoming undefined varrefs).
- `cl-quoted` and `ac-quoted` short-circuit on `keywordp` so the
  keyword passes through unchanged instead of being re-interned in
  `:arc` or `:arc-user`.
- The arc ssyntax for compose (`foo:bar`) is unaffected because
  arc-intern-token's keyword-detect requires `(> (length str) 1)`
  and only fires for *leading* colon. `foo:bar` continues to expand
  through `ssyntax-p`.

### Arc functions inside CL forms

`cl-quoted` redirects call forms whose head names an arc-only function
through `ar-apply` at runtime. So arc's `prn`, `pr`, `disp`, etc. work
inside CL macro bodies:

```
(prn (#'loop for i below 10 collect (prn (+ i i))))
;; outer prn arc-evaluated; loop body runs CL-side, but the inner
;; (prn (+ i i)) compiles to (ar-apply (arc-global-ref 'arc-user::prn)
;; (list (cl:+ arc::i arc::i))) -- arc's prn called with the CL-loop
;; binding's value.
```

The decision rule in `cl-quoted`: a call head `(car x)` is redirected
through `ar-apply` iff `arc-bound-fn-p` is true (arc global is a plain
function) AND `cl-symbol-known-p` is false (no CL-exported symbol with
that name). The CL-symbol check uses `find-symbol ... :common-lisp`
with `:external` status, which catches not just fboundp/macro/special
forms but also declaration markers like `declare` and `ignore` -- they
need to stay as CL syntax inside `(handler-case ... (declare (ignore
c)) ...)`. CL-exported names (`+`, `cons`, `format`) continue to route
through CL directly via `cl-sym`.

This means arc compilation keeps happening inside CL bodies for arc
names, while CL stays CL for CL names -- there's no "I detected a CL
macro so I disabled arc". Variable references still follow CL lexical
scope (loop-bound `i` is arc::I, not arc-user::i) so arc functions
called inside the body receive the CL-bound values via `cl:+` etc.,
not via arc-global lookup.

### Pattern A: `(#'fn args...)` works for any CL callable

`ac` detects whether the canonical CL symbol is a function, macro, or
special operator. For functions, args are arc-evaluated as before.
For macros and special operators, args are `cl-quoted` instead, so
binding forms like `(s "/tmp/x")` in `with-open-file` survive intact:

```
(#'with-open-file (s "/tmp/x") (#'read-line s))    ; => first line
(#'let ((a 10) (b 20)) (+ a b))                    ; => 30
(#'loop for i below 5 collect (* i i))             ; => (0 1 4 9 16)
(#'multiple-value-list (#'truncate 17 5))          ; => (3 2)
```

The detection uses `(macro-function cl-fn)` and `(special-operator-p
cl-fn)` on the result of `(cl-sym head)`.

`cl-quoted` was also taught to recognize `((function fn) args)` — a
Pattern A call embedded inside a CL form. It unwraps to a direct CL
call. Without this, `(#'with-open-file ... (#'read-line s))` would
expand the inner `#'read-line` to `((function read-line) s)` which is
illegal CL syntax.

### Pattern B: `#'(form ...)` for one-shot CL blocks

Still useful when you want to evaluate a single CL expression with no
callable head (e.g., dropping into CL for a series of side-effecting
statements). Equivalent to `(#'progn form ...)` semantically.

### Bridging arc data into a CL macro body

Macro detection in Pattern A means args are cl-quoted, so arc
variables don't bridge in directly — `(let path "/tmp/x"
(#'with-open-file (s path) ...))` won't see `path` because cl-quoted
re-interns it CL-side. Two ways across:

1. Wrap the macro in a CL function: `#'(defun read-first-line (path)
   (with-open-file (s path) (read-line s)))`, then `(#'read-first-line
   arc-path)`. The function takes arc-evaluated args; the macro lives
   inside.
2. Use `#''name` for literal CL-side symbols (e.g., a class name):
   `(#'make-instance #''Point :x 3 :y 4)`.

## Files touched

- `arc0.lisp` — `:arc-user` package, readtable :invert, `arc-invert-case`,
  `arc-sym`/`arc-sym-key` rewrites, `cl-sym` simplified (no upcase),
  `arc-type` rewrite, `arc-coerce` sym↔string updates, `arc-disp-val`/
  `arc-write-val` symbol path updates, `'|that|`/`'|thatexpr|` →
  `'that`/`'thatexpr`.
- `arc1.lisp` — `arc-intern-token` takes `had-vbar` and handles
  leading-colon-as-keyword, callers thread `had-vbar`, `chars->value`
  passes `had-vbar=t`, `expand-compose` / `expand-and` / `build-sexpr`
  / `complement` clause use `arc-sym` instead of `(intern X (sym-pkg
  sym))`, `'|script-file*|` → `'script-file*`, `literal-p` includes
  keywords, `cl-quoted` / `ac-quoted` preserve keywords.
- `boot.lisp` — `'arc::|main-file*|` → `'arc-user::main-file*`.
- `test.arc` — atstrings test `(test? "T" "@t")` → `(test? "t" "@t")`.

## Current state

- Working tree: changes above. Tests green.
- `MEMORY.md` cleared of the TKTK pointer (mission accomplished).
- Commit pending after this handoff.
