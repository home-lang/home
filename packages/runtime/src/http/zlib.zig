// Copied from bun/src/http/zlib.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Free-function `decompress` + `BufferPool` over `Zlib.ZlibReaderArrayList`.
// Used by the HTTP/1.1 client path to decompress response bodies into a
// scratch `MutableString` and recycle the buffer afterwards.
//
// Rewrites versus upstream:
//   1. `@import("bun")` collapses to `@import("home_rt")`; `Zlib` resolves
//      to `../zlib/zlib.zig` (this batch's port — same path the upstream
//      file uses, just via the home_rt tree).
//   2. `bun.MutableString` routes through `home_rt.MutableString`
//      (`string/MutableString.zig`), the real `{ allocator, list }` buffer.
//   3. `bun.ObjectPool` routes through `home_rt.ObjectPool`.

fn initMutableString(allocator: std.mem.Allocator) anyerror!MutableString {
    return .{ .allocator = allocator, .list = .empty };
}

const BufferPool = home_rt.ObjectPool(MutableString, initMutableString, false, 4);
pub fn get(allocator: std.mem.Allocator) *MutableString {
    return &BufferPool.get(allocator).data;
}

pub fn put(mutable: *MutableString) void {
    mutable.* = .{ .allocator = mutable.allocator, .list = .empty };
    var node: *BufferPool.Node = @fieldParentPtr("data", mutable);
    node.release();
}

pub fn decompress(compressed_data: []const u8, output: *MutableString, allocator: std.mem.Allocator) Zlib.ZlibError!void {
    var reader = try Zlib.ZlibReaderArrayList.initWithOptionsAndListAllocator(
        compressed_data,
        &output.list,
        output.allocator,
        allocator,
        .{
            .windowBits = 15 + 32,
        },
    );
    try reader.readAll(true);
    reader.deinit();
}

const Zlib = @import("../zlib/zlib.zig");
const MutableString = home_rt.MutableString;

const std = @import("std");

const home_rt = @import("home_rt");

test "http.zlib.decompress signature compiles" {
    _ = @typeName(@TypeOf(decompress));
    _ = @typeName(@TypeOf(get));
    _ = @typeName(@TypeOf(put));
    // Smoke: BufferPool's node type carries a MutableString-shaped payload.
    _ = @typeName(BufferPool.Node);
    _ = @typeName(BufferPool);
}
