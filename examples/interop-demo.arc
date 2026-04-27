#!./sharc
; sharc <-> Common Lisp interop demos.
;
; Run with:  ./sharc examples/interop-demo.arc
;
; Two forms of interop:
;   (#'fn args...)   -- "Pattern A": call any CL function, macro, or
;                       special operator. ac detects macros / special
;                       operators and cl-quotes the args so binding
;                       forms survive intact; otherwise args are
;                       arc-evaluated.
;   #'(form ...)     -- "Pattern B": cl-quote a whole form and hand
;                       it to CL. Useful for one-shot CL blocks.

; ============================================================
; 1. Case-sensitive names survive the round-trip into CL
; ============================================================
; Pre-TKTK (under :upcase), MyHelper / myhelper / MYHELPER all
; collided. Now they're three distinct identifiers.

#'(defun MyHelper (x) (* x 10))
#'(defun myhelper (x) (* x 100))

(prn (#'MyHelper 3))      ; 30
(prn (#'myhelper 3))      ; 300  -- different function

; ============================================================
; 2. Symbols print without |...| escapes
; ============================================================
; (write 'car) used to print |car| because the symbol-name was
; lowercase and the printer was :upcase. Under :invert the
; round-trip is clean.

(prn (tostring (write 'car)))            ; car
(prn (tostring (write 'CamelCase)))      ; CamelCase
(prn (tostring (write 'arc--internal)))  ; arc--internal

; ============================================================
; 3. Calling CL functions on arc-computed data
; ============================================================
; Pattern A: args are arc-evaluated, so arc lists / numbers /
; strings flow into CL functions naturally. #'#'fn passes a
; CL function as a value.

(prn (#'reduce #'#'+ '(1 2 3 4 5)))           ; 15
(prn (#'sort '(3 1 4 1 5 9 2 6) #'#'<))       ; (1 1 2 3 4 5 6 9)

; ============================================================
; 4. CL keyword arguments (leading-colon -> :keyword)
; ============================================================
; Arc reader interns leading-colon tokens in the :keyword
; package, so :direction / :if-exists / :input flow through
; unchanged.

(let p (#'open "/tmp/sharc-interop.txt"
               :direction :output
               :if-exists :supersede)
  (#'format p "hello from sharc~%")
  (#'close p))

; ============================================================
; 5. CL macros / special operators via Pattern A
; ============================================================
; ac detects (macro-function) / (special-operator-p) on the head
; and cl-quotes the args, so binding forms like (s path) in
; with-open-file or ((a 10)(b 20)) in let are preserved.

(prn (#'with-open-file (s "/tmp/sharc-interop.txt")
       (#'read-line s)))                              ; "hello from sharc"
(prn (#'let ((a 10) (b 20)) (+ a b)))                 ; 30
(prn (#'multiple-value-list (#'truncate 17 5)))       ; (3 2)
(prn (#'loop for i below 10 collect (* i i)))         ; (0 1 4 9 16 ...)
(prn (#'loop for i below 10 collect (do (* i i))))     ; expand arc's DO macro
(prn (#'loop for i below 10 collect (* (do1 i 42) i))) ; expand arc's DO1 macro
(prn (#'loop for i below 10 collect (cl::expt i i)))         ; (0 1 4 9 16 ...)

; ============================================================
; 6. CL condition handling
; ============================================================

(prn (#'handler-case (/ 1 0)
       (division-by-zero (c)
         (declare (ignore c))
         'caught)))                                   ; caught

; ============================================================
; 7. CLOS with case-preserved class and slot names
; ============================================================
; defclass / defmethod / make-instance / accessors all work
; via Pattern A. Use #''Name to hand the class name as a
; CL-side literal symbol (so it matches what defclass
; registered).

#'(defclass Point ()
    ((x :initarg :x :accessor point-x)
     (y :initarg :y :accessor point-y)))

#'(defmethod distance ((a Point) (b Point))
    (sqrt (+ (expt (- (point-x a) (point-x b)) 2)
             (expt (- (point-y a) (point-y b)) 2))))

(let a (#'make-instance #''Point :x 0 :y 0)
  (let b (#'make-instance #''Point :x 3 :y 4)
    (prn (#'distance a b))))                          ; 5.0

; ============================================================
; 8. Bridging arc data into a CL macro body
; ============================================================
; Macro args in Pattern A are cl-quoted, so arc variables
; don't bridge in directly. To pass arc data to a CL macro,
; wrap the macro in a CL function:

#'(defun read-first-line (path)
    (with-open-file (s path)
      (read-line s)))

(let path "/tmp/sharc-interop.txt"
  (prn (#'read-first-line path)))                     ; "hello from sharc"

; ============================================================
; 9. Defining arc names that shadow CL exports
; ============================================================
; Arc-typed symbols live in :arc-user, which doesn't :use
; :common-lisp -- so redefining `some`, `complement`, etc.
; no longer hits a package-locked error.

(def some (x) (list 'arcified x))
(prn (some 42))                                       ; (arcified 42)
