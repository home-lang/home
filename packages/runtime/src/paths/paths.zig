// Copied from bun/src/paths/paths.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT - see ../cli/LICENSE.bun.md.
//
// Trimmed re-export surface. The full Path/AbsPath/RelPath family is parked
// behind paths/Path.zig until its allocator and fd dependencies land.

pub const EnvPath = @import("./EnvPath.zig").EnvPath;

pub const MAX_PATH_BYTES: usize = if (is_wasm) 1024 else std.fs.max_path_bytes;
pub const PathBuffer = [MAX_PATH_BYTES]u8;
pub const PATH_MAX_WIDE = if (Environment.isWindows) std.os.windows.PATH_MAX_WIDE else 0;
pub const WPathBuffer = [PATH_MAX_WIDE]u16;
pub const OSPathChar = if (Environment.isWindows) u16 else u8;
pub const OSPathSliceZ = [:0]const OSPathChar;
pub const OSPathSlice = []const OSPathChar;
pub const OSPathBuffer = if (Environment.isWindows) WPathBuffer else PathBuffer;

pub const path_buffer_pool = @import("./path_buffer_pool.zig").path_buffer_pool;
pub const w_path_buffer_pool = @import("./path_buffer_pool.zig").w_path_buffer_pool;
pub const os_path_buffer_pool = @import("./path_buffer_pool.zig").os_path_buffer_pool;

// Parked until paths/Path.zig is made buildable without the full Bun runtime.
pub fn Path(comptime opts: anytype) type {
    _ = opts;
    @compileError("paths.Path is not ported in Home yet");
}
pub fn AbsPath(comptime opts: anytype) type {
    _ = opts;
    @compileError("paths.AbsPath is not ported in Home yet");
}
pub fn RelPath(comptime opts: anytype) type {
    _ = opts;
    @compileError("paths.RelPath is not ported in Home yet");
}
pub const AutoAbsPath = opaque {};
pub const AutoRelPath = opaque {};

const is_wasm = false;

const std = @import("std");
const builtin = @import("builtin");

const Environment = struct {
    const isWindows = builtin.os.tag == .windows;
};

test "PathBuffer is sized for the platform" {
    try std.testing.expect(MAX_PATH_BYTES > 0);
    try std.testing.expectEqual(MAX_PATH_BYTES, @typeInfo(PathBuffer).array.len);
}

test "OSPathChar matches platform width" {
    if (Environment.isWindows) {
        try std.testing.expectEqual(u16, OSPathChar);
    } else {
        try std.testing.expectEqual(u8, OSPathChar);
    }
}
