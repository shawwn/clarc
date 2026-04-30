---
name: Session summary — Celeste coroutines, thread-locals, and dang's user/subject cascade
description: Index and meta-summary of a multi-day session that landed (1) a celeste-style multi-coroutine-per-actor scheduler with synchronized hash tables, (2) `(the var)` / `(t var)` thread-local primitives for arc, and (3) a sweeping refactor of news.arc / blog.arc / app.arc / prompt.arc / srv.arc applying dang's HN 11242977 simplification. Reads as the canonical jumping-off point — every subsection links to one of the more focused handoffs from this session.
type: project
---

# Session summary: coroutines, thread-locals, dang's cascade — 2026-04-28 → 2026-04-30

This is the index for a long session that touched three big things
in sharc. Each section here points at a more focused handoff doc;
read this one to orient, then dive into the linked one for detail.

## What was the goal

Started 2026-04-28 trying to express Celeste's `IEnumerator`
coroutine pattern in arc-on-CL. Snowballed into:

1. A working multi-coroutine-per-actor scheduler in
   `examples/coroutines.arc` that mirrors Celeste's
   `ComponentList<Coroutine>` model.
2. Hardening the runtime: synchronized hash tables, defensive
   error-handling, contract documentation.
3. Designing (but not implementing) real CL dynamic scope.
4. Reading dang's HN comment on news.arc and implementing the
   `(the var)` / `(t var)` thread-local mechanism.
5. Doing the dang-style cascade across news.arc and friends:
   ~140 call sites simplified, the transient `user` parameter
   gone from a long chain of wrappers.

## Files that changed

| File | What landed |
|---|---|
| `arc0.lisp` | `:synchronized t` on every `make-hash-table` |
| `arc1.lisp` | `:foo` / `foo:` reader → CL keyword; `(t var)` parameter form recognised in `ac-complex-args` |
| `arc.arc` | `thread-locals*` per-thread hash; `(the var)` macro and setter; `w/the` and `w/me` scoped binders |
| `srv.arc` | `respond` binds `(the req)` / `(the ip)` / `(the me)`; `arg!key` reads from `(the req)`; `defop`/`defopr`/etc. drop `req` parameter; form macros take body expression; fnid contract uses thunks |
| `app.arc` | `when-umatch` drops `req`; `defopl` reads `(the me)`; admin/login flows use thread-locals; `vars-form` drops `user` |
| `blog.arc` | `display-post` etc. drop `user`; everything reads thread-locals |
| `prompt.arc` | Same simplifications as blog |
| `news.arc` | Predicate family takes `(t user me)`; ~140 call sites swept; ignore/log-ignore use `(t actor me)`; `auto-init` profile fix |
| `examples/coroutines.arc` | Multi-coroutine-per-actor; cooperative-scheduling contract documented at top |
| `examples/the.arc` | News.arc-style request-handler example demonstrating `(t me)` |
| `test.arc` | 22 new tests covering the thread-local primitives |

229/229 tests pass throughout the session. News server tested
anonymous and logged-in across all common paths.

## The three threads, with handoff links

### Thread 1 — Coroutines (2026-04-28)

Celeste-shaped coroutine scheduler in `examples/coroutines.arc`,
where each *actor* (entity) owns a list of *coroutines*
(components) that all advance once per tick.

- **`2026-04-28-001`** — multi-coroutine-per-actor refactor. Each
  coroutine owns its own pair of semaphores (sharing one pair
  across coroutines on the same actor would race). Per-thread
  hash `coros*` keyed by `(current-thread)` so `(yield)` finds
  its own coro without the body threading it through.
- **`2026-04-28-002`** — `:synchronized t` on every
  `make-hash-table` in `arc0.lisp`. The `coros*` hash was racy
  during concurrent coroutine spawn-startup; rather than fixing
  it locally, fixed at the runtime level. ARM-context analysis
  shows the perf cost is small enough not to matter for sharc's
  scale.
- **`2026-04-28-003`** — design notes for sub-coroutines / await
  / wait-for. Big finding: function calls already implement the
  inline-sub-coroutine pattern (the call stack IS the enumerator
  stack). Only `await` and `wait-for` would need adding for full
  Celeste-shape; held off until a use case appears.

The contract block at the top of `examples/coroutines.arc`
captures the cooperative-scheduling rules: no yield-while-holding-
mutex (deadlock); no unbounded sync work (starvation); no
terminate-thread on a running coro (use a cancel flag);
step-coro is scheduler-only.

### Thread 2 — Reader & dynamic scope discussion

