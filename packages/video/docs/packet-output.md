# Checked elementary packet and PTS output

`src/core/packet_output.zig` is a standalone, allocation-free boundary for
reusable streaming sinks. The broader sink graph includes decoded-frame and
accumulating packet collections; this module neither retains borrowed packets
nor imports that graph.

`annexB(input, output)` converts four-byte big-endian length-prefixed AVC/HEVC
NAL units to four-byte Annex B start codes. It checks every length before writing
any destination bytes, rejects empty/truncated/zero-length input, and checks
output capacity. Input/output must not overlap. Parameter sets can be converted
separately and prepended at the first key of a newly attached output.

`formatPts(timestamp_us, output)` formats integer microsecond PTS as milliseconds
with exactly three decimal digits and LF. Zero and all u64 timestamps are exact;
no floating-point rounding or locale formatting is used. Too-small buffers remain
unchanged. A 32-byte destination covers the complete u64 range.

`PtsWriter` wraps an explicit synchronous `Sink{context,write}`. Sink callbacks
must completely accept their borrowed data or return an error. Rejected
non-increasing timestamps do not touch the sink. A sink failure poisons the
writer; create a fresh writer for a new clip/epoch. The module does not own files,
threads or packet storage and does not depend on FFmpeg/Libav.

Focused tests on Zig 0.15.2 and the Home development toolchain:

```sh
zig test packages/video/src/core/packet_output.zig
```

Tests cover multi-NAL conversion, malformed/truncated input, exact maximum PTS,
small-buffer state preservation, monotonicity and sink-failure poisoning.
zig-camera uses the helpers at its native callback output boundary, with
independent video decoding and media/PTS timeline checks in its integration suite.

`Slots(T, capacity)` provides fixed-capacity attachment identities for serialized
packet fan-out owners. `add` returns a nonzero ID; `get` and `remove` reject stale
IDs even after a slot is reused. Capacity and ID exhaustion leave entries intact.
No allocation, sink callbacks or payload destruction occur inside the registry;
the caller retains ownership and synchronization. IDs never wrap or repeat.
This supports independent container/PTS lifetimes while sharing encoded packets.

`Slots.replace(id, value)` swaps a live payload while preserving its ID and the
registry count. It returns the old payload for caller-managed finalization.
A stale ID fails before mutation. Packet producers can therefore commit one
attachment's keyframe-aligned replacement without disturbing other attachments
or allowing an old detach request to affect a different logical sink.

`output_recovery.zig` provides `Retry.init(limit, initial_ns, maximum_ns)` and
`poll(now, failed)` for bounded recovery claims. A caller supplies a monotonic
clock, serializes access, and creates a fresh sink for every claimed attempt.
The first observed failure starts a deadline. `observe(now, failed)` arms or
clears the deadline without spending an attempt; asynchronous construction
failures should observe their completion time before a later poll. Later claims use exponential
backoff capped at `maximum_ns`; arithmetic saturates at the clock limit. Zero
initial delay allows an immediate claim. Limit zero disables recovery.

A claim consumes one attempt even if sink construction fails. A healthy poll
clears a pending deadline but preserves the lifetime attempt budget, preventing
flapping sinks from retrying forever. Reconfigure with `init` to explicitly reset
the budget. This helper does not sleep, allocate, open files, retry a poisoned
writer, or promise recovery from source/encoder failures. Check `exhausted()` and
expose failed attempts to the application. Tests cover deadline equality, caps,
failed construction, flapping, disablement, saturation and invalid settings:

```sh
zig test packages/video/src/core/output_recovery.zig
```

`owned_fifo.Queue(T)` owns a fixed byte arena and operation-entry array. Unlike
`packet_ring`, it accepts zero-length payloads and duplicate timestamps/metadata,
so it can queue writes, patches and packet notifications in exact order. Metadata
is copied by value; the caller owns any pointers in `T`. Payloads are explicitly
copied. `push` never allocates, and both byte and entry overflow reject atomically.

Use `front()` and `copyFront(scratch)` without popping while an operation is in
flight. Only acknowledge it with `pop()` after completion. This keeps in-flight
bytes and entries charged against capacity while a producer uses the remaining
arena. Neither the payload nor scratch may alias the arena. A caller supplies its
own mutex/condition and worker lifecycle; no sink runs under a queue lock in this
module. `reset` discards pending work only after the caller accounts for in-flight
ownership. This supports fail-on-full or bounded-wait policies without dropping
individual dependent encoded packets.

Focused tests cover arena wrap, metadata-only operations, in-flight accounting,
byte/entry bounds, unchanged state on rejection, reset and partial allocation
failure cleanup on Zig 0.15.2 and the Home development compiler:

```sh
zig test packages/video/src/core/owned_fifo.zig
```

## Host-runtime delivery

`core/delivery_fifo.zig` builds an acknowledged, owned host-consumer queue on
`owned_fifo`. Producer calls copy payloads into bounded storage and receive a
monotonic sequence. `copy(sequence, destination)` exposes only an owned copy;
`ack(sequence)` releases its capacity after delivery. Stale acknowledgements,
oversized packets, full queues and sequence exhaustion leave state unchanged.
Empty metadata also consumes a slot. The caller serializes all queue access.

