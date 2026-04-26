;;; arc0.lisp -- Arc runtime for Common Lisp (SBCL)

#+sbcl
(declaim (sb-ext:muffle-conditions cl:style-warning))

(defpackage :arc
  (:use :common-lisp))

(in-package :arc)

;;;; ============================================================
;;;; Arc primitives
;;;; ============================================================

(defun arc-car (x)
  (cond ((consp x) (car x))
        ((null x)  nil)
        (t (error "Can't take car of ~S" x))))

(defun arc-cdr (x)
  (cond ((consp x) (cdr x))
        ((null x)  nil)
        (t (error "Can't take cdr of ~S" x))))


;;;; ============================================================
;;;; Comparison
;;;; ============================================================

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