- **`2026-04-28-004`** — design notes for real CL dynamic scope
  (`defvar`/`defparam`), but **not implemented**. Designed how
  it would interact with arc's `let` (which would need to lower
  to `cl:let` for special-binding to work) and how to handle
  thread-inheritance (the `:initial-bindings` argument to SBCL's
  `make-thread` was removed in modern SBCL; only
  `*default-special-bindings*` and per-thread `let` remain).
- **`2026-04-28-005`** — keyword arg porting. The reader change
  for `:foo` / `foo:` landed; the call-site reorder design was
  considered and explicitly dropped because of how it would
  interact with `apply` (CL's trailing-list-arg convention vs.
  "move keys to end" pull in opposite directions).

The bare reader change is in commit `b3f0153`: `:foo` and
`foo:` both read as the CL keyword `:FOO`; `literal-p` includes
`keywordp` so keywords self-evaluate. Vbar (`|:foo|`) escapes.

### Thread 3 — Thread-locals (2026-04-30)

The big one. Implements dang's news.arc trick from HN
<https://news.ycombinator.com/item?id=11242977>.

- **`2026-04-30-001`** — implementation of `(the var)` and the
  `(t var)` parameter form. Per-thread hash table keyed by
  `(current-thread)`; `setforms` integration so
  `(= (the var) val)` Just Works; `w/the` and `w/me` for scoped
  binding; `(t var)` and `(t local var)` parameter forms in
  `ac-complex-args`.
- **`2026-04-30-002`** — sweeping refactor of srv/app/blog/
  prompt/news using the thread-locals. `respond` binds
  `(the req)` / `(the ip)` / `(the me)` once per request; every
  helper reads them without explicit threading. Vestigial bug
  fix: profile auto-init for users registered via app.arc's
  plain `(login-page 'login)` flow (didn't fire news.arc's
  `ensure-news-user`, so they had a cookie but no profile).
- **`2026-04-30-003`** — followups: `arg!foo` instead of
  `(arg req "foo")`; form macros take a body expression
  instead of a `(fn (req) ...)` value; `defop`/`defopr`/etc.
  drop the `req` parameter; fnid stored fns are thunks
  uniformly. ~50 call sites swept.
- **`2026-04-30-004`** — dang's own user/subject cascade. After
  the predicates (`editor`, `admin`, `member`, `noob`,
  `cansee`, etc.) default to `(the me)` via `(t user me)`, the
  transient `user` parameter is unnecessary in dozens of
  wrapper functions. ~140 call sites swept across news.arc.
  See that handoff for the eight-commit breakdown.

## Sharp edges discovered (read these before editing)

The headline ones, distilled. Each is documented in detail in
the linked handoff.

- **`/logout` wipes `arc/cooks`** and strands any browser cookie
  pointing at the logged-out user. Save and restore the file
  around any smoke test that hits `/logout` (`/x` posts to the
  logout fnid count too). Restore format is
  `((COOKIE_SYMBOL "username"))` — symbol unquoted, username
  quoted.

- **`(t var)` parameter doesn't propagate to `(the var)` reads
  in helpers.** The parameter binding is local; helpers that
  read `(the var)` directly see the unchanged thread-local.
  Fix is to use `w/me` (or `w/the`) inside the function to
  propagate the override. Followed in `admin-gate` which uses
  `(w/me me ...)`; documented in `examples/the.arc` and
  handoff `001`.

- **`(my-coro)!actor` doesn't work** — arc's `!` ssyntax
  doesn't compose with parenthesized expressions. Bind first
  (`(let c (my-coro) c!actor)` or `(aand (my-coro) it!actor)`).

- **`:foo` ssyntax doesn't compose with parens either**:
  `((my-coro) :actor)` parses as ssyntax expansion and breaks.
  Same bind-first workaround.

- **Bracket-lambdas weren't matched by my initial perl regex**
  during the predicate-family sweep. `[cansee user _]` looks
  like it's in the same class as `(cansee user _)` but only
  the latter has the leading `(`. Caught at smoke test —
  re-running with `[predicate user ` prefix swept the rest.

- **Complement prefix `~`**: `(~cansee user c)` is
  `(complement cansee user c)` — also a regex miss for the
  same reason. Same fix.

- **Form macros' `(fn (req) ,handler)` wrapping**: when I
  changed `/x`, `/y`, `/a`, `/r` dispatch from `(it req)` to
  `(it)`, I had to also change `aform`/`arform`/`taform`/etc.
  to wrap in `(fn () ,handler)` instead of `(fn (req) ,handler)`.
  Missed it in commit `09a31e8`; caught when story submission
  errored with "invalid number of arguments: 0"; fixed in
  `68e006c`.

