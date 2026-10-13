const std = @import("std");

/// Zstandard-style framed compression used by Home.
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
            return @backingInt(self);
        }
    };

    pub const Dictionary = struct {
        data: []const u8,
        id: u32,

        pub fn init(data: []const u8) Dictionary {
            return .{ .data = data, .id = @truncate(std.hash.Wyhash.hash(0, data)) };
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

    const ZSTD_MAGIC: u32 = 0x28B52FFD;
    const BLOCK_SIZE = 128 * 1024;

    pub fn init(allocator: std.mem.Allocator, level: CompressionLevel) Zstd {
        return .{ .allocator = allocator, .level = level, .dictionary = null };
    }

    pub fn initWithDictionary(
        allocator: std.mem.Allocator,
        level: CompressionLevel,
        dictionary: Dictionary,
    ) Zstd {
        return .{ .allocator = allocator, .level = level, .dictionary = dictionary };
    }

    pub fn compress(self: *Zstd, data: []const u8) ![]u8 {
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();

        try self.writeFrameHeader(&output.writer, data.len);
        const blocks = try self.compressBlocks(data);
        defer self.allocator.free(blocks);
        try output.writer.writeAll(blocks);
        try output.writer.writeInt(u32, @truncate(std.hash.XxHash64.hash(0, data)), .little);
        return output.toOwnedSlice();
    }

    pub fn decompress(self: *Zstd, data: []const u8) ![]u8 {
        var input: std.Io.Reader = .fixed(data);
        const header = try self.readFrameHeader(&input);
        if (header.magic_number != ZSTD_MAGIC) return error.InvalidZstdMagic;

        if (header.dictionary_id) |id| {
            const dictionary = self.dictionary orelse return error.DictionaryRequired;
            if (dictionary.id != id) return error.DictionaryMismatch;
        }

        const footer_size: usize = if (header.content_checksum) 4 else 0;
        if (input.seek + footer_size > data.len) return error.InvalidZstdFrame;
        const blocks_end = data.len - footer_size;
        const decompressed = try self.decompressBlocks(data[input.seek..blocks_end], header.content_size);
        errdefer self.allocator.free(decompressed);

        if (header.content_checksum) {
            const stored = std.mem.readInt(u32, data[blocks_end..][0..4], .little);
            const actual: u32 = @truncate(std.hash.XxHash64.hash(0, decompressed));
            if (stored != actual) return error.ChecksumMismatch;
        }
        return decompressed;
    }

    pub fn estimateCompressionRatio(self: *Zstd, data: []const u8) f64 {
        _ = self;
        if (data.len == 0) return 1.0;

        var counts: [256]usize = @splat(0);
        for (data) |byte| counts[byte] += 1;

        var entropy: f64 = 0.0;
        const data_len: f64 = @floatFromInt(data.len);
        for (counts) |count| {
            if (count == 0) continue;
            const probability = @as(f64, @floatFromInt(count)) / data_len;
            entropy -= probability * @log2(probability);
        }
        return @max(0.1, @min(1.0, entropy / 8.0));
    }

    fn writeFrameHeader(self: *Zstd, writer: *std.Io.Writer, content_size: usize) !void {
        try writer.writeInt(u32, ZSTD_MAGIC, .little);
        const descriptor: FrameHeader.FrameDescriptor = .{
            .content_checksum_flag = true,
            ._reserved = false,
            .single_segment = false,
            .unused = false,
            .dictionary_id_flag = if (self.dictionary != null) 2 else 0,
            .content_size_flag = 2,
        };
        try writer.writeByte(@bitCast(descriptor));
        try writer.writeByte(try calculateWindowDescriptor(content_size));
        if (self.dictionary) |dictionary| {
            try writer.writeInt(u32, dictionary.id, .little);
        }
        try writer.writeInt(u64, content_size, .little);
    }

    fn readFrameHeader(self: *Zstd, reader: *std.Io.Reader) !FrameHeader {
        _ = self;
        const magic = try reader.takeInt(u32, .little);
        const descriptor: FrameHeader.FrameDescriptor = @bitCast(try reader.takeByte());
        if (descriptor._reserved or descriptor.unused) return error.InvalidZstdFrame;

        const window_size = if (descriptor.single_segment)
            null
        else
            try decodeWindowSize(try reader.takeByte());

        const dictionary_id = if (descriptor.dictionary_id_flag == 0)
            null
        else
            try reader.takeInt(u32, .little);

        const content_size = if (descriptor.content_size_flag == 0)
            null
        else
            try reader.takeInt(u64, .little);

        return .{
            .magic_number = magic,
            .descriptor = descriptor,
            .window_size = window_size,
            .dictionary_id = dictionary_id,
            .content_size = content_size,
            .content_checksum = descriptor.content_checksum_flag,
        };
    }

    fn calculateWindowDescriptor(size: usize) !u8 {
        var window_log: u8 = 10;
        var window_size: usize = 1024;
        while (window_size < size and window_log < 31) {
            window_log += 1;
            window_size = @as(usize, 1) << @intCast(window_log);
        }
        if (window_size < size) return error.InputTooLarge;
        return window_log;
    }

    fn decodeWindowSize(descriptor: u8) !u64 {
        if (descriptor < 10 or descriptor > 31) return error.InvalidWindowSize;
        return @as(u64, 1) << @intCast(descriptor);
    }

    fn compressBlocks(self: *Zstd, data: []const u8) ![]u8 {
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();

        var offset: usize = 0;
        while (offset < data.len or (data.len == 0 and offset == 0)) {
            const block_end = @min(offset +| BLOCK_SIZE, data.len);
            const block = data[offset..block_end];
            const compressed = try self.compressBlock(block);
            defer self.allocator.free(compressed);
            if (compressed.len > std.math.maxInt(u29)) return error.BlockTooLarge;

            const last = block_end == data.len;
            const header = (@as(u32, @intCast(compressed.len)) << 3) | @intFromBool(last);
            try output.writer.writeInt(u32, header, .little);
            try output.writer.writeAll(compressed);
            offset = block_end;
            if (last) break;
        }
        return output.toOwnedSlice();
    }

    fn compressBlock(self: *Zstd, block: []const u8) ![]u8 {
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();

        var index: usize = 0;
        while (index < block.len) {
            const match = self.findMatch(block, index);
            if (match.length >= 4) {
                try output.writer.writeByte(0xff);
                try output.writer.writeInt(u16, @intCast(match.distance), .little);
                try output.writer.writeInt(u16, @intCast(match.length), .little);
                index += match.length;
            } else {
                try output.writer.writeByte(0x00);
                try output.writer.writeByte(block[index]);
                index += 1;
            }
        }
        return output.toOwnedSlice();
    }

    fn decompressBlocks(self: *Zstd, data: []const u8, expected_size: ?u64) ![]u8 {
        var input: std.Io.Reader = .fixed(data);
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();

        var last = false;
        while (!last) {
            const header = try input.takeInt(u32, .little);
            if (header & 0x6 != 0) return error.InvalidBlockHeader;
            last = header & 1 != 0;
            const compressed_len: usize = header >> 3;
            const compressed = try input.take(compressed_len);
            const block = try self.decompressBlock(compressed);
            defer self.allocator.free(block);
            try output.writer.writeAll(block);
        }
        if (input.seek != input.end) return error.TrailingBlockData;
        if (expected_size) |size| {
            if (size != output.written().len) return error.SizeMismatch;
        }
        return output.toOwnedSlice();
    }

    fn decompressBlock(self: *Zstd, block: []const u8) ![]u8 {
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();

        var index: usize = 0;
        while (index < block.len) {
            const tag = block[index];
            index += 1;
            switch (tag) {
                0x00 => {
                    if (index == block.len) return error.TruncatedLiteral;
                    try output.writer.writeByte(block[index]);
                    index += 1;
                },
                0xff => {
                    if (block.len - index < 4) return error.TruncatedMatch;
                    const distance = std.mem.readInt(u16, block[index..][0..2], .little);
                    const length = std.mem.readInt(u16, block[index + 2 ..][0..2], .little);
                    index += 4;
                    if (distance == 0 or distance > output.written().len or length == 0) {
                        return error.InvalidMatch;
                    }
                    for (0..length) |_| {
                        const written = output.written();
                        try output.writer.writeByte(written[written.len - distance]);
                    }
                },
                else => return error.InvalidBlockTag,
            }
        }
        return output.toOwnedSlice();
    }

    const Match = struct { distance: usize = 0, length: usize = 0 };

    fn findMatch(self: *Zstd, data: []const u8, position: usize) Match {
        _ = self;
        var best: Match = .{};
        const search_start = position -| 32768;
        var candidate = search_start;
        while (candidate < position) : (candidate += 1) {
            var length: usize = 0;
            while (position + length < data.len and
                candidate + length < position and
                data[candidate + length] == data[position + length])
            {
                length += 1;
            }
            if (length > best.length) {
                best = .{ .distance = position - candidate, .length = length };
            }
        }
        return best;
    }
};

/// Streaming facade that emits one complete, checksummed frame on `finish`.
pub const ZstdCompressor = struct {
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    zstd: Zstd,
    buffer: std.ArrayList(u8) = .empty,
    finished: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        output: *std.Io.Writer,
        level: Zstd.CompressionLevel,
    ) ZstdCompressor {
        return .{
            .allocator = allocator,
            .output = output,
            .zstd = Zstd.init(allocator, level),
        };
    }

    pub fn deinit(self: *ZstdCompressor) void {
        self.buffer.deinit(self.allocator);
    }

    pub fn write(self: *ZstdCompressor, data: []const u8) !void {
        if (self.finished) return error.AlreadyFinished;
        try self.buffer.appendSlice(self.allocator, data);
    }

    pub fn finish(self: *ZstdCompressor) !void {
        if (self.finished) return error.AlreadyFinished;
        const compressed = try self.zstd.compress(self.buffer.items);
        defer self.allocator.free(compressed);
        try self.output.writeAll(compressed);
        try self.output.flush();
        self.finished = true;
    }
};

/// Streaming reader facade. A frame is validated in full before bytes are
/// exposed, so checksum or truncation errors cannot produce trusted output.
pub const ZstdDecompressor = struct {
    allocator: std.mem.Allocator,
    input: *std.Io.Reader,
    zstd: Zstd,
    decoded: []u8 = &.{},
    position: usize = 0,
    loaded: bool = false,

    pub fn init(allocator: std.mem.Allocator, input: *std.Io.Reader) ZstdDecompressor {
        return .{
            .allocator = allocator,
            .input = input,
            .zstd = Zstd.init(allocator, .balanced),
        };
    }

    pub fn deinit(self: *ZstdDecompressor) void {
        if (self.loaded) self.allocator.free(self.decoded);
    }

    pub fn read(self: *ZstdDecompressor, output: []u8) !usize {
        if (!self.loaded) {
            const encoded = try self.input.allocRemaining(self.allocator, .unlimited);
            defer self.allocator.free(encoded);
            self.decoded = try self.zstd.decompress(encoded);
            self.loaded = true;
        }

        const count = @min(output.len, self.decoded.len - self.position);
        @memcpy(output[0..count], self.decoded[self.position..][0..count]);
        self.position += count;
        return count;
    }
};
