---
name: Readtable case and the backtrace-pipes problem
description: Why backtraces show `arc::|car|` and `|arc--CAR|` with pipes, what `:upcase`/`:invert`/`:preserve` actually do, what we tried, what worked, and the deeper package refactor (Mission TKTK) needed to fully fix it.
type: project
---

# Handoff: readtable-case and the backtrace-pipes problem — 2026-04-26

This is mostly a thinking document. The actual code change in this
session is tiny (~5 lines). Most of the value is the analysis of the
problem space — read this before touching anything related to symbol
printing, the arc reader, or the `:arc` package.

## Why we care about any of this

The deeper goal — the thing that justifies the whole exercise — is
to support **case-sensitive Arc**. We want this to work:

```arc
(def Foo (x) (+ x 1))
(def foo (x) (* x 2))
(Foo 10)  ; => 11
(foo 10)  ; => 20
```

`Foo` and `foo` should be *separate functions*, the same way they
are in Scheme/Racket (where original Arc lives) and most modern
languages. Default Common Lisp can't do that — its reader upcases
everything, so `Foo`, `FOO`, and `foo` all become the same symbol.

Getting there cleanly means picking a readtable-case mode that
preserves typed case, making the arc reader respect it, and making
sure backtraces and printed output don't bury the user in `|...|`
escapes the moment a mixed-case symbol appears. The pipe-removal
work in this session is one tile in that mosaic. The remaining
tiles (Mission TKTK, below) are about un-blocking the arc reader
so it can actually distinguish `Foo` from `foo` without colliding
with inherited `cl:` symbols.

## The user-visible problem

When the REPL reports an error, the backtrace is full of pipes:

```
4: (ARC::|arc--CAR| 42)
5: (... (ARC::ARC-GLOBAL-REF (QUOTE ARC::|car|)) 42 ...)
7: (ARC:ARC-EVAL (ARC::|car| 42))
```

Two distinct sources of pipes:

1. **`|arc--CAR|`** — the *named primitive* introduced by handoff
   `005-xdef-function-syntax`. Lives in CL source (arc0.lisp). Mixed
   case (`arc--` lowercase, `CAR` uppercase) because of how it's
   built (lowercase prefix string + `(symbol-name 'car)` which is
   `"CAR"` under the default `:upcase` reader).

2. **`|car|`** — an *arc-typed* symbol, interned by the arc reader
   (`arc-intern-token`) which preserves source case literally.
   So typing `car` at the REPL produces a symbol whose `symbol-name`
   is the string `"car"` (all lowercase).

In both cases the pipes are correct: under the default `:upcase`
readtable, the printer emits pipes around any symbol whose name
isn't all-uppercase, because that's the only way to round-trip the
name back through `read`.

## Common Lisp readtable case modes — what each one means

`(readtable-case *readtable*)` has four legal values. They affect
**both** how the reader interns tokens and how the printer
formats/escapes symbols.

### `:upcase` (default)

- **Reader:** unescaped tokens are upcased before interning.
  `car`, `Car`, `CAR` → all read as the symbol named `"CAR"`.
- **Printer:** all-uppercase names print bare; anything with
  lowercase letters needs `|...|` to round-trip.
- This is why CL "feels" case-insensitive in practice.

### `:downcase`

- Mirror image: tokens are downcased on read; uppercase symbol
  names need pipes when printed.
- Rarely useful — almost no CL code is written assuming this mode.

### `:preserve`

- **Reader:** no transform. `Car` interns as `"Car"`, `car` as
  `"car"`. Whatever you type is what you get.
- **Printer:** prints symbol-name verbatim, no pipes.
- **Trade-off:** breaks compatibility with stock CL because every
  stock symbol (e.g. `cl:defun`) has an uppercase name. To use
  `defun` you'd have to type `DEFUN`. Not viable for mixed code.

### `:invert`

- **Reader:** if the token is all-one-case, flip it; mixed case is
  preserved. So `car` → `"CAR"`, `CAR` → `"car"`, `Car` → `"Car"`.
- **Printer:** mirror image. All-upper names print all-lower (no
  pipes), all-lower print all-upper (no pipes), mixed preserves
  (no pipes).
- **Why this is interesting for sharc:** All existing CL code
  written in conventional lowercase (`defun`, `let`, etc.) keeps
  working unchanged, because all-lowercase still resolves to the
  all-uppercase canonical CL symbol. Mixed-case names like
  `arc--CAR` become printable without pipes.
- Used by Allegro CL's "modern mode" and a few other Lisps for the
  same reason — it's the closest thing to "CL feels case-sensitive
  while still working with stock CL packages."

## What we tried this session

### Attempt 1 — set `:invert` globally on the arc readtable

