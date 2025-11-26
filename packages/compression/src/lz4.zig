const std = @import("std");

/// LZ4 compression implementation
/// Extremely fast compression/decompression with reasonable compression ratios
/// LZ4 is designed for real-time compression scenarios
pub const LZ4 = struct {
    allocator: std.mem.Allocator,
    acceleration: u32, // 1 = default, >1 = faster but less compression

    pub const Error = error{
        InvalidStream,
        DecompressionFailed,
        OutOfMemory,
        InvalidToken,
        InvalidOffset,
        OutputTooSmall,
    };

    // LZ4 constants
    const MIN_MATCH: usize = 4;
    const LAST_LITERALS: usize = 5;
    const MFLIMIT: usize = 12;
    const HASH_SIZE_U32: usize = 1 << 16;
    const MAX_DISTANCE: usize = 65535;
    const ML_BITS: u8 = 4;
    const ML_MASK: u8 = (1 << ML_BITS) - 1;
    const RUN_BITS: u8 = 8 - ML_BITS;
    const RUN_MASK: u8 = (1 << RUN_BITS) - 1;

    /// Initialize LZ4 compressor
    /// acceleration: 1 = default, higher values trade compression for speed
    pub fn init(allocator: std.mem.Allocator, acceleration: u32) LZ4 {
        return LZ4{
            .allocator = allocator,
            .acceleration = if (acceleration == 0) 1 else acceleration,
        };
    }

    /// Compress data using LZ4
    pub fn compress(self: *LZ4, input: []const u8) Error![]u8 {
        var compressor = try LZ4Compressor.init(self.allocator, self.acceleration);
        defer compressor.deinit();

        return try compressor.compress(input);
    }

    /// Decompress LZ4-compressed data
    pub fn decompress(self: *LZ4, input: []const u8) Error![]u8 {
        var decompressor = try LZ4Decompressor.init(self.allocator);
        defer decompressor.deinit();

        return try decompressor.decompress(input);
    }

    /// Get maximum compressed size for a given input size
    pub fn compressBound(input_size: usize) usize {
        // LZ4 worst case: input + (input / 255) + 16
        return input_size + (input_size / 255) + 16;
    }
};

