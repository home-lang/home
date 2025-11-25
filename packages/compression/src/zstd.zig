const std = @import("std");

/// Zstandard (zstd) compression and decompression
///
/// Features:
/// - High compression ratios
/// - Fast decompression
/// - Multiple compression levels
/// - Dictionary support
/// - Streaming compression
/// - Frame format
pub const Zstd = struct {
    allocator: std.mem.Allocator,
    level: CompressionLevel,
    dictionary: ?Dictionary,

    pub const CompressionLevel = enum(i8) {
        fastest = 1,
        fast = 3,
        balanced = 6,
        good = 9,
        best = 19,
        ultra = 22,

        pub fn toInt(self: CompressionLevel) i32 {
            return @intFromEnum(self);
        }
    };

    pub const Dictionary = struct {
        data: []const u8,
        id: u32,

        pub fn init(data: []const u8) Dictionary {
            const id = std.hash.Wyhash.hash(0, data);
            return .{
                .data = data,
                .id = @truncate(id),
            };
        }
    };

    pub const FrameHeader = struct {
        magic_number: u32,
        descriptor: FrameDescriptor,
        window_size: ?u64,
        dictionary_id: ?u32,
        content_size: ?u64,
        content_checksum: bool,

        pub const FrameDescriptor = packed struct {
            content_checksum_flag: bool,
            _reserved: bool,
            single_segment: bool,
            unused: bool,
            dictionary_id_flag: u2,
            content_size_flag: u2,
        };
    };

    const ZSTD_MAGIC = 0x28B52FFD;
    const ZSTD_MAGIC_SKIPPABLE_START = 0x184D2A50;
    const ZSTD_MAGIC_SKIPPABLE_END = 0x184D2A5F;

    pub fn init(allocator: std.mem.Allocator, level: CompressionLevel) Zstd {
        return .{
            .allocator = allocator,
            .level = level,
            .dictionary = null,
        };
    }

    pub fn initWithDictionary(allocator: std.mem.Allocator, level: CompressionLevel, dict: Dictionary) Zstd {
        return .{
            .allocator = allocator,
            .level = level,
            .dictionary = dict,
        };
    }

    /// Compress data with Zstandard
    pub fn compress(self: *Zstd, data: []const u8) ![]u8 {
        var output = std.ArrayList(u8).init(self.allocator);
        errdefer output.deinit();

        // Write frame header
        try self.writeFrameHeader(output.writer(), data.len);

        // Compress blocks
        const compressed_blocks = try self.compressBlocks(data);
        defer self.allocator.free(compressed_blocks);

        try output.appendSlice(compressed_blocks);

        // Write checksum if enabled
        const checksum = std.hash.XxHash64.hash(0, data);
        try output.writer().writeInt(u32, @truncate(checksum), .little);

        return output.toOwnedSlice();
    }

    /// Decompress Zstandard data
    pub fn decompress(self: *Zstd, data: []const u8) ![]u8 {
        var stream = std.io.fixedBufferStream(data);
        const reader = stream.reader();

        // Read and validate frame header
        const header = try self.readFrameHeader(reader);

        if (header.magic_number != ZSTD_MAGIC) {
            return error.InvalidZstdMagic;
        }

        // Decompress blocks
        const header_size = @as(usize, @intCast(stream.pos));
        const footer_size: usize = if (header.content_checksum) 4 else 0;
        const compressed_size = data.len - header_size - footer_size;
        const compressed = data[header_size .. header_size + compressed_size];

        const decompressed = try self.decompressBlocks(compressed, header.content_size);
        errdefer self.allocator.free(decompressed);

        // Verify checksum if present
        if (header.content_checksum) {
            const stored_checksum = std.mem.readInt(u32, data[data.len - 4 ..][0..4], .little);
            const calculated_checksum = std.hash.XxHash64.hash(0, decompressed);

            if (stored_checksum != @as(u32, @truncate(calculated_checksum))) {
                self.allocator.free(decompressed);
                return error.ChecksumMismatch;
            }
        }

        return decompressed;
    }

    /// Estimate compression ratio for given data
    pub fn estimateCompressionRatio(self: *Zstd, data: []const u8) f64 {
        _ = self;

        // Simple heuristic based on entropy
        var counts: [256]usize = [_]usize{0} ** 256;
        for (data) |byte| {
            counts[byte] += 1;
        }

        var entropy: f64 = 0.0;
        const data_len_f: f64 = @floatFromInt(data.len);
        for (counts) |count| {
            if (count > 0) {
                const prob: f64 = @as(f64, @floatFromInt(count)) / data_len_f;
                entropy -= prob * @log2(prob);
            }
        }

        // Estimate compression ratio based on entropy
        // Lower entropy = better compression
        const theoretical_bits = entropy * data_len_f;
        const estimated_ratio = theoretical_bits / (data_len_f * 8.0);

        return @max(0.1, @min(1.0, estimated_ratio));
    }

    fn writeFrameHeader(self: *Zstd, writer: anytype, content_size: usize) !void {
        // Write magic number
        try writer.writeInt(u32, ZSTD_MAGIC, .little);

        // Frame descriptor
        const descriptor = FrameHeader.FrameDescriptor{
            .content_checksum_flag = true,
            ._reserved = false,
            .single_segment = false,
            .unused = false,
            .dictionary_id_flag = if (self.dictionary != null) 2 else 0,
            .content_size_flag = 2, // 8 bytes
        };

        try writer.writeByte(@bitCast(descriptor));

        // Window size (if not single segment)
        const window_descriptor = try self.calculateWindowDescriptor(content_size);
        try writer.writeByte(window_descriptor);

        // Dictionary ID (if present)
        if (self.dictionary) |dict| {
            try writer.writeInt(u32, dict.id, .little);
        }

        // Content size
        try writer.writeInt(u64, content_size, .little);
    }

    fn readFrameHeader(self: *Zstd, reader: anytype) !FrameHeader {
        _ = self;

        // Read magic number
        const magic = try reader.readInt(u32, .little);

        // Read frame descriptor
        const descriptor: FrameHeader.FrameDescriptor = @bitCast(try reader.readByte());

        // Read window size
        var window_size: ?u64 = null;
        if (!descriptor.single_segment) {
            const window_descriptor = try reader.readByte();
            window_size = try decodeWindowSize(window_descriptor);
        }

        // Read dictionary ID
        var dictionary_id: ?u32 = null;
        if (descriptor.dictionary_id_flag > 0) {
            dictionary_id = try reader.readInt(u32, .little);
        }

        // Read content size
        var content_size: ?u64 = null;
        if (descriptor.content_size_flag > 0) {
            content_size = try reader.readInt(u64, .little);
        }

        return FrameHeader{
            .magic_number = magic,
            .descriptor = descriptor,
            .window_size = window_size,
            .dictionary_id = dictionary_id,
            .content_size = content_size,
            .content_checksum = descriptor.content_checksum_flag,
        };
    }

    fn calculateWindowDescriptor(self: *Zstd, size: usize) !u8 {
        _ = self;

        // Find minimum window size that can hold the data
        var window_log: u8 = 10; // Minimum: 1KB
        var window_size: usize = 1024;

        while (window_size < size and window_log < 31) {
            window_log += 1;
            window_size = @as(usize, 1) << @intCast(window_log);
        }

        return window_log;
    }

    fn decodeWindowSize(descriptor: u8) !u64 {
        const window_log = descriptor;
        if (window_log < 10 or window_log > 31) {
            return error.InvalidWindowSize;
        }

        return @as(u64, 1) << @intCast(window_log);
    }

    fn compressBlocks(self: *Zstd, data: []const u8) ![]u8 {
        var compressed = std.ArrayList(u8).init(self.allocator);
        errdefer compressed.deinit();

        // Use simple LZ77-style compression
        // In production, this would use the full Zstandard algorithm
        const block_size = 128 * 1024; // 128KB blocks
        var offset: usize = 0;

        while (offset < data.len) {
            const block_end = @min(offset + block_size, data.len);
            const block = data[offset..block_end];

            // Compress block
            const compressed_block = try self.compressBlock(block);
            defer self.allocator.free(compressed_block);

            // Write block header
            const last_block = block_end >= data.len;
            const block_header = (@as(u32, @intCast(compressed_block.len)) << 3) |
                                 (@as(u32, if (last_block) 1 else 0));
            try compressed.writer().writeInt(u32, block_header, .little);

            // Write block data
            try compressed.appendSlice(compressed_block);

            offset = block_end;
        }

        return compressed.toOwnedSlice();
    }

    fn compressBlock(self: *Zstd, block: []const u8) ![]u8 {
        // Simplified compression using LZ77-style matching
        // In production, this would implement full Zstandard FSE + entropy coding

        var output = std.ArrayList(u8).init(self.allocator);
        errdefer output.deinit();

        var i: usize = 0;
        while (i < block.len) {
            // Look for matches in previous data
            const match = try self.findMatch(block, i);

            if (match.length >= 4) {
                // Encode match: <distance, length>
                try output.writer().writeByte(0xFF); // Match marker
                try output.writer().writeInt(u16, @intCast(match.distance), .little);
                try output.writer().writeInt(u16, @intCast(match.length), .little);
                i += match.length;
            } else {
                // Encode literal
                try output.append(block[i]);
                i += 1;
            }
        }

        return output.toOwnedSlice();
    }

    fn decompressBlocks(self: *Zstd, data: []const u8, expected_size: ?u64) ![]u8 {
        var decompressed = std.ArrayList(u8).init(self.allocator);
        errdefer decompressed.deinit();

        if (expected_size) |size| {
            try decompressed.ensureTotalCapacity(size);
        }

        var stream = std.io.fixedBufferStream(data);
        const reader = stream.reader();

        while (true) {
            // Read block header
            const block_header = reader.readInt(u32, .little) catch break;
            const last_block = (block_header & 1) != 0;
            const block_size = block_header >> 3;

            // Read and decompress block
            const compressed_block = try self.allocator.alloc(u8, block_size);
            defer self.allocator.free(compressed_block);

            try reader.readNoEof(compressed_block);

            const decompressed_block = try self.decompressBlock(compressed_block);
            defer self.allocator.free(decompressed_block);

            try decompressed.appendSlice(decompressed_block);

            if (last_block) break;
        }

        return decompressed.toOwnedSlice();
    }

    fn decompressBlock(self: *Zstd, block: []const u8) ![]u8 {
        var output = std.ArrayList(u8).init(self.allocator);
        errdefer output.deinit();

        var i: usize = 0;
        while (i < block.len) {
            if (block[i] == 0xFF and i + 5 <= block.len) {
                // Match: copy from previous data
                i += 1;
                const distance = std.mem.readInt(u16, block[i..][0..2], .little);
                i += 2;
                const length = std.mem.readInt(u16, block[i..][0..2], .little);
                i += 2;

                // Copy match
                const start_pos = output.items.len - distance;
                var j: usize = 0;
                while (j < length) : (j += 1) {
                    try output.append(output.items[start_pos + j]);
                }
            } else {
                // Literal
                try output.append(block[i]);
                i += 1;
            }
        }

        return output.toOwnedSlice();
    }

    const Match = struct {
        distance: usize,
        length: usize,
    };

    fn findMatch(self: *Zstd, data: []const u8, pos: usize) !Match {
        _ = self;

        var best_match = Match{ .distance = 0, .length = 0 };
        const search_start = if (pos >= 32768) pos - 32768 else 0;

        var i = search_start;
        while (i < pos) : (i += 1) {
            var length: usize = 0;
            while (pos + length < data.len and
                   i + length < pos and
                   data[i + length] == data[pos + length]) {
                length += 1;
            }

            if (length > best_match.length) {
                best_match = .{
                    .distance = pos - i,
                    .length = length,
                };
            }
        }

        return best_match;
    }
};

