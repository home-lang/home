//! Linux DMA heap provider for pinned Zig 0.15.x hosted builds.
const std = @import("std");
const Resource = @import("capture_backing.zig").Resource;
pub const LinuxHeap = struct {
    pub const c = @cImport({
        @cInclude("sys/ioctl.h");
        @cInclude("sys/mman.h");
        @cInclude("fcntl.h");
        @cInclude("unistd.h");
        @cInclude("errno.h");
        @cInclude("linux/dma-heap.h");
    });
    fd: c_int = -1,
    page_size: u64 = 0,
    last_errno: c_int = 0,
    pub const defaults = [_][:0]const u8{
        "/dev/dma_heap/vidbuf_cached",
        "/dev/dma_heap/default_cma_region",
        "/dev/dma_heap/linux,cma",
    };
    fn failed(self: *@This()) error{SystemIo} {
        self.last_errno = c.__errno_location().*;
        return error.SystemIo;
    }
    pub fn open(path: ?[]const u8) !@This() {
        var self: @This() = .{};
        const page = c.sysconf(c._SC_PAGESIZE);
        if (page <= 0 or !std.math.isPowerOfTwo(@as(u64, @intCast(page)))) return error.SystemIo;
        self.page_size = @intCast(page);
        if (path) |selected| {
            if (!std.mem.startsWith(u8, selected, "/dev/dma_heap/") or selected.len <= 14 or selected.len > 4096 or
                std.mem.indexOfScalar(u8, selected, 0) != null or std.mem.indexOfScalar(u8, selected[14..], '/') != null or
                std.mem.eql(u8, selected[14..], ".") or std.mem.eql(u8, selected[14..], "..")) return error.InvalidPath;
            var name: [4097]u8 = undefined;
            @memcpy(name[0..selected.len], selected);
            name[selected.len] = 0;
            self.fd = c.open(@as([*:0]const u8, @ptrCast(&name)), c.O_RDWR | c.O_CLOEXEC);
            if (self.fd < 0) return self.failed();
        } else {
            for (defaults) |name| {
                self.fd = c.open(name.ptr, c.O_RDWR | c.O_CLOEXEC);
                if (self.fd >= 0) break;
                self.last_errno = c.__errno_location().*;
                if (self.last_errno != c.ENOENT and self.last_errno != c.ENODEV) return error.SystemIo;
            }
            if (self.fd < 0) return error.Unsupported;
        }
        return self;
    }
    pub fn allocationBytes(self: *const @This(), bytes: u64) !u64 {
        if (bytes == 0 or self.page_size == 0) return error.InvalidLayout;
        const rounded = std.math.add(u64, bytes, self.page_size - 1) catch return error.SizeOverflow;
        return rounded & ~(self.page_size - 1);
    }
    pub fn prepare(self: *@This(), resource: *Resource, bytes: usize) !void {
        if (self.fd < 0 or bytes == 0) return error.InvalidResource;
        var request = std.mem.zeroes(c.struct_dma_heap_allocation_data);
        request.len = bytes;
        request.fd_flags = c.O_RDWR | c.O_CLOEXEC;
        const Request = @typeInfo(@TypeOf(c.ioctl)).@"fn".params[1].type.?;
        const command: Request = if (@sizeOf(Request) == 4) @bitCast(@as(u32, @intCast(c.DMA_HEAP_IOCTL_ALLOC))) else @intCast(c.DMA_HEAP_IOCTL_ALLOC);
        // An interrupted allocation is reported, not retried without a bound.
        if (c.ioctl(self.fd, command, &request) < 0) return self.failed();
        resource.fd = std.math.cast(c_int, request.fd) orelse return error.InvalidDescriptor;
        const memory = c.mmap(null, bytes, c.PROT_READ, c.MAP_SHARED, resource.fd, 0);
        if (memory == c.MAP_FAILED) return self.failed();
        resource.read = @as([*]u8, @ptrCast(memory.?))[0..bytes];
    }
    pub fn writable(self: *@This(), resource: *Resource) ![]u8 {
        if (resource.write) |bytes| return bytes;
        const read = resource.read orelse return error.InvalidResource;
        const memory = c.mmap(null, read.len, c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, resource.fd, 0);
        if (memory == c.MAP_FAILED) return self.failed();
        resource.write = @as([*]u8, @ptrCast(memory.?))[0..read.len];
        return resource.write.?;
    }
    pub fn destroy(self: *@This(), resource: *Resource) !void {
        if (resource.write) |bytes| {
            if (c.munmap(bytes.ptr, bytes.len) < 0) return self.failed();
            resource.write = null;
        }
        if (resource.read) |bytes| {
            if (c.munmap(bytes.ptr, bytes.len) < 0) return self.failed();
            resource.read = null;
        }
        if (resource.fd >= 0) {
            const fd = resource.fd;
            // Linux consumes the descriptor even on EINTR/late close errors.
            // Report the error once; retry must never close a recycled number.
            resource.fd = -1;
            if (c.close(fd) < 0) return self.failed();
        }
    }
    pub fn close(self: *@This()) !void {
        if (self.fd >= 0) {
            const fd = self.fd;
            self.fd = -1;
            if (c.close(fd) < 0) return self.failed();
        }
    }
};

test "heap rounding covers 4K 16K 64K pages and rejects overflow before allocation" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const t = std.testing;
    for ([_]u64{ 4096, 16384, 65536 }) |page| {
        const heap: LinuxHeap = .{ .page_size = page };
        try t.expectEqual(page, try heap.allocationBytes(1));
        try t.expectEqual(page, try heap.allocationBytes(page));
        try t.expectEqual(page * 2, try heap.allocationBytes(page + 1));
        try t.expectError(error.SizeOverflow, heap.allocationBytes(std.math.maxInt(u64)));
        try t.expectError(error.InvalidLayout, heap.allocationBytes(0));
    }
}
