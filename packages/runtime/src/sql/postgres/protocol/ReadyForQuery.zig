// Copied from bun/src/sql/postgres/protocol/ReadyForQuery.zig at
// upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see
// ../../../cli/LICENSE.bun.md.
//
// Imports rewritten: `@import("bun")` dropped — upstream body's only
// reference is `bun.assert(length >= 4)` which lowers to `std.debug.assert`.
// `TransactionStatusIndicator` was already ported (wave-15 / wave-16) so
// the dependency graph is fully in-tree.

const ReadyForQuery = @This();

status: TransactionStatusIndicator = .I,

pub fn decodeInternal(this: *@This(), comptime Container: type, reader: NewReader(Container)) !void {
    const length = try reader.length();
    std.debug.assert(length >= 4);

    const status = try reader.int(u8);
    this.* = .{
        .status = @enumFromInt(status),
    };
}

pub const decode = DecoderWrap(ReadyForQuery, decodeInternal).decode;

test "ReadyForQuery defaults to .I (idle)" {
    const std_local = @import("std");
    const r: ReadyForQuery = .{};
    try std_local.testing.expectEqual(TransactionStatusIndicator.I, r.status);
}

const std = @import("std");
const DecoderWrap = @import("./DecoderWrap.zig").DecoderWrap;
const NewReader = @import("./NewReader.zig").NewReader;
const TransactionStatusIndicator = @import("./TransactionStatusIndicator.zig").TransactionStatusIndicator;
