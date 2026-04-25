## Handoff 021: `how-to-run-news` → `how-to-run-news.md`, sbcl-ified — 2026-04-25

The top-level `how-to-run-news` was the original Arc 3.1 instructions:
unpack `arc3.1.tar`, run `racket -f as.scm`, etc. None of that applies
to clarc6, which runs on SBCL via `./clarc`.

## Fix

- `git mv how-to-run-news how-to-run-news.md` so it renders on GitHub.
- Replace Racket/Arc 3.1 setup with the clarc workflow:
  - Note that SBCL is required (`brew install sbcl` /
    `apt install sbcl`).
  - `mkdir -p arc && echo myname > arc/admins && ./clarc`.
  - Then `(load "news.arc")` / `(nsv)` at the arc prompt.
- Markdown-format the rest (headings, fenced code blocks for the
  performance tunables).

## Files changed

- `how-to-run-news` → `how-to-run-news.md` (rename + rewrite).
