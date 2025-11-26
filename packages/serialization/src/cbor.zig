const std = @import("std");

/// CBOR (Concise Binary Object Representation) implementation
/// RFC 8949 - A binary data serialization format
/// More compact and extensible than JSON
pub const CBOR = struct {
    allocator: std.mem.Allocator,

    pub const Error = error{
        InvalidMajorType,
        InvalidAdditionalInfo,
        InvalidUtf8,
        UnexpectedEndOfInput,
        UnsupportedType,
        IntegerOverflow,
        InvalidIndefiniteLength,
        OutOfMemory,
    };

    // Major types (3-bit)
    pub const MajorType = enum(u3) {
        unsigned_integer = 0,
        negative_integer = 1,
        byte_string = 2,
        text_string = 3,
        array = 4,
        map = 5,
        tag = 6,
        simple_or_float = 7,
    };

    // Simple values
    pub const SimpleValue = enum(u8) {
        false_val = 20,
        true_val = 21,
        null_val = 22,
        undefined_val = 23,
    };

    pub const Value = union(enum) {
        unsigned: u64,
        negative: i64,
        bytes: []const u8,
        text: []const u8,
        array: []const Value,
        map: []const MapEntry,
        tag: struct {
            tag: u64,
            value: *const Value,
        },
        bool: bool,
        null: void,
        undefined: void,
        float: f64,
    };

    pub const MapEntry = struct {
        key: Value,
        value: Value,
    };

    pub fn init(allocator: std.mem.Allocator) CBOR {
        return CBOR{
            .allocator = allocator,
        };
    }

    /// Encode a value to CBOR format
    pub fn encode(self: *CBOR, value: Value) Error![]u8 {
        var encoder = try CBOREncoder.init(self.allocator);
        defer encoder.deinit();

        return try encoder.encode(value);
    }

    /// Decode CBOR data to a value
    pub fn decode(self: *CBOR, data: []const u8) Error!Value {
        var decoder = try CBORDecoder.init(self.allocator);
        defer decoder.deinit();

        return try decoder.decode(data);
    }
};

