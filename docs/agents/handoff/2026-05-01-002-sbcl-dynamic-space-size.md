---
name: bump SBCL dynamic-space-size to 32 GB
description: The default SBCL heap is too small for stress tests that retain millions of mutexes (e.g. `(accum a (repeat 10000000 (a (sb-thread:make-mutex))))`), which crashes the runtime out of dynamic space. The `sharc` launcher now passes `--dynamic-space-size 32768` (32 GB) -- matching what dang says HN runs on -- so allocation-heavy explorations don't require remembering to start sbcl with custom flags. Originally bumped to 64 GB; lowered to 32 GB after `shash` was moved in-process (handoff `004`) since the higher reservation inflated `fork()` cost on macOS. Override via `SHARC_HEAP_MB`. Note: the mutexes have to be kept reachable; throwing them away (`(repeat N (sb-thread:make-mutex))`) just GCs as it goes and never crashes.
type: project
---

# SBCL `--dynamic-space-size 65536` — 2026-05-01

While exercising the new ssyntax-with-CL-pkg-markers expansion (handoff
[`001`](./2026-05-01-001-ssyntax-cl-package-markers.md)) — specifically
`(a:sb-thread::make-mutex)` and friends — a stress test that *retained*
10 million mutexes crashed SBCL with a heap-exhaustion panic.

The retention matters: `(repeat 10000000 (sb-thread:make-mutex))`
discards each mutex as it's created and never crashes — the GC reclaims
them as fast as they're allocated. To actually exhaust the heap the
mutexes have to be kept reachable, e.g.

```arc
(accum a (repeat 10000000 (a (sb-thread:make-mutex))))
;; or
(let xs nil
  (repeat 10000000 (push (sb-thread:make-mutex) xs))
  xs)
```

The default SBCL dynamic space on macOS arm64 is ~1 GB, which is
plenty for the news server itself but cramped for any allocation-heavy
exploration that retains its results (large hash tables, mutex/lock
benchmarks, building big quoted forms, etc.).

## Change

[`sharc`](../../../sharc) launcher now passes `--dynamic-space-size`
with a default of 65536 MB (64 GB), overridable via `SHARC_HEAP_MB`:

```sh
exec sbcl --dynamic-space-size "${SHARC_HEAP_MB:-65536}" --script "$DIR/boot.lisp" "$@"
```

The flag is reserved virtual address space, not committed RAM —
SBCL pages in only what's actually allocated, so this costs nothing at
rest and just removes the cliff for heavy workloads.

## Why 64 GB

Round number, comfortably above any realistic test allocation, well
under the 48-bit user-space limit on arm64. If a future workload still
hits the cap, the constant is one number to bump (or override per-run
via `SHARC_HEAP_MB=131072 ./sharc`).

## Caveats

- `--dynamic-space-size` is parsed in megabytes by default. `65536`
  means 65,536 MB.
- The flag must come before `--script` so SBCL parses it before
  switching into script mode.
- macOS will complain in Activity Monitor about the address-space
  reservation being 64 GB even when actual RSS is small. That's
  cosmetic.

## Portability and the `SHARC_HEAP_MB` override

The 64 GB reservation is fine on 64-bit macOS / Linux / Windows with
default settings, but a few environments will refuse it at startup:

- **32-bit SBCL** — only 4 GB of total address space; SBCL exits with
  `Could not allocate dynamic space`. Vanishingly rare today, but if
  encountered: `SHARC_HEAP_MB=1024 ./sharc`.
- **Linux with `vm.overcommit_memory=2`** (strict, no overcommit) —
  refuses any reservation larger than physical RAM + swap. Default
  Linux (`=0`) is fine.
- **`ulimit -v` set** — also refuses oversized virtual reservation.
  Default unlimited; some CI runners and shared hosts cap it.

In all three cases, override at run time:

```sh
SHARC_HEAP_MB=2048 ./sharc       # cap to 2 GB
```

Cgroup memory limits (`memory.max` etc.) only count *committed* pages
and don't block the reservation itself, so they're fine.

If you actually fill the heap, full GCs of older generations get more
expensive proportional to live data. SBCL handles 10 GB+ heaps fine,
but pauses become noticeable under sustained pressure. Doesn't matter
unless the headroom is in use.
