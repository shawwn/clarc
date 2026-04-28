---
name: Coroutine example — multiple coroutines per actor
description: Refactors examples/coroutines.arc so each actor (a Celeste-style Entity) owns a list of independent coroutines, mirroring Celeste's `ComponentList<Coroutine>` model. Each coroutine carries its own pair of semaphores; (yield) finds its own coro via a thread→coro hash so the body API stays clean.
type: project
---

# Handoff: multi-coro per actor — 2026-04-28

This iterates on `2026-04-27-002` (the original thread-per-actor
scheduler). Same Celeste analogy, but the unit of execution is now
the *coroutine*, not the actor — an actor can own many coroutines
that all advance per tick, exactly like an `Entity` whose
`ComponentList` contains several `Coroutine` components.

The motivating Celeste pattern is `AngryOshiro.Wobble`: it spawns one
`Coroutine` *per* image, all attached to the same entity, all ticked
each frame by `ComponentList.Update`. The previous version of the
demo couldn't express that — there was one body per actor and one
pair of semaphores on the actor. This version can.

## What moved

| Before                                | After                                  |
| ------------------------------------- | -------------------------------------- |
| Actor *is* the coroutine              | Actor owns a list of `coro`s           |
| `resume`/`parked` on the actor        | `resume`/`parked` on each `coro`       |
| One thread per actor                  | One thread per `coro`                  |
| `(yield self)` takes the actor        | `(yield)` looks itself up              |
| `make-coro` / `kill-coro`             | `add-coro` / `kill-coro` / `kill-coros`|
| `tick-world` calls `step-coro` once   | iterates `(copy a!coros)` per actor    |

`deftem actor` and `deftem coro` replace the ad-hoc `obj` tables.
`deftem world` replaces `make-world`. The demo uses `(inst 'actor
…)` to construct each actor.

## Why per-coroutine semaphores

The "obvious wrong thing" is to keep the two semaphores on the actor
and add a list of threads. It looks like it would work but doesn't —
with N parked threads waiting on the same `resume` semaphore, a
single `sem-post` wakes one *arbitrary* thread, not the one we meant
to step. And `sem-wait parked` returns as soon as *any* of them
yields. The hand-off protocol from `2026-04-27-002` only works
1-to-1, so it has to live on the coroutine, not the actor.

This is also how Celeste does it. Each `Coroutine` Component has its
own `waitTimer` and `enumerators` stack
(`Celeste/Monocle/Coroutine.cs:17`); the entity just owns the list.

## How `(yield)` finds its coroutine

The body fn is `(fn (me) …)` where `me` is the actor — same as
before, no extra parameter. So `yield` needs another way to find
which coroutine it belongs to.

A `coros*` global hash maps `(current-thread)` → its `coro`. Each
coroutine thread, on startup, registers itself before its first
yield, and clears its entry on exit:

```arc
(= coros* (table))
(def my-coro () (coros* (current-thread)))

(def add-coro (a body-fn)
  (let c (inst 'coro 'actor a)
    (= c!thread
       (thread
         (= (coros* (current-thread)) c)
         (sem-wait c!resume)
         (after (body-fn a)
           (= c!done t)
           (pull c a!coros)
           (wipe (coros* (current-thread)))
           (sem-post c!parked))))
    (push c a!coros)
    c))
```

There are no cross-thread races on the hash: only the running
coroutine touches its own entry, and only one coroutine runs at a
time (the scheduler blocks on `parked` between steps).

A dynamic variable would also work, and is what I'd reach for if
sharc had a first-class `defparameter`/`with-special` story. The
hash is two lines, no language extension, and the closure-reading
of `(current-thread)` makes it self-evident which coro a given call
belongs to. Worth revisiting if the rest of sharc gains dynamic
vars for other reasons.

## yield vs delay

`yield` is the silent primitive — give up the tick:

```arc
(def yield ((o ticks 1))
  (let c (my-coro)
    (repeat ticks
      (sem-post c!parked)
      (sem-wait c!resume))))
```

`(yield)` waits one tick. `(yield 3)` waits three. This matches
Celeste's `yield return 3.0f` — three ticks of pause, then resume.

`delay` is the talkative version that prints "sleeping at x=…" each
tick and is meant for explicit-wait code paths like `(wait me 4)`:

```arc
(def delay (n)
  (aand (my-coro) it!actor
    (repeat n
      (report it "sleeping at x=" it!x)
      (yield))))
```

