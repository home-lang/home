// Copied from bun/src/sql/postgres/protocol/RowDescription.zig at
// upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see
// ../../../cli/LICENSE.bun.md.
//
// Postgres RowDescription ('T') backend packet — top-level wrapper
// around a heap-allocated slice of `FieldDescription`. Imports
// rewritten: `@import("bun")` → `@import("home_rt")` (only used for
// `default_allocator`). Decoder body delegates each field record to
// `FieldDescription.decodeInternal`, which trips the wave-16 NewReader
// stub method surface if exercised today.

const RowDescription = @This();

fields: []FieldDescription = &[_]FieldDescription{},
pub fn deinit(this: *@This()) void {
    for (this.fields) |*field| {
        field.deinit();
    }

    home_rt.default_allocator.free(this.fields);
}

pub fn decodeInternal(this: *@This(), comptime Container: type, reader: NewReader(Container)) !void {
    var remaining_bytes = try reader.length();
    remaining_bytes -|= 4;

    const field_count: usize = @intCast(@max(try reader.short(), 0));
    var fields = try home_rt.default_allocator.alloc(
        FieldDescription,
        field_count,
    );
    var remaining = fields;
    errdefer {
        for (fields[0 .. field_count - remaining.len]) |*field| {
            field.deinit();
        }

        home_rt.default_allocator.free(fields);
    }
    while (remaining.len > 0) {
        try remaining[0].decodeInternal(Container, reader);
        remaining = remaining[1..];
    }
    this.* = .{
        .fields = fields,
    };
}

pub const decode = DecoderWrap(RowDescription, decodeInternal).decode;

test "RowDescription defaults to an empty fields slice" {
    const std_local = @import("std");
    const rd: RowDescription = .{};
    try std_local.testing.expectEqual(@as(usize, 0), rd.fields.len);
}

test "RowDescription deinit of an empty slice is a no-op" {
    var rd: RowDescription = .{};
    rd.deinit();
}

const FieldDescription = @import("./FieldDescription.zig");
const home_rt = @import("home_rt");
const DecoderWrap = @import("./DecoderWrap.zig").DecoderWrap;
const NewReader = @import("./NewReader.zig").NewReader;
