---
name: news.arc — dang's user/subject cascade
description: Eight-commit cascade applying dang's HN 11242977 simplification to news.arc systematically. Predicates `cansee` / `canvote` / `canedit` / `candelete` / `visible` / `seesdead` / `editor` / `admin` / `member` / `noob` / `author` now default to `(the me)` via `(t user me)`; many wrapper functions (itemline, commentlink, editlink, deletelink, permalink, deadmark, byline, itemscore, display-items, display-threads, listpage, admin-bar, msgpage, etc.) drop their now-unused `user` parameter. ~140 call sites swept. Commits 73c9792 through 6d83532.
type: project
---

# Handoff: dang's user/subject cascade — 2026-04-30

dang's HN comment <https://news.ycombinator.com/item?id=11242977>
describes refactoring news.arc to drop the *transient* `user`
parameter that almost every function was threading just to pass to
predicates like `(editor user)`. After the predicates default to
the current logged-in user via `(t user me)`, the transient
parameter has no work to do, and a long cascade of wrapper
functions can drop it too.

This handoff covers the eight-commit cascade applying that
simplification systematically across news.arc, blog.arc, app.arc,
prompt.arc.

## The pattern

Old (one of dang's examples):

```arc
(def user-name (user subject)
  (if (and (editor user) (ignored subject))
      (tostring (fontcolor darkred (pr subject)))
      ...
      subject))
(def editor (u)
  (and u (or (admin u) (> (uvar u auth) 0))))
```

New:

```arc
(def user-name (user)
  (if (and (editor) (ignored user))
      (tostring (fontcolor darkred (pr user)))
      ...
      user))
(def editor ((t u me))
  (and u (or (admin u) (> (uvar u auth) 0))))
```

Two changes that compose:

1. `editor` defaults its user to `(the me)` via `(t u me)`. So
   `(editor)` works without an arg.
2. `user-name` was *only* passing user to editor, so once editor
   defaults, user-name doesn't need it. The function is left
   with a single user parameter --- which used to be `subject`,
   the user being looked up. The naming now matches what the
   function actually does.

dang's own observation: "every request to the site involves a set
of standard variables, like 'user', that last for the lifetime of
the current page request... the function 'user-name' no longer
has any ambiguity about which user is which".

## Eight commits

1. **`73c9792`** — `ignore` / `log-ignore`: dropped `subject`,
   renamed second param to `user`. Actor became `(t actor me)`
   to preserve the explicit-nil override path
   (system-ban callers pass nil for "no human actor").

2. **`53b41b3`** — `seesdead` (`(t user me)`); `msgpage` (drop
   `user` entirely --- never used).

3. **`4422c22`** — predicate family: `cansee`, `canvote`,
   `canedit`, `candelete`, `visible`, `cansee-descendant`,
   `visible-family` all take `(t user me)` at the end. ~40 call
   sites swept. Two regex-traps to watch for:
   - bracket-lambdas: `[cansee user _]` (not matched by
     `(cansee user...)` regex)
   - complement: `(~cansee user c)` (note the `~`)

4. **`5099bba`** — `author (i (t u me))`. Wrapper functions
   `byline`, `itemscore`, `itemline`, `commentlink`, `editlink`,
   `permalink`, `deadmark`, `display-item-text`, `deletelink`
   drop their `user` param --- it was either unused (byline,
   msgpage) or only forwarded to predicates that now default.

5. **`faa5919`** — story-list selectors `topstories`,
   `newstories`, `beststories`, `bestcomments`, `noobs`,
   `actives` drop `user`.

6. **`d00cb53`** — `listpage` drops `user`; reads `(the me)`
   directly when forwarding to longpage / display-items. 11
   call sites swept.

7. **`5fec670`** — `display-items`, `display-threads`,
   `morelink` drop `user`.

8. **`6d83532`** — `admin-bar` drops `user`. Longpage macro
   stops forwarding it.

## What stays threaded explicitly (and why)

After the cascade, ~500 `user` references remain in news.arc.
They fall into these categories, all legitimate:

- **Data parameters**: `create-comment user`, `set-pw user pw`,
  `cook-user user`, `logout-user user`, `process-story user
  ...`, `add-pollopt user p text ip`, `kill log-kill user`.
  Here `user` is a *specific* user being acted upon, not the
  current actor.

- **Security-sensitive captures**: `votelinks user`, `flaglink
  user`, `killlink user`, `blastlink user`, `comment-form user`,
  `add-pollopt-page user`. These build fnid closures that
  capture the render-time user for later when-umatch verification
  against click-time `(the me)`. Dropping the parameter would
  defeat the security check (or require re-introducing render-
  time capture another way).

- **Page-template macros**: `pagetop`, `fulltop`, `shortpage`,
  `longpage` --- macros with bodies that reference `user`
  internally. Refactoring requires careful macro hygiene; the
  payoff is smaller because the surface was already concentrated.

- **Display dispatcher chain**: `display-item`, `display-story`,
  `display-comment`, `display-comment-tree`,
  `display-comment-body`, `display-pollopt`, `titleline`,
  `topright`. These thread user down toward the security-
  sensitive capture functions; dropping user from any of them
  requires also threading `(the me)` through and the savings
  diminish.

- **`opexpand` local binding**: every `newsop` body has
  `(with (user (the me) ip (the ip)) ...)` so body code can
  reference `user` and `ip` as locals without repeated `(the
  me)` reads. Keep --- one bind, many uses, faster than
  inlining.

## Sharp edges encountered

### Bracket-lambdas

Initial perl sweep `s/\((cansee|...) user /(\1 /g` missed
bracket-lambda forms like `[cansee user _]` because the regex
required `(`. Caught at smoke-test: `/newest` errored with
"value DELETED is not of type (UNSIGNED-BYTE 45)" because cansee
was being called with `user` as the item arg and `_` as user.

Fix is the obvious `\[cansee user /[cansee /g` pattern.

### Complement prefix

`(~cansee user c)` is `(complement cansee user c)`. Same regex
miss. Fixed similarly.

### `(cansee (the me) _)` redundancy

A few inline lambdas were already `(cansee (the me) _)` --- the
explicit `(the me)` was redundant after the refactor. Cleaned
up to `(cansee _)`.

### Argument-order flips

Predicates that originally had `user` *first* (`(cansee user i)`)
now have it last (`(cansee i (t user me))`). Most callers can
just drop user. A few special cases needed reordering:

- `(visible-family nil s)` → `(visible-family s nil)` (explicit
  nil for the contro-factor anonymous-viewer case)
- `(canvote u i dir)` post-login callback, where `u` is the
  fresh logged-in user → `(canvote i dir u)`
- `(author victim (item id))` admin tool → `(author (item id)
  victim)`

All caught by reading the diff carefully; the smoke test
exercised the post-login path indirectly.

### `/logout` deletes the cookies file

Earlier session note worth repeating: `/logout` invokes
`logout-user` which writes an empty `cookie->user*` table to
`arc/cooks`. If a smoke test hits `/logout`, the dev's browser
cookie is stranded.

For this session I saved-and-restored `arc/cooks` around each
smoke-test batch, so the user's `s1BBrWVp` cookie kept working.

## Why I didn't push further

Two reasons the cascade stops here:

1. **Diminishing return.** The remaining wrappers (display-item
   et al.) thread user through 2–3 levels before hitting a
   security-sensitive capture. Dropping user in the middle
   layers requires re-introducing `(the me)` reads to maintain
   capture, which trades parameter-count for read-count without
   changing the behavior.

2. **Macro plumbing.** `pagetop` / `fulltop` / `longpage` /
   `shortpage` are macros with body code that references `user`
   internally. Refactoring requires careful hygiene
   (introducing `(the me)` reads inside the expansion) and
   careful sweeping of all 30+ call sites. The work-to-payoff
   ratio looked worse than the cascade so far.

If a future session wants to push further, the path is:

- Refactor security-capturing fnid functions (`votelinks`,
  `flaglink`, `killlink`, `blastlink`, `comment-form`,
  `add-pollopt-page`) to capture render-time `(the me)`
  internally rather than receiving user as a parameter.
- Then the dispatcher chain (`display-item`, `display-story`,
  etc.) can drop user.
- Then the page macros (`pagetop`, `fulltop`, `longpage`,
  `shortpage`) follow.

## Sanity-check coverage

Every commit ran:
- Test suite: 229/229 throughout.
- News server smoke test: anonymous and logged-in across `/`,
  `/news`, `/newest`, `/best`, `/active`, `/newcomments`,
  `/noobstories`, `/noobcomments`, `/bestcomments`,
  `/user?id=test`, `/submitted?id=test`, `/threads?id=test`,
  `/saved?id=test`, `/submit`, `/leaders`, `/lists`,
  `/topcolors`, `/formatdoc`. All 200 with logged-in-sized
  responses.
- Stderr clean during all of the above.

## Net diff across the eight commits

`news.arc` only:
- Lines: +176 / -181 (5 lines net smaller)
- The line count is misleading --- most of the savings came
  from dropping single tokens (`user `) inside larger forms.
  ~140 distinct call sites simplified.

The bigger win is at the function-signature level. dang said
the simplification "allowed us to simplify hundreds of cases" ---
this session got most of the way there for the published HN
codebase, modulo the fnid-security and page-template layers.
