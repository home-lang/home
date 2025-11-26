const std = @import("std");

/// Brotli compression implementation (RFC 7932)
/// Modern compression algorithm with excellent compression ratios
/// and fast decompression speeds
pub const Brotli = struct {
    allocator: std.mem.Allocator,
    quality: u4, // 0-11, where 11 is best compression
    window_size: u5, // 10-24, window size = 2^window_size - 16

    pub const Error = error{
        InvalidQuality,
        InvalidWindowSize,
        InvalidStream,
        DecompressionFailed,
        OutOfMemory,
        InvalidMetablock,
        InvalidDistance,
        InvalidLiteral,
    };

    /// Initialize Brotli compressor
    pub fn init(allocator: std.mem.Allocator, quality: u4, window_size: u5) Error!Brotli {
        if (quality > 11) return Error.InvalidQuality;
        if (window_size < 10 or window_size > 24) return Error.InvalidWindowSize;

        return Brotli{
            .allocator = allocator,
            .quality = quality,
            .window_size = window_size,
        };
    }

    /// Compress data using Brotli
    pub fn compress(self: *Brotli, input: []const u8) Error![]u8 {
        var compressor = try BrotliCompressor.init(self.allocator, self.quality, self.window_size);
        defer compressor.deinit();

        return try compressor.compress(input);
    }

    /// Decompress Brotli-compressed data
    pub fn decompress(self: *Brotli, input: []const u8) Error![]u8 {
        var decompressor = try BrotliDecompressor.init(self.allocator);
        defer decompressor.deinit();

        return try decompressor.decompress(input);
    }
};

