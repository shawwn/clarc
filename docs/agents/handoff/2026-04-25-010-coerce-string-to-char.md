# Handoff: coerce string→char — 2026-04-25

## What was accomplished

### `(coerce "a" 'char)` now returns `#\a`

Previously, coercing a string to `'char` fell through to the default
`Can't coerce string ~S to ~S` error. Added a new branch in `arc-coerce`'s
`(stringp x)` cond that returns `(char x 0)` when the string has exactly
one character, and errors with `Can't coerce string ~S to char` otherwise.

## Key decisions

- **One-char-only.** A multi-char string has no obvious char to pick.
  Erroring is safer than silently truncating to the first char.
- **Reuse the existing string-handling cond.** Symmetric with the other
  string→X cases (`sym`, `cons`, `num`, `int`).

## Files changed this session

- `arc0.lisp` — `arc-coerce` (~line 942): new `((string= tname "char") ...)`
  branch in the `(stringp x)` cond.

## Verification

REPL session:

```
arc> (coerce "a" 'char)
#\a
arc> (coerce "Z" 'char)
#\Z
```

## Current state

Coerce change is the only thing committed in this handoff's commit. The
working tree also has unrelated style-warning suppression edits in
`arc0.lisp` (stashed during the commit, then restored) and an untracked
`test.arc`; neither is part of this commit.
