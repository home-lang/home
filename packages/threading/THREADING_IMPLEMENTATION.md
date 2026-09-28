# Threading implementation status

> 🚧 This document describes the code that exists today and the remaining
> work. It is not a promise of full POSIX compatibility. Planned APIs are
> labeled explicitly and linked to their tracking issues.

## Current implementation

| Area | Current behavior | Evidence |
|---|---|---|
| Threads | `spawn`, `spawnWithAttr`, `join`, `detach`, IDs, yield, and sleep wrap `std.Thread`. The caller allocator and validated stack size reach `std.Thread.SpawnConfig`; priority is stored but not applied. | [`thread.zig`](src/thread.zig) and its inline tests |
| Mutex | Atomic spin lock with `lock`, `tryLock`, and `unlock`. No recursive/error-checking modes, timed lock, robust ownership, or priority inheritance. | [`mutex.zig`](src/mutex.zig) and [#802](https://github.com/home-lang/home/issues/802) |
| Semaphore | Atomic counting semaphore with spin-based `wait`, CAS-based `tryWait`, `post`, and `getValue`. No named or timed semaphore API. | [`semaphore.zig`](src/semaphore.zig) and its inline tests |
| Condition variable | Sequence-counter implementation with spin waiting, signal, and broadcast. It is not an OS-blocking condition variable yet. | [`condvar.zig`](src/condvar.zig) and [#802](https://github.com/home-lang/home/issues/802) |
| Read/write lock | Atomic reader count plus spin-based writer exclusion. No timed operations, preference modes, or upgrade/downgrade API. | [`rwlock.zig`](src/rwlock.zig) and [#802](https://github.com/home-lang/home/issues/802) |
| Barrier and once | Atomic/spin implementations with focused inline tests. | [`barrier.zig`](src/barrier.zig), [`once.zig`](src/once.zig) |
| TLS | Fixed process-wide key table and per-key atomic values. Destructor and true per-thread storage semantics are not implemented. | [`tls.zig`](src/tls.zig) |
| Scheduling | `CpuSet` bit operations and current-thread affinity round trips are implemented on Linux. macOS hard affinity, Windows affinity, and priority application remain unsupported. | [`sched.zig`](src/sched.zig) and [#803](https://github.com/home-lang/home/issues/803) |

The public facade is [`threading.zig`](src/threading.zig). It exports the
implemented types above, including `BinarySemaphore`, and keeps stack-size
constants tied to `ThreadAttr` validation.

## Current thread API

```zig
pub fn Thread.spawn(
    allocator: std.mem.Allocator,
    comptime func: anytype,
    args: anytype,
) !Thread

pub fn Thread.spawnWithAttr(
    allocator: std.mem.Allocator,
    attr: ThreadAttr,
    comptime func: anytype,
    args: anytype,
) !Thread

pub fn Thread.join(self: Thread) !void
pub fn Thread.detach(self: Thread) !void
pub fn Thread.getCurrentId() std.Thread.Id
pub fn Thread.yield() void
pub fn Thread.sleep(nanoseconds: u64) void
```

`ThreadAttr.stack_size` must be at least 16 KiB. `spawnWithAttr` forwards the
selected stack size and allocator to `std.Thread.spawn`. The `priority` field
does not affect the spawned thread yet; that work remains in #803.

## Current semaphore API

```zig
pub fn Semaphore.init(initial_count: u32) !Semaphore
pub fn Semaphore.deinit(self: *Semaphore) void
pub fn Semaphore.wait(self: *Semaphore) !void
pub fn Semaphore.tryWait(self: *Semaphore) !bool
pub fn Semaphore.post(self: *Semaphore) !void
pub fn Semaphore.getValue(self: *const Semaphore) !i32
```

`getValue` uses an acquire load. Values outside the signed public range and
posts that would overflow the internal `u32` return `SemaphoreOverflow`.
`wait` still spins; replacing spin-only waiting with futex-backed blocking is
part of #802.

## Verification

Implementation tests live beside the source rather than in an aspirational
test plan:

- [`thread.zig`](src/thread.zig): spawn/join, yield, sleep, allocator and stack
  configuration, and undersized-stack rejection.
- [`semaphore.zig`](src/semaphore.zig): permit accounting, empty `tryWait`,
  restoration, and overflow behavior.
- [`mutex.zig`](src/mutex.zig), [`condvar.zig`](src/condvar.zig),
  [`rwlock.zig`](src/rwlock.zig), [`barrier.zig`](src/barrier.zig), and
  [`tls.zig`](src/tls.zig): focused current-surface checks.

These tests prove only the current surface. They do not prove fairness,
contention behavior, real-time scheduling, platform affinity, or data-race
freedom.

## Remaining work

- [#802](https://github.com/home-lang/home/issues/802): replace spin-only
  mutex/condition/read-write/semaphore waiting with futex-backed primitives.
- [#803](https://github.com/home-lang/home/issues/803): apply thread priority,
  add Windows affinity, document macOS affinity tags, and complete OS-level
  stack verification.
- [#805](https://github.com/home-lang/home/issues/805): add language-level
  `spawn`, threads, and the multi-core executor.
- [#806](https://github.com/home-lang/home/issues/806): implement `Send`/`Sync`
  auto traits and thread-aware borrow checking. Until that lands, Home does
  not claim compile-time data-race freedom.

No latency, throughput, platform-support, or POSIX-compliance numbers are
claimed until reproducible benchmarks and platform tests exist.
