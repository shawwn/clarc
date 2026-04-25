# Handoff: ssyntax trailing-char fix — 2026-04-25

## What was accomplished

### Skip trailing char when scanning for ssyntax in `ssyntax-p`

`ssyntax-p` in `arc0.lisp` previously started its right-to-left scan at `(1- (length n))`, i.e. it inspected every character of the symbol name including the final one. This caused symbols whose only ssyntax-looking character was the last one (e.g. `foo.`, `foo!`) to be flagged as ssyntax even though there is nothing for the operator to act on after the trailing punctuation.

The fix changes the starting index to `(- (length n) 2)`, so the final character is excluded from the scan:

```lisp
(defun ssyntax-p (x)
  (and (symbolp x)
       (not (or (string= (symbol-name x) "+")
                (string= (symbol-name x) "++")
                (string= (symbol-name x) "_")))
       (let ((n (symbol-name x)))
         (has-ssyntax-char-p n (- (length n) 2)))))
```

`has-ssyntax-char-p` itself is unchanged — it still recurses leftwards looking for any of `#\: #\~ #\& #\. #\!`.

## Key decisions

- **One-character offset, not a special case for each operator**: Every ssyntax operator (`:`, `~`, `&`, `.`, `!`) needs at least one character after it to be meaningful, so simply skipping the last position is sufficient and avoids per-char logic.
- **Leave the `+`/`++`/`_` early-out untouched**: Those are explicit non-ssyntax exceptions and aren't affected by the trailing-char question.

## Files changed this session

- `arc0.lisp` line 281 — `(1- (length n))` → `(- (length n) 2)` in `ssyntax-p`.

## Current state

Committed as `98d95f1` on `main`. `test.arc` is still present as an untracked file from earlier sessions; it was not touched.
