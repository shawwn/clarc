; Prompt: Web-based programming application.  4 Aug 06.

(= appdir* "arc/apps/")

(defop prompt req
  (if (admin (the me))
      (prompt-page)
      (pr "Sorry.")))

(def prompt-page msg
  (let user (the me)
    (ensure-dir appdir*)
    (ensure-dir (string appdir* user))
    (whitepage
      (prbold "Prompt")
      (hspace 20)
      (pr user " | ")
      (link "logout")
      (when msg (hspace 10) (apply pr msg))
      (br2)
      (tag (table border 0 cellspacing 10)
        (each app (dir (+ appdir* user))
          (tr (td app)
              (td (ulink user 'edit   (edit-app app)))
              (td (ulink user 'run    (run-app  app)))
              (td (hspace 40)
                  (ulink user 'delete (rem-app  app))))))
      (br2)
      (aform (fn (req)
               (when-umatch user
                 (aif (goodname arg!app)
                      (edit-app it)
                      (prompt-page "Bad name."))))
         (tab (row "name:" (input "app") (submit "create app")))))))

(def app-path (user app) 
  (and user app (+ appdir* user "/" app)))

(def read-app (user app)
  (aand (app-path user app) 
        (file-exists it)
        (readfile it)))

(def write-app (user app exprs)
  (awhen (app-path user app)
    (w/outfile o it 
      (each e exprs (write e o)))))

(def rem-app (app (t me))
  (let file (app-path me app)
    (if (file-exists file)
        (do (rmfile file)
            (prompt-page "Program " app " deleted."))
        (prompt-page "No such app."))))

(def edit-app (app (t me))
  (whitepage
    (pr "user: " me " app: " app)
    (br2)
    (aform (fn (req)
             (if (is (the me) me)
                 (do (when (is arg!cmd "save")
                       (write-app me app (readall arg!exprs)))
                     (prompt-page))
                 (login-page 'both nil
                             (fn (u ip) (w/me u (prompt-page))))))
      (textarea "exprs" 10 82
        (pprcode (read-app me app)))
      (br2)
      (buts 'cmd "save" "cancel"))))

(def pprcode (exprs)
  (each e exprs
    (ppr e)
    (pr "\n\n")))

(def view-app (app (t me))
  (whitepage
    (pr "user: " me " app: " app)
    (br2)
    (tag xmp (pprcode (read-app me app)))))

(def run-app (app (t me))
  (let exprs (read-app me app)
    (if exprs
        (on-err (fn (c) (pr "Error: " (details c)))
          (fn () (map eval exprs)))
        (prompt-page "Error: No application " app " for user " me))))

(wipe repl-history*)

(defop repl req
  (if (admin (the me))
      (replpage req)
      (pr "Sorry.")))

(def replpage (req)
  (whitepage
    (repl (readall (or arg!expr "")) "repl")))

(def repl (exprs url)
    (each expr exprs 
      (on-err (fn (c) (push (list expr c t) repl-history*))
              (fn () 
                (= that (eval expr) thatexpr expr)
                (push (list expr that) repl-history*))))
    (form url
      (textarea "expr" 8 60)
      (sp) 
      (submit))
    (tag xmp
      (each (expr val err) (firstn 20 repl-history*)
        (pr "> ")
        (ppr expr)
        (prn)
        (prn (if err "Error: " "")
             (ellipsize (tostring (write val)) 800)))))

