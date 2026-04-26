---
name: Reverse REPL backtrace and truncate at arc-boot
description: Rework `arc-report-error` so the backtrace prints outermost-first (oldest frame at top, error message at bottom) and stops at the `arc-boot` frame, hiding the SBCL load/script machinery.
type: project
---

# Handoff: reversed + truncated REPL backtrace — 2026-04-26

## What was accomplished

Previously `arc-report-error` did:

```lisp
(format stream "Error: ~A~%" c)
(sb-debug:print-backtrace :stream stream :count 30)
```

which prints `Error:` first, then frames innermost (0) → outermost
(26+), so the actual error message scrolls off the top of the
terminal and the bottom of the backtrace is full of irrelevant
`SB-IMPL::%START-LISP` / `SB-IMPL::PROCESS-SCRIPT` /
`SB-FASL::LOAD-STREAM-1` frames.

Now it prints:

1. Frames in reverse (frame N first, frame 0 last).
2. `Backtrace for: #<SB-THREAD:THREAD …>` line.
3. `Error: …` line.

…and stops collecting once it hits the `arc-boot` frame, so the SBCL
loader frames at the bottom of the stack are dropped. End result for
`(car 42)` at the REPL is frames 0–9 with the error message at the
bottom, easily readable in a terminal that auto-scrolls to the
prompt.

## Files changed this session

- `arc0.lisp` — only `arc-report-error` (around line 1407) was
  rewritten. Replaces `sb-debug:print-backtrace` with a manual loop
  using `sb-debug:map-backtrace`, accumulating each frame's printed
  output via `sb-debug::print-frame-call` (note: internal symbol,
  double-colon).

## Key decisions

- **Use `map-backtrace` + manual collection rather than
  `print-backtrace`.** SBCL's `print-backtrace` has no reverse option
  and no early-stop predicate. Collecting strings into a list and
  iterating gives us both for free: `push` reverses iteration order
  so the printed list is naturally outermost→innermost.

- **Stop predicate: match `symbol-name` = `"ARC-BOOT"`, not
  `(eql name 'arc-boot)`.** First attempt used `eql` against
  `'arc-boot` read in package `:arc`, which never matched. Reason:
  `boot.lisp` has no `in-package` form, so it loads in `CL-USER`,
  making the function `COMMON-LISP-USER::ARC-BOOT` — a different
  symbol from `ARC::ARC-BOOT`. Rather than chase that, compare by
  symbol-name string. Robust against future package shuffles.

- **Disable pretty-printing per frame (`*print-pretty* nil`).**
  Otherwise long frames pretty-print across multiple lines and the
  index prefix only gets stamped on the first line. Single-line
  output keeps every frame indexable. Terminal soft-wrap is fine —
  it doesn't break the format.

- **Include the `arc-boot` frame, not just frames above it.** The
  stop flag is set *after* pushing the frame, so frame 9 in the
  printed output is `(ARC-BOOT :ARC-DIR "…" :FILES NIL)` and nothing
  below it.

- **Kept `:count 30` as a safety cap** even though `arc-boot` will
  almost always cut earlier. Prevents pathological loops if the stack
  is somehow corrupted or `arc-boot` is missing (e.g. someone calls
  `arc-eval` from outside the boot path).

- **Kept the `Backtrace for: …` line.** User explicitly asked for it
  to move just above `Error: …` rather than be removed.

## Things to watch

- **`sb-debug::print-frame-call` is internal SBCL.** Could change in
  future SBCL releases. The exported `sb-debug:print-backtrace` does
  not expose enough hooks for our needs (no reverse, no per-frame
  filter), so we're stuck on the internal symbol unless we want to
  reimplement frame formatting from scratch. If SBCL upgrades break
  this, the obvious fallback is to format frames manually using
  `sb-di:debug-fun-name` + `sb-di:frame-call`.

- **`boot.lisp` lives in `CL-USER`.** Anything in `arc0.lisp` that
  wants to refer to symbols defined there has to handle the package
  mismatch (string-name compare, or `find-symbol` in
  `common-lisp-user`). This is the second time it's bitten us — see
  also the unbound-variable handoff (`004`) where `arc-boot` itself
  was the issue.

- **Terminal scroll behaviour.** In a typical TTY the prompt sits at
  the bottom of the screen, so reversing the trace means the most
  important info (`Error: …`) is the last thing printed before the
  prompt — exactly where the eye lands. This was the user's stated
  motivation; preserve that ordering if the function gets touched
  again.

## Current state

- One small change to `arc0.lisp` (~15 lines around the
  `arc-report-error` defun). Uncommitted on `main` at the start of
  this handoff. Commit is next.
