; Locks: thin arc wrappers over sb-thread mutex + semaphore, plus a
; writer-fair reader-writer lock.

;;;; ---- Mutex ----

(def make-mutex ((o name))
  (sb-thread::make-mutex :name (and name (string name))))

; (w/mutex m body) -- run body with the mutex held; releases on exit
; (normal or non-local). Uses sb-thread::with-mutex (a CL macro)
; via #` so it sees a literal binding spec.
(mac w/mutex (m . body)
  `(#'sb-thread::with-mutex #`(#,,m) ,@body))

;;;; ---- Semaphore ----

(def make-semaphore ((o count 0) (o name))
  (sb-thread::make-semaphore :count count :name (and name (string name))))

(def sem-wait (s)
  (sb-thread::wait-on-semaphore s))

(def sem-post (s)
  (sb-thread::signal-semaphore s))

;;;; ---- Reader-writer lock ----
;
; Built from a mutex + two semaphores. Concurrent readers, exclusive
; writer. Writer-fair: a queued writer is not starved by an arrival
; stream of fresh readers.
;
; Fields:
;   m         -- mutex, protects `readers`
;   readers   -- count of in-flight readers
;   ws        -- "writer slot": single permit; whoever holds it has
;                exclusive access (initially 1 = no one holds it)
;   turnstile -- gate on *arrival*: readers grab-and-release on entry,
;                writers hold for the whole wait + critical section
;
; Why writers don't starve:
;   - A reader entering must first pass through the turnstile (grab,
;     immediately release). If a writer currently holds the turnstile,
;     no new reader can enter, period.
;   - The first reader to enter claims `ws` (so writers wait); the
;     last departing reader posts it back.
;   - A writer takes the turnstile *first*, then waits on `ws`. From
;     the moment the writer holds the turnstile, no new reader can
;     pass through; in-flight readers drain to zero and release `ws`;
;     the writer acquires `ws` and runs.
;   - Worst-case writer wait = time for currently-inside readers to
;     finish their critical sections. Bounded by the longest in-flight
;     reader, not by reader arrival rate.
;
; Mild reader-starvability: a stream of writers will hold the
; turnstile in sequence and keep readers queued. This is the classical
; writer-preference tradeoff -- if you want strict fairness, you'd
; need an explicit FIFO queue (mutex + condvar) instead of a pair of
; semaphores.

(def make-rwlock ((o name))
  (obj m         (make-mutex name)
       readers   0
       ws        (make-semaphore 1)
       turnstile (make-semaphore 1)))

(mac w/read-lock (rw . body)
  (w/uniq g
    `(let ,g ,rw
       ; Pass through the turnstile. If a writer holds it we block
       ; here; otherwise grab-and-release immediately so the next
       ; arrival can come through.
       (sem-wait (,g 'turnstile))
       (sem-post (,g 'turnstile))
       ; First reader claims the writer slot; subsequent readers
       ; just bump the counter.
       (w/mutex (,g 'm)
         (when (is (,g 'readers) 0)
           (sem-wait (,g 'ws)))
         (++ (,g 'readers)))
       (after (do ,@body)
         ; Last reader returns the writer slot.
         (w/mutex (,g 'm)
           (-- (,g 'readers))
           (when (is (,g 'readers) 0)
             (sem-post (,g 'ws))))))))

(mac w/write-lock (rw . body)
  (w/uniq g
    `(let ,g ,rw
       ; Hold the turnstile across the whole wait + critical section.
       ; This is what guarantees no writer-starvation: from the moment
       ; we hold it, no new reader can enter, so the in-flight reader
       ; count is monotonically decreasing toward zero.
       (sem-wait (,g 'turnstile))
       (sem-wait (,g 'ws))
       (after (do ,@body)
         (sem-post (,g 'ws))
         (sem-post (,g 'turnstile))))))
