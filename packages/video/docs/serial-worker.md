# Bounded native serial execution

Import `src/serial_worker.zig` with Zig 0.15.2. `Worker.init(allocator, capacity)`
allocates stable private state and starts one joined native thread. Capacity is
1..64 and counts queued plus executing callbacks. The value handle may be moved;
it must not be copied into independent owners. The portable video root does not
import this native entry point.

`submit` returns a never-repeated ticket and immediately rejects full/closed
admission. It does not take ownership on failure. The caller retains each task
context until its callback has returned, including all payload cleanup. Callbacks
execute FIFO, outside the queue mutex. Predicate testing and sleeping share that
mutex; submitting cannot lose a worker wakeup. The callback can submit more work
subject to the same bound, and can close admission, but cannot wait/join itself.

`finished(ticket)` is a nonblocking cleanup fence. `wait(ticket)` blocks through
that exact prefix, including an executing callback; later admissions do not
extend it. Both reuse the existing owned-admission registry. Callback outcomes,
GPU flip completion and any source leases retained beyond callback return are
separate contracts. A completed worker ticket alone cannot prove GPU retirement.

`closeAdmission` rejects new work and drains accepted callbacks. `deinit` closes
admission, joins the actual thread and then frees its state; it is idempotent on
the same handle. Serialize deinit against other public calls. There is no forced
thread cancellation and no promise to interrupt a kernel ioctl. Native hosted
event loops should poll fences instead of calling the blocking wait or join.

Tests cover stable value return, active ownership bounds, prefix isolation,
closed admission, queued cleanup, allocation failures, callback self-join/wait
rejection, idle wake cycles and four concurrent producers. These tests establish
software scheduling/ownership; they do not establish hardware display behavior.

The older `perf/threading.zig` pool has stack-address startup, separated empty/
wait predicates, queue-only drain and a missing historical core import. It is not
used as this executor or claimed as a working media backend. General kernel
message queues and Home OS IRQ/display ownership do not implement hosted worker
or POSIX frame-export lifetimes.
