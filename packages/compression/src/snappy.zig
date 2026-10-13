const std = @import("std");

/// Snappy compression implementation
/// Fast compression/decompression designed by Google
/// Optimizes for speed over compression ratio
pub const Snappy = struct {
    allocator: std.mem.Allocator,

    pub const Error = error{
        InvalidStream,
        DecompressionFailed,
        OutOfMemory,
        InvalidTag,
        InvalidLength,
        InvalidOffset,
        OutputTooSmall,
        ChecksumMismatch,
    };

    // Snappy constants
    const MAX_HASH_TABLE_BITS: u8 = 14;
    const MAX_HASH_TABLE_SIZE: usize = 1 << MAX_HASH_TABLE_BITS;
    const MIN_MATCH: usize = 4;
    const MAX_OFFSET: usize = 65535;

    // Tag types
    const TAG_LITERAL: u8 = 0x00;
    const TAG_COPY_1_BYTE_OFFSET: u8 = 0x01;
    const TAG_COPY_2_BYTE_OFFSET: u8 = 0x02;
    const TAG_COPY_4_BYTE_OFFSET: u8 = 0x03;

    /// Initialize Snappy compressor
    pub fn init(allocator: std.mem.Allocator) Snappy {
        return Snappy{
            .allocator = allocator,
        };
    }

    /// Compress data using Snappy
    pub fn compress(self: *Snappy, input: []const u8) Error![]u8 {
        var compressor = try SnappyCompressor.init(self.allocator);
        defer compressor.deinit();

        return try compressor.compress(input);
    }

    /// Decompress Snappy-compressed data
    pub fn decompress(self: *Snappy, input: []const u8) Error![]u8 {
        var decompressor = try SnappyDecompressor.init(self.allocator);
        defer decompressor.deinit();

        return try decompressor.decompress(input);
    }

    /// Get maximum compressed size for a given input size
    pub fn maxCompressedLength(input_size: usize) usize {
        // Snappy worst case: 32 + input_size + input_size/6
        return 32 + input_size + input_size / 6;
    }
};

