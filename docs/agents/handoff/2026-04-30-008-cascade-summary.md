---
name: User-arg cascade — summary
description: A single-document overview of the user-arg cascade in [PR #1](https://github.com/shawwn/sharc/pull/1), aimed at a reader who wants the design narrative rather than the commit-by-commit play-by-play. Implements [dang's HN comment 11242977](https://news.ycombinator.com/item?id=11242977): replace the `user` parameter threaded through hundreds of news.arc / app.arc / blog.arc / prompt.arc functions with a per-request thread-local read via `(the me)` (and `(me)`, `(ip)`, `w/me`, `(t var)` parameter forms). 36 commits, ~600 call sites, 229/229 tests pass throughout.
type: project
---

# User-arg cascade — summary

## What this is

In [HN comment 11242977](https://news.ycombinator.com/item?id=11242977),
dang noted that news.arc's habit of threading the current viewer's
username (`user`) through every function signature, call site, and
predicate could be eliminated. This PR does that.

The mechanism is a per-thread key-value store with a few small
affordances:

```arc
(the me)             ; read the current request's user
(= (the me) user)    ; set it
(w/the me val ...)   ; bind for body, restore after
(me)                 ; same as (the me); 0-arg shorthand function
(me other)           ; (the me) only if it equals other; nil otherwise
                     ; -- doubles as predicate-and-value
(ip)                 ; same shape, for the request IP
(def f ((t me)) ...) ; me defaults to (the me) if caller omits arg
(def f ((t local var)) ...) ; local defaults to (the var)
```

The arc-level primitives `(the var)` / `(t var)` / `w/the` were
added in a [previous handoff](./2026-04-30-001-thread-locals-news-arc-style.md);
the application-layer helpers `(me)` / `(ip)` / `w/me` and the
sweep across news.arc / app.arc / blog.arc / prompt.arc are this
PR.

## A worked example

Before, `cansee` looked like this everywhere it appeared:

```arc
(def cansee (i user)
  (if i!deleted   (admin user)
      i!dead      (or (author i user) (seesdead user))
      (delayed i) (author i user)
      t))
```

And every caller passed `user` explicitly:

```arc
(when (cansee s user) ...)
(keep [cansee _ user] stories*)
(or (cansee c user)
    (some [cansee-descendant (item _) user] c!kids))
```

After:

```arc
(def cansee (i (t user me))
  (if i!deleted   (admin user)
      i!dead      (or (author i user) (seesdead user))
      (delayed i) (author i user)
      t))
```

The body is unchanged — `user` is still a local, used the same way.
What changed is that callers can now omit it:

```arc
(when (cansee s) ...)
(keep [cansee _] stories*)
(or (cansee c)
    (some [cansee-descendant (item _)] c!kids))
```

Same with the rest of the predicate family (`canvote`, `canedit`,
`candelete`, `editor`, `admin`, `member`, `noob`, `seesdead`,
`visible`, `cansee-descendant`, `visible-family`, `author`,
`legit-user`, `possible-sockpuppet`, `bad-user`, `check-key`,
`profile`, `votes`, `karma`, `ignored`, `noobspage`, `recent-votes-by`).
Each one accepts a target user or defaults to the viewer.

For the rare callers that *do* pass a non-default user — admin
viewing somebody else's profile, ranking computations on
authored items — the override still works.

## A second worked example: closure capture

Forms and links are tricky because their bodies execute *at submit
time*, not render time. The old code threaded `user` lexically so
the closure body referenced the render-time user; the new
`(me)`-inside-the-closure-body would read the submitter, not the
renderer.

Before:

```arc
(mac uform (user after . body)
  `(aform (when-umatch ,user ,after) ,@body))
```

Callers had to provide the captured render-time user:

```arc
(uform user                     ; the form's CSRF token
       (process-story user      ; the submit-handler
                      (clean-url arg!u) ...)
  ...form widgets...)
```

After:

```arc
(mac uform (after . body)
  (w/uniq g
    `(let ,g (me)             ; capture render-time (the me)
       (aform (when-umatch ,g ,after) ,@body))))
```

The macro itself does the lexical capture into a gensym, so the
fnid thunk closes over a render-time value without requiring
the caller to thread it through. Callers become:

```arc
(uform (process-story (clean-url arg!u) ...)
  ...form widgets...)
```

Same CSRF semantics (when-umatch checks the captured render-time
user against submit-time `(the me)`), but no caller needs to know
about the capture. Same pattern for `urform`, `ulink`, `urlink`,
`comment-form`, and the manual closure sites in `admin-page`,
`vars-form`, `prompt-page`.

## The layers

The cascade ran in waves, each making the next possible:

### Layer 1 — Predicates (`cansee` / `canvote` / `canedit` / `candelete` / `author` / `editor` / `admin` / `member` / `noob` / `seesdead` / `visible` / `cansee-descendant` / `visible-family`)

The foundation. Once these accept `(t user me)`, hundreds of
call sites across news.arc can drop their user argument. The
internal `user` references inside each predicate body keep
working — the parameter is bound, just defaulted.

### Layer 2 — Login refresh + form macros

Two changes that unlocked everything else:

1. `app.arc`'s `(def login ...)` now sets `(= (the me) user)`
   right before firing the post-login callback. Before this fix,
   the post-login callback ran with `(the me) = nil` (cookie was
   still being set in the response) and code that read `(the me)`
   saw stale data. After: callbacks see the freshly-authenticated
   user. The previous workaround in `admin-gate` (a `(t me)` +
   `w/me` dance) collapsed back to `(def admin-gate () ...)`.

2. `uform` / `urform` / `ulink` / `urlink` macros do the
   render-time capture themselves. Six call sites in news.arc
   (`del-confirm-page`, `submit-page`, `newpoll-page`,
   `add-pollopt-page`, `resetpw-page`, `scrub-page`) plus three
   in prompt.arc dropped their explicit user threading.

### Layer 3 — Display dispatcher chain

`display-item`, `display-story`, `display-pollopts`,
`display-pollopt`, `display-comment`, `display-comment-tree`,
`display-1comment`, `display-subcomments`, `display-comment-body`,
`gen-comment-body`, `cached-comment-body`, `display-threads`,
`display-selected-items`, `displayfn*` table entries,
`titleline`, `titlelink`. Roughly 30 sites. None of these
display functions take a user parameter anymore; bodies use
`(me)` and helper-defaults exclusively.

### Layer 4 — Page-template macros

`longpage`, `shortpage`, `fulltop`, `pagetop`, `main-color`,
`toprow`, `topright`, `check-procrast`, `procrast-msg`,
`admin-bar`. The `newscache` macro (which generates the
ratelimited cache wrappers around `newspage`, `newestpage`,
`bestpage`, etc.) now wraps the body with `(w/me ,user ...)` so
the cached-anonymous fill renders with `(the me)` bound to nil,
not whichever user happened to populate the cache.

### Layer 5 — Security-capturing fnid leaves

`votelinks`, `votelink`, `vote-url`, `flaglink`, `killlink`,
`blastlink`, `comment-form`. These render fnid links/forms that
fire actions at click/submit time. The closure-capture pattern
(see "second worked example" above) keeps the render-time user
in scope so the action records the correct actor regardless of
URL sharing. (Modulo the explicit choice in flaglink/etc. to
record the *clicker*, not the renderer — the inner closure now
reads `(me)` rather than the captured `user`. Discussed in
[handoff 007's CSRF section](./2026-04-30-007-me-ip-helpers.md).)

### Layer 6 — Action helpers and data writers

The mirror of layer 3 on the action side. `vote-for`,
`submit-item`, `oversubmitting`, `story-ban-test`,
`site-ban-test`, `ip-ban-test`, `comment-ban-test`,
`toggle-blast`, `log-kill`, `set-ip-ban`, `set-site-ban`. The
data writers (`create-story`, `create-poll`, `create-pollopt`,
`create-comment`) drop their explicit user/ip parameters and
read from thread-locals when constructing the item record.

### Layer 7 — Thread-local plumbing

`newslog` reads `(the ip)` and `(the me)` itself, so its ~10
callers stop passing them. Same for `ensure-news-user`. All 8
`(hook ...)` calls drop the viewer-user arg (the `'user` hook
keeps its trailing target-user data arg, since that's actually
data). Post-login callbacks `(fn (u ip) ...)` collapse to
`(fn () ...)` because `app.arc`'s `login` now invokes
`(afterward)` with no args after refreshing the thread-local.

## Sharp edges discovered along the way

A few subtleties that aren't obvious from reading the code, in
no particular order:

### `(t var me)` doesn't propagate to helpers

A function declared `((t user me) ...)` binds a local `user`,
but if its body calls a helper that *also* has `(t u me)`, the
helper reads `(the me)` independently, *not* the caller's
override. Concretely:

```arc
(def cansee (i (t user me))
  (if i!dead (or (author i) (seesdead user))  ; <-- BUG
      ...))
```

If `cansee` is called with an override (e.g. via
`(visible-family s nil)` to compute "what does an anonymous
viewer see?"), the `(seesdead user)` correctly uses the
override but `(author i)` reads `(the me)` — the *actual*
viewer. The author check fires for the actual viewer's items,
inflating the visible-family count.

Fix: thread `user` explicitly to helpers.

```arc
(def cansee (i (t user me))
  (if i!dead (or (author i user) (seesdead user))
      ...))
```

This bit four functions (`cansee`, `canvote`, `own-changeable-item`,
`vote-for`) — all caught and fixed in a single commit. The
`cansee` instance was the only observable bug (the others were
called only with no override).

### Macros need `(o u '(me))`, not `(t u me)`

`(t var)` desugars to `(o var (the var))`, which means the
default `(the me)` is *evaluated at expansion time* for
functions, but for macros the same form would evaluate at
*compile time* — which is when `(the me)` is nil. So macros
need to explicitly quote the form:

```arc
(mac karma   ((o u '(me))) `(uvar ,u karma))
(mac ignored ((o u '(me))) `(uvar ,u ignore))
```

The quoted `(me)` survives into the expansion as a literal form
and gets evaluated at runtime. Documented inline so the next
person who adds a `(t u me)`-style default to a macro doesn't
hit the same trap.

### `&` and `~` don't compose in arc's ssyntax

`cansee&bynoob` works (an `andf` composition). `~subcomment`
works (a `complement`). But `cansee&~subcomment` hangs the loader
in an infinite expansion loop: `expand-ssyntax` sees the `~`
first and routes to `expand-compose`, which only splits on `:`,
returns the same `&`-bearing token, and `ac` re-expands it.
Three sites collapsed cleanly to `&` ssyntax; the fourth had to
stay as `[and (cansee _) (~subcomment _)]`. Worth a small fix in
`arc1.lisp` someday — make `expand-ssyntax` decompose `&` first,
or have `expand-compose` recognize nested `&`-tokens.

### Cache fills must override `(the me)`

`newscache`'s old expansion ran the body with the local `user`
bound to nil, producing the cached anonymous output. After the
sweep, the body reads `(the me)` instead of `user` — but
`(the me)` is whatever the thread populating the cache happened
to be. So a logged-in user triggering a cache miss would have
their identity leak into the cached HTML served to anonymous
visitors. The fix is to wrap the cache fill with `(w/me nil ...)`
so the body always sees a nil `(the me)` regardless of who
triggered the fill. The fresh-render path uses `(w/me ,user ...)`
to ensure the body sees the user-arg-driven value (which equals
`(the me)` already, but explicit makes it match the cache-fill
shape).

### `flaglink`'s `(isnt user i!by)` semantic

Translating `(isnt user i!by)` into the new helpers requires
`(no (me i!by))` (or equivalently `(~me i!by)`), not `(me i!by)`.
The latter is "I am the author"; the former is "I am NOT the
author". Got the wrong direction in one commit, caught in
review. Same gotcha for any predicate that's logically negated.

### `(admin user)` as a free-variable reference

`deadmark` had a longstanding `(admin user)` in its body where
no `user` was lexically bound. It worked because:

1. `(admin user)` only fires when `i!deleted`, an uncommon
   render-time path.
2. When it does fire, `user` resolves to a global lookup — and
   there's no global `user`, so it would error.

But the path was untested. Replaced with `(admin)` which
defaults to `(the me)`. Latent bug fixed.

### Login flow has stale `(the me)` mid-request

In the request that *completes* login, `(the me)` is still nil
when the handler starts. The submitted form has username +
password in the body; `respond` reads `(the me)` from the
request *cookies*, which are still empty (the cookie is being
set in the response, not the request). So when `good-login`
authenticates and calls the post-login `afterward`, the
callback runs with `(the me) = nil`. The fix lives inside
`(def login ...)` — set `(= (the me) user)` after `prcookie`
but before invoking the callback. Any new auth path that
doesn't go through `login` would re-introduce the issue.

## What was deliberately not touched

After the sweep, these `user` references remain — and should:

- **Target-user data parameters**. `(threads-page user)`,
  `(submitted-page user)`, `(user-page user)`, `(submissions
  user)`, `(saved-link user)`, `(uvar user x)`, `(karma user)`,
  `(votes user)`, etc. The `user` here is *whose threads/page/
  votes are being looked up*, not the viewer. Conflating these
  with the viewer was the original sin; preserving them is the
  point.

- **`opexpand`'s `(with (user (the me) ip (the ip)) ...)`
  binding**. Newsop bodies use `user` and `ip` as locals — `(if
  user ...)`, `(when (admin user) ...)` etc. The locals are
  ergonomic and idiomatic for newsop bodies. Stripping the
  binding would just force every newsop to read `(me)` and
  `(ip)` directly, which is more verbose for no real gain.

- **`when-umatch` / `when-umatch/r`**. The CSRF primitives still
  take `user` explicitly because the *capture* belongs at the
  call site (typically inside `uform` / `urform` / `ulink` /
  `urlink` macros that do their own `(let g (me) ...)`). The
  user passed to `when-umatch` is the captured render-time
  value.

- **`save-prof` and `save-votes`**. Targeted writes — explicit
  user makes intent clear at call sites. `(save-prof i!by)`
  saves the item's author's profile; `(save-prof (me))` saves
  the current user's. Defaulting `save-prof` to `(me)` would
  obscure that distinction.

## A note on the closures

A subtle behavior change worth flagging for anyone reading the
diff: in security-capturing fnid leaves like `flaglink`,
`killlink`, `blastlink`, the rlinkf body that fires at click time
used to reference a closure-captured `user` (the renderer). The
new code references `(me)` directly inside the closure, which
reads the *clicker* at submit time.

For private fnids (the normal case where the URL is only seen by
the rendering user), there's no observable difference. For
shared URLs, the new behavior is arguably more correct: actions
get recorded against the user who actually clicked, not the user
who happened to render the page that contained the URL. But it's
a real behavioral change and worth knowing about.

`uform` / `urform` / `ulink` / `urlink` and `comment-form` are
unaffected — they explicitly capture `(me)` into a lexical via
`(let g (me) ...)`, and the closure body references `g`, not
`(me)`. So the captured render-time user is preserved.

## Index

For depth on any layer, the per-layer handoffs are:

- [`2026-04-30-001-thread-locals-news-arc-style.md`](./2026-04-30-001-thread-locals-news-arc-style.md)
  — implementation of `(the var)` / `(t var)` / `w/the` / `w/me`
- [`2026-04-30-002-news-arc-thread-local-refactor.md`](./2026-04-30-002-news-arc-thread-local-refactor.md)
  — first sweep of srv/app/blog/prompt/news using thread-locals
- [`2026-04-30-003-arg-defop-fnid-thunk-refactor.md`](./2026-04-30-003-arg-defop-fnid-thunk-refactor.md)
  — `arg!foo`, form-macros-as-expressions, defop drops `req`
- [`2026-04-30-004-dang-user-subject-cascade.md`](./2026-04-30-004-dang-user-subject-cascade.md)
  — eight-commit breakdown of the predicate-family cascade
- [`2026-04-30-005-session-summary-coroutines-thread-locals.md`](./2026-04-30-005-session-summary-coroutines-thread-locals.md)
  — multi-day session summary covering the start of this work
- [`2026-04-30-006-user-arg-cascade-complete.md`](./2026-04-30-006-user-arg-cascade-complete.md)
  — meta-summary of the layer-by-layer commits through `3cd2302`
- [`2026-04-30-007-me-ip-helpers.md`](./2026-04-30-007-me-ip-helpers.md)
  — `(me)` and `(ip)` helper functions; CSRF capture rule

The PR is [#1](https://github.com/shawwn/sharc/pull/1). Files
of interest after the cascade:
[`news.arc`](../../../news.arc),
[`app.arc`](../../../app.arc),
[`blog.arc`](../../../blog.arc),
[`prompt.arc`](../../../prompt.arc),
[`srv.arc`](../../../srv.arc),
[`arc.arc`](../../../arc.arc),
[`arc1.lisp`](../../../arc1.lisp).

## The numbers

- **36 commits** in the cascade ([`4422c22`](https://github.com/shawwn/sharc/commit/4422c22)
  through [`3821287`](https://github.com/shawwn/sharc/commit/3821287)),
  not counting the 7 prior commits that landed the underlying
  primitive.
- **~600 user-argument call sites** removed, by my counting.
- **229/229 tests pass** at every commit. Smoke-tested ~30 routes
  anonymous and logged-in after each layer (handoffs `006` and
  `007` list the exact route inventory).
- **Two latent bugs caught** along the way: the `cansee` author
  propagation (would've inflated `contro-factor` for
  authored-but-dead items) and the `deadmark` free-variable
  reference (would've errored on `[deleted]` rendering for
  admins).
