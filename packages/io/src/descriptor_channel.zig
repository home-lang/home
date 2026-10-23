//! Bounded, nonblocking local SCM_RIGHTS records, without VM or event-loop state.
//! Endpoints/fds are move-only by convention. Serialize calls and close explicitly.
const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
pub const shared = @import("posix_shared_memory.zig");
pub const max_fds = 16;
pub const max_bytes = 4096;
// Pinned Zig lacks target cmsghdr declarations. These are the Linux 64-bit
// little-endian glibc/musl and Darwin sys/socket.h layouts, independently checked
// by the consumer's C integration. Darwin CMSG_* uses ALIGN32, not sizeof(usize).
const Header = if (builtin.os.tag == .linux) extern struct { len: usize, level: c_int, kind: c_int } else extern struct { len: u32, level: c_int, kind: c_int };
const alignment: usize = if (builtin.os.tag == .linux) 8 else 4;
fn aligned(n: usize) usize {
    return (n + alignment - 1) & ~(alignment - 1);
}
const data_at = aligned(@sizeOf(Header));
// Darwin externalizes *all* rights before copying ancillary bytes to userspace;
// CTRUNC with a small buffer can hide newly installed fds. Receive its complete
// kernel maximum (XNU UIPC_MAX_CMSG_FD=512), then close rights above our limit.
// Linux SCM_MAX_FD=253 fits too. Never size this buffer to the public 16-fd limit.
const control_size = data_at + aligned(512 * @sizeOf(c_int));
fn supported() !void {
    if (!builtin.link_libc or (builtin.os.tag != .linux and builtin.os.tag != .macos) or @sizeOf(usize) != 8 or builtin.cpu.arch.endian() != .little) return error.UnsupportedPlatform;
}
fn lastError() anyerror {
    return switch (c._errno().*) {
        @intFromEnum(c.E.AGAIN), @intFromEnum(c.E.NOBUFS) => error.WouldBlock,
        @intFromEnum(c.E.INTR) => error.Interrupted,
        else => error.ChannelFailed,
    };
}
fn cloexec(fd: c_int) !void {
    while (c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC)) != 0) {
        if (lastError() != error.Interrupted) return error.ChannelFailed;
    }
}
pub const Pair = struct {
    ends: [2]shared.Fd,
    pub fn init() !Pair {
        try supported();
        var fds: [2]c_int = undefined;
        // Darwin's SOCK.CLOEXEC is only a Zig shim, never pass it to libc.
        const flags = c.SOCK.DGRAM | (if (builtin.os.tag == .linux) c.SOCK.CLOEXEC else 0);
        while (c.socketpair(c.AF.UNIX, flags, 0, &fds) != 0) {
            if (lastError() != error.Interrupted) return error.ChannelFailed;
        }
        var result = Pair{ .ends = .{ .{ .value = fds[0] }, .{ .value = fds[1] } } };
        errdefer result.close() catch {};
        for (fds) |fd| {
            if (builtin.os.tag == .macos) try cloexec(fd);
            // Fixed kernel queue budget, no unbounded userspace send queue.
            const bytes: c_int = 64 * 1024;
            if (c.setsockopt(fd, c.SOL.SOCKET, c.SO.SNDBUF, &bytes, @sizeOf(c_int)) != 0 or c.setsockopt(fd, c.SOL.SOCKET, c.SO.RCVBUF, &bytes, @sizeOf(c_int)) != 0) return error.ChannelFailed;
            if (builtin.os.tag == .macos) {
                const yes: c_int = 1;
                if (c.setsockopt(fd, c.SOL.SOCKET, c.SO.NOSIGPIPE, &yes, @sizeOf(c_int)) != 0) return error.ChannelFailed;
            }
        }
        return result;
    }
    pub fn close(self: *Pair) !void {
        var failed = false;
        for (&self.ends) |*fd| fd.close() catch {
            failed = true;
        };
        if (failed) return error.ChannelFailed;
    }
};
/// Atomic datagram. Fds are borrowed for this call; no owner is consumed on
/// WouldBlock. Successful send duplicates descriptors into the peer's queue.
pub fn send(fd: c_int, bytes: []const u8, fds: []const c_int) !void {
    try supported();
    if (fd < 0 or bytes.len == 0 or bytes.len > max_bytes or fds.len > max_fds) return error.InvalidRecord;
    for (fds) |value| if (value < 0) return error.InvalidRecord;
    var control: [control_size]u8 align(8) = @splat(0);
    const header: *Header = @ptrCast(&control);
    header.* = .{ .len = @intCast(data_at + fds.len * @sizeOf(c_int)), .level = c.SOL.SOCKET, .kind = 1 }; // SCM_RIGHTS = 1 on both supported ABIs.
    @memcpy(control[data_at..][0 .. fds.len * @sizeOf(c_int)], std.mem.sliceAsBytes(fds));
    const iov: c.iovec_const = .{ .base = bytes.ptr, .len = bytes.len };
    const message: c.msghdr_const = .{ .name = null, .namelen = 0, .iov = @ptrCast(&iov), .iovlen = 1, .control = if (fds.len == 0) null else &control, .controllen = if (fds.len == 0) 0 else @intCast(data_at + aligned(fds.len * @sizeOf(c_int))), .flags = 0 };
    while (true) {
        const count = c.sendmsg(fd, &message, c.MSG.DONTWAIT | (if (builtin.os.tag == .linux) c.MSG.NOSIGNAL else 0));
        if (count >= 0) return if (count == bytes.len) {} else error.ChannelFailed;
        const err = lastError();
        if (err != error.Interrupted) return err;
    }
}
pub const Received = struct {
    bytes: usize = 0,
    count: usize = 0,
    fds: [max_fds]shared.Fd = @splat(.{}),
    /// Take one fd out of the record; the recipient becomes its sole owner.
    pub fn take(self: *Received, index: usize) !shared.Fd {
        if (index >= self.count or self.fds[index].value < 0) return error.InvalidRecord;
        const value = self.fds[index];
        self.fds[index] = .{};
        return value;
    }
    pub fn close(self: *Received) !void {
        var failed = false;
        for (&self.fds) |*fd| fd.close() catch {
            failed = true;
        };
        self.bytes = 0;
        self.count = 0;
        if (failed) return error.ChannelFailed;
    }
};
/// One record. Rejects truncated bytes/control and closes *every* delivered fd
/// before returning an error. No fd escapes on an invalid packet or CLOEXEC error.
pub fn receive(fd: c_int, bytes: []u8) !Received {
    try supported();
    if (fd < 0 or bytes.len == 0 or bytes.len > max_bytes) return error.InvalidRecord;
    var control: [control_size]u8 align(8) = @splat(0);
    var iov: c.iovec = .{ .base = bytes.ptr, .len = bytes.len };
    var message: c.msghdr = .{ .name = null, .namelen = 0, .iov = @ptrCast(&iov), .iovlen = 1, .control = &control, .controllen = control.len, .flags = 0 };
    const count = while (true) {
        // Linux atomically receives CLOEXEC. Darwin has no such recvmsg flag;
        // callers must serialize exec/inheritance with receive on that platform.
        const n = c.recvmsg(fd, &message, c.MSG.DONTWAIT | (if (builtin.os.tag == .linux) c.MSG.CMSG_CLOEXEC else 0));
        if (n >= 0) break n;
        const err = lastError();
        if (err != error.Interrupted) return err;
    };
    var result: Received = .{ .bytes = @intCast(count) };
    errdefer result.close() catch {};
    var invalid = count == 0 or count > bytes.len or message.controllen > control.len or message.flags & (c.MSG.TRUNC | c.MSG.CTRUNC) != 0;
    var at: usize = 0;
    const end: usize = @min(message.controllen, control.len);
    while (at + @sizeOf(Header) <= end) {
        const header: *align(1) const Header = @ptrCast(&control[at]);
        const len: usize = header.len;
        if (len < data_at) {
            invalid = true;
            break; // Kernel-generated headers must be in bounds.
        }
        const available = @min(len, end - at);
        if (len > available) invalid = true;
        if (header.level == c.SOL.SOCKET and header.kind == 1) {
            // Even if the last ancillary header was truncated, every complete
            // descriptor actually delivered in it must acquire a cleanup owner.
            const data = control[at + data_at .. at + available];
            if (data.len % @sizeOf(c_int) != 0) invalid = true;
            var i: usize = 0;
            while (i + @sizeOf(c_int) <= data.len) : (i += @sizeOf(c_int)) {
                const value = std.mem.readInt(c_int, data[i..][0..@sizeOf(c_int)], .little);
                if (value < 0) {
                    invalid = true;
                    continue;
                }
                var owned: shared.Fd = .{ .value = value };
                if (result.count < max_fds) {
                    result.fds[result.count] = owned;
                    result.count += 1;
                } else {
                    owned.close() catch {};
                    invalid = true;
                }
            }
        } else invalid = true;
        if (len > available) break;
        at += aligned(len);
    }
    // Set CLOEXEC only after collecting all owners, so later errors unwind all.
    for (result.fds[0..result.count]) |owned| try cloexec(owned.value);
    if (invalid) return error.InvalidRecord;
    return result;
}