- **`init-user` returns the username, not the profile.** When
  I made `profile` auto-call `init-user` for valid users
  missing a profile, I had to read `(profs* u)` back AFTER
  the call to get the actual profile, since `init-user`'s
  return value is `u`.

- **Modern SBCL removed `:initial-bindings`** from
  `sb-thread:make-thread`. The `2026-04-28-004` plan that
  proposed using it for thread-local inheritance no longer
  works as written; have to use `*default-special-bindings*`
  or wrap inside the thread body with a `let`.

- **dang vs pg**: HN comment 11242977 is dang's, not pg's. I
  attributed it to pg early in the session and was corrected.
  The handoffs all credit dang now.

## Open work, in rough priority order

### Real CL dynamic scope (handoff `2026-04-28-004`)

The thread-local trick (handoff `001`) is the news.arc-style
hash-based approach. Real dynamic scope (`defvar`/`defparam`)
is still designed-but-not-implemented. Order of work:

1. Lower arc's `let`/`def` bindings to `cl:let` (with
   `destructuring-bind` dispatch on non-symbol patterns)
   instead of compiling to a lambda. Required for special
   binding to work.
2. Add `defvar` / `defparam` forms.
3. Optionally migrate `coros*` hash → `*current-coro*`
   dynamic var as end-to-end validation.

### Push the dang-cascade further (handoff `2026-04-30-004`)

About 500 `user` references remain in news.arc. The categories
that could still simplify, in difficulty order:

1. **Page-template macros** (`pagetop`, `fulltop`, `longpage`,
   `shortpage`) — refactor requires careful macro hygiene; ~30
   call sites to sweep.
2. **Display dispatcher chain** (`display-item`,
   `display-story`, `display-comment`, etc.) — passes user
   toward security-sensitive captures; refactoring is mostly
   moving the `(the me)` read down to the capture site.
3. **Security-capturing fnid functions** (`votelinks`,
   `flaglink`, `killlink`, `blastlink`, `comment-form`,
   `add-pollopt-page`) — capture render-time `(the me)`
   internally rather than receiving user as a parameter. Most
   delicate because it's the security boundary.

After these three, the only remaining `user` references would be
genuine data parameters (target user being acted on), which
should stay.

### Coroutine system extensions (handoff `2026-04-28-003`)

Still on the wishlist:

- `(await c)` for waiting on a parallel coroutine. Two lines.
- `(wait-for pred)` for predicate-polling. Two lines.
- Cooperative `c!cancel` flag plumbing instead of the
  `terminate-thread` sledgehammer.
- A `(send msg coro)` channel-style primitive if the use case
  demands it.

Held off because none has a real use case driving it yet.

### Demo / example for thread-locals

`examples/the.arc` exists as a small demonstration. Worth
considering a richer example that mirrors the news.arc patterns
(login, vote, edit profile), maybe in a tiny self-contained
form. Helps anyone reading the codebase grasp the pattern
before opening news.arc.

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

- Test suite ran after every commit; news server smoke-tested
  after the bigger ones. Two regressions caught at smoke that
  the test suite missed:
  - The form-macro thunk-wrapping bug (story submission)
  - The bracket-lambda regex miss (`/newest` page)
  Both caught within minutes of the offending commit because
  smoke tests covered the right surface.
- For deep-stack errors, `arc0.lisp`'s `new-thread` was
  temporarily switched from `handler-case` to `handler-bind`
  (which doesn't unwind, so user-level frames stay on the
  stack for `arc-report-error`'s `sb-debug:map-backtrace`).
  Reverted before each commit. Worth keeping this trick in
  mind.

## The one-line summary

A long, productive sweep. sharc gained a coroutine system and
a thread-local mechanism; news.arc lost most of its transient
`user` plumbing; everything still passes 229/229 tests; the
news server still serves correctly anonymous and logged-in.
The primary remaining work is real CL dynamic scope (designed
in `004`, not yet implemented) and the deeper layers of
news.arc (page macros, security-capturing fnids).

## Index of related handoffs (this session)

- `2026-04-28-001-coroutine-multi-per-actor.md`
- `2026-04-28-002-synchronize-all-tables.md`
- `2026-04-28-003-coroutine-sub-and-await-design.md`
- `2026-04-28-004-dynamic-scope-design.md`
- `2026-04-28-005-keyword-arg-porting-challenge.md`
- `2026-04-30-001-thread-locals-news-arc-style.md`
- `2026-04-30-002-news-arc-thread-local-refactor.md`
- `2026-04-30-003-arg-defop-fnid-thunk-refactor.md`
- `2026-04-30-004-dang-user-subject-cascade.md`
- (this doc): `2026-04-30-005-session-summary-coroutines-thread-locals.md`
