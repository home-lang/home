//! Reentrant native effective-account lookup; serialized strings retain raw bytes.
const std = @import("std");
const builtin = @import("builtin");

pub const Account = struct {
    uid: std.c.uid_t,
    gid: std.c.gid_t,
    username: []u8,
    homedir: []u8,
    shell: []u8,

    pub fn deinit(self: Account, allocator: std.mem.Allocator) void {
        allocator.free(self.username);
        allocator.free(self.homedir);
        allocator.free(self.shell);
    }
};

fn hex(allocator: std.mem.Allocator, value: [*:0]const u8) ![]u8 {
    const bytes = std.mem.sliceTo(value, 0);
    const encoded = try allocator.alloc(u8, bytes.len * 2);
    const digits = "0123456789abcdef";
    for (bytes, 0..) |byte, index| {
        encoded[index * 2] = digits[byte >> 4];
        encoded[index * 2 + 1] = digits[byte & 15];
    }
    return encoded;
}

pub fn read(allocator: std.mem.Allocator) !Account {
    if (comptime builtin.os.tag == .macos or builtin.os.tag == .linux) {
        var size: usize = 1024;
        while (size <= 1024 * 1024) : (size *= 2) {
            const buffer = try allocator.alloc(u8, size);
            defer allocator.free(buffer);
            var account: std.c.passwd = undefined;
            var result: ?*std.c.passwd = null;
            // Node os.userInfo uses the effective account, never HOME/USER.
            // getpwuid_r keeps concurrent calls out of libc's shared storage.
            const code = std.c.getpwuid_r(std.c.geteuid(), &account, buffer.ptr, buffer.len, &result);
            if (code == @backingInt(std.c.E.RANGE)) continue;
            if (code != 0 or result == null) return error.AccountLookupFailed;
            const username = try hex(allocator, account.name orelse return error.AccountLookupFailed);
            errdefer allocator.free(username);
            const homedir = try hex(allocator, account.dir orelse return error.AccountLookupFailed);
            errdefer allocator.free(homedir);
            const shell = try hex(allocator, account.shell orelse return error.AccountLookupFailed);
            return .{ .uid = account.uid, .gid = account.gid, .username = username, .homedir = homedir, .shell = shell };
        }
        return error.AccountLookupTooLarge;
    }
    return error.UnsupportedPlatform;
}
