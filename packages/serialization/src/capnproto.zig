const std = @import("std");

/// Cap'n Proto serialization implementation
/// Zero-copy binary format with fast encoding/decoding
/// Designed for efficient inter-process communication
pub const CapnProto = struct {
    allocator: std.mem.Allocator,

    pub const Error = error{
        InvalidPointer,
        InvalidSchema,
        OutOfBounds,
        UnexpectedEndOfInput,
        UnsupportedType,
        IntegerOverflow,
        OutOfMemory,
        InvalidSegment,
        InvalidList,
        InvalidStruct,
    };

    // Cap'n Proto constants
    const POINTER_SIZE: usize = 8; // 64-bit pointers
    const SEGMENT_ALIGNMENT: usize = 8; // 8-byte alignment

    /// Pointer types (2-bit tag)
    pub const PointerType = enum(u2) {
        struct_ptr = 0,
        list_ptr = 1,
        far_ptr = 2,
        other = 3,
    };

    /// List element sizes
    pub const ListElementSize = enum(u3) {
        empty = 0,
        bit = 1,
        byte = 2,
        two_bytes = 3,
        four_bytes = 4,
        eight_bytes = 5,
        pointer = 6,
        inline_composite = 7,
    };

    /// Message structure
    pub const Message = struct {
        segments: [][]u8,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Message {
            return Message{
                .segments = &[_][]u8{},
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Message) void {
            for (self.segments) |segment| {
                self.allocator.free(segment);
            }
            self.allocator.free(self.segments);
        }

        pub fn addSegment(self: *Message, size: usize) !*[]u8 {
            // Align size to 8 bytes
            const aligned_size = std.mem.alignForward(usize, size, SEGMENT_ALIGNMENT);

            const segment = try self.allocator.alloc(u8, aligned_size);
            @memset(segment, 0);

            // Expand segments array
            const new_segments = try self.allocator.realloc(self.segments, self.segments.len + 1);
            self.segments = new_segments;
            self.segments[self.segments.len - 1] = segment;

            return &self.segments[self.segments.len - 1];
        }

        pub fn getSegment(self: *Message, index: usize) ?[]u8 {
            if (index >= self.segments.len) return null;
            return self.segments[index];
        }
    };

    /// Struct builder for constructing Cap'n Proto structures
    pub const StructBuilder = struct {
        message: *Message,
        segment_index: usize,
        offset: usize, // Offset within segment (in 64-bit words)
        data_size: u16, // Data section size in words
        pointer_count: u16, // Number of pointers

        pub fn init(message: *Message, data_size: u16, pointer_count: u16) !StructBuilder {
            const total_size = (@as(usize, data_size) + @as(usize, pointer_count)) * 8;
            const segment = try message.addSegment(total_size);

            return StructBuilder{
                .message = message,
                .segment_index = message.segments.len - 1,
                .offset = 0,
                .data_size = data_size,
                .pointer_count = pointer_count,
            };
        }

        pub fn setUInt8(self: *StructBuilder, offset: usize, value: u8) !void {
            const segment = self.message.getSegment(self.segment_index) orelse return Error.InvalidSegment;
            const byte_offset = self.offset * 8 + offset;
            if (byte_offset >= segment.len) return Error.OutOfBounds;
            segment[byte_offset] = value;
        }

        pub fn setUInt16(self: *StructBuilder, offset: usize, value: u16) !void {
            const segment = self.message.getSegment(self.segment_index) orelse return Error.InvalidSegment;
            const byte_offset = self.offset * 8 + offset;
            if (byte_offset + 2 > segment.len) return Error.OutOfBounds;
            std.mem.writeInt(u16, segment[byte_offset..][0..2], value, .little);
        }

        pub fn setUInt32(self: *StructBuilder, offset: usize, value: u32) !void {
            const segment = self.message.getSegment(self.segment_index) orelse return Error.InvalidSegment;
            const byte_offset = self.offset * 8 + offset;
            if (byte_offset + 4 > segment.len) return Error.OutOfBounds;
            std.mem.writeInt(u32, segment[byte_offset..][0..4], value, .little);
        }

        pub fn setUInt64(self: *StructBuilder, offset: usize, value: u64) !void {
            const segment = self.message.getSegment(self.segment_index) orelse return Error.InvalidSegment;
            const byte_offset = self.offset * 8 + offset;
            if (byte_offset + 8 > segment.len) return Error.OutOfBounds;
            std.mem.writeInt(u64, segment[byte_offset..][0..8], value, .little);
        }

        pub fn setFloat32(self: *StructBuilder, offset: usize, value: f32) !void {
            const int_value: u32 = @bitCast(value);
            try self.setUInt32(offset, int_value);
        }

        pub fn setFloat64(self: *StructBuilder, offset: usize, value: f64) !void {
            const int_value: u64 = @bitCast(value);
            try self.setUInt64(offset, int_value);
        }

        pub fn setPointer(self: *StructBuilder, pointer_index: usize, offset_words: i32, data_size: u16, pointer_count: u16) !void {
            const segment = self.message.getSegment(self.segment_index) orelse return Error.InvalidSegment;
            const pointer_offset = (self.offset + @as(usize, self.data_size)) * 8 + pointer_index * 8;

            if (pointer_offset + 8 > segment.len) return Error.OutOfBounds;

            // Struct pointer format:
            // Bits 0-1: Type (0 = struct)
            // Bits 2-31: Offset (signed, in words from end of pointer)
            // Bits 32-47: Data size (in words)
            // Bits 48-63: Pointer count

            const offset_part: u32 = @bitCast(offset_words << 2);
            const lower: u32 = offset_part | @as(u32, @intFromEnum(PointerType.struct_ptr));
            const upper: u32 = (@as(u32, pointer_count) << 16) | @as(u32, data_size);

            std.mem.writeInt(u32, segment[pointer_offset..][0..4], lower, .little);
            std.mem.writeInt(u32, segment[pointer_offset + 4..][0..4], upper, .little);
        }
    };

    /// Struct reader for reading Cap'n Proto structures
    pub const StructReader = struct {
        segment: []const u8,
        offset: usize, // Offset within segment (in bytes)
        data_size: u16, // Data section size in words
        pointer_count: u16, // Number of pointers

        pub fn init(segment: []const u8, offset: usize, data_size: u16, pointer_count: u16) StructReader {
            return StructReader{
                .segment = segment,
                .offset = offset,
                .data_size = data_size,
                .pointer_count = pointer_count,
            };
        }

        pub fn getUInt8(self: *const StructReader, offset: usize) !u8 {
            const byte_offset = self.offset + offset;
            if (byte_offset >= self.segment.len) return Error.OutOfBounds;
            return self.segment[byte_offset];
        }

        pub fn getUInt16(self: *const StructReader, offset: usize) !u16 {
            const byte_offset = self.offset + offset;
            if (byte_offset + 2 > self.segment.len) return Error.OutOfBounds;
            return std.mem.readInt(u16, self.segment[byte_offset..][0..2], .little);
        }

        pub fn getUInt32(self: *const StructReader, offset: usize) !u32 {
            const byte_offset = self.offset + offset;
            if (byte_offset + 4 > self.segment.len) return Error.OutOfBounds;
            return std.mem.readInt(u32, self.segment[byte_offset..][0..4], .little);
        }

        pub fn getUInt64(self: *const StructReader, offset: usize) !u64 {
            const byte_offset = self.offset + offset;
            if (byte_offset + 8 > self.segment.len) return Error.OutOfBounds;
            return std.mem.readInt(u64, self.segment[byte_offset..][0..8], .little);
        }

        pub fn getFloat32(self: *const StructReader, offset: usize) !f32 {
            const int_value = try self.getUInt32(offset);
            return @bitCast(int_value);
        }

        pub fn getFloat64(self: *const StructReader, offset: usize) !f64 {
            const int_value = try self.getUInt64(offset);
            return @bitCast(int_value);
        }

        pub fn getPointer(self: *const StructReader, pointer_index: usize) !PointerInfo {
            const pointer_offset = self.offset + @as(usize, self.data_size) * 8 + pointer_index * 8;

            if (pointer_offset + 8 > self.segment.len) return Error.OutOfBounds;

            const lower = std.mem.readInt(u32, self.segment[pointer_offset..][0..4], .little);
            const upper = std.mem.readInt(u32, self.segment[pointer_offset + 4..][0..4], .little);

            const pointer_type: PointerType = @enumFromInt(lower & 0x3);
            const offset_words: i32 = @bitCast(lower & 0xFFFFFFFC);
            const offset_signed = offset_words >> 2;

            return PointerInfo{
                .pointer_type = pointer_type,
                .offset = offset_signed,
                .data_size = @intCast(upper & 0xFFFF),
                .pointer_count = @intCast(upper >> 16),
            };
        }
    };

    pub const PointerInfo = struct {
        pointer_type: PointerType,
        offset: i32,
        data_size: u16,
        pointer_count: u16,
    };

    /// List builder for constructing Cap'n Proto lists
    pub const ListBuilder = struct {
        message: *Message,
        segment_index: usize,
        offset: usize,
        element_size: ListElementSize,
        element_count: u32,

        pub fn init(message: *Message, element_size: ListElementSize, element_count: u32) !ListBuilder {
            const element_bytes = switch (element_size) {
                .empty => 0,
                .bit => (element_count + 7) / 8,
                .byte => element_count,
                .two_bytes => element_count * 2,
                .four_bytes => element_count * 4,
                .eight_bytes => element_count * 8,
                .pointer => element_count * 8,
                .inline_composite => element_count * 8, // Simplified
            };

            const segment = try message.addSegment(element_bytes);

            return ListBuilder{
                .message = message,
                .segment_index = message.segments.len - 1,
                .offset = 0,
                .element_size = element_size,
                .element_count = element_count,
            };
        }

        pub fn setUInt32(self: *ListBuilder, index: usize, value: u32) !void {
            if (self.element_size != .four_bytes) return Error.UnsupportedType;
            if (index >= self.element_count) return Error.OutOfBounds;

            const segment = self.message.getSegment(self.segment_index) orelse return Error.InvalidSegment;
            const byte_offset = self.offset + index * 4;

            if (byte_offset + 4 > segment.len) return Error.OutOfBounds;
            std.mem.writeInt(u32, segment[byte_offset..][0..4], value, .little);
        }

        pub fn setUInt64(self: *ListBuilder, index: usize, value: u64) !void {
            if (self.element_size != .eight_bytes) return Error.UnsupportedType;
            if (index >= self.element_count) return Error.OutOfBounds;

            const segment = self.message.getSegment(self.segment_index) orelse return Error.InvalidSegment;
            const byte_offset = self.offset + index * 8;

            if (byte_offset + 8 > segment.len) return Error.OutOfBounds;
            std.mem.writeInt(u64, segment[byte_offset..][0..8], value, .little);
        }
    };

    pub fn init(allocator: std.mem.Allocator) CapnProto {
        return CapnProto{
            .allocator = allocator,
        };
    }

    /// Serialize a message to bytes
    pub fn serialize(self: *CapnProto, message: *Message) ![]u8 {
        // Calculate total size
        var total_size: usize = 8; // Header (segment count + padding)
        for (message.segments) |segment| {
            total_size += 4; // Segment size (in words)
        }
        // Align header to 8 bytes
        total_size = std.mem.alignForward(usize, total_size, 8);

        // Add segment data
        for (message.segments) |segment| {
            total_size += segment.len;
        }

        // Allocate output buffer
        var output = try self.allocator.alloc(u8, total_size);
        var pos: usize = 0;

        // Write segment count - 1
        const segment_count: u32 = @intCast(message.segments.len - 1);
        std.mem.writeInt(u32, output[pos..][0..4], segment_count, .little);
        pos += 8; // Skip padding

        // Write segment sizes (in words)
        for (message.segments) |segment| {
            const size_words: u32 = @intCast(segment.len / 8);
            std.mem.writeInt(u32, output[pos..][0..4], size_words, .little);
            pos += 4;
        }

        // Align to 8 bytes
        pos = std.mem.alignForward(usize, pos, 8);

        // Write segment data
        for (message.segments) |segment| {
            @memcpy(output[pos..][0..segment.len], segment);
            pos += segment.len;
        }

        return output;
    }

    /// Deserialize bytes to a message
    pub fn deserialize(self: *CapnProto, data: []const u8) !Message {
        if (data.len < 8) return Error.UnexpectedEndOfInput;

        var message = Message.init(self.allocator);
        var pos: usize = 0;

        // Read segment count
        const segment_count_minus_one = std.mem.readInt(u32, data[pos..][0..4], .little);
        const segment_count = segment_count_minus_one + 1;
        pos += 8; // Skip padding

        // Read segment sizes
        var segment_sizes = try self.allocator.alloc(usize, segment_count);
        defer self.allocator.free(segment_sizes);

        for (segment_sizes) |*size| {
            if (pos + 4 > data.len) return Error.UnexpectedEndOfInput;
            const size_words = std.mem.readInt(u32, data[pos..][0..4], .little);
            size.* = @as(usize, size_words) * 8;
            pos += 4;
        }

        // Align to 8 bytes
        pos = std.mem.alignForward(usize, pos, 8);

        // Read segment data
        for (segment_sizes) |size| {
            if (pos + size > data.len) return Error.UnexpectedEndOfInput;

            const segment = try self.allocator.alloc(u8, size);
            @memcpy(segment, data[pos..][0..size]);

            // Add to message
            const new_segments = try self.allocator.realloc(message.segments, message.segments.len + 1);
            message.segments = new_segments;
            message.segments[message.segments.len - 1] = segment;

            pos += size;
        }

        return message;
    }
};

test "capnproto struct builder and reader" {
    const allocator = std.testing.allocator;

    var message = CapnProto.Message.init(allocator);
    defer message.deinit();

    // Build a simple struct with 2 words data, 0 pointers
    var builder = try CapnProto.StructBuilder.init(&message, 2, 0);

    try builder.setUInt32(0, 42);
    try builder.setFloat64(8, 3.14159);

    // Read back
    const segment = message.getSegment(0).?;
    const reader = CapnProto.StructReader.init(segment, 0, 2, 0);

    const int_value = try reader.getUInt32(0);
    const float_value = try reader.getFloat64(8);

    try std.testing.expectEqual(@as(u32, 42), int_value);
    try std.testing.expectApproxEqAbs(@as(f64, 3.14159), float_value, 0.00001);
}

test "capnproto list builder" {
    const allocator = std.testing.allocator;

    var message = CapnProto.Message.init(allocator);
    defer message.deinit();

    // Build a list of 5 u32 values
    var list = try CapnProto.ListBuilder.init(&message, .four_bytes, 5);

    try list.setUInt32(0, 10);
    try list.setUInt32(1, 20);
    try list.setUInt32(2, 30);
    try list.setUInt32(3, 40);
    try list.setUInt32(4, 50);

    // Verify
    const segment = message.getSegment(1).?;
    try std.testing.expectEqual(@as(u32, 10), std.mem.readInt(u32, segment[0..4], .little));
    try std.testing.expectEqual(@as(u32, 50), std.mem.readInt(u32, segment[16..20], .little));
}

test "capnproto serialize and deserialize" {
    const allocator = std.testing.allocator;

    var capnp = CapnProto.init(allocator);

    var message = CapnProto.Message.init(allocator);
    defer message.deinit();

    var builder = try CapnProto.StructBuilder.init(&message, 1, 0);
    try builder.setUInt64(0, 12345678);

    const serialized = try capnp.serialize(&message);
    defer allocator.free(serialized);

    var deserialized = try capnp.deserialize(serialized);
    defer deserialized.deinit();

    try std.testing.expectEqual(@as(usize, 1), deserialized.segments.len);

    const segment = deserialized.getSegment(0).?;
    const value = std.mem.readInt(u64, segment[0..8], .little);
    try std.testing.expectEqual(@as(u64, 12345678), value);
}

test "capnproto multiple segments" {
    const allocator = std.testing.allocator;

    var capnp = CapnProto.init(allocator);

    var message = CapnProto.Message.init(allocator);
    defer message.deinit();

    // Create two structs in separate segments
    var builder1 = try CapnProto.StructBuilder.init(&message, 1, 0);
    try builder1.setUInt32(0, 111);

    var builder2 = try CapnProto.StructBuilder.init(&message, 1, 0);
    try builder2.setUInt32(0, 222);

    const serialized = try capnp.serialize(&message);
    defer allocator.free(serialized);

    var deserialized = try capnp.deserialize(serialized);
    defer deserialized.deinit();

    try std.testing.expectEqual(@as(usize, 2), deserialized.segments.len);
}
