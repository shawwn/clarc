---
name: Sub-coroutines, await, and wait-for in the coroutine example (design)
description: Design notes for matching Celeste's `yield return someEnumerator()` pattern in `examples/coroutines.arc`. The big finding: function calls already implement the inline-sub-coroutine pattern (the call stack IS the enumerator stack). What remains is two small primitives (`await`, `wait-for`) and a docs pass to surface the pattern. Not yet implemented — captured here for the next time we want to extend the example.
type: project
---

# Handoff: sub-coroutine / await / wait-for design — 2026-04-28

Continuation of `2026-04-28-001`. Investigated whether to add
Celeste's `yield return someEnumerator()` pattern to
`examples/coroutines.arc`. Conclusion: the inline pattern already
works via plain function calls, and the only gap is two
two-line helpers plus a documentation pass.

## Celeste pattern frequency

Surveyed all 2033 `yield return` calls in the decompiled
`/Users/shawn/ml/celeste/Celeste/`:

- ~1300 simple waits (`yield return null`, `yield return 0.5f`)
- **~616 sub-coroutine yields** (~30%) of the form
  `yield return SomeMethodReturningIEnumerator(...)`

Top patterns are camera moves (`Level.ZoomBack(0.5f)`), fades
(`FadeTo(1f)`), NPC sequences (`birdNpc.StartleAndFlyAway()`),
character walks (`player.DummyWalkTo(...)`), and synchronization
helpers (`WaitForPlayer()`, `tween.Wait()`). The pattern lets a
cutscene script read top-to-bottom as straight-line code:

```csharp
yield return FadeOut();
yield return PlayerApproachRightSide(player);
yield return granny.WalkAndTalk();
yield return Level.ZoomTo(point, 2f, 0.5f);
yield return null;
```

So this is Celeste's killer feature, not an edge case.

## The realization: function calls already do this

In Celeste, `yield return EnumeratorMethod()` is a *special form*
because C# enumerators are objects — they don't run on their own,
something has to call `MoveNext`. So Celeste's `Coroutine.cs:59-61`
pushes the child onto an enumerator stack and `Update` advances
whichever enumerator is on top until it finishes:

```csharp
if (!(enumerator.Current is IEnumerator))
    return;
this.enumerators.Push(enumerator.Current as IEnumerator);
```

In our thread model, a "coroutine body" is just an arc function. A
function called from inside a body runs on the same OS thread. If
that function calls `(yield)`, `(my-coro)` is keyed by
`(current-thread)` — it returns *the calling thread's coro*, i.e.
the parent. The yield parks the parent's semaphores, exactly as a
top-level yield would. When the function returns, control returns
to the caller and the body continues.

**The "stack of enumerators" in Celeste is literally our call
stack.** No special form needed.

The current demo already uses this without naming it:

```arc
(def parent-body (me)
  (walk-to me 5)    ; <-- this IS "yield return DummyWalkTo(5)"
  (wait me 4)       ; <-- so is this
  (walk-to me 12))
```

`walk-to` internally yields once per tick until it reaches its
target. From the parent's point of view, the call suspends until
the child sequence completes — same semantics as Celeste's `yield
return`, no new primitive.

## What this implies

The implementation effort to "match Celeste's killer feature" is
**zero code**. The runtime already supports it. What's missing is:

1. The pattern isn't called out anywhere — a reader has to derive
   it from the threading model. Worth a comment block in the file
   that names it: "any function that yields is a sub-coroutine;
   call it like a function and the calling body suspends until it
   completes."

2. There's no idiom for "wait for a *parallel* coroutine to
   finish" — the case where you used `add-coro` to spawn a sibling
   and want to join it. That's `await`:

   ```arc
   (def await (c)
     (while (no c!done) (yield)))
   ```

   Celeste doesn't really do this (almost all sub-coroutines in
   Celeste are inline), but the API feels incomplete without it.

3. There's no idiom for "wait until a predicate fires" — the
   thing Celeste calls `WaitForPlayer()`. Also two lines:

   ```arc
   (def wait-for (pred)
     (while (no (pred)) (yield)))
   ```

   Then `(wait-for [is me!x target])` and `(wait-for [no
   level!frozen])` are one-liners in cutscene-style code.

## Cooperative cancel — the other piece

Touched on in `2026-04-28-001` but not implemented. Once `await`
and `wait-for` exist, "cancel a long-running thing" is just "set a
flag and have any helper that yields check it." The demo already
does the actor version via `me!dead` and the `(when me!dead …
(stop))` check inside `walk-to`. Coro-level cancel would standardise
on `c!cancel` and have helpers check both:

```arc
(def yield ((o ticks 1))
  (let c (or (my-coro) (err "yield called outside a coroutine"))
    (when c!cancel (throw 'cancelled))
    ...))
```

Or simpler: `(unless c!cancel ...)` and let the body notice on its
own. The exact shape depends on whether we want cancel to *unwind*
the body (clean) or just be polled (more like Celeste). Decide
when there's a real use case.

## Recommendation when we get back to this

Order of work, smallest to largest:

1. **Comment block in `examples/coroutines.arc`** explaining the
   inline-sub-coroutine pattern. Could go right after the
   existing contract block. Show that `walk-to` and `wait` are
   already examples. ~10 lines.

2. **Add `await` and `wait-for`** to the file. Four lines of
   code. They're worth having even though the demo doesn't use
   them, because anyone writing real cutscene-style code will
   reach for both within minutes.

3. **Cooperative `c!cancel`** in `yield`. Pick a semantic
   (unwind via condition, or polled flag). Update the contract
   comment block to document it.

4. **Optionally** add a demo actor that exercises the new
   primitives — e.g., madeline spawns a shadow that
   `(wait-for [is me!x 3])` reacts to. Validates the API end-to-
   end and gives readers an example of each.

Total work for #1–#3 is maybe 30 lines including comments.
Skipped for now because the demo doesn't need them and
speculative API design risks landing on the wrong shape.

## Why this isn't done yet

Two reasons:

- **No real use case driving it.** The current demo is small and
  satisfied. Adding speculative primitives without code that
  wants them risks landing on the wrong API.

- **The big insight is the documentation, not the code.** Once
  someone understands "a function that yields IS a sub-
  coroutine," half the speculative additions disappear (you
  don't need a special "yield-to" form because plain function
  call already does it). Until that's written down, additions
  could pile up around a misconception.

## Current state

- `examples/coroutines.arc`: unchanged; existing demo already
  uses the function-as-sub-coroutine pattern (`walk-to`, `wait`)
  without calling it out.
- This handoff captures the design analysis so the next person
  to extend the example doesn't have to redo it.
