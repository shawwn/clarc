;;;; sbcl --script boot.lisp [file...]
;;;;
;;;; Arc bootstrap entry point -- equivalent of arc3.2/as.scm. Loads
;;;; the Arc runtime (arc.arc + libs.arc), then either runs each given
;;;; file as a script and exits, or drops into the Arc REPL when no
;;;; file arguments are given.

(load (merge-pathnames "arc0.lisp" *load-pathname*))

(arc:arc-boot
 :arc-dir (let ((env (uiop:getenv "ARC_DIR")))
            (if (and env (not (string= env "")))
                env
                (namestring (uiop:pathname-directory-pathname *load-pathname*))))
 :files (cdr sb-ext:*posix-argv*))