/// CBOR encoder
pub const CBOREncoder = struct {
    allocator: std.mem.Allocator,
    output: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) CBOR.Error!CBOREncoder {
        return CBOREncoder{
            .allocator = allocator,
            .output = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *CBOREncoder) void {
        self.output.deinit();
    }

    pub fn encode(self: *CBOREncoder, value: CBOR.Value) CBOR.Error![]u8 {
        try self.encodeValue(value);
        return try self.output.toOwnedSlice();
    }

    fn encodeValue(self: *CBOREncoder, value: CBOR.Value) CBOR.Error!void {
        switch (value) {
            .unsigned => |v| try self.encodeUnsigned(v),
            .negative => |v| try self.encodeNegative(v),
            .bytes => |v| try self.encodeBytes(v),
            .text => |v| try self.encodeText(v),
            .array => |v| try self.encodeArray(v),
            .map => |v| try self.encodeMap(v),
            .tag => |v| try self.encodeTag(v.tag, v.value),
            .bool => |v| try self.encodeBool(v),
            .null => try self.encodeNull(),
            .undefined => try self.encodeUndefined(),
            .float => |v| try self.encodeFloat(v),
        }
    }

    fn encodeUnsigned(self: *CBOREncoder, value: u64) !void {
        try self.encodeTypeAndValue(.unsigned_integer, value);
    }

    fn encodeNegative(self: *CBOREncoder, value: i64) !void {
        const unsigned_value: u64 = @intCast(-1 - value);
        try self.encodeTypeAndValue(.negative_integer, unsigned_value);
    }

    fn encodeBytes(self: *CBOREncoder, bytes: []const u8) !void {
        try self.encodeTypeAndValue(.byte_string, bytes.len);
        try self.output.appendSlice(bytes);
    }

    fn encodeText(self: *CBOREncoder, text: []const u8) !void {
        try self.encodeTypeAndValue(.text_string, text.len);
        try self.output.appendSlice(text);
    }

    fn encodeArray(self: *CBOREncoder, array: []const CBOR.Value) !void {
        try self.encodeTypeAndValue(.array, array.len);
        for (array) |item| {
            try self.encodeValue(item);
        }
    }

    fn encodeMap(self: *CBOREncoder, map: []const CBOR.MapEntry) !void {
        try self.encodeTypeAndValue(.map, map.len);
        for (map) |entry| {
            try self.encodeValue(entry.key);
            try self.encodeValue(entry.value);
        }
    }

    fn encodeTag(self: *CBOREncoder, tag: u64, value: *const CBOR.Value) !void {
        try self.encodeTypeAndValue(.tag, tag);
        try self.encodeValue(value.*);
    }

    fn encodeBool(self: *CBOREncoder, value: bool) !void {
        const initial_byte = if (value) 0xF5 else 0xF4; // true or false
        try self.output.append(initial_byte);
    }

    fn encodeNull(self: *CBOREncoder) !void {
        try self.output.append(0xF6);
    }

    fn encodeUndefined(self: *CBOREncoder) !void {
        try self.output.append(0xF7);
    }

    fn encodeFloat(self: *CBOREncoder, value: f64) !void {
        // Encode as float64
        try self.output.append(0xFB);
        const bytes = std.mem.toBytes(value);
        // CBOR uses big-endian
        var i: usize = bytes.len;
        while (i > 0) {
            i -= 1;
            try self.output.append(bytes[i]);
        }
    }

    fn encodeTypeAndValue(self: *CBOREncoder, major_type: CBOR.MajorType, value: u64) !void {
        const major_bits: u8 = @intFromEnum(major_type) << 5;

        if (value < 24) {
            // Single byte encoding
            try self.output.append(major_bits | @as(u8, @intCast(value)));
        } else if (value <= 0xFF) {
            // 1-byte value
            try self.output.append(major_bits | 24);
            try self.output.append(@intCast(value));
        } else if (value <= 0xFFFF) {
            // 2-byte value
            try self.output.append(major_bits | 25);
            try self.output.append(@intCast((value >> 8) & 0xFF));
            try self.output.append(@intCast(value & 0xFF));
        } else if (value <= 0xFFFFFFFF) {
            // 4-byte value
            try self.output.append(major_bits | 26);
            try self.output.append(@intCast((value >> 24) & 0xFF));
            try self.output.append(@intCast((value >> 16) & 0xFF));
            try self.output.append(@intCast((value >> 8) & 0xFF));
            try self.output.append(@intCast(value & 0xFF));
        } else {
            // 8-byte value
            try self.output.append(major_bits | 27);
            try self.output.append(@intCast((value >> 56) & 0xFF));
            try self.output.append(@intCast((value >> 48) & 0xFF));
            try self.output.append(@intCast((value >> 40) & 0xFF));
            try self.output.append(@intCast((value >> 32) & 0xFF));
            try self.output.append(@intCast((value >> 24) & 0xFF));
            try self.output.append(@intCast((value >> 16) & 0xFF));
            try self.output.append(@intCast((value >> 8) & 0xFF));
            try self.output.append(@intCast(value & 0xFF));
        }
    }
};

