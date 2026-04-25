# Handoff: muffle SBCL style-warnings — 2026-04-25

## What was accomplished

### Suppress SBCL style-warnings in `arc-eval`

SBCL emits `style-warning` for things like redefinitions and references to
undefined functions during eval. In an Arc REPL/load context these are
constant noise (every Arc def goes through `eval`, and forward references
between Arc forms look like undefined functions to the host Lisp), so they
were drowning out genuine output.

Two changes in `arc0.lisp`:

1. Top-level `declaim` (SBCL only, just after the `require`s) that muffles
   `cl:style-warning` at compile time.
2. `arc-eval` now wraps its `(eval (ac expr nil))` call in a
   `handler-bind` that calls `muffle-warning` on any `style-warning`
   raised at runtime. Non-SBCL builds still take the unwrapped path via
   `#-sbcl`.

## Key decisions

- **Muffle, don't disable.** Only `style-warning` is suppressed; real
  `warning`s and errors still surface.
- **SBCL-gated.** Other Lisps don't share SBCL's style-warning vocabulary,
  so the change is wrapped in `#+sbcl` / `#-sbcl` to keep portability.
- **Both compile-time and runtime.** The `declaim` covers warnings raised
  during compilation of `ac`-produced forms; the `handler-bind` covers
  warnings raised when those forms are actually run. Either alone leaks
  noise.

## Files changed this session

- `arc0.lisp` — added `declaim` near top (~line 8) and `handler-bind`
  wrapper inside `arc-eval` (~line 612).

## Current state

- Committed on `main`.
- Working tree still has untracked `test.arc` (scratch, not part of this
  change) — same as prior handoff noted.
