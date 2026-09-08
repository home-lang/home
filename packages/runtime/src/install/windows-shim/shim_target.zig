//! Validate the on-disk .bunx target before removing a Windows bin launcher.
//! Kept independent of OS APIs so malformed metadata is tested on every host.
const std = @import("std");

pub fn matches(input: []const u8, expected: []const u16, version: u13) bool {
    if (input.len < 6 or input.len % 2 != 0) return false;
    const flags = std.mem.readInt(u16, input[input.len - 2 ..][0..2], .little);
    if (flags >> 3 != version) return false;
    const has_shebang = flags & 4 != 0;
    var path_bytes: usize = input.len - 6;
    if (has_shebang) {
        if (input.len < 16) return false;
        path_bytes = std.mem.readInt(u32, input[input.len - 10 ..][0..4], .little);
        const arg_bytes = std.mem.readInt(u32, input[input.len - 6 ..][0..4], .little);
        if (path_bytes % 2 != 0 or arg_bytes < 2 or arg_bytes % 2 != 0) return false;
        if (@as(u64, path_bytes) + arg_bytes + 14 != input.len) return false;
    }
    if (path_bytes / 2 != expected.len or path_bytes % 2 != 0) return false;
    if (!std.mem.eql(u8, input[path_bytes..][0..4], &.{ '"', 0, 0, 0 })) return false;
    for (expected, 0..) |unit, i| {
        if (std.mem.readInt(u16, input[i * 2 ..][0..2], .little) != unit) return false;
    }
    return true;
}

test "native and interpreted shim targets require valid lengths, owner, and version" {
    // v5, no shebang: a quoted UTF-16 path and flags.
    const native = [_]u8{ 'a', 0, '"', 0, 0, 0, 0x30, 0xab };
    try std.testing.expect(matches(&native, &.{'a'}, 5478));
    try std.testing.expect(!matches(&native, &.{'b'}, 5478));
    try std.testing.expect(!matches(&native, &.{'a'}, 5477));
    // v5, shebang: path, quote/NUL, launcher plus space, byte lengths, flags.
    const interpreted = [_]u8{ 'a', 0, '"', 0, 0, 0, 'n', 0, ' ', 0, 2, 0, 0, 0, 4, 0, 0, 0, 0x34, 0xab };
    try std.testing.expect(matches(&interpreted, &.{'a'}, 5478));
    for (0..interpreted.len) |len| try std.testing.expect(!matches(interpreted[0..len], &.{'a'}, 5478));
    var corrupt = interpreted;
    corrupt[10] = 0xff;
    try std.testing.expect(!matches(&corrupt, &.{'a'}, 5478));
    corrupt = interpreted;
    corrupt[14] = 0xff;
    try std.testing.expect(!matches(&corrupt, &.{'a'}, 5478));
    corrupt = interpreted;
    corrupt[2] = 'x';
    try std.testing.expect(!matches(&corrupt, &.{'a'}, 5478));
}
