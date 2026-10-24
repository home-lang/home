//! Hosted POSIX descriptor and shared mapping owners. No runtime/VM dependency.
//! Borrowed fds are duplicated with close-on-exec; anonymous staging is unlinked
//! immediately. Owners are move-only by convention; callers serialize access.
const std = @import("std");
const builtin = @import("builtin");
pub const c = std.c;
// Zig 0.15's per-architecture Linux F namespace omits this Linux UAPI command;
// fcntl-linux.h defines it as F_LINUX_SPECIFIC_BASE (1024) + 6 on both targets.
const dup_cloexec: c_int = if (@hasDecl(c.F, "DUPFD_CLOEXEC")) c.F.DUPFD_CLOEXEC else if (builtin.os.tag == .linux) 1030 else @compileError("unsupported fcntl ABI");
fn errno() c_int {
    return c._errno().*;
}
/// Uses each Zig standard library's target ABI declarations, never a guessed
/// stat layout. Linux development Zig exposes statx instead of legacy fstat.
pub fn extent(fd: c_int) !u64 {
    if (fd < 0) return error.InvalidDescriptor;
    if (builtin.os.tag == .linux and @hasDecl(std.os.linux, "STATX")) {
        const linux = std.os.linux;
        var value: linux.Statx = std.mem.zeroes(linux.Statx);
        if (linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .SIZE = true }, &value) != 0 or !value.mask.SIZE) return error.InvalidDescriptor;
        return value.size;
    } else {
        var value: c.Stat = undefined;
        if (c.fstat(fd, &value) != 0 or value.size < 0) return error.InvalidDescriptor;
        return @intCast(value.size);
    }
}
fn supported() !void {
    if (!builtin.link_libc or (builtin.os.tag != .linux and builtin.os.tag != .macos)) return error.UnsupportedPlatform;
}
pub const Span = struct {
    offset: u64,
    length: u64,
    used: u64,
    pub fn validate(self: Span, maximum: usize) !void {
        if (self.length == 0 or self.length > maximum or self.used > self.length or self.offset > std.math.maxInt(i64) or self.length > @as(u64, std.math.maxInt(i64)) - self.offset) return error.InvalidSpan;
    }
};
pub const Fd = struct {
    value: c_int = -1,
    pub fn duplicate(borrowed: c_int) !Fd {
        try supported();
        if (borrowed < 0) return error.InvalidDescriptor;
        while (true) {
            const fd = c.fcntl(borrowed, dup_cloexec, @as(c_int, 0));
            if (fd >= 0) return .{ .value = fd };
            if (errno() != @intFromEnum(c.E.INTR)) return error.DescriptorFailed;
        }
    }
    /// Consumed even on failure; never retry close on a possibly recycled fd.
    pub fn close(self: *Fd) !void {
        const fd = self.value;
        self.value = -1;
        if (fd >= 0 and c.close(fd) != 0) return error.DescriptorFailed;
    }
};
pub const Mapping = struct {
    base: ?*anyopaque,
    size: usize,
    bytes: []u8,
    /// Checks regular/shared-file extent before mapping, avoiding SIGBUS on a
    /// truncated file. Device-specific descriptors with no fstat extent require
    /// a separately validated device mapping path; this function rejects them.
    pub fn init(fd: c_int, span: Span, writable: bool, maximum: usize) !Mapping {
        try supported();
        try span.validate(maximum);
        if (span.offset + span.length > try extent(fd)) return error.InvalidSpan;
        const page = c.sysconf(@intFromEnum(c._SC.PAGESIZE));
        if (page <= 0) return error.MappingFailed;
        const start = span.offset / @as(u64, @intCast(page)) * @as(u64, @intCast(page));
        const delta: usize = @intCast(span.offset - start);
        const size = std.math.add(usize, delta, @intCast(span.length)) catch return error.InvalidSpan;
        const prot = if (@hasField(c.PROT, "READ")) c.PROT{ .READ = true, .WRITE = writable } else @as(c_uint, @intCast(c.PROT.READ | (if (writable) @as(c_int, c.PROT.WRITE) else 0)));
        const base = c.mmap(null, size, prot, .{ .TYPE = .SHARED }, fd, @as(c.off_t, @intCast(start)));
        if (base == c.MAP_FAILED) return error.MappingFailed;
        return .{ .base = base, .size = size, .bytes = @as([*]u8, @ptrCast(base))[delta..][0..@intCast(span.length)] };
    }
    pub fn close(self: *Mapping) !void {
        return self.closeUsing(c.munmap);
    }
    fn closeUsing(self: *Mapping, comptime unmap: anytype) !void {
        const base = self.base orelse return;
        const Address = *align(std.heap.page_size_min) const anyopaque;
        if (unmap(@as(Address, @alignCast(base)), self.size) != 0) return error.MappingFailed;
        self.base = null;
        self.bytes = &.{};
        self.size = 0;
    }
};
pub const Region = struct {
    fd: Fd,
    mapping: Mapping,
    pub fn create(size: usize, maximum: usize) !Region {
        try supported();
        try (Span{ .offset = 0, .length = size, .used = size }).validate(maximum);
        var owned: Fd = .{};
        for (0..16) |_| {
            var name: [20:0]u8 = undefined;
            name[20] = 0;
            @memcpy(name[0..4], "/hm-");
            var random: [8]u8 = undefined;
            if (builtin.os.tag == .linux) {
                var at: usize = 0;
                while (at < random.len) {
                    const n = std.os.linux.getrandom(random[at..].ptr, random.len - at, 0);
                    if (n == 0 or n > random.len - at) return error.DescriptorFailed;
                    at += n;
                }
            } else c.arc4random_buf(&random, random.len);
            for (random, 0..) |value, i| {
                name[4 + i * 2] = "0123456789abcdef"[value >> 4];
                name[5 + i * 2] = "0123456789abcdef"[value & 15];
            }
            const flags: c_int = @bitCast(c.O{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true });
            const signature = @typeInfo(@TypeOf(c.shm_open)).@"fn";
            const variadic = if (@hasField(@TypeOf(signature), "is_var_args")) signature.is_var_args else signature.attrs.varargs;
            const mode = if (variadic) @as(c_uint, 0o600) else @as(c.mode_t, 0o600);
            const fd = c.shm_open(&name, flags, mode);
            if (fd < 0) {
                if (errno() == @intFromEnum(c.E.EXIST)) continue;
                return error.DescriptorFailed;
            }
            owned.value = fd;
            while (c.shm_unlink(&name) != 0) {
                if (errno() == @intFromEnum(c.E.INTR)) continue;
                if (errno() == @intFromEnum(c.E.NOENT)) break;
                owned.close() catch {};
                return error.DescriptorFailed;
            }
            break;
        }
        if (owned.value < 0) return error.DescriptorFailed;
        errdefer owned.close() catch {};
        if (c.fcntl(owned.value, c.F.SETFD, @as(c_int, c.FD_CLOEXEC)) != 0) return error.DescriptorFailed;
        if (c.ftruncate(owned.value, @as(c.off_t, @intCast(size))) != 0) return error.DescriptorFailed;
        return .{ .fd = owned, .mapping = try Mapping.init(owned.value, .{ .offset = 0, .length = size, .used = size }, true, maximum) };
    }
    pub fn close(self: *Region) !void {
        var failed = false;
        self.mapping.close() catch {
            failed = true;
        };
        self.fd.close() catch {
            failed = true;
        };
        if (failed) return error.DescriptorFailed;
    }
};

