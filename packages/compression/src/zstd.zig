const std = @import("std");
const zstd_std = std.compress.zstd;

/// Zstandard (RFC 8878).
///
/// `decompress` reads any sequence of Zstandard and skippable frames. Block
/// decoding is `std.compress.zstd`; this file frames it: it finds each frame's
/// end, bounds the window, and verifies the content checksum (which the std
/// decoder does not). Frames that need a dictionary are refused with
/// `error.DictionaryUnsupported`.
///
/// `compress` writes one frame with a content size and checksum. Its blocks
/// are compressed blocks with raw literals and sequences coded with the
/// predefined FSE tables (RFC 8878 section 3.1.1.3.2.2), or raw and RLE blocks
/// where those are smaller. There is no Huffman literal coding and no
/// dictionary support, so ratios trail the reference encoder.
pub const Zstd = struct {
    allocator: std.mem.Allocator,
    level: CompressionLevel,
    /// Frames whose window is larger than this are refused.
    max_window: u32 = 1 << 27,
    /// Decoding fails with `error.OutputTooLarge` past this many bytes.
    max_output: usize = std.math.maxInt(usize),

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

    pub const Error = error{
        InvalidZstdMagic,
        ChecksumMismatch,
        /// The input ends inside a frame.
        Truncated,
        /// A reserved bit or block type is set, or the content size is wrong.
        InvalidFrame,
        DictionaryUnsupported,
        WindowTooLarge,
        OutputTooLarge,
        OutOfMemory,
    } || zstd_std.Decompress.Error;

    pub const magic: u32 = 0xFD2FB528;
    /// Window of frames too large for a single segment: 2^20 bytes.
    const window_log = 20;
    const window_size: usize = 1 << window_log;
    const block_size_max: usize = zstd_std.block_size_max;

    pub fn init(allocator: std.mem.Allocator, level: CompressionLevel) Zstd {
        return .{ .allocator = allocator, .level = level };
    }

    /// Compress `data` into one Zstandard frame.
    pub fn compress(self: *Zstd, data: []const u8) Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        var encoder = try Encoder.init(self.allocator, self.level);
        defer encoder.deinit();
        try encoder.frame(data, &out);
        return out.toOwnedSlice(self.allocator);
    }

    /// Decompress every frame in `data`, concatenated.
    pub fn decompress(self: *Zstd, data: []const u8) Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        if (data.len == 0) return error.Truncated;
        var pos: usize = 0;
        while (pos < data.len) {
            if (data.len - pos < 4) return error.Truncated;
            const frame_magic = std.mem.readInt(u32, data[pos..][0..4], .little);
            if (frame_magic & 0xFFFF_FFF0 == 0x184D2A50) {
                if (data.len - pos < 8) return error.Truncated;
                const len = std.mem.readInt(u32, data[pos + 4 ..][0..4], .little);
                if (len > data.len - pos - 8) return error.Truncated;
                pos += 8 + len;
                continue;
            }
            if (frame_magic != magic) return error.InvalidZstdMagic;
            pos += try self.decodeFrame(data[pos..], &out);
        }
        return out.toOwnedSlice(self.allocator);
    }

    /// Decode the frame at the start of `data`; returns its length.
    fn decodeFrame(self: *Zstd, data: []const u8, out: *std.ArrayList(u8)) Error!usize {
        const header = try FrameHeader.parse(data);
        if (header.dictionary_id != 0) return error.DictionaryUnsupported;
        const window = header.window orelse return error.InvalidFrame;
        if (window > self.max_window) return error.WindowTooLarge;

        // Walk the block headers to find the end of the frame.
        var pos = header.len;
        while (true) {
            if (data.len - pos < 3) return error.Truncated;
            const block = std.mem.readInt(u24, data[pos..][0..3], .little);
            pos += 3;
            const size: usize = block >> 3;
            const body: usize = switch (@as(u2, @truncate(block >> 1))) {
                0, 2 => size,
                1 => 1,
                3 => return error.InvalidFrame,
            };
            if (body > data.len - pos) return error.Truncated;
            pos += body;
            if (block & 1 == 1) break;
        }
        const checksum: ?u32 = if (header.checksum) blk: {
            if (data.len - pos < 4) return error.Truncated;
            defer pos += 4;
            break :blk std.mem.readInt(u32, data[pos..][0..4], .little);
        } else null;

        const window_len: u32 = @intCast(@max(window, 1 << 10));
        const buffer = try self.allocator.alloc(u8, window_len + zstd_std.block_size_max);
        defer self.allocator.free(buffer);
        var input: std.Io.Reader = .fixed(data[0..pos]);
        var decompressor: zstd_std.Decompress = .init(&input, buffer, .{ .window_len = window_len });

        const start = out.items.len;
        const limit = self.max_output - start;
        while (true) {
            const chunk = decompressor.reader.peekGreedy(1) catch |err| switch (err) {
                error.EndOfStream => break,
                error.ReadFailed => return decompressor.err orelse error.ReadFailed,
            };
            if (chunk.len > limit - (out.items.len - start)) return error.OutputTooLarge;
            try out.appendSlice(self.allocator, chunk);
            decompressor.reader.toss(chunk.len);
        }

        const content = out.items[start..];
        if (header.content_size) |size| if (size != content.len) return error.InvalidFrame;
        if (checksum) |expected| {
            if (expected != @as(u32, @truncate(std.hash.XxHash64.hash(0, content)))) return error.ChecksumMismatch;
        }
        return pos;
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
};

