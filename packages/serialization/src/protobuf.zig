const std = @import("std");

/// Protocol Buffers (protobuf) serialization
///
/// Features:
/// - Binary wire format
/// - Schema-based (code generation)
/// - Backward/forward compatible
/// - Varint encoding
/// - Field tags
pub const Protobuf = struct {
    allocator: std.mem.Allocator,

    pub const Error = error{
        EndOfStream,
        InvalidFieldNumber,
        OutOfMemory,
        ReadFailed,
        UnsupportedWireType,
        VarintOverflow,
        WriteFailed,
    };

    pub const WireType = enum(u3) {
        varint = 0,
        fixed64 = 1,
        length_delimited = 2,
        start_group = 3, // deprecated
        end_group = 4, // deprecated
        fixed32 = 5,
    };

    pub const Value = union(enum) {
        varint: u64,
        fixed32: u32,
        fixed64: u64,
        length_delimited: []const u8,
        message: Message,

        pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
            switch (self.*) {
                .length_delimited => |data| allocator.free(data),
                .message => |*msg| msg.deinit(allocator),
                else => {},
            }
        }
    };

    pub const Field = struct {
        number: u32,
        wire_type: WireType,
        value: Value,

        pub fn deinit(self: *Field, allocator: std.mem.Allocator) void {
            self.value.deinit(allocator);
        }
    };

    pub const Message = struct {
        allocator: std.mem.Allocator,
        fields: std.ArrayList(Field) = .empty,

        pub fn init(allocator: std.mem.Allocator) Message {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Message, allocator: std.mem.Allocator) void {
            for (self.fields.items) |*field| {
                field.deinit(allocator);
            }
            self.fields.deinit(allocator);
        }

        pub fn addVarint(self: *Message, field_number: u32, value: u64) !void {
            try validateFieldNumber(field_number);
            try self.fields.append(self.allocator, .{
                .number = field_number,
                .wire_type = .varint,
                .value = .{ .varint = value },
            });
        }

        pub fn addFixed32(self: *Message, field_number: u32, value: u32) !void {
            try validateFieldNumber(field_number);
            try self.fields.append(self.allocator, .{
                .number = field_number,
                .wire_type = .fixed32,
                .value = .{ .fixed32 = value },
            });
        }

        pub fn addFixed64(self: *Message, field_number: u32, value: u64) !void {
            try validateFieldNumber(field_number);
            try self.fields.append(self.allocator, .{
                .number = field_number,
                .wire_type = .fixed64,
                .value = .{ .fixed64 = value },
            });
        }

        pub fn addBytes(self: *Message, allocator: std.mem.Allocator, field_number: u32, data: []const u8) !void {
            try validateFieldNumber(field_number);
            const owned = try allocator.dupe(u8, data);
            errdefer allocator.free(owned);
            try self.fields.append(self.allocator, .{
                .number = field_number,
                .wire_type = .length_delimited,
                .value = .{ .length_delimited = owned },
            });
        }

        pub fn addString(self: *Message, allocator: std.mem.Allocator, field_number: u32, str: []const u8) !void {
            try self.addBytes(allocator, field_number, str);
        }

        pub fn addMessage(self: *Message, field_number: u32, msg: Message) !void {
            try validateFieldNumber(field_number);
            try self.fields.append(self.allocator, .{
                .number = field_number,
                .wire_type = .length_delimited,
                .value = .{ .message = msg },
            });
        }

        pub fn getVarint(self: *const Message, field_number: u32) ?u64 {
            for (self.fields.items) |field| {
                if (field.number == field_number and field.wire_type == .varint) {
                    return field.value.varint;
                }
            }
            return null;
        }

        pub fn getBytes(self: *const Message, field_number: u32) ?[]const u8 {
            for (self.fields.items) |field| {
                if (field.number == field_number) {
                    switch (field.value) {
                        .length_delimited => |data| return data,
                        else => {},
                    }
                }
            }
            return null;
        }
    };

    pub fn init(allocator: std.mem.Allocator) Protobuf {
        return .{ .allocator = allocator };
    }

    fn validateFieldNumber(field_number: u32) !void {
        if (field_number == 0 or field_number > 0x1fff_ffff) return error.InvalidFieldNumber;
    }

    /// Serialize a message to protobuf wire format
    pub fn serialize(self: *Protobuf, message: Message) Error![]u8 {
        var buffer: std.Io.Writer.Allocating = .init(self.allocator);
        defer buffer.deinit();

        try self.encodeMessage(&buffer.writer, message);

        return try buffer.toOwnedSlice();
    }

    /// Deserialize protobuf wire format to a message
    pub fn deserialize(self: *Protobuf, data: []const u8) !Message {
        var reader: std.Io.Reader = .fixed(data);
        return try self.decodeMessage(&reader);
    }

    fn encodeMessage(self: *Protobuf, writer: anytype, message: Message) Error!void {
        for (message.fields.items) |field| {
            try self.encodeField(writer, field);
        }
    }

    fn encodeField(self: *Protobuf, writer: anytype, field: Field) Error!void {
        try validateFieldNumber(field.number);
        // Encode tag (field number and wire type)
        const tag = (field.number << 3) | @intFromEnum(field.wire_type);
        try self.encodeVarint(writer, tag);

        // Encode value based on wire type
        switch (field.value) {
            .varint => |v| try self.encodeVarint(writer, v),
            .fixed32 => |v| try writer.writeInt(u32, v, .little),
            .fixed64 => |v| try writer.writeInt(u64, v, .little),
            .length_delimited => |data| {
                try self.encodeVarint(writer, data.len);
                try writer.writeAll(data);
            },
            .message => |msg| {
                // First serialize the nested message
                const nested_data = try self.serialize(msg);
                defer self.allocator.free(nested_data);

                // Then write it as length-delimited
                try self.encodeVarint(writer, nested_data.len);
                try writer.writeAll(nested_data);
            },
        }
    }

    fn decodeMessage(self: *Protobuf, reader: *std.Io.Reader) !Message {
        var message = Message.init(self.allocator);
        errdefer message.deinit(self.allocator);

        while (reader.seek < reader.end) {
            const tag = try self.decodeVarint(reader);

            const field_number: u32 = std.math.cast(u32, tag >> 3) orelse return error.InvalidFieldNumber;
            try validateFieldNumber(field_number);
            const wire_bits = tag & 7;
            if (wire_bits > @intFromEnum(WireType.fixed32)) return error.UnsupportedWireType;
            const wire_type: WireType = @enumFromInt(@as(u3, @intCast(wire_bits)));

            var value = try self.decodeValue(reader, wire_type);
            errdefer value.deinit(self.allocator);

            try message.fields.append(self.allocator, .{
                .number = field_number,
                .wire_type = wire_type,
                .value = value,
            });
        }

        return message;
    }

    fn decodeValue(self: *Protobuf, reader: *std.Io.Reader, wire_type: WireType) !Value {
        return switch (wire_type) {
            .varint => .{ .varint = try self.decodeVarint(reader) },
            .fixed32 => .{ .fixed32 = try reader.takeInt(u32, .little) },
            .fixed64 => .{ .fixed64 = try reader.takeInt(u64, .little) },
            .length_delimited => blk: {
                const len = try self.decodeVarint(reader);
                const data = try self.allocator.alloc(u8, @intCast(len));
                errdefer self.allocator.free(data);
                try reader.readSliceAll(data);
                break :blk .{ .length_delimited = data };
            },
            else => error.UnsupportedWireType,
        };
    }

    fn encodeVarint(self: *Protobuf, writer: anytype, value_param: anytype) !void {
        _ = self;
        var value = value_param;

        while (value >= 0x80) {
            try writer.writeByte(@as(u8, @truncate(value)) | 0x80);
            value >>= 7;
        }
        try writer.writeByte(@intCast(value));
    }

    fn decodeVarint(self: *Protobuf, reader: *std.Io.Reader) !u64 {
        _ = self;

        var result: u64 = 0;
        for (0..10) |index| {
            const byte = try reader.takeByte();
            if (index == 9 and byte > 1) return error.VarintOverflow;
            result |= @as(u64, byte & 0x7f) << @intCast(index * 7);
            if (byte & 0x80 == 0) return result;
        }
        return error.VarintOverflow;
    }

    /// Encode signed integer using ZigZag encoding
    pub fn encodeZigZag32(value: i32) u32 {
        return @bitCast((value << 1) ^ (value >> 31));
    }

    pub fn encodeZigZag64(value: i64) u64 {
        return @bitCast((value << 1) ^ (value >> 63));
    }

    /// Decode ZigZag encoded integer
    pub fn decodeZigZag32(value: u32) i32 {
        return @as(i32, @bitCast((value >> 1))) ^ -@as(i32, @intCast(value & 1));
    }

    pub fn decodeZigZag64(value: u64) i64 {
        return @as(i64, @bitCast((value >> 1))) ^ -@as(i64, @intCast(value & 1));
    }
};

