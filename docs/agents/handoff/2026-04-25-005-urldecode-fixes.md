# Handoff: urldecode and int-radix fixes — 2026-04-25

## What was accomplished

Two bugs fixed that together prevented the `/repl` endpoint from accepting any non-trivial expression (anything containing spaces, parentheses, or other characters that get URL-encoded in form submissions).

### 1. `urldecode` writes bytes to a character-only stream (`strings.arc`)

- **Symptom**: Submitting an expression in the `/repl` form caused `SIMPLE-TYPE-ERROR: #<SB-IMPL::STRING-OUTPUT-STREAM ...> is not a binary output stream` in the request-handler thread. The SBCL debugger triggered but could not attach (background thread, not foreground).
- **Root cause**: `urldecode` uses `tostring` internally, which redirects `*standard-output*` to a `STRING-OUTPUT-STREAM` (character-only). Inside that block, the `%XX` branch called `(writeb byte)` without an explicit stream argument. `writeb` defaults to `*standard-output*`, so it tried to call `write-byte` on the string stream. SBCL rejects this because `STRING-OUTPUT-STREAM` is not a binary stream.
- **How it fires for the REPL**: The REPL form POSTs the expression URL-encoded. `parseargs` in `srv.arc` calls `urldecode` on each argument value. Nearly any Arc expression contains `(`, `)`, or spaces — all percent-encoded — triggering the `%XX` branch.
- **Fix**: Replaced `(writeb (int ... 16))` with `(writec (coerce (int ... 16) 'char))`. The server uses `:external-format :latin-1`, so byte→char via `coerce` is correct for the full 0–255 range.

### 2. `(int string radix)` ignores the radix argument (`arc0.lisp`)

- **Symptom**: After fixing the `writeb` issue, a second error appeared: `SIMPLE-ERROR: Can't coerce string "2B" to int`. `"2B"` is the hex encoding of `+` (ASCII 43), produced when the REPL expression contains a literal `+` character (URL-encoded as `%2B`).
- **Root cause**: `arc-coerce` for string→int used `parse-num` (which calls `read-from-string`) regardless of whether a `radix` argument was supplied. `read-from-string` parses `"2B"` as a symbol, not a number, returning `nil`, which then errors. The `radix` optional parameter was only wired up for int→string conversion, not string→int.
- **Fix**: In the `(string= tname "int")` branch of `arc-coerce`, added a radix check: when `radix` is non-nil, use `(parse-integer x :radix radix)` instead of `parse-num`. `parse-integer` understands hex and other radixes natively. Wrapped in `ignore-errors` with a fallback error to match the existing style.

## Key decisions

- **`writec` + `coerce` rather than a separate binary buffer**: A more complete fix would accumulate raw bytes into a `(unsigned-byte 8)` array and then decode them as UTF-8. However the server's socket is Latin-1, Arc strings are character-based, and the existing codebase has no UTF-8 string infrastructure. `coerce byte 'char` (Latin-1 identity mapping) matches the rest of the server's encoding assumptions and is the minimal correct fix.
- **`parse-integer` for radix path, `parse-num` for default**: `parse-integer` is strict (errors on non-integer input) while `parse-num` is lenient (returns nil on failure). Keeping `parse-num` for the no-radix case preserves existing behaviour for decimal strings; using `parse-integer` for the radix case is correct because hex strings like `"2B"` are always integral.

## Files changed this session

- `strings.arc` — `urldecode`: replaced `(writeb ...)` with `(writec (coerce ... 'char))`.
- `arc0.lisp` — `arc-coerce` string→int: added radix branch using `parse-integer`.

## Current state

The `/repl` endpoint should now correctly accept and URL-decode any expression submitted via the form, including expressions with spaces, parentheses, `+`, and other special characters.

Known remaining issues (unchanged from session 004):
- No SSL; runs HTTP only on port 1234.
- Thread interruption ("srv thread took too long") can still hit if a request takes >30s — normal Arc behavior.