/// CBOR decoder
pub const CBORDecoder = struct {
    allocator: std.mem.Allocator,
    input: []const u8,
    pos: usize,

    pub fn init(allocator: std.mem.Allocator) CBOR.Error!CBORDecoder {
        return CBORDecoder{
            .allocator = allocator,
            .input = &[_]u8{},
            .pos = 0,
        };
    }

    pub fn deinit(self: *CBORDecoder) void {
        _ = self;
    }

    pub fn decode(self: *CBORDecoder, data: []const u8) CBOR.Error!CBOR.Value {
        self.input = data;
        self.pos = 0;
        return try self.decodeValue();
    }

    fn decodeValue(self: *CBORDecoder) CBOR.Error!CBOR.Value {
        if (self.pos >= self.input.len) {
            return CBOR.Error.UnexpectedEndOfInput;
        }

        const initial_byte = self.input[self.pos];
        self.pos += 1;

        const major_type_val = initial_byte >> 5;
        const additional_info = initial_byte & 0x1F;

        const major_type: CBOR.MajorType = @enumFromInt(major_type_val);

        switch (major_type) {
            .unsigned_integer => {
                const value = try self.decodeLength(additional_info);
                return CBOR.Value{ .unsigned = value };
            },
            .negative_integer => {
                const value = try self.decodeLength(additional_info);
                const signed: i64 = @intCast(-1 - @as(i128, value));
                return CBOR.Value{ .negative = signed };
            },
            .byte_string => {
                const length = try self.decodeLength(additional_info);
                if (self.pos + length > self.input.len) {
                    return CBOR.Error.UnexpectedEndOfInput;
                }
                const bytes = try self.allocator.dupe(u8, self.input[self.pos..][0..length]);
                self.pos += length;
                return CBOR.Value{ .bytes = bytes };
            },
            .text_string => {
                const length = try self.decodeLength(additional_info);
                if (self.pos + length > self.input.len) {
                    return CBOR.Error.UnexpectedEndOfInput;
                }
                const text = try self.allocator.dupe(u8, self.input[self.pos..][0..length]);
                self.pos += length;
                return CBOR.Value{ .text = text };
            },
            .array => {
                const length = try self.decodeLength(additional_info);
                var array = try self.allocator.alloc(CBOR.Value, length);
                for (0..length) |i| {
                    array[i] = try self.decodeValue();
                }
                return CBOR.Value{ .array = array };
            },
            .map => {
                const length = try self.decodeLength(additional_info);
                var map = try self.allocator.alloc(CBOR.MapEntry, length);
                for (0..length) |i| {
                    const key = try self.decodeValue();
                    const value = try self.decodeValue();
                    map[i] = CBOR.MapEntry{ .key = key, .value = value };
                }
                return CBOR.Value{ .map = map };
            },
            .tag => {
                const tag = try self.decodeLength(additional_info);
                const value = try self.allocator.create(CBOR.Value);
                value.* = try self.decodeValue();
                return CBOR.Value{ .tag = .{ .tag = tag, .value = value } };
            },
            .simple_or_float => {
                return try self.decodeSimpleOrFloat(additional_info);
            },
        }
    }

    fn decodeLength(self: *CBORDecoder, additional_info: u8) CBOR.Error!u64 {
        if (additional_info < 24) {
            return additional_info;
        } else if (additional_info == 24) {
            if (self.pos >= self.input.len) return CBOR.Error.UnexpectedEndOfInput;
            const value = self.input[self.pos];
            self.pos += 1;
            return value;
        } else if (additional_info == 25) {
            if (self.pos + 2 > self.input.len) return CBOR.Error.UnexpectedEndOfInput;
            const value = (@as(u64, self.input[self.pos]) << 8) |
                         @as(u64, self.input[self.pos + 1]);
            self.pos += 2;
            return value;
        } else if (additional_info == 26) {
            if (self.pos + 4 > self.input.len) return CBOR.Error.UnexpectedEndOfInput;
            const value = (@as(u64, self.input[self.pos]) << 24) |
                         (@as(u64, self.input[self.pos + 1]) << 16) |
                         (@as(u64, self.input[self.pos + 2]) << 8) |
                         @as(u64, self.input[self.pos + 3]);
            self.pos += 4;
            return value;
        } else if (additional_info == 27) {
            if (self.pos + 8 > self.input.len) return CBOR.Error.UnexpectedEndOfInput;
            const value = (@as(u64, self.input[self.pos]) << 56) |
                         (@as(u64, self.input[self.pos + 1]) << 48) |
                         (@as(u64, self.input[self.pos + 2]) << 40) |
                         (@as(u64, self.input[self.pos + 3]) << 32) |
                         (@as(u64, self.input[self.pos + 4]) << 24) |
                         (@as(u64, self.input[self.pos + 5]) << 16) |
                         (@as(u64, self.input[self.pos + 6]) << 8) |
                         @as(u64, self.input[self.pos + 7]);
            self.pos += 8;
            return value;
        } else {
            return CBOR.Error.InvalidAdditionalInfo;
        }
    }

    fn decodeSimpleOrFloat(self: *CBORDecoder, additional_info: u8) CBOR.Error!CBOR.Value {
        if (additional_info == 20) {
            return CBOR.Value{ .bool = false };
        } else if (additional_info == 21) {
            return CBOR.Value{ .bool = true };
        } else if (additional_info == 22) {
            return CBOR.Value{ .null = {} };
        } else if (additional_info == 23) {
            return CBOR.Value{ .undefined = {} };
        } else if (additional_info == 27) {
            // Float64
            if (self.pos + 8 > self.input.len) return CBOR.Error.UnexpectedEndOfInput;

            var bytes: [8]u8 = undefined;
            // CBOR uses big-endian, need to reverse for native
            for (0..8) |i| {
                bytes[7 - i] = self.input[self.pos + i];
            }
            self.pos += 8;

            const value = std.mem.bytesToValue(f64, &bytes);
            return CBOR.Value{ .float = value };
        } else {
            return CBOR.Error.UnsupportedType;
        }
    }
};