/// Snappy stream compressor
pub const SnappyCompressor = struct {
    allocator: std.mem.Allocator,
    hash_table: []usize,
    output: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) Snappy.Error!SnappyCompressor {
        const hash_table = try allocator.alloc(usize, Snappy.MAX_HASH_TABLE_SIZE);
        @memset(hash_table, std.math.maxInt(usize));

        return SnappyCompressor{
            .allocator = allocator,
            .hash_table = hash_table,
            .output = .empty,
        };
    }

    pub fn deinit(self: *SnappyCompressor) void {
        self.allocator.free(self.hash_table);
        self.output.deinit(self.allocator);
    }

    pub fn compress(self: *SnappyCompressor, input: []const u8) Snappy.Error![]u8 {
        self.output.clearRetainingCapacity();
        @memset(self.hash_table, std.math.maxInt(usize));

        // Write uncompressed length as varint
        try self.writeVarint(input.len);

        if (input.len == 0) {
            return try self.output.toOwnedSlice(self.allocator);
        }

        // Compress the data
        try self.compressBlock(input);

        return try self.output.toOwnedSlice(self.allocator);
    }

    fn compressBlock(self: *SnappyCompressor, input: []const u8) Snappy.Error!void {
        if (input.len < Snappy.MIN_MATCH) {
            // Too small to compress efficiently
            try self.emitLiteral(input);
            return;
        }

        var ip: usize = 0; // Input position
        var next_emit: usize = 0; // Start of next literal to emit

        const input_limit = if (input.len >= 15) input.len - 15 else 0;

        while (ip <= input_limit) {
            // Look for a match
            const match_result = self.findMatch(input, ip);

            if (match_result) |match| {
                // Emit literal before match
                if (next_emit < ip) {
                    try self.emitLiteral(input[next_emit..ip]);
                }

                // Emit copy
                try self.emitCopy(match.offset, match.length);

                // Update position
                ip += match.length;
                next_emit = ip;
            } else {
                // No match, advance
                ip += 1;
            }
        }

        // Emit remaining literals
        if (next_emit < input.len) {
            try self.emitLiteral(input[next_emit..]);
        }
    }

    const Match = struct {
        offset: usize,
        length: usize,
    };

    fn findMatch(self: *SnappyCompressor, input: []const u8, pos: usize) ?Match {
        if (pos + Snappy.MIN_MATCH > input.len) return null;

        // Hash current position
        const hash = self.hashBytes(input, pos);
        const match_pos = self.hash_table[hash];

        // Keep the full source position. The wire offset is still limited to
        // 16 bits below, but truncating the hash-table position would make a
        // later block refer to unrelated input after 64 KiB.
        self.hash_table[hash] = pos;

        if (match_pos == std.math.maxInt(usize)) return null;
        if (pos < match_pos) return null;

        const offset = pos - match_pos;
        if (offset == 0 or offset > Snappy.MAX_OFFSET) return null;

        // Verify minimum match
        if (!self.matchBytes(input, pos, match_pos, Snappy.MIN_MATCH)) {
            return null;
        }

        // Extend match as far as possible
        var match_len = Snappy.MIN_MATCH;
        const max_len = @min(input.len - pos, 64); // Snappy max match length

        while (match_len < max_len and input[pos + match_len] == input[match_pos + match_len]) {
            match_len += 1;
        }

        return Match{
            .offset = offset,
            .length = match_len,
        };
    }

    fn hashBytes(self: *SnappyCompressor, input: []const u8, pos: usize) usize {
        _ = self;
        if (pos + 4 > input.len) return 0;

        const bytes = input[pos..][0..4];
        const value = std.mem.readInt(u32, bytes, .little);
        return ((value *% 0x1e35a7bd) >> 18) & (Snappy.MAX_HASH_TABLE_SIZE - 1);
    }

    fn matchBytes(self: *SnappyCompressor, input: []const u8, pos1: usize, pos2: usize, length: usize) bool {
        _ = self;
        if (pos1 + length > input.len or pos2 + length > input.len) return false;

        return std.mem.eql(u8, input[pos1..][0..length], input[pos2..][0..length]);
    }

    fn emitLiteral(self: *SnappyCompressor, literal: []const u8) Snappy.Error!void {
        const n = literal.len;
        if (n == 0) return;

        if (n < 60) {
            // Short literal (6-bit length)
            const tag: u8 = @intCast((n - 1) << 2);
            try self.output.append(self.allocator, tag);
        } else {
            // Long literal (multi-byte length)
            var tag: u8 = 60 << 2;

            // Determine number of bytes needed for length
            if (n < 256) {
                tag |= 0 << 2;
                try self.output.append(self.allocator, tag);
                try self.output.append(self.allocator, @intCast(n - 1));
            } else if (n < 65536) {
                tag |= 1 << 2;
                try self.output.append(self.allocator, tag);
                try self.output.append(self.allocator, @intCast((n - 1) & 0xFF));
                try self.output.append(self.allocator, @intCast(((n - 1) >> 8) & 0xFF));
            } else if (n < 16777216) {
                tag |= 2 << 2;
                try self.output.append(self.allocator, tag);
                try self.output.append(self.allocator, @intCast((n - 1) & 0xFF));
                try self.output.append(self.allocator, @intCast(((n - 1) >> 8) & 0xFF));
                try self.output.append(self.allocator, @intCast(((n - 1) >> 16) & 0xFF));
            } else {
                tag |= 3 << 2;
                try self.output.append(self.allocator, tag);
                try self.output.append(self.allocator, @intCast((n - 1) & 0xFF));
                try self.output.append(self.allocator, @intCast(((n - 1) >> 8) & 0xFF));
                try self.output.append(self.allocator, @intCast(((n - 1) >> 16) & 0xFF));
                try self.output.append(self.allocator, @intCast(((n - 1) >> 24) & 0xFF));
            }
        }

        try self.output.appendSlice(self.allocator, literal);
    }

    fn emitCopy(self: *SnappyCompressor, offset: usize, length: usize) Snappy.Error!void {
        var remaining = length;

        while (remaining > 0) {
            // Snappy copy length is at most 64
            const copy_len = @min(remaining, 64);

            if (offset < 2048 and copy_len <= 11) {
                // 1-byte offset encoding (11-bit offset, 3-bit length)
                const length_code: u8 = @intCast(copy_len - 4);
                const offset_code: u8 = @intCast(offset >> 8);
                const tag: u8 = Snappy.TAG_COPY_1_BYTE_OFFSET |
                    (length_code * 4) |
                    (offset_code * 32);
                try self.output.append(self.allocator, tag);
                try self.output.append(self.allocator, @intCast(offset & 0xFF));
            } else {
                // 2-byte offset encoding (16-bit offset, 6-bit length)
                const length_code: u8 = @intCast(copy_len - 1);
                const tag: u8 = Snappy.TAG_COPY_2_BYTE_OFFSET | (length_code * 4);
                try self.output.append(self.allocator, tag);
                try self.output.append(self.allocator, @intCast(offset & 0xFF));
                try self.output.append(self.allocator, @intCast((offset >> 8) & 0xFF));
            }

            remaining -= copy_len;
        }
    }

    fn writeVarint(self: *SnappyCompressor, value: usize) !void {
        var v = value;
        while (v >= 128) {
            try self.output.append(self.allocator, @intCast((v & 0x7F) | 0x80));
            v >>= 7;
        }
        try self.output.append(self.allocator, @intCast(v));
    }
};