/// Brotli stream compressor for incremental compression
pub const BrotliCompressor = struct {
    allocator: std.mem.Allocator,
    quality: u4,
    window_size: u5,
    output: std.ArrayList(u8),
    ring_buffer: []u8,
    ring_buffer_pos: usize,
    literal_cost_model: LiteralCostModel,
    distance_cache: [4]u32,

    const LiteralCostModel = struct {
        costs: [256]f32,

        fn init() LiteralCostModel {
            var model = LiteralCostModel{
                .costs = undefined,
            };
            // Initialize with uniform costs
            for (&model.costs) |*cost| {
                cost.* = 8.0; // 8 bits per byte
            }
            return model;
        }

        fn update(self: *LiteralCostModel, data: []const u8) void {
            var counts = [_]u32{0} ** 256;
            for (data) |byte| {
                counts[byte] += 1;
            }

            // Calculate costs based on frequency (Shannon entropy)
            const total = @as(f32, @floatFromInt(data.len));
            for (0..256) |i| {
                if (counts[i] > 0) {
                    const freq = @as(f32, @floatFromInt(counts[i])) / total;
                    self.costs[i] = -@log2(freq);
                } else {
                    self.costs[i] = 16.0; // High cost for unseen bytes
                }
            }
        }
    };

    pub fn init(allocator: std.mem.Allocator, quality: u4, window_size: u5) Brotli.Error!BrotliCompressor {
        const window_bytes = @as(usize, 1) << @intCast(window_size);
        const ring_buffer = try allocator.alloc(u8, window_bytes);

        return BrotliCompressor{
            .allocator = allocator,
            .quality = quality,
            .window_size = window_size,
            .output = std.ArrayList(u8).init(allocator),
            .ring_buffer = ring_buffer,
            .ring_buffer_pos = 0,
            .literal_cost_model = LiteralCostModel.init(),
            .distance_cache = [_]u32{4, 11, 15, 16},
        };
    }

    pub fn deinit(self: *BrotliCompressor) void {
        self.allocator.free(self.ring_buffer);
        self.output.deinit();
    }

    /// Compress input data
    pub fn compress(self: *BrotliCompressor, input: []const u8) Brotli.Error![]u8 {
        // Write Brotli stream header
        try self.writeStreamHeader();

        // Update cost model based on input
        self.literal_cost_model.update(input);

        // Process input in blocks
        const block_size = @min(1 << 20, input.len); // 1MB blocks
        var offset: usize = 0;

        while (offset < input.len) {
            const chunk_size = @min(block_size, input.len - offset);
            const chunk = input[offset..][0..chunk_size];
            const is_last = (offset + chunk_size >= input.len);

            try self.compressBlock(chunk, is_last);
            offset += chunk_size;
        }

        // Return owned slice
        return try self.output.toOwnedSlice();
    }

    fn writeStreamHeader(self: *BrotliCompressor) !void {
        // Brotli stream header: window size in bits 0-5
        const wbits = @as(u8, self.window_size - 10);
        try self.output.append(wbits);
    }

    fn compressBlock(self: *BrotliCompressor, data: []const u8, is_last: bool) !void {
        // Write metablock header
        try self.writeMetablockHeader(data.len, is_last);

        // Find matches using LZ77-style compression
        var matches = std.ArrayList(Match).init(self.allocator);
        defer matches.deinit();

        try self.findMatches(data, &matches);

        // Encode literals and matches
        try self.encodeCommands(data, matches.items);

        // Update ring buffer
        for (data) |byte| {
            self.ring_buffer[self.ring_buffer_pos] = byte;
            self.ring_buffer_pos = (self.ring_buffer_pos + 1) % self.ring_buffer.len;
        }
    }

    const Match = struct {
        length: usize,
        distance: u32,
        position: usize,
    };

    fn writeMetablockHeader(self: *BrotliCompressor, data_len: usize, is_last: bool) !void {
        // Simplified metablock header
        // In production, this would encode:
        // - ISLAST bit
        // - ISLASTEMPTY bit (if ISLAST)
        // - MNIBBLES (number of nibbles in data length)
        // - MLEN (data length)
        // - ISUNCOMPRESSED bit

        var header: u8 = 0;
        if (is_last) header |= 0x01;
        if (data_len == 0 and is_last) header |= 0x02;

        try self.output.append(header);

        // Write data length (simplified)
        if (data_len > 0) {
            try self.writeVarInt(data_len);
        }
    }

    fn writeVarInt(self: *BrotliCompressor, value: usize) !void {
        var val = value;
        while (val >= 128) {
            try self.output.append(@intCast((val & 0x7F) | 0x80));
            val >>= 7;
        }
        try self.output.append(@intCast(val));
    }

    fn findMatches(self: *BrotliCompressor, data: []const u8, matches: *std.ArrayList(Match)) !void {
        if (data.len < 4) return;

        // Hash table for finding matches
        const hash_size = 1 << 15;
        var hash_table = try self.allocator.alloc(u32, hash_size);
        defer self.allocator.free(hash_table);
        @memset(hash_table, 0xFFFFFFFF);

        var pos: usize = 0;
        while (pos < data.len) {
            // Only look for matches if quality is high enough
            if (self.quality < 4) {
                pos += 1;
                continue;
            }

            // Calculate hash of current position
            if (pos + 4 > data.len) break;
            const hash = self.hashBytes(data[pos..][0..4]) % hash_size;

            // Check for match
            const match_pos = hash_table[hash];
            if (match_pos != 0xFFFFFFFF and pos > match_pos) {
                const distance = @as(u32, @intCast(pos - match_pos));
                if (distance <= self.ring_buffer.len) {
                    // Find match length
                    const max_len = @min(data.len - pos, 262); // Max match length in Brotli
                    var match_len: usize = 0;

                    while (match_len < max_len and
                           match_pos + match_len < pos and
                           data[pos + match_len] == data[match_pos + match_len]) {
                        match_len += 1;
                    }

                    // Only use match if it's beneficial (length >= 4)
                    if (match_len >= 4) {
                        try matches.append(Match{
                            .length = match_len,
                            .distance = distance,
                            .position = pos,
                        });

                        // Skip matched bytes
                        for (0..match_len) |i| {
                            if (pos + i + 4 <= data.len) {
                                const skip_hash = self.hashBytes(data[pos + i..][0..4]) % hash_size;
                                hash_table[skip_hash] = @intCast(pos + i);
                            }
                        }

                        pos += match_len;
                        continue;
                    }
                }
            }

            // Update hash table
            hash_table[hash] = @intCast(pos);
            pos += 1;
        }
    }

    fn hashBytes(self: *BrotliCompressor, bytes: []const u8) u32 {
        _ = self;
        var hash: u32 = 0;
        for (bytes) |byte| {
            hash = hash *% 31 +% byte;
        }
        return hash;
    }

    fn encodeCommands(self: *BrotliCompressor, data: []const u8, matches: []const Match) !void {
        var pos: usize = 0;
        var match_idx: usize = 0;

        while (pos < data.len) {
            // Check if there's a match at this position
            const has_match = match_idx < matches.len and matches[match_idx].position == pos;

            if (has_match) {
                const match = matches[match_idx];

                // Encode copy command (distance + length)
                try self.encodeCopyCommand(match.distance, match.length);

                pos += match.length;
                match_idx += 1;
            } else {
                // Encode literal
                try self.encodeLiteral(data[pos]);
                pos += 1;
            }
        }
    }

    fn encodeLiteral(self: *BrotliCompressor, byte: u8) !void {
        // Simplified literal encoding
        // In production, this would use context modeling and Huffman coding
        try self.output.append(0x00); // Literal marker
        try self.output.append(byte);
    }

    fn encodeCopyCommand(self: *BrotliCompressor, distance: u32, length: usize) !void {
        // Simplified copy command encoding
        // In production, this would use:
        // - Command codes (combining insert and copy lengths)
        // - Distance codes with context
        // - Extra bits for long distances/lengths

        try self.output.append(0x01); // Copy marker
        try self.writeVarInt(length);
        try self.writeVarInt(distance);
    }
};