/// Code generator for Protocol Buffers schema
pub const CodeGen = struct {
    allocator: std.mem.Allocator,

    pub const MessageDef = struct {
        name: []const u8,
        fields: []FieldDef,
    };

    pub const FieldDef = struct {
        name: []const u8,
        number: u32,
        field_type: FieldType,
        repeated: bool,
        optional: bool,
    };

    pub const FieldType = union(enum) {
        int32,
        int64,
        uint32,
        uint64,
        sint32,
        sint64,
        fixed32,
        fixed64,
        sfixed32,
        sfixed64,
        float,
        double,
        bool_type,
        string,
        bytes,
        message: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator) CodeGen {
        return .{ .allocator = allocator };
    }

    /// Generate Zig code from message definition
    pub fn generateCode(self: *CodeGen, msg_def: MessageDef) ![]u8 {
        var code: std.Io.Writer.Allocating = .init(self.allocator);
        defer code.deinit();

        const writer = &code.writer;

        // Generate struct definition
        try writer.print("pub const {s} = struct {{\n", .{msg_def.name});

        // Generate fields
        for (msg_def.fields) |field| {
            const field_type = try self.zigType(field.field_type, field.repeated, field.optional);
            defer self.allocator.free(field_type);

            try writer.print("    {s}: {s},\n", .{ field.name, field_type });
        }

        try writer.writeAll("\n");

        // Generate encode method
        try writer.writeAll("    pub fn encode(self: *const @This(), pb: *Protobuf) ![]u8 {\n");
        try writer.writeAll("        var msg = Protobuf.Message.init(pb.allocator);\n");
        try writer.writeAll("        errdefer msg.deinit(pb.allocator);\n\n");

        for (msg_def.fields) |field| {
            try self.generateEncodeField(writer, field);
        }

        try writer.writeAll("\n        return pb.serialize(msg);\n");
        try writer.writeAll("    }\n\n");

        // Generate decode method
        try writer.writeAll("    pub fn decode(data: []const u8, pb: *Protobuf) !@This() {\n");
        try writer.writeAll("        var msg = try pb.deserialize(data);\n");
        try writer.writeAll("        defer msg.deinit(pb.allocator);\n\n");
        try writer.writeAll("        return .{\n");

        for (msg_def.fields) |field| {
            try self.generateDecodeField(writer, field);
        }

        try writer.writeAll("        };\n");
        try writer.writeAll("    }\n");

        try writer.writeAll("};\n");

        return try code.toOwnedSlice();
    }

    fn zigType(self: *CodeGen, field_type: FieldType, repeated: bool, optional: bool) ![]u8 {
        var type_str: std.Io.Writer.Allocating = .init(self.allocator);
        defer type_str.deinit();

        const base_type = switch (field_type) {
            .int32, .sint32, .sfixed32 => "i32",
            .int64, .sint64, .sfixed64 => "i64",
            .uint32, .fixed32 => "u32",
            .uint64, .fixed64 => "u64",
            .float => "f32",
            .double => "f64",
            .bool_type => "bool",
            .string, .bytes => "[]const u8",
            .message => |name| name,
        };

        if (repeated) {
            try type_str.writer.print("[]const {s}", .{base_type});
        } else if (optional) {
            try type_str.writer.print("?{s}", .{base_type});
        } else {
            try type_str.writer.writeAll(base_type);
        }

        return try type_str.toOwnedSlice();
    }

    fn generateEncodeField(self: *CodeGen, writer: anytype, field: FieldDef) !void {
        _ = self;

        const method = switch (field.field_type) {
            .int32, .int64, .uint32, .uint64, .sint32, .sint64 => "addVarint",
            .fixed32, .sfixed32 => "addFixed32",
            .fixed64, .sfixed64 => "addFixed64",
            .string => "addString",
            .bytes => "addBytes",
            else => "addVarint", // fallback
        };

        if (field.repeated) {
            try writer.print("        for (self.{s}) |item| {{\n", .{field.name});
            try writer.print("            try msg.{s}(pb.allocator, {d}, item);\n", .{ method, field.number });
            try writer.writeAll("        }\n");
        } else if (field.optional) {
            try writer.print("        if (self.{s}) |value| {{\n", .{field.name});
            try writer.print("            try msg.{s}(pb.allocator, {d}, value);\n", .{ method, field.number });
            try writer.writeAll("        }\n");
        } else {
            try writer.print("        try msg.{s}(pb.allocator, {d}, self.{s});\n", .{ method, field.number, field.name });
        }
    }

    fn generateDecodeField(self: *CodeGen, writer: anytype, field: FieldDef) !void {
        _ = self;

        const getter = switch (field.field_type) {
            .string, .bytes => "getBytes",
            else => "getVarint",
        };

        const default_value = switch (field.field_type) {
            .int32, .int64, .uint32, .uint64, .sint32, .sint64 => "0",
            .fixed32, .sfixed32 => "0",
            .fixed64, .sfixed64 => "0",
            .float, .double => "0.0",
            .bool_type => "false",
            .string => "\"\"",
            .bytes => "&.{}",
            else => "null",
        };

        if (field.optional) {
            try writer.print("            .{s} = msg.{s}({d}),\n", .{ field.name, getter, field.number });
        } else {
            try writer.print("            .{s} = msg.{s}({d}) orelse {s},\n", .{ field.name, getter, field.number, default_value });
        }
    }
};

