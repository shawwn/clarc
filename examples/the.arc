#!./sharc

; Thread-local variables in arc, modeled on dang's news.arc trick
; (HN id 11242977).
;
; The motivating problem: a web request handler has a stack of
; functions that all need access to "the current user" and "the
; current IP address," but most of them don't otherwise care about
; those values --- they just need to pass them down to a few
; functions deep in the call tree that *do* care. Threading those
; arguments through every signature is noise:
;
;   (def render-page (user ip path params) ...)
;   (def render-comment (user ip comment) ...)
;   (def can-edit? (user comment) ...)
;
; Almost every function picks up `user` and `ip` only to forward
; them on. The signatures stop reflecting what the function
; actually needs.
;
; The thread-local trick: store request-scoped values in a per-
; thread table, accessed via (the var). Functions that genuinely
; need the value declare (t var) in their parameter list, which
; defaults to (the var) but can still be overridden by an explicit
; argument. Functions that just forward don't mention it at all.
;
; One important rule: (t var) is implemented as an optional
; parameter, so it MUST come at the end of the parameter list ---
; required args first, then any (t ...) trailing. Otherwise a
; positional argument will silently fill the (t var) slot and the
; required arg behind it will be nil. This is a CL/arc semantic,
; not a sharc choice; same rule as for (o ...) optionals.
;
; Run with:  ./examples/the.arc
; Or load:   (load "examples/the.arc") (demo)


; ---- a tiny app: comment editing ----------------------------------
;
; Imagine a Hacker-News-style site. The interesting business rules
; are about comments: who can edit them, what they look like
; rendered, etc. Most of those rules need to know "who's logged in"
; and "where are they connecting from."

(deftem user
  name      nil
  is-admin  nil)

(deftem comment
  author    nil  ; a user
  body      ""
  ip        nil) ; ip the comment was posted from

(def show-comment (c)
  ;; A "view" function. Doesn't take user/ip --- those are ambient.
  ;; Calls helpers that DO need them, but we don't have to thread
  ;; them through this function's signature.
  (string c!author!name " said: " c!body
          (if (can-edit? c) " [edit]" "")))

(def can-edit? (c (t me))
  ;; A user can edit if they're the author, or if they're an admin.
  ;; (t me) at the END of the parameter list means: if the caller
  ;; didn't pass `me`, default to the thread-local `me` (the
  ;; logged-in user). Required args go first; (t ...) defaults go
  ;; last, so callers can omit them.
  (and me
       (or (is me!name c!author!name)
           me!is-admin)))

(def log-action (action (t me) (t ip))
  ;; Audit log entry. Pulls me and ip from thread-locals by default.
  ;; Note: required `action` first, then (t me) (t ip) trailing.
  (prn "  [audit] user=" (and me me!name)
       " ip=" ip
       " action=" action))


; ---- simulated request flow ---------------------------------------
;
; Each "request" sets up its thread-locals (me + ip), then runs a
; handler. In a real server each request would run on its own
; thread, so the locals would be naturally isolated; here we use
; w/me and w/the to scope them within a single thread.

(mac w/request (user ip . body)
  `(w/the me ,user
     (w/the ip ,ip
       ,@body)))

(def demo ()
  (withs (pg     (inst 'user 'name "pg"   'is-admin t)
          dang   (inst 'user 'name "dang" 'is-admin t)
          jcs    (inst 'user 'name "jcs")
          c1     (inst 'comment 'author jcs 'body "neat hack" 'ip "1.2.3.4"))

    (prn "--- pg viewing jcs's comment ---")
    (w/request pg "10.0.0.1"
      (prn (show-comment c1))         ; pg can edit (admin)
      (log-action 'view))

    (prn)
    (prn "--- jcs viewing their own comment ---")
    (w/request jcs "5.6.7.8"
      (prn (show-comment c1))         ; jcs can edit (author)
      (log-action 'view))

    (prn)
    (prn "--- dang viewing as admin tools ---")
    (w/request dang "127.0.0.1"
      (prn (show-comment c1))         ; dang can edit (admin)
      (log-action 'view))

    (prn)
    (prn "--- explicit override (admin tool inspecting as another user) ---")
    (w/request dang "127.0.0.1"
      ; can-edit? takes (t me); pass jcs explicitly to inspect what
      ; jcs would see, without changing thread-local me.
      (prn "would jcs see the edit link? " (can-edit? c1 jcs))
      ; meanwhile log-action still reflects the real actor:
      (log-action 'inspect-as))))


; ---- demo ---------------------------------------------------------

(when (main)
  (demo))
