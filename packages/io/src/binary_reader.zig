// Binary Reader for Home Language
// Used for parsing binary file formats like W3D
// Compatible with Zig 0.16-dev

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const BinaryReader = struct {
    data: []const u8,
    pos: usize,

    pub fn init(data: []const u8) BinaryReader {
        return .{
            .data = data,
            .pos = 0,
        };
    }

    /// Read bytes into buffer
    pub fn read(self: *BinaryReader, buffer: []u8) !usize {
        const bytes_left = self.data.len - self.pos;
        const to_read = @min(buffer.len, bytes_left);
        if (to_read == 0) return 0;

        @memcpy(buffer[0..to_read], self.data[self.pos..][0..to_read]);
        self.pos += to_read;
        return to_read;
    }

    /// Read all bytes into buffer
    pub fn readAll(self: *BinaryReader, buffer: []u8) !usize {
        return try self.read(buffer);
    }

    /// Read integer with specified endianness
    pub fn readInt(self: *BinaryReader, comptime T: type, endian: std.builtin.Endian) !T {
        const size = @sizeOf(T);
        if (self.pos + size > self.data.len) return error.EndOfStream;

        var bytes: [@sizeOf(T)]u8 = undefined;
        @memcpy(&bytes, self.data[self.pos..][0..size]);
        self.pos += size;

        return std.mem.readInt(T, &bytes, endian);
    }

    /// Read struct from binary data
    pub fn readStruct(self: *BinaryReader, comptime T: type) !T {
        const size = @sizeOf(T);
        if (self.pos + size > self.data.len) return error.EndOfStream;

        var result: T = undefined;
        const bytes = std.mem.asBytes(&result);
        @memcpy(bytes, self.data[self.pos..][0..size]);
        self.pos += size;

        return result;
    }

    /// Read u8
    pub fn readU8(self: *BinaryReader) !u8 {
        return try self.readInt(u8, .little);
    }

    /// Read u16 (little-endian)
    pub fn readU16(self: *BinaryReader) !u16 {
        return try self.readInt(u16, .little);
    }

    /// Read u32 (little-endian)
    pub fn readU32(self: *BinaryReader) !u32 {
        return try self.readInt(u32, .little);
    }

    /// Read u64 (little-endian)
    pub fn readU64(self: *BinaryReader) !u64 {
        return try self.readInt(u64, .little);
    }

    /// Read i8
    pub fn readI8(self: *BinaryReader) !i8 {
        return try self.readInt(i8, .little);
    }

    /// Read i16 (little-endian)
    pub fn readI16(self: *BinaryReader) !i16 {
        return try self.readInt(i16, .little);
    }

    /// Read i32 (little-endian)
    pub fn readI32(self: *BinaryReader) !i32 {
        return try self.readInt(i32, .little);
    }

    /// Read i64 (little-endian)
    pub fn readI64(self: *BinaryReader) !i64 {
        return try self.readInt(i64, .little);
    }

    /// Read f32 (little-endian)
    pub fn readF32(self: *BinaryReader) !f32 {
        const int_val = try self.readU32();
        return @bitCast(int_val);
    }

    /// Read f64 (little-endian)
    pub fn readF64(self: *BinaryReader) !f64 {
        const int_val = try self.readU64();
        return @bitCast(int_val);
    }

    /// Get current position
    pub fn getPos(self: *const BinaryReader) usize {
        return self.pos;
    }

    /// Seek to position
    pub fn seekTo(self: *BinaryReader, pos: usize) !void {
        if (pos > self.data.len) return error.SeekPastEnd;
        self.pos = pos;
    }

    /// Seek by offset (relative)
    pub fn seekBy(self: *BinaryReader, amt: i64) !void {
        if (amt < 0) {
            const abs_amt = @abs(amt);
            if (abs_amt > self.pos) return error.SeekBeforeStart;
            self.pos -= @intCast(abs_amt);
        } else {
            const new_pos = self.pos + @as(usize, @intCast(amt));
            if (new_pos > self.data.len) return error.EndOfStream;
            self.pos = new_pos;
        }
    }

    /// Skip bytes
    pub fn skipBytes(self: *BinaryReader, num_bytes: usize) !void {
        if (self.pos + num_bytes > self.data.len) return error.EndOfStream;
        self.pos += num_bytes;
    }

    /// Check if at end of stream
    pub fn isEof(self: *const BinaryReader) bool {
        return self.pos >= self.data.len;
    }

    /// Get remaining bytes
    pub fn remaining(self: *const BinaryReader) usize {
        return self.data.len - self.pos;
    }

    /// Read null-terminated string
    pub fn readCString(self: *BinaryReader, allocator: Allocator, max_len: usize) ![]u8 {
        const start = self.pos;
        var len: usize = 0;

        while (self.pos < self.data.len and len < max_len) : ({
            self.pos += 1;
            len += 1;
        }) {
            if (self.data[self.pos] == 0) {
                self.pos += 1; // Skip null terminator
                break;
            }
        }

        if (len == 0) return try allocator.dupe(u8, "");
        return try allocator.dupe(u8, self.data[start..][0..len]);
    }

    /// Read fixed-length string
    pub fn readFixedString(self: *BinaryReader, allocator: Allocator, len: usize) ![]u8 {
        if (self.pos + len > self.data.len) return error.EndOfStream;

        const str = try allocator.dupe(u8, self.data[self.pos..][0..len]);
        self.pos += len;

        // Find null terminator if present
        const null_pos = std.mem.indexOfScalar(u8, str, 0);
        if (null_pos) |pos| {
            return str[0..pos];
        }

        return str;
    }

    /// Read array of type T
    pub fn readArray(self: *BinaryReader, comptime T: type, allocator: Allocator, count: usize) ![]T {
        const array = try allocator.alloc(T, count);
        errdefer allocator.free(array);

        for (array) |*item| {
            item.* = try self.readStruct(T);
        }

        return array;
    }
};

// Tests
test "BinaryReader - basic reading" {
    const data = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    var reader = BinaryReader.init(&data);

    const byte1 = try reader.readU8();
    try std.testing.expectEqual(@as(u8, 0x01), byte1);

    const byte2 = try reader.readU8();
    try std.testing.expectEqual(@as(u8, 0x02), byte2);

    try std.testing.expectEqual(@as(usize, 2), reader.getPos());
}

test "BinaryReader - integers" {
    const data = [_]u8{ 0x01, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00 };
    var reader = BinaryReader.init(&data);

    const val1 = try reader.readU32();
    try std.testing.expectEqual(@as(u32, 1), val1);

    const val2 = try reader.readU32();
    try std.testing.expectEqual(@as(u32, 2), val2);
}

test "BinaryReader - seeking" {
    const data = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05 };
    var reader = BinaryReader.init(&data);

    try reader.seekTo(2);
    const val = try reader.readU8();
    try std.testing.expectEqual(@as(u8, 0x03), val);

    try reader.seekBy(-2);
    const val2 = try reader.readU8();
    try std.testing.expectEqual(@as(u8, 0x02), val2);
}

test "BinaryReader - float" {
    // 1.0 as f32 in little-endian bytes
    const data = [_]u8{ 0x00, 0x00, 0x80, 0x3F };
    var reader = BinaryReader.init(&data);

    const val = try reader.readF32();
    try std.testing.expectEqual(@as(f32, 1.0), val);
}
