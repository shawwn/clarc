---
name: news.arc / app.arc / blog.arc / prompt.arc thread-local refactor
description: Sweeping refactor of the request-handling code to use the (the var) / (t var) thread-locals from 2026-04-30-001 instead of explicit user / ip / req parameter threading. Drops the req parameter from when-umatch, uform, urform, ulink and updates every caller; removes 100% of (get-user req) and req!ip references from news.arc; auto-creates news profiles for users registered via app.arc's plain login flow. Three commits: 3a50b30, 24a0c1b, 44aed5a.
type: project
---

# Handoff: news / srv / app / blog / prompt thread-local refactor — 2026-04-30

Built on top of `2026-04-30-001` (which landed `(the var)` and
`(t var)`). Goal: drop as many explicit `user` / `ip` / `req`
parameters as possible from the request-handling code without
making it cryptic.

Three commits:

- **`3a50b30`** — first pass: srv.arc binds the thread-locals,
  blog/app/prompt simplified, when-umatch left as
  backward-compat (kept the `req` param but ignored it).
- **`24a0c1b`** — bug fix surfaced during testing: a user created
  via app.arc's plain `(login-page 'login)` form lands without a
  news profile, so `(uvar user k)` would call NIL as a function.
  `profile` now auto-creates a fresh news profile for any user
  in `hpasswords*` who's missing one.
- **`44aed5a`** — full sweep: drop the vestigial `req` parameter
  from `when-umatch` / `when-umatch/r` / `uform` / `urform` /
  `ulink` and update every caller across the codebase. News.arc
  has 0 remaining `(get-user req)` or `req!ip` references.

## What landed

### srv.arc

Bind three thread-locals once per request, in `respond`:

```arc
(w/the req req
  (w/the ip ip
    (w/the me (errsafe (get-user req))
      ...handler...)))
