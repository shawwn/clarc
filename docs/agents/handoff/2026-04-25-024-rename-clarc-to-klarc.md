## Handoff 024: rename project from clarc → klarc — 2026-04-25

The project had been called `clarc`, which collides with dang's *Clarc*
(the closed-source compiler that powers HN's Arc-on-SBCL migration).
Renamed our runtime to `klarc` (with a `k`) so the two are
unambiguous in writing and at the shell.

## Changes

- `clarc` → `klarc` (`git mv`, executable bit preserved). The shell
  launcher now lives at `./klarc`.
- `test.arc` shebang updated: `#!./clarc` → `#!./klarc`.
- `README.md`: title `# clarc` → `# klarc`. Intro now reads
  "...a compiler called *Clarc* (with a `c`) that dang had been
  developing..." so the dang-vs-us distinction is explicit on first
  mention. Layout entry and the run-News command updated to `./klarc`.
- `how-to-run-news.md`: `./clarc` → `./klarc`.
- All handoff files updated to refer to our runtime as `klarc`.
  References to dang's *Clarc* (capital `C`, italicised) are
  preserved verbatim.
- Handoff filename `2026-04-25-009-clarc-script-args.md` → `…-klarc-
  script-args.md` (via `git mv`).

## Things deliberately not renamed

- The repo directory is `clarc7/` on my disk. The task didn't ask for
  a directory rename and it's outside the working tree, so left alone.
- Any future README/handoff text referring to "dang's *Clarc*" — that
  is a proper noun for a different project. Don't fold it into `klarc`.

## Files changed

- `klarc` (renamed from `clarc`)
- `README.md`
- `test.arc`
- `how-to-run-news.md`
- `docs/agents/handoff/2026-04-25-001-arc0-port.md`
- `docs/agents/handoff/2026-04-25-002-arc32-self-contained.md`
- `docs/agents/handoff/2026-04-25-009-klarc-script-args.md` (renamed)
- `docs/agents/handoff/2026-04-25-016-add-test-arc-from-lumen.md`
- `docs/agents/handoff/2026-04-25-019-dir-basenames.md`
- `docs/agents/handoff/2026-04-25-021-how-to-run-news-md.md`
- `docs/agents/handoff/2026-04-25-022-readme-and-mit-license.md`
