const std = @import("std");

/// Apache Avro serialization implementation
/// A compact binary format with schema support
/// Optimized for data serialization in distributed systems
pub const Avro = struct {
    allocator: std.mem.Allocator,

    pub const Error = error{
        InvalidSchema,
        InvalidType,
        UnexpectedEndOfInput,
        InvalidUtf8,
        SchemaViolation,
        IntegerOverflow,
        OutOfMemory,
        InvalidUnion,
        InvalidEnum,
    };

    /// Avro primitive types
    pub const Type = enum {
        null_type,
        boolean,
        int,
        long,
        float,
        double,
        bytes,
        string,
        record,
        @"enum",
        array,
        map,
        @"union",
        fixed,
    };

    /// Schema definition
    pub const Schema = union(Type) {
        null_type: void,
        boolean: void,
        int: void,
        long: void,
        float: void,
        double: void,
        bytes: void,
        string: void,
        record: RecordSchema,
        @"enum": EnumSchema,
        array: *const Schema,
        map: *const Schema,
        @"union": []const Schema,
        fixed: FixedSchema,
    };

    pub const RecordSchema = struct {
        name: []const u8,
        fields: []const Field,

        pub const Field = struct {
            name: []const u8,
            type: Schema,
        };
    };

    pub const EnumSchema = struct {
        name: []const u8,
        symbols: []const []const u8,
    };

    pub const FixedSchema = struct {
        name: []const u8,
        size: usize,
    };

    /// Avro value representation
    pub const Value = union(Type) {
        null_type: void,
        boolean: bool,
        int: i32,
        long: i64,
        float: f32,
        double: f64,
        bytes: []const u8,
        string: []const u8,
        record: []const Field,
        @"enum": u32,
        array: []const Value,
        map: []const MapEntry,
        @"union": struct {
            index: u32,
            value: *const Value,
        },
        fixed: []const u8,

        pub const Field = struct {
            name: []const u8,
            value: Value,
        };

        pub const MapEntry = struct {
            key: []const u8,
            value: Value,
        };
    };

    pub fn init(allocator: std.mem.Allocator) Avro {
        return Avro{
            .allocator = allocator,
        };
    }

    /// Encode a value to Avro binary format
    pub fn encode(self: *Avro, schema: Schema, value: Value) Error![]u8 {
        var encoder = try AvroEncoder.init(self.allocator);
        defer encoder.deinit();

        return try encoder.encode(schema, value);
    }

    /// Decode Avro binary data to a value
    pub fn decode(self: *Avro, schema: Schema, data: []const u8) Error!Value {
        var decoder = try AvroDecoder.init(self.allocator);
        defer decoder.deinit();

        return try decoder.decode(schema, data);
    }
};

