// Copied from bun/src/sql/mysql/protocol/AuthSwitchResponse.zig at
// upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see
// ../../../cli/LICENSE.bun.md.
//
// MySQL auth-switch response packet — client → server reply that
// carries the auth-method-specific response bytes after a server-side
// auth switch (`AuthSwitchRequest`, header 0xfe). No `@import("bun")`
// references upstream.

const AuthSwitchResponse = @This();
auth_response: Data = .{ .empty = {} },

pub fn deinit(this: *AuthSwitchResponse) void {
    this.auth_response.deinit();
}

pub fn writeInternal(this: *const AuthSwitchResponse, comptime Context: type, writer: NewWriter(Context)) !void {
    try writer.write(this.auth_response.slice());
}

pub const write = writeWrap(AuthSwitchResponse, writeInternal).write;

test "AuthSwitchResponse defaults to an empty auth_response" {
    var r: AuthSwitchResponse = .{};
    defer r.deinit();
    try std.testing.expectEqualStrings("", r.auth_response.slice());
}

test "AuthSwitchResponse writes auth payload bytes" {
    var buf: [8]u8 = undefined;
    var len: usize = 0;
    const ctx = TestWriter.init(&buf, &len);
    const writer = NewWriter(TestWriter){ .wrapped = ctx };
    const response: AuthSwitchResponse = .{ .auth_response = .{ .temporary = "ok" } };

    try response.writeInternal(TestWriter, writer);

    try std.testing.expectEqualSlices(u8, "ok", ctx.slice());
}

const Data = @import("../../shared/Data.zig").Data;
const std = @import("std");
const AnyMySQLError = @import("./AnyMySQLError.zig");

const NewWriter = @import("./NewWriter.zig").NewWriter;
const writeWrap = @import("./NewWriter.zig").writeWrap;

const TestWriter = struct {
    bytes: []u8,
    len: *usize,

    fn init(bytes: []u8, len: *usize) TestWriter {
        len.* = 0;
        return .{ .bytes = bytes, .len = len };
    }

    fn slice(this: TestWriter) []const u8 {
        return this.bytes[0..this.len.*];
    }

    pub fn offset(this: TestWriter) usize {
        return this.len.*;
    }

    pub fn write(this: TestWriter, bytes: []const u8) AnyMySQLError.Error!void {
        if (this.len.* + bytes.len > this.bytes.len) return error.ShortRead;
        @memcpy(this.bytes[this.len.*..][0..bytes.len], bytes);
        this.len.* += bytes.len;
    }

    pub fn pwrite(this: TestWriter, bytes: []const u8, offset_value: usize) AnyMySQLError.Error!void {
        if (offset_value + bytes.len > this.len.*) return error.ShortRead;
        @memcpy(this.bytes[offset_value..][0..bytes.len], bytes);
    }
};
