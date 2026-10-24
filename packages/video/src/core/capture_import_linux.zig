//! Pinned Zig 0.15 Linux capture import. Inject Home IO's shared-memory module
//! so standalone/embedded hosts reuse the same descriptor and mapping owners.
const std = @import("std");
const backing = @import("capture_backing.zig");
const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("sys/stat.h");
    @cInclude("sys/ioctl.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("errno.h");
    @cInclude("linux/dma-buf.h");
});

pub fn Linux(comptime shared: type) type {
    return struct {
        const Self = @This();
        pub const Source = struct { input: backing.ImportBuffer, identity: backing.Identity, frame_bytes: u64 };
        dma_buf: bool,
        last_errno: c_int = 0,
        fn failed(self: *Self) error{SystemIo} {
            self.last_errno = c.__errno_location().*;
            return error.SystemIo;
        }
        pub fn describe(self: *Self, input: backing.ImportBuffer, bytes: u64) !Source {
            if (input.fd < 0 or bytes == 0 or bytes > std.math.maxInt(u32) or input.offset > std.math.maxInt(u32) or
                input.offset > std.math.maxInt(u32) - bytes) return error.InvalidResource;
            var stat: c.struct_stat = undefined;
            if (c.fstat(input.fd, &stat) < 0) return self.failed();
            if (stat.st_size <= 0 or stat.st_ino == 0 or input.offset + bytes > @as(u64, @intCast(stat.st_size))) return error.InvalidResource;
            const flags = c.fcntl(input.fd, c.F_GETFL);
            if (flags < 0) return self.failed();
            if (flags & c.O_ACCMODE != c.O_RDWR) return error.InvalidResource;
            if (!self.dma_buf) {
                // memfd seals are irreversible. Mutable files and POSIX shm can
                // be truncated by another owner and SIGBUS a later camera read.
                const seals = c.fcntl(input.fd, c.F_GET_SEALS);
                if (seals < 0) return error.InvalidResource;
                const required = c.F_SEAL_GROW | c.F_SEAL_SHRINK;
                if (seals & required != required) return error.InvalidResource;
            }
            return .{ .input = input, .identity = .{ .device = @intCast(stat.st_dev), .inode = @intCast(stat.st_ino), .bytes = @intCast(stat.st_size) }, .frame_bytes = bytes };
        }
        pub fn importPrepare(self: *Self, resource: *backing.Resource, source: Source) !void {
            resource.fd = (shared.Fd.duplicate(source.input.fd) catch return self.failed()).value;
            // Recheck the actual duplicate, not the borrowed integer: a changed
            // descriptor/extent must never be published under the original key.
            const actual = try self.describe(.{ .fd = resource.fd, .offset = source.input.offset }, source.frame_bytes);
            if (!std.meta.eql(actual.identity, source.identity)) return error.InvalidResource;
            resource.identity = source.identity;
            resource.offset = source.input.offset;
            if (self.dma_buf) {
                try self.sync(resource.fd, c.DMA_BUF_SYNC_START | c.DMA_BUF_SYNC_READ);
                try self.sync(resource.fd, c.DMA_BUF_SYNC_END | c.DMA_BUF_SYNC_READ);
            }
            const map = shared.Mapping.init(resource.fd, .{ .offset = resource.offset, .length = source.frame_bytes, .used = source.frame_bytes }, false, std.math.maxInt(u32)) catch return self.failed();
            resource.read = @as([*]u8, @ptrCast(map.base.?))[0..map.size];
            resource.read_offset = @intFromPtr(map.bytes.ptr) - @intFromPtr(map.base.?);
        }
        fn sync(self: *Self, fd: c_int, flags: u64) !void {
            var request = c.struct_dma_buf_sync{ .flags = flags };
            const Request = @typeInfo(@TypeOf(c.ioctl)).@"fn".params[1].type.?;
            const command: Request = if (@sizeOf(Request) == 4) @bitCast(@as(u32, @intCast(c.DMA_BUF_IOCTL_SYNC))) else @intCast(c.DMA_BUF_IOCTL_SYNC);
            if (c.ioctl(fd, command, &request) < 0) return self.failed();
        }
        pub fn writable(self: *Self, resource: *backing.Resource) ![]u8 {
            if (resource.write) |bytes| return bytes;
            const read = resource.read orelse return error.InvalidResource;
            const visible = read.len - resource.read_offset;
            const map = shared.Mapping.init(resource.fd, .{ .offset = resource.offset, .length = visible, .used = visible }, true, std.math.maxInt(u32)) catch return self.failed();
            // Both maps use the same page window, so the public visible offset
            // is stable across lazy write mapping and later read-only reopens.
            resource.write = @as([*]u8, @ptrCast(map.base.?))[0..map.size];
            return resource.write.?;
        }
        pub fn destroy(self: *Self, resource: *backing.Resource) !void {
            if (resource.write) |bytes| {
                var map: shared.Mapping = .{ .base = bytes.ptr, .size = bytes.len, .bytes = bytes };
                map.close() catch return self.failed();
                resource.write = null;
            }
            if (resource.read) |bytes| {
                var map: shared.Mapping = .{ .base = bytes.ptr, .size = bytes.len, .bytes = bytes };
                map.close() catch return self.failed();
                resource.read = null;
            }
            var fd: shared.Fd = .{ .value = resource.fd };
            resource.fd = -1;
            fd.close() catch return self.failed();
            resource.* = .{};
        }
        pub fn close(_: *Self) !void {}
    };
}
