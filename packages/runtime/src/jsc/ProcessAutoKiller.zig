// Copied from bun/src/jsc/ProcessAutoKiller.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Bookkeeping for the per-VM "auto-killer" — a set of refcounted subprocess
// handles that should receive `SIGTERM` when the VM tears down. The owning
// VM (Phase 12.2) toggles `enabled` on a CLI/option boundary, and the
// `onSubprocessSpawn`/`onSubprocessExit` hooks track lifetime.
//
// `bun.spawn.Process` (the refcounted subprocess handle) and `bun.SignalCode`
// (the cross-platform signal-number enum) are not yet ported. Local stubs
// preserve the structural shape with the methods this file relies on
// (`ref`, `deref`, `hasExited`, `kill`, `pid`). The real types re-attach in
// Phase 12.6 alongside the rest of the subprocess plumbing.
//
// Omitted (re-attach when the subprocess subtree lands):
//   - `bun.Output.scoped(.AutoKiller, .hidden)` debug logger — replaced
//     with a no-op stub so the call sites compile.

const std = @import("std");
const home_rt = @import("home");

const ProcessAutoKiller = @This();

const Process = home_rt.spawn.Process;

/// Stub for `bun.SignalCode`. Real upstream is a cross-platform enum mapping
/// signal names to numeric values; only `.default` is referenced here.
const SignalCode = enum(c_int) {
    default = 15, // SIGTERM
};

/// Stub for `home_rt.Output.scoped(.AutoKiller, .hidden)`. Real logger is a
/// no-op in non-debug builds anyway; the seam re-attaches when the scoped
/// logger lands in `home_rt.Output`.
fn log(comptime _: []const u8, _: anytype) void {}

processes: std.AutoArrayHashMapUnmanaged(*Process, void) = .{},
enabled: bool = false,
ever_enabled: bool = false,

pub fn enable(this: *ProcessAutoKiller) void {
    this.enabled = true;
    this.ever_enabled = true;
}

pub fn disable(this: *ProcessAutoKiller) void {
    this.enabled = false;
}

pub const Result = struct {
    processes: u32 = 0,
};

pub fn kill(this: *ProcessAutoKiller) Result {
    return .{
        .processes = this.killProcesses(),
    };
}

fn killProcesses(this: *ProcessAutoKiller) u32 {
    var count: u32 = 0;
    while (this.processes.pop()) |process| {
        defer process.key.deref();
        if (!process.key.hasExited()) {
            log("process.kill {d}", .{process.key.pid});
            count += @as(u32, @intFromBool(process.key.kill(@intFromEnum(SignalCode.default)) == .result));
        }
    }
    return count;
}

pub fn clear(this: *ProcessAutoKiller) void {
    for (this.processes.keys()) |process| {
        process.deref();
    }

    if (this.processes.capacity() > 256) {
        this.processes.clearAndFree(home_rt.default_allocator);
    }

    this.processes.clearRetainingCapacity();
}

pub fn onSubprocessSpawn(this: *ProcessAutoKiller, process: *Process) void {
    if (this.enabled) {
        this.processes.put(home_rt.default_allocator, process, {}) catch return;
        process.ref();
    }
}

pub fn onSubprocessExit(this: *ProcessAutoKiller, process: *Process) void {
    if (this.ever_enabled) {
        if (this.processes.swapRemove(process)) {
            process.deref();
        }
    }
}

pub fn deinit(this: *ProcessAutoKiller) void {
    for (this.processes.keys()) |process| {
        process.deref();
    }
    this.processes.deinit(home_rt.default_allocator);
}

test "ProcessAutoKiller starts disabled with empty process set" {
    var killer: ProcessAutoKiller = .{};
    defer killer.deinit();
    try std.testing.expect(!killer.enabled);
    try std.testing.expect(!killer.ever_enabled);
    try std.testing.expectEqual(@as(usize, 0), killer.processes.count());
}

test "ProcessAutoKiller.enable sets both enabled and ever_enabled" {
    var killer: ProcessAutoKiller = .{};
    defer killer.deinit();
    killer.enable();
    try std.testing.expect(killer.enabled);
    try std.testing.expect(killer.ever_enabled);
    killer.disable();
    try std.testing.expect(!killer.enabled);
    // `ever_enabled` is sticky — required so post-disable exit hooks still
    // see-through.
    try std.testing.expect(killer.ever_enabled);
}

test "ProcessAutoKiller.kill returns a Result with the process count" {
    var killer: ProcessAutoKiller = .{};
    defer killer.deinit();
    const result = killer.kill();
    try std.testing.expectEqual(@as(u32, 0), result.processes);
}

test "ProcessAutoKiller.onSubprocessSpawn is a no-op when disabled" {
    var killer: ProcessAutoKiller = .{};
    defer killer.deinit();
    var proc: Process = .{ .pid = 12345 };
    killer.onSubprocessSpawn(&proc);
    try std.testing.expectEqual(@as(usize, 0), killer.processes.count());
}

test "SignalCode.default maps to SIGTERM" {
    try std.testing.expectEqual(@as(c_int, 15), @intFromEnum(SignalCode.default));
}
