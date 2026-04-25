## Handoff 022: README.md + MIT relicense — 2026-04-25

The repo had no top-level README, and `copyright` carried the original
Arc 3.1 Artistic License 2.0 notice. Shawn emailed Paul Graham asking
to release Arc under MIT and got the OK, so we relicensed and wrote a
README that frames clarc6 in the context of dang's HN-on-Common-Lisp
migration.

## Changes

- New `README.md`:
  - Intro pointing at the HN announcement
    ([item 44099006](https://news.ycombinator.com/item?id=44099006))
    and Vincent Massol's [Lisp Journey write-up](https://lisp-journey.gitlab.io/blog/hacker-news-now-runs-on-top-of-common-lisp/),
    framing clarc6 as an independent open-source Arc-on-Common-Lisp
    runtime in the same spirit as dang's *Clarc*.
  - `## Requirements` hoisted above both run sections (single SBCL
    install line, no duplication).
  - `## Running the tests` (`./test.arc`, ~193 passed, 0 failed).
  - `## Running News` lifted from `how-to-run-news.md` (mkdir, admins,
    `./clarc`, `(load "news.arc")`, `(nsv)`, localhost:8080).
  - `## Customizing News` and `## Performance tuning` (cache, direct
    calls, explicit flush) — same content as `how-to-run-news.md`.
  - `## Layout` mapping the top-level `.arc` / `.lisp` files.
  - `## Development history` pointing readers at
    `docs/agents/handoff/`, starting with handoff 001.
  - `## License` noting MIT with PG's permission.

- `copyright`: replaced the Artistic License 2.0 notice with the
  standard MIT license text, keeping the "Copyright (c) Paul Graham
  and Robert Morris" attribution line.

## Why this matters for future sessions

- `how-to-run-news.md` and `README.md` now overlap. If you change the
  News setup steps, update both — or fold one into the other.
- The handoff index in the README links to `docs/agents/handoff/`, so
  keep new handoffs in that directory with the same `NNN-slug.md`
  pattern; the README's "starting with 001" link should stay valid.
- License is now MIT. Don't reintroduce Artistic License language in
  new files.

## Files changed

- `README.md` (new)
- `copyright` (Artistic 2.0 → MIT)
