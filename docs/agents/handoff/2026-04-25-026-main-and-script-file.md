# 2026-04-25-026: `main-file*`, `script-file*`, and `(main)`

## What changed

Added a Python-style mechanism (`if __name__ == "__main__":`) so an
`.arc` file can detect whether it is being run as the toplevel script.

Two new arc globals plus one predicate:

- `script-file*` -- absolute path of the file currently being loaded.
  Dynamically rebound by `load` (and by the lisp-side `arc-load`), so
  nested loads see their own filename and the previous value is
  restored on exit.
- `main-file*` -- absolute path of the toplevel script. Set once by
  `arc-boot` to the truename of the **last** file passed on the klarc
  command line.
- `(main)` -- predicate: true iff `script-file*` equals `main-file*`
  (and `main-file*` is non-nil, so the REPL doesn't accidentally
  satisfy it).

Idiom:

```arc
(when (main)
  (nsv))   ; or whatever toplevel side effects the script wants
```

## Multi-file semantics

`./klarc a.arc b.arc c.arc` loads each file in order; only `c.arc`
sees `(main)` as `t`. The earlier files are loaded as libraries.
This matches the user's stated requirement: "if multiple arc files
are passed on the command line, only the last one should run as
toplevel."

## Files touched

- `arc0.lisp`
  - `arc-load`: dynamically binds `script-file*` to
    `(namestring (truename p))` of the open file stream, with
    `unwind-protect` restoring the previous value.
  - `arc-boot`: sets `main-file*` to the truename of `(car (last files))`
    before loading any of the user's files.
- `arc.arc`
  - `(def load ...)` rebinds `script-file*` around the body using
    `after`, so arc-level `(load "x.arc")` participates too.
  - `(def main () ...)` added immediately after.
- `news.arc`
  - Added `#!./klarc` shebang and made the file executable, so
    `./news.arc` runs the server directly.
  - Appended `(when (main) (nsv))` at the bottom: starts the server
    when run as a script, but stays inert if loaded as a library
    (`arc> (load "news.arc")` still requires a manual `(nsv)`,
    matching prior behavior).
- `test.arc`
  - Wrapped the trailing `(run-tests)` in `(when (main) ...)` so
    loading `test.arc` as a library no longer auto-runs the suite;
    `./klarc test.arc` (or running it as `./test.arc` via its existing
    shebang) still runs everything.

## Why both lisp- and arc-side rebinding

The lisp `arc-load` is what the cmdline driver calls; the arc-level
`load` is what user scripts call. Both must rebind `script-file*`,
otherwise loading a library from the toplevel script would leave
`script-file*` pointing at the toplevel and the library would
incorrectly think it was main.

## Sanity check

```
$ ./klarc /tmp/a.arc /tmp/b.arc
loading a, ... main=
loading b, ... main=T          ; only b is main
  b is main
loading a (from b), ... main=  ; nested load: a is not main
back in b, ... main=T          ; restored
```

REPL: both globals are nil, `(main)` is nil.
