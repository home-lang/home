// Home Video Library - Bitstream Utilities
// Bit-level reading and writing for codec implementations

const std = @import("std");
const err = @import("../core/error.zig");

pub const VideoError = err.VideoError;

// ============================================================================
// Bitstream Reader
// ============================================================================

/// Read bits from a byte stream (MSB first, like H.264/HEVC)
pub const BitstreamReader = struct {
    data: []const u8,
    byte_pos: usize,
    bit_pos: u4, // 0-7, bits consumed in current byte (use u4 to avoid overflow in calculations)

    const Self = @This();

    pub fn init(data: []const u8) Self {
        return Self{
            .data = data,
            .byte_pos = 0,
            .bit_pos = 0,
        };
    }

    /// Read up to 32 bits
    pub fn readBits(self: *Self, count: u6) !u32 {
        if (count == 0) return 0;
        if (count > 32) return VideoError.InvalidArgument;

        var result: u32 = 0;
        var remaining: u6 = count;

        while (remaining > 0) {
            if (self.byte_pos >= self.data.len) {
                return VideoError.UnexpectedEof;
            }

            const bits_in_byte: u4 = 8 - self.bit_pos;
            const bits_to_read: u4 = @intCast(@min(remaining, bits_in_byte));

            // Extract bits from current byte
            const shift: u3 = @intCast(bits_in_byte - bits_to_read);
            // Use wider type for mask calculation to avoid overflow when bits_to_read == 8
            const mask: u8 = if (bits_to_read >= 8) 0xFF else (@as(u8, 1) << @intCast(bits_to_read)) - 1;
            const bits: u32 = (self.data[self.byte_pos] >> shift) & mask;

            result = (result << @intCast(bits_to_read)) | bits;
            remaining -= @intCast(bits_to_read);

            self.bit_pos += bits_to_read;
            if (self.bit_pos >= 8) {
                self.bit_pos = 0;
                self.byte_pos += 1;
            }
        }

        return result;
    }

    /// Read a single bit
    pub fn readBit(self: *Self) !u1 {
        return @intCast(try self.readBits(1));
    }

    /// Read unsigned Exp-Golomb coded value (H.264/HEVC)
    pub fn readUE(self: *Self) !u32 {
        // Count leading zeros
        var leading_zeros: u32 = 0;
        while (try self.readBit() == 0) {
            leading_zeros += 1;
            if (leading_zeros > 31) return VideoError.InvalidArgument;
        }

        if (leading_zeros == 0) return 0;

        const suffix = try self.readBits(@intCast(leading_zeros));
        return (@as(u32, 1) << @intCast(leading_zeros)) - 1 + suffix;
    }

    /// Read signed Exp-Golomb coded value
    pub fn readSE(self: *Self) !i32 {
        const ue = try self.readUE();
        if (ue & 1 != 0) {
            return @intCast((ue + 1) / 2);
        } else {
            return -@as(i32, @intCast(ue / 2));
        }
    }

    /// Read fixed-length unsigned value
    pub fn readU(self: *Self, comptime T: type) !T {
        const bits = @bitSizeOf(T);
        if (bits <= 32) {
            return @intCast(try self.readBits(@intCast(bits)));
        } else {
            // For 64-bit values
            const high = try self.readBits(32);
            const low = try self.readBits(@intCast(bits - 32));
            return (@as(T, high) << @intCast(bits - 32)) | low;
        }
    }

    /// Peek bits without consuming
    pub fn peekBits(self: *Self, count: u6) !u32 {
        const saved_byte_pos = self.byte_pos;
        const saved_bit_pos = self.bit_pos;

        const result = try self.readBits(count);

        self.byte_pos = saved_byte_pos;
        self.bit_pos = saved_bit_pos;

        return result;
    }

    /// Skip bits
    pub fn skipBits(self: *Self, count: u32) !void {
        var remaining = count;

        while (remaining > 0) {
            const bits_in_byte = @as(u32, 8) - @as(u32, self.bit_pos);

            if (remaining >= bits_in_byte) {
                remaining -= bits_in_byte;
                self.bit_pos = 0;
                self.byte_pos += 1;
            } else {
                self.bit_pos += @intCast(remaining);
                remaining = 0;
            }

            if (self.byte_pos > self.data.len) {
                return VideoError.UnexpectedEof;
            }
        }
    }

    /// Align to byte boundary
    pub fn alignToByte(self: *Self) void {
        if (self.bit_pos != 0) {
            self.bit_pos = 0;
            self.byte_pos += 1;
        }
    }

    /// Check if at byte boundary
    pub fn isByteAligned(self: *Self) bool {
        return self.bit_pos == 0;
    }

    /// Get current bit position
    pub fn getBitPosition(self: *Self) u64 {
        return @as(u64, self.byte_pos) * 8 + @as(u64, self.bit_pos);
    }

    /// Get remaining bits
    pub fn remainingBits(self: *Self) u64 {
        if (self.byte_pos >= self.data.len) return 0;
        return (@as(u64, self.data.len - self.byte_pos) * 8) - @as(u64, self.bit_pos);
    }

    /// Check if more data available
    pub fn hasMoreData(self: *Self) bool {
        return self.byte_pos < self.data.len;
    }

    /// Read byte-aligned bytes
    pub fn readBytes(self: *Self, count: usize) ![]const u8 {
        self.alignToByte();
        if (self.byte_pos + count > self.data.len) {
            return VideoError.UnexpectedEof;
        }
        const result = self.data[self.byte_pos .. self.byte_pos + count];
        self.byte_pos += count;
        return result;
    }
};

