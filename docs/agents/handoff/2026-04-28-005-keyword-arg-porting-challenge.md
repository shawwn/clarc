---
name: Keyword arguments — reader fix landed; call-site reorder dropped
description: Reader now treats `:foo` and `foo:` as CL keywords (commit b3f0153). Considered a Racket-style call-site reorder rule (`foo: 42` → moved to end as `:foo 42`) but dropped it after the `apply` interaction surfaced cognitive overhead not worth the ergonomic win. CL's positional-first rule stands. Arc-level keyword args design is deferred indefinitely.
type: project
---

# Handoff: keyword argument port — reader done, calling convention TBD — 2026-04-28

This handoff has two parts: what's done (the reader change), and
what's left (the call-site ergonomics, which need a design pass).

## Done: reader treats `:foo` and `foo:` as CL keywords

Commit `b3f0153`. Two fixes:

- A leading or trailing single colon (`:foo`, `foo:`) reads as
  the CL keyword `:FOO`. Previously both were eaten by compose
  ssyntax — `:initial-bindings` would tokenise into the bare
  symbol `initial-bindings` and "Unbound variable" out at eval.
- `literal-p` includes `keywordp`, so keywords self-evaluate.

Vbar (`|:foo|`) suppresses the keyword interpretation and keeps
the colons literal as an arc symbol. `foo:bar` (compose) and
`pkg::name` (CL package qualification) are unchanged.

Test suite still 207/207, coroutines demo unchanged.

## Discovery: `:initial-bindings` is gone in modern SBCL

This was the original motivating example, from the dynamic-scope
work in handoff `2026-04-28-004`. Modern SBCL (2.6.3 here) only
accepts `:NAME` and `:ARGUMENTS` on `sb-thread:make-thread`. The
`:initial-bindings` keyword was removed at some point.

So the per-spawn-binding mechanism in `004` (`:initial-bindings
'((*x* . *x*))`) doesn't work as written. The remaining options
for getting dynamic bindings into a new thread are:

- `sb-thread:*default-special-bindings*` — push per-symbol
  globally, every thread inherits.
- Inside the thread function: `(let ((*x* captured-value)) ...)`
  with the value captured in the parent at spawn time via a
  closure.

`004`'s `defparam` design (push to `*default-special-bindings*`)
still works. The "per-spawn explicit `:initial-bindings`" branch
should be replaced with the closure-capture pattern — same effect,
slightly more code at the call site.

## The harder problem: CL's keyword-call ergonomics are not great

The reader now produces keywords. The harder question is how
arc-level functions should *use* them at call sites. CL's rules
have two well-known papercuts:

### Papercut 1: positional must come before keys

Required and `&optional` arguments are matched left-to-right
*before* `&key` parsing begins. There's no syntactic way to put
keys first or interleave them.

```arc
;; This DOES NOT work in CL:
(sb-thread::make-thread name: "hi" (fn () (prn "hi")))
;; The first positional arg `function` consumes :NAME (the
;; keyword itself, treated as a value), then key-parsing on the
;; remaining args fails because "hi" isn't a keyword.

;; You have to write:
(sb-thread::make-thread (fn () (prn "hi")) name: "hi")
```

This is awkward when the positional arg is large (a multi-line
`fn`) and the keyword args are small (a name string). You'd
rather lead with the small annotations and trail with the bulky
function body.

The standard CL workaround: define an all-keyword wrapper.

```lisp
(defun mk-thread (&key fn name arguments)
  (sb-thread:make-thread fn :name name :arguments arguments))
```

Now order is fully flexible at call sites. Used widely in CL
libraries that want keyword-first ergonomics.

### Papercut 2: `&rest` + `&key` is "all keys or error"

If a function declares both `&rest` and `&key`, the *entire* rest
list must form valid keyword/value pairs:

```lisp
(defun foo (&rest r &key x) (list r x))

(foo :x 5)              ; → ((:X 5) 5)         OK
(foo :x 5 'a 'b 'c)     ; → ERROR: odd number of &KEY arguments
(foo :x 5 'a 'b)        ; → ERROR: Unknown &KEY argument: A
```

There's no "this part is data, this part is keys" split. The
intuitive call pattern of "pass some positional data plus a few
options" doesn't work — once `&key` is active, every rest arg
becomes a key.

This is why `&rest` + `&key` is almost exclusively used for
*forwarding wrappers* in CL (where the rest contains keys all
the way down, destined for `apply`). Mixing data and keys means
either:

- Bundling the data into a single positional arg (a list):
  `(defun foo (data &rest opts &key x) ...)`, called as
  `(foo '(a b c) :x 5)`.
