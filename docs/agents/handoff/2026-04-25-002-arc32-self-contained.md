# Handoff: arc3.2 self-contained copy — 2026-04-25

## What was accomplished

- Copied all arc3.2 source files (`*.arc`, `*.scm`, `copyright`, `how-to-run-news`) into the klarc repo root so the project is self-contained.
- Copied `../arc3.2/static/*` (`arc.png`, `grayarrow.gif`, `graydown.gif`, `robots.txt`, `s.gif`) into `klarc/static/`.
- Updated `klarc` shell script: default `arc-dir` is now `$DIR/` (the script's own directory) instead of `../arc3.2/`. `ARC_DIR` env override still works.
- Exported `arc-tl` from the `arc` package (`arc0.lisp` line 10) so callers can use `(arc:arc-tl)` to re-enter the Arc REPL after a CL debugger interrupt.
- Updated the Arc REPL banner to print `(arc:arc-tl)` instead of `(tl)`.

## Key decisions

- **Copy, not symlink**: files are copied directly so there's no dependency on `../arc3.2/` at all.
- **`arc-tl` export**: SBCL upcase-reads all symbols, so `arc-tl` is interned as `ARC-TL`; the `#:arc-tl` in the export list is also read as `ARC-TL`, so they match and `(arc:arc-tl)` works correctly at the SBCL prompt.

## Current state

The repo is now fully self-contained. `./klarc` boots from its own directory with no sibling `arc3.2/` required.

After a CL debugger interrupt, use:
```
1        ; select ABORT restart to return to SBCL top level
(arc:arc-tl)   ; re-enter the Arc REPL
```

## Next steps

- Load and test `news.arc` (the HN application)
- Wire up real URL handlers / test a page render end-to-end
- Profile under load; tune `sb-thread` concurrency for multi-core