```

Each request handler runs on its own thread (see
`handle-request-thread`) so these are naturally isolated.
Anything down the call chain pulls them via `(the me)`,
`(the ip)`, `(the req)` without explicit plumbing.

### app.arc

- `defopl` checks `(the me)` instead of `(get-user req)`.
- `defop admin`, `defop logout`, `defop whoami` drop their
  `(get-user req)` calls.
- `admin-gate ((t me))` — defaults to thread-local; uses `w/me`
  to propagate the parameter override into helpers that read
  `(the me)` (the parameter binding alone doesn't reach them).
- `admin-page` drops the `user` parameter; reads `(the me)`
  internally.
- `login-handler`, `create-handler` use `(the ip)` for IP
  capture and `(the me)` for the existing-user logout-on-login.
- `vars-form` drops the `user` parameter; captures `(the me)`
  at form-generation time via `let` so the submit-side
  `when-umatch` can verify the submitter matches the user who
  received the form (preserves the CSRF protection).
- `when-umatch` and `when-umatch/r` drop the `req` parameter.

### blog.arc

- `blogop`, `post-page`, `display-post` drop `user` threading.
- `display-post (p (t me))` lets admin tools pass an explicit
  user override.
- `addpost` drops the `user` parameter (it was unused in the
  body anyway --- a long-standing redundancy).
- `edit-page` drops the `user` parameter.

### prompt.arc

- `prompt-page` drops the `user` parameter.
- `edit-app`, `view-app`, `run-app`, `rem-app` use
  `(app (t me))` to make explicit overrides possible.
- The login-redirect callback uses `(w/me u (prompt-page))` to
  rebind the thread-local for the post-login flow.

### news.arc

- `defopt` (and via it `defopg`, `defope`, `defopa`) tests
  `(the me)` directly.
- `opexpand` reads `(the me)` and `(the ip)` instead of
  `(get-user gr)` and `(gr 'ip)`. The local `user` and `ip`
  bindings are kept for body code compatibility --- many
  newsop bodies reference `user` / `ip` as locals.
- `defopa newsadmin`, `defop formatdoc`, `defopg resetpw`,
  `defopa scrubrules` all drop `(get-user req)`.
- All inline `(fn (req) (... (get-user req) ...))` patterns
  swapped to `(the me)` and all `req!ip` to `(the ip)`.
- All `[... (get-user _) ...]` link callbacks that just
  threaded the user through swapped to `[... (the me) ...]`.
- News.arc was the file with the most call sites --- ~20
  edits in total.

### Backward-compat removed

The earlier `3a50b30` commit kept `when-umatch (user req . body)`
with `req` ignored, on the theory that news.arc callers shouldn't
break. `44aed5a` finished the job: dropped `req` from the
signature, updated all 8 callers across app/blog/news/prompt.
Same story for `uform` / `urform` / `ulink`.

## Sharp edge: `(t me)` parameter doesn't propagate to `(the me)` reads

If a function takes `(t me)`, its parameter `me` defaults to the
thread-local. But helpers it calls that read `(the me)` directly
see the *original* thread-local, not the parameter binding.

Example:

```arc
(def admin-gate ((t me))            ; me = (the me) by default
  (admin-page))                     ; admin-page reads (the me) -- same value here
```

This works fine in the *default* case (parameter and thread-local
are the same value). But in the *explicit-override* case it fails:

```arc
(admin-gate "pg")                   ; me parameter = "pg",
                                    ; but (the me) is unchanged
```

Inside, `admin-page` reads `(the me)` which is still whoever's
logged in --- not "pg". The override didn't propagate.

Fix is to use `w/me` to *also* rebind the thread-local for the
duration of the body:

```arc
(def admin-gate ((t me))
  (w/me me
    (admin-page)))                  ; now (the me) = parameter
```

Worth applying any time you have `(t var)` and the body calls
helpers that read `(the var)`. Documented in the example header
of `examples/the.arc` and now followed in `admin-gate`. Most
bodies don't actually call helpers that read `(the me)`, so the
issue is rare in practice, but worth knowing.

## What's still threaded explicitly (and why)

Some `user` / `ip` parameters remain. These were left alone
because the parameter is *data*, not the current actor:

- `cook-user`, `logout-user`, `login`, `set-pw`, `create-acct`,
  `disable-acct` --- operate on a *specific* user being acted
  upon. Could be the current user or anyone else.
- `process-story`, `process-comment`, `process-poll`,
  `add-pollopt` --- create items attributed to a user, with a
  source IP. Both inputs.
- `display-item`, `user-page`, `submitted-page` --- take a
  `user` arg that's the *viewer*, but also a `subject` arg
  that's a different user. Disambiguating via thread-local
  would lose information.
- `noob`, `karma`, `editor`, `admin` --- predicates that can be
  asked about *any* user, not just the current one.

Rule of thumb: if the parameter could plausibly be a user other
than the current actor, keep it explicit. If it's *always* the
current actor (a viewer threading their own identity), drop it
and use `(the me)`.

## Sanity checks

- Test suite: 229/229 (no change from baseline).
- News server tested anonymous and logged-in:
  - Anonymous: `/`, `/news`, `/newest`, `/submit`, `/leaders`,
    `/lists`, `/newcomments` all 200 with full-page bodies.
  - Logged-in (via cookie): same paths return larger bodies
    indicating the logged-in user banner / submit form / etc.
  - `/user?id=test` renders the profile page (2970 bytes).
  - Login flow: POST credentials to `/x?fnid=...` returns
    "hello test at 127.0.0.1" (default `hello-page` afterward).
- Coroutines example and `the.arc` example both run unchanged.
- Stderr is clean during all of the above.

## Pre-existing data inconsistency now papered over

The user "test" had a cookie in `arc/cooks` but no profile in
`arc/news/profile/`, because they registered via app.arc's plain
`/login` form, which doesn't fire news.arc's `ensure-news-user`
callback. Hitting any page as them used to crash with
"Function call on non-function: NIL" --- `(uvar user k)`
expands to `((profile user) 'k)`, profile returned nil, and
`(nil 'k)` errored.

`profile` now auto-calls `init-user` for any user that has a
password but no profs*/profdir* entry. The first request from
such a user creates a fresh profile on the fly, then proceeds
normally. Same effect as if they'd gone through ensure-news-user.

Side note: this isn't a regression from the refactor --- the
same chain existed before. The user just happened to surface
it while testing the changes.

## Net diff

| File | +/- |
|------|-----|
| `app.arc` | -38 / +37 (and 67520a5 added the runtime) |
| `news.arc` | -42 / +37 |
| `blog.arc` | -2 / +1 |
| `prompt.arc` | -56 / +53 |
| `srv.arc` | -13 / +17 |

Total: smaller files, fewer threaded parameters, the request
context is genuinely *ambient* now.

## Open work

- The `defopt`-style login callbacks still pass
  `(fn (u ip) (ensure-news-user u))` as the post-login
  afterward. Now that `profile` auto-inits, this is redundant
  but harmless. Could remove for cleanup, but it's defensive
  and explicit, so left alone.
- A few news.arc functions could simplify further by reading
  `(the me)` directly instead of taking a `user` parameter
  (e.g., `display-item`, `submitted-page`). Held off because
  the parameter sometimes carries a non-current-user value
  (the subject of a profile page, for example), and
  disambiguating the call sites would be invasive without a
  proportional readability win.
