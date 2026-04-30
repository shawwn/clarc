---
name: User-arg cascade complete — full sweep across news.arc / app.arc
description: Meta-summary of the full multi-day refactor that removes the transient `user` parameter from news.arc / app.arc by leaning on `(the me)` and `(the ip)` thread-locals and the `(t user me)` parameter form. Indexes all 14 commits from `4422c22` through `3cd2302`, the layers they touched, the sharp edges discovered, and what was intentionally left alone.
type: project
---

# User-arg cascade complete — 2026-04-28 → 2026-04-30

This is the meta-summary for the whole cascade that removed transient
`user` (and where applicable `ip`) parameters from news.arc / app.arc.
The cascade started 2026-04-28 with the predicate family
(`cansee` / `canvote` / etc.) and finished 2026-04-30 with
small-leaf cleanups in newscache pages and `vote-url`. Every commit
is indexed below; read this file to orient, then jump to the focused
sub-handoff or commit for detail.

The starting context is in handoff `2026-04-30-001-thread-locals-news-arc-style.md`,
which landed `(the var)` / `(t var)` and the per-thread hash that
backs them. Handoffs `002`, `003`, `004` documented the first
waves; handoff `005` was the multi-day session summary. This doc
extends the picture forward through the second half (commits
`5dbb85c` … `3cd2302`).

## What was the goal

