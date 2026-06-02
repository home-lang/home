// Copied from bun/src/threading/threading.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// Imports rewritten: @import("bun") → @import("home").
// Rewrites:
//   * Skipped entries (none re-exported here yet):
//     - `Channel` — upstream wraps `bun.LinearFifo`, which depends on
//       `std.Io.GenericReader/Writer` (removed in Zig 0.17 dev). The
//       `linear_fifo.zig` port is parked until the std.Io adapter lands.
//     - `ThreadPool` / `WorkPool` — drag in `bun.mimalloc` and
//       `bun.jsc.wtf.releaseFastMallocFreeMemoryForThisThread`, neither of
//       which is wired into home_rt yet.
//   * Everything else (Mutex, Futex, Condition, guarded, WaitGroup,
//     UnboundedQueue) is re-exported verbatim.

pub const Mutex = @import("./Mutex.zig");
pub const Futex = @import("./Futex.zig");
pub const Condition = @import("./Condition.zig");
pub const guarded = @import("./guarded.zig");
pub const Guarded = guarded.Guarded;
pub const GuardedBy = guarded.GuardedBy;
pub const DebugGuarded = guarded.Debug;
pub const WaitGroup = @import("./WaitGroup.zig");
pub const UnboundedQueue = @import("./unbounded_queue.zig").UnboundedQueue;

test "threading: aggregator pulls in all ported leaves" {
    _ = Mutex;
    _ = Futex;
    _ = Condition;
    _ = guarded;
    _ = Guarded;
    _ = GuardedBy;
    _ = DebugGuarded;
    _ = WaitGroup;
    _ = UnboundedQueue;
}

const std = @import("std");
