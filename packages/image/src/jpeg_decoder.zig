//! Bounded 8-bit Huffman JPEG decoding. Sequential/progressive coefficient scans,
//! restart markers and independent component sampling; no hosted dependencies.
const std = @import("std");
const dct = @import("jpeg_dct.zig");
const zigzag = [64]u8{
    0,  1,  8,  16, 9,  2,  3,  10,
    17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
};
pub const Upsampling = enum(u32) { linear, nearest };
pub const ColorModel = enum(u32) { gray, rgb, ycbcr, cmyk, ycck };
pub const Limits = struct {
    max_input_bytes: usize = 64 * 1024 * 1024,
    max_output_bytes: usize = 256 * 1024 * 1024,
    max_working_bytes: usize = 448 * 1024 * 1024,
    max_metadata_bytes: usize = 16 * 1024 * 1024,
    max_work_units: u64 = 1024 * 1024 * 1024,
    max_scans: u32 = 256,
    max_markers: u32 = 16384,
    pub fn validate(self: Limits) !void {
        if (self.max_input_bytes == 0 or self.max_input_bytes > std.math.maxInt(u31) or self.max_output_bytes == 0 or self.max_output_bytes > std.math.maxInt(u31) or self.max_working_bytes == 0 or self.max_metadata_bytes == 0 or self.max_metadata_bytes > 16 * 1024 * 1024 or self.max_work_units == 0 or self.max_work_units > 16 * 1024 * 1024 * 1024 or self.max_scans == 0 or self.max_scans > 1024 or self.max_markers == 0 or self.max_markers > 65536) return error.InvalidLimits;
    }
};
pub const Checkpoint = struct {
    context: ?*anyopaque = null,
    call: ?*const fn (?*anyopaque) bool = null,
    pub fn check(self: Checkpoint) !void {
        if (self.call) |callback| if (!callback(self.context)) return error.Cancelled;
    }
};
pub const Options = struct { limits: Limits = .{}, upsampling: Upsampling = .linear, checkpoint: Checkpoint = .{} };
pub const Result = struct {
    allocator: std.mem.Allocator,
    pixels: []u8,
    width: u32,
    height: u32,
    components: u32,
    progressive: bool,
    scans: u32,
    color_model: ColorModel,
    upsampling: Upsampling,
    sampling: [4]u8,
    adobe_transform: ?u8,
    icc: ?[]u8 = null,
    exif: ?[]u8 = null,
    working_peak: usize = 0,
    work_units: u64 = 0,
    pub fn stride(self: Result) usize {
        return @as(usize, self.width) * (if (self.components == 1) @as(usize, 1) else 3);
    }
    pub fn ownedBytes(self: Result) usize {
        return self.pixels.len + (if (self.icc) |b| b.len else @as(usize, 0)) + (if (self.exif) |b| b.len else @as(usize, 0));
    }
    pub fn deinit(self: *Result) void {
        self.allocator.free(self.pixels);
        if (self.icc) |b| self.allocator.free(b);
        if (self.exif) |b| self.allocator.free(b);
        self.* = undefined;
    }
};
const Account = struct {
    allocator: std.mem.Allocator,
    limit: usize,
    live: usize = 0,
    peak: usize = 0,
    fn alloc(self: *Account, comptime T: type, count: usize) ![]T {
        const bytes = try std.math.mul(usize, count, @sizeOf(T));
        if (bytes > self.limit - self.live) return error.WorkingLimit;
        const result = try self.allocator.alloc(T, count);
        self.live += bytes;
        self.peak = @max(self.peak, self.live);
        return result;
    }
    fn free(self: *Account, memory: anytype) void {
        self.live -= memory.len * @sizeOf(@TypeOf(memory[0]));
        self.allocator.free(memory);
    }
};
const Block = [64]i16;
const Component = struct {
    id: u8 = 0,
    h: u32 = 1,
    v: u32 = 1,
    q: u8 = 0,
    quant: [64]u16 = @splat(0),
    latched: bool = false,
    predictor: i32 = 0,
    approximation: [64]i8 = @splat(-1),
    width: u32 = 0,
    height: u32 = 0,
    bx: u32 = 0,
    by: u32 = 0,
    blocks: []Block = &.{},
    cache: []u8 = &.{},
    cache_rows: [2]?u32 = @splat(null),
};
const Huffman = struct {
    present: bool = false,
    count: [17]u32 = @splat(0),
    first: [17]u32 = @splat(0),
    offset: [17]u32 = @splat(0),
    values: [256]u8 = @splat(0),
    fast: [256]u16 = @splat(0),
    fn init(counts: []const u8, values: []const u8) !Huffman {
        var result: Huffman = .{ .present = true };
        var code: u32 = 0;
        var at: u32 = 0;
        for (1..17) |size| {
            const count: u32 = counts[size - 1];
            // JPEG reserves the all-ones code for entropy padding.
            if (code + count >= @as(u32, 1) << @as(u5, @intCast(size))) return error.InvalidHuffman;
            result.count[size] = count;
            result.first[size] = code;
            result.offset[size] = at;
            if (size <= 8) for (0..count) |i| {
                const start = (code + @as(u32, @intCast(i))) << @as(u5, @intCast(8 - size));
                const end = start + (@as(u32, 1) << @as(u5, @intCast(8 - size)));
                for (start..end) |slot| result.fast[slot] = (@as(u16, @intCast(size)) << 8) | values[at + i];
            };
            at += count;
            code = (code + count) << 1;
        }
        if (at == 0 or at != values.len) return error.InvalidHuffman;
        @memcpy(result.values[0..values.len], values);
        return result;
    }
    fn read(self: *const Huffman, bits: *Bits) !u8 {
        if (!self.present) return error.MissingHuffman;
        if (try bits.ensure(8)) {
            const entry = self.fast[bits.peek(8)];
            if (entry != 0) {
                bits.drop(@intCast(entry >> 8));
                return @truncate(entry);
            }
        }
        var code: u32 = 0;
        for (1..17) |size| {
            code = (code << 1) | try bits.read(1);
            if (code >= self.first[size] and code - self.first[size] < self.count[size]) return self.values[self.offset[size] + code - self.first[size]];
        }
        return error.InvalidHuffmanCode;
    }
};
const Bits = struct {
    data: []const u8,
    pos: usize,
    value: u64 = 0,
    count: u7 = 0,
    fn ensure(self: *Bits, wanted: u7) !bool {
        while (self.count < wanted) {
            if (self.pos >= self.data.len) return error.TruncatedData;
            var next = self.pos + 1;
            const byte = self.data[self.pos];
            if (byte == 0xff) {
                if (next >= self.data.len) return error.TruncatedData;
                if (self.data[next] != 0) return false;
                next += 1;
            }
            self.value = (self.value << 8) | byte;
            self.count += 8;
            self.pos = next;
        }
        return true;
    }
    fn peek(self: *const Bits, count: u6) u32 {
        return @intCast((self.value >> @as(u6, @intCast(self.count - count))) & ((@as(u64, 1) << count) - 1));
    }
    fn drop(self: *Bits, count: u7) void {
        self.count -= count;
    }
    fn read(self: *Bits, count: u6) !u32 {
        if (!try self.ensure(count)) return error.TruncatedEntropy;
        const value = self.peek(count);
        self.drop(count);
        return value;
    }
    fn receive(self: *Bits, count: u5) !i32 {
        if (count == 0) return 0;
        const value = try self.read(count);
        return if (value < @as(u32, 1) << (count - 1)) @as(i32, @intCast(value)) - @as(i32, @intCast(@as(u32, 1) << count)) + 1 else @intCast(value);
    }
    fn finish(self: *Bits) !void {
        if (self.count >= 8 or (self.count != 0 and self.peek(@intCast(self.count)) != (@as(u32, 1) << @as(u5, @intCast(self.count))) - 1)) return error.InvalidPadding;
        self.count = 0;
        self.value = 0;
    }
};
const ScanComponent = struct { index: usize, dc: u8, ac: u8 };
const Decoder = struct {
    account: Account,
    data: []const u8,
    options: Options,
    pos: usize = 2,
    width: u32 = 0,
    height: u32 = 0,
    components: [4]Component = @splat(.{}),
    count: usize = 0,
    max_h: u32 = 1,
    max_v: u32 = 1,
    mcus_x: u32 = 0,
    mcus_y: u32 = 0,
    progressive: bool = false,
    scans: u32 = 0,
    markers: u32 = 0,
    work: u64 = 0,
    restart: u16 = 0,
    quant: [4][64]u16 = @splat(@splat(0)),
    quant_present: [4]bool = @splat(false),
    huffman: [2][4]Huffman = @splat(@splat(.{})),
    jfif: bool = false,
    adobe: ?u8 = null,
    exif: ?[]const u8 = null,
    icc: [255]?[]const u8 = @splat(null),
    icc_count: ?u8 = null,
    metadata_size: usize = 0,
    fn deinit(self: *Decoder) void {
        for (&self.components) |*component| {
            self.account.free(component.blocks);
            self.account.free(component.cache);
        }
    }
    fn tick(self: *Decoder, units: u64) !void {
        if (units > self.options.limits.max_work_units - self.work) return error.WorkLimit;
        self.work += units;
        try self.options.checkpoint.check();
    }
    fn marker(self: *Decoder) !u8 {
        self.markers += 1;
        if (self.markers > self.options.limits.max_markers) return error.MarkerLimit;
        try self.tick(1);
        if (self.pos >= self.data.len or self.data[self.pos] != 0xff) return error.InvalidMarker;
        while (self.pos < self.data.len and self.data[self.pos] == 0xff) self.pos += 1;
        if (self.pos >= self.data.len) return error.TruncatedData;
        const code = self.data[self.pos];
        self.pos += 1;
        if (code == 0) return error.InvalidMarker;
        return code;
    }
    fn segment(self: *Decoder) ![]const u8 {
        if (self.data.len - self.pos < 2) return error.TruncatedData;
        const length = std.mem.readInt(u16, self.data[self.pos..][0..2], .big);
        if (length < 2 or length > self.data.len - self.pos) return error.TruncatedData;
        const result = self.data[self.pos + 2 .. self.pos + length];
        self.pos += length;
        return result;
    }
    fn frame(self: *Decoder, data: []const u8, code: u8) !void {
        if (self.count != 0 or data.len < 6) return error.InvalidFrame;
        if (data[0] != 8) return error.UnsupportedPrecision;
        self.height = std.mem.readInt(u16, data[1..3], .big);
        self.width = std.mem.readInt(u16, data[3..5], .big);
        self.count = data[5];
        if (self.width == 0 or self.height == 0 or (self.count != 1 and self.count != 3 and self.count != 4) or data.len != 6 + self.count * 3) return error.InvalidFrame;
        const size = try std.math.mul(usize, try std.math.mul(usize, self.width, self.height), if (self.count == 1) 1 else 3);
        if (size > self.options.limits.max_output_bytes) return error.OutputLimit;
        self.progressive = code == 0xc2;
        for (self.components[0..self.count], 0..) |_, i| {
            const id = data[6 + i * 3];
            for (self.components[0..i]) |other| if (other.id == id) return error.InvalidComponent;
            const c = &self.components[i];
            c.id = id;
            c.h = data[7 + i * 3] >> 4;
            c.v = data[7 + i * 3] & 15;
            c.q = data[8 + i * 3];
            if (c.h == 0 or c.h > 4 or c.v == 0 or c.v > 4 or c.q > 3) return error.InvalidSampling;
            self.max_h = @max(self.max_h, c.h);
            self.max_v = @max(self.max_v, c.v);
        }
        self.mcus_x = (self.width + 8 * self.max_h - 1) / (8 * self.max_h);
        self.mcus_y = (self.height + 8 * self.max_v - 1) / (8 * self.max_v);
        for (self.components[0..self.count]) |*c| {
            c.width = (self.width * c.h + self.max_h - 1) / self.max_h;
            c.height = (self.height * c.v + self.max_v - 1) / self.max_v;
            c.bx = self.mcus_x * c.h;
            c.by = self.mcus_y * c.v;
            c.blocks = try self.account.alloc(Block, try std.math.mul(usize, c.bx, c.by));
            @memset(c.blocks, @splat(0));
        }
    }
    fn tables(self: *Decoder, data: []const u8) !void {
        var at: usize = 0;
        while (at < data.len) {
            const info = data[at];
            at += 1;
            const wide = info >> 4;
            const id = info & 15;
            if (wide > 1 or id > 3 or data.len - at < 64 * (@as(usize, wide) + 1)) return error.InvalidQuantization;
            for (zigzag) |slot| {
                const value: u16 = if (wide == 0) data[at] else std.mem.readInt(u16, data[at..][0..2], .big);
                at += @as(usize, wide) + 1;
                if (value == 0) return error.InvalidQuantization;
                self.quant[id][slot] = value;
            }
            self.quant_present[id] = true;
        }
        if (at == 0) return error.InvalidQuantization;
    }
    fn codes(self: *Decoder, data: []const u8) !void {
        var at: usize = 0;
        while (at < data.len) {
            if (data.len - at < 17) return error.InvalidHuffman;
            const info = data[at];
            if (info >> 4 > 1 or info & 15 > 3) return error.InvalidHuffman;
            var count: usize = 0;
            for (data[at + 1 .. at + 17]) |n| count += n;
            if (count > 256 or count > data.len - at - 17) return error.InvalidHuffman;
            self.huffman[info >> 4][info & 15] = try Huffman.init(data[at + 1 .. at + 17], data[at + 17 .. at + 17 + count]);
            at += 17 + count;
        }
        if (at == 0) return error.InvalidHuffman;
    }
    fn metadata(self: *Decoder, code: u8, data: []const u8) !void {
        var charge: usize = 0;
        if (code == 0xe0 and std.mem.startsWith(u8, data, "JFIF\x00")) {
            if (data.len < 14) return error.InvalidMetadata;
            self.jfif = true;
        }
        if (code == 0xee and std.mem.startsWith(u8, data, "Adobe")) {
            if (data.len != 12 or self.adobe != null or data[11] > 2) return error.InvalidMetadata;
            self.adobe = data[11];
        }
        if (code == 0xe1 and std.mem.startsWith(u8, data, "Exif\x00\x00")) {
            if (self.exif != null or data.len <= 6) return error.InvalidMetadata;
            self.exif = data[6..];
            charge = data.len - 6;
        }
        if (code == 0xe2 and std.mem.startsWith(u8, data, "ICC_PROFILE\x00")) {
            if (data.len <= 14 or data[12] == 0 or data[13] == 0 or data[12] > data[13]) return error.InvalidMetadata;
            if (self.icc_count) |count| {
                if (data[13] != count) return error.InvalidMetadata;
            } else self.icc_count = data[13];
            const index = data[12] - 1;
            if (self.icc[index] != null) return error.InvalidMetadata;
            self.icc[index] = data[14..];
            charge = data.len - 14;
        }
        if (charge > self.options.limits.max_metadata_bytes - self.metadata_size) return error.MetadataLimit;
        self.metadata_size += charge;
    }
    fn coefficient(value: i64) !i16 {
        return std.math.cast(i16, value) orelse error.InvalidCoefficient;
    }
    fn dc(self: *Decoder, c: *Component, table: u8, bits: *Bits, low: u4) !i16 {
        const category = try self.huffman[0][table].read(bits);
        if (category > 11) return error.InvalidCoefficient;
        c.predictor = try std.math.add(i32, c.predictor, try bits.receive(@intCast(category)));
        return coefficient(@as(i64, c.predictor) * (@as(i64, 1) << low));
    }
    fn sequential(self: *Decoder, c: *Component, selected: ScanComponent, block: *Block, bits: *Bits) !void {
        block[0] = try self.dc(c, selected.dc, bits, 0);
        var k: usize = 1;
        while (k < 64) {
            const rs = try self.huffman[1][selected.ac].read(bits);
            const size = rs & 15;
            const run = rs >> 4;
            if (size == 0) {
                if (run == 0) break;
                if (run != 15 or k + 16 > 64) return error.InvalidCoefficient;
                k += 16;
            } else {
                k += run;
                if (size > 10 or k >= 64) return error.InvalidCoefficient;
                block[zigzag[k]] = try coefficient(try bits.receive(@intCast(size)));
                k += 1;
            }
        }
    }
    fn refine(block: *Block, k: usize, bits: *Bits, low: u4) !void {
        const at = zigzag[k];
        if (block[at] == 0) return;
        const bit: i32 = @as(i32, 1) << low;
        const value: i32 = block[at];
        if (try bits.read(1) != 0 and @abs(value) & @as(u32, @intCast(bit)) == 0) block[at] = try coefficient(value + (if (value < 0) -bit else bit));
    }
    fn acFirst(self: *Decoder, table: u8, block: *Block, bits: *Bits, start: usize, end: usize, low: u4, eob: *u32) !void {
        if (eob.* != 0) {
            eob.* -= 1;
            return;
        }
        var k = start;
        while (k <= end) {
            const rs = try self.huffman[1][table].read(bits);
            const size = rs & 15;
            const run = rs >> 4;
            if (size == 0) {
                if (run != 15) {
                    eob.* = (@as(u32, 1) << @as(u5, @intCast(run))) + try bits.read(@intCast(run)) - 1;
                    return;
                }
                if (k + 16 > end + 1) return error.InvalidCoefficient;
                k += 16;
            } else {
                k += run;
                if (size > 10 or k > end) return error.InvalidCoefficient;
                block[zigzag[k]] = try coefficient(@as(i64, try bits.receive(@intCast(size))) * (@as(i64, 1) << low));
                k += 1;
            }
        }
    }
    fn acRefine(self: *Decoder, table: u8, block: *Block, bits: *Bits, start: usize, end: usize, low: u4, eob: *u32) !void {
        var k = start;
        if (eob.* == 0) while (k <= end) {
            const rs = try self.huffman[1][table].read(bits);
            const size = rs & 15;
            const run = rs >> 4;
            var fresh: i16 = 0;
            if (size == 0) {
                if (run != 15) {
                    eob.* = (@as(u32, 1) << @as(u5, @intCast(run))) + try bits.read(@intCast(run));
                    break;
                }
            } else {
                if (size != 1) return error.InvalidCoefficient;
                fresh = @as(i16, 1) << low;
                if (try bits.read(1) == 0) fresh = -fresh;
            }
            var zeros: u32 = if (fresh == 0) 16 else run;
            while (k <= end) {
                if (block[zigzag[k]] != 0) {
                    try refine(block, k, bits, low);
                    k += 1;
                } else if (zeros != 0) {
                    zeros -= 1;
                    k += 1;
                    if (fresh == 0 and zeros == 0) break;
                } else break;
            }
            if (zeros != 0) return error.InvalidCoefficient;
            if (fresh != 0) {
                if (k > end) return error.InvalidCoefficient;
                block[zigzag[k]] = fresh;
                k += 1;
            }
        };
        if (eob.* != 0) {
            while (k <= end) : (k += 1) try refine(block, k, bits, low);
            eob.* -= 1;
        }
    }
    fn scan(self: *Decoder, data: []const u8) !void {
        if (self.count == 0 or data.len < 6) return error.InvalidScan;
        self.scans += 1;
        if (self.scans > self.options.limits.max_scans) return error.ScanLimit;
        const count: usize = data[0];
        if (count == 0 or count > self.count or data.len != 4 + count * 2) return error.InvalidScan;
        const start: usize = data[1 + count * 2];
        const end: usize = data[2 + count * 2];
        const high: u4 = @intCast(data[3 + count * 2] >> 4);
        const low: u4 = @intCast(data[3 + count * 2] & 15);
        if (!self.progressive) {
            if (start != 0 or end != 63 or high != 0 or low != 0) return error.InvalidScan;
        } else if (start > end or end > 63 or (start == 0 and end != 0) or (start != 0 and count != 1) or low > 13 or high > 13 or (high != 0 and high != low + 1)) return error.InvalidScan;
        var selected: [4]ScanComponent = undefined;
        for (0..count) |i| {
            const id = data[1 + i * 2];
            const table = data[2 + i * 2];
            var index: ?usize = null;
            for (self.components[0..self.count], 0..) |component, slot| if (component.id == id) {
                index = slot;
            };
            const slot = index orelse return error.InvalidComponent;
            for (selected[0..i]) |previous| if (previous.index == slot) return error.InvalidScan;
            if (table >> 4 > 3 or table & 15 > 3) return error.InvalidScan;
            selected[i] = .{ .index = slot, .dc = table >> 4, .ac = table & 15 };
            const component = &self.components[slot];
            if (self.progressive and start != 0 and component.approximation[0] < 0) return error.InvalidProgression;
            for (start..end + 1) |k| {
                const previous = component.approximation[k];
                if ((high == 0 and previous != -1) or (high != 0 and previous != high)) return error.InvalidProgression;
            }
            if (!component.latched) {
                if (!self.quant_present[component.q]) return error.MissingQuantization;
                component.quant = self.quant[component.q];
                component.latched = true;
            }
            if ((!self.progressive or (start == 0 and high == 0)) and !self.huffman[0][table >> 4].present) return error.MissingHuffman;
            if ((!self.progressive or start != 0) and !self.huffman[1][table & 15].present) return error.MissingHuffman;
        }
        var mcu_blocks: u32 = 0;
        for (selected[0..count]) |item| mcu_blocks += self.components[item.index].h * self.components[item.index].v;
        if (count > 1 and mcu_blocks > 10) return error.InvalidSampling;
        for (&self.components) |*component| component.predictor = 0;
        const single = &self.components[selected[0].index];
        const columns = if (count == 1) (single.width + 7) / 8 else self.mcus_x;
        const rows = if (count == 1) (single.height + 7) / 8 else self.mcus_y;
        var bits = Bits{ .data = self.data, .pos = self.pos };
        var eob: u32 = 0;
        var ordinal: u32 = 0;
        var restart_id: u8 = 0;
        for (0..rows) |y| for (0..columns) |x| {
            if (self.restart != 0 and ordinal != 0 and ordinal % self.restart == 0) {
                if (eob != 0) return error.InvalidRestart;
                try bits.finish();
                self.pos = bits.pos;
                if (try self.marker() != 0xd0 + restart_id) return error.InvalidRestart;
                restart_id = (restart_id + 1) % 8;
                bits = .{ .data = self.data, .pos = self.pos };
                for (&self.components) |*component| component.predictor = 0;
            }
            ordinal += 1;
            for (selected[0..count]) |item| {
                const component = &self.components[item.index];
                const horizontal: usize = if (count == 1) 1 else component.h;
                const vertical: usize = if (count == 1) 1 else component.v;
                for (0..vertical) |v| for (0..horizontal) |h| {
                    try self.tick(64);
                    const block = &component.blocks[(y * vertical + v) * component.bx + x * horizontal + h];
                    if (!self.progressive) try self.sequential(component, item, block, &bits) else if (start == 0) {
                        if (high == 0) block[0] = try self.dc(component, item.dc, &bits, low) else if (try bits.read(1) != 0) {
                            block[0] |= @as(i16, 1) << low;
                        }
                    } else if (high == 0) try self.acFirst(item.ac, block, &bits, start, end, low, &eob) else try self.acRefine(item.ac, block, &bits, start, end, low, &eob);
                };
            }
        };
        if (eob != 0) return error.InvalidScan;
        try bits.finish();
        self.pos = bits.pos;
        for (selected[0..count]) |item| for (start..end + 1) |k| {
            self.components[item.index].approximation[k] = low;
        };
    }
    fn colorModel(self: *const Decoder) !ColorModel {
        if (self.count == 1) {
            if (self.adobe != null and self.adobe.? != 0) return error.UnsupportedColor;
            return .gray;
        }
        if (self.count == 3) {
            if (self.adobe) |value| return switch (value) {
                0 => .rgb,
                1 => .ycbcr,
                else => error.UnsupportedColor,
            };
            if (!self.jfif and self.components[0].id == 'R' and self.components[1].id == 'G' and self.components[2].id == 'B') return .rgb;
            return .ycbcr;
        }
        if (self.adobe) |value| return switch (value) {
            0 => .cmyk,
            2 => .ycck,
            else => error.UnsupportedColor,
        };
        return .cmyk;
    }
    fn cacheRow(self: *Decoder, component: *Component, row: u32) !void {
        const slot = row % 2;
        if (component.cache_rows[slot] == row) return;
        const width: usize = @as(usize, component.bx) * 8;
        for (0..component.bx) |x| {
            try self.tick(64);
            var block: [64]i32 = undefined;
            for (component.blocks[@as(usize, row) * component.bx + x], 0..) |value, k| block[k] = value;
            dct.inverse(&block, &component.quant);
            for (0..8) |y| for (0..8) |i| {
                component.cache[@as(usize, slot) * width * 8 + y * width + x * 8 + i] = @intCast(block[y * 8 + i]);
            };
        }
        component.cache_rows[slot] = row;
    }
    fn sampleAt(component: *const Component, x: u32, y: u32) u32 {
        const width: usize = @as(usize, component.bx) * 8;
        return component.cache[@as(usize, (y / 8) % 2) * width * 8 + @as(usize, y % 8) * width + x];
    }
    const Axis = struct { a: u32, b: u32, fraction: u32, denominator: u32 };
    fn axis(coordinate: u32, sampling: u32, maximum: u32, extent: u32) Axis {
        const denominator = 2 * maximum;
        const point = @as(i64, (2 * coordinate + 1) * sampling) - maximum;
        const base = @divFloor(point, denominator);
        const fraction: u32 = @intCast(@mod(point, denominator));
        return .{ .a = @intCast(std.math.clamp(base, 0, extent - 1)), .b = @intCast(std.math.clamp(base + 1, 0, extent - 1)), .fraction = fraction, .denominator = denominator };
    }
    fn sample(self: *Decoder, component: *Component, x: u32, y: u32) !u8 {
        if (self.options.upsampling == .nearest) {
            const xx = @min(component.width - 1, x * component.h / self.max_h);
            const yy = @min(component.height - 1, y * component.v / self.max_v);
            try self.cacheRow(component, yy / 8);
            return @intCast(sampleAt(component, xx, yy));
        }
        const xx = axis(x, component.h, self.max_h, component.width);
        const yy = axis(y, component.v, self.max_v, component.height);
        try self.cacheRow(component, yy.a / 8);
        try self.cacheRow(component, yy.b / 8);
        const upper = sampleAt(component, xx.a, yy.a) * (xx.denominator - xx.fraction) + sampleAt(component, xx.b, yy.a) * xx.fraction;
        const lower = sampleAt(component, xx.a, yy.b) * (xx.denominator - xx.fraction) + sampleAt(component, xx.b, yy.b) * xx.fraction;
        const divisor = xx.denominator * yy.denominator;
        return @intCast((upper * (yy.denominator - yy.fraction) + lower * yy.fraction + divisor / 2) / divisor);
    }
    fn ycbcr(values: [4]u8) [3]u8 {
        const y: i32 = values[0];
        const cb: i32 = @as(i32, values[1]) - 128;
        const cr: i32 = @as(i32, values[2]) - 128;
        return .{ @intCast(std.math.clamp(y + @divFloor(91881 * cr + 32768, 65536), 0, 255)), @intCast(std.math.clamp(y + @divFloor(-22554 * cb - 46802 * cr + 32768, 65536), 0, 255)), @intCast(std.math.clamp(y + @divFloor(116130 * cb + 32768, 65536), 0, 255)) };
    }
    fn render(self: *Decoder) !Result {
        const model = try self.colorModel();
        for (self.components[0..self.count]) |*component| {
            if (component.approximation[0] < 0) return error.IncompleteImage;
            if (!self.progressive) for (component.approximation) |value| if (value != 0) return error.IncompleteImage;
            component.cache = try self.account.alloc(u8, @as(usize, component.bx) * 8 * 16);
        }
        const size = try std.math.mul(usize, @as(usize, self.width) * self.height, if (self.count == 1) 1 else 3);
        var result = Result{ .allocator = self.account.allocator, .pixels = try self.account.alloc(u8, size), .width = self.width, .height = self.height, .components = @intCast(self.count), .progressive = self.progressive, .scans = self.scans, .color_model = model, .upsampling = self.options.upsampling, .sampling = @splat(0), .adobe_transform = self.adobe };
        errdefer result.deinit();
        for (self.components[0..self.count], 0..) |component, i| result.sampling[i] = @intCast((component.h << 4) | component.v);
        for (0..self.height) |y| {
            try self.tick(self.width);
            for (0..self.width) |x| {
                var values: [4]u8 = @splat(0);
                for (self.components[0..self.count], 0..) |_, i| values[i] = try self.sample(&self.components[i], @intCast(x), @intCast(y));
                const offset = (y * self.width + x) * (if (self.count == 1) @as(usize, 1) else 3);
                if (self.count == 1) {
                    result.pixels[offset] = values[0];
                    continue;
                }
                var rgb: [3]u8 = undefined;
                switch (model) {
                    .gray => unreachable,
                    .rgb => rgb = values[0..3].*,
                    .ycbcr => rgb = ycbcr(values),
                    .cmyk, .ycck => {
                        if (model == .ycck) {
                            const decoded = ycbcr(values);
                            for (0..3) |i| values[i] = 255 - decoded[i];
                        }
                        for (0..3) |i| {
                            const sample_color: u32 = if (self.adobe != null) values[i] else 255 - values[i];
                            const black: u32 = if (self.adobe != null) values[3] else 255 - values[3];
                            rgb[i] = @intCast((sample_color * black + 127) / 255);
                        }
                    },
                }
                @memcpy(result.pixels[offset..][0..3], &rgb);
            }
        }
        if (self.exif) |bytes| {
            result.exif = try self.account.alloc(u8, bytes.len);
            @memcpy(result.exif.?, bytes);
        }
        if (self.icc_count) |count| {
            var total: usize = 0;
            for (self.icc[0..count]) |maybe| {
                total += (maybe orelse return error.IncompleteIcc).len;
            }
            result.icc = try self.account.alloc(u8, total);
            var offset: usize = 0;
            for (self.icc[0..count]) |maybe| {
                const bytes = maybe.?;
                @memcpy(result.icc.?[offset..][0..bytes.len], bytes);
                offset += bytes.len;
            }
        }
        result.working_peak = self.account.peak;
        result.work_units = self.work;
        return result;
    }
};
pub fn decode(allocator: std.mem.Allocator, data: []const u8, options: Options) !Result {
    try options.limits.validate();
    if (data.len > options.limits.max_input_bytes) return error.InputLimit;
    if (data.len < 4 or !std.mem.eql(u8, data[0..2], &.{ 0xff, 0xd8 })) return error.InvalidSignature;
    var decoder = Decoder{ .data = data, .options = options, .account = .{ .allocator = allocator, .limit = options.limits.max_working_bytes } };
    defer decoder.deinit();
    while (decoder.pos < data.len) {
        const code = try decoder.marker();
        if (code == 0xd9) {
            if (decoder.scans == 0 or decoder.pos != data.len) return error.IncompleteImage;
            return decoder.render();
        }
        if (code == 0xd8 or code == 1 or (code >= 0xd0 and code <= 0xd7)) return error.InvalidMarker;
        const bytes = try decoder.segment();
        switch (code) {
            0xc0, 0xc1, 0xc2 => try decoder.frame(bytes, code),
            0xc4 => try decoder.codes(bytes),
            0xdb => try decoder.tables(bytes),
            0xda => try decoder.scan(bytes),
            0xdd => {
                if (bytes.len != 2) return error.InvalidRestart;
                decoder.restart = std.mem.readInt(u16, bytes[0..2], .big);
            },
            0xe0...0xef => try decoder.metadata(code, bytes),
            0xfe => {},
            else => return error.UnsupportedCoding,
        }
    }
    return error.TruncatedData;
}

