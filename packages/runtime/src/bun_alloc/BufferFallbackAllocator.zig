// Copied from bun/src/bun_alloc/BufferFallbackAllocator.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Upstream uses `#`-prefixed field names (a forthcoming Zig private-field
// syntax) for the two state fields. Zig 0.17.0-dev.263 doesn't accept the
// `#` token, so the fields are renamed to plain `fallback_allocator` /
// `fixed_buffer_allocator`. Semantics are identical — visibility is
// already restricted to the file via private field access; the `#`
// adornment was purely cosmetic at the time of the copy.
//
// No JSC bridge.

/// An allocator that attempts to allocate from a provided buffer first,
/// falling back to another allocator when the buffer is exhausted.
/// Unlike `std.heap.StackFallbackAllocator`, this does not own the buffer.
const BufferFallbackAllocator = @This();

fallback_allocator: Allocator,
fixed_buffer_allocator: FixedBufferAllocator,

pub fn init(buffer: []u8, fallback_allocator: Allocator) BufferFallbackAllocator {
    return .{
        .fallback_allocator = fallback_allocator,
        .fixed_buffer_allocator = FixedBufferAllocator.init(buffer),
    };
}

pub fn allocator(self: *BufferFallbackAllocator) Allocator {
    return .{
        .ptr = self,
        .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        },
    };
}

fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
    const self: *BufferFallbackAllocator = @ptrCast(@alignCast(ctx));
    return FixedBufferAllocator.alloc(
        &self.fixed_buffer_allocator,
        len,
        alignment,
        ra,
    ) orelse self.fallback_allocator.rawAlloc(len, alignment, ra);
}

fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
    const self: *BufferFallbackAllocator = @ptrCast(@alignCast(ctx));
    if (self.fixed_buffer_allocator.ownsPtr(buf.ptr)) {
        return FixedBufferAllocator.resize(
            &self.fixed_buffer_allocator,
            buf,
            alignment,
            new_len,
            ra,
        );
    }
    return self.fallback_allocator.rawResize(buf, alignment, new_len, ra);
}

fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
    const self: *BufferFallbackAllocator = @ptrCast(@alignCast(ctx));
    if (self.fixed_buffer_allocator.ownsPtr(memory.ptr)) {
        return FixedBufferAllocator.remap(
            &self.fixed_buffer_allocator,
            memory,
            alignment,
            new_len,
            ra,
        );
    }
    return self.fallback_allocator.rawRemap(memory, alignment, new_len, ra);
}

fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ra: usize) void {
    const self: *BufferFallbackAllocator = @ptrCast(@alignCast(ctx));
    if (self.fixed_buffer_allocator.ownsPtr(buf.ptr)) {
        return FixedBufferAllocator.free(
            &self.fixed_buffer_allocator,
            buf,
            alignment,
            ra,
        );
    }
    return self.fallback_allocator.rawFree(buf, alignment, ra);
}

pub fn reset(self: *BufferFallbackAllocator) void {
    self.fixed_buffer_allocator.reset();
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;

test "BufferFallbackAllocator: serves from buffer until exhausted, then falls back" {
    var buffer: [16]u8 = undefined;
    var bfa = BufferFallbackAllocator.init(&buffer, std.testing.allocator);
    defer bfa.reset();

    const a = bfa.allocator();

    // First allocation fits in the 16-byte buffer.
    const first = try a.alloc(u8, 8);
    defer a.free(first);

    // Pointer is inside the on-stack buffer.
    const buf_start = @intFromPtr(&buffer[0]);
    const buf_end = buf_start + buffer.len;
    const first_addr = @intFromPtr(first.ptr);
    try std.testing.expect(first_addr >= buf_start and first_addr < buf_end);

    // Second allocation is too big for the remaining buffer; falls back to
    // the testing allocator. The pointer is outside the buffer range.
    const second = try a.alloc(u8, 64);
    defer a.free(second);
    const second_addr = @intFromPtr(second.ptr);
    try std.testing.expect(second_addr < buf_start or second_addr >= buf_end);
}

test "BufferFallbackAllocator: reset clears the fixed-buffer arena" {
    var buffer: [32]u8 = undefined;
    var bfa = BufferFallbackAllocator.init(&buffer, std.testing.allocator);

    const a = bfa.allocator();
    const first = try a.alloc(u8, 16);
    _ = first;

    bfa.reset();

    // After reset, the buffer is fully available again.
    const second = try a.alloc(u8, 16);
    const buf_start = @intFromPtr(&buffer[0]);
    const buf_end = buf_start + buffer.len;
    const addr = @intFromPtr(second.ptr);
    try std.testing.expect(addr >= buf_start and addr < buf_end);
}
