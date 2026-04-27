---
name: Reorder arc-report-error to match SBCL's printer
description: Custom backtrace printer in arc0.lisp now prints error first, then "Backtrace for: thread", then frames numbered from 0 (innermost outward) — matching SBCL's default debugger format. ARC-BOOT elision is unchanged.
type: project
---

# Handoff: backtrace printer order — 2026-04-27

`arc-report-error` in `arc0.lisp` (used by `arc-tl2`'s
`handler-bind` and by `new-thread`'s thread-error handler)
previously printed:

```
N: outermost-frame
...
0: where-the-error-happened
Backtrace for: <thread>
Error: foo
```

— frames descending, error last. SBCL's stock debugger prints
the inverse: error first, then the thread, then frames ascending
from 0 (innermost). This change matches that shape:

```
Error: Can't take car of 42
Backtrace for: #<THREAD tid=… "arc" RUNNING …>
0: (arc::arc-report-error …)
1: ((lambda nil :in arc::arc--NEW-THREAD))
...
6: (sb-thread::run)
```

## What changed

One function, `arc-report-error`. Two structural edits:

1. The two header lines (`Error: …` and `Backtrace for: …`) moved
   *above* the `map-backtrace` loop instead of after it.
2. The frame-collection step that pushed onto a list (and then
   `dolist`-printed in collected order, which reversed to give
   descending numbers) is gone. The map callback now `format`s
   each frame to the stream directly, so frame 0 is whichever
   one `map-backtrace` visits first — i.e. the innermost.

The ARC-BOOT elision logic is byte-for-byte the same: the
callback still checks each frame's debug-fun-name, and once it
sees `ARC-BOOT` it sets the `stop` flag so all outer frames are
skipped. The 30-frame cap is also unchanged.

## Verified

- `./test.arc` → `207 passed, 0 failed` (no test exercises the
  printer; this is a "didn't break the build" check).
- `./examples/coroutines.arc` produces the new format on stderr
  for neo's intentional `(car 42)` (in-thread error path).

## Notes for whoever picks this up

- **`arc-report-error` is not installed on every error path.** The
  REPL (`arc-tl2`) and `new-thread` install `handler-bind` /
  `handler-case` that route through it. The stdin loader
  (`arc-load-stdin` in `boot.lisp`) does *not* — errors there
  hit SBCL's default debugger. If you ever want stdin errors to
  use this printer, wrap the loop in `handler-case` and call
  `arc-report-error` yourself.

- **Frame 0 is `arc-report-error` itself**, because we walk the
  stack from inside the handler. This is unavoidable without a
  little more bookkeeping (skip the first frame whose debug-fun
  is `ARC-REPORT-ERROR`). Left as-is to match the previous
  behavior, which also had it as the innermost frame.

- **The `:invert` readtable case for frame text is unchanged.**
  Mixed-case symbols like `arc--CAR` still print without
  `|...|` escapes. All-lower and all-upper print canonically.

## Current state

- `arc0.lisp`: ~10-line refactor of `arc-report-error`. No new
  helpers, no API change.
- No test additions — the printer's output isn't pinned anywhere
  the test suite checks.