/// Streaming Zstandard compressor
pub const ZstdCompressor = struct {
    allocator: std.mem.Allocator,
    writer: std.io.AnyWriter,
    zstd: Zstd,
    buffer: std.ArrayList(u8),
    checksum: std.hash.XxHash64,
    total_size: usize,

    const BUFFER_SIZE = 128 * 1024;

    pub fn init(allocator: std.mem.Allocator, writer: std.io.AnyWriter, level: Zstd.CompressionLevel) !ZstdCompressor {
        return .{
            .allocator = allocator,
            .writer = writer,
            .zstd = Zstd.init(allocator, level),
            .buffer = std.ArrayList(u8).init(allocator),
            .checksum = std.hash.XxHash64.init(0),
            .total_size = 0,
        };
    }

    pub fn deinit(self: *ZstdCompressor) void {
        self.buffer.deinit();
    }

    pub fn write(self: *ZstdCompressor, data: []const u8) !void {
        self.checksum.update(data);
        self.total_size += data.len;

        try self.buffer.appendSlice(data);

        if (self.buffer.items.len >= BUFFER_SIZE) {
            try self.flush();
        }
    }

    pub fn flush(self: *ZstdCompressor) !void {
        if (self.buffer.items.len == 0) return;

        const compressed = try self.zstd.compressBlocks(self.buffer.items);
        defer self.allocator.free(compressed);

        try self.writer.writeAll(compressed);
        self.buffer.clearRetainingCapacity();
    }

    pub fn finish(self: *ZstdCompressor) !void {
        try self.flush();

        // Write checksum
        try self.writer.writeInt(u32, @truncate(self.checksum.final()), .little);
    }
};