/// RFC 8878 section 3.1.1.1.
const FrameHeader = struct {
    len: usize,
    window: ?u64,
    dictionary_id: u32,
    content_size: ?u64,
    checksum: bool,

    fn parse(data: []const u8) Zstd.Error!FrameHeader {
        if (data.len < 5) return error.Truncated;
        const fhd = data[4];
        if (fhd & 0b1000 != 0) return error.InvalidFrame; // reserved bit
        const fcs_flag: u2 = @intCast(fhd >> 6);
        const single_segment = fhd & 0b10_0000 != 0;
        const dict_flag: u2 = @intCast(fhd & 0b11);
        const fcs_len: usize = switch (fcs_flag) {
            0 => if (single_segment) 1 else 0,
            1 => 2,
            2 => 4,
            3 => 8,
        };
        const dict_len: usize = switch (dict_flag) {
            0 => 0,
            1 => 1,
            2 => 2,
            3 => 4,
        };
        const len = 5 + @as(usize, if (single_segment) 0 else 1) + dict_len + fcs_len;
        if (data.len < len) return error.Truncated;

        var pos: usize = 5;
        var window: ?u64 = null;
        if (!single_segment) {
            const wd = data[pos];
            pos += 1;
            const log: u6 = 10 + @as(u6, @intCast(wd >> 3));
            const base = @as(u64, 1) << log;
            window = base + (base / 8) * (wd & 7);
        }
        var dictionary_id: u32 = 0;
        for (0..dict_len) |i| dictionary_id |= @as(u32, data[pos + i]) << @intCast(8 * i);
        pos += dict_len;
        var content_size: ?u64 = null;
        if (fcs_len > 0) {
            var value: u64 = 0;
            for (0..fcs_len) |i| value |= @as(u64, data[pos + i]) << @intCast(8 * i);
            if (fcs_len == 2) value += 256;
            content_size = value;
        }
        if (single_segment) window = content_size;
        return .{
            .len = len,
            .window = window,
            .dictionary_id = dictionary_id,
            .content_size = content_size,
            .checksum = fhd & 0b100 != 0,
        };
    }
};

