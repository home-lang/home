// Copied from bun/src/paths/path_buffer_pool.zig at upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// Thread-local-ish pool of PathBuffer / WPathBuffer slabs so callers don't
// pay the 64 KB-per-buffer stack cost on Windows. Upstream pulls the
// allocator from `bun.threadLocalAllocator()` (mimalloc's per-thread
// heap, freed automatically on thread deinit). Home doesn't have that
// allocator surface yet — see stub note below.

// This pool exists because on Windows, each path buffer costs 64 KB.
// This makes the stack memory usage very unpredictable, which means we can't really know how much stack space we have left.
// This pool is a workaround to make the stack memory usage more predictable.
// We keep up to 4 path buffers alive per thread at a time.
fn PathBufferPoolT(comptime T: type) type {
    return struct {
        const Pool = ObjectPool(T, null, true, 4);

        pub fn get() *T {
            // stubbed: re-attaches when `home_rt.threadLocalAllocator()` lands.
            // Until then we use the global default allocator, which still gives
            // correct behavior — just without the per-thread free-on-exit.
            return &Pool.get(home_rt.default_allocator).data;
        }

        pub fn put(buffer: *const T) void {
            // there's no deinit function on T so @constCast is fine
            var node: *Pool.Node = @alignCast(@fieldParentPtr("data", @constCast(buffer)));
            node.release();
        }

        pub fn deleteAll() void {
            Pool.deleteAll();
        }
    };
}

pub const path_buffer_pool = PathBufferPoolT(PathBuffer);
pub const w_path_buffer_pool = PathBufferPoolT(WPathBuffer);
pub const os_path_buffer_pool = if (Environment.isWindows) w_path_buffer_pool else path_buffer_pool;

const paths = @import("./paths.zig");
const PathBuffer = paths.PathBuffer;
const WPathBuffer = paths.WPathBuffer;

const home_rt = @import("home_rt");
const Environment = home_rt.Environment;
const ObjectPool = home_rt.ObjectPool;

test "path_buffer_pool get/put round-trips a buffer" {
    const buf = path_buffer_pool.get();
    // Stash a sentinel byte so we can confirm we hold a writable slab.
    buf.*[0] = 0x42;
    try @import("std").testing.expectEqual(@as(u8, 0x42), buf.*[0]);
    path_buffer_pool.put(buf);
    path_buffer_pool.deleteAll();
}