/// Snappy stream decompressor
pub const SnappyDecompressor = struct {
    allocator: std.mem.Allocator,
    output: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) Snappy.Error!SnappyDecompressor {
        return SnappyDecompressor{
            .allocator = allocator,
            .output = .empty,
        };
    }

    pub fn deinit(self: *SnappyDecompressor) void {
        self.output.deinit(self.allocator);
    }

    pub fn decompress(self: *SnappyDecompressor, input: []const u8) Snappy.Error![]u8 {
        if (input.len == 0) return Snappy.Error.InvalidStream;
        self.output.clearRetainingCapacity();

        // Read uncompressed length
        var pos: usize = 0;
        const uncompressed_len = try self.readVarint(input, &pos);

        // Pre-allocate output, capped relative to the compressed input so
        // a malicious length field can't trigger a huge allocation.
        const prealloc = @min(uncompressed_len, input.len *| 256);
        try self.output.ensureTotalCapacity(self.allocator, prealloc);

        // Decompress
        while (pos < input.len) {
            const tag = input[pos];
            pos += 1;

            const tag_type = tag & 0x03;

            if (tag_type == Snappy.TAG_LITERAL) {
                // Literal
                const literal_len = try self.decodeLiteralLength(input, tag, &pos);

                if (literal_len > input.len - pos) {
                    return Snappy.Error.InvalidStream;
                }
                if (literal_len > uncompressed_len -| self.output.items.len) return Snappy.Error.InvalidLength;

                try self.output.appendSlice(self.allocator, input[pos..][0..literal_len]);
                pos += literal_len;
            } else if (tag_type == Snappy.TAG_COPY_1_BYTE_OFFSET) {
                // 1-byte offset copy
                if (pos >= input.len) return Snappy.Error.InvalidStream;

                const length = 4 + ((tag >> 2) & 0x07);
                const offset = ((@as(usize, tag) & 0xE0) << 3) | input[pos];
                pos += 1;

                try self.emitCopy(offset, length, uncompressed_len);
            } else if (tag_type == Snappy.TAG_COPY_2_BYTE_OFFSET) {
                // 2-byte offset copy
                if (pos + 1 >= input.len) return Snappy.Error.InvalidStream;

                const length = 1 + ((tag >> 2) & 0x3F);
                const offset = @as(usize, input[pos]) | (@as(usize, input[pos + 1]) << 8);
                pos += 2;

                try self.emitCopy(offset, length, uncompressed_len);
            } else if (tag_type == Snappy.TAG_COPY_4_BYTE_OFFSET) {
                if (input.len - pos < 4) return Snappy.Error.InvalidStream;

                const length = 1 + ((tag >> 2) & 0x3f);
                const offset = std.mem.readInt(u32, input[pos..][0..4], .little);
                pos += 4;

                try self.emitCopy(offset, length, uncompressed_len);
            }
        }

        if (self.output.items.len != uncompressed_len) {
            return Snappy.Error.InvalidLength;
        }

        return try self.output.toOwnedSlice(self.allocator);
    }

    fn readVarint(self: *SnappyDecompressor, input: []const u8, pos: *usize) Snappy.Error!usize {
        _ = self;
        var result: usize = 0;
        // Use u8 so `shift += 7` past 63 doesn't panic on u6 overflow —
        // we catch the too-large case via the explicit check below.
        var shift: u8 = 0;

        while (pos.* < input.len) {
            const byte = input[pos.*];
            pos.* += 1;

            const payload = byte & 0x7f;
            if (shift >= @bitSizeOf(usize)) return Snappy.Error.InvalidLength;
            const shift_amount: std.math.Log2Int(usize) = @intCast(shift);
            const payload_value: usize = payload;
            if (payload_value > (@as(usize, std.math.maxInt(usize)) >> shift_amount)) return Snappy.Error.InvalidLength;
            result |= payload_value << shift_amount;

            if ((byte & 0x80) == 0) {
                return result;
            }

            shift += 7;
            if (shift >= @bitSizeOf(usize)) return Snappy.Error.InvalidLength;
        }

        return Snappy.Error.InvalidStream;
    }

    fn decodeLiteralLength(self: *SnappyDecompressor, input: []const u8, tag: u8, pos: *usize) Snappy.Error!usize {
        _ = self;
        const length_bits = tag >> 2;

        if (length_bits < 60) {
            return length_bits + 1;
        }

        const num_bytes = length_bits - 59;
        if (pos.* + num_bytes > input.len) return Snappy.Error.InvalidStream;

        var length: usize = 0;
        for (0..num_bytes) |i| {
            length |= @as(usize, input[pos.* + i]) << @intCast(i * 8);
        }
        pos.* += num_bytes;

        return length + 1;
    }

    fn emitCopy(self: *SnappyDecompressor, offset: usize, length: usize, output_limit: usize) Snappy.Error!void {
        if (offset > self.output.items.len or offset == 0) {
            return Snappy.Error.InvalidOffset;
        }
        if (length > output_limit -| self.output.items.len) return Snappy.Error.InvalidLength;

        const start_pos = self.output.items.len - offset;

        // Handle overlapping copies (when offset < length)
        for (0..length) |i| {
            const byte = self.output.items[start_pos + (i % offset)];
            try self.output.append(self.allocator, byte);
        }
    }
};

