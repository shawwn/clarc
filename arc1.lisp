;;; arc1.lisp -- Arc compiler for Common Lisp (SBCL)
;;; Port of arc3.2/ac.scm.  Usage: sbcl --load arc1.lisp

(load (merge-pathnames "arc0.lisp" *load-pathname*))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :asdf)
  (require :sb-bsd-sockets))

#+sbcl
(declaim (sb-ext:muffle-conditions cl:style-warning))

(defpackage :arc
  (:use :common-lisp)
  (:export #:arc-load #:arc-eval #:arc-read #:arc-read-1 #:arc-tl))

(in-package :arc)

;;;; ============================================================
;;;; Arc readtable
;;;; ============================================================

;;; Symbols used for Arc's quasiquote notation
(defvar *arc-qq-sym*  (intern "quasiquote"       :arc))
(defvar *arc-uq-sym*  (intern "unquote"          :arc))
(defvar *arc-uqs-sym* (intern "unquote-splicing" :arc))

;;;; ============================================================
;;;; Arc reader  (custom, to handle : . ! ~ & as symbol chars)
;;;; ============================================================
;;; CL's package: separator conflicts with Arc ssyntax (foo:bar = compose).
;;; We write our own tokenizer so : is just a constituent character.

(defun arc-whitespace-p (c)
  (member c '(#\space #\tab #\newline #\return #\page)))

(defun arc-delimiter-p (c)
  (or (arc-whitespace-p c)
      (member c '(#\( #\) #\[ #\] #\{ #\} #\" #\; ))))

(defun arc-read-vbar-segment (stream buf)
  "Read characters up to a closing |, writing them verbatim to BUF.
Backslash escapes the next character."
  (read-char stream)  ; consume opening |
  (loop
    (let ((c (read-char stream nil nil)))
      (cond
        ((null c) (error "Unexpected EOF in |...| symbol"))
        ((char= c #\|) (return))
        ((char= c #\\)
         (let ((next (read-char stream nil nil)))
           (when (null next) (error "Unexpected EOF after \\ in |...| symbol"))
           (write-char next buf)))
        (t (write-char c buf))))))

(defun arc-read-token (stream)
  "Read a bare token (symbol or number) from stream.
Handles |...| segments verbatim, allowing special chars in symbol names.
Returns (values string had-vbar-p) so the caller can distinguish a real
empty-name symbol (`||`) from no token at all."
  (let ((had-vbar nil))
    (values
     (with-output-to-string (buf)
       (loop
         (let ((c (peek-char nil stream nil nil)))
           (cond
             ((null c) (return))
             ((char= c #\|)
              (setf had-vbar t)
              (arc-read-vbar-segment stream buf))
             ((arc-delimiter-p c) (return))
             (t (write-char (read-char stream) buf))))))
     had-vbar)))

(defun arc-intern-token (str)
  "Convert a raw token string to a CL value."
  (cond
    ((string= str "") nil)
    ((string= str "nil") nil)
    ;; Intern t as arc::t (regular bindable symbol) rather than cl:t,
    ;; so it can be used as a lambda parameter name. ac translates
    ;; free references back to cl:t at expression position.
    ((string= str "t")   (intern "t" :arc))
    (t
     ;; Try number first
     (let ((n (ignore-errors
                (with-standard-io-syntax
                  (let ((*read-eval* nil)
                        (*readtable* (copy-readtable nil)))
                    (let ((v (read-from-string str)))
                      (if (numberp v) v nil)))))))
       (or n (intern str :arc))))))

(defun arc-read-string (stream)
  "Read a double-quoted string, handling backslash escapes."
  (with-output-to-string (buf)
    (loop
      (let ((c (read-char stream t nil)))
        (cond
          ((char= c #\") (return))
          ((char= c #\\)
           (let ((next (read-char stream t nil)))
             (write-char (case next
                           (#\n #\newline) (#\t #\tab) (#\r #\return)
                           (t next))
                         buf)))
          (t (write-char c buf)))))))

(defun arc-read-char-literal (stream)
  "Read #\\ character literal."
  ;; Already consumed #\\
  ;; If next char is a delimiter (e.g. #\ = space), read it directly.
  (let ((first (peek-char nil stream nil nil)))
    (when (or (null first) (arc-delimiter-p first))
      (return-from arc-read-char-literal
        (or (read-char stream nil nil)
            (error "EOF after #\\")))))
  (let ((buf (with-output-to-string (s)
               (loop
                 (let ((c (peek-char nil stream nil nil)))
                   (if (or (null c) (arc-delimiter-p c))
                       (return)
                       (write-char (read-char stream) s)))))))
    (cond
      ((string= buf "space")   #\space)
      ((string= buf "newline") #\newline)
      ((string= buf "tab")     #\tab)
      ((string= buf "return")  #\return)
      ((string= buf "null")    #\null)
      ((string= buf "nul")     #\null)
      ((= (length buf) 1)      (char buf 0))
      (t (error "Unknown character name: ~S" buf)))))

(defun arc-skip-comment (stream)
  (loop (let ((c (read-char stream nil nil)))
          (when (or (null c) (char= c #\newline)) (return)))))

(defun arc-read-list (stream close-char)
  "Read a list, handling dotted pairs."
  (let ((result nil))
    (loop
      (let ((c (arc-skip-ws stream)))
        (cond
          ((eq c :eof) (error "Unexpected EOF in list"))
          ((char= c close-char) (read-char stream) (return (nreverse result)))
          ((char= c #\.)
           ;; could be dot or number or symbol starting with .
           (read-char stream)
           (let ((next (peek-char nil stream nil nil)))
             (if (or (null next) (arc-delimiter-p next))
                 ;; It's a dotted-pair dot
                 (progn
                   (arc-skip-ws stream)
                   (let ((tail (arc-read-1 stream)))
                     (arc-skip-ws stream)
                     (let ((c2 (read-char stream nil nil)))
                       (unless (and c2 (char= c2 close-char))
                         (error "Expected ~C after cdr of dotted pair" close-char)))
                     (return (nconc (nreverse result) tail))))
                 ;; Not a dot - unread and read as token
                 (progn
                   (unread-char #\. stream)
                   (push (arc-read-1 stream) result)))))
          (t
           (push (arc-read-1 stream) result)))))))

(defun arc-skip-ws (stream)
  "Skip whitespace and comments.  Returns the next char (peeked, not
   consumed) or :eof.  On a TTY, `peek-char' triggers a read syscall;
   returning the char lets callers avoid a second peek that would
   require a second EOF (Ctrl-D) to dislodge."
  (loop
    (let ((c (peek-char nil stream nil :eof)))
      (cond
        ((eq c :eof) (return :eof))
        ((char= c #\;) (arc-skip-comment stream))
        ((arc-whitespace-p c) (read-char stream))
        (t (return c))))))

(defun arc-read-1 (stream)
  "Read one Arc expression from stream."
  (let ((c (arc-skip-ws stream)))
    (cond
      ((eq c :eof) (values :eof t))
      ((char= c #\()
       (read-char stream)
       (arc-read-list stream #\)))
      ((char= c #\[)
       (read-char stream)
       (let ((body (arc-read-list stream #\])))
         (cons (intern "%brackets" :arc) body)))
      ((char= c #\{)
       (read-char stream)
       (let ((body (arc-read-list stream #\})))
         (cons (intern "%braces" :arc) body)))
      ((char= c #\")
       (read-char stream)
       (arc-read-string stream))
      ((char= c #\')
       (read-char stream)
       (list (intern "quote" :arc) (arc-read-1 stream)))
      ((char= c #\`)
       (read-char stream)
       (list *arc-qq-sym* (arc-read-1 stream)))
      ((char= c #\,)
       (read-char stream)
       (let ((next (peek-char nil stream nil nil)))
         (if (and next (char= next #\@))
             (progn (read-char stream)
                    (list *arc-uqs-sym* (arc-read-1 stream)))
             (list *arc-uq-sym* (arc-read-1 stream)))))
      ((char= c #\#)
       (read-char stream)
       (let ((c2 (read-char stream t nil)))
         (cond
           ((char= c2 #\\)
            (arc-read-char-literal stream))
           ((char= c2 #\()
            ;; #(v0 v1 ...) - vector literal
            (apply #'vector (arc-read-list stream #\))))
           ((or (char= c2 #\t) (char= c2 #\T)) t)
           ((or (char= c2 #\f) (char= c2 #\F)) nil)
           ;; skip shebangs
           ((char= c2 #\!)
            (read-line stream nil)
            (arc-read-1 stream))
           ((char= c2 #\')
            (list (intern "function" :arc) (arc-read-1 stream)))
           ((char= c2 #\`)
            (list (intern "quasisyntax" :arc) (arc-read-1 stream)))
           ((char= c2 #\,)
            (let ((next (peek-char nil stream nil nil)))
              (if (and next (char= next #\@))
                  (progn (read-char stream)
                         (list (intern "unsyntax-splicing" :arc)
                               (arc-read-1 stream)))
                  (list (intern "unsyntax" :arc)
                        (arc-read-1 stream)))))
           (t (error "Unknown # syntax: #~C" c2)))))
      ((char= c #\;)
       (arc-skip-comment stream)
       (arc-read-1 stream))
      ((char= c #\))
       (error "Unexpected )"))
      ((char= c #\])
       (error "Unexpected ]"))
      ((char= c #\})
       (error "Unexpected }"))
      (t
       ;; Symbol or number
       (multiple-value-bind (tok had-vbar) (arc-read-token stream)
         (cond
           ;; Real |...| with an empty content -> the empty-name symbol.
           ((and (string= tok "") had-vbar) (intern "" :arc))
           ((string= tok "") (arc-read-1 stream)) ; shouldn't happen
           (t (arc-intern-token tok))))))))

(defun arc-read (stream &optional (eof-error-p t) eof-value)
  (multiple-value-bind (val eof-p) (arc-read-1 stream)
    (if (eq val :eof)
        (if eof-error-p
            (error "End of file on ~S" stream)
            eof-value)
        val)))

;;;; ============================================================
;;;; Tagged types
;;;; ============================================================

(defstruct (arc-tagged (:constructor %arc-tag (type rep)))
  type rep)

(defun ar-tagged-p (x) (typep x 'arc-tagged))

;;;; ============================================================
;;;; Global variable table  (key = lowercase string)
;;;; ============================================================

(defvar *arc-globals*       (make-hash-table :test #'equal))
(defvar *arc-fn-signatures* (make-hash-table :test #'equal))

(defun arc-sym-key (s)
  "Normalize any CL symbol to a lowercase string key for Arc globals."
  (string-downcase (symbol-name s)))

(defun arc-global (s)
  (gethash (arc-sym-key s) *arc-globals*))

(defun (setf arc-global) (val s)
  (setf (gethash (arc-sym-key s) *arc-globals*) val))

(defun arc-bound-p (s)
  (nth-value 1 (gethash (arc-sym-key s) *arc-globals*)))

(defun arc-global-ref (s)
  (multiple-value-bind (v present) (gethash (arc-sym-key s) *arc-globals*)
    (if present v (error "Unbound variable: ~A" s))))

(defun arc-global-name (name)
  (intern (concatenate 'string "arc--" (symbol-name name))))

;;; xdef: define an Arc primitive.
;;; (xdef name value)              - bind name to value
;;; (xdef name (args...) body...)  - defun arc--NAME and bind name to it,
;;;                                  so the function shows up in backtraces.
(defmacro xdef (name x &rest body)
  (if (null body)
      `(setf (arc-global ',name) ,x)
      (let ((f (arc-global-name name)))
        `(progn (defun ,f ,x ,@body)
                (xdef ,name #',f)))))

;;;; ============================================================
;;;; Compiler options
;;;; ============================================================

(defvar *arc-atstrings*     t)
(defvar *arc-direct-calls*  nil)
(defvar *arc-explicit-flush* nil)

;;;; ============================================================
;;;; Utilities
;;;; ============================================================

(defun tnil (x) (if x t nil))

(defun arc-sym= (x name)
  "Case-insensitive comparison of symbol X to string NAME."
  (and (symbolp x) (string-equal (symbol-name x) name)))

(defun arc-list-p (x) (or (consp x) (null x)))

(defun arc-imap (f l)
  "map over proper or improper list (like Scheme's imap)."
  (cond ((consp l) (cons (funcall f (car l)) (arc-imap f (cdr l))))
        ((null l) nil)
        (t (funcall f l))))

(defun arc-car (x)
  (cond ((consp x) (car x))
        ((null x)  nil)
        (t (error "Can't take car of ~S" x))))

(defun arc-cdr (x)
  (cond ((consp x) (cdr x))
        ((null x)  nil)
        (t (error "Can't take cdr of ~S" x))))

;;;; ============================================================
;;;; ssyntax
;;;; ============================================================

(defun ssyntax-p (x)
  (and (symbolp x)
       (not (or (string= (symbol-name x) "+")
                (string= (symbol-name x) "++")
                (string= (symbol-name x) "_")))
       (let ((n (symbol-name x)))
         (has-ssyntax-char-p n (- (length n) 2)))))

(defun has-ssyntax-char-p (str i)
  (and (>= i 0)
       (or (member (char str i) '(#\: #\~ #\& #\. #\!))
           (has-ssyntax-char-p str (- i 1)))))

(defun arc-sym-intern (chars pkg)
  (intern (coerce chars 'string) pkg))

(defun chars->value (chars)
  (arc-intern-token (coerce chars 'string)))

(defun sym->chars (x) (coerce (symbol-name x) 'list))

(defun arc-tokens (test source token acc keepsep-p)
  (cond
    ((null source)
     (reverse (if (consp token) (cons (reverse token) acc) acc)))
    ((funcall test (car source))
     (arc-tokens test (cdr source) nil
                 (let ((rec (if (null token) acc (cons (reverse token) acc))))
                   (if keepsep-p (cons (car source) rec) rec))
                 keepsep-p))
    (t
     (arc-tokens test (cdr source) (cons (car source) token) acc keepsep-p))))

(defun sym-pkg (sym) (symbol-package sym))

(defun expand-ssyntax (sym)
  (let ((n (symbol-name sym)))
    (cond
      ((or (find #\: n) (find #\~ n)) (expand-compose sym))
      ((or (find #\. n) (find #\! n)) (expand-sexpr sym))
      ((find #\& n) (expand-and sym))
      (t (error "Unknown ssyntax: ~S" sym)))))

(defun expand-compose (sym)
  (let ((pkg (sym-pkg sym)))
    (let ((elts (mapcar
                 (lambda (tok)
                   (if (eql (car tok) #\~)
                       (if (null (cdr tok))
                           (intern "no" pkg)
                           `(,(intern "complement" pkg) ,(chars->value (cdr tok))))
                       (chars->value tok)))
                 (arc-tokens (lambda (c) (eql c #\:))
                             (sym->chars sym) nil nil nil))))
      (if (null (cdr elts))
          (car elts)
          (cons (intern "compose" pkg) elts)))))

(defun expand-and (sym)
  (let ((pkg (sym-pkg sym)))
    (let ((elts (mapcar #'chars->value
                        (arc-tokens (lambda (c) (eql c #\&))
                                    (sym->chars sym) nil nil nil))))
      (if (null (cdr elts))
          (car elts)
          (cons (intern "andf" pkg) elts)))))

(defun expand-sexpr (sym)
  (build-sexpr (reverse (arc-tokens (lambda (c) (or (eql c #\.) (eql c #\!)))
                                    (sym->chars sym) nil nil t))
               sym))

(defun build-sexpr (toks orig)
  (cond
    ((null toks) (intern "get" (sym-pkg orig)))
    ((null (cdr toks)) (chars->value (car toks)))
    (t (list (build-sexpr (cddr toks) orig)
             (if (eql (cadr toks) #\!)
                 (list 'quote (chars->value (car toks)))
                 (if (or (eql (car toks) #\.) (eql (car toks) #\!))
                     (error "Bad ssyntax: ~S" orig)
                     (chars->value (car toks))))))))

;;;; ============================================================
;;;; Arc compiler  (ac)
;;;; ============================================================

(defun literal-p (x)
  (or (eq x t) (characterp x) (stringp x) (numberp x) (null x)))

(defun ac (s env)
  (cond
    ((stringp s)   (ac-string s env))
    ((literal-p s)  s)
    ;; Arc nil/t with preserved case from arc-read
    ((and (symbolp s) (string-equal (symbol-name s) "nil")) nil)
    ;; Free reference to t -> cl:t; lex-bound t falls through to ac-var-ref
    ((and (symbolp s) (string-equal (symbol-name s) "t") (not (lex-p s env))) t)
    ((ssyntax-p s) (ac (expand-ssyntax s) env))
    ((symbolp s)   (ac-var-ref s env))
    ((and (consp s) (ssyntax-p (car s)))
     (ac (cons (expand-ssyntax (car s)) (cdr s)) env))
    ((and (consp s) (arc-sym= (car s) "quote"))
     `',(cadr s))
    ((and (consp s) (arc-sym= (car s) "quasiquote"))
     (ac-qq (cadr s) env))            ; ac-qq builds explicit cons/list code
    ((and (consp s) (arc-sym= (car s) "if"))
     (ac-if (cdr s) env))
    ((and (consp s) (arc-sym= (car s) "%do"))
     `(progn ,@(ac-body* (cdr s) env)))
    ((and (consp s) (arc-sym= (car s) "fn"))
     (ac-fn (cadr s) (cddr s) env))
    ((and (consp s) (arc-sym= (car s) "assign"))
     (ac-set (cdr s) env))
    ((and (consp s) (consp (car s)) (arc-sym= (caar s) "compose"))
     (ac (decompose (cdar s) (cdr s)) env))
    ((and (consp s) (consp (car s)) (arc-sym= (caar s) "complement"))
     (ac `(,(intern "no" (sym-pkg (caar s)))
           (,(cadar s) ,@(cdr s))) env))
    ((and (consp s) (consp (car s)) (arc-sym= (caar s) "andf"))
     (ac-andf s env))
    ((consp s) (ac-call (car s) (cdr s) env))
    (t (error "Bad object in expression: ~S" s))))

;;; Atstring expansion
(defun ac-string (s env)
  (if *arc-atstrings*
      (let ((pos (atpos s 0)))
        (if pos
            (ac (cons (intern "string" :arc)
                      (mapcar (lambda (x) (if (stringp x) (unescape-ats x) x))
                              (codestring s)))
                env)
            (copy-seq (unescape-ats s))))
      (copy-seq s)))

;;;; ---- quasiquote ----
;;; We compile Arc quasiquotes to explicit cons/list/append CL code.
;;; The Arc readtable produces (quasiquote ...) / (unquote ...) / (unquote-splicing ...)
;;; as plain s-expression lists.

(defun ac-qq (x env)
  "Entry: compile Arc (quasiquote x) to list-building CL code."
  (ac-qq1 1 x env))

(defun ac-qq1 (level x env)
  (cond
    ;; Level 0: compile as normal Arc expression
    ((= level 0) (ac x env))
    ;; nil -> CL nil
    ((null x) nil)
    ;; Non-cons atoms -> quoted literal
    ((not (consp x)) `',x)
    ;; (quasiquote inner) -> increase level
    ((arc-sym= (car x) "quasiquote")
     `(cons ',*arc-qq-sym* (cons ,(ac-qq1 (1+ level) (cadr x) env) nil)))
    ;; (unquote expr) at level 1 -> compile expr
    ((and (= level 1) (arc-sym= (car x) "unquote"))
     (ac (cadr x) env))
    ;; (unquote expr) at level > 1 -> wrap, reducing level
    ((arc-sym= (car x) "unquote")
     `(cons ',*arc-uq-sym* (cons ,(ac-qq1 (1- level) (cadr x) env) nil)))
    ;; Check car for unquote-splicing at level 1
    ((and (= level 1) (consp (car x)) (arc-sym= (caar x) "unquote-splicing"))
     `(append ,(ac (cadar x) env) ,(ac-qq1 1 (cdr x) env)))
    ;; (unquote-splicing expr) at level > 1 -> wrap, reducing level
    ((and (> level 1) (arc-sym= (car x) "unquote-splicing"))
     `(cons ',*arc-uqs-sym* (cons ,(ac-qq1 (1- level) (cadr x) env) nil)))
    ;; Normal cons cell
    (t
     `(cons ,(ac-qq1 level (car x) env)
            ,(ac-qq1 level (cdr x) env)))))

;;;; ---- if ----

(defun ac-if (args env)
  (cond
    ((null args) nil)
    ((null (cdr args)) (ac (car args) env))
    (t `(if ,(ac (car args) env)
            ,(ac (cadr args) env)
            ,(ac-if (cddr args) env)))))

;;;; ---- fn ----

(defun ac-fn (args body env)
  (if (ac-complex-args-p args)
      (ac-complex-fn args body env)
      (let ((largs (ac-arglist-cl args)))
        `(lambda ,largs
           ,@(ac-body* body (append (ac-arglist args) env))))))

;;; Convert Arc arglist to CL lambda list (handles rest params)
(defun ac-arglist-cl (args)
  (cond
    ((null args) nil)
    ((and (symbolp args) (not (arc-sym= args "nil")))
     `(&rest ,args))                       ; bare rest param
    ((symbolp (cdr args))
     (if (null (cdr args))
         (list (car args))
         (list (car args) '&rest (cdr args)))) ; (x . rest)
    (t (cons (car args) (ac-arglist-cl (cdr args))))))

(defun ac-complex-args-p (args)
  (cond
    ((or (null args) (arc-sym= args "nil")) nil)
    ((symbolp args) nil)
    ((and (consp args) (symbolp (car args))) (ac-complex-args-p (cdr args)))
    (t t)))

(defun ac-complex-fn (args body env)
  (let* ((ra (gensym "RA"))
         (z  (ac-complex-args args env ra t)))
    `(lambda (&rest ,ra)
       (let* ,z
         ,@(ac-body* body (append (ac-complex-getargs z) env))))))

(defun ac-complex-args (args env ra is-params)
  (cond
    ((or (null args) (arc-sym= args "nil")) nil)
    ((symbolp args) (list (list args ra)))
    ((consp args)
     (let* ((x (if (and (consp (car args)) (arc-sym= (caar args) "o"))
                   (ac-complex-opt (cadar args)
                                   (if (consp (cddar args)) (caddar args) nil)
                                   env ra)
                   (ac-complex-args
                    (car args) env
                    (if is-params `(car ,ra) `(ar-xcar ,ra))
                    nil)))
            (xa (ac-complex-getargs x)))
       (append x (ac-complex-args (cdr args)
                                  (append xa env)
                                  `(ar-xcdr ,ra)
                                  is-params))))
    (t (error "Can't understand fn arg list: ~S" args))))

(defun ac-complex-opt (var expr env ra)
  (list (list var `(if (consp ,ra) (car ,ra) ,(ac expr env)))))

(defun ac-complex-getargs (a) (mapcar #'car a))

;;; Arc arglist -> list of symbols for env tracking
(defun ac-arglist (a)
  (cond
    ((null a) nil)
    ((and (symbolp a) (not (arc-sym= a "nil"))) (list a))
    ((symbolp (cdr a)) (list (car a) (cdr a)))
    (t (cons (car a) (ac-arglist (cdr a))))))

(defun ac-body  (body env) (mapcar (lambda (x) (ac x env)) body))
(defun ac-body* (body env) (if (null body) '(nil) (ac-body body env)))

;;;; ---- assign / set ----

(defun ac-set (x env)
  `(progn ,@(ac-setn x env)))

(defun ac-setn (x env)
  (if (null x) nil
      (cons (ac-set1 (ac-macex (car x)) (cadr x) env)
            (ac-setn (cddr x) env))))

(defun ac-set1 (a b1 env)
  (if (symbolp a)
      (let ((b (ac b1 env)))
        `(let ((zz ,b))
           ,(cond
              ((arc-sym= a "nil") (error "Can't rebind nil"))
              ((arc-sym= a "t")   (error "Can't rebind t"))
              ((lex-p a env)      `(setq ,a zz))
              (t `(setf (arc-global ',a) zz)))
           zz))
      (error "First arg to assign must be a symbol: ~S" a)))

;;;; ---- call / macros ----

(defun ac-var-ref (s env)
  (if (lex-p s env) s `(arc-global-ref ',s)))

(defun lex-p (v env) (member v env :test #'eq))

(defun ac-call (fn args env)
  (let ((macfn (ac-macro-p fn)))
    (cond
      (macfn (ac-mac-call macfn args env))
      ((and (consp fn) (arc-sym= (car fn) "fn"))
       `(,(ac fn env) ,@(mapcar (lambda (x) (ac x env)) args)))
      ((= (length args) 0)
       `(ar-funcall0 ,(ac fn env)))
      ((= (length args) 1)
       `(ar-funcall1 ,(ac fn env) ,(ac (car args) env)))
      ((= (length args) 2)
       `(ar-funcall2 ,(ac fn env) ,(ac (car args) env) ,(ac (cadr args) env)))
      ((= (length args) 3)
       `(ar-funcall3 ,(ac fn env) ,(ac (car args) env)
                     ,(ac (cadr args) env) ,(ac (caddr args) env)))
      (t `(ar-apply ,(ac fn env)
                    (list ,@(mapcar (lambda (x) (ac x env)) args)))))))

(defun ac-mac-call (m args env)
  (ac (apply m args) env))

(defun ac-macro-p (fn)
  (when (symbolp fn)
    (let ((val (gethash (arc-sym-key fn) *arc-globals*)))
      (when (and val (ar-tagged-p val)
                 (arc-sym= (arc-tagged-type val) "mac"))
        (arc-tagged-rep val)))))

(defun ac-macex (e &optional once)
  (if (consp e)
      (let ((m (ac-macro-p (car e))))
        (if m
            (let ((exp (apply m (cdr e))))
              (if once exp (ac-macex exp)))
            e))
      e))

(defun decompose (fns args)
  (cond
    ((null fns)  `((fn (vals) (car vals)) ,@args))
    ((null (cdr fns)) (cons (car fns) args))
    (t (list (car fns) (decompose (cdr fns) args)))))

(defun ac-andf (s env)
  (let ((gs (mapcar (lambda (x) (declare (ignore x)) (gensym)) (cdr s))))
    (ac `((fn ,gs
            (and ,@(mapcar (lambda (f) `(,f ,@gs)) (cdar s))))
          ,@(cdr s))
        env)))

;;;; ============================================================
;;;; Arc eval / load
;;;; ============================================================

(defun arc-eval (expr)
  #+sbcl
  (handler-bind ((style-warning #'muffle-warning))
    (eval (ac expr nil)))
  #-sbcl
  (eval (ac expr nil)))

(defun arc-load (filename)
  (with-open-file (p filename :direction :input
                              :element-type 'character
                              :external-format :utf-8)
    (let ((path (namestring (truename p)))
          (prev (arc-global '|script-file*|)))
      (setf (arc-global '|script-file*|) path)
      (unwind-protect
           (loop
             (let ((x (arc-read p nil :eof)))
               (when (eq x :eof) (return))
               (arc-eval x)))
        (setf (arc-global '|script-file*|) prev)))))

;;;; ============================================================
;;;; Funcall helpers
;;;; ============================================================

(defun ar-funcall0 (fn)
  (if (functionp fn) (funcall fn) (ar-apply fn nil)))
(defun ar-funcall1 (fn a)
  (if (functionp fn) (funcall fn a) (ar-apply fn (list a))))
(defun ar-funcall2 (fn a b)
  (if (functionp fn) (funcall fn a b) (ar-apply fn (list a b))))
(defun ar-funcall3 (fn a b c)
  (if (functionp fn) (funcall fn a b c) (ar-apply fn (list a b c))))

(defun ar-apply (fn args)
  (cond
    ((functionp fn)  (apply fn args))
    ((consp fn)      (nth (car args) fn))
    ((stringp fn)    (char fn (car args)))
    ((hash-table-p fn)
     (let ((v (gethash (car args) fn :arc/missing)))
       (if (eq v :arc/missing)
           (if (cdr args) (cadr args) nil)
           v)))
    (t (error "Function call on non-function: ~S" fn))))

(defun ar-apply-args (args)
  (cond
    ((null args) nil)
    ((null (cdr args)) (car args))
    (t (cons (car args) (ar-apply-args (cdr args))))))

(defun ar-xcar (x) (if (null x) nil (car x)))
(defun ar-xcdr (x) (if (null x) nil (cdr x)))

;;;; ============================================================
;;;; Core primitives
;;;; ============================================================

(xdef cons #'cons)

(xdef car #'arc-car)

(xdef cdr #'arc-cdr)

(defun pairwise (pred lst)
  (cond ((null lst)       t)
        ((null (cdr lst)) t)
        ((null (funcall pred (car lst) (cadr lst))) nil)
        (t (pairwise pred (cdr lst)))))

(defun ar-is2 (a b)
  (tnil (or (eql a b)
            (and (numberp a) (numberp b) (= a b))
            (and (stringp a) (stringp b) (string= a b))
            (and (null a) (null b)))))

(xdef is (&rest args) (pairwise #'ar-is2 args))

(defun char-or-str-p (x) (or (stringp x) (characterp x)))

(defun ar-+2 (x y)
  (cond ((and (numberp x) (numberp y)) (+ x y))
        ((char-or-str-p x)
         (concatenate 'string
                      (if (characterp x) (string x) x)
                      (if (characterp y) (string y) y)))
        ((and (arc-list-p x) (arc-list-p y)) (append x y))
        (t (+ x y))))

(xdef + (&rest args)
  (cond
    ((null args) 0)
    ((char-or-str-p (car args))
     (apply #'concatenate 'string
            (mapcar (lambda (a)
                      (cond ((stringp a) a)
                            ((characterp a) (string a))
                            ((null a) "")
                            (t (format nil "~A" a))))
                    args)))
    ((arc-list-p (car args)) (apply #'append args))
    (t (apply #'+ args))))

(xdef - #'-)
(xdef * #'*)
(xdef / #'/)
(xdef mod #'mod)
(xdef expt #'expt)
(xdef sqrt #'sqrt)

(defun ar->2 (x y)
  (tnil (cond ((and (numberp x) (numberp y)) (> x y))
              ((and (stringp x) (stringp y)) (string> x y))
              ((and (symbolp x) (symbolp y))
               (string> (symbol-name x) (symbol-name y)))
              ((and (characterp x) (characterp y)) (char> x y))
              (t (> x y)))))

(defun ar-<2 (x y)
  (tnil (cond ((and (numberp x) (numberp y)) (< x y))
              ((and (stringp x) (stringp y)) (string< x y))
              ((and (symbolp x) (symbolp y))
               (string< (symbol-name x) (symbol-name y)))
              ((and (characterp x) (characterp y)) (char< x y))
              (t (< x y)))))

(xdef > (&rest args) (pairwise #'ar->2 args))
(xdef < (&rest args) (pairwise #'ar-<2 args))

(xdef len (x)
  (cond ((stringp x)    (length x))
        ((hash-table-p x) (hash-table-count x))
        (t (length x))))

;;;; ---- Type system ----

(defun ar-type (x)
  (cond
    ((ar-tagged-p x)                   (arc-tagged-type x))
    ((consp x)                         (intern "cons"    :arc))
    ((null x)                          (intern "sym"     :arc))
    ((symbolp x)                       (intern "sym"     :arc))
    ((functionp x)                     (intern "fn"      :arc))
    ((characterp x)                    (intern "char"    :arc))
    ((stringp x)                       (intern "string"  :arc))
    ((and (integerp x) (= x (truncate x))) (intern "int" :arc))
    ((numberp x)                       (intern "num"     :arc))
    ((hash-table-p x)                  (intern "table"   :arc))
    ((and (streamp x) (output-stream-p x)) (intern "output" :arc))
    ((and (streamp x) (input-stream-p x))  (intern "input"  :arc))
    ((typep x 'sb-thread:thread)       (intern "thread"  :arc))
    (t (error "Unknown type: ~S" x))))

(defun ar-tag (type rep)
  (if (and (ar-tagged-p rep)
           (arc-sym= (arc-tagged-type rep) (symbol-name type)))
      rep
      (%arc-tag type rep)))

(defun ar-rep (x)
  (if (ar-tagged-p x) (arc-tagged-rep x) x))

(xdef annotate #'ar-tag)
(xdef type     #'ar-type)
(xdef rep      #'ar-rep)

;;;; ---- Gensym ----

(defvar *arc-gensym-count* 0)
(defun ar-gensym ()
  (incf *arc-gensym-count*)
  (intern (format nil "gs~D" *arc-gensym-count*) :arc))

(xdef uniq #'ar-gensym)

;;;; ---- Continuations (escape-only) ----

(xdef ccc (f)
  (let ((tag (gensym "K")))
    (catch tag
      (ar-funcall1 f (lambda (x) (throw tag x))))))

;;;; ============================================================
;;;; I/O
;;;; ============================================================

(xdef infile (f)
  (open f :direction :input
          :element-type 'character
          :external-format :latin-1))

(xdef infile-binary (f)
  (open f :direction :input
          :element-type '(unsigned-byte 8)))

(xdef outfile (f &rest args)
  (open f :direction :output
          :element-type 'character
          :external-format :latin-1
          :if-exists (if (equal (car args) "append") :append :supersede)
          :if-does-not-exist :create))

(xdef instring  #'make-string-input-stream)
(xdef outstring () (make-string-output-stream))
(xdef inside    #'get-output-stream-string)

(xdef stdout () *standard-output*)
(xdef stdin  () *standard-input*)
(xdef stderr () *error-output*)

(xdef call-w/stdout (port thunk)
  (let ((*standard-output* port)) (ar-funcall0 thunk)))
(xdef call-w/stdin (port thunk)
  (let ((*standard-input* port)) (ar-funcall0 thunk)))

(xdef readc (&rest args)
  (let ((c (read-char (if args (car args) *standard-input*) nil nil)))
    (or c nil)))

(xdef readb (&rest args)
  (let ((b (read-byte (if args (car args) *standard-input*) nil nil)))
    (or b nil)))

(xdef peekc (&rest args)
  (let ((c (peek-char nil (if args (car args) *standard-input*) nil nil)))
    (or c nil)))

(xdef writec (c &rest args)
  (write-char c (if args (car args) *standard-output*))
  c)

(xdef writeb (b &rest args)
  (write-byte b (if args (car args) *standard-output*))
  b)

(defun arc-disp-val (x port)
  (cond
    ((stringp x)    (write-string x port))
    ((characterp x) (write-char x port))
    ((null x)       nil)
    ((symbolp x)    (write-string (symbol-name x) port))
    ((consp x)
     (write-char #\( port)
     (arc-write-val (car x) port)
     (let ((rest (cdr x)))
       (loop while rest do
         (cond
           ((consp rest)
            (write-char #\space port)
            (arc-write-val (car rest) port)
            (setf rest (cdr rest)))
           (t
            (write-string " . " port)
            (arc-write-val rest port)
            (setf rest nil)))))
     (write-char #\) port))
    (t (write x :stream port :readably nil))))

(defun arc-write-val (x port)
  (cond
    ((stringp x)    (write x :stream port))  ; quoted
    ((characterp x) (write x :stream port))
    ((null x)       (write-string "nil" port))
    ((eq x t)       (write-string "t" port))
    ((symbolp x)    (write-string (symbol-name x) port))
    ((consp x)
     (write-char #\( port)
     (arc-write-val (car x) port)
     (let ((rest (cdr x)))
       (loop while rest do
         (cond
           ((consp rest)
            (write-char #\space port)
            (arc-write-val (car rest) port)
            (setf rest (cdr rest)))
           (t
            (write-string " . " port)
            (arc-write-val rest port)
            (setf rest nil)))))
     (write-char #\) port))
    (t (write x :stream port :readably nil))))

(xdef disp (&rest args)
  (let ((port (if (cdr args) (cadr args) *standard-output*)))
    (when args (arc-disp-val (car args) port))
    (unless *arc-explicit-flush* (force-output port)))
  nil)

(xdef write (&rest args)
  (let ((port (if (cdr args) (cadr args) *standard-output*)))
    (when args (arc-write-val (car args) port))
    (unless *arc-explicit-flush* (force-output port)))
  nil)

(xdef sread (p eof)
  (arc-read p nil eof))

;;;; ---- coerce ----

(defun parse-num (s)
  (with-standard-io-syntax
    (let ((*read-eval* nil))
      (ignore-errors
        (let ((n (read-from-string s)))
          (if (numberp n) n nil))))))

(defun arc-coerce (x type &optional radix)
  (let ((tname (string-downcase
                (if (symbolp type) (symbol-name type) (string type)))))
    (cond
      ((ar-tagged-p x) (error "Can't coerce annotated object"))
      ((string= tname (string-downcase (symbol-name (ar-type x)))) x)
      ((characterp x)
       (cond ((string= tname "int")    (char-code x))
             ((string= tname "string") (string x))
             ((string= tname "sym")    (intern (string x) :arc))
             (t (error "Can't coerce char ~S to ~S" x type))))
      ((and (integerp x) (= x (truncate x)))
       (cond ((string= tname "num")    x)
             ((string= tname "char")   (code-char x))
             ((string= tname "string")
              (if radix
                  (format nil (format nil "~~~DR" radix) x)
                  (format nil "~D" x)))
             (t (error "Can't coerce int ~S to ~S" x type))))
      ((numberp x)
       (cond ((string= tname "int")    (round x))
             ((string= tname "char")   (code-char (round x)))
             ((string= tname "string") (format nil "~A" x))
             (t (error "Can't coerce num ~S to ~S" x type))))
      ((stringp x)
       (cond ((string= tname "sym")    (intern x :arc))
             ((string= tname "cons")   (coerce x 'list))
             ((string= tname "char")
              (if (= (length x) 1)
                  (char x 0)
                  (error "Can't coerce string ~S to char" x)))
             ((string= tname "num")
              (or (parse-num x) (error "Can't coerce string ~S to num" x)))
             ((string= tname "int")
              (if radix
                  (or (ignore-errors (parse-integer x :radix radix))
                      (error "Can't coerce string ~S to int" x))
                  (let ((n (parse-num x)))
                    (if n (round n) (error "Can't coerce string ~S to int" x)))))
             (t (error "Can't coerce string ~S to ~S" x type))))
      ((consp x)
       (cond ((string= tname "string")
              (apply #'concatenate 'string
                     (mapcar (lambda (c)
                               (if (characterp c) (string c) (format nil "~A" c)))
                             x)))
             (t (error "Can't coerce cons to ~S" type))))
      ((null x)
       (cond ((string= tname "string") "")
             (t (error "Can't coerce nil to ~S" type))))
      ((symbolp x)
       (cond ((string= tname "string") (symbol-name x))
             (t (error "Can't coerce sym ~S to ~S" x type))))
      (t x))))

(xdef coerce (x type &rest args) (arc-coerce x type (car args)))

;;;; ============================================================
;;;; Networking  (sb-bsd-sockets)
;;;; ============================================================

(defclass arc-server-socket ()
  ((sock :initarg :sock :reader ass-sock)))

;;; Gray stream wrapper with byte limit
(defclass arc-limited-stream (sb-gray:fundamental-character-input-stream)
  ((source :initarg :source :reader als-src)
   (limit  :initarg :limit  :reader als-limit)
   (count  :initform 0 :accessor als-count)))

(defmethod sb-gray:stream-read-char ((s arc-limited-stream))
  (if (>= (als-count s) (als-limit s))
      :eof
      (let ((c (read-char (als-src s) nil :eof)))
        (when (characterp c) (incf (als-count s)))
        c)))

(defmethod sb-gray:stream-unread-char ((s arc-limited-stream) c)
  (unread-char c (als-src s))
  (when (> (als-count s) 0) (decf (als-count s))))

(defmethod sb-gray:stream-peek-char ((s arc-limited-stream))
  (if (>= (als-count s) (als-limit s))
      :eof
      (peek-char nil (als-src s) nil :eof)))

(defmethod sb-gray:stream-line-column ((s arc-limited-stream)) nil)

(defmethod cl:close ((s arc-limited-stream) &key abort)
  (close (als-src s) :abort abort))

(defun arc-open-socket (port)
  (let ((s (make-instance 'sb-bsd-sockets:inet-socket
                          :type :stream :protocol :tcp)))
    (setf (sb-bsd-sockets:sockopt-reuse-address s) t)
    (sb-bsd-sockets:socket-bind s #(0 0 0 0) port)
    (sb-bsd-sockets:socket-listen s 50)
    (make-instance 'arc-server-socket :sock s)))

(defun arc-socket-accept (arc-sock)
  ;; socket-accept returns (client-socket ip-vec port)
  (multiple-value-bind (client ipv _port)
      (sb-bsd-sockets:socket-accept (ass-sock arc-sock))
    (declare (ignore _port))
    (let* ((ip  (format nil "~D.~D.~D.~D"
                        (aref ipv 0) (aref ipv 1)
                        (aref ipv 2) (aref ipv 3)))
           (stream (sb-bsd-sockets:socket-make-stream
                    client :input t :output t
                    :element-type :default
                    :external-format :latin-1
                    :buffering :full))
           (lim (make-instance 'arc-limited-stream
                               :source stream :limit 2000000)))
      (list lim stream ip))))

(xdef open-socket  #'arc-open-socket)
(xdef socket-accept #'arc-socket-accept)

(xdef setuid (uid)
  (handler-case
      (sb-alien:alien-funcall
       (sb-alien:extern-alien
        "setuid"
        (function sb-alien:int sb-alien:unsigned))
       uid)
    (error () nil))
  nil)

(xdef client-ip (port) (declare (ignore port)) "unknown")

;;;; ============================================================
;;;; Threading  (sb-thread)
;;;; ============================================================

(xdef new-thread (f)
  (sb-thread:make-thread
   (lambda ()
     (handler-case (ar-funcall0 f)
       (error (c) (arc-report-error c *error-output*) nil)))
   :name "arc"))

(xdef kill-thread (th) (sb-thread:terminate-thread th) nil)

(xdef break-thread (th)
  (sb-thread:interrupt-thread
   th (lambda () (error "Thread interrupted")))
  nil)

(xdef current-thread () sb-thread:*current-thread*)

(xdef dead (th) (tnil (not (sb-thread:thread-alive-p th))))

(xdef sleep (n) (sleep n) nil)

;;;; ---- atomic-invoke ----

(defvar *arc-mutex* (sb-thread:make-mutex :name "arc"))
(defvar *arc-atomic-owner* nil)

(xdef atomic-invoke (f)
  (if (eq sb-thread:*current-thread* *arc-atomic-owner*)
      (ar-funcall0 f)
      (sb-thread:with-mutex (*arc-mutex*)
        (let ((*arc-atomic-owner* sb-thread:*current-thread*))
          (ar-funcall0 f)))))

;;;; ============================================================
;;;; System calls
;;;; ============================================================

(xdef system (cmd)
  (let* ((proc (sb-ext:run-program "/bin/sh" (list "-c" cmd)
                                   :output :stream :wait nil))
         (out  (sb-ext:process-output proc)))
    (loop for c = (read-char out nil nil)
          while c do (write-char c *standard-output*))
    (sb-ext:process-wait proc))
  nil)

(xdef pipe-from (cmd)
  (sb-ext:process-output
   (sb-ext:run-program "/bin/sh" (list "-c" cmd)
                       :output :stream :wait nil)))

;;;; ============================================================
;;;; Tables / hash tables
;;;; ============================================================

(xdef table (&rest args)
  (let ((h (make-hash-table :test #'equal)))
    (when args (ar-funcall1 (car args) h))
    h))

(xdef maptable (fn table)
  (maphash (lambda (k v) (ar-funcall2 fn k v)) table)
  table)

(xdef sref (obj val idx)
  (cond
    ((hash-table-p obj)
     (if (null val) (remhash idx obj) (setf (gethash idx obj) val)))
    ((stringp obj)  (setf (char obj idx) val))
    ((consp obj)    (setf (car (nthcdr idx obj)) val))
    (t (error "Can't sref ~S" obj)))
  val)

;;;; ============================================================
;;;; protect / error handling
;;;; ============================================================

(xdef protect (during after)
  (unwind-protect (ar-funcall0 during) (ar-funcall0 after)))

(xdef err #'error)

(xdef on-err (errfn f)
  (handler-case (ar-funcall0 f)
    (error (c) (ar-funcall1 errfn c))))

(xdef details (c) (format nil "~A" c))

;;;; ============================================================
;;;; Misc primitives
;;;; ============================================================

(xdef rand (&optional n)
  (if n (random n)
      (random 1.0d0)))

(let ((urandom-stream nil))
  (xdef randb ()
    (unless urandom-stream
      (setf urandom-stream
            (open "/dev/urandom"
                  :element-type '(unsigned-byte 8)
                  :direction :input)))
    (read-byte urandom-stream)))

(xdef dir (name)
  (let* ((base (if (or (zerop (length name))
                       (eql (char name (1- (length name))) #\/))
                   name
                   (concatenate 'string name "/")))
         (files (directory (concatenate 'string base "*.*")))
         (subdirs (directory (concatenate 'string base "*/"))))
    (append
     (loop for p in files
           for n = (file-namestring p)
           unless (or (null n) (string= n "")) collect n)
     (mapcar (lambda (p) (car (last (pathname-directory p))))
             subdirs))))

(xdef file-exists (name) (if (probe-file name) name nil))

(xdef dir-exists (name)
  (let ((p (probe-file name)))
    (if (and p (cl:pathname-name p) (string= (cl:pathname-name p) ""))
        nil
        (if (and p (null (pathname-name p))) name nil))))

(xdef rmfile (name) (delete-file name) nil)

(xdef mvfile (old new)
  ; CL rename-file merges new-name with old's truename, which can
  ; double directory components and inherit the old extension.
  ; Avoid both by making new-name absolute and setting type to
  ; :unspecific (explicitly no extension) when the caller provides none.
  (let* ((new-p    (pathname new))
         (new-typed (make-pathname :defaults new-p
                                   :type (or (pathname-type new-p) :unspecific)))
         (new-abs  (merge-pathnames new-typed *default-pathname-defaults*)))
    (rename-file old new-abs))
  nil)

(xdef bound (x) (tnil (arc-bound-p x)))

(xdef newstring #'make-string)

(xdef trunc (x) (truncate x))

(xdef exact (x) (tnil (and (integerp x) (= x (truncate x)))))

(defun arc-msec ()
  (floor (* 1000 (/ (get-internal-real-time)
                    internal-time-units-per-second))))
(xdef msec #'arc-msec)

(xdef current-process-milliseconds ()
  (floor (* 1000 (/ (get-internal-run-time)
                    internal-time-units-per-second))))

(xdef current-gc-milliseconds () 0)

;;; Unix time: CL universal time is from 1900; Unix from 1970
(defconstant +cl-to-unix+ 2208988800)

(xdef seconds () (- (get-universal-time) +cl-to-unix+))

(xdef timedate (&rest args)
  (let* ((unix (if args (car args) (- (get-universal-time) +cl-to-unix+)))
         (ut   (+ unix +cl-to-unix+))
         (d    (multiple-value-list (decode-universal-time ut 0))))
    ;; sec min hr day mon yr ...
    (list (first d) (second d) (third d) (fourth d) (fifth d) (sixth d))))

(xdef sin  #'sin)
(xdef cos  #'cos)
(xdef tan  #'tan)
(xdef asin #'asin)
(xdef acos #'acos)
(xdef atan #'atan)
(xdef log  #'log)

(xdef flushout () (force-output *standard-output*) t)

(xdef ssyntax  (x) (tnil (ssyntax-p x)))
(xdef ssexpand (x) (if (ssyntax-p x) (expand-ssyntax x) x))

(xdef quit () (sb-ext:exit))

(xdef memory () (sb-kernel:dynamic-usage))

;;;; ---- close / force-close ----

(xdef close (&rest args)
  (dolist (p args)
    (ignore-errors
      (cond ((typep p 'arc-server-socket) (sb-bsd-sockets:socket-close (ass-sock p)))
            ((streamp p) (cl:close p))
            (t nil))))
  nil)

(xdef force-close (&rest args)
  (dolist (p args)
    (ignore-errors
      (cond ((typep p 'arc-server-socket) (sb-bsd-sockets:socket-close (ass-sock p)))
            ((streamp p) (cl:close p :abort t))
            (t nil))))
  nil)

;;;; ---- apply / sig / declare / eval / macex ----

(xdef apply (fn &rest args)
  (ar-apply fn (ar-apply-args args)))

(xdef sig *arc-fn-signatures*)

(xdef declare (key val)
  (let ((flag (not (null val)))
        (k (string-downcase (symbol-name key))))
    (cond ((string= k "atstrings")      (setf *arc-atstrings*      flag))
          ((string= k "direct-calls")   (setf *arc-direct-calls*   flag))
          ((string= k "explicit-flush") (setf *arc-explicit-flush* flag)))
    val))

(xdef eval   (e) (arc-eval e))
(xdef macex  (e) (ac-macex e))
(xdef macex1 (e) (ac-macex e t))

;;;; ---- scar / scdr ----

(xdef scar (x val)
  (if (stringp x) (setf (char x 0) val) (setf (car x) val))
  val)

(xdef scdr (x val)
  (if (stringp x) (error "Can't set cdr of string")
      (setf (cdr x) val))
  val)

;;;; ---- nil / t (bound in globals for completeness) ----

(xdef nil nil)
(xdef t   t)

;;;; ============================================================
;;;; Atstring helpers
;;;; ============================================================

(defun atpos (s i)
  (cond ((>= i (length s)) nil)
        ((char= (char s i) #\@)
         (if (and (< (1+ i) (length s))
                  (char/= (char s (1+ i)) #\@))
             i
             (atpos s (+ i 2))))
        (t (atpos s (1+ i)))))

(defun unescape-ats (s)
  (with-output-to-string (out)
    (loop with i = 0 and len = (length s)
          while (< i len)
          do (let ((c (char s i)))
               (if (and (char= c #\@)
                        (< (1+ i) len)
                        (char= (char s (1+ i)) #\@))
                   (progn (write-char #\@ out) (incf i 2))
                   (progn (write-char c out)   (incf i)))))))

(defun codestring (s)
  (let ((i (atpos s 0)))
    (if i
        (cons (subseq s 0 i)
              (let* ((rest (subseq s (1+ i)))
                     (in   (make-string-input-stream rest))
                     (expr (arc-read in nil :eof))
                     (pos  (file-position in)))
                (cons expr (codestring (subseq rest pos)))))
        (list s))))

;;;; ============================================================
;;;; REPL
;;;; ============================================================

(defvar *arc-last-err* nil)

(defun arc-report-error (c &optional (stream *standard-output*))
  (setf *arc-last-err* c)
  (let ((frames '())
        (i 0)
        (count 30)
        (stop nil))
    (sb-debug:map-backtrace
     (lambda (frame)
       (when (and (not stop) (< i count))
         ;; Print frames under :invert readtable case so mixed-case
         ;; symbol names (like arc--CAR) come out without |...| escapes.
         ;; All-lowercase and all-uppercase names still print in their
         ;; canonical form; only mixed-case ones change.
         (let ((text (with-output-to-string (s)
                       (let ((*print-pretty* nil)
                             (*readtable* (copy-readtable *readtable*)))
                         (setf (readtable-case *readtable*) :invert)
                         (sb-debug::print-frame-call frame s :number nil)))))
           (push (cons i text) frames)
           (incf i)
           (let ((name (sb-di:debug-fun-name (sb-di:frame-debug-fun frame))))
             (when (and (symbolp name)
                        (string= (symbol-name name) "ARC-BOOT"))
               (setf stop t)))))))
    (dolist (entry frames)
      (format stream "~D: ~A~%" (car entry) (cdr entry)))
    (format stream "Backtrace for: ~A~%" sb-thread:*current-thread*))
  (format stream "Error: ~A~%~%" c)
  (force-output stream))

(defun arc-tl ()
  (format t "Use (quit) to quit, (arc:arc-tl) to return here after an interrupt.~%")
  (arc-tl2))

(defun arc-tl2 ()
  (format t "arc> ")
  (force-output *standard-output*)
  (block iter
    (handler-bind ((sb-sys:interactive-interrupt
                    (lambda (c)
                      (declare (ignore c))
                      (clear-input *standard-input*)
                      (terpri)
                      (return-from iter)))
                   (error (lambda (c)
                            (arc-report-error c)
                            (return-from iter))))
      (let ((expr (arc-read *standard-input* nil :eof)))
        (cond
          ((or (eq expr :eof) (equal expr :a)) (return-from arc-tl2 'done))
          (t
           (let ((val (arc-eval expr)))
             (arc-write-val val *standard-output*)
             (terpri)
             (setf (arc-global '|that|)     val)
             (setf (arc-global '|thatexpr|) expr)))))))
  (arc-tl2))

