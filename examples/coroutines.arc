#!./sharc

; A celeste-style coroutine scheduler.
;
; An actor (~ Celeste Entity) owns a list of coroutines (~ Celeste
; Coroutine Components). Each coroutine runs on its own SBCL thread
; with its own pair of semaphores. (yield) parks the caller's thread;
; the scheduler ticks each coroutine of each actor once per tick by
; signalling the coro's resume-semaphore and then waiting on its
; parked-semaphore until it yields again or returns.
;
; Multiple coroutines on a single actor advance in parallel within a
; tick (in add-order), exactly like ComponentList.Update iterating
; over Coroutine components. A coroutine can spawn more coroutines on
; the same actor (or on a new one) just by calling add-coro / spawn.
;
; This means a coroutine body can be written as straight-line code
; with ordinary (while ...) loops --- the same shape as Celeste's
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
;
; Contract for coroutine bodies (cooperative scheduling has no
; preemption, so violating any of these stalls or corrupts the
; whole world):
;
;   - Don't yield while holding atomic or any user-level mutex.
;     The lock stays held across the park; the next coro that
;     tries to take it blocks its OS thread and never posts
;     parked, deadlocking the scheduler.
;
;   - Don't run unbounded synchronous work without yielding.
;     A body that loops without yield (or makes a long blocking
;     call) starves every other coroutine on every other actor.
;
;   - Don't terminate-thread a running coroutine. terminate-thread
;     is async and forced --- it skips the (after ...) cleanup
;     and can interrupt mid-write to shared state. Use a
;     cooperative cancel flag instead: (= c!cancel t) and have
;     the body check it at each yield. (kill-coro is fine at
;     world shutdown when nothing is awake.)
;
;   - step-coro is scheduler-only. Calling it from a coro body
;     unparks a second coroutine while the caller is still
;     running, breaking the "only one coro awake at a time"
;     invariant that everything else relies on.

(= tickrate*    1/2 ; half a second between each tick = 2 FPS
   numticks*    20  ; how long it runs: 20 ticks * 1/2 = 10s
   ground*      20) ; anyone outside x=[0..20] is falling

(def report (me . msg)
  (atomic ; ensure the prn doesn't get split up between threads
    (apply prn "  " me!name " " msg)))

; ---- semaphore helpers ----------------------------------------------

(def sem      ()  (sb-thread::make-semaphore))
(def sem-wait (s) (sb-thread::wait-on-semaphore s) nil)
(def sem-post (s) (sb-thread::signal-semaphore s) nil)

; ---- coroutine primitive --------------------------------------------

; An actor is the Celeste-style Entity: it holds shared state (name,
; position, dead-flag) and a list of coroutines that read/mutate it.
(deftem actor
  name  nil
  x     0
  dead  nil
  coros nil)

; A coro is one independent thread of control attached to an actor.
; The two semaphores belong to the coroutine, NOT the actor --- with
; multiple coros per actor, sharing one pair would wake the wrong one.
(deftem coro
  actor  nil
  thread nil
  done   nil
  resume (sem)
  parked (sem))

; Map current-thread -> its coro so (yield) can find its own semaphores
; without the body having to thread the coro through every call.
(= coros* (table))

(def my-coro () (coros* (current-thread)))

(def add-coro (a body-fn)
  (let c (inst 'coro 'actor a)
    (= c!thread
       (thread
         (= (coros* (current-thread)) c)
         (sem-wait c!resume)             ; wait for the first tick
         (after (body-fn a)
           (= c!done t)
           (pull c a!coros)
           (wipe (coros* (current-thread)))
           (sem-post c!parked))))        ; hand back scheduler
    (push c a!coros)
    c))

(def step-coro (c)
  (unless c!done
    (sem-post c!resume)
    (sem-wait c!parked)))

(def kill-coro (c)
  (unless c!done
    (= c!done t)
    (wipe (coros* c!thread))
    (errsafe:kill-thread c!thread)))

(def kill-coros (a)
  (whilet c (pop a!coros)
    (kill-coro c)))

; called from within a coro body to give up the rest of this tick
; (and optionally skip the next n-1 ticks too).  (yield) waits 1 tick,
; (yield 3) waits 3 ticks --- matches Celeste's "yield return 3.0f".
(def yield ((o ticks 1))
  (let c (or (my-coro) (err "yield called outside a coroutine"))
    (repeat ticks
      (sem-post c!parked)
      (sem-wait c!resume))))

; like yield, but reports each sleeping tick (so the demo output shows
; the actor explicitly waiting instead of going silent)
(def delay (n)
  (aand (my-coro) it!actor
    (repeat n
      (report it "sleeping at x=" it!x)
      (yield))))

; ---- world / scheduler ----------------------------------------------

(deftem world
  actors nil
  walls  nil
  tick   0)

(def actors () world*!actors)
(def tick () world*!tick)

(def spawn (a body-fn)
  (add-coro a body-fn)
  (push a world*!actors)
  a)

(def collides (x)
  (some x world*!walls))

(def on-ground (x)
  (<= 0 x ground*))

(def tick-world ()
  (++ world*!tick)
  (prn "-- tick " (tick) " --")
  (each a (actors)
    ; copy the list -- a coro can mutate a!coros by finishing
    (each c (copy a!coros)
      (step-coro c))))

(def run-world (n)
  (repeat n
    (sleep tickrate*)
    (tick-world))
  (each a (actors)
    (kill-coros a)))

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
  (delay ticks)
  (report me "waking up at x=" me!x))

(def finished (me reason)
  (= me!reason reason)
  (report me "finished at x=" me!x " (" reason ")"))

(def walk-to (me target (o cancel-on-fall t))
  (report me "walking from x=" me!x " to x=" target)
  (point stop
    (while t
      ; let other actors run
      (yield)
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
  (= world* (inst 'world 'walls '(8)))
  (spawn (inst 'actor 'name 'madeline 'x 0)
    (fn (me)
      ; spawn a sibling coroutine on the same actor that ticks
      ; alongside the main body --- like Celeste's per-image
      ; wobbleRoutines on AngryOshiro.
      (add-coro me
        (fn (me)
          (while (no me!reason)
            (report me "(shadow watching x=" me!x ")")
            (yield 2))))
      (walk-to me 5)    ; reaches 5 cleanly
      (wait me 4)       ; wait 4 ticks
      (walk-to me 12))) ; blocked by wall at 8
  (spawn (inst 'actor 'name 'badeline 'x 22)
    (fn (me)
      (walk-to me 16))) ; cancels: falling
  (spawn (inst 'actor 'name 'theo 'x 18)
    (fn (me)
      (walk-to me 14)
      (wait me 3)
      (walk-to me 19)))
  (spawn (inst 'actor 'name 'granny 'x 3)
    (fn (me)
      (wait me 16)
      (car 42)          ; errors won't interrupt other actors
      (walk-to me 10))) ; never runs
  (run-world numticks*)
  (prn)
  (each a (actors)
    (report a "final: x=" a!x " " a!reason)))

(when (main)
  (demo))