/// LZ4 stream compressor
pub const LZ4Compressor = struct {
    allocator: std.mem.Allocator,
    acceleration: u32,
    hash_table: []u32,
    output: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator, acceleration: u32) LZ4.Error!LZ4Compressor {
        const hash_table = try allocator.alloc(u32, LZ4.HASH_SIZE_U32);
        @memset(hash_table, 0);

        return LZ4Compressor{
            .allocator = allocator,
            .acceleration = acceleration,
            .hash_table = hash_table,
            .output = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *LZ4Compressor) void {
        self.allocator.free(self.hash_table);
        self.output.deinit();
    }

    pub fn compress(self: *LZ4Compressor, input: []const u8) LZ4.Error![]u8 {
        if (input.len == 0) {
            return try self.output.toOwnedSlice();
        }

        // Write uncompressed size as header
        try self.writeU32(input.len);

        // Compress the data
        try self.compressBlock(input);

        return try self.output.toOwnedSlice();
    }

    fn compressBlock(self: *LZ4Compressor, input: []const u8) LZ4.Error!void {
        if (input.len < LZ4.MFLIMIT) {
            // Too small to compress, store as literals
            try self.storeLiterals(input);
            return;
        }

        var ip: usize = 0; // Input position
        const anchor = 0; // Start of current literal run
        var current_anchor = anchor;

        const input_end = input.len;
        const match_limit = input_end - LZ4.LAST_LITERALS;

        // Main compression loop
        while (ip < match_limit) {
            // Find match
            const match_result = self.findMatch(input, ip);

            if (match_result) |match| {
                // Encode literals before match
                const literal_length = ip - current_anchor;
                try self.encodeSequence(
                    input[current_anchor..ip],
                    match.length,
                    match.offset,
                );

                // Move past the match
                ip += match.length;
                current_anchor = ip;
            } else {
                // No match found, move forward
                ip += 1 + (ip - current_anchor) / self.acceleration;
            }
        }

        // Encode remaining literals
        const remaining = input[current_anchor..];
        if (remaining.len > 0) {
            try self.storeLiterals(remaining);
        }
    }

    const Match = struct {
        offset: u32,
        length: usize,
    };

    fn findMatch(self: *LZ4Compressor, input: []const u8, pos: usize) ?Match {
        if (pos + LZ4.MIN_MATCH > input.len) return null;

        // Hash current position
        const hash = self.hashPosition(input, pos);
        const match_pos = self.hash_table[hash];

        // Update hash table
        self.hash_table[hash] = @intCast(pos);

        // Check if match is valid
        if (match_pos == 0) return null;
        if (pos < match_pos) return null;

        const offset = pos - match_pos;
        if (offset == 0 or offset > LZ4.MAX_DISTANCE) return null;

        // Verify match
        if (!self.matchesAtPosition(input, pos, match_pos, LZ4.MIN_MATCH)) {
            return null;
        }

        // Extend match
        var match_len = LZ4.MIN_MATCH;
        const max_len = @min(input.len - pos, 65535 + LZ4.MIN_MATCH);

        while (match_len < max_len and
               match_pos + match_len < pos and
               input[pos + match_len] == input[match_pos + match_len]) {
            match_len += 1;
        }

        return Match{
            .offset = @intCast(offset),
            .length = match_len,
        };
    }

    fn hashPosition(self: *LZ4Compressor, input: []const u8, pos: usize) usize {
        _ = self;
        if (pos + 4 > input.len) return 0;

        const value = std.mem.readInt(u32, input[pos..][0..4], .little);
        return ((value *% 2654435761) >> 16) & (LZ4.HASH_SIZE_U32 - 1);
    }

    fn matchesAtPosition(self: *LZ4Compressor, input: []const u8, pos1: usize, pos2: usize, length: usize) bool {
        _ = self;
        if (pos1 + length > input.len or pos2 + length > input.len) return false;

        for (0..length) |i| {
            if (input[pos1 + i] != input[pos2 + i]) return false;
        }
        return true;
    }

    fn encodeSequence(self: *LZ4Compressor, literals: []const u8, match_length: usize, offset: u32) LZ4.Error!void {
        // Calculate match length minus MIN_MATCH
        const ml = match_length - LZ4.MIN_MATCH;

        // Encode token
        const literal_length = literals.len;
        var token: u8 = 0;

        // Literal length in token (4 bits)
        if (literal_length < 15) {
            token = @intCast(literal_length << 4);
        } else {
            token = 15 << 4;
        }

        // Match length in token (4 bits)
        if (ml < 15) {
            token |= @intCast(ml);
        } else {
            token |= 15;
        }

        try self.output.append(token);

        // Encode extra literal length if needed
        if (literal_length >= 15) {
            var remaining = literal_length - 15;
            while (remaining >= 255) {
                try self.output.append(255);
                remaining -= 255;
            }
            try self.output.append(@intCast(remaining));
        }

        // Write literals
        try self.output.appendSlice(literals);

        // Write offset (little-endian)
        try self.output.append(@intCast(offset & 0xFF));
        try self.output.append(@intCast((offset >> 8) & 0xFF));

        // Encode extra match length if needed
        if (ml >= 15) {
            var remaining = ml - 15;
            while (remaining >= 255) {
                try self.output.append(255);
                remaining -= 255;
            }
            try self.output.append(@intCast(remaining));
        }
    }

    fn storeLiterals(self: *LZ4Compressor, literals: []const u8) LZ4.Error!void {
        if (literals.len == 0) return;

        // Token with only literals (no match)
        var token: u8 = 0;
        const literal_length = literals.len;

        if (literal_length < 15) {
            token = @intCast(literal_length << 4);
        } else {
            token = 15 << 4;
        }

        try self.output.append(token);

        // Encode extra literal length if needed
        if (literal_length >= 15) {
            var remaining = literal_length - 15;
            while (remaining >= 255) {
                try self.output.append(255);
                remaining -= 255;
            }
            try self.output.append(@intCast(remaining));
        }

        // Write literals
        try self.output.appendSlice(literals);
    }

    fn writeU32(self: *LZ4Compressor, value: usize) !void {
        const val: u32 = @intCast(value);
        try self.output.append(@intCast(val & 0xFF));
        try self.output.append(@intCast((val >> 8) & 0xFF));
        try self.output.append(@intCast((val >> 16) & 0xFF));
        try self.output.append(@intCast((val >> 24) & 0xFF));
    }
};

