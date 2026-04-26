---
name: xdef gets function syntax so primitives have named backing functions
description: Extend `xdef` to accept `(xdef name (args...) body...)` which defuns `arc--NAME` and binds the global to `#'arc--NAME`, so Arc primitives show up by name in SBCL backtraces. All lambda-form xdefs converted.
type: project
---

# Handoff: xdef function syntax + named primitives — 2026-04-26

## What was accomplished

Before, every Arc primitive defined with `xdef` was an anonymous
`lambda`, so a runtime error inside a primitive surfaced as an
unhelpful `(LAMBDA (X) ...)` frame in the SBCL backtrace:

```
arc> (car 5)
...
4: ((LAMBDA (X)) 5)
```

Now those primitives are real top-level `defun`s with the prefix
`arc--`, so the backtrace identifies them:

```
arc> (car 5)
...
4: (ARC::|arc--CAR| 5)
```

## How

`xdef` now accepts two shapes:

```lisp
(xdef name value)              ; original: bind name to value
(xdef name (args...) body...)  ; new:      defun arc--NAME and bind name to it
```

The new shape expands to `(progn (defun arc--NAME args body...) (xdef name #'arc--NAME))`.
The `arc--`-prefixed symbol is built by the helper `arc-global-name`,
so anything else that needs the same prefix convention can reuse it.
The 2-arg form is unchanged, so all the `(xdef foo #'foo)` and
`(xdef nil nil)` style calls keep working without modification.

## Files changed this session

- `arc0.lisp`:
  - **New helper `arc-global-name`** (just before `xdef`): interns
    `arc--NAME` in the `arc` package from a given symbol.
  - **`xdef` macro** (around line 288): now dispatches on whether
    `body` is empty. The function-shape branch builds the `arc--`
    symbol via `arc-global-name`.
  - **All ~50 lambda-form xdefs converted** to function syntax —
    `car`, `cdr`, `is`, `+`, `>`, `<`, `len`, `ccc`, the I/O
    primitives, threading primitives, `system`, `pipe-from`, `table`,
    `maptable`, `sref`, `protect`, `on-err`, `details`, `rand`,
    `randb`, `dir`, `file-exists`, `dir-exists`, `rmfile`, `mvfile`,
    `bound`, `trunc`, `exact`, `current-process-milliseconds`,
    `current-gc-milliseconds`, `seconds`, `timedate`, `flushout`,
    `ssyntax`, `ssexpand`, `quit`, `memory`, `close`, `force-close`,
    `apply`, `declare`, `eval`, `macex`, `macex1`, `scar`, `scdr`,
    `coerce`, `disp`, `write`, `sread`, `setuid`, `client-ip`,
    `new-thread`, `kill-thread`, `break-thread`, `current-thread`,
    `dead`, `sleep`, `atomic-invoke`.
  - 2-arg `(xdef name #'fn)` and `(xdef name value)` forms left
    untouched (cons, -, *, /, mod, expt, sqrt, annotate, type, rep,
    uniq, instring, inside, msec, sin/cos/tan/asin/acos/atan/log,
    open-socket, socket-accept, err, newstring, sig, nil, t, etc.).

## Key decisions

- **Prefix `arc--` (double dash), not `ar-`.** First pass used `ar-`,
  but that collided with the internal helper `ar-apply` at
  `arc0.lisp:693` — converting `(xdef apply (lambda ...))` to function
  form would have redefined the helper and broken the runtime. Switched
  to `arc--` (double dash) which avoids both the existing `ar-*`
  helpers (`ar-tag`, `ar-type`, `ar-rep`, `ar-apply`, etc.) and the
  existing `arc-*` functions (`arc-eval`, `arc-load`, `arc-coerce`,
  etc.). The double-dash also reads as "Arc primitive" at a glance.

- **Backwards-compatible macro.** Kept the 2-arg form so `(xdef cons
  #'cons)` and `(xdef nil nil)` still work. Anything that already
  references a CL function or a plain value didn't need to change.

- **Closure-capturing xdef inside `let` still works.** The one tricky
  case is `randb`, which is wrapped in `(let ((urandom-stream nil))
  ...)` to share state across calls. The new expansion produces
  `(progn (defun arc--randb () ...) (setf (arc-global 'randb)
  #'arc--randb))` *inside* that `let`, and SBCL closes the defun over
  the lexical `urandom-stream` correctly. Verified by running the test
  suite (which exercises `randb` indirectly).

- **Did not rename or repackage existing `ar-*` helpers.** The
  internal helpers (`ar-funcall0..3`, `ar-apply`, `ar-apply-args`,
  `ar-xcar`, `ar-xcdr`, `ar-is2`, `ar-+2`, `ar-tag`, `ar-type`,
  `ar-rep`, `ar-gensym`, `ar-tagged-p`) are unchanged. They sit in
  `ar-` (single dash), distinct from the new `arc--` namespace.

## Verification

- `./sharc test.arc` → **193 passed, 0 failed**
- `echo "(car 5)" | ./sharc` → backtrace contains
  `(ARC::|arc--CAR| 5)`, confirming the named function appears
- Smoke test of arithmetic, list ops, `is`, `apply`, `type`:
  ```
  (prn (+ 1 2 3))           => 6
  (prn (car '(a b c)))      => a
  (prn (cdr '(a b c)))      => (b c)
  (prn (is 1 1 1))          => T   (still tnil-style — ar-is2 returns t)
  (prn (apply + '(1 2 3)))  => 6
  (prn:type 'foo)           => sym
  ```

## Things to watch

- **Symbol case in backtraces.** SBCL prints the interned symbol with
  its actual case, so the frame reads `arc--CAR` (mixed case from
  `(symbol-name 'car)` returning `"CAR"` — pipes around it because of
  the `--` and case mixing). Cosmetic; the symbol *is* `|arc--CAR|`
  in the `arc` package and is grep-able.

- **New `arc--*` functions are exported nowhere.** They live in the
  `arc` package, internal. Nothing should call them by name from
  outside the runtime — the canonical handle is the value stored in
  `*arc-globals*` under the lowercase string key.

- **Nothing else in the repo defines `xdef`.** `grep -rn xdef` confirms
  every call site is in `arc0.lisp`. If a future file introduces more
  primitives, the same syntax is now available there too.

## Current state

- One change to `arc0.lisp` (255+/266- lines, mostly mechanical
  re-indentation as `(lambda (x) ...)` shrunk to `(x) ...)`).
  Uncommitted on `main` at the start of this handoff. Commit is next.