/// Brotli stream decompressor for incremental decompression
pub const BrotliDecompressor = struct {
    allocator: std.mem.Allocator,
    output: std.ArrayList(u8),
    ring_buffer: std.ArrayList(u8),
    window_size: u5,

    pub fn init(allocator: std.mem.Allocator) Brotli.Error!BrotliDecompressor {
        return BrotliDecompressor{
            .allocator = allocator,
            .output = std.ArrayList(u8).init(allocator),
            .ring_buffer = std.ArrayList(u8).init(allocator),
            .window_size = 22, // Default window size
        };
    }

    pub fn deinit(self: *BrotliDecompressor) void {
        self.output.deinit();
        self.ring_buffer.deinit();
    }

    /// Decompress Brotli-compressed data
    pub fn decompress(self: *BrotliDecompressor, input: []const u8) Brotli.Error![]u8 {
        if (input.len == 0) return Brotli.Error.InvalidStream;

        // Read stream header
        var pos: usize = 0;
        const wbits = input[pos] & 0x3F;
        self.window_size = @intCast(wbits + 10);
        pos += 1;

        // Process metablocks
        while (pos < input.len) {
            const consumed = try self.decompressMetablock(input[pos..]);
            pos += consumed;
        }

        return try self.output.toOwnedSlice();
    }

    fn decompressMetablock(self: *BrotliDecompressor, input: []const u8) Brotli.Error!usize {
        if (input.len == 0) return 0;

        var pos: usize = 0;

        // Read metablock header
        const header = input[pos];
        pos += 1;

        const is_last = (header & 0x01) != 0;
        const is_last_empty = (header & 0x02) != 0;

        if (is_last and is_last_empty) {
            return pos;
        }

        // Read data length
        var data_len: usize = 0;
        const len_bytes = try self.readVarInt(input[pos..], &data_len);
        pos += len_bytes;

        // Decompress commands
        var processed: usize = 0;
        while (processed < data_len and pos < input.len) {
            const command_type = input[pos];
            pos += 1;

            if (command_type == 0x00) {
                // Literal
                if (pos >= input.len) return Brotli.Error.InvalidStream;
                const byte = input[pos];
                pos += 1;

                try self.output.append(byte);
                try self.ring_buffer.append(byte);
                processed += 1;
            } else if (command_type == 0x01) {
                // Copy command
                var length: usize = 0;
                pos += try self.readVarInt(input[pos..], &length);

                var distance: usize = 0;
                pos += try self.readVarInt(input[pos..], &distance);

                // Copy from ring buffer
                if (distance > self.ring_buffer.items.len) {
                    return Brotli.Error.InvalidDistance;
                }

                const copy_start = self.ring_buffer.items.len - distance;
                for (0..length) |i| {
                    const byte = self.ring_buffer.items[copy_start + (i % distance)];
                    try self.output.append(byte);
                    try self.ring_buffer.append(byte);
                }

                processed += length;
            } else {
                return Brotli.Error.InvalidMetablock;
            }
        }

        return pos;
    }

    fn readVarInt(self: *BrotliDecompressor, input: []const u8, out_value: *usize) Brotli.Error!usize {
        _ = self;
        var value: usize = 0;
        var shift: u6 = 0;
        var pos: usize = 0;

        while (pos < input.len) {
            const byte = input[pos];
            pos += 1;

            value |= @as(usize, byte & 0x7F) << shift;

            if ((byte & 0x80) == 0) {
                out_value.* = value;
                return pos;
            }

            shift += 7;
            if (shift >= 64) return Brotli.Error.InvalidStream;
        }

        return Brotli.Error.InvalidStream;
    }
};