Added `(setf (readtable-case *readtable*) :invert)` near the top of
arc0.lisp. Goal: make mixed-case names like `arc--CAR` print
without pipes everywhere.

**Result:** load worked (arc0.lisp is all-lowercase, so `:invert`
upcases tokens identically to `:upcase`). All 193 tests passed.
But the REPL backtrace still showed pipes, because
`sb-debug::print-frame-call` rebinds `*readtable*` to a standard
io-syntax readtable internally. Our global setting didn't reach
the formatter.

### Attempt 2 — local `:invert` rebind in `arc-report-error`

Bind a `:invert`-cased copy of the readtable inside the
`with-output-to-string` block that captures each frame's text:

```lisp
(let ((*print-pretty* nil)
      (*readtable* (copy-readtable *readtable*)))
  (setf (readtable-case *readtable*) :invert)
  (sb-debug::print-frame-call frame s :number nil))
```

**Result:** `arc--CAR` now prints clean. *But* `arc::|car|` (the
arc-side symbol) still prints with pipes — because under `:invert`,
all-lowercase `"car"` should print *uppercase* (it inverts to
`CAR`), so the printer adds pipes to preserve the lowercase form.

That's correct `:invert` behavior, but not what we want.

### Attempt 3 — also invert in the arc reader

The right fix conceptually: have `arc-intern-token` apply the same
invert transform on read, so typed `car` interns as `"CAR"` (which
under `:invert` printer round-trips back to `car`).

Wrote `arc-invert-case`, threaded `had-vbar` through
`arc-intern-token`, and uppercased ~14 literal-string
`(intern "foo" :arc)` calls (line 28-30, 208, 212, 218, 397, 398,
404, 413, 422, 468, 480, 842-853) so the runtime would still match
what the inverted reader produces.

**Result: blew up at boot** with:

```
Lock on package COMMON-LISP violated when interning NO while in
package COMMON-LISP-USER.
```

**Why:** `(defpackage :arc (:use :common-lisp) ...)` means every
external CL symbol is inherited into `:arc`. When the arc reader
reads token `some` and inverts it to `"SOME"`, then calls
`(intern "SOME" :arc)`, intern finds the *inherited* `cl:some` and
returns it instead of creating a fresh `arc::some`. The arc symbol
is now `cl:some`, with `(symbol-package sym) = #<PACKAGE
"COMMON-LISP">`. Later, ssyntax expansion does
`(intern "no" pkg)` where `pkg` is that symbol's package — so it
tries to intern in the locked CL package and SBCL refuses.

This is a *fundamental* collision: under `:upcase` (or `:preserve`
with lowercase tokens), arc symbols couldn't collide with CL exports
because the names differed in case. Under `:invert`, they can.

### Attempt 4 — back out everything except the local rebind

Reverted Attempt 3 (arc reader untouched) and Attempt 1 (global
`:invert` removed). Kept only the local rebind in
`arc-report-error`. Final diff is ~5 lines.

## What this session actually committed (or will)

Single change in `arc0.lisp` inside `arc-report-error`:

```diff
+         ;; Print frames under :invert readtable case so mixed-case
+         ;; symbol names (like arc--CAR) come out without |...| escapes.
+         ;; All-lowercase and all-uppercase names still print in their
+         ;; canonical form; only mixed-case ones change.
          (let ((text (with-output-to-string (s)
-                       (let ((*print-pretty* nil))
+                       (let ((*print-pretty* nil)
+                             (*readtable* (copy-readtable *readtable*)))
+                         (setf (readtable-case *readtable*) :invert)
                          (sb-debug::print-frame-call frame s :number nil)))))
```

**What this buys us:** mixed-case named primitives like `arc--CAR`
now print as `arc::arc--CAR` in the REPL backtrace instead of
`ARC::|arc--CAR|`.

**What this does NOT fix:** arc-typed symbols like `car` still
print with pipes (`ARC::|car|`) because their symbol-name is
all-lowercase and `:invert` adds pipes to lowercase names. Fixing
that requires the package refactor below.

Test status: 193 passed, 0 failed. Untouched from before.

## Key decisions

- **Local rebind, not global readtable change.** A global `:invert`
  setting affects SBCL's own error-message formatting (e.g.
  `Unhandled SIMPLE-ERROR` becomes `Unhandled simple-error`), which
  is cosmetic, weird, and unrelated to our backtrace. The local
  rebind keeps the change scoped to where it matters.

- **Did not touch the arc reader.** The `:invert` transform in the
  arc reader is the *right* answer in the long run, but it's blocked
  by the `:use :common-lisp` collision. Doing it now would require
  the package refactor first; doing it after the package refactor
  is straightforward.

