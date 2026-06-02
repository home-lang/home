// Copied from bun/src/sql/mysql/protocol/ColumnDefinition41.zig at
// upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see
// ../../../cli/LICENSE.bun.md.
//
// MySQL ColumnDefinition41 — per-column metadata record nested inside a
// ResultSet response. Carries catalog / schema / table / org_table /
// name / org_name (length-encoded strings) plus the wire FieldType
// + ColumnFlags packed mask. `decodeInternal` reads the column,
// converts the name into a `ColumnIdentifier` (parsing decimal indices
// for JSC indexed-property fast-path), then skips the trailing 2-byte
// extension that MariaDB adds.
//
// Reaches into wave-21 NewReader stub methods (encodeLenString /
// encodedLenInt / int / skip) — exercising decode() trips a natural
// compile error until the real reader lands (Phase 12.2).

const ColumnDefinition41 = @This();
catalog: Data = .{ .empty = {} },
schema: Data = .{ .empty = {} },
table: Data = .{ .empty = {} },
org_table: Data = .{ .empty = {} },
name: Data = .{ .empty = {} },
org_name: Data = .{ .empty = {} },
fixed_length_fields_length: u64 = 0,
character_set: u16 = 0,
column_length: u32 = 0,
column_type: types.FieldType = .MYSQL_TYPE_NULL,
flags: ColumnFlags = .{},
decimals: u8 = 0,
name_or_index: ColumnIdentifier = .{
    .name = .{ .empty = {} },
},

pub const ColumnFlags = packed struct {
    NOT_NULL: bool = false,
    PRI_KEY: bool = false,
    UNIQUE_KEY: bool = false,
    MULTIPLE_KEY: bool = false,
    BLOB: bool = false,
    UNSIGNED: bool = false,
    ZEROFILL: bool = false,
    BINARY: bool = false,
    ENUM: bool = false,
    AUTO_INCREMENT: bool = false,
    TIMESTAMP: bool = false,
    SET: bool = false,
    NO_DEFAULT_VALUE: bool = false,
    ON_UPDATE_NOW: bool = false,
    _padding: u2 = 0,

    pub fn toInt(this: ColumnFlags) u16 {
        return @bitCast(this);
    }

    pub fn fromInt(flags: u16) ColumnFlags {
        return @bitCast(flags);
    }
};

pub fn deinit(this: *ColumnDefinition41) void {
    this.catalog.deinit();
    this.schema.deinit();
    this.table.deinit();
    this.org_table.deinit();
    this.name.deinit();
    this.org_name.deinit();
    this.name_or_index.deinit();
}

pub fn decodeInternal(this: *ColumnDefinition41, comptime Context: type, reader: NewReader(Context)) !void {
    // Length encoded strings
    this.catalog = try reader.encodeLenString();
    debug("catalog: {s}", .{this.catalog.slice()});

    this.schema = try reader.encodeLenString();
    debug("schema: {s}", .{this.schema.slice()});

    this.table = try reader.encodeLenString();
    debug("table: {s}", .{this.table.slice()});

    this.org_table = try reader.encodeLenString();
    debug("org_table: {s}", .{this.org_table.slice()});

    this.name = try reader.encodeLenString();
    debug("name: {s}", .{this.name.slice()});

    this.org_name = try reader.encodeLenString();
    debug("org_name: {s}", .{this.org_name.slice()});

    this.fixed_length_fields_length = try reader.encodedLenInt();
    this.character_set = try reader.int(u16);
    this.column_length = try reader.int(u32);
    this.column_type = @enumFromInt(try reader.int(u8));
    this.flags = ColumnFlags.fromInt(try reader.int(u16));
    this.decimals = try reader.int(u8);

    this.name_or_index.deinit();
    this.name_or_index = try ColumnIdentifier.init(this.name);

    // https://mariadb.com/kb/en/result-set-packets/#column-definition-packet
    // According to mariadb, there seem to be extra 2 bytes at the end that is not being used
    reader.skip(2);
}

pub const decode = decoderWrap(ColumnDefinition41, decodeInternal).decode;

test "ColumnFlags packs to 2 bytes and round-trips" {
    const std = @import("std");
    const fl: ColumnFlags = .{ .NOT_NULL = true, .PRI_KEY = true, .AUTO_INCREMENT = true };
    const packed_int = fl.toInt();
    const round = ColumnFlags.fromInt(packed_int);
    try std.testing.expect(round.NOT_NULL);
    try std.testing.expect(round.PRI_KEY);
    try std.testing.expect(round.AUTO_INCREMENT);
    try std.testing.expect(!round.UNIQUE_KEY);
}

test "ColumnDefinition41 defaults to MYSQL_TYPE_NULL with empty name" {
    const std = @import("std");
    var cd: ColumnDefinition41 = .{};
    defer cd.deinit();
    try std.testing.expectEqual(types.FieldType.MYSQL_TYPE_NULL, cd.column_type);
    try std.testing.expectEqualStrings("", cd.name.slice());
    try std.testing.expect(cd.name_or_index == .name);
}

const debug = home_rt.Output.scoped(.ColumnDefinition41, .hidden);

const home_rt = @import("home");
const types = @import("../MySQLTypes.zig");
const ColumnIdentifier = @import("../../shared/ColumnIdentifier.zig").ColumnIdentifier;
const Data = @import("../../shared/Data.zig").Data;

const NewReader = @import("./NewReader.zig").NewReader;
const decoderWrap = @import("./NewReader.zig").decoderWrap;