// ============================================================================
// Bitstream Writer
// ============================================================================

/// Write bits to a byte stream (MSB first)
pub const BitstreamWriter = struct {
    buffer: std.ArrayList(u8),
    allocator: std.mem.Allocator,
    current_byte: u8,
    bit_pos: u4, // Bits written in current byte (0-7), use u4 to avoid overflow

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .buffer = .empty,
            .allocator = allocator,
            .current_byte = 0,
            .bit_pos = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.buffer.deinit(self.allocator);
    }

    /// Write up to 32 bits
    pub fn writeBits(self: *Self, value: u32, count: u6) !void {
        if (count == 0) return;
        if (count > 32) return VideoError.InvalidArgument;

        var remaining: u6 = count;
        var val = value;

        // Mask off excess bits
        if (count < 32) {
            val &= (@as(u32, 1) << @intCast(count)) - 1;
        }

        while (remaining > 0) {
            const bits_available: u4 = 8 - self.bit_pos;
            const bits_to_write: u4 = @intCast(@min(remaining, bits_available));

            const shift: u6 = remaining - @as(u6, bits_to_write);
            const bits: u8 = @truncate(val >> @intCast(shift));

            const shift_amount: u3 = @intCast(bits_available - bits_to_write);
            self.current_byte |= bits << shift_amount;
            remaining -= @intCast(bits_to_write);

            self.bit_pos += bits_to_write;
            if (self.bit_pos >= 8) {
                try self.buffer.append(self.allocator, self.current_byte);
                self.current_byte = 0;
                self.bit_pos = 0;
            }
        }
    }

    /// Write a single bit
    pub fn writeBit(self: *Self, bit: u1) !void {
        try self.writeBits(bit, 1);
    }

    /// Write unsigned Exp-Golomb coded value
    pub fn writeUE(self: *Self, value: u32) !void {
        if (value == 0) {
            try self.writeBit(1);
            return;
        }

        // Calculate leading zeros needed
        const v = value + 1;
        const leading_zeros = 31 - @clz(v);

        // Write leading zeros
        for (0..leading_zeros) |_| {
            try self.writeBit(0);
        }

        // Write the value with leading 1
        try self.writeBits(v, @intCast(leading_zeros + 1));
    }

    /// Write signed Exp-Golomb coded value
    pub fn writeSE(self: *Self, value: i32) !void {
        const ue: u32 = if (value > 0)
            @intCast(value * 2 - 1)
        else
            @intCast(-value * 2);
        try self.writeUE(ue);
    }

    /// Align to byte boundary (pad with zeros)
    pub fn alignToByte(self: *Self) !void {
        if (self.bit_pos != 0) {
            try self.buffer.append(self.allocator, self.current_byte);
            self.current_byte = 0;
            self.bit_pos = 0;
        }
    }

    /// Align with rbsp_trailing_bits (1 followed by zeros)
    pub fn alignRBSP(self: *Self) !void {
        try self.writeBit(1);
        while (self.bit_pos != 0) {
            try self.writeBit(0);
        }
    }

    /// Write bytes (must be byte-aligned)
    pub fn writeBytes(self: *Self, data: []const u8) !void {
        try self.alignToByte();
        try self.buffer.appendSlice(self.allocator, data);
    }

    /// Get the written data (finalizes the stream)
    pub fn getData(self: *Self) ![]const u8 {
        try self.alignToByte();
        return self.buffer.items;
    }

    /// Get owned data (transfers ownership)
    pub fn toOwnedSlice(self: *Self) ![]u8 {
        try self.alignToByte();
        return self.buffer.toOwnedSlice(self.allocator);
    }

    /// Get current bit position
    pub fn getBitPosition(self: *Self) u64 {
        return @as(u64, self.buffer.items.len) * 8 + @as(u64, self.bit_pos);
    }
};

// ============================================================================
// RBSP (Raw Byte Sequence Payload) for H.264/HEVC
// ============================================================================

