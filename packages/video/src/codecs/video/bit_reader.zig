//! Home allocation-free MSB-first codec reader. Failed reads leave the cursor unchanged.
//! Exp-Golomb values are limited to at most 31 leading zeros.
const std = @import("std");

pub const Reader = struct {
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
        if (count > 32) return error.InvalidArgument;
        if (count > self.remainingBits()) return error.UnexpectedEof;

        var result: u32 = 0;
        var remaining: u6 = count;

        while (remaining > 0) {
            if (self.byte_pos >= self.data.len) {
                return error.UnexpectedEof;
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
        var cursor = self.*;
        const value = try cursor.readUnsignedExpGolomb();
        self.* = cursor;
        return value;
    }

    fn readUnsignedExpGolomb(self: *Self) !u32 {
        // Count leading zeros
        var leading_zeros: u32 = 0;
        while (try self.readBit() == 0) {
            leading_zeros += 1;
            if (leading_zeros > 31) return error.InvalidArgument;
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
        if (bits > 64) @compileError("readU supports at most 64 bits");
        if (bits > self.remainingBits()) return error.UnexpectedEof;
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

        defer {
            self.byte_pos = saved_byte_pos;
            self.bit_pos = saved_bit_pos;
        }
        return self.readBits(count);
    }

    /// Skip bits
    pub fn skipBits(self: *Self, count: u32) !void {
        if (count > self.remainingBits()) return error.UnexpectedEof;
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
                return error.UnexpectedEof;
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
        const at = self.byte_pos + @as(usize, @intFromBool(self.bit_pos != 0));
        if (at > self.data.len or count > self.data.len - at) return error.UnexpectedEof;
        self.alignToByte();
        const result = self.data[self.byte_pos .. self.byte_pos + count];
        self.byte_pos += count;
        return result;
    }
};

test "reader failed reads are atomic at byte and bit boundaries" {
    const t = std.testing;
    var r = Reader.init(&.{0x81});
    try t.expectEqual(@as(u32, 1), try r.readBits(1));
    const at = r.getBitPosition();
    try t.expectError(error.UnexpectedEof, r.readBits(8));
    try t.expectError(error.UnexpectedEof, r.peekBits(8));
    try t.expectError(error.UnexpectedEof, r.skipBits(8));
    try t.expectError(error.UnexpectedEof, r.readBytes(1));
    try t.expectError(error.UnexpectedEof, r.readBytes(std.math.maxInt(usize)));
    try t.expectEqual(at, r.getBitPosition());
    try t.expectEqual(@as(u32, 1), try r.readBits(7));
    try t.expectEqual(@as(u64, 0), r.remainingBits());
    try t.expectEqual(@as(u32, 0), try r.readBits(0));
    try t.expectError(error.InvalidArgument, r.readBits(33));
}

test "reader Exp-Golomb boundaries, truncation and legacy fixed-width reads" {
    const t = std.testing;
    var r = Reader.init(&.{0});
    try t.expectError(error.UnexpectedEof, r.readUE());
    try t.expectEqual(@as(u64, 0), r.getBitPosition());
    var overflow = Reader.init(&.{ 0, 0, 0, 0, 0x80 });
    try t.expectError(error.InvalidArgument, overflow.readUE());
    try t.expectEqual(@as(u64, 0), overflow.getBitPosition());
    var maximum = Reader.init(&.{ 0, 0, 0, 1, 0xff, 0xff, 0xff, 0xfe });
    try t.expectEqual(@as(u32, 0xfffffffe), try maximum.readUE());
    maximum = Reader.init(&.{ 0, 0, 0, 1, 0xff, 0xff, 0xff, 0xfe });
    try t.expectEqual(@as(i32, -2147483647), try maximum.readSE());
    var fixed = Reader.init(&.{ 1, 2, 3, 4, 5, 6, 7, 8 });
    try t.expectEqual(@as(u64, 0x0102030405060708), try fixed.readU(u64));
    var aligned = Reader.init(&.{ 0x80, 42 });
    _ = try aligned.readBit();
    try t.expectEqualSlices(u8, &.{42}, try aligned.readBytes(1));
}

test "wide fixed reads reject atomically before consuming the high word" {
    var r = Reader.init(&.{ 1, 2, 3, 4, 5 });
    try std.testing.expectError(error.UnexpectedEof, r.readU(u64));
    try std.testing.expectEqual(@as(u64, 0), r.getBitPosition());
}