test "actual SCM_RIGHTS shares bytes, owns CLOEXEC duplicates, and closes once" {
    const t = std.testing;
    var pair = try Pair.init();
    defer pair.close() catch unreachable;
    var region = try shared.Region.create(64, 64);
    defer region.close() catch unreachable;
    region.mapping.bytes[7] = 93;
    try send(pair.ends[0].value, "descriptor", &.{region.fd.value});
    var bytes: [max_bytes]u8 = undefined;
    var record = try receive(pair.ends[1].value, &bytes);
    defer record.close() catch unreachable;
    try t.expectEqualStrings("descriptor", bytes[0..record.bytes]);
    try t.expectEqual(@as(usize, 1), record.count);
    var fd = try record.take(0);
    defer fd.close() catch unreachable;
    try t.expect(fd.value != region.fd.value);
    try t.expect(c.fcntl(fd.value, c.F.GETFD) & c.FD_CLOEXEC != 0);
    var mapping = try shared.Mapping.init(fd.value, .{ .offset = 7, .length = 9, .used = 9 }, true, 64);
    defer mapping.close() catch unreachable;
    try t.expectEqual(@as(u8, 93), mapping.bytes[0]);
    mapping.bytes[0] = 68;
    try t.expectEqual(@as(u8, 68), region.mapping.bytes[7]);
    try t.expectError(error.InvalidRecord, record.take(0));
    try t.expectError(error.WouldBlock, receive(pair.ends[1].value, &bytes));
}