test "brotli basic compression and decompression" {
    const allocator = std.testing.allocator;

    var brotli = try Brotli.init(allocator, 6, 22);

    const input = "Hello, Brotli! This is a test of the Brotli compression algorithm.";

    const compressed = try brotli.compress(input);
    defer allocator.free(compressed);

    const decompressed = try brotli.decompress(compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualStrings(input, decompressed);
}

test "brotli empty input" {
    const allocator = std.testing.allocator;

    var brotli = try Brotli.init(allocator, 6, 22);

    const input = "";
    const compressed = try brotli.compress(input);
    defer allocator.free(compressed);

    const decompressed = try brotli.decompress(compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualStrings(input, decompressed);
}

test "brotli quality levels" {
    const allocator = std.testing.allocator;

    const input = "The quick brown fox jumps over the lazy dog. " ** 10;

    // Test different quality levels
    for (0..12) |quality| {
        var brotli = try Brotli.init(allocator, @intCast(quality), 22);

        const compressed = try brotli.compress(input);
        defer allocator.free(compressed);

        const decompressed = try brotli.decompress(compressed);
        defer allocator.free(decompressed);

        try std.testing.expectEqualStrings(input, decompressed);
    }
}

test "brotli large data" {
    const allocator = std.testing.allocator;

    var brotli = try Brotli.init(allocator, 6, 22);

    // Generate large input with patterns
    var input = try allocator.alloc(u8, 100000);
    defer allocator.free(input);

    for (input, 0..) |*byte, i| {
        byte.* = @intCast(i % 256);
    }

    const compressed = try brotli.compress(input);
    defer allocator.free(compressed);

    const decompressed = try brotli.decompress(compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualSlices(u8, input, decompressed);
}

test "brotli repeated patterns" {
    const allocator = std.testing.allocator;

    var brotli = try Brotli.init(allocator, 9, 22);

    const input = "abcdefgh" ** 100;

    const compressed = try brotli.compress(input);
    defer allocator.free(compressed);

    // Compression should be effective on repeated patterns
    try std.testing.expect(compressed.len < input.len);

    const decompressed = try brotli.decompress(compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualStrings(input, decompressed);
}
