---
name: ssyntax composes cleanly with CL pkg::name markers
description: Lets `pkg::name` segments survive inside compose / andf / sexpr ssyntax tokens. `(a:sb-thread::make-mutex)` now expands to `(compose a sb-thread::make-mutex)` and `(a&sb-thread::make-mutex)` to `(andf a sb-thread::make-mutex)`. Fixes a REPL hang where a mid-token reader error left stray `))` that re-triggered "Unexpected )" on every prompt forever.
type: project
---

# ssyntax + CL package markers — 2026-05-01

Reported by exercising the arc REPL: `(#'ac '(sb-thread:make-mutex))`
compiled fine, but `(#'ac '(a:sb-thread::make-mutex))` hung the REPL
spitting "Unexpected )" forever. Two compounding bugs in the reader and
ssyntax expander, plus a third missing-affordance once those were fixed.

## The three bugs

### 1. `cl-package-qualified-p` was too lenient

[`arc1.lisp`](../../../arc1.lisp) `cl-package-qualified-p` only rejected
a *second* `::` in the same token. Any other ssyntax char (`:` `~` `&`
`.` `!`) on either side of the `::` slipped through, and the reader
would call `intern-cl-qualified` on garbage like `a:sb-thread::make-mutex`
→ `(find-package "A:SB-THREAD")` → nil → error.

Fix: reject if either side of the `::` contains an ssyntax char.

```lisp
(defun ssyntax-char-p (c) (member c '(#\: #\~ #\& #\. #\!)))

(defun cl-package-qualified-p (str)
  (let ((p (search "::" str)))
    (and p (> p 0) (< (+ p 2) (length str))
         (not (find-if #'ssyntax-char-p str :end p))
         (not (find-if #'ssyntax-char-p str :start (+ p 2)))
         (not (search "::" str :start2 (+ p 2))))))
```

### 2. `arc-read-1` signalled "Unexpected )" without consuming the char

[`arc1.lisp`](../../../arc1.lisp) `arc-read-1` does
`(error "Unexpected )")` on a stray `)`/`]`/`}` *without* a `read-char`
first. After bug 1's reader error, the stream still held the trailing
`))`. The REPL handler in `arc-tl2` returned to read again, saw the
same `)`, errored, returned, saw the same `)`, ... infinite loop.

Even after bug 1 was fixed, any *future* mid-token reader error would
hang the REPL the same way. The defensive fix is in `arc-tl2`:

```lisp
(error (lambda (c)
         (arc-report-error c)
         (clear-input *standard-input*)
         (return-from iter)))
```

`clear-input` drops the rest of the buffered terminal line, matching
the existing Ctrl-C handler. After a read error, the user gets one
diagnostic and a fresh prompt.

### 3. `expand-ssyntax` dispatched on `:` even when it was inside `::`

Once 1 and 2 were fixed, `(a&sb-thread::make-mutex)` *still* hung —
this time as an infinite `ac` recursion.

Trace: the symbol contains `&` (andf) and `::` (cl marker). `expand-ssyntax`
checked `(or (find #\: n) (find #\~ n))` first, found the `:` from
`::`, and dispatched to `expand-compose`. `compose-tokens` correctly
keeps `::` runs glued, so the whole symbol became a single token,
which `chars->value` re-interned as the *same* arc symbol. `ac` saw
ssyntax again → `expand-compose` again → forever.

Fix: dispatch on `:` should ignore colons inside `::` runs.

```lisp
(defun find-outside-cl-marker (c str) ...)  ; skips `::` pairs while scanning

(defun expand-ssyntax (sym)
  (let ((n (symbol-name sym)))
    (cond
      ((or (find-outside-cl-marker #\: n) (find #\~ n)) (expand-compose sym))
      ((or (find #\. n) (find #\! n)) (expand-sexpr sym))
      ((find #\& n) (expand-and sym))
      ...)))
```

`~`, `&`, `.`, `!` can't appear inside `::`, so only `:` needed the
skip-logic.

## New affordances

`compose-tokens` (new): tokenises a chars list for compose, splitting
on a *single* `:` while keeping `::` glued. Replaces the
`(arc-tokens (lambda (c) (eql c #\:)) ...)` call in `expand-compose`.
Required because compose's separator is the same character that forms
the package marker; `expand-and` / `expand-sexpr` use `&` / `.` / `!`
respectively, so their splitters already leave `::` intact.

`chars->value` (updated): now checks `cl-package-qualified-p` first
and routes through `intern-cl-qualified` if so. This is what lets the
right-hand piece of a compose/andf/sexpr token (e.g.
`sb-thread::make-mutex`) intern as the real CL symbol from the
`sb-thread` package, not as a stringy arc symbol with `::` in its name.

## Cases now working

| Source | Expansion |
|---|---|
| `sb-thread::make-mutex` | reader path: real CL symbol via `intern-cl-qualified` (unchanged) |
| `a:sb-thread::make-mutex` | `(compose a sb-thread::make-mutex)` |
| `a&sb-thread::make-mutex` | `(andf a sb-thread::make-mutex)` |
| `~sb-thread::make-mutex` | `(complement sb-thread::make-mutex)` |
| `obj.sb-thread::field` | sexpr access on `sb-thread::field` |

## Tests

Added [`test.arc`](../../../test.arc) `ssyntax-with-cl-packages`:

```arc
(test? '(complement sb-thread::make-mutex) (ssexpand '~sb-thread::make-mutex))
(test? '(compose a sb-thread::make-mutex) (ssexpand 'a:sb-thread::make-mutex))
(test? '(andf a sb-thread::make-mutex) (ssexpand 'a&sb-thread::make-mutex))
(test? nil (~sb-thread::make-mutex))
(test? 1 (len:accum a (a:sb-thread::make-mutex)))
```

The last two exercise the values, not just the expansions: `~` of a
fresh mutex is nil, and `(a:sb-thread::make-mutex)` calls
`(compose a sb-thread::make-mutex)` which produces a single mutex
captured by `accum a`.

## What didn't change

- The reader path for plain `sb-thread::make-mutex` is unchanged. Both
  sides clean of ssyntax chars → `cl-package-qualified-p` t →
  `intern-cl-qualified` direct.
- `expand-and` / `expand-sexpr` still use the original `arc-tokens`
  splitter. Their separators don't conflict with `::`, so the new
  smart `chars->value` is enough on its own.
- `ssyntax-p` / `has-ssyntax-char-p` still naively scan for ssyntax
  chars without skipping `::`. An arc symbol like `|sb-thread::make-mutex|`
  (vbar-escaped, interned in `:arc`) would be flagged as ssyntax and
  hit `expand-ssyntax`, which now errors "Unknown ssyntax" cleanly
  rather than recursing or mis-dispatching. Acceptable: that token
  shape isn't expected and the error is informative.

## Files touched

| File | What landed |
|---|---|
| [`arc0.lisp`](../../../arc0.lisp) | `arc-tl2` error handler now `clear-input`s before returning |
| [`arc1.lisp`](../../../arc1.lisp) | `ssyntax-char-p`; `cl-package-qualified-p` rejects ssyntax chars on either side of `::`; `chars->value` routes pkg-qualified tokens through `intern-cl-qualified`; `compose-tokens` splits on single `:` keeping `::` glued; `find-outside-cl-marker` for dispatch; `expand-ssyntax` and `expand-compose` updated to use them |
| [`test.arc`](../../../test.arc) | `ssyntax-with-cl-packages` test |