test "bounded queue refuses producers and receive truncation closes its rights" {
    const t = std.testing;
    var pair = try Pair.init();
    defer pair.close() catch unreachable;
    var region = try shared.Region.create(64, 64);
    defer region.close() catch unreachable;
    var payload: [max_bytes]u8 = @splat(17);
    var sent: usize = 0;
    while (sent < 10000) : (sent += 1) {
        send(pair.ends[0].value, &payload, &.{region.fd.value}) catch |err| {
            try t.expectEqual(error.WouldBlock, err);
            break;
        };
    }
    try t.expect(sent > 0 and sent < 10000);
    // A truncated datagram has delivered descriptors too: reject without leaks.
    var small: [1]u8 = undefined;
    try t.expectError(error.InvalidRecord, receive(pair.ends[1].value, &small));
    for (1..sent) |_| {
        var record = try receive(pair.ends[1].value, &payload);
        try t.expectEqual(@as(usize, 1), record.count);
        try record.close();
    }
    try t.expectError(error.WouldBlock, receive(pair.ends[1].value, &payload));
    try send(pair.ends[0].value, "again", &.{});
    var record = try receive(pair.ends[1].value, &payload);
    try t.expectEqual(@as(usize, 0), record.count);
    try record.close();
    try t.expectError(error.InvalidRecord, send(pair.ends[0].value, "", &.{}));
    try t.expectError(error.InvalidRecord, send(pair.ends[0].value, "bad", &.{-1}));
}

fn descriptorCount() usize {
    var count: usize = 0;
    for (0..1024) |fd| if (c.fcntl(@intCast(fd), c.F.GETFD) >= 0) {
        count += 1;
    };
    return count;
}
test "excess descriptor arrays and truncated payloads release every received owner" {
    const t = std.testing;
    var pair = try Pair.init();
    defer pair.close() catch unreachable;
    var region = try shared.Region.create(8, 8);
    defer region.close() catch unreachable;
    const before = descriptorCount();
    // Bypass the public send limit. Receiver must collect and close *all* rights
    // before rejecting; never truncate Darwin's ancillary descriptor record.
    const extra = max_fds + 8;
    var control: [data_at + aligned(extra * @sizeOf(c_int))]u8 align(8) = @splat(0);
    const header: *Header = @ptrCast(&control);
    header.* = .{ .len = data_at + extra * @sizeOf(c_int), .level = c.SOL.SOCKET, .kind = 1 };
    for (0..extra) |i| std.mem.writeInt(c_int, control[data_at + i * @sizeOf(c_int) ..][0..@sizeOf(c_int)], region.fd.value, .little);
    const iov: c.iovec_const = .{ .base = "record", .len = 6 };
    const message: c.msghdr_const = .{ .name = null, .namelen = 0, .iov = @ptrCast(&iov), .iovlen = 1, .control = &control, .controllen = control.len, .flags = 0 };
    var bytes: [max_bytes]u8 = undefined;
    for (0..32) |_| {
        try t.expectEqual(@as(isize, 6), c.sendmsg(pair.ends[0].value, &message, c.MSG.DONTWAIT));
        try t.expectError(error.InvalidRecord, receive(pair.ends[1].value, &bytes));
        try t.expectEqual(before, descriptorCount());
        try send(pair.ends[0].value, "truncated", &.{region.fd.value});
        try t.expectError(error.InvalidRecord, receive(pair.ends[1].value, bytes[0..1]));
        try t.expectEqual(before, descriptorCount());
    }
    try pair.ends[1].close();
    try t.expectError(error.ChannelFailed, send(pair.ends[0].value, "peer gone", &.{}));
    try t.expect(c.fcntl(region.fd.value, c.F.GETFD) >= 0);
}
