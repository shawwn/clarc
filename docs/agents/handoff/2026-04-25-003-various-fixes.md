# Handoff: various runtime fixes — 2026-04-25

## What was accomplished

Six bugs fixed while running the news app (HN clone) in the SBCL port.

### 1. `randb` primitive + `rand-string` refactor (`arc0.lisp`, `arc.arc`)
- Added `(randb)` to `arc0.lisp`: lazily opens `/dev/urandom` once as a binary stream and returns one byte per call.
- Refactored `rand-string` in `arc.arc` to call `(randb)` instead of opening `/dev/urandom` itself with `w/infile`. Removes the repeated file-open overhead and the `w/infile` nesting.

### 2. Static binary file serving (`arc0.lisp`, `arc.arc`, `srv.arc`)
- **Symptom**: `arc.png`, `s.gif` etc. failed with "not a binary input stream".
- **Root cause 1**: `infile` opens as `element-type 'character`; `readb` calls `read-byte` which requires a binary stream.
- **Root cause 2**: `writeb` to the socket output stream also fails since the socket was `element-type 'character`.
- **Fixes**:
  - Added `infile-binary` primitive in `arc0.lisp` (`element-type '(unsigned-byte 8)`).
  - Added `w/infile-binary` macro in `arc.arc` (same `expander` pattern as `w/infile`).
  - Changed `arc-socket-accept` socket stream from `:element-type 'character` to `:element-type :default` (SBCL bivalent stream — supports both `read-char`/`write-char` and `read-byte`/`write-byte`).
  - Changed `srv.arc` static file loop from `w/infile` to `w/infile-binary`.

### 3. Symbol display bug — form labels and fnids (`arc0.lisp`)
- **Symptom**: Login page showed `ARC::|username|:` and `ARC::TJCB5067B0` as field labels/values.
- **Root cause**: `arc-disp-val` fell through to `(write x :stream port :readably nil)` for symbols. In server threads, `*package*` is not `:arc`, so `write` includes the `ARC::` package prefix and `|...|` escape bars for lowercase symbols.
- **Fix**: Added `((symbolp x) (write-string (symbol-name x) port))` branch in `arc-disp-val` before the catch-all `write` clause. `symbol-name` returns just the bare name string regardless of current package.

### 4. Double `arc/` directory in `mvfile` (`arc0.lisp`)
- **Symptom**: `couldn't rename arc/cooks.tmp to arc/arc/cooks.tmp`.
- **Root cause**: SBCL's `rename-file` internally does `(merge-pathnames new-name (truename old))`, so a relative `new` like `"arc/cooks"` gets its directory appended to old's absolute directory `…/arc/`, doubling it. The old extension was also inherited.
- **Fix**: Before calling `rename-file`, convert `new` to an absolute path (via `merge-pathnames` with `*default-pathname-defaults*`) and set its type to `:unspecific` if nil (so the old `.tmp` extension isn't inherited).

### 5. `system` stdout capture for `shash` (`arc0.lisp`)
- **Symptom**: Login attempt crashed with `The value -1 is not of type (UNSIGNED-BYTE 45) when binding COUNT`.
- **Root cause**: `shash` in `app.arc` uses `(tostring (system "openssl dgst -sha1 ..."))` to capture the hash. But `system` ran the subprocess with stdout going to the process terminal, not Arc's `*standard-output*`, so `tostring` captured `""`. Then `(cut "" 0 (- (len "") 1))` = `(cut "" 0 -1)` caused the negative-length array error.
- **Fix**: Changed `system` in `arc0.lisp` to run with `:output :stream`, then loop-copy the subprocess stdout to `*standard-output*`. `tostring` (which rebinds `*standard-output*`) now captures it correctly.

## Key decisions

- **Bivalent socket stream** rather than a separate binary socket: `:element-type :default` in SBCL gives a stream that supports both `read-char`/`write-char` (for HTTP headers) and `read-byte`/`write-byte` (for binary bodies). The `arc-limited-stream` Gray stream wrapper uses `read-char` on the underlying stream, which still works on a bivalent stream.
- **Pure-CL `mvfile`** rather than `sb-posix:rename`: `sb-posix` is not available on the macOS ARM SBCL build (reader error at load time). Using `make-pathname` with `:unspecific` type + `merge-pathnames` against `*default-pathname-defaults*` achieves the same POSIX semantics portably.
- **`symbol-name` in `arc-disp-val`**: Arc's `pr`/`disp` should behave like Racket's `display` — symbols print as their bare name. The `null` check stays above `symbolp` since `nil` is a symbol in CL but should display as nothing.

## Current state

The news app (`news.arc`) now boots and serves pages. Login/create-account forms render correctly. Static images/GIFs are served. Saving tables (cookies, passwords) works. Password hashing via `openssl` works.

Known remaining issues (not investigated this session):
- No SSL; runs HTTP only on port 1234.
- Thread interruption ("srv thread took too long") can still hit if a request takes >30s — this is normal Arc behavior.

## Files changed this session

- `arc0.lisp` — `randb`, `infile-binary`, `arc-disp-val` symbol branch, bivalent socket, `mvfile` pathname fix, `system` stdout capture.
- `arc.arc` — `w/infile-binary` macro, `rand-string` uses `randb`.
- `srv.arc` — static file loop uses `w/infile-binary`.
