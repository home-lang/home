//! Standalone executable verifies the public wrapper without running unrelated
//! legacy env/runtime tests. No Python, shell interpolation or host env leakage.
const std = @import("std");
const env = @import("env");
pub fn main() !void {
    const a = std.heap.page_allocator;
    const key = "HOME_ENV_PUBLIC_EXPORTS_TEST";
    const previous = try env.get(a, key);
    defer if (previous) |v| a.free(v);
    defer {
        if (previous) |v| {
            env.set(key, v) catch unreachable;
        } else env.unset(key) catch unreachable;
    }
    try env.unset(key);
    if (try env.get(a, key) != null) return error.MissingValueMismatch;
    try env.set(key, "");
    const empty = (try env.get(a, key)) orelse return error.EmptyValueMissing;
    defer a.free(empty);
    if (empty.len != 0) return error.EmptyValueMismatch;
    const long = try a.alloc(u8, 8192);
    defer a.free(long);
    @memset(long, 'x');
    try env.set(key, long);
    const value = (try env.get(a, key)) orelse return error.LinuxLibcValueMissing;
    defer a.free(value);
    if (!std.mem.eql(u8, long, value)) return error.LongValueMismatch;
    try env.unset(key);
    if (!std.mem.eql(u8, long, value)) return error.BorrowedValueInvalidated;
}
