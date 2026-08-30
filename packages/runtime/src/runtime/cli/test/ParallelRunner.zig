// Ported from bun/src/cli/test/ParallelRunner.zig at source pin
// 4982b91e3702094330f3be3883354c52b8c01323. MIT — see
// ../../../cli/LICENSE.bun.md.

//! `bun test --parallel`: process-pool coordinator and worker.
//!
//! The coordinator lazily spawns up to N `bun test --test-worker --isolate`
//! processes, hands out one file at a time over stdin, and reads per-test
//! events back over fd 3. Worker output is buffered and flushed atomically so
//! output from concurrently running files does not interleave.

const runner = @import("./parallel/runner.zig");

pub const runAsCoordinator = runner.runAsCoordinator;
pub const runAsWorker = runner.runAsWorker;
pub const workerEmitTestDone = runner.workerEmitTestDone;
pub const Worker = @import("./parallel/Worker.zig");

const std = @import("std");

test "ParallelRunner exports the complete parallel runtime" {
    try std.testing.expect(@hasDecl(@This(), "runAsCoordinator"));
    try std.testing.expect(@hasDecl(@This(), "runAsWorker"));
    try std.testing.expect(@hasDecl(@This(), "workerEmitTestDone"));
    try std.testing.expect(@hasDecl(@This(), "Worker"));
}
