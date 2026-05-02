---
name: shash via vendored sha1.lisp instead of fork+exec to openssl
description: `shash` was forking + execing `openssl dgst -sha1` per call; with the 64 GB SBCL heap from handoff `2026-05-01-002`, fork overhead inflated each call to ~100 ms (kernel walks the parent's page tables on fork even with COW). A page render that hashes 7 kill links was taking ~9 seconds. Replaced with Jeffrey Massung's pure-CL [sha1.lisp](https://github.com/massung/sha1) (Apache 2.0), vendored into the repo and loaded from boot.lisp. shash is now ~0.13 ms per call -- ~1000× faster -- and no longer scales with SBCL heap size. Output is lowercased to match openssl's format so existing on-disk hashes still compare equal.
type: project
---

# `shash` in-process — 2026-05-02

## What was slow

[`app.arc`](../../../app.arc) `shash` was a shell-out:

```arc
(def shash (str)
  (let fname (+ "/tmp/shash" (rand-string 10))
    (w/outfile f fname (disp str f))
    (do1 (last (tokens (tostring (system (+ "openssl dgst -sha1 <" fname)))))
         (rmfile fname))))
```

Per call: write a temp file, fork+exec `/bin/sh -c "openssl dgst -sha1 < /tmp/..."` (two process spawns: sh, then openssl), read all output, delete file.

With the default ~1 GB SBCL heap that was ~10 ms per call. Tolerable.
With the 64 GB heap from handoff [`2026-05-01-002`](./2026-05-01-002-sbcl-dynamic-space-size.md), `fork()` inflates roughly proportional to the parent's reserved virtual memory because the kernel walks the parent's page tables on fork even with COW. Per call jumped to ~100 ms.

A logged-in news front page renders 7 kill links → 7 `gen-auth` calls → 7 `shash` calls, plus a one-shot `user-secret` create on first request → 8 calls total → ~8.9 seconds end-to-end. User noticed and reported.

## What landed

Vendored [`sha1.lisp`](../../../sha1.lisp) (Jeffrey Massung,
Apache 2.0; license header preserved at the top of the file) at the
repo root.

Loaded from [`boot.lisp`](../../../boot.lisp) immediately after
`arc1.lisp`:

```lisp
(load (merge-pathnames "arc1.lisp" *load-pathname*))
(load (merge-pathnames "sha1.lisp" *load-pathname*))
```

Replaced `shash` in [`app.arc`](../../../app.arc):

```arc
(def shash (str)
  (downcase (sha1::sha1-hex str)))
```

The `downcase` matters: `sha1:sha1-hex` uses `~16,2,'0r` which prints
uppercase in SBCL (`AAF4C61D...`); `openssl dgst -sha1` outputs
lowercase (`aaf4c61d...`). Existing on-disk hashes (`arc/hpw`,
`arc/cooks`, ...) are lowercase — without the downcase, login
comparisons would fail for any account that pre-dates this change.

## Performance

Benchmark in `sharc`:

```
arc> (time (repeat 100 (shash "the quick brown fox jumps over the lazy dog")))
time: 13 msec.
```

~0.13 ms / call. Roughly 1000× the openssl-fork path under the 64 GB
heap, ~75× under the default 1 GB heap. No longer scales with
SBCL heap size. Front-page render returns to milliseconds-per-page.

## Correctness spot-check

```
arc> (shash "hello")
"aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d"
arc> (shash "")
"da39a3ee5e6b4b0d3255bfef95601890afd80709"
```

Matches the canonical SHA-1 outputs.

## What didn't change

- The `shash` API. Same signature, same lowercase 40-char hex output;
  callers (`hpasswords*`, `cookie->user*`, `user-secret*`,
  `gen-auth`) unaffected.
- The 64 GB heap. The fork-overhead amplifier is real but the heap
  itself isn't the bug; once `shash` doesn't fork, the heap size is
  irrelevant.

## Files touched

| File | What landed |
|---|---|
| [`sha1.lisp`](../../../sha1.lisp) | new file: vendored from massung/sha1 (Apache 2.0) |
| [`boot.lisp`](../../../boot.lisp) | load `sha1.lisp` after `arc1.lisp` |
| [`app.arc`](../../../app.arc) | `shash` rewritten to call `sha1::sha1-hex` and downcase |