/// LZ4 stream decompressor
pub const LZ4Decompressor = struct {
    allocator: std.mem.Allocator,
    output: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) LZ4.Error!LZ4Decompressor {
        return LZ4Decompressor{
            .allocator = allocator,
            .output = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *LZ4Decompressor) void {
        self.output.deinit();
    }

    pub fn decompress(self: *LZ4Decompressor, input: []const u8) LZ4.Error![]u8 {
        if (input.len < 4) return LZ4.Error.InvalidStream;

        // Read uncompressed size
        const uncompressed_size = self.readU32(input[0..4]);

        // Pre-allocate output buffer
        try self.output.ensureTotalCapacity(uncompressed_size);

        // Decompress
        var ip: usize = 4; // Skip size header

        while (ip < input.len) {
            // Read token
            const token = input[ip];
            ip += 1;

            // Decode literal length
            var literal_length: usize = @intCast(token >> 4);
            if (literal_length == 15) {
                while (ip < input.len) {
                    const extra = input[ip];
                    ip += 1;
                    literal_length += extra;
                    if (extra != 255) break;
                }
            }

            // Copy literals
            if (ip + literal_length > input.len) {
                return LZ4.Error.InvalidStream;
            }
            try self.output.appendSlice(input[ip..][0..literal_length]);
            ip += literal_length;

            // Check if we're done
            if (ip >= input.len) break;

            // Read offset
            if (ip + 2 > input.len) return LZ4.Error.InvalidStream;
            const offset = @as(u32, input[ip]) | (@as(u32, input[ip + 1]) << 8);
            ip += 2;

            if (offset == 0 or offset > self.output.items.len) {
                return LZ4.Error.InvalidOffset;
            }

            // Decode match length
            var match_length: usize = @intCast(token & LZ4.ML_MASK);
            if (match_length == 15) {
                while (ip < input.len) {
                    const extra = input[ip];
                    ip += 1;
                    match_length += extra;
                    if (extra != 255) break;
                }
            }
            match_length += LZ4.MIN_MATCH;

            // Copy match
            const match_pos = self.output.items.len - offset;
            for (0..match_length) |i| {
                const byte = self.output.items[match_pos + (i % offset)];
                try self.output.append(byte);
            }
        }

        return try self.output.toOwnedSlice();
    }

    fn readU32(self: *LZ4Decompressor, bytes: []const u8) usize {
        _ = self;
        return @as(usize, bytes[0]) |
               (@as(usize, bytes[1]) << 8) |
               (@as(usize, bytes[2]) << 16) |
               (@as(usize, bytes[3]) << 24);
    }
};

test "lz4 basic compression and decompression" {
    const allocator = std.testing.allocator;

    var lz4 = LZ4.init(allocator, 1);

    const input = "Hello, LZ4! This is a test of the LZ4 compression algorithm.";

    const compressed = try lz4.compress(input);
    defer allocator.free(compressed);

    const decompressed = try lz4.decompress(compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualStrings(input, decompressed);
}

test "lz4 empty input" {
    const allocator = std.testing.allocator;

    var lz4 = LZ4.init(allocator, 1);

    const input = "";
    const compressed = try lz4.compress(input);
    defer allocator.free(compressed);

    const decompressed = try lz4.decompress(compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualStrings(input, decompressed);
}

test "lz4 acceleration levels" {
    const allocator = std.testing.allocator;

    const input = "The quick brown fox jumps over the lazy dog. " ** 10;

    // Test different acceleration levels
    for (1..5) |accel| {
        var lz4 = LZ4.init(allocator, @intCast(accel));

        const compressed = try lz4.compress(input);
        defer allocator.free(compressed);

        const decompressed = try lz4.decompress(compressed);
        defer allocator.free(decompressed);

        try std.testing.expectEqualStrings(input, decompressed);
    }
}

test "lz4 large data" {
    const allocator = std.testing.allocator;

    var lz4 = LZ4.init(allocator, 1);

    // Generate large input with patterns
    var input = try allocator.alloc(u8, 100000);
    defer allocator.free(input);

    for (input, 0..) |*byte, i| {
        byte.* = @intCast(i % 256);
    }

    const compressed = try lz4.compress(input);
    defer allocator.free(compressed);

    const decompressed = try lz4.decompress(compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualSlices(u8, input, decompressed);
}

test "lz4 repeated patterns" {
    const allocator = std.testing.allocator;

    var lz4 = LZ4.init(allocator, 1);

    const input = "abcdefgh" ** 100;

    const compressed = try lz4.compress(input);
    defer allocator.free(compressed);

    // LZ4 should achieve good compression on repeated patterns
    try std.testing.expect(compressed.len < input.len);

    const decompressed = try lz4.decompress(compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualStrings(input, decompressed);
}

test "lz4 compress bound" {
    const input_size: usize = 1000;
    const max_compressed = LZ4.compressBound(input_size);

    // Maximum compressed size should be larger than input
    try std.testing.expect(max_compressed > input_size);

    // But not excessively larger
    try std.testing.expect(max_compressed < input_size * 2);
}

test "lz4 incompressible data" {
    const allocator = std.testing.allocator;
    const random = std.crypto.random;

    var lz4 = LZ4.init(allocator, 1);

    // Generate random data (incompressible)
    var input: [1000]u8 = undefined;
    random.bytes(&input);

    const compressed = try lz4.compress(&input);
    defer allocator.free(compressed);

    const decompressed = try lz4.decompress(compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualSlices(u8, &input, decompressed);
}
