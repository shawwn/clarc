---
name: Reader and ac support for pkg::name
description: Bare `sb-thread::make-semaphore` now reads as the package-qualified CL symbol, and call forms with foreign-CL heads compile to direct CL calls. Lets Arc code call any CL function without `#'` plumbing or `find-symbol` wrappers.
type: project
---

# Handoff: package-qualified CL symbols — 2026-04-27

Follow-up to handoff `2026-04-26-009` (`#'` interop). That session
made `(#'cons 1 2)` work for any symbol *visible in `:arc`* — i.e.
inherited from `:common-lisp`. But anything from another package
(`sb-thread:make-semaphore`, `sb-bsd-sockets:socket-bind`, …) was
still unreachable: Arc's reader interns every token in `:arc`, so
`sb-thread:make-semaphore` became one Arc symbol with a literal
colon in its name, and `cl-quoted` upcased it to
`arc::|SB-THREAD:MAKE-SEMAPHORE|` — wrong package, undefined function.

This session lets Arc code refer to *any* CL package's symbols by
writing `pkg::name`, and lets call forms drop the `#'`.

## What landed (`arc1.lisp`)

### Reader: `pkg::name`

Two new helpers near the top of the reader:

```lisp
(defun cl-package-qualified-p (str) ...)   ; true for "pkg::name"
(defun intern-cl-qualified (str) ...)      ; find-symbol in named pkg
```

The check is simple: token contains exactly one `::`, with non-empty
parts on either side. (Single colon stays compose ssyntax, so
`(no:isa 1 'sym)` is unaffected.) `intern-cl-qualified` upcases both
parts and uses `find-symbol`, not `intern` — a typo errors with
"No symbol named X in package Y" instead of polluting (often locked)
CL packages.

`arc-read-1` consults the new helper *before* falling through to
`arc-intern-token`, and only when `had-vbar` is false. That keeps
`|sb-thread::foo|` reading as a literal Arc symbol with colons in
its name, the way it always did.

### `ac`: bare `(pkg::fn args)` as a direct CL call

A new clause in `ac`, sitting between the two `function` clauses and
`quote`:

```lisp
((foreign-cl-call-p s env)
 (cons (car s) (mapcar (lambda (x) (ac x env)) (cdr s))))
```

It emits the head verbatim and compiles each argument through `ac`
— the same shape as the existing `((function fn) args)` clause, just
without requiring the user to write `#'` first.

Backed by two predicates:

```lisp
(defun foreign-cl-symbol-p (s)
  "Symbol from a package other than :arc and not visible from :arc
through inheritance.  cl:= and cl:cons are NOT foreign even though
their symbol-package is :common-lisp, because Arc-side names resolve
to them via find-symbol."
  (and (symbolp s)
       (let ((pkg (symbol-package s)))
         (and pkg
              (not (eq pkg (find-package :arc)))
              (not (eq (find-symbol (symbol-name s) :arc) s))))))

(defun foreign-cl-call-p (s env)
  (and (consp s)
       (foreign-cl-symbol-p (car s))
       (not (lex-p (car s) env))))
```

The `find-symbol` check is load-bearing — the first version of
`foreign-cl-symbol-p` only checked `symbol-package`, which made
short-name inherited symbols (`=`, `+`, `cons`, `if`, …) look
foreign and broke `arc.arc` immediately: `(= templates* (table))`
compiled to a direct call to `cl:=` (numeric equality) instead of
expanding through Arc's `=` macro. The fix: a symbol is foreign
only if `(find-symbol name :arc)` doesn't return it. Inherited
short-names pass that test (find-symbol returns the inherited
symbol itself); package-qualified imports like
`sb-thread:make-semaphore` don't.

The `(not (lex-p ...))` guard means `(let cons (...) (cons 1 2))`
with a shadowing local still binds normally.

### `cl-quoted` / `ac-quoted` package-preservation

Same problem in the other direction: `cl-quoted` previously walked
every symbol through `cl-sym`, which interns into `:arc`. That would
strip `sb-thread:make-semaphore` of its package and re-intern as
`arc::MAKE-SEMAPHORE`. Fix:

```lisp
(defun arc-package-symbol-p (x)
  (and (symbolp x) (eq (symbol-package x) (find-package :arc))))

(defun cl-quoted (x)
  (cond ((null x) nil)
        ((eq x t) t)
        ((consp x)                (arc-imap #'cl-quoted x))
        ((arc-package-symbol-p x) (cl-sym x))
        (t x)))
```

`ac-quoted` got the same guard. Symbols whose home is *not* `:arc`
(both inherited CL like `cl:cons` and explicitly-qualified like
`sb-thread:make-semaphore`) now pass through quoting unchanged.

This is a deliberate behavior change for inherited symbols too:
`'cons` used to be re-interned as the lowercase Arc-typed symbol
`arc::|cons|`; now it stays as `cl:cons`. The test suite passes
unchanged (207 passed, 0 failed), so no observable consequence in
practice — but it's worth knowing if some downstream code relies
on the old normalisation.

## Why two predicates instead of one

`arc-package-symbol-p` answers "is this an Arc-typed identifier
that should be normalised through `arc-sym`/`cl-sym`?" — used by
the quoting helpers. `foreign-cl-symbol-p` answers "is this a
symbol pointing at code in another CL package?" — used by `ac`'s
call-compilation clause. They're *not* complements: a symbol
inherited via `:use` (`cl:cons`) is neither — its home isn't `:arc`,
but it's also not foreign because Arc-side names resolve to it.
Both predicates correctly reject it, and `ac` falls through to the
normal Arc call path for it.

## What this enables

The whole point is being able to write things like:

```arc
(def sem      ()  (sb-thread::make-semaphore))
(def sem-wait (s) (sb-thread::wait-on-semaphore s) nil)
(def sem-post (s) (sb-thread::signal-semaphore s) nil)
```

without `withs (… #'find-symbol "MAKE-SEMAPHORE" "SB-THREAD" …)`
plumbing or a separate `xdef` shim per primitive. Anything in any
loaded CL package — sb-thread, sb-bsd-sockets, sb-ext, third-party
asdf systems — is reachable from Arc source the moment its package
exists.

See handoff `2026-04-27-002` for the coroutine example built on
top of this.

## Verified

- `./test.arc` → `207 passed, 0 failed` (unchanged from before).
- `(prn (sb-thread::make-semaphore))` → `#<SB-THREAD:SEMAPHORE …>`.
- `(apply #'#'sb-thread::make-semaphore nil)` works (value position).
- `(no:isa 1 'sym)` and `((compose no isa) 1 'sym)` both `T` —
  single-colon compose ssyntax untouched.
- `'|sb-thread::foo|` reads as the literal Arc symbol with the
  colons in its name, NOT as the package-qualified form.

## Notes for whoever picks this up

- **`pkg::name` is `find-symbol`, not `intern`.** Differs from CL
  on purpose. If you genuinely need to *create* a symbol in another
  package, use `(#'intern "NAME" "PKG")` explicitly.

- **No `pkg:name` syntax (single colon).** That's still compose
  ssyntax — `foo:bar` = `(compose foo bar)`. Single-colon
  package-qualified syntax would require disambiguation we don't
  attempt.

- **`|pkg::name|` is intentionally an Arc symbol.** The vbar form
  bypasses the package-qualifier check — useful for keeping a
  literal symbol with colons in its name. The price is the call
  to `arc-read-token` returns `had-vbar=t`, which the caller in
  `arc-read-1` tests before applying the new rule.

- **The `lex-p` shadow check matters.** Without it,
  `(let cons (...) (cons 1 2))` would compile to a direct CL call
  to `cl:cons` ignoring the binding — except actually it wouldn't,
  because `cl:cons` is not foreign (inherited). But the same
  scenario with `(let make-semaphore (...) (sb-thread::make-semaphore))`
  *would* misbehave without the guard. Belt and suspenders.

- **The `#'fn` / `#'#'fn` rules from handoff `009` are unchanged.**
  This session is purely additive: bare `(pkg::fn args)` is a new
  call path; everything `#'` did before still works.

## Current state

- `arc1.lisp`: ~50 added lines (two helpers in the reader, two
  predicates near `cl-quoted`, one new `ac` clause, package-guard
  on `cl-quoted`/`ac-quoted`).
- `MEMORY.md`: not touched. Mission TKTK is independent of this
  work — the un-`:use :common-lisp` rewrite would change which
  symbols are inherited, but the predicates here use
  `find-symbol` and would adapt automatically.