test "snappy basic compression and decompression" {
    const allocator = std.testing.allocator;

    var snappy = Snappy.init(allocator);

    const input = "Hello, Snappy! This is a test of the Snappy compression algorithm.";

    const compressed = try snappy.compress(input);
    defer allocator.free(compressed);

    const decompressed = try snappy.decompress(compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualStrings(input, decompressed);
}

test "snappy empty input" {
    const allocator = std.testing.allocator;

    var snappy = Snappy.init(allocator);

    const input = "";
    const compressed = try snappy.compress(input);
    defer allocator.free(compressed);

    const decompressed = try snappy.decompress(compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualStrings(input, decompressed);
}

test "snappy large data" {
    const allocator = std.testing.allocator;

    var snappy = Snappy.init(allocator);

    // Generate large input with patterns
    const input = try allocator.alloc(u8, 100000);
    defer allocator.free(input);

    for (input, 0..) |*byte, i| {
        byte.* = @intCast(i % 256);
    }

    const compressed = try snappy.compress(input);
    defer allocator.free(compressed);

    const decompressed = try snappy.decompress(compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualSlices(u8, input, decompressed);
}

test "snappy repeated patterns" {
    const allocator = std.testing.allocator;

    var snappy = Snappy.init(allocator);

    const pattern = "abcdefgh";
    var input: [pattern.len * 100]u8 = undefined;
    for (0..100) |i| {
        @memcpy(input[i * pattern.len ..][0..pattern.len], pattern);
    }

    const compressed = try snappy.compress(&input);
    defer allocator.free(compressed);

    // Snappy should achieve good compression on repeated patterns
    try std.testing.expect(compressed.len < input.len);

    const decompressed = try snappy.decompress(compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualStrings(&input, decompressed);
}

test "snappy max compressed length" {
    const input_size: usize = 1000;
    const max_compressed = Snappy.maxCompressedLength(input_size);

    // Maximum compressed size should be larger than input
    try std.testing.expect(max_compressed > input_size);

    // But not excessively larger
    try std.testing.expect(max_compressed < input_size * 2);
}

test "snappy incompressible data" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x534e_4150);

    var snappy = Snappy.init(allocator);

    // Generate random data (incompressible)
    var input: [1000]u8 = undefined;
    prng.random().bytes(&input);

    const compressed = try snappy.compress(&input);
    defer allocator.free(compressed);

    const decompressed = try snappy.decompress(compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualSlices(u8, &input, decompressed);
}

test "snappy single byte" {
    const allocator = std.testing.allocator;

    var snappy = Snappy.init(allocator);

    const input = "A";

    const compressed = try snappy.compress(input);
    defer allocator.free(compressed);

    const decompressed = try snappy.decompress(compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualStrings(input, decompressed);
}

test "snappy long repeated sequence" {
    const allocator = std.testing.allocator;

    var snappy = Snappy.init(allocator);

    const input = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";

    const compressed = try snappy.compress(input);
    defer allocator.free(compressed);

    // Should compress very well
    try std.testing.expect(compressed.len < input.len / 2);

    const decompressed = try snappy.decompress(compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualStrings(input, decompressed);
}

test "snappy rejects malformed streams and supports four-byte offsets" {
    const allocator = std.testing.allocator;
    var snappy = Snappy.init(allocator);

    try std.testing.expectError(Snappy.Error.InvalidStream, snappy.decompress(&.{}));
    try std.testing.expectError(Snappy.Error.InvalidStream, snappy.decompress(&.{0x80}));
    try std.testing.expectError(Snappy.Error.InvalidLength, snappy.decompress(&.{ 1, 4, 'A', 'B' }));
    try std.testing.expectError(Snappy.Error.InvalidOffset, snappy.decompress(&.{ 4, 1, 0 }));

    const decoded = try snappy.decompress(&.{ 5, 0, 'A', 15, 1, 0, 0, 0 });
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("AAAAA", decoded);
}