/// Remove emulation prevention bytes (0x03 after 0x0000)
pub fn removeEmulationPrevention(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < data.len) {
        if (i + 2 < data.len and data[i] == 0 and data[i + 1] == 0 and data[i + 2] == 3) {
            try result.append(allocator, 0);
            try result.append(allocator, 0);
            i += 3; // Skip the 0x03
        } else {
            try result.append(allocator, data[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Add emulation prevention bytes
pub fn addEmulationPrevention(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var zero_count: u8 = 0;

    for (data) |byte| {
        if (zero_count == 2 and byte <= 3) {
            // Insert emulation prevention byte
            try result.append(allocator, 0x03);
            zero_count = 0;
        }

        try result.append(allocator, byte);

        if (byte == 0) {
            zero_count += 1;
        } else {
            zero_count = 0;
        }
    }

    return result.toOwnedSlice(allocator);
}

// ============================================================================
// NAL Unit Parsing (H.264/HEVC)
// ============================================================================

/// Find start code (0x000001 or 0x00000001)
pub fn findStartCode(data: []const u8) ?struct { pos: usize, len: u8 } {
    if (data.len < 3) return null;

    var i: usize = 0;
    while (i + 2 < data.len) {
        if (data[i] == 0 and data[i + 1] == 0) {
            if (data[i + 2] == 1) {
                return .{ .pos = i, .len = 3 };
            } else if (i + 3 < data.len and data[i + 2] == 0 and data[i + 3] == 1) {
                return .{ .pos = i, .len = 4 };
            }
        }
        i += 1;
    }

    return null;
}

/// Iterator over NAL units in a byte stream
pub const NALUnitIterator = struct {
    data: []const u8,
    pos: usize,

    const Self = @This();

    pub fn init(data: []const u8) Self {
        return Self{
            .data = data,
            .pos = 0,
        };
    }

    pub fn next(self: *Self) ?[]const u8 {
        // Find start code
        const start = findStartCode(self.data[self.pos..]) orelse return null;
        const nal_start = self.pos + start.pos + start.len;

        // Find next start code or end
        const remaining = self.data[nal_start..];
        const end_info = findStartCode(remaining);

        const nal_end = if (end_info) |info|
            nal_start + info.pos
        else
            self.data.len;

        self.pos = nal_end;

        return self.data[nal_start..nal_end];
    }
};

// ============================================================================
// Tests
// ============================================================================

test "BitstreamReader basic" {
    const data = [_]u8{ 0b10110100, 0b01010101 };
    var reader = BitstreamReader.init(&data);

    try std.testing.expectEqual(@as(u32, 1), try reader.readBits(1));
    try std.testing.expectEqual(@as(u32, 0), try reader.readBits(1));
    try std.testing.expectEqual(@as(u32, 0b1101), try reader.readBits(4));
    try std.testing.expectEqual(@as(u32, 0b00), try reader.readBits(2));
}

test "BitstreamReader cross byte" {
    const data = [_]u8{ 0xFF, 0x00 };
    var reader = BitstreamReader.init(&data);

    try std.testing.expectEqual(@as(u32, 0b11111111_0000), try reader.readBits(12));
}

test "BitstreamReader UE" {
    // 1 -> ue(0)
    // 010 -> ue(1)
    // 011 -> ue(2)
    // 00100 -> ue(3)
    const data = [_]u8{ 0b10100110, 0b01000000 };
    var reader = BitstreamReader.init(&data);

    try std.testing.expectEqual(@as(u32, 0), try reader.readUE());
    try std.testing.expectEqual(@as(u32, 1), try reader.readUE());
    try std.testing.expectEqual(@as(u32, 2), try reader.readUE());
    try std.testing.expectEqual(@as(u32, 3), try reader.readUE());
}

test "BitstreamWriter basic" {
    var writer = BitstreamWriter.init(std.testing.allocator);
    defer writer.deinit();

    try writer.writeBits(0b1011, 4);
    try writer.writeBits(0b0100, 4);
    try writer.writeBits(0b01010101, 8);

    const data = try writer.getData();
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0b10110100, 0b01010101 }, data);
}

test "BitstreamWriter UE" {
    var writer = BitstreamWriter.init(std.testing.allocator);
    defer writer.deinit();

    try writer.writeUE(0);
    try writer.writeUE(1);
    try writer.writeUE(2);
    try writer.writeUE(3);

    _ = try writer.getData();
}

test "Emulation prevention" {
    const allocator = std.testing.allocator;

    // Data with emulation prevention byte
    const with_ep = [_]u8{ 0x00, 0x00, 0x03, 0x01 };
    const without_ep = try removeEmulationPrevention(allocator, &with_ep);
    defer allocator.free(without_ep);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00, 0x01 }, without_ep);

    // Add it back
    const original = [_]u8{ 0x00, 0x00, 0x01 };
    const added = try addEmulationPrevention(allocator, &original);
    defer allocator.free(added);

    try std.testing.expectEqualSlices(u8, &with_ep, added);
}

test "NAL unit iterator" {
    const data = [_]u8{ 0x00, 0x00, 0x01, 0x67, 0x42, 0x00, 0x00, 0x01, 0x68, 0x43 };
    var iter = NALUnitIterator.init(&data);

    const nal1 = iter.next();
    try std.testing.expect(nal1 != null);
    try std.testing.expectEqual(@as(u8, 0x67), nal1.?[0]);

    const nal2 = iter.next();
    try std.testing.expect(nal2 != null);
    try std.testing.expectEqual(@as(u8, 0x68), nal2.?[0]);

    const nal3 = iter.next();
    try std.testing.expect(nal3 == null);
}