`poll(prefix)` observes a fixed issued prefix. A later failure cannot change a
completed prefix, while pending delivery returns the first latched failure.
This supports native codec callbacks feeding an event-loop host without invoking
runtime functions on native threads. The owner supplies synchronization and
keeps the queue alive until every producer and in-flight host hook has retired.

`pts_clock.Clock.accept(source_ns)` supplies a shared epoch when separate clips
rebase their own timestamps. It returns integer microseconds from the first
accepted video frame, retaining source-clock gaps across replacements. Regressing
sources, duplicate times and sub-microsecond collisions fail before mutation.
The caller serializes clock/sink access, excludes audio, orders retiring segments
before successors, and poisons the observer if a write fails. No queue, allocation,
file ownership or floating-point arithmetic is hidden in this helper.

## Asynchronous output factories

`factory_policy.State` composes the existing recording threshold and retry
helpers for caller-serialized asynchronous rotation or recovery. `poll(Input)`
returns a ticket/index claim only when the threshold or media-clock deadline is
due and the caller reports available lifecycle capacity. Pending claims reserve
one preparation slot in the caller; repeated polls cannot duplicate a claim.
No callback, allocation, file operation or thread runs in this policy.

Finish every claim, including cancellation and failure. `finishAt(ticket, code,
now)` rejects stale tickets and positive result codes, records the result and
arms failed recovery backoff at completion time without spending another attempt.
Rotation errors latch until explicit reconfiguration. Recovery claims consume a
lifetime attempt even if construction fails; healthy periods preserve that budget.
Reconfiguration requires no pending claim and preserves the ticket sequence.

Indices and tickets never wrap. The maximum u64 index may be claimed exactly
once. Admission failure consumes neither an index nor an attempt. The caller
owns output identity, slot reservation, generation checks, hook cancellation and
publication; a successful factory result is not itself permission to replace a
live sink. zig-camera uses this module for Bun-created sinks while retaining
bounded native preparation and keyframe publication.

`zig test packages/video/src/core/factory_policy.zig` covers threshold admission,
failed construction, stale completion, pending reconfiguration, lifetime retry
budgets and index exhaustion with both Zig 0.15.2 and the Home development compiler.

## Queue telemetry and cooperative capacity waits

`delivery_fifo.Queue.stats()` reports current owned bytes/entries, accepted and
acknowledged operation/byte totals, rejected admissions, configured bounds and
high-water marks. A copy does not acknowledge an entry. Zero-length metadata
still consumes one operation. Lifetime byte/rejection counters saturate; delivery
sequences reject exhaustion before wrapping. Failed admissions leave queued data
unchanged and do not poison the queue automatically.

`capacity(bytes, items)` checks a complete headroom predicate without mutation.
Requests exceeding the queue's configured limits or requesting zero operations
are invalid. Failure closes capacity queries. A true result is an observation,
not a reservation; callers must serialize admissions or allow later contention.

`capacity_wait.Registry(N)` stores at most N cooperative wait tickets, including
terminal results until explicitly released. Callers supply monotonic times and
capacity observations; the helper never sleeps, allocates, enqueues or calls a
sink. `begin` observes immediate capacity, including a zero timeout. Otherwise,
`poll` checks closure, deadline equality, then available capacity. A timeout cannot
become success merely because polling was delayed until space later appeared.
Tickets never repeat or wrap. Terminal results survive later closure/failure.
Release cancels a pending wait, and close terminates pending waits. Counters expose
requests, blocked waits, outcomes, pending count and saturating total/peak elapsed
time. The caller owns synchronization, payload lifetimes, cancellation and ticket
release; cooperative polling is not a realtime wakeup guarantee.

Focused checks on Zig 0.15.2 and the Home development compiler:

```sh
zig test packages/video/src/core/delivery_fifo.zig
zig test packages/video/src/core/capacity_wait.zig
```

## Owned producer input admission

`owned_admission.Registry(N)` bounds separately allocated asynchronous payloads
by both total bytes and live ticket count. A copied frame or PCM batch remains
charged while queued, running or retained after completion; release only after
freeing its owned payload. The helper owns no pointers, memory, threads or clock.
The caller serializes its control operations and supplies payload allocation.

Admission failures preserve existing ownership. Tickets combine a bounded slot
with a never-repeated identity, so stale or duplicate releases cannot uncharge a
new allocation. Oversized payloads, configured count/byte limits and u64 identity
exhaustion reject without wrapping. Current and peak ownership and admitted,
released and rejected totals remain observable. This supports a persistent
producer worker while keeping codec, buffer and lifecycle policy with its caller.

Capture `issued` and poll `pendingThrough(target)` to fence payload cleanup for
that fixed admission prefix. It scans only the bounded slots and handles releases
in any order, including slot reuse. Later admissions cannot extend a drain, and
an empty prefix is immediately complete. Invalid future targets reject. This
reports ownership settlement regardless of operation result; track cancellation
and operation failures separately. A caller retaining a drain after worker close
must retain the registry and serialize polls with releases.

```sh
zig test packages/video/src/core/owned_admission.zig
```

Focused tests run on Zig 0.15.2 and development Zig. zig-camera reuses this helper
for owned RGB/PCM input budgets and existing capacity_wait/delivery_fifo for
bounded producer backpressure and acknowledged host delivery.
