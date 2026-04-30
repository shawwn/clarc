---
name: Thread-local variables (news.arc style) — implemented
description: Implements dang's news.arc `(the var)` / `(t var)` thread-local trick (HN id 11242977). Per-thread hash table; `(t var)` parameter form lowers to an optional defaulting to `(the var)`. Landed in commit cdac4ad with 22 new tests. Explicitly chose the hash-based hack over real CL dynamic scope from handoff 2026-04-28-004; the two are additive.
type: project
---

# Handoff: thread-locals (news.arc style) — 2026-04-30

Implemented dang's news.arc thread-local trick from
<https://news.ycombinator.com/item?id=11242977>. Commit `cdac4ad`.

## What landed

```arc
(the var)              ; read thread-local
(= (the var) val)      ; write
(w/the var val body)   ; scoped bind, restored on exit (incl. error)
(w/me val body)        ; shorthand for (w/the me ...)

(def f ((t me)) ...)        ; me defaults to (the me) if omitted
(def f ((t local var)) ...) ; local defaults to (the var)
```

Three files:

- **`arc1.lisp`** — `ac-complex-args` recognises `(t var)` and
  `(t local var)` in fn lambda lists, lowering both to
  `(o local (the var))` (an optional with a thread-local default).
  The dispatch is one new clause in the existing cond that
  already handles `(o ...)`. ~10 lines.
- **`arc.arc`** — `thread-locals*` global hash keyed by
  `(current-thread)`; `thread-local`/`(the var)` reader; setter
  registered via `defset`; `w/the` and `w/me` scoping macros.
  ~25 lines.
- **`test.arc`** — five test groups covering reads/writes,
  `w/the` scoping (including restoration on error), `w/me`,
  `(t var)` parameter behaviour with and without explicit
  override, and cross-thread isolation. 229/229 passing
  (was 207).
- **`examples/the.arc`** — simulated request-handler flow.
  `can-edit?` and `log-action` declare `(t me)` and `(t ip)`,
  pull from thread-locals when called with the "real" args
  only, and let admin tools pass explicit overrides without
  changing the surrounding scope.

## Why the hack and not handoff `004`'s real dynamic scope

`2026-04-28-004` recommended real CL dynamic scope (`defvar`/
`defparam`) over this hash-based approach. Going the other
direction here is deliberate, not a reversal of that
recommendation. Two reasons:

1. **The hack is small, self-contained, and works today.** Real
   dynamic scope still depends on getting arc's `let` to lower
   to `cl:let` with destructuring dispatch, which is a real
   compiler change with destructuring corner cases. This
   thread-local hack needed only one new clause in
   `ac-complex-args` and ~25 lines of arc.arc; the rest is
   tests and an example.

2. **`004`'s recommendation still stands for the dynamic-scope
   use case.** Things like `*standard-output*` redirection or
   error-handler stacks want real specials with proper unwind
   semantics. The news.arc hack doesn't replace any of that --
   it just gives you a clean way to thread "current request
   context" through call stacks without polluting every
   signature.

So treat the two as additive: this lands the small thing today;
the bigger thing remains open in `004` and would be implemented
the same way regardless of whether the hack is also present.

## Sharp edges

### `(t var)` must come last in the parameter list

`(t var)` is an optional parameter. Optionals are filled by
positional args left-to-right, exactly the same as `(o ...)`.
So:

```arc
(def can-edit? ((t me) c) ...)   ; WRONG
(can-edit? c1)                    ; binds me=c1, c=nil

(def can-edit? (c (t me)) ...)   ; right
(can-edit? c1)                    ; binds c=c1, me=(the me)
(can-edit? c1 jcs)                ; explicit override of me
```

Caught me when writing the example. Documented in the example
header. This is a CL/arc semantic, not a sharc choice — same
rule has always applied to `(o ...)` optionals; we inherit it.

If we ever want to relax this (so `(t var)` and `(o ...)` can
appear before required args), we'd have to change the lowering
to *not* use optionals — maybe a custom argument-binding pass
that fills `(t ...)` from thread-locals only after consuming
the required args. Bigger change, no compelling reason yet.

### Memory: dead threads stay in `thread-locals*`

The hash is keyed by thread object. When a thread exits, its
entry is not automatically removed. For long-lived processes
that spawn many short-lived threads (e.g. an HTTP server
handling many requests), `thread-locals*` will grow without
bound.

Three mitigations available, none implemented yet:

- **Weak hash table** keyed by thread, so entries get GC'd when
  the thread itself is no longer referenced. SBCL supports
  `:weakness :key` for this. Cleanest fix; one change to the
  table constructor.
- **Explicit cleanup** at request boundary: the request
  handler's `unwind-protect` removes the entry after the
  request completes. More precise; doesn't depend on GC.
- **Lazy reaping** during `thread-locals` lookup: occasionally
  walk the table and remove dead entries. Hacky; only worth
  it if the above don't fit.

For the demo and tests, none of this matters. For a real
news.arc-style server, weak-keys is probably what you want.

### Per-thread setq has no inheritance

A child thread spawned mid-request does *not* inherit the
parent's thread-locals — it has an empty hash. If you want
inheritance, the parent has to copy explicitly:

```arc
(let parent-locals (thread-locals)
  (thread
    (each (k v) parent-locals
      (= ((thread-locals) k) v))
    ...))
```

Or wrap it in a helper. Same trade-off as the SBCL specials
discussion in `004`: explicit > magic. News.arc itself doesn't
inherit either, by design — request workers are short-lived
and request-bound, not nested.

## What's NOT included

Things considered and skipped:

- `(the (var))` with computed var name. Always literal symbols
  for now — call `thread-local` directly if you want a runtime
  key.
- `(thread-local-bind ((var val) ...) body)` parallel scoped
  binding form. `w/the` and `w/me` cover the common cases;
  multi-binding can be done via nesting.
- Setting in the parameter list itself, e.g. `(def f ((t! me val)))`
  to *set* a thread-local rather than read it. Not part of
  news.arc's API.

## Current state

- `cdac4ad` is on `main`; tests 229/229; examples both run
  cleanly (`coroutines.arc` and `the.arc`).
- Handoff `2026-04-28-004` (real dynamic scope design) is still
  open and not invalidated by this work.
- Future: weak-keys for `thread-locals*` when a real workload
  surfaces the leak.