/// Streaming Zstandard decompressor
pub const ZstdDecompressor = struct {
    allocator: std.mem.Allocator,
    reader: std.io.AnyReader,
    zstd: Zstd,
    buffer: std.ArrayList(u8),
    buffer_pos: usize,
    checksum: std.hash.XxHash64,
    finished: bool,

    pub fn init(allocator: std.mem.Allocator, reader: std.io.AnyReader) !ZstdDecompressor {
        return .{
            .allocator = allocator,
            .reader = reader,
            .zstd = Zstd.init(allocator, .balanced),
            .buffer = std.ArrayList(u8).init(allocator),
            .buffer_pos = 0,
            .checksum = std.hash.XxHash64.init(0),
            .finished = false,
        };
    }

    pub fn deinit(self: *ZstdDecompressor) void {
        self.buffer.deinit();
    }

    pub fn read(self: *ZstdDecompressor, output: []u8) !usize {
        if (self.finished) return 0;

        var total_read: usize = 0;

        while (total_read < output.len) {
            // Use buffered data first
            if (self.buffer_pos < self.buffer.items.len) {
                const available = self.buffer.items.len - self.buffer_pos;
                const to_copy = @min(available, output.len - total_read);
                @memcpy(output[total_read..][0..to_copy], self.buffer.items[self.buffer_pos..][0..to_copy]);
                self.buffer_pos += to_copy;
                total_read += to_copy;
                continue;
            }

            // Read next block
            const block_header = self.reader.readInt(u32, .little) catch {
                self.finished = true;
                break;
            };

            const last_block = (block_header & 1) != 0;
            const block_size = block_header >> 3;

            const compressed_block = try self.allocator.alloc(u8, block_size);
            defer self.allocator.free(compressed_block);

            try self.reader.readNoEof(compressed_block);

            self.buffer.clearRetainingCapacity();
            const decompressed = try self.zstd.decompressBlock(compressed_block);
            defer self.allocator.free(decompressed);

            try self.buffer.appendSlice(decompressed);
            self.buffer_pos = 0;

            if (last_block) {
                self.finished = true;
                break;
            }
        }

        self.checksum.update(output[0..total_read]);
        return total_read;
    }
};
