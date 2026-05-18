// Copied from bun/src/jsc/BunCPUProfiler.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Slim leaf port: type-rename `BunCPUProfiler` → `CPUProfiler` per the
// home_rt naming convention. The `CPUProfilerConfig` struct and the
// `Bun__startCPUProfiler` / `Bun__setSamplingInterval` extern wrappers are
// preserved (Bun__ externs are C++ link-time contracts and stay verbatim).
//
// The upstream file's `stopAndWriteProfile` / `writeProfileToFile` /
// `buildOutputPath` / `generateDefaultFilename` helpers are NOT yet ported.
// They depend on `bun.sys.File.writeFile`, `bun.AutoAbsPath`,
// `bun.OSPathBuffer`, `bun.timespec`, and `bun.FD.cwd().makePath`, none of
// which are in home_rt's leaf surface. Phase 12.5 (full HTTP/FS stack)
// brings them back online.

const std = @import("std");

// JSC bridge jsc.VM stubbed — re-attaches in Phase 12.2.
pub const VM = opaque {};
// JSC bridge bun.String stubbed — re-attaches in Phase 12.2.
pub const String = opaque {};

pub const CPUProfilerConfig = struct {
    name: []const u8,
    dir: []const u8,
    md_format: bool = false,
    json_format: bool = false,
    interval: u32 = 1000,
};

// C++ function declarations (Bun__-prefixed externs stay verbatim — they
// are C++ link-time contracts that rename when the C++ side ports).
extern fn Bun__startCPUProfiler(vm: *VM) void;
extern fn Bun__stopCPUProfiler(vm: *VM, outJSON: ?*String, outText: ?*String) void;
extern fn Bun__setSamplingInterval(intervalMicroseconds: c_int) void;

/// Re-export under the home-native name. Upstream's `BunCPUProfiler` namespace
/// of free functions becomes `CPUProfiler` here.
pub const CPUProfiler = struct {
    pub fn setSamplingInterval(interval: u32) void {
        Bun__setSamplingInterval(@intCast(interval));
    }

    pub fn startCPUProfiler(vm: *VM) void {
        Bun__startCPUProfiler(vm);
    }

    /// Slim stop hook — calls into C++ but does NOT write to disk yet.
    /// Phase 12.5 reattaches the disk-writing path.
    pub fn stopCPUProfiler(vm: *VM, out_json: ?*String, out_text: ?*String) void {
        Bun__stopCPUProfiler(vm, out_json, out_text);
    }
};

test "CPUProfilerConfig defaults" {
    const cfg: CPUProfilerConfig = .{ .name = "x", .dir = "y" };
    try std.testing.expect(!cfg.md_format);
    try std.testing.expect(!cfg.json_format);
    try std.testing.expectEqual(@as(u32, 1000), cfg.interval);
}

test "VM is an opaque pointer-only type" {
    try std.testing.expect(@sizeOf(*VM) == @sizeOf(usize));
}
