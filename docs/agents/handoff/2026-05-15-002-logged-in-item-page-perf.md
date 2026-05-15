---
name: logged-in item-page perf, 30ms -> 6ms
description: Extends the work in 2026-05-15-001 to logged-in viewers. The logged-out fast path on `perf` cached the whole page as one string; that doesn't generalise because logged-in vote-link URLs carry per-user by=/auth=. Per-user caching is unworkable at HN scale, so this branch caches one entry per item and splices the user-specific bits at emit time via a native-CL walker. Logged-in goes from 30ms to ~6ms; logged-out stays at ~3-4ms.
type: project
---

# Handoff: logged-in item-page perf, 30ms -> 6ms (2026-05-15)

> Builds on [`2026-05-15-001-item-page-perf.md`](2026-05-15-001-item-page-perf.md),
> which got logged-out down to ~4ms via a per-item flat-string cache
> but left logged-in at ~30ms because that cache can't be shared
> across users whose vote links embed `by=`/`auth=`.

## Result

934-comment thread, Apple M2 Max, `curl` to localhost:8080, perf branch
(`perf`) baseline vs this branch (`perf-logged-in`):

| viewer / state                       | perf    | perf-logged-in | vs HN median   |
|---                                   |---:     |---:            |---:            |
| logged-out, warm (cache hit)         | 3-4 ms  | **3-4 ms**     | ~16x faster    |
| logged-in, warm (cache hit)          | 30 ms   | **5-7 ms**     | ~14x faster    |
| logged-out / -in, page-cache miss    | ~130 ms | ~130 ms        |                |

Production HN medians (from `performance.md`): logged-out 65.5ms,
logged-in 85.5ms.

## Branch status

`perf-logged-in` branches off `perf`. Not pushed. Two commits beyond
the `perf` branch:

| sha       | what                                                       |
|---        |---                                                         |
| `8369ed2` | chunked cache + per-comment vote-link templates (logged-in 30ms -> 9-10ms) |
| `3d2e6c5` | native CL walker for the cached emit path (9-10ms -> 5-7ms)                |

Plus one earlier sha (`8be0398`) carried in from `perf` is the docs
handoff for the previous session, not relevant to this work.

## The shape of the problem

The `perf` branch's logged-out cache stores a fully-rendered HTML
string per item (~1MB). On hit it's one `pr` call (~3ms). That can't
be shared with logged-in viewers because each logged-in user's vote
links contain `by=<USERNAME>&auth=<COOKIE>` -- different per user.

Two non-starter approaches I considered and rejected:

1. **Per-user page cache.** ~100k users × ~1000 popular items × ~1MB
   = ~100 TB. The user explicitly called this out: "all performance
   optimizations should be in the context of a production-grade
   server, able to serve ~15m views per day. Don't do fake
   optimizations like a per-user cache that can't actually be used
   when HN is running with a hundred thousand users."

2. **Move auth out of the URL to a JS click handler.** This *would*
   unify logged-in and logged-out HTML and let them share the
   existing flat-string cache, but it's a behaviour change with
   security implications (CSRF posture changes). Out of scope.

## What landed

### Shared item-level cache with a marker-substitution emit path

The cache stores **one entry per item, shared across every non-admin/
editor viewer**. Memory is bounded by `#popular_items × ~2.5MB`, NOT
by user count.

Cache fill (in `build-comments-cache`, news.arc:1899):

1. Render `display-subcomments` into a tostring buffer under
   `(w/the building-cache t)`.
2. `votelinks` (news.arc:1053) checks `(the building-cache)` and, if
   set, emits a marker sequence -- `\x01<comment-id>\x01` -- in place
   of the real `<center>...</center>` block.
3. The resulting raw string contains all the HTML except the per-
   viewer vote links, which are marker holes.
4. A second pass walks the markers (via the native
   `split-on-marker-native`) and populates three parallel CL hash
   tables, keyed by comment-id:
   - `pre-tbl[id]` -> `<center><a id=up_ID onclick="..." href="vote?for=ID&dir=up&by=`
   - `suf-tbl[id]` -> `&whence=ENC">UP_IMG</a><span id=down_ID></span></center>`
   - `author-tbl[id]` -> the comment author's username (for the
     orange-asterisk "this is yours" case)

At emit time, the per-viewer rendering paths are:

- **Logged-out:** flat-string fast path, exactly as on `perf`. Built
  lazily on the first logged-out hit after each cache rebuild via
  `build-loggedout-html` (news.arc:1933).
- **Logged-in:** call `emit-cached-loggedin-raw`
  (arc0.lisp:783) -- one CL function that walks the raw string once
  using `write-sequence` for the slice emits and `write-string` for
  the per-marker pieces. For each marker:
    - if `voted-tbl[id]`, emit static `votelink-voted-html*`
    - else if `author-tbl[id] = me`, emit static `votelink-author-html*`
    - else emit `pre-tbl[id]` + me + `"&auth="` + cook + `suf-tbl[id]`
- **Admin / editor:** bypass cache entirely. Their HTML has
  kill/blast/delete/flag links the cache key doesn't track.

### Why a CL-native walker

Earlier iteration of this session used an arc-level
`(each c chunks ...)` loop over a split chunks list, with the same
substitution logic in arc. That landed logged-in at 9-10ms. The CL
walker (`emit-cached-loggedin-raw`) replaced ~5k arc-level `disp`
dispatches per render with `write-sequence` and `write-string`
called from inside a single CL function entry, dropping the warm
logged-in render to ~5-7ms.

Arg coercion (`symbol-name` for symbol-typed usernames/cookies, etc.)
is done once at function entry, not per-`pr`.

### New arc0.lisp primitives

- `substr` -- `(xdef substr (s start end) (subseq s start end))`.
  Arc's `cut` allocates a new string and copies char-by-char in arc;
  on 1MB inputs that was ~500ms.
- `split-on-marker-native` -- splits a raw cache string on a single
  marker char, returning alternating string-chunks and integer ids.
  An arc-level walk of 1MB strings was ~200-470ms; this is ~2ms.
- `emit-cached-loggedin-raw` -- the native emit walker described
  above.
