const std = @import("std");
const tables = @import("brotli_tables.zig");

/// Brotli (RFC 7932).
///
/// The decoder reads any conforming stream: prefix codes, block switching,
/// context modeling and the static dictionary with its transforms.
///
/// The encoder writes conforming streams made of uncompressed meta-blocks,
/// which every Brotli decoder accepts but which do not shrink the data (the
/// output is the input plus a few bytes of framing per 64 KiB). It exists so
/// Home can produce `br` content that interoperates; it is not a compressor.
pub const Brotli = struct {
    allocator: std.mem.Allocator,
    quality: u4, // accepted for API compatibility; the encoder does not compress
    window_size: u5, // 10-24: WBITS written in the stream header

    pub const Error = error{
        InvalidQuality,
        InvalidWindowSize,
        /// The stream breaks a rule of RFC 7932.
        InvalidStream,
        /// The stream ends before its last meta-block does.
        Truncated,
        /// Bytes follow the end of the stream.
        TrailingData,
        /// Decoding would produce more than the allowed output.
        OutputTooLarge,
        OutOfMemory,
    };

    /// Initialize a Brotli codec.
    pub fn init(allocator: std.mem.Allocator, quality: u4, window_size: u5) Error!Brotli {
        if (quality > 11) return Error.InvalidQuality;
        if (window_size < 10 or window_size > 24) return Error.InvalidWindowSize;

        return Brotli{
            .allocator = allocator,
            .quality = quality,
            .window_size = window_size,
        };
    }

    /// Encode `input` as a Brotli stream (uncompressed meta-blocks).
    pub fn compress(self: *Brotli, input: []const u8) Error![]u8 {
        var compressor = try BrotliCompressor.init(self.allocator, self.quality, self.window_size);
        defer compressor.deinit();

        return try compressor.compress(input);
    }

    /// Decode a Brotli stream.
    pub fn decompress(self: *Brotli, input: []const u8) Error![]u8 {
        var decompressor = try BrotliDecompressor.init(self.allocator);
        defer decompressor.deinit();

        return try decompressor.decompress(input);
    }
};

/// Writes Brotli streams made of uncompressed meta-blocks.
pub const BrotliCompressor = struct {
    allocator: std.mem.Allocator,
    window_size: u5,
    output: std.ArrayList(u8) = .empty,

    /// Largest uncompressed meta-block written: 4 MLEN nibbles hold up to 2^16.
    const max_block = 1 << 16;

    pub fn init(allocator: std.mem.Allocator, quality: u4, window_size: u5) Brotli.Error!BrotliCompressor {
        if (quality > 11) return Brotli.Error.InvalidQuality;
        if (window_size < 10 or window_size > 24) return Brotli.Error.InvalidWindowSize;
        return .{ .allocator = allocator, .window_size = window_size };
    }

    pub fn deinit(self: *BrotliCompressor) void {
        self.output.deinit(self.allocator);
    }

    pub fn compress(self: *BrotliCompressor, input: []const u8) Brotli.Error![]u8 {
        self.output.clearRetainingCapacity();
        var bits: BitWriter = .{ .list = &self.output, .allocator = self.allocator };

        try writeWindowBits(&bits, self.window_size);

        var rest = input;
        while (rest.len > 0) {
            const n = @min(rest.len, max_block);
            // ISLAST = 0, MNIBBLES = 4 (code 0), MLEN - 1, ISUNCOMPRESSED = 1.
            try bits.write(1, 0);
            try bits.write(2, 0);
            try bits.write(16, @intCast(n - 1));
            try bits.write(1, 1);
            try bits.alignToByte();
            try self.output.appendSlice(self.allocator, rest[0..n]);
            rest = rest[n..];
        }

        // ISLAST = 1, ISLASTEMPTY = 1.
        try bits.write(1, 1);
        try bits.write(1, 1);
        try bits.alignToByte();
        return self.output.toOwnedSlice(self.allocator);
    }

    fn writeWindowBits(bits: *BitWriter, wbits: u5) !void {
        switch (wbits) {
            16 => try bits.write(1, 0),
            17 => try bits.write(7, 1),
            18...24 => try bits.write(4, (@as(u32, wbits - 17) << 1) | 1),
            10...15 => try bits.write(7, (@as(u32, wbits - 8) << 4) | 1),
            else => unreachable, // validated by init
        }
    }
};