/// Avro binary encoder
pub const AvroEncoder = struct {
    allocator: std.mem.Allocator,
    output: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) Avro.Error!AvroEncoder {
        return AvroEncoder{
            .allocator = allocator,
            .output = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *AvroEncoder) void {
        self.output.deinit();
    }

    pub fn encode(self: *AvroEncoder, schema: Avro.Schema, value: Avro.Value) Avro.Error![]u8 {
        try self.encodeValue(schema, value);
        return try self.output.toOwnedSlice();
    }

    fn encodeValue(self: *AvroEncoder, schema: Avro.Schema, value: Avro.Value) Avro.Error!void {
        // Verify schema and value type match
        if (@as(Avro.Type, schema) != @as(Avro.Type, value)) {
            return Avro.Error.SchemaViolation;
        }

        switch (value) {
            .null_type => {}, // Null is encoded as nothing
            .boolean => |v| try self.encodeBoolean(v),
            .int => |v| try self.encodeInt(v),
            .long => |v| try self.encodeLong(v),
            .float => |v| try self.encodeFloat(v),
            .double => |v| try self.encodeDouble(v),
            .bytes => |v| try self.encodeBytes(v),
            .string => |v| try self.encodeString(v),
            .record => |v| try self.encodeRecord(schema.record, v),
            .@"enum" => |v| try self.encodeEnum(v),
            .array => |v| try self.encodeArray(schema.array.*, v),
            .map => |v| try self.encodeMap(schema.map.*, v),
            .@"union" => |v| try self.encodeUnion(schema.@"union", v),
            .fixed => |v| try self.encodeFixed(schema.fixed, v),
        }
    }

    fn encodeBoolean(self: *AvroEncoder, value: bool) !void {
        try self.output.append(if (value) 1 else 0);
    }

    fn encodeInt(self: *AvroEncoder, value: i32) !void {
        try self.encodeZigZag32(value);
    }

    fn encodeLong(self: *AvroEncoder, value: i64) !void {
        try self.encodeZigZag64(value);
    }

    fn encodeFloat(self: *AvroEncoder, value: f32) !void {
        const bytes = std.mem.toBytes(value);
        try self.output.appendSlice(&bytes);
    }

    fn encodeDouble(self: *AvroEncoder, value: f64) !void {
        const bytes = std.mem.toBytes(value);
        try self.output.appendSlice(&bytes);
    }

    fn encodeBytes(self: *AvroEncoder, bytes: []const u8) !void {
        try self.encodeLong(@intCast(bytes.len));
        try self.output.appendSlice(bytes);
    }

    fn encodeString(self: *AvroEncoder, string: []const u8) !void {
        try self.encodeLong(@intCast(string.len));
        try self.output.appendSlice(string);
    }

    fn encodeRecord(self: *AvroEncoder, schema: Avro.RecordSchema, fields: []const Avro.Value.Field) !void {
        if (fields.len != schema.fields.len) {
            return Avro.Error.SchemaViolation;
        }

        for (schema.fields, fields) |schema_field, value_field| {
            try self.encodeValue(schema_field.type, value_field.value);
        }
    }

    fn encodeEnum(self: *AvroEncoder, index: u32) !void {
        try self.encodeInt(@intCast(index));
    }

    fn encodeArray(self: *AvroEncoder, item_schema: Avro.Schema, array: []const Avro.Value) !void {
        if (array.len > 0) {
            // Write block count (positive for non-empty block)
            try self.encodeLong(@intCast(array.len));

            // Write array items
            for (array) |item| {
                try self.encodeValue(item_schema, item);
            }
        }

        // Write zero to indicate end of array
        try self.encodeLong(0);
    }

    fn encodeMap(self: *AvroEncoder, value_schema: Avro.Schema, map: []const Avro.Value.MapEntry) !void {
        if (map.len > 0) {
            // Write block count
            try self.encodeLong(@intCast(map.len));

            // Write map entries
            for (map) |entry| {
                try self.encodeString(entry.key);
                try self.encodeValue(value_schema, entry.value);
            }
        }

        // Write zero to indicate end of map
        try self.encodeLong(0);
    }

    fn encodeUnion(self: *AvroEncoder, schemas: []const Avro.Schema, union_value: struct { index: u32, value: *const Avro.Value }) !void {
        if (union_value.index >= schemas.len) {
            return Avro.Error.InvalidUnion;
        }

        // Write union index
        try self.encodeLong(@intCast(union_value.index));

        // Write value according to selected schema
        try self.encodeValue(schemas[union_value.index], union_value.value.*);
    }

    fn encodeFixed(self: *AvroEncoder, schema: Avro.FixedSchema, bytes: []const u8) !void {
        if (bytes.len != schema.size) {
            return Avro.Error.SchemaViolation;
        }
        try self.output.appendSlice(bytes);
    }

    fn encodeZigZag32(self: *AvroEncoder, value: i32) !void {
        const unsigned: u32 = @bitCast((value << 1) ^ (value >> 31));
        try self.encodeVarInt(unsigned);
    }

    fn encodeZigZag64(self: *AvroEncoder, value: i64) !void {
        const unsigned: u64 = @bitCast((value << 1) ^ (value >> 63));
        try self.encodeVarInt(unsigned);
    }

    fn encodeVarInt(self: *AvroEncoder, value: anytype) !void {
        var v = value;
        while (v >= 0x80) {
            try self.output.append(@intCast((v & 0x7F) | 0x80));
            v >>= 7;
        }
        try self.output.append(@intCast(v));
    }
};

