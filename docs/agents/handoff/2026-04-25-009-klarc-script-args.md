# Handoff: klarc script file args — 2026-04-25

## What was accomplished

### `klarc <file>...` now loads files and exits

Previously the `klarc` shell script always dropped into the Arc REPL after
booting. Running `klarc test.arc` had no way to load `test.arc`; the user had
to enter the REPL and `(load "test.arc")` manually. Now any positional args
passed to the script are loaded after `arc.arc`/`libs.arc`, and the process
exits with status 0 instead of starting the toplevel.

`arc-boot` gained a `:files` keyword. When non-nil, it loads each path in
order, then calls `(uiop:quit 0)`. When nil, the original "Arc ready." +
`arc-tl` REPL behaviour is preserved — there are no other call sites of
`arc-boot` so the keyword is effectively script-only today.

The `klarc` script now builds a `(list "f1" "f2" ...)` form for the `:files`
keyword from `"$@"`, escaping `\` and `"` in each path with `sed` before
splicing into the `--eval` string. If no args are given the boot expression
is identical to before, so interactive use is unchanged.

## Key decisions

- **Quit inside `arc-boot` rather than from the script.** Keeping the
  exit-vs-REPL decision in Lisp means the script stays a thin shim and a
  programmatic caller of `arc-boot` (e.g. tests, future entrypoints) gets the
  same semantics by passing `:files`.
- **`uiop:quit` over `sb-ext:exit`.** `uiop` is already used elsewhere in
  `arc-boot` (for `pathname-directory-pathname`) and is portable across CL
  implementations should we ever run on something other than SBCL.
- **Pass files as a Lisp list, not a single string.** Leaves room for
  `klarc a.arc b.arc` to load multiple files in order without re-parsing in
  Lisp. Shell-side escaping handles spaces/quotes in paths.
- **No flag parsing yet.** Anything starting with `-` would currently be
  passed to `arc-load` and fail. If we want `--eval`, `-i`, or
  `--` separators later, parse them in the script before building `FILES`.

## Files changed this session

- `arc0.lisp` — `arc-boot` line 1351: added `:files` keyword; new `cond`
  branch loads each file and `(uiop:quit 0)` instead of entering `arc-tl`.
- `klarc` — builds a `:files (list ...)` form from `"$@"` with `\`/`"`
  escaping; falls back to the original boot form when no args are given.

## Verification

`./klarc test.arc` boots, prints the usual compilation noise from
`arc.arc`/`libs.arc`, then prints `18 passed, 0 failed` from `test.arc` and
exits. `./klarc` (no args) still drops into the REPL.

## Current state

Uncommitted on `main` alongside the previous untracked `test.arc`. Commit
covers `arc0.lisp` and `klarc` only.
