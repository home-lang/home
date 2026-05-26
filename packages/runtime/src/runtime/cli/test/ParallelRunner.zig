// Copied from bun/src/runtime/cli/test/ParallelRunner.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../../cli/LICENSE.bun.md.
//
// Rewrites:
//   - Upstream re-exports (runAsCoordinator / runAsWorker /
//     workerEmitTestDone / Worker) are PARKED — they depend on
//     `./parallel/runner.zig` and `./parallel/Worker.zig`, which carry
//     bun.sys / bun.spawn / bun.cli.Command deps that fall outside the
//     present allow-list. They will re-land alongside the rest of the
//     `parallel/` subtree (post-12.5).
//   - The module-level //! doc comment is preserved verbatim so future
//     re-attachment of the facade only needs to delete the parked block
//     and re-add the four re-exports.
// No `bun.*` runtime references remain; the file currently has no
// public surface beyond its docs + the inline test below.

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

pub const Worker = struct {
    pub fn onProcessExit(this: *Worker, process: anytype, status: anytype, rusage: anytype) void {
        _ = this;
        _ = process;
        _ = status;
        _ = rusage;
    }
};

test "ParallelRunner docs facade compiles standalone" {
    // No runtime surface yet — the test exists so the file participates in
    // `zig test` and the banner comments above stay live as compile-checked
    // documentation. Once `parallel/runner.zig` lands, replace this with
    // smoke coverage of the facade.
    try std.testing.expect(true);
}