const BitWriter = struct {
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    acc: u32 = 0,
    count: u5 = 0,

    /// Append the low `n` bits of `value`, least significant first.
    fn write(self: *BitWriter, n: u5, value: u32) !void {
        var i: u5 = 0;
        while (i < n) : (i += 1) {
            self.acc |= ((value >> i) & 1) << self.count;
            self.count += 1;
            if (self.count == 8) {
                try self.list.append(self.allocator, @truncate(self.acc));
                self.acc = 0;
                self.count = 0;
            }
        }
    }

    fn alignToByte(self: *BitWriter) !void {
        if (self.count > 0) {
            try self.list.append(self.allocator, @truncate(self.acc));
            self.acc = 0;
            self.count = 0;
        }
    }
};

/// Decodes RFC 7932 streams.
pub const BrotliDecompressor = struct {
    allocator: std.mem.Allocator,
    /// Decoding fails with `error.OutputTooLarge` past this many bytes.
    max_output: usize = std.math.maxInt(usize),

    pub fn init(allocator: std.mem.Allocator) Brotli.Error!BrotliDecompressor {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *BrotliDecompressor) void {
        _ = self;
    }

    /// Decode a complete stream. The caller owns the result.
    pub fn decompress(self: *BrotliDecompressor, input: []const u8) Brotli.Error![]u8 {
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        var state: Decoder = .{
            .br = .{ .data = input },
            .scratch = arena.allocator(),
            .gpa = self.allocator,
            .max_output = self.max_output,
        };
        errdefer state.out.deinit(self.allocator);
        try state.run();
        return state.out.toOwnedSlice(self.allocator);
    }
};

const BitReader = struct {
    data: []const u8,
    pos: usize = 0,
    acc: u64 = 0,
    nbits: u7 = 0,

    fn refill(self: *BitReader) void {
        while (self.nbits <= 56 and self.pos < self.data.len) {
            self.acc |= @as(u64, self.data[self.pos]) << @intCast(self.nbits);
            self.pos += 1;
            self.nbits += 8;
        }
    }

    fn read(self: *BitReader, n: u5) Brotli.Error!u32 {
        if (n == 0) return 0;
        if (self.nbits < n) self.refill();
        if (self.nbits < n) return error.Truncated;
        const value: u32 = @truncate(self.acc & ((@as(u64, 1) << n) - 1));
        self.acc >>= n;
        self.nbits -= n;
        return value;
    }

    /// The next 4 bits without consuming them; zeros past the end of input.
    fn peek4(self: *BitReader) u32 {
        if (self.nbits < 4) self.refill();
        return @truncate(self.acc & 15);
    }

    fn drop(self: *BitReader, n: u5) Brotli.Error!void {
        if (self.nbits < n) return error.Truncated;
        self.acc >>= n;
        self.nbits -= n;
    }

    /// Skip to the next byte boundary; the skipped bits must be zero.
    fn alignToByte(self: *BitReader) Brotli.Error!void {
        const extra: u5 = @intCast(self.nbits % 8);
        if (try self.read(extra) != 0) return error.InvalidStream;
    }

    /// Bytes of input consumed so far, once byte aligned.
    fn consumed(self: *const BitReader) usize {
        return self.pos - self.nbits / 8;
    }
};

/// A canonical prefix code, decoded one bit at a time.
const PrefixCode = struct {
    counts: [16]u16 = @splat(0),
    symbols: []u16,
    /// A code with one symbol uses zero bits.
    single: ?u16 = null,

    fn fromLengths(scratch: std.mem.Allocator, lengths: []const u4) Brotli.Error!PrefixCode {
        var code: PrefixCode = .{ .symbols = &.{} };
        var used: usize = 0;
        var last: u16 = 0;
        for (lengths, 0..) |len, symbol| {
            code.counts[len] += 1;
            if (len != 0) {
                used += 1;
                last = @intCast(symbol);
            }
        }
        if (used == 0) return error.InvalidStream;
        if (used == 1) {
            code.single = last;
            return code;
        }
        var offsets: [16]u16 = undefined;
        offsets[1] = 0;
        for (1..15) |len| offsets[len + 1] = offsets[len] + code.counts[len];
        code.symbols = try scratch.alloc(u16, used);
        for (lengths, 0..) |len, symbol| {
            if (len == 0) continue;
            code.symbols[offsets[len]] = @intCast(symbol);
            offsets[len] += 1;
        }
        return code;
    }

    fn decode(self: *const PrefixCode, br: *BitReader) Brotli.Error!u16 {
        if (self.single) |s| return s;
        var code: i32 = 0;
        var first: i32 = 0;
        var index: i32 = 0;
        for (1..16) |len| {
            code |= @intCast(try br.read(1));
            const count: i32 = self.counts[len];
            if (code - count < first) return self.symbols[@intCast(index + (code - first))];
            index += count;
            first += count;
            first <<= 1;
            code <<= 1;
        }
        return error.InvalidStream;
    }
};

