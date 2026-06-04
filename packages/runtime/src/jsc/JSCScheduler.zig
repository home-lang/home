// Copied from bun/src/jsc/JSCScheduler.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// JSC-bridge surface omitted:
//   - `Bun__runDeferredWork`                           extern call inside `run()`
//   - `Bun__eventLoop__incrementRefConcurrently`       export needing VirtualMachine
//   - `Bun__queueJSCDeferredWorkTaskConcurrently`      export needing VirtualMachine + ConcurrentTask
//   - `Bun__tickWhilePaused`                           export needing VirtualMachine.eventLoop
// All four exports re-land alongside the rest of the JSC binding surface in
// Phase 12.2 once VirtualMachine + ExceptionValidationScope + ConcurrentTask +
// Task exist under `home_rt.jsc.*`.
//
// What survives is just the opaque tag type that Bun's scheduler hands across
// the FFI boundary; pointers to it can be threaded through Zig signatures even
// before the dispatch surface lands.

const JSCScheduler = @This();

pub const JSCDeferredWorkTask = opaque {
    pub fn run(_: *JSCDeferredWorkTask) !void {}
};

test "JSCDeferredWorkTask is an opaque pointer-only type" {
    const std = @import("std");
    try std.testing.expect(@sizeOf(*JSCScheduler.JSCDeferredWorkTask) == @sizeOf(usize));
}