/// FSE encoding table for one of the predefined distributions.
const FseTable = struct {
    log: u5,
    states: []u16,
    delta_bits: []u32,
    delta_state: []i32,

    fn build(allocator: std.mem.Allocator, norm: []const i16, log: u5) !FseTable {
        const size: u32 = @as(u32, 1) << log;
        const mask = size - 1;
        const step = (size >> 1) + (size >> 3) + 3;
        const states = try allocator.alloc(u16, size);
        errdefer allocator.free(states);
        const delta_bits = try allocator.alloc(u32, norm.len);
        errdefer allocator.free(delta_bits);
        const delta_state = try allocator.alloc(i32, norm.len);
        errdefer allocator.free(delta_state);
        const symbols = try allocator.alloc(u8, size);
        defer allocator.free(symbols);
        const cumul = try allocator.alloc(u32, norm.len + 1);
        defer allocator.free(cumul);

        // Low-probability (-1) symbols take the top of the table.
        var high: u32 = size - 1;
        cumul[0] = 0;
        for (norm, 0..) |n, s| {
            if (n == -1) {
                cumul[s + 1] = cumul[s] + 1;
                symbols[high] = @intCast(s);
                high -%= 1;
            } else {
                cumul[s + 1] = cumul[s] + @as(u32, @intCast(n));
            }
        }
        var position: u32 = 0;
        for (norm, 0..) |n, s| {
            var i: i16 = 0;
            while (i < n) : (i += 1) {
                symbols[position] = @intCast(s);
                position = (position + step) & mask;
                while (position > high) position = (position + step) & mask;
            }
        }
        const next = try allocator.dupe(u32, cumul[0..norm.len]);
        defer allocator.free(next);
        for (0..size) |u| {
            const s = symbols[u];
            states[next[s]] = @intCast(size + u);
            next[s] += 1;
        }
        var total: i32 = 0;
        for (norm, 0..) |n, s| {
            switch (n) {
                0 => {
                    delta_bits[s] = ((@as(u32, log) + 1) << 16) - size;
                    delta_state[s] = 0;
                },
                -1, 1 => {
                    delta_bits[s] = (@as(u32, log) << 16) - size;
                    delta_state[s] = total - 1;
                    total += 1;
                },
                else => {
                    const count: u32 = @intCast(n);
                    const max_bits_out: u32 = log - (31 - @clz(count - 1));
                    const min_state_plus = count << @intCast(max_bits_out);
                    delta_bits[s] = (max_bits_out << 16) - min_state_plus;
                    delta_state[s] = total - n;
                    total += n;
                },
            }
        }
        return .{ .log = log, .states = states, .delta_bits = delta_bits, .delta_state = delta_state };
    }

    fn deinit(self: *FseTable, allocator: std.mem.Allocator) void {
        allocator.free(self.states);
        allocator.free(self.delta_bits);
        allocator.free(self.delta_state);
    }

    fn initState(self: *const FseTable, symbol: u8) u32 {
        const bits_out: u5 = @intCast((self.delta_bits[symbol] + (1 << 15)) >> 16);
        const value = (@as(u32, bits_out) << 16) -% self.delta_bits[symbol];
        return self.states[@intCast(@as(i64, value >> bits_out) + self.delta_state[symbol])];
    }

    fn encode(self: *const FseTable, bits: *BitWriter, state: *u32, symbol: u8) void {
        const bits_out: u5 = @intCast((state.* +% self.delta_bits[symbol]) >> 16);
        bits.add(state.*, bits_out);
        state.* = self.states[@intCast(@as(i64, state.* >> bits_out) + self.delta_state[symbol])];
    }

    fn flush(self: *const FseTable, bits: *BitWriter, state: u32) void {
        bits.add(state, self.log);
    }
};

