---
name: Free references to unbound globals now error at runtime
description: Add `arc-global-ref` (errors on unbound) and have `ac-var-ref` emit it for Arc-source-level free references; internal `arc-global` callers keep silent-nil semantics.
type: project
---

# Handoff: Unbound Arc variables raise an error — 2026-04-26

## What was accomplished

Before, an Arc free reference to an undefined global silently evaluated
to `nil`:

```
arc> (list foo bar baz)
(nil nil nil)
```

This diverges from reference Arc (mzscheme/Racket), where the
underlying scheme errors on unbound identifiers, and made typos in
user code very hard to notice. Now:

```
arc> (list foo bar baz)
Error: Unbound variable: foo
arc> (+ 1 2)
3
```

The REPL's existing `error` handler in `arc-tl2` catches the condition
and recovers to the next prompt. Piped scripts (`./sharc < file`) and
file scripts (`./sharc file.arc`) abort on first unbound reference.

## Files changed this session

- `arc0.lisp`:
  - **New `arc-global-ref` (after `arc-bound-p`)**: like `arc-global`
    but uses `gethash`'s second value to distinguish "absent" from
    "bound to nil", and `error`s on absent.
  - **`ac-var-ref`**: emits `(arc-global-ref ',s)` instead of
    `(arc-global ',s)` for free references. Lex-bound symbols still
    pass through unchanged.

No other files changed. Internal CL code that calls `(arc-global '...)`
directly (e.g. `script-file*`, `that`/`thatexpr`, the runtime helpers)
is **unaffected** — they keep silent-nil semantics, which is what we
want for runtime infrastructure that legitimately probes for
maybe-unset globals.

## Key decisions

- **Runtime check, not compile-time.** `ac-var-ref` runs at
  *compile* time (during `ac`), but it must not error there: macros,
  recursive function bodies, and forward references all reference
  names that are not yet bound when the form is being compiled. The
  emitted call to `arc-global-ref` defers the existence check to the
  moment the reference is actually evaluated, by which time bindings
  added later in the file (or by `def`/`set` at the REPL) are present.

- **New function rather than tightening `arc-global`.** Lots of
  internal CL code reads globals defensively, expecting `nil` for
  "not set yet" — e.g. probing optional config flags during boot, or
  reading `that`/`thatexpr` before the user has typed anything.
  Tightening `arc-global` itself would break boot. A separate
  `arc-global-ref` keeps the user-visible Arc semantics strict while
  leaving the runtime's tolerant lookup intact.

- **Use `gethash`'s second value, not `(or v default)`.** A symbol
  legitimately bound to `nil` (`(= x nil)`) must not error. The
  `multiple-value-bind ... present` pattern is the only correct way
  to distinguish "absent" from "bound to nil" in a CL hash table.

- **Did not prettify the stdin/script error path.** When stdin isn't a
  TTY, `arc-load-stdin` has no handler, so unbound errors there dump a
  full SBCL backtrace. That's ugly but correct — scripts *should*
  abort on unbound refs. If/when this matters, wrap `arc-load-stdin`
  with the same `(error (lambda (c) (arc-report-error c) ...))`
  pattern used in `arc-tl2`, and probably exit non-zero.

## Verification

- `./sharc test.arc` → **193 passed, 0 failed**
- `./sharc app.arc` → news server boots and starts listening (the
  `*** redefining ...*` lines are pre-existing noise from libs.arc /
  news.arc redefining each other; not introduced by this change)
- Pty-driven REPL session:
  - `(list foo bar baz)` → `Error: Unbound variable: foo` + backtrace,
    REPL recovers to next `arc>` prompt
  - `(+ 1 2)` → `3`
  - `(quit)` → exits cleanly

The fact that all of `arc.arc`, `libs.arc`, `news.arc`, and the test
suite load and run without unbound-variable errors is the strongest
signal that no Arc-source code in the repo was relying on silent-nil
for free references.

## Things to watch

- **User code that relied on `nil`-for-unbound.** Any Arc code that
  read a global as a "feature flag" without ever setting it will now
  error. None exist in this repo, but external Arc programs ported in
  may need a `(= flagname nil)` somewhere up top.

- **Forward references at top level.** A top-level form that
  references a global *before* it is defined later in the same file
  will now error at the time that form is evaluated. Arc files in
  this repo are organized so definitions precede uses, so this hasn't
  bitten us — but it's a behavior shift worth keeping in mind if a
  future port reorders forms.

## Current state

- One change to `arc0.lisp` (5+/1- lines), uncommitted on `main` at
  the start of this handoff. Commit is the next step.
