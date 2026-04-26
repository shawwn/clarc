;;; arc0.lisp -- Arc runtime for Common Lisp (SBCL)

#+sbcl
(declaim (sb-ext:muffle-conditions cl:style-warning))

(defpackage :arc
  (:use :common-lisp))

(in-package :arc)

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