test "cbor encode unsigned integer" {
    const allocator = std.testing.allocator;

    var cbor = CBOR.init(allocator);

    const value = CBOR.Value{ .unsigned = 42 };
    const encoded = try cbor.encode(value);
    defer allocator.free(encoded);

    try std.testing.expectEqual(@as(usize, 1), encoded.len);
    try std.testing.expectEqual(@as(u8, 0x18), encoded[0] >> 5); // Major type 0
}

test "cbor encode and decode unsigned integer" {
    const allocator = std.testing.allocator;

    var cbor = CBOR.init(allocator);

    const value = CBOR.Value{ .unsigned = 1000 };
    const encoded = try cbor.encode(value);
    defer allocator.free(encoded);

    const decoded = try cbor.decode(encoded);

    try std.testing.expectEqual(CBOR.Value.unsigned, std.meta.activeTag(decoded));
    try std.testing.expectEqual(@as(u64, 1000), decoded.unsigned);
}

test "cbor encode and decode text string" {
    const allocator = std.testing.allocator;

    var cbor = CBOR.init(allocator);

    const value = CBOR.Value{ .text = "Hello, CBOR!" };
    const encoded = try cbor.encode(value);
    defer allocator.free(encoded);

    const decoded = try cbor.decode(encoded);
    defer allocator.free(decoded.text);

    try std.testing.expectEqualStrings("Hello, CBOR!", decoded.text);
}

test "cbor encode and decode boolean" {
    const allocator = std.testing.allocator;

    var cbor = CBOR.init(allocator);

    const true_value = CBOR.Value{ .bool = true };
    const encoded_true = try cbor.encode(true_value);
    defer allocator.free(encoded_true);

    const decoded_true = try cbor.decode(encoded_true);
    try std.testing.expectEqual(true, decoded_true.bool);

    const false_value = CBOR.Value{ .bool = false };
    const encoded_false = try cbor.encode(false_value);
    defer allocator.free(encoded_false);

    const decoded_false = try cbor.decode(encoded_false);
    try std.testing.expectEqual(false, decoded_false.bool);
}

test "cbor encode and decode array" {
    const allocator = std.testing.allocator;

    var cbor = CBOR.init(allocator);

    var array = [_]CBOR.Value{
        CBOR.Value{ .unsigned = 1 },
        CBOR.Value{ .unsigned = 2 },
        CBOR.Value{ .unsigned = 3 },
    };

    const value = CBOR.Value{ .array = &array };
    const encoded = try cbor.encode(value);
    defer allocator.free(encoded);

    const decoded = try cbor.decode(encoded);
    defer allocator.free(decoded.array);

    try std.testing.expectEqual(@as(usize, 3), decoded.array.len);
    try std.testing.expectEqual(@as(u64, 1), decoded.array[0].unsigned);
    try std.testing.expectEqual(@as(u64, 2), decoded.array[1].unsigned);
    try std.testing.expectEqual(@as(u64, 3), decoded.array[2].unsigned);
}

test "cbor encode and decode float" {
    const allocator = std.testing.allocator;

    var cbor = CBOR.init(allocator);

    const value = CBOR.Value{ .float = 3.14159 };
    const encoded = try cbor.encode(value);
    defer allocator.free(encoded);

    const decoded = try cbor.decode(encoded);

    try std.testing.expectApproxEqAbs(@as(f64, 3.14159), decoded.float, 0.00001);
}

test "cbor encode and decode null" {
    const allocator = std.testing.allocator;

    var cbor = CBOR.init(allocator);

    const value = CBOR.Value{ .null = {} };
    const encoded = try cbor.encode(value);
    defer allocator.free(encoded);

    const decoded = try cbor.decode(encoded);

    try std.testing.expectEqual(CBOR.Value.null, std.meta.activeTag(decoded));
}

test "cbor encode and decode negative integer" {
    const allocator = std.testing.allocator;

    var cbor = CBOR.init(allocator);

    const value = CBOR.Value{ .negative = -100 };
    const encoded = try cbor.encode(value);
    defer allocator.free(encoded);

    const decoded = try cbor.decode(encoded);

    try std.testing.expectEqual(@as(i64, -100), decoded.negative);
}
