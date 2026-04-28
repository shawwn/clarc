---
name: Dynamic scope for sharc — design notes
description: Design analysis for adding real CL-style dynamic scope to sharc, vs implementing news.arc's `(the var)` / `(t var)` thread-local hack. Conclusion: real dynamic scope, opt-in per symbol via two forms (`defvar` for no-inheritance, `defparam` for Scheme-parameter-style inheritance via `*default-special-bindings*`). Earmufs stay pure convention. Not yet implemented.
type: project
---

# Handoff: dynamic scope design — 2026-04-28

Continuation of `2026-04-28-003`. Working out how to give sharc
real dynamic scope so coroutine bodies can use `*current-coro*`
instead of the `coros*` thread→coro hash trick. The design ranged
over several questions; this captures the conclusions and the
intended order of work.

## The two paths

**News.arc's hack** (dang, HN <https://news.ycombinator.com/item?id=11242977>):
`(the var)` reads from a per-thread hash table; `(t var)` is a
parameter syntax that auto-binds from it. Surface stays lexical,
implementation is a hash. Dang himself says: *"this is a good
hack for the HN codebase but probably wouldn't make a good
extension for Arc in general, because it's clearly a poor man's
dynamic scope."*

**Real CL dynamic scope.** A symbol proclaimed `special` (via
`defvar` or equivalent) makes every binding of that symbol
dynamic. Already a primitive in SBCL. `let`, `defun` args, lambda
args, `destructuring-bind` — all bindings of a special symbol are
dynamic, no opt-in at the binding site.

Picked real dynamic scope. Reasons:

- Dang explicitly recommends it.
- SBCL gives it for free; reimplementing as a hash is reinventing
  a worse version of what's already there.
- The hash sidesteps the question rather than answering it; future
  features (error handlers, output redirection, etc.) want real
  dynamic scope eventually.

## How it works in CL — and the footgun

`defvar` proclaims a symbol special globally. After that, every
binding of the symbol is dynamic. Quick test:

```lisp
(defvar *foo* 3)
(defun bar () *foo*)
((lambda (*foo*) (+ *foo* (bar))) 2)   ; → 4
```

The lambda's `*foo*` parameter is a dynamic binding (= 2). Inside
the body, `(bar)` is called *while that binding is still in
effect*, so `bar` reads `*foo*` and also sees 2. 2 + 2 = 4.

If `*foo*` were lexical (no `defvar`), `bar` would read the
global → 3, and the answer would be 5.

This is both the feature (ambient context flowing through call
stacks) and the footgun (a function arg whose name happens to
match a defvar silently becomes dynamic, causing spooky action at
a distance).

Mitigations:

- **Earmufs stay pure convention.** A symbol becomes dynamic if
  and only if it's explicitly proclaimed special. Naming
  conventions (`*foo*`, `world*`, etc.) signal intent to
  *readers*, not to the compiler. This preserves On Lisp's
  continuation-passing macros (where `*cont*` is a *lexical*
  lambda parameter) and arc's existing trailing-`*` lexical
  globals (`world*`, `coros*`).
- **Compile-time warning** when arc lowers a binding whose LHS is
  proclaimed special, to flag accidental dynamic capture from a
  collision. SBCL itself doesn't warn here; arc can do better.
- **Restrict naming**: only earmuffed (`*foo*`) symbols are
  allowed to be proclaimed special. Plain identifiers stay
  lexical, by policy. Stops user code from accidentally making
  `count` or `result` dynamic.

## Thread inheritance is opt-in in SBCL, unlike Scheme

```lisp
(defvar *foo* 3)
(thread (let ((*foo* 42))
  (thread (sleep 2) (prn *foo*))))      ; prints 3, not 42
```

`sb-thread:make-thread` does not propagate dynamic bindings into
the new thread by default. Each thread starts with an empty
dynamic binding stack and sees the global value (3) when reading
a special variable.

Two ways to opt in:

1. **Per-spawn**: `:initial-bindings '((*foo* . ,*foo*))` captures
   specific values into the new thread.

2. **Per-symbol globally**: `(push '(*foo* . *foo*) sb-thread:*default-special-bindings*)`
   makes every spawn auto-inherit that symbol's parent value.

This is exactly where SBCL diverges from Scheme. Scheme's
`make-parameter` always inherits; CL's specials don't, you opt in.

## The recommended split: defvar vs defparam

Two forms, two intents:

```arc
(defvar  *foo*           3)    ; special, no auto-inherit (CL semantics)
(defparam *current-user* nil)  ; special, auto-inherits via *default-special-bindings*
```

