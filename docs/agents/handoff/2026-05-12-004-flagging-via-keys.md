---
name: 'flagged via i!keys
description: Reworks news.arc's flag-handling so a `'flagged` entry in `i!keys` is the authoritative "this item is flagged" marker, parallel to dead/deleted. Updates the scraper to match. Also loosens `seesdead` so ignored users can still read dead content with showdead on.
type: project
---

# Handoff: flagging via i!keys (2026-05-12)

> Builds on the work in
> [`2026-05-12-002-hn-scraper.md`](2026-05-12-002-hn-scraper.md).
> That handoff describes how the scraper recorded `[flagged]`
> comments by stuffing the scraper username into `i!flags` enough
> times to clear `many-flags*`; that workaround is now gone.

## Three commits

| sha | what |
|---|---|
| `ea07ac9` | news.arc: let ignored users still see dead comments |
| `ae2ffe2` | news.arc: make `'flagged` a first-class item state via i!keys |
| `88310c2` | scrape.arc: align with news's new keys-based flagged marker |

## What changed in news.arc

### `(flagged i)` is now an explicit per-item marker

Before:

```arc
(def flagged (i)
  (and (live i)
       (~mem 'nokill i!keys)
       (len> i!flags many-flags*)))
```

After:

```arc
(def flagged (i) (mem 'flagged i!keys))
```

The old condition (a karma-weighted vote count over a threshold,
modulo `'nokill`) moves to a new predicate `(flagging i)` which is
the union of "explicitly flagged" and "enough user flags to
count".  That's what the admin `/flagged` view uses; for most
other purposes you want `(flagged i)`.

### `cansee` hides flagged items the same way it hides dead

```arc
(def cansee (i (t user me))
  (if i!deleted   (admin user)
      i!dead      (or (author i user) (seesdead user))
      (flagged i) (or (author i user) (seesdead user))   ; NEW
      (delayed i) (author i user)
      t))
```

So flagged items now require `showdead` (or authorship/editor) to
appear in any of news.arc's listings.  Matches what HN does
visually.

### Rendering: a new `[flagged]` marker

- `deadmark` prints `" [flagged] "` (alongside the existing
  `[dead]` / `[deleted]` markers) when `(flagged i)` and
  `(seesdead)`.
- `pseudo-text` (used for stubs shown to viewers who can't see the
  body) emits `"[flagged]"` for flagged items, `"[deleted]"` for
  deleted ones, and `"[dead]"` for plain dead.

### Flag link: admin vs user

The flag link's `togglemem` target now depends on the viewer:

```arc
(w/rlink (do (if (admin)
                 (togglemem 'flagged i!keys)
                 (togglemem (me) i!flags))
             (save-item i)
             (when (and (~admin)
                        (~mem 'nokill i!keys)
                        (len> i!flags flag-kill-threshold*)
                        (< (realscore i) 10)
                        (~find admin:!2 i!vote))
               (pushnew 'flagged i!keys)
               (kill i 'flags))
             whence)
  (let flag (if (admin) (flagged i) (mem (me) i!flags))
    (pr "@(if flag 'un)flag")))
```

- Admin flag/unflag flips `'flagged` in `i!keys` directly.
- Non-admin flag/unflag still records the user in `i!flags`.  If
  that user-flag pushes the item past `flag-kill-threshold*`,
  `'flagged` is pushed onto `i!keys` as part of the kill, so the
  marker still lands.

### Thresholds dropped to 0

```arc
(= flag-threshold* 0 flag-kill-threshold* 0 many-flags* 0)
```

(Was `30`, `7`, `1`.)  With the keys-based marker as the source of
truth, the old karma gate (`flag-threshold*`) and the admin
"X flags" display threshold (`many-flags*`) don't need to be high
to be meaningful -- one flag is enough.

Out of caution: this also lets *anyone* flag (zero-karma users
included), which is more permissive than HN's policy.  Bump
`flag-threshold*` back up if you want HN-style gating.

### `seesdead` no longer gates on `ignored`

```arc
(def seesdead ((t user me))
  (or (and user (uvar user showdead))   ; was: (and user ... (no (ignored user)))
      (editor user)))
```

An ignored user with `showdead` set still sees dead content in
the UI -- they're only blocked from posting / voting, not from
reading.  `(editor user)` continues to bypass both checks.

## What changed in scrape.arc

Followups now that the news side has a real keys-based marker.

- `scrape-flagger*` is a string (`"hnscraper"`) instead of a
  symbol.  News stores usernames as strings everywhere else
  (`profile.id`, `hpasswords*` keys, `cookie->user*` values), so
  this matches.
- Drops `(= many-flags* 0)` from `import-scrape!`.  No longer
  needed.
- Drops `scrape-flag-list` and the `(many-flags* + 1)`-copies
  hack.  Each imported `[flagged]` comment now gets one entry per
  actual flagger via `pushnew`, which is the right semantics.
- `import-scraped-comment` pushes `'flagged` onto `i!keys` for
  any scraped `[flagged]` comment.  That's what `(flagged i)`
  reads.

```arc
(when c!flagged
  (pushnew 'flagged it!keys)
  (pushnew scrape-flagger* it!flags))
```

## Migration

Existing on-disk items written by the scraper *before* `88310c2`
have the scraper username stuffed into `i!flags` multiple times
but no `'flagged` in `i!keys`.  Under the new `(flagged i)` they
won't read as flagged.  Re-importing from `arc/scrape/item/*.json`
fixes that:

```sh
rm -rf arc/news/story arc/news/profile arc/news/vote arc/news/topstories
./sharc
arc> (load "news.arc")
arc> (load "scrape.arc")
arc> (import-scrape!)
```

The raw scrape JSON is unchanged, so this is cheap.

## Why this is a better shape

The original (`len> i!flags many-flags*`) was fine when the only
source of flag state was real users voting.  Adding a scraper as
a sometime-flagger broke the model: one external agent can't
faithfully synthesize "enough flags to trip the threshold" without
either (a) lying about how many users flagged or (b) tweaking the
global threshold.  Both routes have weird side effects elsewhere.

Making `'flagged` a per-item keys entry lets the scraper write the
state it wants directly, while leaving the user-vote machinery
alone for actual users.  Same shape news already uses for
`'nokill` / `'commentable` / `'flagged` (for an admin override) --
keys is the right place for per-item moderation metadata.
