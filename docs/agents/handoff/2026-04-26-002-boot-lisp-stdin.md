---
name: Move arc-boot into boot.lisp; handle piped stdin
description: Move arc:arc-boot's implementation out of arc0.lisp into boot.lisp, and add a non-interactive stdin branch so `echo '...' | ./sharc` evaluates and exits.
type: project
---

# Handoff: boot.lisp owns arc-boot, stdin pipes evaluate-and-exit — 2026-04-26

## What was accomplished

### `echo '...' | ./sharc` now evaluates and exits

Previously, piping expressions into `./sharc` dropped into the REPL anyway:

```
$ echo '(prn "hi") (prn "there")' | ./sharc
Use (quit) to quit, (arc:arc-tl) to return here after an interrupt.
arc> hi
"hi"
arc> there
"there"
arc>
```

…which is the wrong shape for one-liners and shell pipelines. Now:

```
$ echo '(prn "hi") (prn "there")' | ./sharc
hi
there
```

The dispatch in `arc-boot` is now a three-way `cond`:

1. **file args** → run each as a script and exit (unchanged).
2. **stdin not a tty** (`(not (interactive-stream-p *standard-input*))`)
   → read/eval all expressions from stdin and exit. Implemented by
   `arc-load-stdin`, which loops `arc:arc-read` until `:eof` and calls
   `arc:arc-eval` on each form.
3. **otherwise** → drop into `arc:arc-tl` (the REPL), unchanged.

The interactive REPL path is detected by `interactive-stream-p` rather than
e.g. `isatty(0)`, because that's what SBCL exposes portably and it returns
the answer we actually want (does this stream behave like a terminal).

### Move `arc:arc-boot`'s implementation into `boot.lisp`

`arc-boot` and its helpers (`arc-vlog`, `arc-verbose-p`, the eval-when
"runtime loaded" banner) used to live at the bottom of `arc0.lisp`. They
existed only to be called by the `boot.lisp` script wrapper, which was a
thin two-liner:

```lisp
(load (merge-pathnames "arc0.lisp" *load-pathname*))
(arc:arc-boot :arc-dir ... :files (cdr sb-ext:*posix-argv*))
```

The boot logic is now defined directly in `boot.lisp` (still as a function
named `arc-boot`, but in the default `cl-user` package, not exported from
`:arc`). `boot.lisp` calls it at the end with `arc-dir` and `files`. The
runtime in `arc0.lisp` no longer knows or cares how it gets driven —
that's `boot.lisp`'s job.

`arc-boot` was removed from the `:arc` `:export` list. `arc-vlog` and
`arc-verbose-p` moved to `boot.lisp`. The eval-when banner was deleted (it
was already gated behind `ARC_VERBOSE` and only printed in the
`--load arc0.lisp` flow that no longer exists).

### `arc::arc-global` from outside the package

`arc-boot` sets `|main-file*|` when files are given. Inside `arc0.lisp`
that was `(setf (arc-global '|main-file*|) ...)` because both the function
and the symbol are interned in `:arc`. From `boot.lisp` (default package,
no `(in-package :arc)`), it's now:

```lisp
(setf (arc::arc-global 'arc::|main-file*|)
      (namestring (truename (car (last files)))))
```

Double-colon access because `arc-global` is internal. Could export it, but
`boot.lisp` is the only external caller and it already crosses the line
into runtime guts (touching `*posix-argv*`, package-qualified symbols);
`arc::` keeps the export surface minimal.

## Key decisions

- **`interactive-stream-p` over `isatty(0)`.** Standard CL, no FFI, and
  it answers the right question (is this a terminal-shaped stream).
  Tested under `script -q /dev/null ./sharc` (which provides a pty) — the
  REPL path is taken, as expected.
- **Move the whole boot story to `boot.lisp`, not just a stdin shim.**
  The user explicitly asked for this. It also makes sense: `arc-boot`'s
  job is policy (which files to load, what to do when there are no
  args), not runtime. The runtime exposes `arc-load`, `arc-eval`,
  `arc-read`, `arc-tl`, and lets the entry point compose them.
- **Don't export `arc-global`.** Used `arc::` from `boot.lisp` instead.
  Adding to exports just to set one variable from one external file
  isn't worth the API growth.
- **Removed the eval-when "runtime loaded" banner.** It was a hint for
  the old `--load arc0.lisp` flow ("call `(arc:arc-boot)`"), which
  nothing uses anymore. `boot.lisp` calls `arc-boot` itself.
- **Kept the `ignore-errors` around `libs.arc` load.** Same as before —
  `libs.arc` is optional / experimental, and a missing or broken libs
  shouldn't kill `./sharc`.

## Files changed this session

- `boot.lisp` — now contains `arc-verbose-p`, `arc-vlog`, `arc-boot-dir`,
  `arc-load-stdin`, `arc-boot`, and the top-level call. The previous
  two-liner is gone.
- `arc0.lisp`:
  - `:export` clause (line 13): dropped `#:arc-boot`. Now exports
    `#:arc-load #:arc-eval #:arc-read #:arc-read-1 #:arc-tl`.
  - Old "Boot" section at the bottom (was ~lines 1430–1467) — deleted
    entirely (`arc-verbose-p`, `arc-vlog`, `arc-boot`, eval-when banner).

## Verification

- `echo '(prn "hi") (prn "there")' | ./sharc` → `hi\nthere\n`, exit 0.
- `./sharc /tmp/foo.arc` (file containing `(prn "from-file")`) → prints
  `from-file`, exits 0.
- `script -q /dev/null ./sharc` (simulated tty) → drops into REPL with
  the `Use (quit) to quit…` banner and `arc>` prompt.

## Current state

- All work uncommitted on `main`. No commits made yet this session.
- No tests run beyond the three smoke checks above; `test.arc` was not
  rerun. The change is to the boot dispatcher, not to anything `test.arc`
  exercises, so a regression there is unlikely but worth a sanity run
  before closing out.
