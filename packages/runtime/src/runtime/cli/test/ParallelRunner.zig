// Copied from bun/src/runtime/cli/test/ParallelRunner.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../../cli/LICENSE.bun.md.
//
// Rewrites:
//   - Upstream re-exports (runAsCoordinator / runAsWorker /
//     workerEmitTestDone / Worker) are PARKED — they depend on
//     `./parallel/runner.zig` and `./parallel/Worker.zig`, which carry
//     bun.sys / bun.spawn / bun.cli.Command deps that fall outside the
//     present allow-list. They will re-land alongside the rest of the
//     runtime entrypoint pass.
//   - The module-level //! doc comment is preserved verbatim so future
//     re-attachment of the facade only needs to delete the parked block
//     and re-add the four re-exports.
// No `bun.*` runtime references remain. The upstream behavior surface stays
// parked, but the copied process-pool files are compile-wired behind the
// smoke gate below so Home can parse the chunk without exposing spawn/IPC
// entrypoints prematurely.

//! `bun test --parallel`: process-pool coordinator and worker.
//!
//! The coordinator lazily spawns up to N `bun test --test-worker --isolate`
//! processes (starting with one, adding another whenever every live worker
//! has been busy for ≥`scale_up_after_ms`), hands out one file at a time over
//! stdin, and reads per-test events back over fd 3. Per-test status lines are
//! streamed to the coordinator the moment a test finishes; worker stdout and
//! stderr are buffered and flushed atomically before each result line so
//! console output never interleaves across files. Output is identical to
//! serial: workers are an implementation detail and never named.
//!
//! Thin facade re-exporting the entry points from `parallel/`.

// Parked upstream surface (see file banner):
//   pub const runAsCoordinator = runner.runAsCoordinator;
//   pub const runAsWorker = runner.runAsWorker;
//   pub const workerEmitTestDone = runner.workerEmitTestDone;
//   pub const Worker = @import("./parallel/Worker.zig");

const std = @import("std");

pub const Worker = opaque {};

pub const parallel = struct {
    pub const channel_source = "runtime/cli/test/parallel/Channel.zig";
    pub const coordinator_source = "runtime/cli/test/parallel/Coordinator.zig";
    pub const worker_source = "runtime/cli/test/parallel/Worker.zig";
    pub const aggregate_source = "runtime/cli/test/parallel/aggregate.zig";
    pub const runner_source = "runtime/cli/test/parallel/runner.zig";

    pub const imports = if (enable_process_pool_smoke) struct {
        pub const channel = @import("./parallel/Channel.zig");
        pub const coordinator = @import("./parallel/Coordinator.zig");
        pub const worker = @import("./parallel/Worker.zig");
        pub const aggregate = @import("./parallel/aggregate.zig");
        pub const runner = @import("./parallel/runner.zig");
    } else struct {};
};

test "ParallelRunner docs facade compiles standalone" {
    // No runtime surface yet — the test exists so the file participates in
    // `zig test` and the banner comments above stay live as compile-checked
    // documentation. The process-pool modules are declaration-smoked below.
    try std.testing.expect(true);
}

test "ParallelRunner tracks the copied process-pool modules behind a smoke gate" {
    try std.testing.expectEqualStrings("runtime/cli/test/parallel/Channel.zig", parallel.channel_source);
    try std.testing.expectEqualStrings("runtime/cli/test/parallel/Coordinator.zig", parallel.coordinator_source);
    try std.testing.expectEqualStrings("runtime/cli/test/parallel/Worker.zig", parallel.worker_source);
    try std.testing.expectEqualStrings("runtime/cli/test/parallel/aggregate.zig", parallel.aggregate_source);
    try std.testing.expectEqualStrings("runtime/cli/test/parallel/runner.zig", parallel.runner_source);

    if (enable_process_pool_smoke) {
        try std.testing.expect(@hasDecl(parallel.imports.channel, "Channel"));
        try std.testing.expect(@hasDecl(parallel.imports.coordinator, "Coordinator"));
        try std.testing.expect(@hasDecl(parallel.imports.worker, "Worker"));
        try std.testing.expect(@hasDecl(parallel.imports.aggregate, "mergeJUnitFragments"));
        try std.testing.expect(@hasDecl(parallel.imports.runner, "runAsCoordinator"));
        try std.testing.expect(@hasDecl(parallel.imports.runner, "runAsWorker"));
        try std.testing.expect(@hasDecl(parallel.imports.runner, "workerEmitTestDone"));
    } else {
        try std.testing.expectEqual(@as(usize, 0), @typeInfo(parallel.imports).@"struct".decls.len);
    }
}

const enable_process_pool_smoke = blk: {
    const home_rt = @import("home_rt");
    break :blk home_rt.enable_parallel_process_pool_smoke;
};
