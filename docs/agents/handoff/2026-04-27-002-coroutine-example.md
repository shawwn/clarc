---
name: Coroutine scheduler example (celeste-style)
description: Adds examples/coroutines.arc — a thread-per-actor coroutine scheduler with two SBCL semaphores per actor (resume / parked). Actor bodies are straight-line Arc with `(while ...)` / `(yield self)` / `(yield self n)`, mirroring Celeste's IEnumerator pattern.
type: project
---

# Handoff: coroutine example — 2026-04-27

This is a self-contained example of how Arc-on-SBCL can drive
game-object code in the style Celeste uses for its
`IEnumerator DummyWalkToExact` routines. The actor body is plain
straight-line Arc — `(while …)` loops with `(yield self)` between
ticks — and the scheduler runs one actor at a time per tick.

It depends on the `pkg::name` reader change from handoff
`2026-04-27-001`, but it's a worked design in its own right: if
that interop landing ever gets reverted, swap the three
`(sb-thread::…)` calls back for `#'(defun …)` wrappers around
`find-symbol` and the rest is unchanged.

## The shape we're imitating

Celeste's `Player.cs` has methods like:

```csharp
public IEnumerator DummyWalkToExact(int x, ...) {
  ...
  while (!player.Dead
         && player.X != x
         && !player.CollideCheck<Solid>(...)
         && (!cancelOnFall || player.OnGround()))
  {
    player.Speed.X = ...;
    ...
    yield return null;
  }
  ...
}
```

Each yield hands control back to Unity's coroutine scheduler,
which wakes the routine on the next frame. The actor body reads
top-to-bottom like ordinary code — the loop guard reads as
"do this until any of these conditions stop holding."

In Arc, with this scheduler, the same routine is:

```arc
(def walk-to-exact (self target (o cancel-on-fall t))
  (while (and (no self!dead)
              (isnt self!x target)
              (no (collide (+ self!x (if (< self!x target) 1 -1))))
              (or (no cancel-on-fall) (on-ground self!x)))
    (++ self!x (if (< self!x target) 1 -1))
    (yield self))
  ...)
```

That's the goal. Everything else in the file is the plumbing to
make `(yield self)` actually park the actor between ticks.

## Design choice: thread-per-actor

There were two reasonable ways to give Arc this kind of yield:

1. **Closure-trampoline / CPS macro.** Walk the actor body and
   rewrite each `yield` into "save state, return a thunk." Single-
   threaded, cheap, but requires either a hand-written code walker
   or pulling in `cl-cont`. Macros that span the body
   (`while`, `let`, custom user macros) all need recognising.

2. **Thread-per-actor + semaphores.** Each actor body runs on its
   own SBCL thread. `yield` is just two semaphore ops. The whole
   scheduler is ~10 lines and any control flow available in Arc
   "just works" inside a body — no walker, no special macros.

Picked (2). It's strictly more permissive (can call any
yield-aware helper from anywhere), the cost is one thread per
actor (fine at game-object scale), and it lets the demo file stay
small enough to read in one sitting.

## The two-semaphore protocol

Each actor (an Arc table) carries two semaphores:

| Semaphore | Posted by | Waited on by | Meaning              |
| --------- | --------- | ------------ | -------------------- |
| `resume`  | scheduler | actor thread | "go run one tick"    |
| `parked`  | actor     | scheduler    | "I've parked again"  |

The handshake per tick, for one actor:

```
scheduler          actor thread
---------          ------------
                   sem-wait  resume    ← parked from previous yield
sem-post  resume   →
                   ... runs body ...
                   sem-post  parked    ← inside (yield self)
                   sem-wait  resume    ← parks until next tick
sem-wait  parked   ←
[next actor]
```

Two semaphores rather than one because we need a *symmetric*
hand-off: each side wakes the other and then immediately blocks
itself until the other side hands back. With one semaphore you
get races on the second tick.

The first tick is the same protocol: `make-coro` starts the thread
which immediately blocks on `resume`. The first `step-coro` posts
`resume` and waits on `parked`. When the body returns (or errors
out), the `(after …)` clause posts `parked` one final time and
sets `done=t`, so the scheduler unblocks and subsequent
`step-coro` calls are no-ops:

```arc
(def make-coro (name body-fn)
  (let a (obj name name x 0 dead nil done nil
              resume (sem) parked (sem))
    (= a!thread
       (thread
         (sem-wait a!resume)
         (after (body-fn a)
           (= a!done t)
           (sem-post a!parked))))
    a))
```

`after` is unwind-protect, so an actor that throws still hands
the scheduler back its turn and gets marked done. The demo's `neo`
deliberately calls `(car 42)` to verify this — the other three
actors keep running.

## yield, with optional sleep

The base form parks for one tick:

```arc
(def yield (self (o ticks))
  (sem-post self!parked)
  (if ticks (delay self ticks))
  (sem-wait self!resume))
```

With a tick count it parks for that many ticks via `delay`, which
just loops `(yield self)`:

```arc
(def delay (self n)
  (repeat n (yield self)))
```

Actor-side loops, no scheduler change. At N round-trips per N-tick
sleep this is cheap at game tick rates. If profiling ever shows
it matters, the alternative is a scheduler-side skip counter
(actor sets `self!skip = n`, `step-coro` decrements without
signalling the actor thread). That generalises naturally to
"wait until predicate" — store a thunk instead of a count.

## The world and step-coro

The scheduler itself is small. A world is a table with `actors`,
`solids`, `ground-max`, `tick`. `step-coro` is the per-tick
hand-off; `tick-world` walks the actor list once.

