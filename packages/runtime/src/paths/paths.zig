// Copied from bun/src/paths/paths.zig at upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// Trimmed re-export surface. Bun's aggregator re-exports the full `Path` /
// `AbsPath` / `RelPath` family from `Path.zig`; those are blocked on a much
// larger port (973 lines + pool machinery) and re-attach when that lands.
// The PathBuffer / WPathBuffer / OSPathChar set is what every other copied
// leaf wants, and that's what we expose here.

pub const EnvPath = @import("./EnvPath.zig").EnvPath;

pub const MAX_PATH_BYTES: usize = if (is_wasm) 1024 else std.fs.max_path_bytes;
pub const PathBuffer = [MAX_PATH_BYTES]u8;
pub const PATH_MAX_WIDE = if (Environment.isWindows) std.os.windows.PATH_MAX_WIDE else 0;
pub const WPathBuffer = [PATH_MAX_WIDE]u16;
pub const OSPathChar = if (Environment.isWindows) u16 else u8;
pub const OSPathSliceZ = [:0]const OSPathChar;
pub const OSPathSlice = []const OSPathChar;
pub const OSPathBuffer = if (Environment.isWindows) WPathBuffer else PathBuffer;

// stubbed: `is_wasm` re-attaches when `home_rt.Environment.isWasm` lands.
// The wasm target is a separate Phase 12 follow-up; for native targets the
// branch always picks `std.fs.max_path_bytes`.
const is_wasm = false;

const std = @import("std");

const home_rt = @import("home_rt");
const Environment = home_rt.Environment;

test "PathBuffer is sized for the platform" {
    // Native targets always use `std.fs.max_path_bytes`; the WASM branch is
    // stubbed out today. The assertion is just that we picked a non-zero size.
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
