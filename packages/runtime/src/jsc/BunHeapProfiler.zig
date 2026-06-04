// Copied from bun/src/jsc/BunHeapProfiler.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Slim leaf port: type-rename `BunHeapProfiler` → `HeapProfiler` per the
// home_rt naming convention. The `HeapProfilerConfig` struct and the
// `Bun__generateHeapProfile` / `Bun__generateHeapSnapshotV8` externs are
// preserved (Bun__ externs are C++ link-time contracts and stay verbatim).
//
// The upstream file's `generateAndWriteProfile` / `buildOutputPath` /
// `generateDefaultFilename` helpers are NOT yet ported. They depend on
// `bun.sys.File.writeFile`, `bun.AutoAbsPath`, `bun.OSPathBuffer`,
// `bun.timespec`, `bun.FD.cwd().makePath`, `bun.path.dirname`, and
// `bun.Output`. Phase 12.5 (full HTTP/FS stack) brings them back online.

const std = @import("std");

// JSC bridge jsc.VM stubbed — re-attaches in Phase 12.2.
pub const VM = opaque {};
// JSC bridge bun.String stubbed — re-attaches in Phase 12.2.
pub const String = opaque {};

pub const HeapProfilerConfig = struct {
    name: []const u8,
    dir: []const u8,
    text_format: bool,
};

// C++ function declarations (Bun__-prefixed externs stay verbatim).
extern fn Bun__generateHeapProfile(vm: *VM) *String;
extern fn Bun__generateHeapSnapshotV8(vm: *VM) *String;

pub const HeapProfiler = struct {
    /// Generates a heap profile via the C++ entry point. The caller owns the
    /// returned `*String` and must `deref` it once Phase 12.2 ports
    /// `bun.String.deref`.
    pub fn generate(vm: *VM, text_format: bool) *String {
        return if (text_format)
            Bun__generateHeapProfile(vm)
        else
            Bun__generateHeapSnapshotV8(vm);
    }
};

pub fn generateAndWriteProfile(_: anytype, _: HeapProfilerConfig) !void {}

test "HeapProfilerConfig field shape" {
    const cfg: HeapProfilerConfig = .{ .name = "a", .dir = "b", .text_format = true };
    try std.testing.expect(cfg.text_format);
    try std.testing.expectEqualStrings("a", cfg.name);
    try std.testing.expectEqualStrings("b", cfg.dir);
}

test "VM and String stubs are opaque pointer-sized" {
    try std.testing.expectEqual(@sizeOf(usize), @sizeOf(*VM));
    try std.testing.expectEqual(@sizeOf(usize), @sizeOf(*String));
}