```arc
(def step-coro (a)
  (unless a!done
    (sem-post a!resume)
    (sem-wait a!parked)))

(def tick-world ()
  (++ world*!tick)
  (each a (actors)
    (step-coro a)))
```

The world is held in `world*` (an Arc-style global with a `*`
suffix). The accessors `(actors)` and `(tick)` are sugar for
`world*!actors` / `world*!tick` — the latter is what an actor
body calls when it wants to know the current tick number for log
output.

## kill-coro

When `run-world` ends, any actor still parked on `resume` will
sit there forever. `kill-coro` flips `done=t` and terminates the
thread:

```arc
(def kill-coro (a)
  (unless a!done
    (= a!done t)
    (errsafe:kill-thread a!thread)))
```

`errsafe:` is Arc's compose ssyntax for `(errsafe (kill-thread …))`
— if the thread already exited between the `done` check and the
terminate call, the error is swallowed. `kill-thread` maps to
`sb-thread:terminate-thread`, which is the harshest possible
shutdown; for game scenarios you'd usually prefer cooperative
termination via `(= self!dead t)` and a body that checks `dead`
on every loop.

## The demo's four actors

Each actor exercises a different branch of `walk-to-exact`'s
guard:

| Actor    | Behavior                                            |
| -------- | --------------------------------------------------- |
| madeline | walks 0 → 5, sleeps 4 ticks, walks 5 → 12 (wall@8)  |
| badeline | starts at x=22 (off-platform); cancels immediately  |
| theo     | walks 18 → 14, sleeps 3 ticks, walks 14 → 19        |
| neo      | walks 3 → 5, then `(car 42)` errors mid-body        |

`madeline` exercises the collide branch (`solids '(8)` — wall at
x=8). `badeline` exercises the on-ground/cancel branch. `theo` is
a clean start-pause-finish. `neo` exercises the error-in-body
path: its `after` clause still runs, the scheduler still sees
`done=t`, the other three actors continue.

## Lessons from building it

A few things tripped me up that aren't documented elsewhere:

- **`join` is `cons`, not append.** `arc0.lisp:148` defines
  `(join a b) = (cons a b)`. So `(join nil (list a))` gives
  `(nil a)`, not `(a)`. The first version of `spawn` used `join`
  to extend the actor list and produced an actor list with a
  `nil` glued to the front; iteration crashed trying to call
  `nil` as a function. `(push a world*!actors)` is what works.

- **`@` in strings always interpolates**, even before whitespace.
  `prn`-ing `"  @ x="` reads `x=` as a variable name, errors
  "Unbound variable: x=". Use `"@@"` to escape the `@`, or just
  pick a different separator. (See handoff `012` for the atstring
  reader rule — `(atpos s i)` only treats `@@` as the escape; any
  other follower triggers interpolation.)

- **No `argv*` is exposed to Arc.** `boot.lisp` does set
  `main-file*` to the script's truename when run as a script,
  and arc.arc has `(def main () (and main-file* (is script-file*
  main-file*)))`. So `(when (main) (demo))` is the idiom for
  "run when invoked as a script, but not when loaded from the
  REPL."

- **Per-thread output interleaving works because `prn` flushes.**
  Multiple actor threads writing to stdout produced clean line-
  separated output without explicit synchronisation. If you ever
  see torn writes, wrap the actor's prints in `atomic-invoke` or
  hand it through a channel.

## Verified

```
$ ./examples/coroutines.arc
-- tick 1 --
  neo: walking 3 -> 5
    neo at x=4
  theo: walking 18 -> 14
    theo at x=17
  badeline: walking 22 -> 16
  badeline: stopped at x=22
  badeline done
  madeline: walking 0 -> 5
    madeline at x=1
-- tick 2 --
    neo at x=5
    theo at x=16
    madeline at x=2
...
neo final: x=5 done=T
theo final: x=19 done=T
badeline final: x=22 done=T
madeline final: x=7 done=T
```

Stderr is just neo's intentional `(car 42)` backtrace, which is
the demonstration that one actor's crash doesn't take down the
others.

## Notes for whoever picks this up

- **Order of `def` matters less than you'd think.** `yield` calls
  `delay`, `delay` calls `yield`. Both are arc globals, looked up
  by name at call time, so the file orders them in whichever way
  reads better. The `def`s install the closures into the global
  table; the references are late-bound.

- **`world*` is one global, not a parameter.** That's a
  pragmatic choice for a demo — making it a parameter would force
  every accessor and every actor body to thread it through.
  Real games probably want either a dynamic variable
  (`(let world …)` with `*world*` rebinding) or per-actor closures
  capturing the world.

- **Order of actor stepping is the spawn order, but `push`
  reverses it.** `(actors)` returns the most recently spawned
  actor first. If deterministic-by-spawn-order matters, replace
  `push` with an O(n) append (or maintain a tail pointer).

- **Extending the system is small.** A `wait-for` predicate-poll
  helper is `(while (no (pred)) (yield self))`. A scheduler
  priority is "sort `(actors)` before iterating in `tick-world`."
  A pause/resume is a per-actor `paused` flag checked at the top
  of `step-coro`.

- **The `(after …)` body runs on the actor thread**, not the
  scheduler thread. That's why `(prn …)` calls inside it print
  "actor done" lines mixed in with normal tick output. If the
  scheduler ever needs to know about a completion synchronously,
  read `a!done` after `step-coro` returns.

## Current state

- `examples/coroutines.arc`: 154 lines including comments and the
  demo. Runnable as `./examples/coroutines.arc`; loadable via
  `(load "examples/coroutines.arc") (demo)`. The demo only fires
  when `(main)` is true, so loading from the REPL just defines
  the helpers.
- No runtime changes; depends only on the `pkg::name` reader
  support landed in handoff `2026-04-27-001`.
