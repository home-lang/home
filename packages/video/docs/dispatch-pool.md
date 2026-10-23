# Bounded joined dispatch

`core/dispatch_pool.zig` exports `Pool(worker_capacity, task_capacity)` through
`video.dispatch_pool`. It is a portable, allocation-free policy over the existing
`owned_admission.Registry`, not an OS process/thread implementation. The caller
owns payloads, synchronization, transport, result storage and exit evidence.

`init(workers, items, bytes)` bounds live tasks and declared payload cost.
`reserve(cost)` chooses an accepting worker with the lowest pending count,
rotating equal counts. It returns a monotonic ticket and worker generation.
Rejected admission leaves workers/cursor/tasks unchanged. IDs never wrap.
`next(worker, generation)` selects the oldest queued ticket, with at most one
sent task per worker. Call `sent` only after an atomic send succeeds; backpressure
must leave the task queued. No frame/camera pointers are stored here.

The task phases are queued, sent, acknowledged, joined and retired. Sent work
cannot retire until a matching ACK or verified peer join. `stop` quarantines a
worker but does not prove that its mapping users have exited. `acknowledge`
validates the exact ticket/worker/generation. `joined` requires external proof
that the peer and its borrowed resource users exited. It permits retiring that
generation's sent tasks. Merely requesting cancellation or sending a signal is
insufficient. Unsent queued tasks may retire directly.

`retire` permits the caller to destroy the payload/device owner, but retains its
slot and byte reservation through application completion/callback cleanup.
`release` frees only a retired task. Slow callbacks therefore cannot bypass
admission; least-pending counts include them. The underlying registry's
`pendingThrough(target)` provides a fixed cleanup prefix: later tasks do not
extend it, while earlier holes remain pending.

`restart` requires a joined worker with no active or retained tasks. It advances
the generation; stale ACKs/joins cannot mutate its replacement. Pending task
capacity and identities remain independent of worker restarts. The host must
prepare/spawn the new peer and handle startup failure explicitly.

Three policy tests plus four imported admission tests pass on pinned Zig 0.15.2
and Home's development compiler in Debug/ReleaseSafe. Both compiler lines also
cross-link Linux x86_64/aarch64 tests. Coverage includes fair ties, out-of-order
cleanup, stale/reused slots, stop-vs-join, wrong/double ACKs, retirement fences,
replacement generations and rejected transition/accounting invariants.

zig-camera reuses the module verbatim for native-owned frame exports and argument/
result reservations. Its separate C/Bun exec tests verify real descriptor handoff,
ACK/exit-before-retirement, CPU-bound cancellation, error isolation and callback
drains. Those process tests do not turn this pure helper into a kernel supervisor
or establish physical camera/DMA throughput.
