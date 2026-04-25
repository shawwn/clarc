# Handoff 018: `t` as a parameter, and `||` as the empty symbol — 2026-04-25

Two reader / compiler issues that surfaced while loading `news.arc`.
Both were blocking the load before any news code could run.

## 1. `t` could not be used as a function parameter

`(newsop submitlink (u t) ...)` (news.arc:1465) expands into a `fn`
whose argument list is `(u t)`. Previously the reader interned `t` as
`cl:t` (the CL truth constant), so the generated CL `lambda` had `T` in
its lambda list and SBCL refused with:

> `COMMON-LISP:T names a defined constant, and cannot be used in an
> ordinary lambda list.`

Fix:

- `arc-intern-token` (arc0.lisp:73) now interns the bare `"t"` token as
  `arc::t` — a regular bindable symbol — instead of `cl:t`.
- `ac` (arc0.lisp:401) translates a *free* `t` reference back to `cl:t`
  at expression position. When the symbol is lex-bound by an enclosing
  `fn`, it falls through to `ac-var-ref` and is treated as a normal
  variable.

Net effect: `t` still evaluates to truth in expressions, but it can now
appear as a parameter and references inside the body see the parameter
value.

Verified:

- `((fn (u t) (list u t)) 1 99)` → `(1 99)`
- `((fn (u t) t) 1 nil)` → `nil` (parameter, not the constant)
- `(let f (fn (u t) (list u t)) (f 1 99))` → `(1 99)`

## 2. `||` was being silently dropped by the reader

`(defop || req (pr "It's alive."))` (srv.arc:516) is the landing-page
op — its name is the empty-name symbol. Previously `arc-read-token`
returned an empty string for `||` and `arc-read-1` (arc0.lisp:228)
treated empty as "no token" and recursed, eating the *next* token as
the name. So the form was being read as `(defop req (pr "It's alive."))`
and erroring with `Can't understand fn arg list: "It's alive."`.

That stopped `srv.arc` at line 516 — so `defbg` (srv.arc:563) never got
defined, which is why `(defbg ...)` in news.arc looked like an unknown
macro. The two reports were the same root cause.

Fix:

- `arc-read-token` (arc0.lisp:54) now returns
  `(values string had-vbar-p)` — a second value that records whether
  any `|...|` segment was consumed.
- `arc-read-1` (arc0.lisp:226) uses that flag: if the token is empty
  *and* `|` was seen, intern as `(intern "" :arc)` (the empty-name
  symbol). Empty *without* vbar still recurses, preserving the old
  guard against zero-progress reads.

This reverses the `||` → `nil` choice from handoff 012. That choice
matched no real Arc code: `||` in mzscheme is the empty symbol, and Arc
code (news/srv) actually uses it.

`|nil|` and `|t|` still collapse to `nil` / `arc::t` via
`arc-intern-token`. The only behavior change is for `||` itself.

Verified:

- `(is '|| '||)` → `t`
- `(no '||)` → `nil`
- `(type '||)` → `sym`
- `(tostring:write '||)` → `""`

## Test status

- `test.arc`: 193 passed, 0 failed.
- `(load "news.arc")` runs to completion (362 forms).

## Files changed

- `arc0.lisp:54-71` — `arc-read-token` returns `(values tok had-vbar)`.
- `arc0.lisp:73-77` — `arc-intern-token` interns `"t"` as `arc::t`.
- `arc0.lisp:226-232` — `arc-read-1` handles empty-with-vbar as `||`.
- `arc0.lisp:399-401` — `ac` only rewrites *free* `t` to `cl:t`.
