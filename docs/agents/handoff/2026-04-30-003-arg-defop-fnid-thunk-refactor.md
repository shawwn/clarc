---
name: arg, defop, and fnid contract simplifications
description: Three follow-up commits to the news.arc thread-local refactor. (1) `arg` reads `(the req)` so callers write `arg!foo` instead of `(arg req "foo")`. (2) The form macros (`aform` / `arform` / `taform` / `tarform` / `aformh` / `arformh`) take a body expression instead of a `(fn (req) ...)`. (3) `defop` and its variants drop their request-parameter, and the fnid contract uniformly uses thunks. Commits 6b098dc, 5113ec3, 09a31e8.
type: project
---

# Handoff: arg / defop / fnid simplifications — 2026-04-30

Three commits on top of the thread-local sweep in
`2026-04-30-002`. Each removes a layer of explicit request-passing
that the thread-locals made redundant.

## Commit 1 — `arg!foo` (`6b098dc`)

`arg` is now a one-arg function that reads `(the req)` and accepts
either a symbol or a string key:

```arc
(def arg (key)
  (let req (the req)
    (alref req!args (if (isa key 'sym) (string key) key))))
```

Three call shapes work:

```arc
arg!foo        ; arc bang ssyntax: (arg 'foo)
(arg 'foo)     ; symbol key
(arg "foo")    ; string key
```

All 27 `(arg req "FOO")` call sites swept across app/blog/news/
prompt/srv. `news.arc`'s `opexpand` now emits `(arg 'NAME)` for
declared op params instead of `(arg gr STR)`.

## Commit 2 — form macros take a body (`5113ec3`)

`aform`, `arform`, `taform`, `tarform`, `aformh`, `arformh` no
longer expect a `(fn (req) ...)` value as their first argument.
They take a *handler expression* directly. The macro internally
wraps it in a one-arg fn for the fnid contract.

```arc
;; Before
(aform (fn (req) (when-umatch user (do-thing arg!x)))
  form-body)

;; After
(aform (when-umatch user (do-thing arg!x))
  form-body)
```

Other simplifications in the same commit:

- `login-handler` and `create-handler` drop their `req`
  parameter (they never used it after the refactor).
- `vars-form`'s submit code reads `(the req)!args` via
  `let`-binding, dropping the function-parameter `req`.
- `uform` / `urform` expand to a single line — `(aform
  (when-umatch user after) body)` — no fn wrap.

## Commit 3 — defop drops its req param; fnid uses thunks (`09a31e8`)

The big one. Two coupled changes:

### `defop` and friends drop the request-parameter name

```arc
;; Before
(defop foo req
  (do-thing arg!x))

(defopl bar req
  (when-something))

;; After
(defop foo
  (do-thing arg!x))

(defopl bar
  (when-something))
```

Bodies that genuinely need the request can use `(the req)`. None
of the existing 27 call sites needed that — `arg!key`, `(the me)`,
`(the ip)` cover everything in practice.

`opexpand` (the `newsop` builder) updates correspondingly:

```arc
(mac opexpand (definer name parms . body)
  `(,definer ,name
     (with (user (the me) ip (the ip))
       ...)))
```

### fnid stored fns are now thunks

`/x`, `/y`, `/a`, `/r` dispatch with `(it)` not `(it req)`.
`flink`, `rflink`, `linkf`, `rlinkf`, `ulink`, `afnid`, `fnform`
all wrap or accept thunks. This collapses several previously
parallel idioms onto one form:

```arc
;; Before
(linkf text (req) body...)
(rlinkf text (req) body...)
(ulink user text (when-umatch user body))   ; with hidden gensym parm

;; After
(linkf text body...)
(rlinkf text body...)
(ulink user text body...)
```

The `(req)` parameter list is gone everywhere; bodies that need
the request use `(the req)`, but in practice none do.

## Why thunks for fnid?

Two reasons:

1. **Consistency with the form macros.** Once `aform` etc. stop
   passing `req` to user handlers, having `linkf`/`rlinkf`/`afnid`
   still pass `req` is incongruous --- the same body that you'd
   put inside an `aform` is what you'd put inside a `linkf`, but
   the parameter shape used to differ.

2. **Removes an arc-specific idiom that didn't compose well.**
   The `(linkf TEXT (req) body)` form had a parameter list in the
   middle of an otherwise-clean call shape. Now `linkf` reads as
   "a clickable thing with this text that does this body" --- no
   ceremony.

The cost is one extra `let req (the req)` line in any future
helper that genuinely needs the request. None do today.

## What's still threaded explicitly (and why)

Same answer as `2026-04-30-002`:

- Functions that take a *user* parameter representing some
  arbitrary user (subject of a profile page, item author for
  permission checks, recipient of an action) keep it.
- Functions where the `user` parameter is *always* the current
  actor and only forwarded could potentially drop it for
  `(the me)`, but the per-page rendering layer (`display-item`,
  `submitted-page`, `listpage`, `noobspage`, etc.) is left
  alone --- the call sites occasionally use a different user
  for admin-tooling paths, and the parameter form is
  self-documenting.

Rule of thumb: if you can name a plausible call site that
passes a user other than the current actor, keep the parameter
explicit. If the parameter is *always* the current actor and
exists purely to forward through, drop it.

## A pre-existing bug uncovered while testing

While running smoke tests against the news server I saw
`Function call on non-function: NIL` for any logged-in user
whose cookie pointed to a username that existed in
`hpasswords*` but had no entry in `profs*`/`profdir*`. This
happens for users created via `app.arc`'s plain
`(login-page 'login)` form, which doesn't fire news.arc's
`ensure-news-user` callback.

Not from this refactor --- the same chain existed before.
Fixed in `24a0c1b` (`profile` auto-calls `init-user` for any
valid user that's missing a news profile). Documented in
`2026-04-30-002`.

## Sharp edge: don't /logout in smoke tests

`/logout` invokes `logout-user` which removes the current user
from `cookie->user*` and saves the table. Running the news
server, hitting `/logout`, and then exiting writes an empty
table to `arc/cooks` --- leaving any browser cookie pointing at
the test user stranded.

If you need to test the logout path, save a copy of `arc/cooks`
first and restore after, or mint a one-shot cookie just for the
test. (For the current dev session I restored
`((s1BBrWVp "test"))` by hand --- the user's browser cookie is
named explicitly so we know what to write.)

## Net diff

Across all six commits in this thread (from `3a50b30` to
`09a31e8`):

| File | -/+ |
|------|-----|
| `app.arc` | -149 / +144 |
| `news.arc` | -178 / +160 |
| `blog.arc` | -39 / +28 |
| `prompt.arc` | -184 / +175 |
| `srv.arc` | -83 / +91 (gained the thread-local bindings) |

Net call-site simplification is much larger than the line count
suggests because most of the line-count change is comments
(headers explaining the new conventions) and the few small
runtime additions (`thread-locals*`, `the` / `w/the` / `w/me`,
the new `arg` shape, the form-macro reshapes).

## Open work

- Could extend the simplification pass to per-page rendering
  helpers (`display-item`, `listpage`, etc.) that take `user`
  as the viewer. Held off because some are occasionally called
  with a non-current user.
- The `defopt`-style login callbacks still pass
  `(fn (u ip) (ensure-news-user u))` as the post-login
  `afterward`. After the `profile` auto-init bug fix, this is
  redundant but defensive --- left alone.