/// Avro binary decoder
pub const AvroDecoder = struct {
    allocator: std.mem.Allocator,
    input: []const u8,
    pos: usize,

    pub fn init(allocator: std.mem.Allocator) Avro.Error!AvroDecoder {
        return AvroDecoder{
            .allocator = allocator,
            .input = &[_]u8{},
            .pos = 0,
        };
    }

    pub fn deinit(self: *AvroDecoder) void {
        _ = self;
    }

    pub fn decode(self: *AvroDecoder, schema: Avro.Schema, data: []const u8) Avro.Error!Avro.Value {
        self.input = data;
        self.pos = 0;
        return try self.decodeValue(schema);
    }

    fn decodeValue(self: *AvroDecoder, schema: Avro.Schema) Avro.Error!Avro.Value {
        switch (schema) {
            .null_type => return Avro.Value{ .null_type = {} },
            .boolean => return Avro.Value{ .boolean = try self.decodeBoolean() },
            .int => return Avro.Value{ .int = try self.decodeInt() },
            .long => return Avro.Value{ .long = try self.decodeLong() },
            .float => return Avro.Value{ .float = try self.decodeFloat() },
            .double => return Avro.Value{ .double = try self.decodeDouble() },
            .bytes => return Avro.Value{ .bytes = try self.decodeBytes() },
            .string => return Avro.Value{ .string = try self.decodeString() },
            .record => |s| return Avro.Value{ .record = try self.decodeRecord(s) },
            .@"enum" => return Avro.Value{ .@"enum" = try self.decodeEnum() },
            .array => |s| return Avro.Value{ .array = try self.decodeArray(s.*) },
            .map => |s| return Avro.Value{ .map = try self.decodeMap(s.*) },
            .@"union" => |s| return try self.decodeUnion(s),
            .fixed => |s| return Avro.Value{ .fixed = try self.decodeFixed(s) },
        }
    }

    fn decodeBoolean(self: *AvroDecoder) Avro.Error!bool {
        if (self.pos >= self.input.len) return Avro.Error.UnexpectedEndOfInput;
        const value = self.input[self.pos];
        self.pos += 1;
        return value != 0;
    }

    fn decodeInt(self: *AvroDecoder) Avro.Error!i32 {
        const unsigned = try self.decodeVarInt(u32);
        return @bitCast((unsigned >> 1) ^ (0 -% (unsigned & 1)));
    }

    fn decodeLong(self: *AvroDecoder) Avro.Error!i64 {
        const unsigned = try self.decodeVarInt(u64);
        return @bitCast((unsigned >> 1) ^ (0 -% (unsigned & 1)));
    }

    fn decodeFloat(self: *AvroDecoder) Avro.Error!f32 {
        if (self.pos + 4 > self.input.len) return Avro.Error.UnexpectedEndOfInput;
        const bytes = self.input[self.pos..][0..4];
        self.pos += 4;
        return std.mem.bytesToValue(f32, bytes);
    }

    fn decodeDouble(self: *AvroDecoder) Avro.Error!f64 {
        if (self.pos + 8 > self.input.len) return Avro.Error.UnexpectedEndOfInput;
        const bytes = self.input[self.pos..][0..8];
        self.pos += 8;
        return std.mem.bytesToValue(f64, bytes);
    }

    fn decodeBytes(self: *AvroDecoder) Avro.Error![]const u8 {
        const length: usize = @intCast(try self.decodeLong());
        if (self.pos + length > self.input.len) return Avro.Error.UnexpectedEndOfInput;
        const bytes = try self.allocator.dupe(u8, self.input[self.pos..][0..length]);
        self.pos += length;
        return bytes;
    }

    fn decodeString(self: *AvroDecoder) Avro.Error![]const u8 {
        return try self.decodeBytes();
    }

    fn decodeRecord(self: *AvroDecoder, schema: Avro.RecordSchema) Avro.Error![]const Avro.Value.Field {
        var fields = try self.allocator.alloc(Avro.Value.Field, schema.fields.len);

        for (schema.fields, 0..) |schema_field, i| {
            const value = try self.decodeValue(schema_field.type);
            fields[i] = Avro.Value.Field{
                .name = schema_field.name,
                .value = value,
            };
        }

        return fields;
    }

    fn decodeEnum(self: *AvroDecoder) Avro.Error!u32 {
        const index = try self.decodeInt();
        if (index < 0) return Avro.Error.InvalidEnum;
        return @intCast(index);
    }

    fn decodeArray(self: *AvroDecoder, item_schema: Avro.Schema) Avro.Error![]const Avro.Value {
        var items = std.ArrayList(Avro.Value).init(self.allocator);

        while (true) {
            const block_count = try self.decodeLong();
            if (block_count == 0) break;

            if (block_count < 0) {
                // Negative count means block size follows
                _ = try self.decodeLong(); // Skip block size
                return Avro.Error.InvalidType;
            }

            const count: usize = @intCast(block_count);
            for (0..count) |_| {
                const item = try self.decodeValue(item_schema);
                try items.append(item);
            }
        }

        return try items.toOwnedSlice();
    }

    fn decodeMap(self: *AvroDecoder, value_schema: Avro.Schema) Avro.Error![]const Avro.Value.MapEntry {
        var entries = std.ArrayList(Avro.Value.MapEntry).init(self.allocator);

        while (true) {
            const block_count = try self.decodeLong();
            if (block_count == 0) break;

            if (block_count < 0) {
                // Negative count means block size follows
                _ = try self.decodeLong(); // Skip block size
                return Avro.Error.InvalidType;
            }

            const count: usize = @intCast(block_count);
            for (0..count) |_| {
                const key = try self.decodeString();
                const value = try self.decodeValue(value_schema);
                try entries.append(Avro.Value.MapEntry{
                    .key = key,
                    .value = value,
                });
            }
        }

        return try entries.toOwnedSlice();
    }

    fn decodeUnion(self: *AvroDecoder, schemas: []const Avro.Schema) Avro.Error!Avro.Value {
        const index_long = try self.decodeLong();
        if (index_long < 0) return Avro.Error.InvalidUnion;

        const index: u32 = @intCast(index_long);
        if (index >= schemas.len) return Avro.Error.InvalidUnion;

        const value = try self.allocator.create(Avro.Value);
        value.* = try self.decodeValue(schemas[index]);

        return Avro.Value{ .@"union" = .{ .index = index, .value = value } };
    }

    fn decodeFixed(self: *AvroDecoder, schema: Avro.FixedSchema) Avro.Error![]const u8 {
        if (self.pos + schema.size > self.input.len) return Avro.Error.UnexpectedEndOfInput;
        const bytes = try self.allocator.dupe(u8, self.input[self.pos..][0..schema.size]);
        self.pos += schema.size;
        return bytes;
    }

    fn decodeVarInt(self: *AvroDecoder, comptime T: type) Avro.Error!T {
        var result: T = 0;
        var shift: u7 = 0;

        while (self.pos < self.input.len) {
            const byte = self.input[self.pos];
            self.pos += 1;

            result |= @as(T, byte & 0x7F) << shift;

            if ((byte & 0x80) == 0) {
                return result;
            }

            shift += 7;
            if (shift >= @bitSizeOf(T)) return Avro.Error.IntegerOverflow;
        }

        return Avro.Error.UnexpectedEndOfInput;
    }
};