- `new-eq-table` -- `(make-hash-table :test #'eql :synchronized t)`,
  used to allocate the per-item `pre`/`suf`/`author` lookup tables.
  Arc's default tables use `:test #'equal`; for integer-keyed
  lookups in a tight loop `eql` is enough.

## Key decisions

### One entry per item, NOT per (item, viewer)

This is the design hinge. The realisation: the per-viewer parts of
the HTML are constrained to two short substrings per vote link
(`by=USER`, `auth=COOKIE`) plus the `id=`/`onclick=` attribute shape.
Everything else is shared. So a single cached representation per item
plus a O(1) emit-time splice serves every viewer.

### Marker-substitution rather than a string-template engine

The first idea was a more elaborate template format. The version
that landed is just one C1-range char (`\x01`) wrapping a comment id.
`votelinks` emits it during cache fill; the native walker recognises
it during emit. No grammar, no parser; one `char=` test per output
byte.

### Marker char `\x01`

`(coerce 1 'char)` (news.arc:1881). C1 control char; can't appear in
real HTML attribute values or text content. If it ever could -- e.g.
if comment text were allowed raw control chars through the escape
layer -- this would corrupt the cache.

### Caching `pre`/`suf`/`author` keyed by integer comment-id, NOT
### (id, here)

Earlier in the session the pre/suf tables were keyed by `(cons id
whence)` so they could survive across cache rebuilds. With the
per-item bundle design, lookup tables are rebuilt every time the
item's cache rebuilds and lifetime is scoped to the item. Memory
released when the item entry is dropped.

### Voted / author / admin handling

- **Voted** (user has up-voted this comment): in the native walker,
  emit `votelink-voted-html*` (a static `<center><img s.gif></center>`).
- **Author** (user is the comment's `i!by`): emit
  `votelink-author-html*` (a static `<center><font orange>*</font>...`).
- **Admin / editor**: bypassed at the `cacheable-subcomments-viewer`
  check (news.arc:1843). Their HTML carries kill/blast/delete/flag
  links and changes with item state in ways the simple cache key
  doesn't track.
- **Downvote-capable** (admin or item-age < downvote-time*): the
  cache assumes no downvote arrow. Admins skip the cache entirely;
  the only non-admin downvoters are users with karma >
  `downvote-threshold*` on recent items. Cache fill currently emits
  the marker for them too -- so they'd see no downvote arrow,
  silently. **TODO:** either bypass the cache for them or emit a
  separate marker kind.

### Cache scope and TTL: 60s, invalidated on `(len kids)` or `score`
### change

Same as on the `perf` branch. A new top-level reply changes
`(len kids)`. A vote on the root changes `score`. Deep replies are
caught by the 60s TTL.

## What's NOT done -- production TODOs

These are real concerns for HN-scale deployment that the user flagged
explicitly. None of them affect the perf numbers above, but they all
need work before a long-running server.

1. **`comment-cache*` is unbounded.** `cc-window*` was widened from
   10000 to 1e8 on the `perf` branch so every comment on a typical
   item-page renders from cache. On a long-running server with the
   full HN corpus that's ~48M comments × ~1KB = ~48GB. Switch to
   either age-based or LRU eviction; the per-entry `cc-timeout`
   already exists but only refreshes, doesn't drop.

2. **`item-comments-*` tables aren't bounded either.** Each cached
   item is ~2.5MB (raw string + 3 lookup tables + flat logged-out
   string). After cache TTL expires, the entry just sits in the
   tables until a request for that item triggers a rebuild. With ~10K
   active items × 2.5MB = ~25GB, growing unbounded. Want an LRU.

3. **Cache stampede.** If a popular item's cache expires at the same
   moment 100 requests arrive, all 100 trigger `build-comments-cache`
   concurrently. Want a per-item "build-in-progress" lock so the
   other 99 wait or fall through to a slightly-stale read.

4. **Downvote-capable non-admins see a wrong vote area.** See above
   under "Voted / author / admin handling". Probably needs a separate
   marker kind, or just bypass the cache for any user with karma >
   downvote-threshold* on an item that's still in its downvote window.

5. **The `\x01` marker assumes it can't appear in cached content.**
   It can't reach the cached output via any current code path I can
   see, but the failure mode is silent corruption. Worth a defensive
   `find` check during cache fill, with a fallback that bypasses the
   cache if a real `\x01` is detected.

## How to reproduce / measure

```sh
# Start the server (perf-logged-in branch)
git checkout perf-logged-in
pkill -f 'sbcl.*boot.lisp' 2>/dev/null
nohup bash -c '(printf "(load \"news.arc\")\n(nsv)\n"; sleep 1000000) | ./sharc' \
  > /tmp/news-server.log 2>&1 &
sleep 5

# Warm caches once (first request fills both caches; ~130ms)
curl -s 'http://localhost:8080/item?id=48100433&perf=t' >/dev/null

# Logged-out warm hit
for i in $(seq 1 10); do
  curl -s 'http://localhost:8080/item?id=48100433&perf=t' \
    | grep -oE '[0-9]+/[0-9]+ loaded.* [0-9]+ msec' | tail -1
done

# Logged-in warm hit (red_admiral is the existing non-admin cookie
# in arc/cooks)
for i in $(seq 1 10); do
  curl -s -H 'Cookie: user=DjQpMegd' \
       'http://localhost:8080/item?id=48100433&perf=t' \
    | grep -oE '[0-9]+/[0-9]+ loaded.* [0-9]+ msec' | tail -1
done
```

The trailing `N msec` in each `1889/48120366 loaded | NNN mb | N msec`
line is what `admin-bar` reports. `subcomments: N msec | page-cache:
hit|miss | ...` is the breakdown above the admin-bar.

`?nocache=t` bypasses the page cache (see `cacheable-subcomments-viewer`
in news.arc:1843); useful for measuring the underlying render cost.

## Files changed

- **`arc0.lisp`** (+59 lines net) -- four new `xdef`s: `substr`,
  `split-on-marker-native`, `emit-cached-loggedin-raw`, `new-eq-table`.
- **`news.arc`** (~+100 lines net since `perf`) -- new cache layout
  (parallel tables under `item-comments-*`), new `votelinks`
  building-cache branch, new `render-subcomments`, new helpers
  `build-comments-cache` / `build-loggedout-html` / `cache-fresh`.

Tests: 291/291 still pass (`./sharc test.arc`).

## What's not in this branch that future-me will want

- Anything from the production TODOs above. None of them are
  prerequisites for the perf numbers; all of them are prerequisites
  for actually deploying this.
- The `perf` branch's handoff
  (`2026-05-15-001-item-page-perf.md`) is the right place to start
  reading -- it explains the underlying caching architecture, the
  `cc-window*` widening, the `(declare 'explicit-flush t)` flip, the
  votelinks fast paths, and the `pr`/`prt` `map1`->`each` change.
  This handoff only documents the delta on top of that.