/// Forward bit writer; the decoder reads the result backwards.
const BitWriter = struct {
    bytes: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,
    acc: u64 = 0,
    count: u6 = 0,
    failed: bool = false,

    fn add(self: *BitWriter, value: u64, n: u6) void {
        if (n == 0) return;
        self.acc |= (value & ((@as(u64, 1) << n) - 1)) << self.count;
        self.count += n;
        while (self.count >= 8) {
            self.bytes.append(self.allocator, @truncate(self.acc)) catch {
                self.failed = true;
            };
            self.acc >>= 8;
            self.count -= 8;
        }
    }

    fn close(self: *BitWriter) !void {
        self.add(1, 1);
        if (self.count > 0) {
            try self.bytes.append(self.allocator, @truncate(self.acc));
            self.acc = 0;
            self.count = 0;
        }
        if (self.failed) return error.OutOfMemory;
    }
};

const Sequence = struct {
    literal_length: u32,
    match_length: u32,
    offset: u32,
};

const Encoder = struct {
    allocator: std.mem.Allocator,
    hash_table: []u32,
    ll: FseTable,
    ml: FseTable,
    of: FseTable,
    /// Positions skipped per miss grows faster at low levels.
    skip_shift: u5,

    const hash_log = 16;
    const min_match = 4;

    fn init(allocator: std.mem.Allocator, level: Zstd.CompressionLevel) !Encoder {
        var ll = try FseTable.build(allocator, &zstd_std.literals_length_default_distribution, zstd_std.default_accuracy_log.literal);
        errdefer ll.deinit(allocator);
        var ml = try FseTable.build(allocator, &zstd_std.match_lengths_default_distribution, zstd_std.default_accuracy_log.match);
        errdefer ml.deinit(allocator);
        var of = try FseTable.build(allocator, &zstd_std.offset_codes_default_distribution, zstd_std.default_accuracy_log.offset);
        errdefer of.deinit(allocator);
        return .{
            .allocator = allocator,
            .hash_table = try allocator.alloc(u32, 1 << hash_log),
            .ll = ll,
            .ml = ml,
            .of = of,
            .skip_shift = if (level.toInt() <= 3) 5 else 8,
        };
    }

    fn deinit(self: *Encoder) void {
        self.allocator.free(self.hash_table);
        self.ll.deinit(self.allocator);
        self.ml.deinit(self.allocator);
        self.of.deinit(self.allocator);
    }

    fn frame(self: *Encoder, data: []const u8, out: *std.ArrayList(u8)) !void {
        const a = self.allocator;
        var header: [14]u8 = undefined;
        std.mem.writeInt(u32, header[0..4], Zstd.magic, .little);
        var len: usize = 5;
        const single_segment = data.len <= Zstd.window_size;
        const fcs_flag: u8, const fcs_len: usize = if (data.len < 256 and single_segment)
            .{ 0, 1 }
        else if (data.len >= 256 and data.len < 65536 + 256)
            .{ 1, 2 }
        else if (data.len <= std.math.maxInt(u32))
            .{ 2, 4 }
        else
            .{ 3, 8 };
        // FHD: content size flag, single segment, content checksum.
        header[4] = (fcs_flag << 6) | (@as(u8, @intFromBool(single_segment)) << 5) | 0b100;
        if (!single_segment) {
            header[len] = (Zstd.window_log - 10) << 3;
            len += 1;
        }
        const fcs_value: u64 = if (fcs_len == 2) data.len - 256 else data.len;
        for (0..fcs_len) |i| header[len + i] = @truncate(fcs_value >> @intCast(8 * i));
        len += fcs_len;
        try out.appendSlice(a, header[0..len]);

        @memset(self.hash_table, 0);
        var block_buf: std.ArrayList(u8) = .empty;
        defer block_buf.deinit(a);
        var pos: usize = 0;
        while (true) {
            const end = @min(data.len, pos + Zstd.block_size_max);
            const last = end == data.len;
            const chunk = data[pos..end];
            block_buf.clearRetainingCapacity();
            var block_header: u32 = @intFromBool(last);
            if (chunk.len > 1 and std.mem.allEqual(u8, chunk, chunk[0])) {
                block_header |= (1 << 1) | (@as(u32, @intCast(chunk.len)) << 3);
                try appendU24(a, out, block_header);
                try out.append(a, chunk[0]);
            } else if (chunk.len > 0 and try self.compressedBlock(data, pos, end, &block_buf) and block_buf.items.len < chunk.len) {
                block_header |= (2 << 1) | (@as(u32, @intCast(block_buf.items.len)) << 3);
                try appendU24(a, out, block_header);
                try out.appendSlice(a, block_buf.items);
            } else {
                block_header |= @as(u32, @intCast(chunk.len)) << 3;
                try appendU24(a, out, block_header);
                try out.appendSlice(a, chunk);
            }
            pos = end;
            if (last) break;
        }

        var checksum: [4]u8 = undefined;
        std.mem.writeInt(u32, &checksum, @truncate(std.hash.XxHash64.hash(0, data)), .little);
        try out.appendSlice(a, &checksum);
    }

    fn appendU24(a: std.mem.Allocator, out: *std.ArrayList(u8), value: u32) !void {
        var bytes: [3]u8 = undefined;
        std.mem.writeInt(u24, &bytes, @intCast(value), .little);
        try out.appendSlice(a, &bytes);
    }

    /// Encode `data[start..end]` as a compressed block body into `out`;
    /// matches may reach back into earlier blocks within the window. Returns
    /// false when it found no match.
    fn compressedBlock(self: *Encoder, data: []const u8, start: usize, end: usize, out: *std.ArrayList(u8)) !bool {
        const a = self.allocator;
        var sequences: std.ArrayList(Sequence) = .empty;
        defer sequences.deinit(a);
        var literals: std.ArrayList(u8) = .empty;
        defer literals.deinit(a);

        var anchor = start;
        var ip = start;
        var misses: usize = 0;
        while (end - ip >= min_match + 8) {
            const word = std.mem.readInt(u32, data[ip..][0..4], .little);
            const hash = (word *% 2654435761) >> (32 - hash_log);
            const candidate = self.hash_table[hash];
            self.hash_table[hash] = @intCast(ip + 1);
            if (candidate != 0) {
                const ref = candidate - 1;
                if (ip - ref <= Zstd.window_size and std.mem.readInt(u32, data[ref..][0..4], .little) == word) {
                    var len: usize = min_match;
                    while (ip + len < end and data[ref + len] == data[ip + len]) len += 1;
                    try literals.appendSlice(a, data[anchor..ip]);
                    try sequences.append(a, .{
                        .literal_length = @intCast(ip - anchor),
                        .match_length = @intCast(len),
                        .offset = @intCast(ip - ref),
                    });
                    ip += len;
                    anchor = ip;
                    misses = 0;
                    continue;
                }
            }
            misses += 1;
            ip += 1 + (misses >> self.skip_shift);
        }
        if (sequences.items.len == 0) return false;
        try literals.appendSlice(a, data[anchor..end]);

        // Literals section: Raw_Literals_Block.
        const n = literals.items.len;
        if (n < 32) {
            try out.append(a, @intCast(n << 3));
        } else if (n < 4096) {
            try out.append(a, @intCast(((n & 0xf) << 4) | 0b0100));
            try out.append(a, @intCast(n >> 4));
        } else {
            try out.append(a, @intCast(((n & 0xf) << 4) | 0b1100));
            try out.append(a, @intCast((n >> 4) & 0xff));
            try out.append(a, @intCast(n >> 12));
        }
        try out.appendSlice(a, literals.items);

        // Sequences section header, then all three in Predefined_Mode.
        const count = sequences.items.len;
        if (count < 128) {
            try out.append(a, @intCast(count));
        } else if (count < 0x7f00) {
            try out.append(a, @intCast((count >> 8) + 128));
            try out.append(a, @intCast(count & 0xff));
        } else {
            try out.append(a, 255);
            try out.append(a, @intCast((count - 0x7f00) & 0xff));
            try out.append(a, @intCast((count - 0x7f00) >> 8));
        }
        try out.append(a, 0);

        var bits: BitWriter = .{ .allocator = a };
        defer bits.bytes.deinit(a);
        const seqs = sequences.items;
        const last = codes(seqs[count - 1]);
        var ll_state = self.ll.initState(last.ll);
        var ml_state = self.ml.initState(last.ml);
        var of_state = self.of.initState(last.of);
        addExtra(&bits, last);
        var i = count - 1;
        while (i > 0) {
            i -= 1;
            const c = codes(seqs[i]);
            self.of.encode(&bits, &of_state, c.of);
            self.ml.encode(&bits, &ml_state, c.ml);
            self.ll.encode(&bits, &ll_state, c.ll);
            addExtra(&bits, c);
        }
        self.ml.flush(&bits, ml_state);
        self.of.flush(&bits, of_state);
        self.ll.flush(&bits, ll_state);
        try bits.close();
        try out.appendSlice(a, bits.bytes.items);
        return true;
    }

    const Codes = struct {
        ll: u8,
        ll_extra: u32,
        ll_bits: u5,
        ml: u8,
        ml_extra: u32,
        ml_bits: u5,
        of: u8,
        of_extra: u32,
    };

    fn codes(s: Sequence) Codes {
        const ll = codeFor(&zstd_std.literals_length_code_table, s.literal_length);
        const ml = codeFor(&zstd_std.match_length_code_table, s.match_length);
        // Offset_Value = offset + 3 keeps clear of the repeat-offset codes 1..3.
        const offset_value = s.offset + 3;
        const of: u8 = @intCast(31 - @clz(offset_value));
        return .{
            .ll = ll,
            .ll_extra = s.literal_length - zstd_std.literals_length_code_table[ll][0],
            .ll_bits = zstd_std.literals_length_code_table[ll][1],
            .ml = ml,
            .ml_extra = s.match_length - zstd_std.match_length_code_table[ml][0],
            .ml_bits = zstd_std.match_length_code_table[ml][1],
            .of = of,
            .of_extra = offset_value - (@as(u32, 1) << @intCast(of)),
        };
    }

    fn codeFor(table: []const struct { u32, u5 }, value: u32) u8 {
        var code: usize = table.len - 1;
        while (table[code][0] > value) code -= 1;
        return @intCast(code);
    }

    fn addExtra(bits: *BitWriter, c: Codes) void {
        bits.add(c.ll_extra, c.ll_bits);
        bits.add(c.ml_extra, c.ml_bits);
        bits.add(c.of_extra, @intCast(c.of));
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

/// Streaming reader facade. All frames are validated in full before bytes
/// are exposed, so checksum or truncation errors cannot produce trusted output.
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

test "zstd round trips text, runs and random bytes" {
    const allocator = std.testing.allocator;
    var zstd = Zstd.init(allocator, .balanced);
    var prng = std.Random.DefaultPrng.init(8878);

    const sizes = [_]usize{ 0, 1, 31, 255, 256, 4095, 70_000, 300_000, 1_300_000 };
    for (sizes) |size| {
        const input = try allocator.alloc(u8, size);
        defer allocator.free(input);
        for (input, 0..) |*b, i| b.* = switch ((i / 5000) % 3) {
            0 => "zstd frames, blocks and sequences "[i % 34],
            1 => 'z',
            else => prng.random().int(u8),
        };
        const encoded = try zstd.compress(input);
        defer allocator.free(encoded);
        const decoded = try zstd.decompress(encoded);
        defer allocator.free(decoded);
        try std.testing.expectEqualSlices(u8, input, decoded);
    }
}

test "zstd compresses repetitive input" {
    const allocator = std.testing.allocator;
    var zstd = Zstd.init(allocator, .balanced);
    const input = try allocator.alloc(u8, 100_000);
    defer allocator.free(input);
    for (input, 0..) |*b, i| b.* = "the quick brown fox jumps over the lazy dog. "[i % 45];
    const encoded = try zstd.compress(input);
    defer allocator.free(encoded);
    try std.testing.expect(encoded.len < input.len / 20);
}
