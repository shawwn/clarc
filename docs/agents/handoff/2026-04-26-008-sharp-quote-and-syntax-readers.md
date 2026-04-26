---
name: Sharp-quote and syntax reader macros
description: Added `#'x`, `` #`x ``, `#,x`, `#,@x` reader syntax to the arc reader, expanding to (function ...), (quasisyntax ...), (unsyntax ...), (unsyntax-splicing ...).
type: project
---

# Handoff: sharp-quote and syntax readers — 2026-04-26

Small reader extension. The user said "we'll have some interesting
things to do with them soon," so these forms are scaffolding — there
are no consumers yet for `function`, `quasisyntax`, `unsyntax`, or
`unsyntax-splicing`. They just intern as plain arc symbols.

## Change

In `arc0.lisp`, inside `arc-read-1`'s `#`-dispatch branch (around
line 210–225 before, ~210–235 after), added four new sub-dispatches
alongside the existing `#\`, `#(`, `#t`, `#f`, `#!`:

```lisp
((char= c2 #\')
 (list (intern "function" :arc) (arc-read-1 stream)))
((char= c2 #\`)
 (list (intern "quasisyntax" :arc) (arc-read-1 stream)))
((char= c2 #\,)
 (let ((next (peek-char nil stream nil nil)))
   (if (and next (char= next #\@))
       (progn (read-char stream)
              (list (intern "unsyntax-splicing" :arc)
                    (arc-read-1 stream)))
       (list (intern "unsyntax" :arc)
             (arc-read-1 stream)))))
```

The `#,@` lookahead mirrors how the top-level `,`/`,@` distinction
already works in `arc-read-1` (the existing comma branch a few lines
up).

## Verified

```
$ echo "(prn (quote #'foo))
(prn (quote #\`x))
(prn (quote #,x))
(prn (quote #,@x))
(prn (quote #'(a b c)))
(prn (quote #\`(1 #,x #,@y)))" | ./sharc
(function foo)
(quasisyntax x)
(unsyntax x)
(unsyntax-splicing x)
(function (a b c))
(quasisyntax (1 (unsyntax x) (unsyntax-splicing y)))
```

Test suite: `193 passed, 0 failed` — unchanged.

## Notes for whoever picks this up

- The four target symbols are interned by literal lowercase string
  in `:arc`, same convention as `quote`, `quasiquote`, `unquote`,
  `unquote-splicing` (line ~22-24 and the comma branch). If/when
  Mission TKTK lands and the arc reader case-folds via `:invert`,
  these literal `intern` calls will need uppercasing along with the
  rest of the list in handoff `007`.

- No semantics yet. `(function foo)` will currently try to evaluate
  `function` as a free variable and error — there's no special
  form, no global, no macro. Same for `quasisyntax`/`unsyntax`/
  `unsyntax-splicing`. The reader change is purely syntactic; the
  user signalled they'll wire up meaning in a follow-up.

- The naming aligns with Racket's `syntax`/`quasisyntax` family
  (Racket uses `#'`, `` #` ``, `#,`, `#,@` for that). If sharc
  ends up with a Racket-style macro system, these forms are the
  obvious surface syntax — but nothing in the current commit
  presumes that.
