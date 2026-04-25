## Handoff 019: `dir` returns basenames, not full paths — 2026-04-25

`(dir name)` was returning the full namestring of every match, e.g.
`"/Users/shawn/ml/clarc/arc/news/story/1"` instead of `"1"`. That broke
`load-items` in news.arc:170, which does `(map int (dir storydir*))` —
coerce blew up trying to turn the absolute path into an integer.

In Racket Arc the equivalent is `(map path->string (directory-list name))`,
which yields just the entries' base names. We need to match that.

## Fix

`arc0.lisp:1202` — rewrite `dir` to:

1. Glob `name/*.*` for files and `name/*/` for subdirectories
   separately. SBCL's `*.*` over a directory will also surface
   subdirectories as directory pathnames whose `file-namestring` is
   `""`, so we filter empties out of the file list.
2. Return `file-namestring` for files and the last
   `pathname-directory` component for subdirectories.

Result includes both files and subdirectories as bare basename strings.

## Verified

```
$ mkdir -p /tmp/dirtest/sub && touch /tmp/dirtest/{1,2,foo.txt}
arc> (dir "/tmp/dirtest")
("1" "2" "foo.txt" "sub")
```

`(load "news.arc")` followed by `(nsv 1234)` now gets past
`load-items` — the "Can't coerce string ... to int" error is gone.

## Files changed

- `arc0.lisp:1202-1214` — `dir` returns basename strings for files and
  subdirectories.
