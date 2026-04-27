#!./sharc

; A celeste-style coroutine scheduler.
;
; Each game object runs on its own SBCL thread. (yield self) parks the
; thread on a semaphore; the scheduler ticks one actor at a time by
; signalling its resume-semaphore and then waiting on its parked-
; semaphore until the actor either yields again or its body returns.
;
; This means an actor body can be written as straight-line code with
; ordinary (while ...) loops --- the same shape as Celeste's
; IEnumerator DummyWalkToExact:
;
;   while (!player.Dead
;          && player.X != x
;          && !player.CollideCheck<Solid>(...)
;          && (!cancelOnFall || player.OnGround()))
;   { ... yield return null; }
;
; Run with:  ./examples/coroutines.arc
; Or load:   (load "examples/coroutines.arc") (demo)


; ---- semaphore helpers ----------------------------------------------
;
(def sem      ()  (sb-thread::make-semaphore))
(def sem-wait (s) (sb-thread::wait-on-semaphore s) nil)
(def sem-post (s) (sb-thread::signal-semaphore s) nil)

; ---- coroutine primitive --------------------------------------------

; An actor is a table with at least: name, x, dead, done, resume, parked.
; The body-fn is called once with the actor; when it returns, the
; coroutine is done.

(def make-coro (name body-fn)
  (let a (obj name   name
              x      0
              dead   nil
              done   nil
              resume (sem)
              parked (sem))
    (= a!thread
       (thread
         (sem-wait a!resume)         ; wait for the first tick
         (after (body-fn a)
           (= a!done t)
           (prn "  " a!name " done")
           (sem-post a!parked))))    ; final hand-back to scheduler
    a))

(def delay (self n) ; pause for n ticks
  (prn "  " self!name ": sleeping till tick " (+ (tick) n))
  (repeat n (yield self))
  (prn "  " self!name ": waking up"))

(def yield (self (o ticks))
  (sem-post self!parked)                 ; "I've parked"
  (if ticks (delay self ticks))
  (sem-wait self!resume))                ; wait for next tick

(def step-coro (a)
  (unless a!done
    (sem-post a!resume)
    (sem-wait a!parked)))

(def kill-coro (a)
  (unless a!done
    (= a!done t)
    (errsafe:kill-thread a!thread)))


; ---- world / scheduler ----------------------------------------------

(def make-world ()
  (obj actors nil  solids nil  ground-max 20  tick 0))

(def actors () world*!actors)
(def tick () world*!tick)

(def spawn (name body-fn)
  (let a (make-coro name body-fn)
    (push a world*!actors)
    a))

(def collide (x)
  (some [is _ x] world*!solids))

(def on-ground (x)
  (and (>= x 0) (<= x world*!ground-max)))

(def tick-world ()
  (++ world*!tick)
  (prn "-- tick " (tick) " --")
  (each a (actors)
    (step-coro a)))

(def run-world (n)
  (repeat n
    (sleep 1/2)
    (tick-world))
  (each a (actors)
    (kill-coro a)))


; ---- a celeste-style routine ----------------------------------------

(def walk-to-exact (self target (o cancel-on-fall t))
  (prn "  " self!name ": walking " self!x " -> " target)
  (while (and (no self!dead)
              (isnt self!x target)
              (no (collide (+ self!x (if (< self!x target) 1 -1))))
              (or (no cancel-on-fall) (on-ground self!x)))
    (++ self!x (if (< self!x target) 1 -1))
    (prn "    " self!name " at x=" self!x)
    (yield self))
  (prn "  " self!name ": stopped at x=" self!x))


; ---- demo -----------------------------------------------------------

(def demo ()
  (= world* (make-world)
     world*!solids '(8))
  (spawn 'madeline
    (fn (self)
      (= self!x 0)
      (walk-to-exact self 5)             ; reaches 5 cleanly
      (yield self 4)                     ; wait 4 ticks
      (walk-to-exact self 12)))          ; blocked by wall at 8
  (spawn 'badeline
    (fn (self)
      (= self!x 22)                      ; starts off the platform
      (walk-to-exact self 16)))          ; cancels: not on-ground
  (spawn 'theo
    (fn (self)
      (= self!x 18)
      (walk-to-exact self 14)
      (yield self 3)
      (walk-to-exact self 19)))
  (spawn 'neo
    (fn (self)
      (= self!x 3)
      (walk-to-exact self 5)
      (car 42) ; errors without interrupting other actors
      (walk-to-exact self 10)))
  (run-world 20)
  (prn)
  (each a (actors)
    (prn a!name " final: x=" a!x " done=" a!done)))

(when (main)
  (demo))
