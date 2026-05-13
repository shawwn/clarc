# Performance log

Ad-hoc snapshots of how long pages take to render on the local mirror,
recorded before we knew enough to write proper benchmarks.  Treat
these as anecdotes: they're tied to a specific corpus snapshot (often
listed in the entry) and a specific machine, and they go stale every
time the corpus is re-imported.

Each entry should record:

- date, and ideally the commit (`git rev-parse HEAD`) it was measured against
- what page was loaded and against what corpus snapshot
- the hardware (CPU + machine class), since numbers move with the host
- how the timings were collected (browser dev tools, `curl -w '%{time_total}'`, ...)
- raw numbers (so future entries can compare apples to apples)

---

## 2026-05-13 -- item page, 632 comments, logged-in vs logged-out

**Page:** local mirror of `item?id=48100433` (HN snapshot at 593 points,
632 comments at scrape time).

**Hardware:** Apple M2 Max laptop.

**Method:** browser page load, 10 successive measurements each.  Times
in milliseconds.

### Local mirror (this repo)

| viewer       | n  | min | median | mean  | max |
|---           |---:|---: |---:    |---:   |---: |
| logged-in    | 10 | 158 | 166    | 168.3 | 190 |
| logged-out   | 10 | 130 | 138    | 138.2 | 147 |

Raw:

```
logged-in:  190 164 181 170 168 160 159 160 173 158
logged-out: 142 140 139 147 137 134 130 134 135 144
```

About 30 ms slower for the logged-in path -- that's the cost of all
the per-user state news.arc computes (vote arrows, hide links,
showdead-gated markers, threads-link header).

### Baseline: production HN, same thread, ~8 hours later

Numbers from dang (HN admin, over email) for the last-10 server-side
render times of the same item.  By that time the thread had grown to
roughly ~850 comments, so HN is producing more output in less time.

| viewer       | n  | min | median | mean  | max | notes |
|---           |---:|---: |---:    |---:   |---: |---    |
| logged-in    | 10 | 74  | 85.5   | 165.9 | 597 | mean skewed by two outliers (388, 597) -- probably GC pauses; excluding them, mean is 84.3 |
| logged-out   | 10 | 60  | 65.5   | 65.3  | 76  |       |

Raw:

```
logged-in:  93 95 89 597 82 388 80 74 80 81
logged-out: 66 67 65 61 66 66 63 60 63 76
```

### Comparison

Stripping the two outliers from the logged-in row makes the medians
comparable:

| viewer       | local median | HN median | local / HN |
|---           |---:          |---:       |---:        |
| logged-in    | 166          | 82        | **~2.0x slower** |
| logged-out   | 138          | 65.5      | **~2.1x slower** |

That gap is on a *smaller* corpus too, so the real margin is wider.
Roughly: **HN's production Arc+News is about 2x faster than ours on
the same page**, give or take, and we're rendering ~20% less content.

For scale context, also from the same email: HN served ~23.2M page
views yesterday, of which ~14.9M hit the Arc server (the rest came
from an Nginx cache in front).

### Note

This snapshot is about to be invalidated by a re-scrape (the source
thread is now at 979 comments / 879 points).  Re-measured numbers
go under the next entry below.

---

## 2026-05-13 -- same item, re-scraped at 934 comments

**Page:** local mirror of `item?id=48100433`, after re-scraping
(883 points, 934 comments at scrape time -- roughly the size HN was
rendering when dang took the baseline numbers above).

**Hardware:** Apple M2 Max laptop (same machine as the previous entry).

**Method:** browser page load, 10 successive measurements each.
Times in milliseconds.

| viewer       | n  | min | median | mean  | max |
|---           |---:|---: |---:    |---:   |---: |
| logged-in    | 10 | 369 | 383    | 381.7 | 391 |
| logged-out   | 10 | 320 | 329    | 328.7 | 337 |

Raw:

```
logged-in:  376 391 389 390 381 376 385 388 372 369
logged-out: 333 320 329 337 331 326 326 324 329 332
```

### Comparison vs HN, like-for-like

Now that our snapshot has ~934 comments and HN's baseline above
was ~979, the corpora are about the same size.

| viewer       | local median | HN median | local / HN |
|---           |---:          |---:       |---:        |
| logged-in    | 383          | 82        | **~4.7x slower** |
| logged-out   | 329          | 65.5      | **~5.0x slower** |

A larger gap than the previous entry showed (~2x on the smaller
corpus).  Suggests rendering on our side scales worse than linearly
with comment count -- ~1.5x more comments (632 -> 934) produced
~2.3x more render time (166 -> 383 ms logged-in).  The HN baseline
above shows HN doesn't have the same scaling problem on its end
(its medians were already comparable at ~979 comments).
