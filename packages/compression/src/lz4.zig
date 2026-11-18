const std = @import("std");

const XxHash32 = std.hash.XxHash32;

/// LZ4 in the LZ4 Frame format (lz4/doc/lz4_Frame_format.md), which is what
/// the `lz4` tool reads and writes.
///
/// `compress` writes one frame of independent 64 KiB blocks with the content
/// size and a content checksum. `decompress` reads any sequence of frames:
/// independent or linked blocks, block and content checksums, skippable
/// frames, and the legacy frame format (`lz4 -l`). Dictionary frames are
/// refused with `error.DictionaryUnsupported`.
///
/// `compressBlock` and `decompressBlock` expose the raw LZ4 block format.
pub const LZ4 = struct {
    allocator: std.mem.Allocator,
    acceleration: u32, // 1 = default, >1 = faster but less compression

    pub const Error = error{
        InvalidStream,
        DecompressionFailed,
        OutOfMemory,
        InvalidToken,
        InvalidOffset,
        InvalidLength,
        OutputTooSmall,
        SizeTooLarge,
        /// Not an LZ4 frame, skippable frame or legacy frame.
        InvalidMagic,
        /// A frame descriptor field this version does not define.
        UnsupportedVersion,
        HeaderChecksumMismatch,
        BlockChecksumMismatch,
        ContentChecksumMismatch,
        DictionaryUnsupported,
        /// Decoding would produce more than the allowed output.
        OutputTooLarge,
    };

    pub const frame_magic: u32 = 0x184D2204;
    pub const legacy_magic: u32 = 0x184C2102;

    // LZ4 block constants
    const MIN_MATCH: usize = 4;
    /// The last 5 bytes of a block are always literals.
    const LAST_LITERALS: usize = 5;
    /// The last match starts at least 12 bytes before the end of the block.
    const MFLIMIT: usize = 12;
    const HASH_LOG = 16;
    const MAX_DISTANCE: usize = 65535;
    const block_size: usize = 64 * 1024;
    const legacy_block_size: usize = 8 * 1024 * 1024;

    /// Initialize LZ4 compressor
    /// acceleration: 1 = default, higher values trade compression for speed
    pub fn init(allocator: std.mem.Allocator, acceleration: u32) LZ4 {
        return LZ4{
            .allocator = allocator,
            .acceleration = if (acceleration == 0) 1 else acceleration,
        };
    }

    /// Compress `input` into one LZ4 frame.
    pub fn compress(self: *LZ4, input: []const u8) Error![]u8 {
        var compressor = try LZ4Compressor.init(self.allocator, self.acceleration);
        defer compressor.deinit();

        return try compressor.compress(input);
    }

    /// Decompress a sequence of LZ4 frames.
    pub fn decompress(self: *LZ4, input: []const u8) Error![]u8 {
        var decompressor = try LZ4Decompressor.init(self.allocator);
        defer decompressor.deinit();

        return try decompressor.decompress(input);
    }

    /// Get maximum compressed size of one block for a given input size
    pub fn compressBound(input_size: usize) usize {
        // LZ4 worst case: input + (input / 255) + 16
        return input_size + (input_size / 255) + 16;
    }

    /// Compress `input` as one raw LZ4 block, appended to `out`.
    pub fn compressBlock(allocator: std.mem.Allocator, input: []const u8, acceleration: u32, out: *std.ArrayList(u8)) Error!void {
        const table = try allocator.alloc(u32, 1 << HASH_LOG);
        defer allocator.free(table);
        try compressBlockWithTable(allocator, input, @max(acceleration, 1), table, out);
    }

    /// Decompress one raw LZ4 block, appending to `out`. Matches may reach back
    /// into the `history` bytes already in `out` (linked blocks); the block may
    /// add at most `max_len` bytes.
    pub fn decompressBlock(allocator: std.mem.Allocator, block: []const u8, out: *std.ArrayList(u8), history: usize, max_len: usize) Error!void {
        const start = out.items.len;
        const floor = start - @min(history, start);
        var ip: usize = 0;
        while (true) {
            if (ip >= block.len) return Error.InvalidStream;
            const token = block[ip];
            ip += 1;

            const literal_length = try readLength(block, &ip, token >> 4);
            if (literal_length > block.len - ip) return Error.InvalidStream;
            if (literal_length > max_len - (out.items.len - start)) return Error.OutputTooLarge;
            try out.appendSlice(allocator, block[ip..][0..literal_length]);
            ip += literal_length;

            // The last sequence has literals only.
            if (ip == block.len) return;

            if (block.len - ip < 2) return Error.InvalidStream;
            const offset = @as(usize, block[ip]) | (@as(usize, block[ip + 1]) << 8);
            ip += 2;
            if (offset == 0 or offset > out.items.len - floor) return Error.InvalidOffset;

            const match_length = try readLength(block, &ip, token & 15) + MIN_MATCH;
            if (match_length > max_len - (out.items.len - start)) return Error.OutputTooLarge;
            try out.ensureUnusedCapacity(allocator, match_length);
            const from = out.items.len - offset;
            for (0..match_length) |i| out.appendAssumeCapacity(out.items[from + i]);
        }
    }

    fn readLength(block: []const u8, ip: *usize, nibble: u8) Error!usize {
        var length: usize = nibble;
        if (nibble != 15) return length;
        while (true) {
            if (ip.* >= block.len) return Error.InvalidStream;
            const extra = block[ip.*];
            ip.* += 1;
            length = std.math.add(usize, length, extra) catch return Error.InvalidLength;
            if (extra != 255) return length;
        }
    }

    fn compressBlockWithTable(
        allocator: std.mem.Allocator,
        input: []const u8,
        acceleration: u32,
        table: []u32,
        out: *std.ArrayList(u8),
    ) Error!void {
        // Hash table entries hold position + 1, so zero means empty.
        @memset(table, 0);
        var anchor: usize = 0;
        if (input.len >= MFLIMIT + 1) {
            const match_limit = input.len - MFLIMIT;
            const match_end = input.len - LAST_LITERALS;
            var ip: usize = 0;
            var misses: usize = 0;
            while (ip < match_limit) {
                const sequence = std.mem.readInt(u32, input[ip..][0..4], .little);
                const hash = (sequence *% 2654435761) >> (32 - HASH_LOG);
                const candidate = table[hash];
                table[hash] = @intCast(ip + 1);
                if (candidate != 0) {
                    const ref = candidate - 1;
                    if (ip - ref <= MAX_DISTANCE and std.mem.readInt(u32, input[ref..][0..4], .little) == sequence) {
                        var len: usize = MIN_MATCH;
                        while (ip + len < match_end and input[ref + len] == input[ip + len]) len += 1;
                        try writeSequence(allocator, out, input[anchor..ip], ip - ref, len);
                        ip += len;
                        anchor = ip;
                        misses = 0;
                        continue;
                    }
                }
                misses += 1;
                ip += 1 + (misses >> 6) * acceleration;
            }
        }
        try writeLastLiterals(allocator, out, input[anchor..]);
    }

    fn writeLength(allocator: std.mem.Allocator, out: *std.ArrayList(u8), length: usize) Error!void {
        var remaining = length - 15;
        while (remaining >= 255) : (remaining -= 255) try out.append(allocator, 255);
        try out.append(allocator, @intCast(remaining));
    }

    fn writeSequence(allocator: std.mem.Allocator, out: *std.ArrayList(u8), literals: []const u8, offset: usize, match_length: usize) Error!void {
        const ml = match_length - MIN_MATCH;
        const token: u8 = (@as(u8, @intCast(@min(literals.len, 15))) << 4) | @as(u8, @intCast(@min(ml, 15)));
        try out.append(allocator, token);
        if (literals.len >= 15) try writeLength(allocator, out, literals.len);
        try out.appendSlice(allocator, literals);
        try out.append(allocator, @intCast(offset & 0xff));
        try out.append(allocator, @intCast(offset >> 8));
        if (ml >= 15) try writeLength(allocator, out, ml);
    }

    fn writeLastLiterals(allocator: std.mem.Allocator, out: *std.ArrayList(u8), literals: []const u8) Error!void {
        try out.append(allocator, @as(u8, @intCast(@min(literals.len, 15))) << 4);
        if (literals.len >= 15) try writeLength(allocator, out, literals.len);
        try out.appendSlice(allocator, literals);
    }
};