test "strict JPEG entropy codes and byte stuffing do not consume markers" {
    const t = std.testing;
    const table = try Huffman.init(&.{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, &.{7});
    var bits = Bits{ .data = &.{ 0x7f, 0xff, 0xd9 }, .pos = 0 };
    try t.expectEqual(@as(u8, 7), try table.read(&bits));
    try bits.finish();
    try t.expectEqual(@as(usize, 1), bits.pos);
    var stuffed = Bits{ .data = &.{ 0xff, 0, 0xff, 0xd9 }, .pos = 0 };
    try t.expectEqual(@as(u32, 255), try stuffed.read(8));
    try t.expect(!try stuffed.ensure(1));
    try t.expectEqual(@as(usize, 2), stuffed.pos);
    try t.expectError(error.InvalidHuffman, Huffman.init(&.{ 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, &.{ 1, 2 }));
}
test "JPEG invalid headers and cancellation fail before pixel allocation" {
    const t = std.testing;
    try t.expectError(error.InvalidSignature, decode(t.allocator, "no jpeg", .{}));
    try t.expectError(error.TruncatedData, decode(t.allocator, &.{ 0xff, 0xd8, 0xff, 0xdb }, .{}));
    const Cancel = struct {
        fn check(_: ?*anyopaque) bool {
            return false;
        }
    };
    try t.expectError(error.Cancelled, decode(t.allocator, &.{ 0xff, 0xd8, 0xff, 0xd9 }, .{ .checkpoint = .{ .call = Cancel.check } }));
}

fn testImage(allocator: std.mem.Allocator) ![]u8 {
    const Encoder = @import("jpeg_encoder.zig").Encoder;
    var encoder = Encoder.init(allocator);
    defer encoder.deinit();
    const pixels: [9 * 17][3]u8 = @splat(.{ 213, 74, 31 });
    _ = try encoder.encode(std.mem.asBytes(&pixels), 9, 17, 9 * 3, 3, 95);
    return encoder.output.toOwnedSlice(allocator);
}
fn allocationProbe(allocator: std.mem.Allocator, encoded: []const u8) !void {
    var result = try decode(allocator, encoded, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(u32, 9), result.width);
    try std.testing.expectEqual(@as(u32, 17), result.height);
    try std.testing.expectEqual(@as(usize, 9 * 17 * 3), result.pixels.len);
}
test "JPEG decoder releases every partial allocation and owns input-independent pixels" {
    const t = std.testing;
    const data = try testImage(t.allocator);
    defer t.allocator.free(data);
    try t.checkAllAllocationFailures(t.allocator, allocationProbe, .{data});
    var result = try decode(t.allocator, data, .{});
    defer result.deinit();
    @memset(data, 0);
    for (0..9 * 17) |i| {
        try t.expectApproxEqAbs(@as(f64, 213), @as(f64, @floatFromInt(result.pixels[i * 3])), 3);
        t.expectApproxEqAbs(@as(f64, 74), @as(f64, @floatFromInt(result.pixels[i * 3 + 1])), 3) catch |err| {
            std.debug.print("JPEG uniform mismatch pixel {d},{d}, rgb={any}, first={any}, model={s}\n", .{ i % 9, i / 9, result.pixels[i * 3 ..][0..3], result.pixels[0..12], @tagName(result.color_model) });
            return err;
        };
        try t.expectApproxEqAbs(@as(f64, 31), @as(f64, @floatFromInt(result.pixels[i * 3 + 2])), 3);
    }
}
test "JPEG separate input output working and work ceilings reject without leaks" {
    const t = std.testing;
    const data = try testImage(t.allocator);
    defer t.allocator.free(data);
    try t.expectError(error.InputLimit, decode(t.allocator, data, .{ .limits = .{ .max_input_bytes = data.len - 1 } }));
    try t.expectError(error.OutputLimit, decode(t.allocator, data, .{ .limits = .{ .max_output_bytes = 9 * 17 * 3 - 1 } }));
    try t.expectError(error.WorkingLimit, decode(t.allocator, data, .{ .limits = .{ .max_working_bytes = 1 } }));
    try t.expectError(error.WorkLimit, decode(t.allocator, data, .{ .limits = .{ .max_work_units = 100 } }));
    try t.expectError(error.MarkerLimit, decode(t.allocator, data, .{ .limits = .{ .max_markers = 1 } }));
    var completed = try decode(t.allocator, data, .{});
    defer completed.deinit();
    try t.expect(completed.working_peak > completed.ownedBytes());
    const exact = completed.working_peak;
    var bounded = try decode(t.allocator, data, .{ .limits = .{ .max_working_bytes = exact, .max_work_units = completed.work_units } });
    defer bounded.deinit();
    try t.expectEqualSlices(u8, completed.pixels, bounded.pixels);
    try t.expectError(error.WorkingLimit, decode(t.allocator, data, .{ .limits = .{ .max_working_bytes = exact - 1 } }));
    try t.expectError(error.WorkLimit, decode(t.allocator, data, .{ .limits = .{ .max_work_units = completed.work_units - 1 } }));
}
test "JPEG malformed coefficient and segment mutations cannot escape ownership or bounds" {
    const t = std.testing;
    const data = try testImage(t.allocator);
    defer t.allocator.free(data);
    for (0..data.len) |end| {
        if (decode(t.allocator, data[0..end], .{})) |value| {
            var result = value;
            result.deinit();
            return error.AcceptedTruncation;
        } else |_| {}
    }
    for (0..data.len) |at| {
        const saved = data[at];
        defer data[at] = saved;
        for ([_]u8{ 0, 255, saved ^ 0x80 }) |byte| {
            data[at] = byte;
            if (decode(t.allocator, data, .{ .limits = .{ .max_working_bytes = 16 * 1024 * 1024, .max_output_bytes = 1024 * 1024, .max_work_units = 1024 * 1024 } })) |value| {
                var result = value;
                result.deinit();
            } else |_| {}
        }
    }
}

fn metadataImage(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const prefix = [_]u8{ 0xff, 0xe1, 0, 12, 'E', 'x', 'i', 'f', 0, 0, 'I', 'I', 42, 0, 0xff, 0xe2, 0, 20, 'I', 'C', 'C', '_', 'P', 'R', 'O', 'F', 'I', 'L', 'E', 0, 1, 1, 9, 8, 7, 6 };
    const output = try allocator.alloc(u8, data.len + prefix.len);
    @memcpy(output[0..2], data[0..2]);
    @memcpy(output[2..][0..prefix.len], &prefix);
    @memcpy(output[2 + prefix.len ..], data[2..]);
    return output;
}
test "JPEG metadata is owned bounded and partial result allocation failures clean up" {
    const t = std.testing;
    const base = try testImage(t.allocator);
    defer t.allocator.free(base);
    const data = try metadataImage(t.allocator, base);
    defer t.allocator.free(data);
    try t.checkAllAllocationFailures(t.allocator, allocationProbe, .{data});
    try t.expectError(error.MetadataLimit, decode(t.allocator, data, .{ .limits = .{ .max_metadata_bytes = 7 } }));
    var result = try decode(t.allocator, data, .{});
    defer result.deinit();
    try t.expectEqualSlices(u8, &.{ 9, 8, 7, 6 }, result.icc.?);
    try t.expectEqualSlices(u8, &.{ 'I', 'I', 42, 0 }, result.exif.?);
    data[33] = 2; // Advertised ICC fragment count, with fragment two absent.
    try t.expectError(error.IncompleteIcc, decode(t.allocator, data, .{}));
    @memset(data, 0);
    try t.expectEqualSlices(u8, &.{ 9, 8, 7, 6 }, result.icc.?);
}

test "JPEG runtime inverse and color conversion preserve uniform component values" {
    const t = std.testing;
    var values: [4]u8 = .{ 110, 83, 201, 0 };
    for ([_]i32{ -18, -45, 73 }, 0..) |level, i| {
        var block: [64]i32 = @splat(0);
        block[0] = level * 8;
        std.mem.doNotOptimizeAway(&block);
        dct.inverse(&block, &@as([64]u16, @splat(1)));
        for (block) |sample_value| try t.expectEqual(level + 128, sample_value);
        values[i] = @intCast(block[0]);
    }
    std.mem.doNotOptimizeAway(&values);
    const rgb = Decoder.ycbcr(values);
    try t.expectApproxEqAbs(@as(f64, 213), @as(f64, @floatFromInt(rgb[0])), 3);
    try t.expectApproxEqAbs(@as(f64, 74), @as(f64, @floatFromInt(rgb[1])), 3);
    try t.expectApproxEqAbs(@as(f64, 31), @as(f64, @floatFromInt(rgb[2])), 3);
}
