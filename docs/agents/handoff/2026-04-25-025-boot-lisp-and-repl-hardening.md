---
name: boot.lisp and REPL hardening
description: Add a script-mode entry point (boot.lisp), make Ctrl-C/Ctrl-D and thread errors behave, gate boot chatter behind ARC_VERBOSE.
type: project
---

# Handoff: boot.lisp and REPL hardening — 2026-04-25

## What was accomplished

### `boot.lisp` — script-mode entry point (equivalent of `arc3.2/as.scm`)

Previously the `klarc` shell wrapper invoked `sbcl --noinform --load arc0.lisp
--eval "(arc:arc-boot ...)"`. Any unhandled error during script load dropped
into SBCL's interactive debugger REPL (the `0]` prompt), which is the
opposite of script behaviour. Replaced with `sbcl --script boot.lisp …`,
which disables the debugger so unhandled errors print a backtrace and exit
non-zero.

`boot.lisp` is the CL analogue of `as.scm`: load the runtime, then either
load each given file and exit, or drop into the Arc REPL when no files are
given. Arg passing is via `(cdr sb-ext:*posix-argv*)` (the script name is
consumed by `--script`). `arc-dir` honours `$ARC_DIR`, otherwise derives
from `*load-pathname*`.

`klarc` collapsed to:

```sh
#!/bin/sh
DIR="$(cd "$(dirname "$0")" && pwd)"
exec sbcl --script "$DIR/boot.lisp" "$@"
```

The previous shell-side `FILES` building / sed-escaping is gone — SBCL
hands argv to Lisp directly, so spaces/quotes in paths are no longer a
shell-quoting problem.

### REPL backtraces

`arc-tl2` previously used `handler-case`, which unwinds before the handler
runs — so any backtrace would be from the handler frame, not the offending
form. Rewrote with `handler-bind` so `sb-debug:print-backtrace` runs in the
condition's dynamic context. Pulled the print logic into a small helper
`arc-report-error` so threads can share it.

### Thread error containment

`(thread (car 42))` was killing the whole process: an unhandled error in a
thread propagates, and `--script` (`--disable-debugger`) terminates the
process on any unhandled condition. Wrapped `new-thread`'s body in
`handler-case`, which prints via `arc-report-error` to `*error-output*` and
returns `nil`. The REPL now survives bad threads.

### Ctrl-C handling

`sb-sys:interactive-interrupt` doesn't inherit from `error`, so the existing
handler clause didn't catch it — Ctrl-C propagated and `--script` exited.
Added an `interactive-interrupt` clause to the `handler-bind` in `arc-tl2`
that calls `clear-input` (to drop partially-typed characters) and
`return-from`s out of the per-iteration block. Whatever was running unwinds
and `arc-tl2` re-prompts.

Tested: Ctrl-C at idle prompt → fresh prompt; Ctrl-C during
`(while t (sleep 0.05))` → form interrupted, prompt returns, next
expression evaluates.

### Single-Ctrl-D exit (the double-peek bug)

`arc-read-1` was peeking twice for what should be one logical "next char"
check: once inside `arc-skip-ws`, then again at the top of `arc-read-1`.
On a TTY, an empty `peek-char` triggers a `read()` syscall, and a Ctrl-D
only completes one such syscall — so it took two Ctrl-Ds to drive an EOF
through both peeks.

Changed `arc-skip-ws` to return the next character (or `:eof`) instead of
returning void, and updated `arc-read-1` and `arc-read-list` to consume
that return value rather than re-peeking. The other two `arc-skip-ws`
callsites inside `arc-read-list` (the dotted-pair branch) already discard
the return value and continue working unchanged.

Pipe-EOF still exits cleanly (verified). Interactive Ctrl-D should now
exit on first press (couldn't drive a TTY from the test harness, but the
double-syscall is gone).

### ARC_VERBOSE gates boot chatter

The four boot lines (`arc0: runtime loaded…`, `Loading arc.arc…`,
`Loading libs.arc…`, `Arc ready.`) printed unconditionally, which is
noise when running scripts. Added `arc-verbose-p` (checks `$ARC_VERBOSE`
for non-empty, non-`"0"`) and an `arc-vlog` macro wrapping the gated
`format` + `force-output`. The eval-when "runtime loaded" banner uses the
same gate. Default is silent; `ARC_VERBOSE=1 ./klarc …` restores the old
output.

The `Use (quit) to quit, (arc:arc-tl) to return here after an interrupt.`
line in `arc-tl` is *not* gated — it's an interactive REPL hint, not boot
chatter.

### Rename `as.lisp` → `boot.lisp`