/// Writes LZ4 frames.
pub const LZ4Compressor = struct {
    allocator: std.mem.Allocator,
    acceleration: u32,
    hash_table: []u32,
    output: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator, acceleration: u32) LZ4.Error!LZ4Compressor {
        return LZ4Compressor{
            .allocator = allocator,
            .acceleration = if (acceleration == 0) 1 else acceleration,
            .hash_table = try allocator.alloc(u32, 1 << LZ4.HASH_LOG),
            .output = .empty,
        };
    }

    pub fn deinit(self: *LZ4Compressor) void {
        self.allocator.free(self.hash_table);
        self.output.deinit(self.allocator);
    }

    /// One frame: independent 64 KiB blocks, content size, content checksum.
    pub fn compress(self: *LZ4Compressor, input: []const u8) LZ4.Error![]u8 {
        const a = self.allocator;
        const out = &self.output;
        out.clearRetainingCapacity();

        var header: [4]u8 = undefined;
        std.mem.writeInt(u32, &header, LZ4.frame_magic, .little);
        try out.appendSlice(a, &header);

        // FLG: version 01, block independence, content size, content checksum.
        // BD: 64 KiB maximum block size.
        const descriptor_start = out.items.len;
        try out.append(a, 0b01_1_0_1_1_0_0);
        try out.append(a, 4 << 4);
        var size: [8]u8 = undefined;
        std.mem.writeInt(u64, &size, input.len, .little);
        try out.appendSlice(a, &size);
        const descriptor_hash = XxHash32.hash(0, out.items[descriptor_start..]);
        try out.append(a, @truncate(descriptor_hash >> 8));

        var block: std.ArrayList(u8) = .empty;
        defer block.deinit(a);
        var rest = input;
        while (rest.len > 0) {
            const chunk = rest[0..@min(rest.len, LZ4.block_size)];
            rest = rest[chunk.len..];
            block.clearRetainingCapacity();
            try LZ4.compressBlockWithTable(a, chunk, self.acceleration, self.hash_table, &block);
            var block_header: [4]u8 = undefined;
            if (block.items.len < chunk.len) {
                std.mem.writeInt(u32, &block_header, @intCast(block.items.len), .little);
                try out.appendSlice(a, &block_header);
                try out.appendSlice(a, block.items);
            } else {
                // Incompressible: store the block uncompressed (high bit set).
                std.mem.writeInt(u32, &block_header, @as(u32, @intCast(chunk.len)) | 0x8000_0000, .little);
                try out.appendSlice(a, &block_header);
                try out.appendSlice(a, chunk);
            }
        }

        var trailer: [8]u8 = undefined;
        std.mem.writeInt(u32, trailer[0..4], 0, .little); // EndMark
        std.mem.writeInt(u32, trailer[4..8], XxHash32.hash(0, input), .little);
        try out.appendSlice(a, &trailer);
        return out.toOwnedSlice(a);
    }
};