Implement [dang's HN comment 11242977](https://news.ycombinator.com/item?id=11242977):
make news.arc as small as it can be by reading the current user from
a thread-local instead of threading it through every wrapper, helper,
display function, page macro, hook, and post-login callback.

The mechanism is the `(the var)` / `(t var)` primitive (see handoff
`001`), which lets a function declare `((t user me) ...)` and have
`user` default to `(the me)` when the caller doesn't supply one.
Functions that *render fnid closures* (forms, links) bind a local
`user` to the render-time `(the me)` so the captured closure
preserves the existing CSRF semantics — the closure's `user`
value is fixed at render time, not re-read at submit time.

## Files that changed

| File | Aggregate over the cascade |
|---|---|
| `app.arc` | `login` refreshes `(the me)` before firing the post-login callback; `uform` / `urform` macros take the user implicitly via render-time `(the me)` capture; `admin-gate` collapsed to `(def admin-gate () ...)`; `hello-page` (default afterward) reads thread-locals; post-login callback contract dropped from `(fn (u ip) ...)` to `(fn () ...)` |
| `news.arc` | predicates / display chain / page-template macros / security-capturing fnid leaves / action-side helpers / data writers all stop threading user; ~600 call sites swept; `newslog` reads `(the ip)` and `(the me)` itself; `ensure-news-user` reads `(the me)`; all `(hook ...)` calls drop the viewer-user arg; newscache pages take `(t user me)` so newsop callers drop the `user` arg |

229/229 tests pass throughout. News server smoke-tested for ~30
routes anonymous and logged-in after each layer.

## The layers, in order, with commit anchors

### Layer 0 — Predicate family (2026-04-30, before this session)

- **`4422c22`** — `cansee` / `canvote` / `canedit` / `candelete`
  / `visible` / `cansee-descendant` / `visible-family` take
  `(t user me)`. This is the foundation; every later layer relies
  on these predicates defaulting their user.

- **`5099bba`** — drop now-unused `user` from wrapper functions
  whose only use of user was passing it to the predicate family.

- **`faa5919`** — drop user from leaf story selectors
  (`live-story-w/url`, `frontpage-rank`, etc.).

- **`d00cb53`** — drop user from `listpage`; pass `(the me)`
  explicitly to `longpage` / `display-items` (this is reverted /
  generalized in later layers).

- **`5fec670`** — drop user from `display-items` /
  `display-threads` / `morelink`.

- **`6d83532`** — `admin-bar` drops user; `longpage` macro stops
  forwarding `,gu` to it.

These layers are documented in detail in handoffs `002`, `003`,
`004` and the `005` session summary. The eight-commit breakdown
in `004` is the cleanest reference for that wave.

### Layer 1 — Login + uform/urform (commit `5dbb85c`)

Two changes that unlocked the rest:

1. `(def login ...)` in app.arc now sets `(= (the me) user)` after
   `prcookie`. Before this, the post-login callback fired with
   `(the me) = nil` because the request thread's `(the me)` is
   read from the *request* cookies (still empty / stale), not the
   response's `Set-Cookie`. After this, every callback path
   (`login-handler`, `create-handler`) sees the freshly-logged-in
   user in `(the me)`.

2. `uform` / `urform` macros lose their `user` parameter and
   capture render-time `(the me)` into a `w/uniq` lexical, which
   the fnid thunk closes over. Six call sites in news.arc updated:
   `del-confirm-page`, `submit-page`, `newpoll-page`,
   `add-pollopt-page`, `resetpw-page`, `scrub-page`.

   The lexical `let` is *necessary*: if we inlined `(the me)` into
   the `aform` body it would re-read at submit time (the submitter)
   and `when-umatch` would trivially succeed, defeating CSRF.

`admin-gate` collapses back to `(def admin-gate () ...)`; the
`(t me)` + `w/me` workaround (admin-gate's only consumer) is
retired.

### Layer 2 — urform-rooted helpers (commit `13331a8`)

The functions invoked by `urform` / `uform` and the page wrappers
that contain those forms. All drop their `user` parameter:

| Function | Before | After |
|---|---|---|
| `resetpw-page` | `(user (o msg))` | `((o msg))` |
| `try-resetpw` | `(user newpw)` | `(newpw)` |
| `scrub-page` | `(user rules (o msg))` | `(rules (o msg))` |
| `del-confirm-page` | `(user i whence)` | `(i whence)` |
| `add-pollopt-page` | `(p user)` | `(p)` |
| `add-pollopt` | `(user p text ip)` | `(p text ip)` |
| `addoptlink` | `(p user)` | `(p)` |
| `newpoll-page` | `(user (o title) ...)` | `((o title) ...)` |
| `process-poll` | `(user title text opts ip)` | `(title text opts ip)` |
| `submit-page` | `(user (o url) ...)` | `((o url) ...)` |
| `process-story` | `(user url title ...)` | `(url title ...)` |

All flink-bracket closures inside these were updated too. The
post-login callback in `submit-login-warning` no longer needs
`(t me)` + `w/me` because of the Layer 1 login fix.

### Layer 3 — Display chain & page macros (commit `56382e0`)

The big one. Three sub-layers:

**Page-template macros** drop user; `newscache` wraps the body
with `w/me` so cache fills don't leak the cache-populating user's
identity into anonymous cached HTML:

- `longpage`, `shortpage`, `fulltop`, `pagetop`
- `main-color`, `toprow`, `topright`, `check-procrast`,
  `procrast-msg` → `(t user me)`
- `newscache` macro now generates
  `(let ,user nil (w/me ,user ,@body))` for the cache filler and
  `(w/me ,user ,@body)` for the fresh path.

**Display dispatcher chain** drops user:
- `display-item`, `display-story`, `display-pollopts`,
  `display-pollopt`
- `display-comment`, `display-comment-tree`, `display-1comment`,
  `display-subcomments`, `display-comment-body`,
  `cached-comment-body`, `gen-comment-body`
- `display-threads`, `display-selected-items`
- `displayfn*` table entries
- `titleline`, `titlelink`

**Security-capturing fnid leaves** use `(t user me)` to preserve
closure capture:
- `votelinks`, `votelink`, `flaglink`, `killlink`, `blastlink`,
  `comment-form`, `process-comment`

**Page wrappers** drop user:
- `item-page`, `edit-page`, `addcomment-page`,
  `comment-login-warning`, `newsadmin-page`
- `note-baditem`, `ignore-edit`, `fieldfn*` table entries

### Layer 4 — Thread-local plumbing (commit `8243200`)

Generalize the thread-local read pattern across the rest of the
plumbing:

- `newslog` reads `(the ip)` and `(the me)` itself; ~10 callers
  drop those args. `logvote` drops both ip and user params.
- `ensure-news-user` reads `(the me)`; 6 callers drop the arg.
- All 8 `(hook ...)` calls drop the viewer-user arg. The
  `'user` hook keeps its trailing target-user data arg.
  `pagefns*` invocation simplified to `(each f pagefns* (f))`.
- 7 post-login callbacks `(fn (u ip) ...)` → `(fn () ...)`.
  app.arc's `login` invokes `(afterward)` / `(f)` without args.
- The vote-login callback simplifies further: `canvote i dir`,
  `vote-for (the me) i dir`, `logvote i`.

### Layer 5 — Action helpers & data writers (commit `1779c15`)

Mirror of Layer 3, but on the write/action side rather than the
display side.

**Action helpers** — `(t user me)` or read thread-locals:
- `vote-for` → `(i (o dir 'up) (t user me))`
- `submit-item` → `(i (t user me))`
- `oversubmitting` → reads `(the me)` and `(the ip)`
- `story-ban-test`, `site-ban-test`, `ip-ban-test`,
  `comment-ban-test`
- `toggle-blast` → `(t user me)` for closure
- `log-kill` → `(o how (the me))` so manual callers can omit
- `set-ip-ban` / `set-site-ban` — param renamed `user` → `actor`
  and `(t actor me)`. `maybe-ban-ip`'s system-ban call passes nil
  explicitly to record "no human actor".

**Data writers** drop user/ip params:
- `create-story`, `create-poll`, `create-pollopt`, `create-comment`
  read `(the me)` / `(the ip)` directly when constructing the item
  record.

`process-story`, `process-poll`, `process-comment`, `add-pollopt`
themselves drop their ip parameters.

### Layer 6 — Small-leaf cleanups (commit `3cd2302`)

- newscache pages take `(t user me)`; callers drop the explicit
  user arg (`(newspage user)` → `(newspage)`).
- `noobspage`'s user param was dead — removed.
- `vote-url` takes `(t user me)`; `votelink` call simplifies.
- `hello-page` (login's default afterward) reads thread-locals.

## Sharp edges discovered

These all bit during the cascade and are documented inline; gathered
here so a future agent doesn't have to rediscover them:

- **`/logout` wipes `arc/cooks`.** Save it before any smoke test
  that hits `/logout` (or the logout fnid). Restore format is
  `((COOKIE_SYMBOL "username"))` — symbol unquoted. Or
  `/bin/cp /Users/shawn/ml/sharc/arc/cooks /tmp/cooks.bak` before
  and back after.

- **The login-completion request has stale `(the me)`.** Login
  authenticates via the POST body; the new cookie is *set in the
  response* but never read by the current request thread. Before
  Layer 1, post-login callbacks had to either (a) take `(t me)`
  + `w/me` like `admin-gate` did, or (b) read user from the
  callback's `u` parameter that `login` passed in. Layer 1's
  one-line fix in `(def login ...)` makes (a) and (b) both
  unnecessary going forward. **If you add a new login flow,
  call `login` (not just `good-login` or `prcookie`)** — that's
  where the thread-local refresh lives.

- **`uform` / `urform` must capture `(the me)` in a lexical**,
  not inline `(the me)` into the `when-umatch` body. The body
  runs in the fnid thunk at submit time; an inlined `(the me)`
  reads the submitter, which is what's being checked against —
  `when-umatch` would trivially succeed.

- **`(t var)` does not propagate into helpers.** A function
  declared `((t user me) ...)` binds a local `user`; *helpers it
  calls* still read `(the me)` directly. If a helper needs to
  see the override (e.g. an admin gate where the param is the
  freshly-logged-in user), wrap the call in `(w/me me ...)`. After
  Layer 1, this pattern is only needed for cases like the old
  admin-gate that was retired; new code shouldn't need it.

- **`newscache` cache-fill must run with `(the me) = user`.** The
  cache filler runs with whatever thread happens to invalidate
  it. If the body reads `(the me)` directly, the cached HTML
  reflects the cache-populating user, not nil. Layer 3 wraps the
  filler with `(let ,user nil (w/me ,user ,@body))` so the cache
  is always populated as the anonymous view, regardless of who
  triggered the fill.

- **Bracket-lambdas weren't matched by the initial sweep regex.**
  `[del-confirm-page (the me) i whence]` and `[cansee user _]`
  look like the corresponding parenthesized forms but only the
  parenthesized form has a leading `(`. Caught at smoke test;
  re-run with `[predicate user ` prefix to sweep the rest. Same
  for the complement `~`: `(~cansee user c)` is
  `(complement cansee user c)`.

- **`opexpand` still binds `user` and `ip` lexically** for newsop
  bodies. ~22 newsop bodies reference these locals (`(if user ...)`,
  `(when (admin user) ...)`, etc.). This binding is idiomatic
  and was *not* removed; doing so would just make every newsop
  body read `(the me)` and `(the ip)` directly, with no
  simplification.

- **`(t user me)` after `(o ...)` is fine** but order matters
  for positional-arg match. `(def votelinks (i whence (o downtoo)
  (t user me))` was rewritten from `(i whence (t user me) (o
  downtoo))` after a 4-arg call site `(votelinks c whence t)`
  would otherwise have mapped `t` to the user position.

- **`(set-ip-ban nil ...)` system bans need explicit `nil` actor.**
  After renaming the param from `user` to `actor` with `(t actor me)`,
  the only call that wanted the historical "no human actor"
  behavior is `maybe-ban-ip`. It now passes nil explicitly for
  the actor:
  `(set-ip-ban s!ip t nil nil)` — ip, yesno, info, actor.

- **dang vs pg.** HN 11242977 is dang's, not pg's. The handoffs
  consistently credit dang; if you're tempted to write "pg's
  trick", don't.

## What's left, intentionally

After commit `3cd2302`, the remaining `user` references in
news.arc / app.arc break down as:

| Category | Count | Why kept |
|---|---|---|
| `(t user me)` parameter declarations | ~30 | The canonical idiom |
| Target-user functions (`user-page`, `threads-page`, ...) | ~36 | Genuine data, not viewer plumbing |
| Data accessors (`(votes user)`, `(karma user)`, `(uvar user X)`) | ~54 | Macros over a target user; explicit user is clearer |
| `(if user ...)` newsop checks via opexpand local | ~22 | Idiomatic for newsop bodies |
| `newscache` cache-key bindings | ~8 | Drives the cache vs fresh decision |
| Internal references inside `(t user me)` bodies | many | Just reading the local |
| Strings, comments, `user` newsop name itself | a few | Not refactorable |

Anything more aggressive (dropping opexpand's
`(with (user (the me) ip (the ip)) ...)` binding, or making
`karma`/`ignored`/`uvar` macros default user to `(the me)`)
would actively hurt readability — `user` and `ip` as locals are
the canonical idiom for newsop bodies, and explicit user on data
accessors is clearer than implicit.

## Index of commits (this cascade)

In commit order:

1. **`4422c22`** — predicates take `(t user me)`
2. **`5099bba`** — drop user from wrappers
3. **`faa5919`** — drop user from leaf story selectors
4. **`d00cb53`** — drop user from `listpage`
5. **`5fec670`** — drop user from `display-items` / `display-threads` / `morelink`
6. **`6d83532`** — drop user from `admin-bar`
7. *(handoff `004` — sub-summary of #1–6)*
8. *(handoff `005` — multi-day session summary)*
9. **`5dbb85c`** — `login` refreshes `(the me)`; uform/urform read it
10. **`13331a8`** — drop user from urform/uform-rooted helpers
11. **`56382e0`** — drop user from display chain and page-template macros
12. **`8243200`** — thread-local plumbing for newslog, hooks, callbacks
13. **`1779c15`** — drop user/ip from action helpers and data writers
14. **`3cd2302`** — small-leaf cleanups

## Related handoffs

- `2026-04-28-004-dynamic-scope-design.md` — designed-but-not-implemented
  real CL dynamic scope. The thread-local approach used in this
  cascade is the alternative that actually shipped.
- `2026-04-30-001-thread-locals-news-arc-style.md` — implementation
  of `(the var)` / `(t var)` primitives. The foundation.
- `2026-04-30-002-news-arc-thread-local-refactor.md` — first
  sweep of srv/app/blog/prompt/news using the thread-locals.
- `2026-04-30-003-arg-defop-fnid-thunk-refactor.md` — `arg!foo`,
  form-macro-bodies-as-expressions, `defop` drops `req`.
- `2026-04-30-004-dang-user-subject-cascade.md` — eight-commit
  breakdown of the predicate-family cascade (Layer 0 above).
- `2026-04-30-005-session-summary-coroutines-thread-locals.md` —
  multi-day session summary covering coroutines, thread-locals,
  and the start of the user-arg cascade.
- (this doc): `2026-04-30-006-user-arg-cascade-complete.md`

## Cookies file note

The user's browser cookie is `s1BBrWVp` mapped to user "test".
For any future smoke test:

```bash
/bin/cp /Users/shawn/ml/sharc/arc/cooks /tmp/cooks.bak
# ... run smoke tests ...
/bin/cp /tmp/cooks.bak /Users/shawn/ml/sharc/arc/cooks
```

Or restore explicitly with:

```bash
echo '((s1BBrWVp "test"))' > /Users/shawn/ml/sharc/arc/cooks
```

## Process notes

- Tests run after every commit (229/229 throughout).
- News server smoke-tested anonymous and logged-in across ~30
  routes after each layer: `/`, `/news`, `/newest`, `/best`,
  `/lists`, `/leaders`, `/threads?id=test`, `/user?id=test`,
  `/submit`, `/newpoll`, `/resetpw`, `/admin`, `/scrubrules`,
  `/newsadmin`, `/newcomments`, `/active`, `/welcome`,
  `/bestcomments`, `/saved?id=test`, `/submitted?id=test`,
  `/badsites`, `/topips`, `/noobstories`, `/noobcomments`,
  plus `/item?id=14`, `/edit?id=14`, `/reply?id=14&whence=news`,
  `/vote?for=14&dir=up&by=test&auth=...`. All 200 at HEAD.
- Server invocation: `./sharc news.arc` — runs as a script with
  `(when (main) (nsv))` at the bottom of news.arc, default port
  8080. Loading interactively via stdin (`./sharc <<<` ...) hits
  `Unbound variable: main-file*` because `(when (main) ...)`
  references it.
- Two regressions caught at smoke that the test suite missed:
  the `/leaders` newscache page after the longpage signature
  change (passed `user` as `t1`, type-error on `(- (msec) "test")`),
  and an addcomment-page argument-position bug at the
  `/reply` newsop. Both fixed within minutes of the offending
  commit.

## The one-line summary

The transient `user` parameter is gone from news.arc / app.arc:
predicates, wrappers, display chain, page-template macros,
security-capturing fnids, action helpers, data writers, hooks,
callbacks. Everything reads `(the me)` / `(the ip)` from
thread-locals or accepts `(t user me)` for caller override. 14
commits. 229/229 tests throughout. ~30 routes smoke-tested at
each layer. The remaining `user` references are all genuine
target-user data, idiomatic locals, or explicit data-accessor
arguments.