/// Order in which code length code lengths are stored (section 3.5).
const code_length_order = [18]u8{ 1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
/// The fixed code for code length code lengths, indexed by the next 4 bits.
const code_length_prefix_len = [16]u5{ 2, 2, 2, 3, 2, 2, 2, 4, 2, 2, 2, 3, 2, 2, 2, 4 };
const code_length_prefix_value = [16]u4{ 0, 4, 3, 2, 0, 4, 3, 1, 0, 4, 3, 2, 0, 4, 3, 5 };

/// Block count codes (section 6): base value and extra bits.
const block_length_base = [26]u32{ 1, 5, 9, 13, 17, 25, 33, 41, 49, 65, 81, 97, 113, 145, 177, 209, 241, 305, 369, 497, 753, 1265, 2289, 4337, 8433, 16625 };
const block_length_extra = [26]u5{ 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 6, 6, 7, 8, 9, 10, 11, 12, 13, 24 };

/// Insert and copy length codes (section 5).
const insert_base = [24]u32{ 0, 1, 2, 3, 4, 5, 6, 8, 10, 14, 18, 26, 34, 50, 66, 98, 130, 194, 322, 578, 1090, 2114, 6210, 22594 };
const insert_extra = [24]u5{ 0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 12, 14, 24 };
const copy_base = [24]u32{ 2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 14, 18, 22, 30, 38, 54, 70, 102, 134, 198, 326, 582, 1094, 2118 };
const copy_extra = [24]u5{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 24 };
/// Per range of 64 insert-and-copy symbols: insert code base, copy code base.
const command_ranges = [11][2]u8{ .{ 0, 0 }, .{ 0, 8 }, .{ 0, 0 }, .{ 0, 8 }, .{ 8, 0 }, .{ 8, 8 }, .{ 0, 16 }, .{ 16, 0 }, .{ 8, 16 }, .{ 16, 8 }, .{ 16, 16 } };

fn alphabetBits(size: usize) u5 {
    var bits: u5 = 0;
    while ((@as(usize, 1) << bits) < size) bits += 1;
    return bits;
}

/// Block types and counts for one category (literal, command, distance).
const BlockCategory = struct {
    types: u32 = 1,
    type_code: PrefixCode = .{ .symbols = &.{} },
    count_code: PrefixCode = .{ .symbols = &.{} },
    current: u32 = 0,
    previous: u32 = 1,
    remaining: u32 = 1 << 24,

    fn read(br: *BitReader, scratch: std.mem.Allocator) Brotli.Error!BlockCategory {
        var cat: BlockCategory = .{};
        cat.types = try readVarLenUint8(br) + 1;
        if (cat.types >= 2) {
            cat.type_code = try readPrefixCode(br, scratch, cat.types + 2);
            cat.count_code = try readPrefixCode(br, scratch, 26);
            cat.remaining = try readBlockLength(br, &cat.count_code);
        }
        return cat;
    }

    /// Account for one symbol, switching block type first when the block is done.
    fn next(self: *BlockCategory, br: *BitReader) Brotli.Error!void {
        if (self.remaining == 0) {
            const code = try self.type_code.decode(br);
            var block_type: u32 = switch (code) {
                0 => self.previous,
                1 => self.current + 1,
                else => code - 2,
            };
            if (block_type >= self.types) block_type -= self.types;
            self.previous = self.current;
            self.current = block_type;
            self.remaining = try readBlockLength(br, &self.count_code);
        }
        self.remaining -= 1;
    }
};

fn readVarLenUint8(br: *BitReader) Brotli.Error!u32 {
    if (try br.read(1) == 0) return 0;
    const n: u5 = @intCast(try br.read(3));
    if (n == 0) return 1;
    return (@as(u32, 1) << n) + try br.read(n);
}

fn readBlockLength(br: *BitReader, code: *const PrefixCode) Brotli.Error!u32 {
    const symbol = try code.decode(br);
    if (symbol >= 26) return error.InvalidStream;
    return block_length_base[symbol] + try br.read(block_length_extra[symbol]);
}

/// Read a prefix code over `alphabet_size` symbols (sections 3.4 and 3.5).
fn readPrefixCode(br: *BitReader, scratch: std.mem.Allocator, alphabet_size: u32) Brotli.Error!PrefixCode {
    const lengths = try scratch.alloc(u4, alphabet_size);
    @memset(lengths, 0);
    const hskip = try br.read(2);

    if (hskip == 1) {
        // Simple prefix code: 1 to 4 explicit symbols.
        const count = try br.read(2) + 1;
        const bits = alphabetBits(alphabet_size);
        var symbols: [4]u16 = undefined;
        for (symbols[0..count], 0..) |*s, i| {
            s.* = @intCast(try br.read(bits));
            if (s.* >= alphabet_size) return error.InvalidStream;
            for (symbols[0..i]) |earlier| if (earlier == s.*) return error.InvalidStream;
        }
        switch (count) {
            1 => return .{ .symbols = &.{}, .single = symbols[0] },
            2 => {
                lengths[symbols[0]] = 1;
                lengths[symbols[1]] = 1;
            },
            3 => {
                lengths[symbols[0]] = 1;
                lengths[symbols[1]] = 2;
                lengths[symbols[2]] = 2;
            },
            else => if (try br.read(1) == 0) {
                for (symbols) |s| lengths[s] = 2;
            } else {
                lengths[symbols[0]] = 1;
                lengths[symbols[1]] = 2;
                lengths[symbols[2]] = 3;
                lengths[symbols[3]] = 3;
            },
        }
        return PrefixCode.fromLengths(scratch, lengths);
    }

    // Complex prefix code: code lengths coded with a code length code.
    var cl_lengths: [18]u4 = @splat(0);
    var space: i32 = 32;
    var num_codes: u32 = 0;
    for (code_length_order[hskip..]) |symbol| {
        const peeked = br.peek4();
        try br.drop(code_length_prefix_len[peeked]);
        const len = code_length_prefix_value[peeked];
        cl_lengths[symbol] = len;
        if (len != 0) {
            space -= @as(i32, 32) >> len;
            num_codes += 1;
            if (space <= 0) break;
        }
    }
    if (!(num_codes == 1 or space == 0)) return error.InvalidStream;
    const cl_code = try PrefixCode.fromLengths(scratch, &cl_lengths);

    var symbol: u32 = 0;
    var previous: u4 = 8;
    var repeat: u32 = 0;
    var repeat_len: u4 = 0;
    var remaining_space: i32 = 32768;
    while (symbol < alphabet_size and remaining_space > 0) {
        const len = try cl_code.decode(br);
        if (len < 16) {
            repeat = 0;
            lengths[symbol] = @intCast(len);
            symbol += 1;
            if (len != 0) {
                previous = @intCast(len);
                remaining_space -= @as(i32, 32768) >> @intCast(len);
            }
            continue;
        }
        const extra: u5 = if (len == 16) 2 else 3;
        const new_len: u4 = if (len == 16) previous else 0;
        if (repeat_len != new_len) {
            repeat = 0;
            repeat_len = new_len;
        }
        const old = repeat;
        if (repeat > 0) {
            repeat -= 2;
            repeat <<= extra;
        }
        repeat += try br.read(extra) + 3;
        const delta = repeat - old;
        if (symbol + delta > alphabet_size) return error.InvalidStream;
        @memset(lengths[symbol..][0..delta], new_len);
        symbol += delta;
        if (new_len != 0) remaining_space -= @as(i32, @intCast(delta)) << (15 - @as(u5, new_len));
    }
    if (remaining_space != 0) return error.InvalidStream;
    return PrefixCode.fromLengths(scratch, lengths);
}

fn readContextMap(br: *BitReader, scratch: std.mem.Allocator, size: usize, trees: u32) Brotli.Error![]u8 {
    const map = try scratch.alloc(u8, size);
    if (trees == 1) {
        @memset(map, 0);
        return map;
    }
    const rle_max: u32 = if (try br.read(1) == 1) try br.read(4) + 1 else 0;
    const code = try readPrefixCode(br, scratch, trees + rle_max);
    var i: usize = 0;
    while (i < size) {
        const symbol = try code.decode(br);
        if (symbol == 0) {
            map[i] = 0;
            i += 1;
        } else if (symbol <= rle_max) {
            const n: u5 = @intCast(symbol);
            const run = (@as(usize, 1) << n) + try br.read(n);
            if (i + run > size) return error.InvalidStream;
            @memset(map[i..][0..run], 0);
            i += run;
        } else {
            const value = symbol - rle_max;
            if (value >= trees) return error.InvalidStream;
            map[i] = @intCast(value);
            i += 1;
        }
    }
    if (try br.read(1) == 1) {
        // Inverse move-to-front.
        var mtf: [256]u8 = undefined;
        for (&mtf, 0..) |*m, j| m.* = @intCast(j);
        for (map) |*v| {
            const index = v.*;
            const value = mtf[index];
            v.* = value;
            std.mem.copyBackwards(u8, mtf[1 .. @as(usize, index) + 1], mtf[0..index]);
            mtf[0] = value;
            if (value >= trees) return error.InvalidStream;
        }
    }
    return map;
}

const Decoder = struct {
    br: BitReader,
    scratch: std.mem.Allocator,
    gpa: std.mem.Allocator,
    max_output: usize,
    out: std.ArrayList(u8) = .empty,
    window: usize = 0,
    /// The last four distances, most recent first.
    distances: [4]u32 = .{ 4, 11, 15, 16 },

    fn run(self: *Decoder) Brotli.Error!void {
        const wbits = try self.readWindowBits();
        self.window = (@as(usize, 1) << wbits) - 16;

        while (true) {
            const is_last = try self.br.read(1) == 1;
            if (is_last and try self.br.read(1) == 1) break; // ISLASTEMPTY

            const nibbles_code = try self.br.read(2);
            if (nibbles_code == 3) {
                // Metadata block: skipped.
                if (is_last) return error.InvalidStream;
                if (try self.br.read(1) != 0) return error.InvalidStream;
                const skip_bytes = try self.br.read(2);
                var skip: usize = 0;
                for (0..skip_bytes) |i| {
                    const byte = try self.br.read(8);
                    if (i + 1 == skip_bytes and skip_bytes > 1 and byte == 0) return error.InvalidStream;
                    skip |= @as(usize, byte) << @intCast(8 * i);
                }
                if (skip_bytes > 0) skip += 1;
                try self.br.alignToByte();
                for (0..skip) |_| _ = try self.br.read(8);
                continue;
            }

            const nibbles: u5 = @intCast(nibbles_code + 4);
            var mlen: usize = 0;
            for (0..nibbles) |i| {
                const nibble = try self.br.read(4);
                if (i + 1 == nibbles and nibbles > 4 and nibble == 0) return error.InvalidStream;
                mlen |= @as(usize, nibble) << @intCast(4 * i);
            }
            mlen += 1;
            if (mlen > self.max_output - self.out.items.len) return error.OutputTooLarge;

            if (!is_last and try self.br.read(1) == 1) {
                // Uncompressed meta-block.
                try self.br.alignToByte();
                try self.out.ensureUnusedCapacity(self.gpa, mlen);
                for (0..mlen) |_| self.out.appendAssumeCapacity(@intCast(try self.br.read(8)));
                continue;
            }

            try self.compressedMetaBlock(mlen);
            if (is_last) break;
        }

        try self.br.alignToByte();
        if (self.br.consumed() != self.br.data.len) return error.TrailingData;
    }

    fn readWindowBits(self: *Decoder) Brotli.Error!u5 {
        if (try self.br.read(1) == 0) return 16;
        const n = try self.br.read(3);
        if (n != 0) return @intCast(17 + n);
        const m = try self.br.read(3);
        if (m == 1) return error.InvalidStream; // large-window streams are not RFC 7932
        if (m != 0) return @intCast(8 + m);
        return 17;
    }

    fn compressedMetaBlock(self: *Decoder, mlen: usize) Brotli.Error!void {
        const br = &self.br;
        const scratch = self.scratch;

        var literal_blocks = try BlockCategory.read(br, scratch);
        var command_blocks = try BlockCategory.read(br, scratch);
        var distance_blocks = try BlockCategory.read(br, scratch);

        const npostfix: u5 = @intCast(try br.read(2));
        const ndirect: u32 = try br.read(4) << npostfix;
        const postfix_mask = (@as(u32, 1) << npostfix) - 1;

        const context_modes = try scratch.alloc(u2, literal_blocks.types);
        for (context_modes) |*mode| mode.* = @intCast(try br.read(2));

        const literal_trees = try readVarLenUint8(br) + 1;
        const literal_map = try readContextMap(br, scratch, 64 * @as(usize, literal_blocks.types), literal_trees);
        const distance_trees = try readVarLenUint8(br) + 1;
        const distance_map = try readContextMap(br, scratch, 4 * @as(usize, distance_blocks.types), distance_trees);

        const literal_codes = try scratch.alloc(PrefixCode, literal_trees);
        for (literal_codes) |*c| c.* = try readPrefixCode(br, scratch, 256);
        const command_codes = try scratch.alloc(PrefixCode, command_blocks.types);
        for (command_codes) |*c| c.* = try readPrefixCode(br, scratch, 704);
        const distance_alphabet = 16 + ndirect + (@as(u32, 48) << npostfix);
        const distance_codes = try scratch.alloc(PrefixCode, distance_trees);
        for (distance_codes) |*c| c.* = try readPrefixCode(br, scratch, distance_alphabet);

        try self.out.ensureUnusedCapacity(self.gpa, mlen);
        var remaining = mlen;
        while (remaining > 0) {
            try command_blocks.next(br);
            const command = try command_codes[command_blocks.current].decode(br);
            const range = command >> 6;
            const insert_code = command_ranges[range][0] + ((command >> 3) & 7);
            const copy_code = command_ranges[range][1] + (command & 7);
            const insert_len = insert_base[insert_code] + try br.read(insert_extra[insert_code]);
            const copy_len = copy_base[copy_code] + try br.read(copy_extra[copy_code]);

            for (0..insert_len) |_| {
                try literal_blocks.next(br);
                const len = self.out.items.len;
                const p1: usize = if (len >= 1) self.out.items[len - 1] else 0;
                const p2: usize = if (len >= 2) self.out.items[len - 2] else 0;
                const lut = tables.context_lookup[@as(usize, context_modes[literal_blocks.current]) * 512 ..];
                const context = lut[p1] | lut[256 + p2];
                const tree = literal_map[64 * @as(usize, literal_blocks.current) + context];
                const literal = try literal_codes[tree].decode(br);
                try self.out.append(self.gpa, @intCast(literal));
                remaining -= 1;
                if (remaining == 0) return; // the copy part is ignored
            }

            // Commands below 128 reuse the last distance without coding one.
            var distance_code: u32 = 0;
            if (range >= 2) {
                try distance_blocks.next(br);
                const context: usize = if (copy_len > 4) 3 else copy_len - 2;
                const tree = distance_map[4 * @as(usize, distance_blocks.current) + context];
                distance_code = try distance_codes[tree].decode(br);
            }
            const distance = try self.translateDistance(distance_code, ndirect, npostfix, postfix_mask);

            const max_distance = @min(self.window, self.out.items.len);
            if (distance > max_distance) {
                remaining -= try self.dictionaryWord(distance - max_distance - 1, copy_len, remaining);
                continue;
            }

            if (copy_len > remaining) return error.InvalidStream;
            const start = self.out.items.len - distance;
            for (0..copy_len) |i| try self.out.append(self.gpa, self.out.items[start + i]);
            remaining -= copy_len;
            if (distance_code != 0) {
                std.mem.copyBackwards(u32, self.distances[1..], self.distances[0..3]);
                self.distances[0] = distance;
            }
        }
    }

    fn translateDistance(self: *Decoder, code: u32, ndirect: u32, npostfix: u5, postfix_mask: u32) Brotli.Error!u32 {
        if (code < 16) {
            const relative = [16]struct { u2, i32 }{
                .{ 0, 0 },  .{ 1, 0 }, .{ 2, 0 },  .{ 3, 0 },
                .{ 0, -1 }, .{ 0, 1 }, .{ 0, -2 }, .{ 0, 2 },
                .{ 0, -3 }, .{ 0, 3 }, .{ 1, -1 }, .{ 1, 1 },
                .{ 1, -2 }, .{ 1, 2 }, .{ 1, -3 }, .{ 1, 3 },
            };
            const slot, const delta = relative[code];
            const value = @as(i64, self.distances[slot]) + delta;
            if (value <= 0) return error.InvalidStream;
            return @intCast(value);
        }
        if (code < 16 + ndirect) return code - 15;
        const c = code - ndirect - 16;
        const ndistbits: u5 = @intCast(1 + (c >> (npostfix + 1)));
        const hcode = c >> npostfix;
        const lcode = c & postfix_mask;
        const offset = ((@as(u64, 2) + (hcode & 1)) << ndistbits) - 4;
        const distance = ((offset + try self.br.read(ndistbits)) << npostfix) + lcode + ndirect + 1;
        return std.math.cast(u32, distance) orelse error.InvalidStream;
    }

    /// Append a transformed static dictionary word; returns its length.
    fn dictionaryWord(self: *Decoder, word_id: u64, len: u32, remaining: usize) Brotli.Error!usize {
        if (len < 4 or len > 24) return error.InvalidStream;
        const nbits = tables.size_bits_by_length[len];
        const index = word_id & ((@as(u64, 1) << nbits) - 1);
        const transform_id = word_id >> nbits;
        if (transform_id >= tables.transforms.len) return error.InvalidStream;
        const offset = tables.offsets_by_length[len] + index * len;
        const word = tables.dictionary[@intCast(offset)..][0..len];
        const transform = tables.transforms[@intCast(transform_id)];

        var buf: [24 + 2 * 32]u8 = undefined;
        var n: usize = 0;
        @memcpy(buf[n..][0..transform.prefix.len], transform.prefix);
        n += transform.prefix.len;

        var body: []const u8 = word;
        switch (transform.kind) {
            1...9 => body = body[0 .. body.len - @min(body.len, transform.kind)],
            12...20 => body = body[@min(body.len, transform.kind - 11)..],
            else => {},
        }
        const body_start = n;
        @memcpy(buf[n..][0..body.len], body);
        n += body.len;
        switch (transform.kind) {
            10 => if (n > body_start) {
                _ = toUpper(buf[body_start..n]);
            },
            11 => {
                var i = body_start;
                while (i < n) i += toUpper(buf[i..n]);
            },
            else => {},
        }
        @memcpy(buf[n..][0..transform.suffix.len], transform.suffix);
        n += transform.suffix.len;

        if (n > remaining) return error.InvalidStream;
        try self.out.appendSlice(self.gpa, buf[0..n]);
        return n;
    }
};

/// RFC 7932 section 8 uppercasing of the character at the start of `p`;
/// returns how many bytes it covers.
fn toUpper(p: []u8) usize {
    if (p[0] < 0xc0) {
        if (p[0] >= 'a' and p[0] <= 'z') p[0] ^= 32;
        return 1;
    }
    if (p[0] < 0xe0) {
        if (p.len > 1) p[1] ^= 32;
        return @min(2, p.len);
    }
    if (p.len > 2) p[2] ^= 5;
    return @min(3, p.len);
}

test "brotli uncompressed stream round trips" {
    const allocator = std.testing.allocator;
    var brotli = try Brotli.init(allocator, 6, 22);
    const input = try allocator.alloc(u8, 150_000);
    defer allocator.free(input);
    for (input, 0..) |*b, i| b.* = "Hello, Brotli! "[i % 15];
    const encoded = try brotli.compress(input);
    defer allocator.free(encoded);
    const decoded = try brotli.decompress(encoded);
    defer allocator.free(decoded);
    try std.testing.expectEqualSlices(u8, input, decoded);
}

test "brotli empty stream" {
    const allocator = std.testing.allocator;
    for ([_]u5{ 10, 16, 17, 18, 24 }) |wbits| {
        var brotli = try Brotli.init(allocator, 1, wbits);
        const encoded = try brotli.compress("");
        defer allocator.free(encoded);
        const decoded = try brotli.decompress(encoded);
        defer allocator.free(decoded);
        try std.testing.expectEqual(@as(usize, 0), decoded.len);
    }
}

test "brotli rejects invalid parameters and streams" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(Brotli.Error.InvalidQuality, Brotli.init(allocator, 12, 22));
    try std.testing.expectError(Brotli.Error.InvalidWindowSize, Brotli.init(allocator, 6, 9));
    var brotli = try Brotli.init(allocator, 6, 22);
    try std.testing.expectError(Brotli.Error.Truncated, brotli.decompress(""));
    // WBITS 16, ISLAST + ISLASTEMPTY, then a stray byte.
    try std.testing.expectError(Brotli.Error.TrailingData, brotli.decompress(&.{ 0x06, 0x00 }));
}