`defparam` does both proclaim-special and the push to default
bindings, in one shot. `defvar` only proclaims.

Why split rather than auto-push everything:

1. **Auto-inheritance is opinionated and silent.** A worker pool
   inheriting `*current-request*` from whichever thread spawned
   it is a real bug class. Opt-in forces you to think.
2. **Capture happens in the parent at spawn time.** Every entry in
   `*default-special-bindings*` runs its capture form on every
   `make-thread`. Adds up if every defvar contributes,
   particularly for thread-heavy code like our coroutine
   scheduler.
3. **Override is awkward.** With `:initial-bindings` you can
   *add* bindings at a spawn site; you can't easily *suppress*
   an entry from the global default. If a thread wants a clean
   slate for `*foo*`, it has to rebind to nil inside its body.

Mirrors Clojure's `def` vs `def ^:dynamic` + `bound-fn`. Mirrors
how well-designed CL apps push specific symbols to
`*default-special-bindings*` informally rather than blanketing
everything.

## Specific cases

For news.arc's `me` and `ip`:

- News.arc's hash today has *no* inheritance — child threads see
  empty hashes unless explicitly pushed.
- A 1:1 migration is therefore `defvar` for both, not `defparam`.
- For synchronous request handling the choice doesn't matter
  (`me` is rebound at handler entry).
- For threads spawned *from* a handler, `defvar` requires
  explicit `:initial-bindings` if the worker should act on
  behalf of the user. That explicitness is a feature, not a bug
  — stale-identity-in-worker is a common production bug class.

For the coroutine system's `*current-coro*`:

- `defvar`. Each coro thread binds its own value at startup;
  inheritance from the parent coro would be wrong (we want each
  coro to identify as itself, not as whoever spawned it).

For a hypothetical `*world*`:

- Could go either way. Inheritance is convenient but auto-inherit
  has subtle implications. I'd start with `defvar` and pass
  explicitly; switch to `defparam` only when a real pattern
  demands ambient inheritance.

## What needs to happen in the compiler

In dependency order:

1. **Lower bare-symbol bindings to `cl:let`/`cl:let*`** instead
   of compiling to a lambda. Required for `let` to produce a
   real dynamic binding when the LHS is special.

2. **Use `destructuring-bind` for non-symbol patterns.** Dispatch
   in the lowering function:

   ```lisp
   (if (symbolp pat)
       `(let ((,pat ,val)) ,body)
       `(destructuring-bind ,pat ,val ,body))
   ```

   Walk multi-binding forms (`with`, `withs`) left-to-right,
   nesting `let` and `destructuring-bind` as appropriate.
   `withs` (sequential) → nested singletons; `with` (parallel) →
   flat `let` for the symbol cases.

3. **Add `defvar` and `defparam`.** `defvar` proclaims special
   and assigns; `defparam` does that plus pushes to
   `sb-thread:*default-special-bindings*`. Earmuf-only naming
   restriction enforced if we go that route.

4. **Compile-time warning** for `let`/binding sites whose LHS is
   already proclaimed special. Surfaces accidental dynamic
   capture.

5. **(Optional) Migrate the coroutine example** from `coros*`
   hash to `(defvar *current-coro* nil)` + `(let *current-coro*
   c ...)` inside `add-coro`'s thread body. Sanity-check the
   feature end-to-end.

## Corner cases worth flagging

- **`destructuring-bind` is strict** about list shape;
  `(destructuring-bind (a b) '(1 2 3))` errors. Arc's `let` is
  more forgiving (extras ignored, missing → nil). Either pre-pad
  the value, or write a looser `arc-destructuring-bind` macro.
- **Arc-specific patterns** (`(o x default)` for optionals) might
  appear in `let` LHS, not just fn parameters. Verify the
  destructuring-bind lambda-list semantics cover them, or extend.
- **`defglobal` (SBCL extension)** is the right primitive if you
  want an explicit non-special global (faster than `defvar`,
  guaranteed not dynamic). Worth using for `world*` etc. if their
  status as plain globals is documented.

## Why this isn't done yet

Two reasons:

- **Order of operations**: needs the `let` lowering change first.
  That's the bigger lift; the rest is small once it lands.
- **One bug to fix first** (next conversation will identify it,
  per user). After that, attempt the implementation against this
  design.

## Current state

- No code changes from this analysis. Design captured here.
- `examples/coroutines.arc` continues to use the `coros*` hash;
  works correctly under `:synchronized t` from `2026-04-28-002`.
- Next: fix the bug, then implement the design above.