The script entry was first written as `as.lisp` (mirroring `as.scm`).
Renamed to `boot.lisp` because it pairs better with `arc-boot` and doesn't
read as cryptic two-letter shorthand. Other names considered: `klarc.lisp`
(close runner-up — would have mirrored the shell wrapper), `run.lisp`,
`main.lisp`, `script.lisp`, `entry.lisp`. Picked the one that names what
the file *does*.

## Key decisions

- **`--script` over `--load`+`--eval`.** The single best lever for "behave
  like a script" — disables the debugger, suppresses the banner, exits on
  unhandled errors. Everything downstream (REPL behaviour, thread error
  containment) was tuned around the assumption that the debugger isn't
  going to catch escapees, so they have to be caught in our code.
- **`handler-bind` over `handler-case` in `arc-tl2`.** The dynamic context
  matters for backtraces; `handler-case` is wrong for anything that wants
  to inspect the stack at error time. Same pattern would apply if we ever
  add e.g. a "drop into Arc-level debugger" step before unwinding.
- **`arc-report-error` is shared by REPL and threads.** Originally inlined
  the print logic in `arc-tl2`. Hoisted out so `new-thread` could use it,
  keeping error formatting consistent.
- **`arc-skip-ws` returns the peeked char.** Considered keeping the old
  contract and adding a non-peeking EOF probe in `arc-read-1`, but that
  would just push the same double-read problem somewhere else. Returning
  the char makes the shared peek explicit.
- **Did not gate the `Use (quit) ...` line behind `ARC_VERBOSE`.** That
  line teaches the user how to leave the REPL — useful even (especially)
  when boot is otherwise quiet. The four gated lines are pure boot
  progress chatter.
- **`new-thread` writes errors to `*error-output*`, not `*standard-output*`.**
  Thread output interleaves badly with the REPL prompt; routing to stderr
  at least makes it shell-redirectable.

## Files changed this session

- `boot.lisp` — new file (started life as `as.lisp`, then renamed).
- `klarc` — collapsed to a single `exec sbcl --script "$DIR/boot.lisp" "$@"`.
- `arc0.lisp`:
  - `arc-skip-ws` (~line 166) — now returns the next char or `:eof`.
  - `arc-read-1` (~line 175) — uses `arc-skip-ws`'s return value, no
    second peek.
  - `arc-read-list` (~line 136) — same.
  - `new-thread` (~line 1091) — body wrapped in `handler-case` →
    `arc-report-error` to `*error-output*`.
  - `arc-report-error` (~line 1386, new) — shared error+backtrace printer
    using `sb-debug:print-backtrace`.
  - `arc-tl2` (~line 1390) — `handler-bind` with clauses for
    `sb-sys:interactive-interrupt` (clear-input + return) and `error`
    (call `arc-report-error` + return).
  - `arc-verbose-p` / `arc-vlog` (~line 1429, new) — gate boot chatter.
  - `arc-boot` (~line 1437) — `format` calls replaced with `arc-vlog`.
  - `eval-when` banner (~line 1450) — gated behind `arc-verbose-p`.

## Verification

- `./klarc test.arc` → `193 passed, 0 failed`, exit 0, silent boot.
- `ARC_VERBOSE=1 ./klarc test.arc` → boot chatter restored.
- `./klarc /tmp/err.arc` (file with a runtime error) → backtrace +
  `unhandled condition in --disable-debugger mode, quitting`, exit 1.
  No SBCL `0]` debugger prompt.
- REPL `(car 42)` → `Error: Can't take car of 42` + backtrace, REPL
  survives.
- REPL `(thread (car 42))` then `(prn "back")` → thread error printed,
  REPL still alive, next expression evaluates.
- SIGINT to backgrounded klarc at idle prompt → fresh prompt, process
  alive (verified via `kill -INT` with a fifo-fed stdin).
- SIGINT during `(while t (sleep 0.05))` → form interrupted, REPL
  returns to prompt.
- Pipe-EOF (`echo '(prn "hello")' | ./klarc`) → exits 0.

## Current state

- All work uncommitted on `main`. No commits made this session.
- `git status` short:
  ```
  M  arc0.lisp
  AM boot.lisp
  MM klarc
  ```
  (`AM boot.lisp` because `as.lisp` was untracked before the `git mv`, so
  the rename surfaces as a new path.)
- No tests broken (`test.arc`: 193/0).
- Interactive Ctrl-D was not directly verified from a TTY (the test
  harness uses pipes); the fix is structural — one `peek-char` per read
  attempt — so a single Ctrl-D in a real terminal should suffice. If a
  future session hears otherwise, look at SBCL's `*standard-input*`
  buffering or the terminal's canonical-mode behaviour.
