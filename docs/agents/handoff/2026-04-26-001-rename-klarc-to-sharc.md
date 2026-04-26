## Handoff 001: rename project from klarc → sharc — 2026-04-26

Renamed the runtime from `klarc` to `sharc`. No collision motivation
this time — just a project rename. The shell launcher now lives at
`./sharc`.

## Changes

- `klarc` → `sharc` (`git mv`, executable bit preserved).
- Shebangs updated: `#!./klarc` → `#!./sharc` in `news.arc`,
  `blog.arc`, `test.arc`.
- `README.md`: title `# klarc` → `# sharc`; layout entry
  `` `klarc` `` → `` `sharc` ``.
- `how-to-run-news.md`: `./klarc` → `./sharc`.
- `arc.arc:1466` comment: "passed on the klarc command line" →
  "passed on the sharc command line".

## Things deliberately not renamed

- The repo directory on disk is still `/Users/shawn/ml/klarc`. User
  explicitly said to leave it — renaming would break the working
  shell session's CWD. The in-tree references are all updated.
- Handoff docs under `docs/agents/handoff/` were left untouched.
  They are historical records describing past state at the time they
  were written; rewriting them would falsify history. The previous
  rename handoff (`2026-04-25-024-rename-clarc-to-klarc.md`) followed
  the opposite policy and rewrote past handoffs — I chose not to
  repeat that, since it makes prior handoffs internally inconsistent
  with their own filenames and dates.

## Files changed

- `sharc` (renamed from `klarc`)
- `README.md`
- `news.arc`
- `blog.arc`
- `test.arc`
- `how-to-run-news.md`
- `arc.arc`
