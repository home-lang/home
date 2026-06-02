// Copied from bun/src/sql/postgres/protocol/FieldMessage.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../../cli/LICENSE.bun.md.
//
// Postgres backend-message field record — a tagged union over the
// FieldType enum carrying each `T<value>` pair in an ErrorResponse /
// NoticeResponse body. Upstream uses `bun.String` (WTF-String backing)
// for `String.cloneUTF8` / `.deref()` / `.format`. Home substrate has
// no WTF-String today, so we substitute a heap-owned `[]u8` slice +
// matching `cloneUTF8` / `deref` helpers — the public API
// (`init(tag, []const u8)`, `deinit`, `decodeList`, `format`) keeps the
// same shape so call sites (ErrorResponse, NoticeResponse) don't
// branch on substrate. The `home_rt.default_allocator` indirection
// is the standard `@import("bun")` → `home_rt` rewrite.

pub const FieldMessage = union(FieldType) {
    severity: String,
    localized_severity: String,
    code: String,
    message: String,
    detail: String,
    hint: String,
    position: String,
    internal_position: String,
    internal: String,
    where: String,
    schema: String,
    table: String,
    column: String,
    datatype: String,
    constraint: String,
    file: String,
    line: String,
    routine: String,

    /// Stand-in for `bun.String`. The real type carries a WTF-String
    /// (length-prefixed UTF-16 / Latin-1 SSO container). Until that
    /// substrate ports, we hold a heap-owned UTF-8 byte slice. `slice()`
    /// returns the bytes; `deref()` frees through the default allocator.
    pub const String = struct {
        bytes: []u8 = &.{},

        pub fn cloneUTF8(text: []const u8) String {
            const copy = home_rt.default_allocator.alloc(u8, text.len) catch
                return .{};
            @memcpy(copy, text);
            return .{ .bytes = copy };
        }

        pub fn slice(this: String) []const u8 {
            return this.bytes;
        }

        pub fn deref(this: *String) void {
            if (this.bytes.len > 0) {
                home_rt.default_allocator.free(this.bytes);
                this.bytes = &.{};
            }
        }

        pub fn format(this: String, writer: *std.Io.Writer) !void {
            try writer.writeAll(this.bytes);
        }
    };

    pub fn format(this: FieldMessage, writer: *std.Io.Writer) !void {
        switch (this) {
            inline else => |str| {
                try writer.print("{f}", .{str});
            },
        }
    }

    pub fn deinit(this: *FieldMessage) void {
        switch (this.*) {
            inline else => |*message| {
                message.deref();
            },
        }
    }

    pub fn decodeList(comptime Context: type, reader: anytype) !std.ArrayListUnmanaged(FieldMessage) {
        var messages = std.ArrayListUnmanaged(FieldMessage){};
        _ = Context;
        while (true) {
            const field_int = try reader.int(u8);
            if (field_int == 0) break;
            const field: FieldType = @enumFromInt(field_int);

            var message = try reader.readZ();
            defer message.deinit();
            if (message.slice().len == 0) break;

            try messages.append(home_rt.default_allocator, FieldMessage.init(field, message.slice()) catch continue);
        }

        return messages;
    }

    pub fn init(tag: FieldType, message: []const u8) !FieldMessage {
        return switch (tag) {
            .severity => FieldMessage{ .severity = String.cloneUTF8(message) },
            .code => FieldMessage{ .code = String.cloneUTF8(message) },
            .message => FieldMessage{ .message = String.cloneUTF8(message) },
            .detail => FieldMessage{ .detail = String.cloneUTF8(message) },
            .hint => FieldMessage{ .hint = String.cloneUTF8(message) },
            .position => FieldMessage{ .position = String.cloneUTF8(message) },
            .internal_position => FieldMessage{ .internal_position = String.cloneUTF8(message) },
            .internal => FieldMessage{ .internal = String.cloneUTF8(message) },
            .where => FieldMessage{ .where = String.cloneUTF8(message) },
            .schema => FieldMessage{ .schema = String.cloneUTF8(message) },
            .table => FieldMessage{ .table = String.cloneUTF8(message) },
            .column => FieldMessage{ .column = String.cloneUTF8(message) },
            .datatype => FieldMessage{ .datatype = String.cloneUTF8(message) },
            .constraint => FieldMessage{ .constraint = String.cloneUTF8(message) },
            .file => FieldMessage{ .file = String.cloneUTF8(message) },
            .line => FieldMessage{ .line = String.cloneUTF8(message) },
            .routine => FieldMessage{ .routine = String.cloneUTF8(message) },
            else => error.UnknownFieldType,
        };
    }
};

test "FieldMessage.init wraps severity into the .severity variant" {
    var msg = try FieldMessage.init(.severity, "ERROR");
    defer msg.deinit();
    try std.testing.expectEqualStrings("ERROR", msg.severity.slice());
}

test "FieldMessage.init returns UnknownFieldType for unmapped tags" {
    try std.testing.expectError(error.UnknownFieldType, FieldMessage.init(.localized_severity, "x"));
}

const std = @import("std");
const home_rt = @import("home");
const FieldType = @import("./FieldType.zig").FieldType;
