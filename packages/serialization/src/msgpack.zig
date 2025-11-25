const std = @import("std");

/// MessagePack serialization and deserialization
///
/// Features:
/// - Compact binary format
/// - Type preservation
/// - Schema-less
/// - Forward/backward compatible
/// - Extension types
pub const MessagePack = struct {
    allocator: std.mem.Allocator,

    pub const Value = union(enum) {
        nil,
        boolean: bool,
        integer: i64,
        unsigned: u64,
        float: f64,
        string: []const u8,
        binary: []const u8,
        array: []Value,
        map: std.StringHashMap(Value),
        extension: Extension,

        pub const Extension = struct {
            type: i8,
            data: []const u8,
        };

        pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
            switch (self.*) {
                .string => |s| allocator.free(s),
                .binary => |b| allocator.free(b),
                .array => |arr| {
                    for (arr) |*item| {
                        item.deinit(allocator);
                    }
                    allocator.free(arr);
                },
                .map => |*m| {
                    var it = m.iterator();
                    while (it.next()) |entry| {
                        allocator.free(entry.key_ptr.*);
                        entry.value_ptr.deinit(allocator);
                    }
                    m.deinit();
                },
                .extension => |ext| allocator.free(ext.data),
                else => {},
            }
        }
    };

    // Format constants
    const POSITIVE_FIXINT_MAX: u8 = 0x7f;
    const FIXMAP_PREFIX: u8 = 0x80;
    const FIXARRAY_PREFIX: u8 = 0x90;
    const FIXSTR_PREFIX: u8 = 0xa0;
    const NIL: u8 = 0xc0;
    const FALSE: u8 = 0xc2;
    const TRUE: u8 = 0xc3;
    const BIN8: u8 = 0xc4;
    const BIN16: u8 = 0xc5;
    const BIN32: u8 = 0xc6;
    const EXT8: u8 = 0xc7;
    const EXT16: u8 = 0xc8;
    const EXT32: u8 = 0xc9;
    const FLOAT32: u8 = 0xca;
    const FLOAT64: u8 = 0xcb;
    const UINT8: u8 = 0xcc;
    const UINT16: u8 = 0xcd;
    const UINT32: u8 = 0xce;
    const UINT64: u8 = 0xcf;
    const INT8: u8 = 0xd0;
    const INT16: u8 = 0xd1;
    const INT32: u8 = 0xd2;
    const INT64: u8 = 0xd3;
    const FIXEXT1: u8 = 0xd4;
    const FIXEXT2: u8 = 0xd5;
    const FIXEXT4: u8 = 0xd6;
    const FIXEXT8: u8 = 0xd7;
    const FIXEXT16: u8 = 0xd8;
    const STR8: u8 = 0xd9;
    const STR16: u8 = 0xda;
    const STR32: u8 = 0xdb;
    const ARRAY16: u8 = 0xdc;
    const ARRAY32: u8 = 0xdd;
    const MAP16: u8 = 0xde;
    const MAP32: u8 = 0xdf;
    const NEGATIVE_FIXINT_MIN: u8 = 0xe0;

    pub fn init(allocator: std.mem.Allocator) MessagePack {
        return .{ .allocator = allocator };
    }

    /// Serialize a value to MessagePack format
    pub fn serialize(self: *MessagePack, value: Value) ![]u8 {
        var buffer = std.ArrayList(u8).init(self.allocator);
        errdefer buffer.deinit();

        try self.encodeValue(buffer.writer(), value);

        return buffer.toOwnedSlice();
    }

    /// Deserialize MessagePack data
    pub fn deserialize(self: *MessagePack, data: []const u8) !Value {
        var stream = std.io.fixedBufferStream(data);
        return try self.decodeValue(stream.reader());
    }

    fn encodeValue(self: *MessagePack, writer: anytype, value: Value) !void {
        switch (value) {
            .nil => try writer.writeByte(NIL),
            .boolean => |b| try writer.writeByte(if (b) TRUE else FALSE),
            .integer => |i| try self.encodeInteger(writer, i),
            .unsigned => |u| try self.encodeUnsigned(writer, u),
            .float => |f| try self.encodeFloat(writer, f),
            .string => |s| try self.encodeString(writer, s),
            .binary => |b| try self.encodeBinary(writer, b),
            .array => |arr| try self.encodeArray(writer, arr),
            .map => |m| try self.encodeMap(writer, m),
            .extension => |ext| try self.encodeExtension(writer, ext),
        }
    }

    fn encodeInteger(self: *MessagePack, writer: anytype, value: i64) !void {
        _ = self;

        if (value >= 0) {
            return self.encodeUnsigned(writer, @intCast(value));
        }

        if (value >= -32) {
            // negative fixint
            try writer.writeByte(@bitCast(@as(i8, @intCast(value))));
        } else if (value >= std.math.minInt(i8)) {
            try writer.writeByte(INT8);
            try writer.writeByte(@bitCast(@as(i8, @intCast(value))));
        } else if (value >= std.math.minInt(i16)) {
            try writer.writeByte(INT16);
            try writer.writeInt(i16, @intCast(value), .big);
        } else if (value >= std.math.minInt(i32)) {
            try writer.writeByte(INT32);
            try writer.writeInt(i32, @intCast(value), .big);
        } else {
            try writer.writeByte(INT64);
            try writer.writeInt(i64, value, .big);
        }
    }

    fn encodeUnsigned(self: *MessagePack, writer: anytype, value: u64) !void {
        _ = self;

        if (value <= POSITIVE_FIXINT_MAX) {
            try writer.writeByte(@intCast(value));
        } else if (value <= std.math.maxInt(u8)) {
            try writer.writeByte(UINT8);
            try writer.writeByte(@intCast(value));
        } else if (value <= std.math.maxInt(u16)) {
            try writer.writeByte(UINT16);
            try writer.writeInt(u16, @intCast(value), .big);
        } else if (value <= std.math.maxInt(u32)) {
            try writer.writeByte(UINT32);
            try writer.writeInt(u32, @intCast(value), .big);
        } else {
            try writer.writeByte(UINT64);
            try writer.writeInt(u64, value, .big);
        }
    }

    fn encodeFloat(self: *MessagePack, writer: anytype, value: f64) !void {
        _ = self;

        // Always use float64 for simplicity
        try writer.writeByte(FLOAT64);
        try writer.writeInt(u64, @bitCast(value), .big);
    }

    fn encodeString(self: *MessagePack, writer: anytype, value: []const u8) !void {
        _ = self;

        const len = value.len;

        if (len <= 31) {
            try writer.writeByte(FIXSTR_PREFIX | @as(u8, @intCast(len)));
        } else if (len <= std.math.maxInt(u8)) {
            try writer.writeByte(STR8);
            try writer.writeByte(@intCast(len));
        } else if (len <= std.math.maxInt(u16)) {
            try writer.writeByte(STR16);
            try writer.writeInt(u16, @intCast(len), .big);
        } else {
            try writer.writeByte(STR32);
            try writer.writeInt(u32, @intCast(len), .big);
        }

        try writer.writeAll(value);
    }

    fn encodeBinary(self: *MessagePack, writer: anytype, value: []const u8) !void {
        _ = self;

        const len = value.len;

        if (len <= std.math.maxInt(u8)) {
            try writer.writeByte(BIN8);
            try writer.writeByte(@intCast(len));
        } else if (len <= std.math.maxInt(u16)) {
            try writer.writeByte(BIN16);
            try writer.writeInt(u16, @intCast(len), .big);
        } else {
            try writer.writeByte(BIN32);
            try writer.writeInt(u32, @intCast(len), .big);
        }

        try writer.writeAll(value);
    }

    fn encodeArray(self: *MessagePack, writer: anytype, array: []Value) !void {
        const len = array.len;

        if (len <= 15) {
            try writer.writeByte(FIXARRAY_PREFIX | @as(u8, @intCast(len)));
        } else if (len <= std.math.maxInt(u16)) {
            try writer.writeByte(ARRAY16);
            try writer.writeInt(u16, @intCast(len), .big);
        } else {
            try writer.writeByte(ARRAY32);
            try writer.writeInt(u32, @intCast(len), .big);
        }

        for (array) |item| {
            try self.encodeValue(writer, item);
        }
    }

    fn encodeMap(self: *MessagePack, writer: anytype, map: std.StringHashMap(Value)) !void {
        const len = map.count();

        if (len <= 15) {
            try writer.writeByte(FIXMAP_PREFIX | @as(u8, @intCast(len)));
        } else if (len <= std.math.maxInt(u16)) {
            try writer.writeByte(MAP16);
            try writer.writeInt(u16, @intCast(len), .big);
        } else {
            try writer.writeByte(MAP32);
            try writer.writeInt(u32, @intCast(len), .big);
        }

        var it = map.iterator();
        while (it.next()) |entry| {
            try self.encodeString(writer, entry.key_ptr.*);
            try self.encodeValue(writer, entry.value_ptr.*);
        }
    }

    fn encodeExtension(self: *MessagePack, writer: anytype, ext: Value.Extension) !void {
        _ = self;

        const len = ext.data.len;

        if (len == 1) {
            try writer.writeByte(FIXEXT1);
        } else if (len == 2) {
            try writer.writeByte(FIXEXT2);
        } else if (len == 4) {
            try writer.writeByte(FIXEXT4);
        } else if (len == 8) {
            try writer.writeByte(FIXEXT8);
        } else if (len == 16) {
            try writer.writeByte(FIXEXT16);
        } else if (len <= std.math.maxInt(u8)) {
            try writer.writeByte(EXT8);
            try writer.writeByte(@intCast(len));
        } else if (len <= std.math.maxInt(u16)) {
            try writer.writeByte(EXT16);
            try writer.writeInt(u16, @intCast(len), .big);
        } else {
            try writer.writeByte(EXT32);
            try writer.writeInt(u32, @intCast(len), .big);
        }

        try writer.writeByte(@bitCast(ext.type));
        try writer.writeAll(ext.data);
    }

    fn decodeValue(self: *MessagePack, reader: anytype) !Value {
        const marker = try reader.readByte();

        // Positive fixint
        if (marker <= POSITIVE_FIXINT_MAX) {
            return Value{ .unsigned = marker };
        }

        // Negative fixint
        if (marker >= NEGATIVE_FIXINT_MIN) {
            return Value{ .integer = @as(i8, @bitCast(marker)) };
        }

        // Fixmap
        if (marker >= FIXMAP_PREFIX and marker <= FIXMAP_PREFIX + 15) {
            const len = marker & 0x0f;
            return try self.decodeMap(reader, len);
        }

        // Fixarray
        if (marker >= FIXARRAY_PREFIX and marker <= FIXARRAY_PREFIX + 15) {
            const len = marker & 0x0f;
            return try self.decodeArray(reader, len);
        }

        // Fixstr
        if (marker >= FIXSTR_PREFIX and marker <= FIXSTR_PREFIX + 31) {
            const len = marker & 0x1f;
            return try self.decodeString(reader, len);
        }

        return switch (marker) {
            NIL => Value.nil,
            FALSE => Value{ .boolean = false },
            TRUE => Value{ .boolean = true },

            UINT8 => Value{ .unsigned = try reader.readByte() },
            UINT16 => Value{ .unsigned = try reader.readInt(u16, .big) },
            UINT32 => Value{ .unsigned = try reader.readInt(u32, .big) },
            UINT64 => Value{ .unsigned = try reader.readInt(u64, .big) },

            INT8 => Value{ .integer = try reader.readByte() },
            INT16 => Value{ .integer = try reader.readInt(i16, .big) },
            INT32 => Value{ .integer = try reader.readInt(i32, .big) },
            INT64 => Value{ .integer = try reader.readInt(i64, .big) },

            FLOAT32 => blk: {
                const bits = try reader.readInt(u32, .big);
                break :blk Value{ .float = @floatCast(@as(f32, @bitCast(bits))) };
            },
            FLOAT64 => blk: {
                const bits = try reader.readInt(u64, .big);
                break :blk Value{ .float = @bitCast(bits) };
            },

            STR8 => try self.decodeString(reader, try reader.readByte()),
            STR16 => try self.decodeString(reader, try reader.readInt(u16, .big)),
            STR32 => try self.decodeString(reader, try reader.readInt(u32, .big)),

            BIN8 => try self.decodeBinary(reader, try reader.readByte()),
            BIN16 => try self.decodeBinary(reader, try reader.readInt(u16, .big)),
            BIN32 => try self.decodeBinary(reader, try reader.readInt(u32, .big)),

            ARRAY16 => try self.decodeArray(reader, try reader.readInt(u16, .big)),
            ARRAY32 => try self.decodeArray(reader, try reader.readInt(u32, .big)),

            MAP16 => try self.decodeMap(reader, try reader.readInt(u16, .big)),
            MAP32 => try self.decodeMap(reader, try reader.readInt(u32, .big)),

            FIXEXT1 => try self.decodeExtension(reader, 1),
            FIXEXT2 => try self.decodeExtension(reader, 2),
            FIXEXT4 => try self.decodeExtension(reader, 4),
            FIXEXT8 => try self.decodeExtension(reader, 8),
            FIXEXT16 => try self.decodeExtension(reader, 16),
            EXT8 => try self.decodeExtension(reader, try reader.readByte()),
            EXT16 => try self.decodeExtension(reader, try reader.readInt(u16, .big)),
            EXT32 => try self.decodeExtension(reader, try reader.readInt(u32, .big)),

            else => error.InvalidMessagePackFormat,
        };
    }

    fn decodeString(self: *MessagePack, reader: anytype, len: anytype) !Value {
        const length: usize = @intCast(len);
        const data = try self.allocator.alloc(u8, length);
        errdefer self.allocator.free(data);

        try reader.readNoEof(data);

        return Value{ .string = data };
    }

    fn decodeBinary(self: *MessagePack, reader: anytype, len: anytype) !Value {
        const length: usize = @intCast(len);
        const data = try self.allocator.alloc(u8, length);
        errdefer self.allocator.free(data);

        try reader.readNoEof(data);

        return Value{ .binary = data };
    }

    fn decodeArray(self: *MessagePack, reader: anytype, len: anytype) !Value {
        const length: usize = @intCast(len);
        const array = try self.allocator.alloc(Value, length);
        errdefer self.allocator.free(array);

        for (0..length) |i| {
            array[i] = try self.decodeValue(reader);
        }

        return Value{ .array = array };
    }

    fn decodeMap(self: *MessagePack, reader: anytype, len: anytype) !Value {
        const length: usize = @intCast(len);
        var map = std.StringHashMap(Value).init(self.allocator);
        errdefer map.deinit();

        for (0..length) |_| {
            const key_value = try self.decodeValue(reader);
            const key = switch (key_value) {
                .string => |s| s,
                else => return error.InvalidMapKey,
            };

            const value = try self.decodeValue(reader);
            try map.put(key, value);
        }

        return Value{ .map = map };
    }

    fn decodeExtension(self: *MessagePack, reader: anytype, len: anytype) !Value {
        const ext_type: i8 = @bitCast(try reader.readByte());
        const length: usize = @intCast(len);

        const data = try self.allocator.alloc(u8, length);
        errdefer self.allocator.free(data);

        try reader.readNoEof(data);

        return Value{
            .extension = .{
                .type = ext_type,
                .data = data,
            },
        };
    }
};