test "avro encode and decode int" {
    const allocator = std.testing.allocator;

    var avro = Avro.init(allocator);

    const schema = Avro.Schema{ .int = {} };
    const value = Avro.Value{ .int = 42 };

    const encoded = try avro.encode(schema, value);
    defer allocator.free(encoded);

    const decoded = try avro.decode(schema, encoded);

    try std.testing.expectEqual(@as(i32, 42), decoded.int);
}

test "avro encode and decode string" {
    const allocator = std.testing.allocator;

    var avro = Avro.init(allocator);

    const schema = Avro.Schema{ .string = {} };
    const value = Avro.Value{ .string = "Hello, Avro!" };

    const encoded = try avro.encode(schema, value);
    defer allocator.free(encoded);

    const decoded = try avro.decode(schema, encoded);
    defer allocator.free(decoded.string);

    try std.testing.expectEqualStrings("Hello, Avro!", decoded.string);
}

test "avro encode and decode boolean" {
    const allocator = std.testing.allocator;

    var avro = Avro.init(allocator);

    const schema = Avro.Schema{ .boolean = {} };
    const true_value = Avro.Value{ .boolean = true };

    const encoded = try avro.encode(schema, true_value);
    defer allocator.free(encoded);

    const decoded = try avro.decode(schema, encoded);

    try std.testing.expectEqual(true, decoded.boolean);
}

test "avro encode and decode array" {
    const allocator = std.testing.allocator;

    var avro = Avro.init(allocator);

    const item_schema = try allocator.create(Avro.Schema);
    defer allocator.destroy(item_schema);
    item_schema.* = Avro.Schema{ .int = {} };

    const schema = Avro.Schema{ .array = item_schema };

    var array = [_]Avro.Value{
        Avro.Value{ .int = 1 },
        Avro.Value{ .int = 2 },
        Avro.Value{ .int = 3 },
    };
    const value = Avro.Value{ .array = &array };

    const encoded = try avro.encode(schema, value);
    defer allocator.free(encoded);

    const decoded = try avro.decode(schema, encoded);
    defer allocator.free(decoded.array);

    try std.testing.expectEqual(@as(usize, 3), decoded.array.len);
    try std.testing.expectEqual(@as(i32, 1), decoded.array[0].int);
    try std.testing.expectEqual(@as(i32, 2), decoded.array[1].int);
    try std.testing.expectEqual(@as(i32, 3), decoded.array[2].int);
}

test "avro encode and decode null" {
    const allocator = std.testing.allocator;

    var avro = Avro.init(allocator);

    const schema = Avro.Schema{ .null_type = {} };
    const value = Avro.Value{ .null_type = {} };

    const encoded = try avro.encode(schema, value);
    defer allocator.free(encoded);

    const decoded = try avro.decode(schema, encoded);

    try std.testing.expectEqual(Avro.Value.null_type, std.meta.activeTag(decoded));
}
