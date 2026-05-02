---
name: arc-global-ref is now a setf-able place
description: Add `(defun (setf arc-global-ref) ...)` so CL place-modifying macros (`setf`, `incf`, `decf`, `push`, `pop`, ...) work on arc globals when invoked from CL. Previously `(#'sb-ext::incf x)` from CL on an arc global errored with `The function (COMMON-LISP:SETF ARC::ARC-GLOBAL-REF) is undefined`, because `arc-global-ref` was read-only as a place even though `arc-global` already had a `(setf arc-global)` defun. The new setter delegates straight to `(setf arc-global)`. Note: read-modify-write macros like `incf` / `push` still error on an unbound name -- their expansion *reads* through `arc-global-ref` first, and the reader's unbound-var check fires before the write ever happens. The variable has to be bound (`(= x 0)`) before `(#'cl::incf x)` works.
type: project
---

# `(setf arc-global-ref)` — 2026-05-02

When `ac` compiles a free arc reference, it emits `(arc-global-ref 'arc::|x|)`
([arc1.lisp:720](../../../arc1.lisp)). That form is a perfectly fine *read*,
but until this commit it wasn't a *place* — calling any CL place-modifying
macro (`incf`, `setf`, `push`, ...) on an arc global from the CL side errored
out at `setf` expansion:

```
arc> (= x (list 0))
(0)
arc> (#'sb-ext::incf x)
Error: The function (COMMON-LISP:SETF ARC::ARC-GLOBAL-REF) is undefined.
```

The companion accessor `arc-global` had a `(setf arc-global)` since the
beginning ([arc0.lisp:54](../../../arc0.lisp)) — `arc-global-ref` just hadn't
been wired up as a place. Adding the missing setter is three lines:

```lisp
(defun (setf arc-global-ref) (val s)
  (setf (arc-global s) val))
```

It delegates to the canonical setter rather than touching the hash table
directly, so there's exactly one path that writes to `*arc-globals*`.

## Read-modify-write needs a bound name; pure setf doesn't

`arc-global-ref` errors on *read* of an unbound name. The new setter
doesn't add an unbound-on-write check — it just `puthash`es via
`(setf arc-global)`, the same path `(= x ...)` from arc takes. So:

- **`(#'cl::setf x ...)` on an unbound `x` works.** No read happens; the
  setter directly stores.
- **`(#'cl::incf x)` / `(#'cl::push v x)` / `(#'cl::pop x)` on an unbound
  `x` errors `Unbound variable: x`.** These macros expand to a form that
  reads the place before writing it (`(setf x (+ x 1))`,
  `(setf x (cons v x))`, etc.); the read goes through `arc-global-ref`,
  which errors when the entry isn't there. The error fires before the
  setter is reached.

This matches the symmetry between read and write — there's nothing
asymmetric to document, the read just happens to come first in
read-modify-write expansions.

## What works now

```
arc> (= x 41)
41
arc> (#'sb-ext::incf x)         ; x is bound -> read 41, write 42
42
arc> (#'cl::setf z (cl::list 1 2 3))   ; pure setf, z unbound -> creates
(1 2 3)
arc> (#'cl::push 'hi y)         ; y unbound, push reads first -> error
Error: Unbound variable: y
arc> (= y nil)
nil
arc> (#'cl::push 'hi y)         ; y now bound -> works
(hi)
```

## What still doesn't work — `sb-ext:atomic-incf`

`atomic-incf` rejects `(arc-global-ref 'x)` because it accepts only
specific place forms it can compile to a single CAS instruction
(`(car cons)`, `(cdr cons)`, `(svref v i)`, `(symbol-value sym)`,
fixnum-typed struct slots). A hash-table-backed global doesn't fit —
SBCL has no atomic primitive for "CAS the value at hash key K". To
make arc globals atomic-incf-able you'd need either:

- a boxed-fixnum representation (`(cons fixnum nil)`) and atomic-incf
  on `(car ...)`,
- mirroring globals into special variables and atomic-incf on
  `(symbol-value ...)`,
- or per-global locking (correct but lock-based, not lock-free).

None of those are urgent; flagged here so a future agent doesn't
expect `atomic-incf` to start working from this change alone.

## Files touched

| File | What landed |
|---|---|
| [`arc0.lisp`](../../../arc0.lisp) | `(defun (setf arc-global-ref) (val s) (setf (arc-global s) val))` next to the `arc-global-ref` reader |