The two are split so a parallel sibling coroutine can `(yield 2)`
without spamming "sleeping" output for an actor that's actively
walking on its main coroutine. The shadow watcher in the demo uses
`yield`; `wait` uses `delay`.

(`aand` rebinds `it` at each step — first to the coro, then to the
actor — so the body can use `it` and `it!x` referring to the actor.
Avoids the `(my-coro)!actor` ssyntax trap below.)

## tick-world copies the list

```arc
(def tick-world ()
  (++ world*!tick)
  (prn "-- tick " (tick) " --")
  (each a (actors)
    (each c (copy a!coros)
      (step-coro c))))
```

A coroutine can finish (or spawn a sibling) mid-step and mutate
`a!coros` from inside its `after` clause — that runs on the
coroutine thread *between* `sem-post resume` and `sem-wait parked`,
so it overlaps with the scheduler's `each`. Iterating `(copy
a!coros)` makes the per-tick set deterministic.

## Demo additions

`madeline` now spawns a sibling coroutine on herself before walking:

```arc
(spawn (inst 'actor 'name 'madeline 'x 0)
  (fn (me)
    (add-coro me
      (fn (me)
        (while (no me!reason)
          (report me "(shadow watching x=" me!x ")")
          (yield 2))))
    (walk-to me 5)
    (wait me 4)
    (walk-to me 12)))
```

The shadow ticks every 2 ticks until madeline finishes (sets
`me!reason`). Shows up in the demo output as `(shadow watching
x=N)` lines interleaved with the main body's progress, proving
multiple coroutines on the same actor advance in parallel within
each tick.

The other three actors are unchanged in spirit — `granny` replaces
`neo` as the deliberate-error case (`(car 42)` mid-body).

## Lessons (in addition to those in 2026-04-27-002)

- **`!` ssyntax doesn't compose with parenthesized exprs.**
  `(my-coro)!actor` looks like it should read the `actor` field of
  the coro returned by `(my-coro)`, but `!field` only attaches to
  bare symbols. `(my-coro)!actor` parses as `((my-coro) 'actor)` —
  i.e. calls `my-coro` *with* one argument — which then errors with
  "invalid number of arguments: 1". `(let c (my-coro) c!actor)` or
  `(aand (my-coro) it!actor)` are the working idioms.

- **`(yield n)` should not also `(yield)`.** First version had
  `(if ticks (delay ticks))` *then* one more sem-post/sem-wait.
  That makes `(yield 2)` actually three ticks. The fix is `(repeat
  ticks (sem-post …) (sem-wait …))` — n round-trips, n ticks.

- **An actor body errors → the after clause might not run.** Arc's
  `new-thread` (`arc0.lisp:611`) wraps the body in a `handler-case`
  that prints the error and exits the thread *without* unwinding —
  so the `(after …)` cleanup in `add-coro` is skipped. The
  coroutine never sets `done=t` and the scheduler will hang next
  time it tries to step it. `granny` doesn't trigger this in the
  demo only because she errors at tick 17 with three ticks left.
  Worth wrapping the body call itself in `errsafe` (or doing the
  `done=t` and `sem-post parked` inside a CL `unwind-protect`-style
  wrapper) before this is used for anything real.

## Verified

```
$ ./examples/coroutines.arc
-- tick 1 --
  granny sleeping till tick 17
  granny sleeping at x=3
  theo walking from x=18 to x=14
  badeline walking from x=22 to x=16
  madeline walking from x=0 to x=5
-- tick 2 --
  granny sleeping at x=3
  theo moved to x=17
  badeline finished at x=22 (falling)
  madeline (shadow watching x=0)
  madeline moved to x=1
...
-- tick 17 --
  granny waking up at x=3
Error: Can't take car of 42
...
  granny final: x=3
  theo final: x=19 reached
  badeline final: x=22 falling
  madeline final: x=7 collision
```

`(shadow watching x=…)` interleaved with `madeline moved to x=…`
is the multi-coro evidence — both run inside madeline's tick slot.
Granny's `(car 42)` still doesn't take down the others, same as
before.

## Current state

- `examples/coroutines.arc`: ~240 lines including the demo. Same
  invocation: `./examples/coroutines.arc` or `(load …) (demo)`.
- No runtime changes — all changes are inside the example.
- Open issue: error-in-body bypasses the `after` cleanup; not
  exercised by the current demo but will hang if exercised.
