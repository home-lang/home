const std = @import("std");
const builtin = @import("builtin");
const memory = @import("basics_memory");
const testing = std.testing;

test "protection flags retain each POSIX permission bit" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    for (0..8) |bits| {
        const flags = (memory.Protection{
            .read = bits & 1 != 0,
            .write = bits & 2 != 0,
            .execute = bits & 4 != 0,
        }).toFlags();
        try testing.expectEqual(@as(u32, @intCast(bits)), @as(u32, @bitCast(flags)));
    }
}

test "mapped pages use the runtime page size and allow protection transitions" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const size = memory.pageSize();
    try testing.expectEqual(std.heap.pageSize(), size);
    try testing.expect(std.math.isPowerOfTwo(size));
    try testing.expectError(error.InvalidLength, memory.MappedMemory.create(0, .{ .read = true }));

    const mapping = try memory.MappedMemory.create(size, .{ .read = true, .write = true });
    defer mapping.unmap();
    try testing.expectEqual(size, mapping.len);
    try testing.expectEqual(@as(usize, 0), @intFromPtr(mapping.ptr) % size);
    mapping.asSlice()[0] = 42;
    try mapping.protect(.{ .read = true });
    try testing.expectEqual(@as(u8, 42), mapping.asSlice()[0]);
    try mapping.protect(.{ .read = true, .write = true });
    mapping.asSlice()[size - 1] = 24;
    try testing.expectEqual(@as(u8, 24), mapping.asSlice()[size - 1]);
    try mapping.sync();
}

test "mlock and munlock accept addresses inside a mapped page" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const size = memory.pageSize();
    const mapping = try memory.MappedMemory.create(size, .{ .read = true, .write = true });
    defer mapping.unmap();
    mapping.asSlice()[0] = 11;
    try memory.lock(mapping.ptr + 1, size - 1);
    try memory.unlock(mapping.ptr + 1, size - 1);
    try testing.expectEqual(@as(u8, 11), mapping.asSlice()[0]);
}

test "aligned allocation returns the requested alignment and rejects invalid alignment" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const ptr = try memory.allocAligned(64, 64);
    defer std.c.free(ptr);
    try testing.expectEqual(@as(usize, 0), @intFromPtr(ptr) % 64);
    try testing.expectError(error.AlignedAllocFailed, memory.allocAligned(64, 3));
}
