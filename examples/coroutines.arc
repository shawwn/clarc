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

(= tickrate*    1/2 ; half a second between each tick = 2 FPS
   numticks*    20  ; how long it runs: 20 ticks * 1/2 = 10s
   ground*      20) ; anyone outside x=[0..20] is falling

(def report (me . msg)
  (atomic ; ensure the prn doesn't get split up between threads
    (apply prn "  " me!name " " msg)))

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
           (report a "done")
           (sem-post a!parked))))    ; hand back scheduler
    a))

(def kill-coro (a)
  (unless a!done
    (= a!done t)
    (errsafe:kill-thread a!thread)))

(def step-coro (a)
  (unless a!done
    (sem-post a!resume)
    (sem-wait a!parked)))

(def yield (a (o ticks))
  ;; "I've parked"
  (sem-post a!parked)
  (if ticks (delay a ticks))
  ;; wait for next tick
  (sem-wait a!resume))

(def delay (a n) ; pause for n ticks
  (repeat n
    (report a "sleeping at x=" a!x)
    (yield a)))

; ---- world / scheduler ----------------------------------------------

(def make-world ()
  (obj actors nil  walls nil  tick 0))

(def actors () world*!actors)
(def tick () world*!tick)

(def spawn (name body-fn)
  (let a (make-coro name body-fn)
    (push a world*!actors)
    a))

(def collides (x)
  (some x world*!walls))

(def on-ground (x)
  (<= 0 x ground*))

(def tick-world ()
  (++ world*!tick)
  (prn "-- tick " (tick) " --")
  (each a (actors)
    (step-coro a)))

(def run-world (n)
  (repeat n
    (sleep tickrate*)
    (tick-world))
  (each a (actors)
    (kill-coro a)))

; ---- a celeste-style coroutine ----------------------------------------

(def reached (me target)
  (is me!x target))

(def behind (me target)
  (< me!x target))

(def toward (me target)
  (if (behind me target) 1 -1))

(def falling (me)
  (~on-ground me!x))

(def wait (me ticks)
  (report me "sleeping till tick " (+ (tick) ticks))
  (delay me ticks)
  (report me "waking up at x=" me!x))

(def finished (me reason)
  (= me!reason reason)
  (report me "finished at x=" me!x " (" reason ")"))

(def walk-to (me target (o cancel-on-fall t))
  (report me "walking from x=" me!x " to x=" target)
  (point stop
    (while t
      ; let other actors run
      (yield me)
      (withs (facing (toward me target)
              next-pos (+ me!x facing))
        ; stop if we're dead
        (when me!dead
          (finished me 'dead)
          (stop))
        ; stop if we've reached our target
        (when (reached me target)
          (finished me 'reached)
          (stop))
        ; stop if we've hit a wall
        (when (collides next-pos)
          (finished me 'collision)
          (stop))
        ; stop if we're falling
        (when (and cancel-on-fall (falling me))
          (finished me 'falling)
          (stop))
        ; advance towards target
        (++ me!x facing)
        ; report our new position
        (report me "moved to x=" me!x)))))

; ---- demo -----------------------------------------------------------

(def demo ()
  (= world* (make-world)
     world*!walls '(8))
  (spawn 'madeline
    (fn (me)
      (= me!x 0)
      (walk-to me 5)    ; reaches 5 cleanly
      (wait me 4)       ; wait 4 ticks
      (walk-to me 12))) ; blocked by wall at 8
  (spawn 'badeline
    (fn (me)
      (= me!x 22)       ; starts off the platform
      (walk-to me 16))) ; cancels: falling
  (spawn 'theo
    (fn (me)
      (= me!x 18)
      (walk-to me 14)
      (wait me 3)
      (walk-to me 19)))
  (spawn 'granny
    (fn (me)
      (= me!x 3)
      (wait me 16)
      ;; errors won't interrupt other actors
      (car 42)
      (walk-to me 10))) ; never runs
  (run-world numticks*)
  (prn)
  (each a (actors)
    (report a "final: x=" a!x " " a!reason)))

(when (main)
  (demo))
