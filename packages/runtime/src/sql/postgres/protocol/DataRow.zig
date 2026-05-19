// Copied verbatim from bun/src/sql/postgres/protocol/DataRow.zig at
// upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see
// ../../../cli/LICENSE.bun.md. No `@import("bun")` references.
//
// Postgres DataRow ('D') row-iterator helper. `decode` is a free
// function (not a packet struct) that walks columns, invoking the
// caller-supplied `forEach` per field. Wire body reaches into the
// wave-16 NewReader stub method surface (reader.length, reader.short,
// reader.int4, reader.bytes); those trip a natural compile error if
// exercised today.

pub fn decode(context: anytype, comptime ContextType: type, reader: NewReader(ContextType), comptime forEach: fn (@TypeOf(context), index: u32, bytes: ?*Data) AnyPostgresError!bool) AnyPostgresError!void {
    var remaining_bytes = try reader.length();
    remaining_bytes -|= 4;

    const remaining_fields: usize = @intCast(@max(try reader.short(), 0));

    for (0..remaining_fields) |index| {
        const byte_length = try reader.int4();
        switch (byte_length) {
            0 => {
                var empty = Data.Empty;
                if (!try forEach(context, @intCast(index), &empty)) break;
            },
            null_int4 => {
                if (!try forEach(context, @intCast(index), null)) break;
            },
            else => {
                var bytes = try reader.bytes(@intCast(byte_length));
                if (!try forEach(context, @intCast(index), &bytes)) break;
            },
        }
    }
}

pub const null_int4 = 4294967295;

test "DataRow.null_int4 is the canonical Postgres NULL sentinel" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), null_int4);
}

const Data = @import("../../shared/Data.zig").Data;

const AnyPostgresError = @import("../AnyPostgresError.zig").AnyPostgresError;

const NewReader = @import("./NewReader.zig").NewReader;