test "protobuf emits and parses canonical wire values" {
    var codec = Protobuf.init(std.testing.allocator);
    var message = Protobuf.Message.init(std.testing.allocator);
    defer message.deinit(std.testing.allocator);

    try message.addVarint(1, 150);
    try message.addFixed32(2, 0x1234_5678);
    try message.addBytes(std.testing.allocator, 3, "hi");

    const encoded = try codec.serialize(message);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualSlices(u8, &.{
        0x08, 0x96, 0x01,
        0x15, 0x78, 0x56,
        0x34, 0x12, 0x1a,
        0x02, 'h',  'i',
    }, encoded);

    var decoded = try codec.deserialize(encoded);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?u64, 150), decoded.getVarint(1));
    try std.testing.expectEqualStrings("hi", decoded.getBytes(3).?);
}

test "protobuf rejects invalid tags and overlong varints" {
    var codec = Protobuf.init(std.testing.allocator);
    var message = Protobuf.Message.init(std.testing.allocator);
    defer message.deinit(std.testing.allocator);

    try std.testing.expectError(error.InvalidFieldNumber, message.addVarint(0, 1));
    try std.testing.expectError(error.InvalidFieldNumber, codec.deserialize(&.{0x00}));
    try std.testing.expectError(error.UnsupportedWireType, codec.deserialize(&.{0x0e}));
    try std.testing.expectError(error.EndOfStream, codec.deserialize(&.{0x80}));
    try std.testing.expectError(error.VarintOverflow, codec.deserialize(&.{
        0x08,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0x02,
    }));
    try std.testing.expectError(error.EndOfStream, codec.deserialize(&.{ 0x0a, 0x02, 0x01 }));
}