- **Did not change `arc-global-name`.** Still produces mixed-case
  names like `"arc--CAR"`. With the local rebind this now prints
  cleanly. An alternative was `string-downcase`-ing the suffix to
  produce `"arc--car"` — but under `:invert` all-lowercase prints
  inverted to all-uppercase (`ARC--CAR`), which is uglier than the
  mixed-case version.

## Mission TKTK — the unfinished work

Tracked separately in user memory as "Mission TKTK". Goal: stop
arc symbols colliding with CL exports so the arc reader can safely
apply `:invert`.

### Approach A: drop `:use :common-lisp` from `:arc`

Change:

```lisp
(defpackage :arc
  (:use :common-lisp)            ; <-- remove this
  (:export ...))
```

to:

```lisp
(defpackage :arc
  (:import-from :common-lisp
    #:defun #:defmacro #:lambda #:let #:let* ...)
  (:export ...))
```

Then arc symbols never collide with CL exports — typing `some`
interns a fresh `arc::some` regardless of CL's `some`.

**Pain:** arc0.lisp uses *huge* numbers of CL symbols (every
`defun`, `let`, `cond`, `if`, `setf`, `format`, `loop`, `when`,
`mapcar`, `cons`, `car`, `cdr`, ...). Manually listing them in
`:import-from` is tedious. Realistic options:

1. Generate the import list by grep-ing the file for unqualified
   CL symbols.
2. `:shadow` only the specific names that conflict (`some`,
   `complement`, `compose`, `andf`, `no`, `get`, `string`, `cons`,
   `sym`, `fn`, `char`, `int`, `num`, `table`, `output`, `input`,
   `thread`, `quote`, `quasiquote`, `unquote`, `unquote-splicing`)
   — those are the lowercase strings interned by literal in
   arc0.lisp that would otherwise resolve to CL exports under
   `:invert`.

Approach 2 is much smaller and probably correct. Worth pursuing
first.

### Approach B: use a separate package for arc-side symbols

Have `:arc` keep `:use :common-lisp` for the *implementation*, but
intern arc-typed symbols in a different package like `:arc-user`
that only `:use`s a stripped-down core.

Probably more work than Approach A, with no clear advantage.

### Once unblocked

After the package refactor:

```lisp
(defun arc-invert-case (str)
  (let ((has-upper nil) (has-lower nil))
    (loop for c across str do
      (cond ((upper-case-p c) (setf has-upper t))
            ((lower-case-p c) (setf has-lower t))))
    (cond ((and has-upper (not has-lower)) (string-downcase str))
          ((and has-lower (not has-upper)) (string-upcase str))
          (t str))))

(defun arc-intern-token (str &optional had-vbar)
  ...
  (or n (intern (if had-vbar str (arc-invert-case str)) :arc)))
```

And update all the literal `(intern "lowercase" :arc)` calls in
arc0.lisp to uppercase strings (or uppercase via a helper) so they
match what the inverted reader produces. Pre-Mission-TKTK list of
lines that need updating: 28-30, 208, 212, 218, 397-398, 404, 413,
422, 468, 480, 842-853.

Test command: `./sharc test.arc` should still report
`193 passed, 0 failed`.

## Lessons learned

- **`:invert` is the only readtable-case mode that interoperates
  with stock CL while preserving case for mixed-case names.** Worth
  remembering when the question of "case sensitivity in CL" comes
  up.

- **Symbol identity is by-pointer, not by name.** `arc::|car|` and
  `cl:car` are different symbols even though both have name
  `"CAR"` (under upcase readers). Package matters. This bites
  anywhere `(intern name pkg)` might find an inherited symbol
  instead of creating a fresh one — `:use` is a footgun for any
  package that wants to "own" common short names.

- **`sb-debug::print-frame-call` is internal SBCL** (double colon).
  No exported equivalent gives us the per-frame control we need
  (reverse order, custom truncation, our own readtable). This is
  the second time we've taken a dependency on it — flag if SBCL
  upgrades break.

- **`with-standard-io-syntax` resets the readtable.** Anywhere
  SBCL formats output that goes through that wrapper, our
  readtable-case settings won't reach. Lexical rebinding of
  `*readtable*` is the only reliable way to influence formatting.

- **Boot.lisp loads in `cl-user`**, not `:arc`. Anything in
  arc0.lisp that compares a symbol against `'arc-boot` (etc.) needs
  to compare by name, not by `eql` — the symbol may be in
  `cl-user`, not `:arc`. (See handoff `004` and `006` for prior
  bites of this same trap.)

## Current state

- Working tree: one ~5-line change in `arc0.lisp` to
  `arc-report-error`. Test suite green.
- `MEMORY.md` references this mission (Mission TKTK).
- Commit pending after this handoff.
