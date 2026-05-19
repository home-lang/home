// Copied from bun/src/sql/mysql/protocol/AuthSwitchResponse.zig at
// upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see
// ../../../cli/LICENSE.bun.md.
//
// MySQL auth-switch response packet — client → server reply that
// carries the auth-method-specific response bytes after a server-side
// auth switch (`AuthSwitchRequest`, header 0xfe). No `@import("bun")`
// references upstream. The writer body reaches into the wave-22
// `NewWriter.write(...)` stub method which trips a natural compile
// error until the real writer lands (Phase 12.2).

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
    const std = @import("std");
    var r: AuthSwitchResponse = .{};
    defer r.deinit();
    try std.testing.expectEqualStrings("", r.auth_response.slice());
}

const Data = @import("../../shared/Data.zig").Data;

const NewWriter = @import("./NewWriter.zig").NewWriter;
const writeWrap = @import("./NewWriter.zig").writeWrap;
