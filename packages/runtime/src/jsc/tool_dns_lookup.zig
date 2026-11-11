//! Owned, bounded system getaddrinfo results. No JS or process-global state.
const std = @import("std");
const builtin = @import("builtin");

pub const Record = struct { address: []const u8, family: u8 };
pub const Failure = struct { code: []const u8, errno: i32, native_code: c_int };
pub const Result = struct {
    records: std.ArrayList(Record) = .empty,
    failure: ?Failure = null,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        for (self.records.items) |record| allocator.free(record.address);
        self.records.deinit(allocator);
    }
};

pub fn hintsMask() u32 {
    if (comptime builtin.os.tag != .macos and builtin.os.tag != .linux) return 0;
    return @bitCast(std.c.AI{ .ADDRCONFIG = true, .V4MAPPED = true, .ALL = true });
}

fn failure(code: std.c.EAI) Failure {
    // Stable libuv EAI numbers are part of Node's observable error contract;
    // native_code also retains the actual, platform-specific libc result.
    const name, const number: i32 = switch (code) {
        .ADDRFAMILY => .{ "EAI_ADDRFAMILY", -3000 },
        .AGAIN => .{ "EAI_AGAIN", -3001 },
        .BADFLAGS => .{ "EAI_BADFLAGS", -3002 },
        .FAIL => .{ "EAI_FAIL", -3004 },
        .FAMILY => .{ "EAI_FAMILY", -3005 },
        .MEMORY => .{ "EAI_MEMORY", -3006 },
        .NODATA => .{ "ENOTFOUND", -3007 },
        .NONAME => .{ "ENOTFOUND", -3008 },
        .OVERFLOW => .{ "EAI_OVERFLOW", -3009 },
        .SERVICE => .{ "EAI_SERVICE", -3010 },
        .SOCKTYPE => .{ "EAI_SOCKTYPE", -3011 },
        .SYSTEM => .{ "EAI_SYSTEM", -std.c._errno().* },
        else => .{ "EAI_UNKNOWN", -4094 },
    };
    return .{ .code = name, .errno = number, .native_code = @backingInt(code) };
}

pub fn lookup(allocator: std.mem.Allocator, hostname: []const u8, family: u8, flags: u32) !Result {
    if (comptime builtin.os.tag != .macos and builtin.os.tag != .linux) return error.UnsupportedPlatform;
    if (hostname.len == 0 or hostname.len > 1024 or std.mem.indexOfScalar(u8, hostname, 0) != null or
        (family != 0 and family != 4 and family != 6) or flags & ~hintsMask() != 0) return error.InvalidLookupArguments;
    const name = try allocator.dupeSentinel(u8, hostname, 0);
    defer allocator.free(name);
    var hints = std.mem.zeroes(std.c.addrinfo);
    hints.family = switch (family) {
        4 => std.c.AF.INET,
        6 => std.c.AF.INET6,
        else => std.c.AF.UNSPEC,
    };
    hints.socktype = std.c.SOCK.STREAM;
    hints.flags = @bitCast(flags);
    var head: ?*std.c.addrinfo = null;
    const code = std.c.getaddrinfo(name, null, &hints, &head);
    // On failure Linux need not initialize head. Never free an uninitialized
    // result or substitute a successful empty list for a resolver failure.
    if (@backingInt(code) != 0) return .{ .failure = failure(code) };
    defer if (head) |list| std.c.freeaddrinfo(list);
    var result: Result = .{};
    errdefer result.deinit(allocator);
    var current = head;
    var visited: usize = 0;
    while (current) |node| : (current = node.next) {
        visited += 1;
        if (visited > 4096) return error.LookupRecordLimit;
        if (node.family != std.c.AF.INET and node.family != std.c.AF.INET6) continue;
        var address: [1025]u8 = undefined;
        const numeric = std.c.getnameinfo(node.addr orelse return error.InvalidNativeAddress, node.addrlen, &address, address.len, null, 0, .{ .NUMERICHOST = true });
        if (@backingInt(numeric) != 0) {
            result.deinit(allocator);
            return .{ .failure = failure(numeric) };
        }
        const text = std.mem.sliceTo(&address, 0);
        const version: u8 = if (node.family == std.c.AF.INET) 4 else 6;
        var duplicate = false;
        for (result.records.items) |record| {
            if (record.family == version and std.mem.eql(u8, record.address, text)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) continue;
        const copy = try allocator.dupe(u8, text);
        errdefer allocator.free(copy);
        try result.records.append(allocator, .{ .address = copy, .family = version });
    }
    if (result.records.items.len == 0) result.failure = failure(.NONAME);
    return result;
}

test "system lookup owns numeric IPv4 and IPv6 results" {
    const allocator = std.testing.allocator;
    inline for (.{ .{ "192.0.2.1", @as(u8, 4) }, .{ "2001:db8::1", @as(u8, 6) } }) |entry| {
        var result = try lookup(allocator, entry[0], entry[1], 0);
        defer result.deinit(allocator);
        try std.testing.expect(result.failure == null);
        try std.testing.expectEqual(@as(usize, 1), result.records.items.len);
        try std.testing.expectEqualStrings(entry[0], result.records.items[0].address);
        try std.testing.expectEqual(entry[1], result.records.items[0].family);
    }
}

test "system lookup refuses ambiguous input and unsupported flags" {
    try std.testing.expectError(error.InvalidLookupArguments, lookup(std.testing.allocator, "localhost\x00tail", 0, 0));
    try std.testing.expectError(error.InvalidLookupArguments, lookup(std.testing.allocator, "localhost", 7, 0));
    try std.testing.expectError(error.InvalidLookupArguments, lookup(std.testing.allocator, "localhost", 0, ~hintsMask()));
}