/// Reads LZ4 frames.
pub const LZ4Decompressor = struct {
    allocator: std.mem.Allocator,
    output: std.ArrayList(u8),
    /// Decoding fails with `error.OutputTooLarge` past this many bytes.
    max_output: usize = std.math.maxInt(usize),

    pub fn init(allocator: std.mem.Allocator) LZ4.Error!LZ4Decompressor {
        return LZ4Decompressor{
            .allocator = allocator,
            .output = .empty,
        };
    }

    pub fn deinit(self: *LZ4Decompressor) void {
        self.output.deinit(self.allocator);
    }

    /// Decode every frame in `input`, concatenated.
    pub fn decompress(self: *LZ4Decompressor, input: []const u8) LZ4.Error![]u8 {
        self.output.clearRetainingCapacity();
        var reader: Cursor = .{ .data = input };
        if (input.len == 0) return LZ4.Error.InvalidStream;
        while (reader.pos < input.len) {
            const magic = try reader.int(u32);
            if (magic == LZ4.frame_magic) {
                try self.frame(&reader);
            } else if (magic == LZ4.legacy_magic) {
                try self.legacyFrame(&reader);
            } else if (magic & 0xFFFF_FFF0 == 0x184D2A50) {
                const len = try reader.int(u32);
                _ = try reader.take(len);
            } else return LZ4.Error.InvalidMagic;
        }
        return self.output.toOwnedSlice(self.allocator);
    }

    fn remainingOutput(self: *const LZ4Decompressor) usize {
        return self.max_output - self.output.items.len;
    }

    fn frame(self: *LZ4Decompressor, reader: *Cursor) LZ4.Error!void {
        const descriptor_start = reader.pos;
        const flg = try reader.byte();
        const bd = try reader.byte();
        if (flg >> 6 != 1) return LZ4.Error.UnsupportedVersion;
        if (flg & 0b10 != 0 or bd & 0x8F != 0) return LZ4.Error.UnsupportedVersion;
        const independent = flg & 0b0010_0000 != 0;
        const block_checksum = flg & 0b0001_0000 != 0;
        const has_size = flg & 0b0000_1000 != 0;
        const content_checksum = flg & 0b0000_0100 != 0;
        const has_dict = flg & 0b0000_0001 != 0;
        const max_block: usize = switch (bd >> 4) {
            4 => 64 * 1024,
            5 => 256 * 1024,
            6 => 1024 * 1024,
            7 => 4 * 1024 * 1024,
            else => return LZ4.Error.UnsupportedVersion,
        };
        const content_size: ?u64 = if (has_size) try reader.int(u64) else null;
        if (has_dict) {
            _ = try reader.int(u32);
        }
        const descriptor = reader.data[descriptor_start..reader.pos];
        const hc = try reader.byte();
        if (hc != @as(u8, @truncate(XxHash32.hash(0, descriptor) >> 8))) return LZ4.Error.HeaderChecksumMismatch;
        if (has_dict) return LZ4.Error.DictionaryUnsupported;

        const frame_start = self.output.items.len;
        while (true) {
            const raw = try reader.int(u32);
            if (raw == 0) break;
            const uncompressed = raw & 0x8000_0000 != 0;
            const len = raw & 0x7FFF_FFFF;
            if (len > max_block) return LZ4.Error.InvalidLength;
            const data = try reader.take(len);
            if (block_checksum) {
                if (try reader.int(u32) != XxHash32.hash(0, data)) return LZ4.Error.BlockChecksumMismatch;
            }
            const limit = @min(max_block, self.remainingOutput());
            if (uncompressed) {
                if (data.len > self.remainingOutput()) return LZ4.Error.OutputTooLarge;
                try self.output.appendSlice(self.allocator, data);
            } else {
                // Linked blocks may reach 64 KiB back into this frame's earlier blocks.
                const history: usize = if (independent) 0 else @min(64 * 1024, self.output.items.len - frame_start);
                try LZ4.decompressBlock(self.allocator, data, &self.output, history, limit);
            }
        }

        const content = self.output.items[frame_start..];
        if (content_size) |size| if (size != content.len) return LZ4.Error.InvalidLength;
        if (content_checksum) {
            if (try reader.int(u32) != XxHash32.hash(0, content)) return LZ4.Error.ContentChecksumMismatch;
        }
    }

    /// Legacy frames: independent blocks of up to 8 MiB, each with a size
    /// prefix, until end of input or the next frame's magic number.
    fn legacyFrame(self: *LZ4Decompressor, reader: *Cursor) LZ4.Error!void {
        while (reader.pos < reader.data.len) {
            const len = std.mem.readInt(u32, (try reader.peek(4))[0..4], .little);
            if (len == LZ4.frame_magic or len == LZ4.legacy_magic or len & 0xFFFF_FFF0 == 0x184D2A50) return;
            reader.pos += 4;
            if (len > LZ4.compressBound(LZ4.legacy_block_size)) return LZ4.Error.InvalidLength;
            const data = try reader.take(len);
            try LZ4.decompressBlock(self.allocator, data, &self.output, 0, @min(LZ4.legacy_block_size, self.remainingOutput()));
        }
    }
};

