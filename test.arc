#!./clarc

; adapted from test.l in https://github.com/sctb/lumen

(= true 't false nil)

(= tests* (table))

(mac test! (x msg)
  `(if (no ,x)
       (do (= failed* (+ failed* 1))
           (return ,msg))
     (++ passed*)))

(def writes (x)
  (tostring (write x)))

(def equal? (a b)
  (is (writes a) (writes b)))

(mac test? (a b)
  (w/uniq (x y)
    `(withs (,x ,a ,y ,b)
       (test! (equal? ,x ,y)
              (+ "failed: expected " (writes ,x) ", was " (writes ,y)
                 " for " (writes '(test? ,a ,b)))))))

(mac define-test (name . body)
  (let label (coerce (string "test-" name) 'sym)
    `(do (def ,label ()
           (point return ,@body))
         (= (tests* ',name) ,label))))

(def run-tests ()
  (= passed* 0 failed* 0)
  (each (name f) tests*
    (let result (f)
      (when (isa result 'string)
        (prn (+ " " name " " result)))))
  (prn (+ " " passed* " passed, " failed* " failed")))

(define-test no
  (test? true (no nil))
  ;(test? true (no unset))
  ;(test? true (no (void)))
  (test? false (no true))
  (test? true (no false))
  (test? false (no (obj)))
  (test? false (no 0)))

;(define-test yes
;  (test? false (yes nil))
;  (test? false (yes unset))
;  (test? false (yes (void)))
;  (test? true (yes true))
;  (test? false (yes false))
;  (test? true (yes (obj)))
;  (test? true (yes 0)))

(define-test boolean
  (test? true (or true false))
  (test? false (or false false))
  (test? true (or false false true))
  (test? true (no false))
  (test? true (no (and false true)))
  (test? false (no (or false true)))
  (test? true (and true true))
  (test? false (and true false))
  (test? false (and true true false)))

(define-test short
  (test? true (or true (err 'bad)))
  (test? false (and false (err 'bad)))
  (let a true
    (test? true (or true (do (= a false) false)))
    (test? true a)
    (test? false (and false (do (= a false) true)))
    (test? true a))
  (let b true
    (test? true (or (do (= b false) false) (do (= b true) b)))
    (test? true b)
    (test? true (or (do (= b true) b) (do (= b true) b)))
    (test? true b)
    (test? true (and (do (= b false) true) (do (= b true) b)))
    (test? true b)
    (test? false (and (do (= b false) b) (do (= b true) b)))
    (test? false b)))

(define-test numeric
  (test? 4 (+ 2 2))
  (test? 0 (apply * '(0 0)))
  (test? 4 (apply + '(2 2)))
  (test? 0 (apply + ()))
  (test? 4 (- 7 3))
  (test? 4 (apply - '(7 3)))
  ;(test? 0 (apply - ()))
  (test? 5 (/ 10 2))
  (test? 5 (apply / '(10 2)))
  ;(test? 1 (apply / ()))
  (test? 6.0 (* 2 3.00))
  (test? 6.0 (apply * '(2 3.00)))
  ;(test? 1 (apply * ()))
  (test? true (> 2.01 2))
  (test? true (>= 5.0 5.0))
  (test? true (> 2.1e3 2000))
  (test? true (< 2e-3 0.0021))
  (test? false (< 2 2))
  (test? true (<= 2 2))
  ;(test? true (is 2 2.0))
  (test? true (is -0.0 +0.0))
  (test? -7 (- 7)))

(define-test math
  (test? 3 (max 1 3))
  (test? 2 (min 2 7))
  (let n (rand)
    (test? true (and (> n 0) (< n 1))))
  (test? 4 (trunc 4.78)))

(define-test precedence
  (test? -3 (- (+ 1 2)))
  (test? 10 (- 12 (+ 1 1)))
  (test? 11 (- 12 (* 1 1)))
  (test? 10 (+ (/ 4 2) 8)))

(define-test infix
  (withs (l '(1 1 2 3)
          (a b c d) l)
    (test? true (apply <= l))
    (test? false (apply < l))
    (test? false (apply is l))
    (test? true ((do is) 1 a b))
    (test? false (apply > (rev l)))
    (test? true (apply >= (rev l)))
    (test? true (<= a b c d))
    (test? true (<= a b c d))
    (test? false (< a b c d))
    (test? false (is a b c d))
    (test? true (is 1 a b))
    (test? false (> d c b a))
    (test? true (>= d c b a))))

;(define-test standalone
;  (test? 10 (do (+ illegal) 10))
;  (let x nil
;    (test? 9 (do (list nothing fooey (= x 10)) 9))
;    (test? 10 x))
;  (test? 12 (do (get but zz) 12))
;  (let y nil
;    (let ignore (do (%literal y | = 10;|) 42)
;      (test? 10 y))))

(define-test string
  (test? 3 (len "foo"))
  (test? 3 (len "\"a\""))
  ;(test? 'a "a")
  (test? #\a ("bar" 1))
  ;(test? #\a (coerce "a" 'char))
  (test? '(#\a #\b #\c) (coerce "abc" 'cons))
  (let s "a
b"
    (test? 3 (len s)))
  (let s "a
b
c"
    (test? 5 (len s)))
  (test? 3 (len "a\nb"))
  (test? 3 (len "a\\b"))
  ;(test? "x3" (cat "x" (+ 1 2)))
  )

(define-test atstrings
  (let a 'foo
    (test? "barfoo" "bar@a")
    (test? "foobar" "@{a}bar")
    ;(test? "" "@unset")
    (test? "" "@nil")
    (test? "" "@(list)")
    (test? "T" "@t")
    ;(test? "false" "@false")
    ))

(define-test quote
  (test? 7 (quote 7))
  (test? t (quote t))
  (test? nil (quote nil))
  ;(test? true (quote true))
  ;(test? false (quote false))
  (test? (quote a) 'a)
  (test? (quote (quote a)) ''a)
  (test? "a" '"a")
  (test? "\n" (quote "\n"))
  (test? "\r\n" (quote "\r\n"))
  (test? "\\" (quote "\\"))
  (test? '(quote "a") ''"a")
  (test? t (isnt '|(| '|)|))
  (test? (quote unquote) 'unquote)
  (test? (quote (unquote)) '(unquote))
  (test? (quote (unquote a)) '(unquote a))
  ;(let x '(10 20 a: 33 1a: 44)
  ;  (test? 20 (at x 1))
  ;  (test? 33 (get x 'a))
  ;  (test? 44 (get x '1a)))
  )

(define-test list
  (test? '() (list))
  (test? () (list))
  (test? '(a) (list 'a))
  ;(test? '(false) (list false)) ; todo
  (test? '(a) (quote (a)))
  (test? '(()) (list (list)))
  (test? 0 (len (list)))
  (test? 2 (len (list 1 2)))
  (test? '(1 2 3) (list 1 2 3))
  ;(test? 17 (get (list foo: 17) 'foo))
  ;(test? 17 (get (list 1 foo: 17) 'foo))
  ;(test? true (get (list :foo) 'foo))
  ;(test? true (get '(:foo) 'foo))
  ;(test? true (get (hd '((:foo))) 'foo))
  ;(test? '(:a) (list :a))
  ;(test? '(b: false) (list b: false))
  ;(test? '(c: 0) (list c: 0))
  ;(let d 42
  ;  (test? `(d: ,d) (list :d)))
  )

(define-test quasiquote
  (test? (quote a) (quasiquote a))
  (test? 'a `a)
  (test? () `())
  (test? 2 `,2)
  (test? nil `(,@nil))
  (let a 42
    (test? 42 `,a)
    (test? 42 (quasiquote (unquote a)))
    (test? '(quasiquote (unquote a)) ``,a)
    (test? '(quasiquote (unquote 42)) ``,,a)
    (test? '(quasiquote (quasiquote (unquote (unquote a)))) ```,,a)
    (test? '(quasiquote (quasiquote (unquote (unquote 42)))) ```,,,a)
    (test? '(a (quasiquote (b (unquote c)))) `(a `(b ,c)))
    (test? '(a (quasiquote (b (unquote 42)))) `(a `(b ,,a)))
    (let b 'c
      (test? '(quote c) `',b)
      (test? '(42) `(,a))
      (test? '((42)) `((,a)))
      (test? '(41 (42)) `(41 (,a)))))
  (let c '(1 2 3)
    (test? '((1 2 3)) `(,c))
    (test? '(1 2 3) `(,@c))
    (test? '(0 1 2 3) `(0 ,@c))
    (test? '(0 1 2 3 4) `(0 ,@c 4))
    (test? '(0 (1 2 3) 4) `(0 (,@c) 4))
    (test? '(1 2 3 1 2 3) `(,@c ,@c))
    (test? '((1 2 3) 1 2 3) `((,@c) ,@c)))
  (let a 42
    (test? '(quasiquote ((unquote-splicing (list a)))) ``(,@(list a)))
    (test? '(quasiquote ((unquote-splicing (list 42)))) ``(,@(list ,a))))
  ;(test? true (get `(:foo) 'foo))
  ;(let (a 17
  ;      b '(1 2)
  ;      c (obj a: 10)
  ;      d (list a: 10))
  ;  (test? 17 (get `(foo: ,a) 'foo))
  ;  (test? 2 (# `(foo: ,a ,@b)))
  ;  (test? 17 (get `(foo: ,@a) 'foo))
  ;  (test? '(1 a: 10) `(1 ,@c))
  ;  (test? '(1 a: 10) `(1 ,@d))
  ;  (test? true (get (hd `((:foo))) 'foo))
  ;  (test? true (get (hd `(,(list :foo))) 'foo))
  ;  (test? true (get `(,@(list :foo)) 'foo))
  ;  (test? true (get `(1 2 3 ,@'(:foo)) 'foo)))
  ;(let-macro ((a keys `(obj ,@keys)))
  ;  (test? true (get (a :foo) 'foo))
  ;  (test? 17 (get (a bar: 17) 'bar)))
  ;(let-macro ((a () `(obj baz: (fn () 17))))
  ;  (test? 17 ((get (a) 'baz))))
  )

(define-test quasiexpand
  (withs (x 'x z 'z)
    (test? 'a (macex 'a))
    (test? '(17) (macex '(17)))
    (test? '(1 z) (macex '(1 z)))
    (test? '(quasiquote (1 z)) (macex '`(1 z)))
    (test? '(quasiquote ((unquote 1) (unquote z))) (macex '`(,1 ,z)))
    (test? '(1 z) `(1 z))
    (test? '(1 z) `(,1 ,z))
    (let z '(z)
      (test? '(z) `(,@z)))
    ;(test? '(join (%array 1) z) (macex '`(,1 ,@z)))
    ;(test? '(join (%array 1) x y) (macex '`(,1 ,@x ,@y)))
    ;(test? '(join (%array 1) z (%array 2)) (macex '`(,1 ,@z ,2)))
    ;(test? '(join (%array 1) z (%array "a")) (macex '`(,1 ,@z a)))
    ;(test? '"x" (macex '`x))
    ;(test? '(%array "quasiquote" "x") (macex '``x))
    ;(test? '(%array "quasiquote" (%array "quasiquote" "x")) (macex '```x))
    ;(test? 'x (macex '`,x))
    ;(test? '(%array "quote" x) (macex '`',x))
    ;(test? '(%array "quasiquote" (%array "x")) (macex '``(x)))
    ;(test? '(%array "quasiquote" (%array "unquote" "a")) (macex '``,a))
    ;(test? '(%array "quasiquote" (%array (%array "unquote" "x")))
    ;       (macex '``(,x)))))
    ))

(define-test calls
  (withs (f (fn () 42)
          l (list f)
          ;t (obj f f) ; todo
          )
    (f)
    ((fn ()
      (test? 42 (f))))
    (test? 42 ((l 0)))
    ;(test? 42 ((t 'f)))
    ;(test? 42 (t!f))
    (test? nil ((fn ())))
    (test? 10 ((fn (x) (- x 2)) 12))
    ;(= plus '+)
    ;(test? 3 (plus 1 2))
    ;(test? 3 ('plus 1 2))
    ;(= p 'pr)
    ;(test? "1,2,3" (tostring:p 1 2 3 sep: ","))
    ))

;(define-test identifier
;  (let (a 10
;        b (obj x: 20)
;        f (fn () 30))
;    (test? 10 a)
;    (test? 10 (%literal a))
;    (test? 20 (%literal b |.x|))
;    (test? 30 (%literal f |()|))))

(define-test names
  (withs (a! 0
          b? 1
          -% 2
          ** 3
          break 4)
    (test? 0 a!)
    (test? 1 b?)
    (test? 2 -%)
    (test? 3 **)
    (test? 4 break)))

(define-test =
  (test? 1 (= xx 1))
  (test? 1 xx)
  (test? 2 (= yy 1 zz 2))
  (test? 1 yy)
  (test? 2 zz)
  (let a 42
    (= a 'bar)
    (test? 'bar a)
    (let x (= a 10)
      (test? 10 x)
      (test? 10 a))
    (= a false)
    (test? false a)
    (= a)
    (test? nil a)))

(define-test wipe
  (let x (obj a t b t c t)
    (wipe (x 'a))
    (test? nil (x 'a))
    (test? true (x 'b))
    (wipe (x 'c))
    (test? nil (x 'c))
    (test? true (x 'b))
    (wipe (x 'b))
    (test? nil (x 'b))
    ;(test? (obj) x) ; todo
    ))

(define-test do
  (let a 17
    (do (= a 10)
        (test? 10 a))
    (test? 10 (do a))
    (let b (do (= a 2) (+ a 5))
      (test? a 2)
      (test? b 7))
    (do (= a 10)
        (do (= a 20)
            (test? 20 a)))
    (test? 20 (do (= a 10)
                  (do (= a 20) a))))
  (test? '(%do) (macex '(do))))

(define-test if
  (test? '(if a) (macex '(if a)))
  (test? '(if a b) (macex '(if a b)))
  (test? '(if a b c) (macex '(if a b c)))
  (test? '(if a b c d) (macex '(if a b c d)))
  (test? '(if a b c d e) (macex '(if a b c d e)))
  (if true
      (test? true true)
    (test? true false))
  (if false (test? true false)
      false (test? false true)
    (test? true true))
  (if false (test? true false)
      false (test? false true)
      false (test? false true)
    (test? true true))
  (if false (test? true false)
      true (test? true true)
      false (test? false true)
    (test? true true))
  (test? false (if false true false))
  (test? 1 (if true 1 2))
  (test? 1 (if (let a 10 a) 1 2))
  (test? 1 (if true (do1 1) 2))
  (test? 1 (if false 2 (let a 1 a)))
  (test? 1 (if false 2 true (do1 1)))
  (test? 1 (if false 2 false 3 (let a 1 a)))
  (test? 0 (if false 1 0)))

(define-test case
  (let x 10
    (test? 2 (case x 9 9 10 2 4))
    (test? 2 (case x 9 9 (10) 2 4))
    (test? 2 (case x 9 9 (10 20) 2 4)))
  (let x 'z
    (test? 9 (case x z 9 10))
    (test? 7 (case x a 1 b 2 7))
    (test? 2 (case x a 1 (z) 2 7))
    (test? 2 (case x a 1 (b z) 2 7)))
  (withs (n 0 f (fn () (++ n))) ; no multiple eval
    (test? 'b (case (f) 0 'a 1 'b 'c)))
  (test? 'b ((fn () (case 2 0 (do) 1 'a 2 'b)))))

(run-tests)
