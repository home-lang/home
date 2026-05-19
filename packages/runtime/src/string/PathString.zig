// Copied from bun/src/string/PathString.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// A packed `{pointer, length}` view of a borrowed path slice. On 64-bit
// non-Windows targets the pointer is truncated to 53 bits, which on
// x86-64 / aarch64 still covers the full canonical address range; the
// length packs into the remaining bits chosen to fit
// `home_rt.MAX_PATH_BYTES`. This keeps PathString at 64 bits on macOS /
// Linux (a single register) instead of a 128-bit struct on Windows.
//
// Imports rewritten: `@import("bun")` → `@import("home_rt")`,
// `bun.MAX_PATH_BYTES` → `home_rt.MAX_PATH_BYTES`,
// `bun.Environment.isWasm` → `home_rt.Environment.isWasm`. The original
// `const jsc = bun.jsc;` line is dropped (it was unused inside the
// file). No JSC bridge surface.

const PathIntLen = std.math.IntFittingRange(0, home_rt.MAX_PATH_BYTES);
const use_small_path_string_ = @bitSizeOf(usize) - @bitSizeOf(PathIntLen) >= 53;

const PathStringBackingIntType = if (use_small_path_string_) u64 else u128;

// macOS sets file path limit to 1024
// Since a pointer on x64 is 64 bits and only 46 bits are used
// We can safely store the entire path slice in a single u64.
pub const PathString = packed struct(PathStringBackingIntType) {
    pub const PathInt = if (use_small_path_string_) PathIntLen else usize;
    pub const PointerIntType = if (use_small_path_string_) u53 else usize;
    pub const use_small_path_string = use_small_path_string_;

    ptr: PointerIntType = 0,
    len: PathInt = 0,

    pub fn estimatedSize(this: *const PathString) usize {
        return @as(usize, this.len);
    }

    pub inline fn slice(this: anytype) []const u8 {
        @setRuntimeSafety(false); // "cast causes pointer to be null" is fine here. if it is null, the len will be 0.
        return @as([*]u8, @ptrFromInt(@as(usize, @intCast(this.ptr))))[0..this.len];
    }

    pub inline fn sliceAssumeZ(this: anytype) [:0]const u8 {
        @setRuntimeSafety(false); // "cast causes pointer to be null" is fine here. if it is null, the len will be 0.
        return @as([*:0]u8, @ptrFromInt(@as(usize, @intCast(this.ptr))))[0..this.len :0];
    }

    /// Create a PathString from a borrowed slice. No allocation occurs.
    pub inline fn init(str: []const u8) @This() {
        @setRuntimeSafety(false); // "cast causes pointer to be null" is fine here. if it is null, the len will be 0.

        return .{
            .ptr = @as(PointerIntType, @truncate(@intFromPtr(str.ptr))),
            .len = @as(PathInt, @truncate(str.len)),
        };
    }

    pub inline fn isEmpty(this: anytype) bool {
        return this.len == 0;
    }

    pub fn format(self: PathString, writer: *std.Io.Writer) !void {
        try writer.writeAll(self.slice());
    }

    pub const empty = @This(){ .ptr = 0, .len = 0 };
    comptime {
        if (!home_rt.Environment.isWasm) {
            if (use_small_path_string and @bitSizeOf(@This()) != 64) {
                @compileError("PathString must be 64 bits");
            } else if (!use_small_path_string and @bitSizeOf(@This()) != 128) {
                @compileError("PathString must be 128 bits");
            }
        }
    }
};

const home_rt = @import("home_rt");
const std = @import("std");

test "PathString: init round-trips a borrowed slice" {
    const buf = "home/runtime/src/string/PathString.zig";
    const ps = PathString.init(buf);
    try std.testing.expectEqual(@as(usize, buf.len), ps.estimatedSize());
    try std.testing.expectEqualStrings(buf, ps.slice());
    try std.testing.expect(!ps.isEmpty());
}

test "PathString: empty is empty" {
    try std.testing.expect(PathString.empty.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), PathString.empty.estimatedSize());
}

test "PathString: bit layout is 64 on non-Windows" {
    // On macOS/Linux the small path string optimization kicks in.
    if (!home_rt.Environment.isWasm and !home_rt.Environment.isWindows) {
        try std.testing.expectEqual(@as(usize, 64), @bitSizeOf(PathString));
    }
}