test "shared regions duplicate descriptors close on exec and share unaligned mapped bytes" {
    const t = std.testing;
    var region = try Region.create(8193, 16384);
    defer region.close() catch unreachable;
    @memset(region.mapping.bytes, 73);
    try t.expect(try extent(region.fd.value) >= 8193);
    var duplicate = try Fd.duplicate(region.fd.value);
    defer duplicate.close() catch unreachable;
    try t.expect(c.fcntl(duplicate.value, c.F.GETFD) & c.FD_CLOEXEC != 0);
    try t.expect(c.fcntl(region.fd.value, c.F.GETFD) & c.FD_CLOEXEC != 0);
    var view = try Mapping.init(duplicate.value, .{ .offset = 4095, .length = 4098, .used = 4098 }, true, 16384);
    defer view.close() catch unreachable;
    try t.expectEqual(@as(u8, 73), view.bytes[4097]);
    view.bytes[0] = 19;
    try t.expectEqual(@as(u8, 19), region.mapping.bytes[4095]);
    try region.fd.close();
    try t.expectEqual(@as(u8, 19), view.bytes[0]);
}
test "shared mappings preflight invalid extents bounds and descriptors without mutation" {
    const t = std.testing;
    var region = try Region.create(32, 64);
    defer region.close() catch unreachable;
    @memset(region.mapping.bytes, 73);
    try t.expectError(error.InvalidSpan, Region.create(0, 64));
    try t.expectError(error.InvalidSpan, Region.create(65, 64));
    const actual_extent = try extent(region.fd.value);
    try t.expectError(error.InvalidSpan, Mapping.init(region.fd.value, .{ .offset = actual_extent - 1, .length = 2, .used = 2 }, true, 64));
    try t.expectError(error.InvalidSpan, Mapping.init(region.fd.value, .{ .offset = std.math.maxInt(u64), .length = 1, .used = 1 }, true, 64));
    try t.expectError(error.InvalidSpan, Mapping.init(region.fd.value, .{ .offset = 0, .length = 1, .used = 2 }, true, 64));
    try t.expectError(error.InvalidDescriptor, Fd.duplicate(-1));
    for (region.mapping.bytes) |v| try t.expectEqual(@as(u8, 73), v);
}

test "failed unmap retains the exact owned mapping and retry retires it once" {
    const t = std.testing;
    var region = try Region.create(8193, 16384);
    defer region.close() catch unreachable;
    const before = region.mapping;
    const Unmap = struct {
        var calls: usize = 0;
        fn fail(_: anytype, _: usize) c_int {
            calls += 1;
            return -1;
        }
        fn succeed(base: anytype, size: usize) c_int {
            calls += 1;
            return c.munmap(base, size);
        }
    };
    Unmap.calls = 0;
    try t.expectError(error.MappingFailed, region.mapping.closeUsing(Unmap.fail));
    try t.expectEqual(before.base, region.mapping.base);
    try t.expectEqual(before.size, region.mapping.size);
    try t.expectEqual(before.bytes.ptr, region.mapping.bytes.ptr);
    try t.expectEqual(before.bytes.len, region.mapping.bytes.len);
    // A live region can still close its descriptor while retaining the mapping.
    // A later unmap retry must not need or close the old descriptor number.
    try region.fd.close();
    region.mapping.bytes[8192] = 91;
    try region.mapping.closeUsing(Unmap.succeed);
    try t.expectEqual(@as(usize, 2), Unmap.calls);
    try t.expect(region.mapping.base == null);
    try t.expectEqual(@as(usize, 0), region.mapping.size);
    try t.expectEqual(@as(usize, 0), region.mapping.bytes.len);
    try region.mapping.closeUsing(Unmap.succeed);
    try t.expectEqual(@as(usize, 2), Unmap.calls);
}