/// Helper for building MessagePack values
pub const Builder = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{ .allocator = allocator };
    }

    pub fn nil(self: *Builder) MessagePack.Value {
        _ = self;
        return .nil;
    }

    pub fn boolean(self: *Builder, value: bool) MessagePack.Value {
        _ = self;
        return .{ .boolean = value };
    }

    pub fn integer(self: *Builder, value: i64) MessagePack.Value {
        _ = self;
        return .{ .integer = value };
    }

    pub fn unsigned(self: *Builder, value: u64) MessagePack.Value {
        _ = self;
        return .{ .unsigned = value };
    }

    pub fn float(self: *Builder, value: f64) MessagePack.Value {
        _ = self;
        return .{ .float = value };
    }

    pub fn string(self: *Builder, value: []const u8) !MessagePack.Value {
        return .{ .string = try self.allocator.dupe(u8, value) };
    }

    pub fn binary(self: *Builder, value: []const u8) !MessagePack.Value {
        return .{ .binary = try self.allocator.dupe(u8, value) };
    }

    pub fn array(self: *Builder, values: []const MessagePack.Value) !MessagePack.Value {
        const arr = try self.allocator.alloc(MessagePack.Value, values.len);
        @memcpy(arr, values);
        return .{ .array = arr };
    }

    pub fn map(self: *Builder, entries: []const struct { []const u8, MessagePack.Value }) !MessagePack.Value {
        var m = std.StringHashMap(MessagePack.Value).init(self.allocator);
        for (entries) |entry| {
            try m.put(try self.allocator.dupe(u8, entry[0]), entry[1]);
        }
        return .{ .map = m };
    }
};
