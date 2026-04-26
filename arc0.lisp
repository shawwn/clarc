;;; arc0.lisp -- Arc runtime for Common Lisp (SBCL)

#+sbcl
(declaim (sb-ext:muffle-conditions cl:style-warning))

(defpackage :arc
  (:use :common-lisp))

(in-package :arc)

;;;; ============================================================
;;;; Funcall helpers
;;;; ============================================================

(defun ar-apply-args (args)
  (cond
    ((null args) nil)
    ((null (cdr args)) (car args))
    (t (cons (car args) (ar-apply-args (cdr args))))))

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

(defun arc-apply (fn &rest args)
  (ar-apply fn (ar-apply-args args)))

(defun arc-call0 (fn)
  (if (functionp fn) (funcall fn) (ar-apply fn nil)))

(defun arc-call1 (fn a)
  (if (functionp fn) (funcall fn a) (ar-apply fn (list a))))

(defun arc-call2 (fn a b)
  (if (functionp fn) (funcall fn a b) (ar-apply fn (list a b))))

(defun arc-call3 (fn a b c)
  (if (functionp fn) (funcall fn a b c) (ar-apply fn (list a b c))))

;;;; ============================================================
;;;; Core primitives
;;;; ============================================================

(defun arc-join (&optional (a nil) (b nil))
  (cons a b))

(defun arc-car (x)
  (cond ((consp x) (car x))
        ((null x)  nil)
        (t (error "Can't take car of ~S" x))))

(defun arc-cdr (x)
  (cond ((consp x) (cdr x))
        ((null x)  nil)
        (t (error "Can't take cdr of ~S" x))))

(defun arc-xcar (x) (if (null x) nil (car x)))
(defun arc-xcdr (x) (if (null x) nil (cdr x)))

(defun pairwise (pred lst)
  (cond ((null lst)       t)
        ((null (cdr lst)) t)
        ((null (funcall pred (car lst) (cadr lst))) nil)
        (t (pairwise pred (cdr lst)))))

;; Returns true iff a and b are identical. 
(defun arc-id (a b)
  (or (eql a b)
      (and (numberp a) (numberp b) (= a b))
      (and (stringp a) (stringp b) (string= a b))
      (and (null a) (null b))))

(defun arc-is2 (a b)
   (or (arc-id a b)
       (cond
         ;; lists
         ((and (consp a) (consp b))
          (and (arc-is2 (car a) (car b))
               (arc-is2 (cdr a) (cdr b))))
         ;; vectors (skip strings — arc-id already handled them)
         ((and (vectorp a) (vectorp b)
               (not (stringp a)) (not (stringp b)))
          (and (= (length a) (length b))
               (loop for i below (length a)
                     always (arc-is2 (aref a i) (aref b i)))))
         ;; tables
         ((and (hash-table-p a) (hash-table-p b))
          (and (eq (hash-table-test a) (hash-table-test b))
               (= (hash-table-count a) (hash-table-count b))
               (loop for k being the hash-keys of a using (hash-value va)
                     always (multiple-value-bind (vb present) (gethash k b)
                              (and present (arc-is2 va vb)))))))))

(defun arc-is (a b &rest args)
  (and (arc-is2 a b)
       (or (null args)
           (apply #'arc-is b args))))

(defun arc->2 (x y)
  (tnil (cond ((and (numberp x) (numberp y)) (> x y))
              ((and (stringp x) (stringp y)) (string> x y))
              ((and (symbolp x) (symbolp y))
               (string> (symbol-name x) (symbol-name y)))
              ((and (characterp x) (characterp y)) (char> x y))
              (t (> x y)))))

(defun arc-<2 (x y)
  (tnil (cond ((and (numberp x) (numberp y)) (< x y))
              ((and (stringp x) (stringp y)) (string< x y))
              ((and (symbolp x) (symbolp y))
               (string< (symbol-name x) (symbol-name y)))
              ((and (characterp x) (characterp y)) (char< x y))
              (t (< x y)))))

(defun char-or-str-p (x) (or (stringp x) (characterp x)))

(defun arc-+2 (x y)
  (cond ((and (numberp x) (numberp y)) (+ x y))
        ((char-or-str-p x)
         (concatenate 'string
                      (if (characterp x) (string x) x)
                      (if (characterp y) (string y) y)))
        ((and (arc-list-p x) (arc-list-p y)) (append x y))
        (t (+ x y))))

(defun arc-+ (&rest args)
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

(defun arc-len (x)
  (cond ((stringp x)    (length x))
        ((hash-table-p x) (hash-table-count x))
        (t (length x))))

;;;; ---- Continuations (escape-only) ----

(defun arc-ccc (f)
  (let ((tag (gensym "K")))
    (catch tag
      (arc-call1 f (lambda (x) (throw tag x))))))

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

;;;; ============================================================
;;;; Tagged types
;;;; ============================================================

(defstruct (arc-tagged (:constructor %arc-tag (type rep)))
  type rep)

;;;; ---- Type system ----

(defun arc-type (x)
  (cond
    ((arc-tagged-p x)                  (arc-tagged-type x))
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

(defun arc-tag (type rep)
  (if (and (arc-tagged-p rep)
           (arc-sym= (arc-tagged-type rep) (symbol-name type)))
      rep
      (%arc-tag type rep)))

(defun arc-rep (x)
  (if (arc-tagged-p x) (arc-tagged-rep x) x))

