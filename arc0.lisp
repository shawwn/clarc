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