const Cursor = struct {
    data: []const u8,
    pos: usize = 0,

    fn take(self: *Cursor, n: usize) LZ4.Error![]const u8 {
        if (n > self.data.len - self.pos) return LZ4.Error.InvalidStream;
        defer self.pos += n;
        return self.data[self.pos..][0..n];
    }

    fn peek(self: *Cursor, n: usize) LZ4.Error![]const u8 {
        if (n > self.data.len - self.pos) return LZ4.Error.InvalidStream;
        return self.data[self.pos..][0..n];
    }

    fn byte(self: *Cursor) LZ4.Error!u8 {
        return (try self.take(1))[0];
    }

    fn int(self: *Cursor, comptime T: type) LZ4.Error!T {
        return std.mem.readInt(T, (try self.take(@sizeOf(T)))[0..@sizeOf(T)], .little);
    }
};

test "lz4 basic compression and decompression" {
    const allocator = std.testing.allocator;

    var lz4 = LZ4.init(allocator, 1);

    const input = "Hello, LZ4! This is a test of the LZ4 compression algorithm.";

    const compressed = try lz4.compress(input);
    defer allocator.free(compressed);
    try std.testing.expectEqual(LZ4.frame_magic, std.mem.readInt(u32, compressed[0..4], .little));

    const decompressed = try lz4.decompress(compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualStrings(input, decompressed);
}

test "lz4 empty input" {
    const allocator = std.testing.allocator;

    var lz4 = LZ4.init(allocator, 1);

    const compressed = try lz4.compress("");
    defer allocator.free(compressed);

    const decompressed = try lz4.decompress(compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqual(@as(usize, 0), decompressed.len);
}

test "lz4 acceleration levels" {
    const allocator = std.testing.allocator;

    const phrase = "The quick brown fox jumps over the lazy dog. ";
    var input: [phrase.len * 10]u8 = undefined;
    for (0..10) |i| {
        @memcpy(input[i * phrase.len ..][0..phrase.len], phrase);
    }

    for (1..5) |accel| {
        var lz4 = LZ4.init(allocator, @intCast(accel));

        const compressed = try lz4.compress(&input);
        defer allocator.free(compressed);

        const decompressed = try lz4.decompress(compressed);
        defer allocator.free(decompressed);

        try std.testing.expectEqualStrings(&input, decompressed);
    }
}

test "lz4 large data spans several blocks" {
    const allocator = std.testing.allocator;

    var lz4 = LZ4.init(allocator, 1);

    const input = try allocator.alloc(u8, 300_000);
    defer allocator.free(input);

    for (input, 0..) |*byte, i| {
        byte.* = @intCast(i % 251);
    }

    const compressed = try lz4.compress(input);
    defer allocator.free(compressed);
    try std.testing.expect(compressed.len < input.len / 10);

    const decompressed = try lz4.decompress(compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualSlices(u8, input, decompressed);
}

test "lz4 compress bound" {
    const input_size: usize = 1000;
    const max_compressed = LZ4.compressBound(input_size);
    try std.testing.expect(max_compressed > input_size);
    try std.testing.expect(max_compressed < input_size * 2);
}

test "lz4 incompressible data is stored" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x4c5a_3401);

    var lz4 = LZ4.init(allocator, 1);

    var input: [1000]u8 = undefined;
    prng.random().bytes(&input);

    const compressed = try lz4.compress(&input);
    defer allocator.free(compressed);

    const decompressed = try lz4.decompress(compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualSlices(u8, &input, decompressed);
}

test "lz4 raw blocks reject malformed lengths and offsets" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    const max = std.math.maxInt(usize);

    try std.testing.expectError(LZ4.Error.InvalidStream, LZ4.decompressBlock(allocator, &.{}, &out, 0, max));
    try std.testing.expectError(LZ4.Error.InvalidStream, LZ4.decompressBlock(allocator, &.{ 0x20, 'A' }, &out, 0, max));
    out.clearRetainingCapacity();
    try std.testing.expectError(LZ4.Error.InvalidOffset, LZ4.decompressBlock(allocator, &.{ 0x10, 'A', 2, 0 }, &out, 0, max));
    out.clearRetainingCapacity();
    try std.testing.expectError(LZ4.Error.InvalidStream, LZ4.decompressBlock(allocator, &.{ 0xf0, 255 }, &out, 0, max));
    out.clearRetainingCapacity();
    try std.testing.expectError(LZ4.Error.OutputTooLarge, LZ4.decompressBlock(allocator, &.{ 0x1f, 'A', 1, 0, 100, 0x00 }, &out, 0, 50));
}

test "lz4 frames reject bad magic and checksums" {
    const allocator = std.testing.allocator;
    var lz4 = LZ4.init(allocator, 1);
    const encoded = try lz4.compress("checksummed content, checksummed content");
    defer allocator.free(encoded);

    encoded[0] ^= 0xff;
    try std.testing.expectError(LZ4.Error.InvalidMagic, lz4.decompress(encoded));
    encoded[0] ^= 0xff;

    encoded[14] ^= 0xff; // header checksum
    try std.testing.expectError(LZ4.Error.HeaderChecksumMismatch, lz4.decompress(encoded));
    encoded[14] ^= 0xff;

    encoded[encoded.len - 1] ^= 0xff;
    try std.testing.expectError(LZ4.Error.ContentChecksumMismatch, lz4.decompress(encoded));
}
