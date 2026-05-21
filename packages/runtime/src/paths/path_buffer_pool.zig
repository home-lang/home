// Copied from bun/src/paths/path_buffer_pool.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT - see ../cli/LICENSE.bun.md.
//
// Bun keeps up to four path buffers alive per thread through ObjectPool +
// thread-local allocator machinery. Home keeps the same public get/put shape
// here and uses the runtime heap allocator for the backing slabs.

fn PathBufferPoolT(comptime T: type) type {
    return struct {
        pub fn get() *T {
            return allocator.create(T) catch @panic("OOM");
        }

        pub fn put(buffer: *const T) void {
            allocator.destroy(@constCast(buffer));
        }

        pub fn deleteAll() void {}
    };
}

pub const path_buffer_pool = PathBufferPoolT(PathBuffer);
pub const w_path_buffer_pool = PathBufferPoolT(WPathBuffer);
pub const os_path_buffer_pool = if (Environment.isWindows) w_path_buffer_pool else path_buffer_pool;

const paths = @import("./paths.zig");
const PathBuffer = paths.PathBuffer;
const WPathBuffer = paths.WPathBuffer;

const std = @import("std");
const builtin = @import("builtin");

const allocator = std.heap.smp_allocator;
const Environment = struct {
    const isWindows = builtin.os.tag == .windows;
};

test "path_buffer_pool get/put round-trips a buffer" {
    const buf = path_buffer_pool.get();
    buf.*[0] = 0x42;
    try std.testing.expectEqual(@as(u8, 0x42), buf.*[0]);
    path_buffer_pool.put(buf);
    path_buffer_pool.deleteAll();
}