- Forgoing keys entirely and using positional/`&rest` only.

### What Racket got right

Racket's keyword arguments can appear *anywhere* in a call,
freely interleaved with positionals. `apply`'s analogue
(`keyword-apply`) handles them sanely. The runtime separates
keyword args from positional args at call time.

CL pre-dates this design by ~20 years and shows it. Most CL code
never hits these edges — you write either all-positional or
`&key`-with-no-`&rest` — but library wrappers and extension
points trip over it regularly.

## The porting challenge

Question: how should arc-level keyword arguments work?

Three plausible designs:

### Option A: pass through to CL `&key` semantics unchanged

Cheapest. `(def foo (x &key y) ...)` lowers to a CL `&key`
function with the same calling rules. Inherits both papercuts.

Pros: trivial implementation. Pros: full CL interop — every
`&key` CL function can be called from arc using the existing
reader changes.

Cons: the papercuts. Especially the positional-first rule, which
clashes with arc's tendency to put short annotations before bulky
function bodies.

### Option B: Racket-style — keys can appear anywhere

Reader collects keyword/value pairs into a separate stream from
positionals during call-site parsing. The compiler emits a call
that places the keys after the positionals automatically.

So `(make-thread name: "hi" (fn () ...))` reads syntactically as
keys-first but compiles to `(make-thread (fn () ...) :name "hi")`.

Pros: matches the natural "small annotations first" reading.

Cons: the reader has to rewrite call forms based on whether the
operator is a `&key`-taking function — which it doesn't know at
read time. Compile-time rewriting is possible but requires
function-signature awareness in the compiler, which arc currently
doesn't have. And mixing arc keyword-anywhere with calls into raw
CL functions becomes confusing — does the reordering apply to
`sb-thread::make-thread` too? Probably not, but the rule needs
to be specified.

### Option C: arc keyword args are always all-keyword (no positional + key)

Following the conventional CL workaround as a language rule:
`def`/`fn` lambda lists are either all-positional or
all-keyword. No mixing. Inside an all-keyword form, args can
appear in any order at the call site — same as CL but with the
mixing trap eliminated by construction.

Pros: simple semantics, no reordering magic. Avoids both
papercuts. Matches the idiom CL libraries already use to escape
the trap.

Cons: less expressive than CL — can't have a mandatory
positional with optional keys. (Workaround: use the first key as
"the main one," or split into two functions.)

## Decision: do nothing further for now

After working through Option B in detail (call-site reorder rule
where `foo: VALUE` gets moved to the end of the arglist), the
`apply` interaction killed it. `apply`'s last arg must be the
trailing list, but a "move keys to end" rule wants to put them
after the list — opposite directions. The clean version requires
either special-casing `apply` (and any other trailing-rest forms)
or accepting that the syntax doesn't apply to indirect calls.

Both are workable but introduce a "two ways to spell keys, depends
on context" cognitive load that probably isn't worth the
ergonomic win. For direct calls you'd write `name: "hi"`; for
`apply` you'd write `:name "hi"` literally. Same value, two
spellings, with rules about when each is allowed.

Final call: **drop the call-site reorder feature entirely.** Arc
keyword args, when needed, will follow CL's positional-first rule
(Option A in the original list). The reader change in `b3f0153`
stays — `:foo` and `foo:` both produce the keyword `:FOO`, which
is independently useful for CL interop. No further design
required.

If a future concrete use case demands keyword-first ergonomics,
revisit then; the most likely path would be **Option C** (arc
keyword forms are all-keyword by construction — no `&rest`/`&key`
mixing trap), which avoids the apply pitfall because there's no
positional-vs-key reordering happening at all.

For arc → CL interop today: write keys after positionals at the
call site, e.g.:

```arc
(sb-thread::make-thread (fn () (prn "hi")) name: "hi")
```

`name:` reads as `:NAME`, lands in keyword-pair position, CL
parses it normally. Done.

## Next concrete step

The dynamic-scope plan from `2026-04-28-004` doesn't actually
need arc-level keyword args — `defvar`/`defparam` are zero-arg
forms (or one-arg with an init value), and the `:initial-bindings`
escape hatch is gone in modern SBCL anyway. So the porting
challenge captured here is independent of the dynamic-scope
work. Both can proceed separately.

Order of operations:

1. Arc `let`/`def` lowering to CL `let`/lambda with destructuring
   dispatch (handoff `004`).
2. `defvar`/`defparam` for dynamic scope (handoff `004`).
3. Arc-level keyword argument design is deferred indefinitely.
   The reader changes in `b3f0153` are sufficient for CL interop
   and that's all that's needed right now.
