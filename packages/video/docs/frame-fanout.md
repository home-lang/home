# Bounded frame consumer admission

`core/frame_fanout.zig` shares `packet_output.Slots` identities across a fixed
number of independent frame consumers. It stores no frames, pointers, audio,
threads, queues or allocator. The caller serializes operations. Each admitted
consumer's existing producer owns its copied inputs and byte budget.

Call `ready()` before acquiring a source frame, then `offer()` once and `claim()`
for each active consumer. A consumer admits at most one unfinished ticket.
A busy `wait` consumer gates acquisition; a busy `drop` consumer returns null and
increments its skipped counter. All claims must name the latest offered source
ordinal; duplicates and stale ordinals reject before counters change. Preserve
source timestamps when dropping; deriving time from accepted frame count would
compress gaps. The registry does not synchronize PCM or define a media clock.

Call `finish(id, ticket, outcome)` exactly once after producer cleanup. Completion,
failure and cancellation have separate counters; cancellation alone does not
quarantine a live consumer. `fail(id)` quarantines source/dispatch failure even
without a claim, retaining any entered ticket until its owner finishes it.
`retire(id)` stops admission immediately. Busy retirement reserves capacity until
the exact ticket finishes; idle retirement removes the slot immediately. Save the
returned state for statistics after retirement. Identities/tickets never recycle,
exhaustion rejects without wrapping, and observation counters saturate.

The consumer owner remains responsible for joining codecs, asynchronous hooks,
and resource cleanup. Finishing an old ticket cannot release a replacement's
slot. A retained failed consumer consumes bounded capacity until retirement.
Use one registry across camera reopen operations when old consumers can remain
observable. There is no implicit shared audio read cursor or extra frame queue.

Test directly with Zig 0.15.2 or Home development Zig:

```sh
zig test packages/video/src/core/frame_fanout.zig
zig test packages/video/src/core/frame_fanout.zig -O ReleaseSafe
```
