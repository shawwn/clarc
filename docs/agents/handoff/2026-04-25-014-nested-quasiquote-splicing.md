# Handoff: nested quasiquote unquote inside unquote-splicing — 2026-04-25

## What was accomplished

Fixed a bug in `ac-qq1` (`arc0.lisp`) where an `unquote` nested inside
an `unquote-splicing` form inside a nested quasiquote did not get its
level decremented.

Failing case reported by user:

```
(let a 42
  (test? '(quasiquote ((unquote-splicing (list 42)))) ``(,@(list ,a))))
```

Expected the inner `,a` to evaluate to `42`. Actual result kept `a` as
a literal symbol, producing `(quasiquote ((unquote-splicing (list (unquote a)))))`.

### Root cause

`ac-qq1` had a clause for `(unquote X)` at `level > 1` that wraps and
recurses with `(1- level)`, but no analogous clause for
`(unquote-splicing X)` when it appears as a form (not in splicing
position, i.e. not as the car of a list element). At `level 2`, the
form `(unquote-splicing (list (unquote a)))` fell through to the
default cons handler and was traversed at level 2 unchanged. Then the
inner `(unquote a)` matched the `unquote at level > 1` rule which
recursed into `a` at level 1, where atoms become quoted literals.

### Fix (`arc0.lisp:466-468`)

Added the symmetric clause:

```lisp
;; (unquote-splicing expr) at level > 1 -> wrap, reducing level
((and (> level 1) (arc-sym= (car x) "unquote-splicing"))
 `(cons ',*arc-uqs-sym* (cons ,(ac-qq1 (1- level) (cadr x) env) nil)))
```

Mirrors the existing `unquote` level>1 rule. `*arc-uqs-sym*` was
already defined at `arc0.lisp:24` but had no use site outside the
splicing-position check.

### Why this matters

In conventional Lisp quasiquote semantics, every `,` and `,@` decreases
the nesting level by one for the purposes of when an inner expression
gets evaluated. The previous code only honored that for `,`. With the
fix, ``(,@(list ,a))` correctly counts: outer `` and inner `` give
level 2; the `,@` and `,` give two unquote depths; net zero at `a`, so
`a` evaluates.

## Verification

- `./test.arc`: 128 passed, 0 failed (was 127 passed / 1 failed before
  the fix; the failing test was already in `test.arc:261`).
- All previously passing nested-quasiquote tests still pass — the new
  clause is additive, only firing on `(unquote-splicing X)` at
  `level > 1`, which previously fell through to the default cons
  walker.

## Files changed this session

- `arc0.lisp:466-468` — new `unquote-splicing` level>1 clause in
  `ac-qq1`.

## Current state

- Committed.
- `test.arc` (untracked scratch) still present.
