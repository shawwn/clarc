# Handoff: ar-is2 numeric equality — 2026-04-25

## What was accomplished

### Make `ar-is2` compare numbers by value, not `eql`

`ar-is2` in `arc0.lisp` is the kernel of Arc's `is` predicate. It previously treated numbers via the top-level `eql` clause, which returns true for same-typed equal numbers but fails for cross-type numeric comparisons (e.g. an integer vs. the same value as a float, or bignum/fixnum boundaries on some implementations). Arc's `is` is expected to compare numbers by mathematical value, matching the behaviour of MzScheme's `equal?`/`=` in the original Arc runtime.

A new clause was added before the string and null clauses:

```lisp
(defun ar-is2 (a b)
  (tnil (or (eql a b)
            (and (numberp a) (numberp b) (= a b))
            (and (stringp a) (stringp b) (string= a b))
            (and (null a) (null b)))))
```

`=` in Common Lisp coerces numeric arguments to a common type before comparing, so `(ar-is2 1 1.0)` now returns `t` as expected.

## Key decisions

- **Use `=` rather than `equal`**: `equal` on numbers in CL is essentially `eql`, so it would not have fixed the cross-type case. `=` is the right primitive for "numerically equal".
- **Guard with `numberp` on both sides**: `=` signals an error on non-numeric arguments, so the `and` short-circuits before we reach it. The `eql` clause still handles the common same-type fast path.
- **Clause ordering**: numeric check placed after `eql` (fast path for identical objects / same-type small numbers) but before string/null clauses, since numeric comparisons are cheaper than `string=` and more commonly hit.

## Files changed this session

- `arc0.lisp` line 686 — added `(and (numberp a) (numberp b) (= a b))` clause inside `ar-is2`.

## Current state

Committed on `main` with message "Make ar-is2 compare numbers by value, not eql". `test.arc` remains an untracked file from earlier sessions; not touched.
