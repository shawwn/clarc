---
name: Table destructuring with keyword syntax
description: Adds keyword-based table destructuring to fn/def. `(:a :b :c)` at a positional slot binds locals from a table. Supports `(o :k default)` for lazy defaults, remapping (`foo: x`), and nested sub-patterns.
type: project
---

# Handoff: table destructuring (2026-05-12)

## What landed

`fn` / `def` now accept a table-destructuring pattern at any
positional slot. The pattern is a list whose first form is a CL
keyword (or `(o :keyword ...)` opt-form).

```arc
(def foo ((:a :b :c))
  (list a b c))

> (foo (obj a 1 b 2 c 3))
(1 2 3)
```

Supported forms inside the pattern:

- `:k` -- bind local `k` to `(tbl 'k)`.
- `(o :k default)` -- bind `k` to `(tbl 'k)`, lazily falling back to
  `default` when the key is absent.
- `:k var` -- remap: bind `var` (a symbol) to `(tbl 'k)`.
- `:k sub-pat` -- nested: destructure `(tbl 'k)` with `sub-pat`
  (recursing through `ac-complex-args` / `ac-table-args`, so the
  sub-pat can be a list pattern or another table pattern).

Both `:foo` and `foo:` read as the same keyword (the existing
keyword reader from `b3f0153`), so either spelling works on the key
side.

## Implementation

All in `arc1.lisp:657-803`.

- `ac-table-pattern-p` -- detects `(:k ...)` or `((o :k ...) ...)`.
- `ac-table-args` / `ac-table-args-loop` -- walks the pattern,
  emitting `let*` bindings.
- `ac-table-slot` -- one slot's bindings; dispatches sub-patterns
  back through either `ac-table-args` (nested table) or
  `ac-complex-args` (nested list).
- `ac-table-lookup` -- the actual fetch. With no default it emits
  `(arc-call1 tbl 'k)`. With a default it emits a lazy
  `(let ((v (gethash 'k tbl :arc/missing))) (if (eq v :arc/missing) <default> v))`.

The dispatch lives inside `ac-complex-args`'s positional-slot
iteration -- checked **before** the existing `(o ...)` branch so
that `(o :keyword ...)` is recognised as a table entry rather than
as a positional optional named `:keyword` (which would error,
since keywords can't be local variables).

`ac-complex-args-p` was extended so a positional whose pattern is
a table pattern marks the whole arglist as "complex" and routes
through `ac-complex-fn`.

## What's deliberately not supported

- **String keys**. `(obj a 1 ...)` keys are arc symbols; the
  destructure lowers keywords to those symbols. Tables built with
  string keys would need a different spelling at the destructure
  site and aren't covered here.
- **`(o :k default)` with remap**. `(o :k var default)` was tried
  but the 2-arg form `(o :k something)` is ambiguous: is
  `something` the default or the rename target? Kept it simple:
  one extra arg is always the default. If you need both, use the
  prefix `key: var` form (no default).
- **`a` bound separately when a sub-pattern is supplied**. In
  `(:a (:x :y))`, only `x` and `y` are bound; `a` is not. The
  sub-pattern replaces the default "bind to local with same name"
  behaviour. If you want both, write `:a` twice or restructure
  the call site.

## Tests

10 new asserts in `test.arc` under `(define-test table-destructure)`:
basic, missing keys (nil), default with key absent, default with
key present, lazy default evaluation, `foo:` vs `:foo` spelling,
multi-key remap, nested table value, table mixed with positional,
two table patterns at distinct positional slots.

Full suite: 251 passed / 0 failed (was 241 before).

## Related

This builds on the keyword-reader change from `b3f0153` (handoff
`2026-04-28-005`), which made `:foo` and `foo:` both read as the
CL keyword `:FOO`. That handoff explicitly deferred arc-level
keyword *arguments* (call-site `&key` semantics); table
destructuring is a different feature -- it consumes a single
positional table value rather than rewriting call sites -- so
none of the `apply`/positional-first cognitive overhead from that
discussion applies here.
