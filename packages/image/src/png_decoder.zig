//! Strict bounded PNG/APNG decoding to owned integer pixels. Pixel reconstruction
//! adapts Home formats/png.zig; container validation and bounded planning are
//! shared with hosted consumers. zlib uses the existing caller-owned adapter.
const std = @import("std");
const zlib = @import("formats/zlib_stream.zig");
const pixel = @import("formats/pixel_view.zig");
pub const signature = "\x89PNG\r\n\x1a\n";
pub const frame_limit = 256;
pub const chunk_limit = 16384;
pub const Limits = struct {
    max_input_bytes: usize = 64 * 1024 * 1024,
    max_output_bytes: usize = 256 * 1024 * 1024,
    max_working_bytes: usize = 512 * 1024 * 1024,
    max_metadata_bytes: usize = 16 * 1024 * 1024,
    max_frames: usize = frame_limit,
    max_chunks: usize = chunk_limit,
    pub fn validate(self: Limits) !void {
        if (self.max_input_bytes == 0 or self.max_input_bytes > std.math.maxInt(u31) or self.max_output_bytes == 0 or self.max_output_bytes > std.math.maxInt(u31) or self.max_working_bytes == 0 or self.max_metadata_bytes == 0 or self.max_metadata_bytes > 16 * 1024 * 1024 or self.max_frames == 0 or self.max_frames > frame_limit or self.max_chunks == 0 or self.max_chunks > chunk_limit) return error.InvalidLimits;
    }
};
pub const Checkpoint = struct {
    context: ?*anyopaque = null,
    call: ?*const fn (?*anyopaque) bool = null,
    pub fn check(self: Checkpoint) !void {
        if (self.call) |callback| if (!callback(self.context)) return error.Cancelled;
    }
};
pub const Options = struct {
    limits: Limits = .{},
    /// Home Image retains palette indices; raster consumers can expand to RGBA8.
    expand_palette: bool = false,
    checkpoint: Checkpoint = .{},
};
pub const Format = enum(u32) { gray, rgb, rgba, indexed };
pub const Raster = struct {
    pixels: []u8 = &.{},
    width: u32 = 0,
    height: u32 = 0,
    stride: usize = 0,
    format: Format = .gray,
    bits: u8 = 8,
    pub fn view(self: Raster) !pixel.View {
        const format: pixel.Format = switch (self.format) {
            .gray => .gray,
            .rgb => .rgb,
            .rgba => .rgba,
            .indexed => return error.IndexedRaster,
        };
        return .{ .data = self.pixels, .width = self.width, .height = self.height, .stride = self.stride, .format = format, .bits = self.bits };
    }
};
pub const Control = struct {
    width: u32,
    height: u32,
    x: u32 = 0,
    y: u32 = 0,
    delay_num: u16 = 0,
    delay_den: u16 = 100,
    dispose: u8 = 0,
    blend: u8 = 0,
};
pub const Frame = struct { raster: Raster, control: Control };
pub const Metadata = struct {
    icc: ?[]u8 = null,
    exif: ?[]u8 = null,
    srgb: ?u8 = null,
    gamma: ?u32 = null,
    chromaticities: ?[8]u32 = null,
    cicp: ?[4]u8 = null,
};
pub const Result = struct {
    allocator: std.mem.Allocator,
    default_image: Raster = .{},
    frames: []Frame = &.{},
    default_is_frame: bool = false,
    plays: u32 = 0,
    source_depth: u8,
    source_color: u8,
    interlaced: bool,
    palette: [1024]u8 = @splat(0),
    palette_count: u16 = 0,
    metadata: Metadata = .{},
    pub fn deinit(self: *Result) void {
        self.allocator.free(self.default_image.pixels);
        for (self.frames) |frame| self.allocator.free(frame.raster.pixels);
        self.allocator.free(self.frames);
        if (self.metadata.icc) |bytes| self.allocator.free(bytes);
        if (self.metadata.exif) |bytes| self.allocator.free(bytes);
        self.* = undefined;
    }
    /// Sum surviving owned allocations. No native zlib workspace survives decode.
    pub fn ownedBytes(self: Result) usize {
        var total = self.default_image.pixels.len + self.frames.len * @sizeOf(Frame);
        for (self.frames) |frame| total += frame.raster.pixels.len;
        if (self.metadata.icc) |bytes| total += bytes.len;
        if (self.metadata.exif) |bytes| total += bytes.len;
        return total;
    }
};
const Header = struct {
    width: u32,
    height: u32,
    depth: u8,
    color: u8,
    interlace: bool,
    fn parse(bytes: []const u8) !Header {
        if (bytes.len != 13 or bytes[10] != 0 or bytes[11] != 0 or bytes[12] > 1) return error.InvalidHeader;
        const result = Header{ .width = be32(bytes, 0), .height = be32(bytes, 4), .depth = bytes[8], .color = bytes[9], .interlace = bytes[12] == 1 };
        if (result.width == 0 or result.height == 0 or result.width > std.math.maxInt(u31) or result.height > std.math.maxInt(u31)) return error.InvalidGeometry;
        const valid = switch (result.color) {
            0 => result.depth == 1 or result.depth == 2 or result.depth == 4 or result.depth == 8 or result.depth == 16,
            2, 4, 6 => result.depth == 8 or result.depth == 16,
            3 => result.depth == 1 or result.depth == 2 or result.depth == 4 or result.depth == 8,
            else => false,
        };
        if (!valid) return error.InvalidHeader;
        return result;
    }
    fn samples(self: Header) usize {
        return switch (self.color) {
            0, 3 => 1,
            2 => 3,
            4 => 2,
            6 => 4,
            else => unreachable,
        };
    }
    fn rowBytes(self: Header, width: u32) !usize {
        const bits = try std.math.mul(usize, width, self.samples() * self.depth);
        return (try std.math.add(usize, bits, 7)) / 8;
    }
};
fn be32(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .big);
}
fn be16(bytes: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, bytes[at..][0..2], .big);
}
const Chunk = struct {
    start: usize,
    end: usize,
    kind: []const u8,
    data: []const u8,
    fn is(self: Chunk, name: *const [4]u8) bool {
        return std.mem.eql(u8, self.kind, name);
    }
};
const Reader = struct {
    data: []const u8,
    pos: usize = 8,
    fn next(self: *Reader) !Chunk {
        if (self.pos > self.data.len or self.data.len - self.pos < 12) return error.TruncatedData;
        const size = be32(self.data, self.pos);
        if (size > std.math.maxInt(u31) or size > self.data.len - self.pos - 12) return error.InvalidChunk;
        const name = self.data[self.pos + 4 ..][0..4];
        for (name) |byte| if (!std.ascii.isAlphabetic(byte)) return error.InvalidChunk;
        if (name[2] & 32 != 0) return error.InvalidChunk;
        const end = self.pos + 12 + size;
        const bytes = self.data[self.pos + 8 ..][0..size];
        var crc = std.hash.Crc32.init();
        crc.update(name);
        crc.update(bytes);
        if (crc.final() != be32(self.data, end - 4)) return error.InvalidChecksum;
        const result = Chunk{ .start = self.pos, .end = end, .kind = name, .data = bytes };
        self.pos = end;
        return result;
    }
};
const Range = struct {
    start: usize = 0,
    end: usize = 0,
    size: usize = 0,
    frame_data: bool = false,
    fn add(self: *Range, chunk: Chunk, skip: usize) !void {
        if (self.start == 0) self.start = chunk.start;
        self.end = chunk.end;
        self.size = try std.math.add(usize, self.size, chunk.data.len - skip);
    }
};
const FramePlan = struct { control: Control, range: Range };
const Document = struct {
    header: Header,
    default_range: Range = .{},
    frames: [frame_limit]FramePlan = undefined,
    count: usize = 0,
    declared_frames: ?u32 = null,
    plays: u32 = 0,
    default_is_frame: bool = false,
    palette: [1024]u8 = @splat(0),
    palette_count: u16 = 0,
    transparency: ?[]const u8 = null,
    icc_compressed: ?[]const u8 = null,
    exif: ?[]const u8 = null,
    srgb: ?u8 = null,
    gamma: ?u32 = null,
    chromaticities: ?[8]u32 = null,
    cicp: ?[4]u8 = null,
    fn sequence(next: *u64, value: u32) !void {
        if (value > std.math.maxInt(u31) or value != next.*) return error.InvalidSequence;
        next.* += 1;
    }
    fn parse(data: []const u8, options: Options) !Document {
        try options.limits.validate();
        if (data.len > options.limits.max_input_bytes) return error.DecodeLimit;
        if (data.len < 8 or !std.mem.eql(u8, data[0..8], signature)) return error.InvalidFormat;
        var reader = Reader{ .data = data };
        const first = try reader.next();
        if (!first.is("IHDR")) return error.InvalidChunkOrder;
        var doc = Document{ .header = try Header.parse(first.data) };
        var chunks: usize = 1;
        var idat = false;
        var idat_ended = false;
        var seq: u64 = 0;
        while (true) {
            try options.checkpoint.check();
            if (chunks >= options.limits.max_chunks) return error.DecodeLimit;
            const chunk = try reader.next();
            chunks += 1;
            if (idat and !chunk.is("IDAT")) idat_ended = true;
            if (chunk.is("IHDR")) return error.InvalidChunkOrder;
            if (chunk.is("IDAT")) {
                if (idat_ended or (doc.header.color == 3 and doc.palette_count == 0)) return error.InvalidChunkOrder;
                idat = true;
                try doc.default_range.add(chunk, 0);
                if (doc.default_is_frame) try doc.frames[0].range.add(chunk, 0);
            } else if (chunk.is("PLTE")) {
                if (idat or doc.palette_count != 0 or doc.transparency != null or doc.header.color == 0 or doc.header.color == 4 or chunk.data.len == 0 or chunk.data.len > 768 or chunk.data.len % 3 != 0) return error.InvalidPalette;
                const count = chunk.data.len / 3;
                if (doc.header.color == 3 and count > @as(usize, 1) << @intCast(doc.header.depth)) return error.InvalidPalette;
                doc.palette_count = @intCast(count);
                for (0..count) |i| {
                    @memcpy(doc.palette[i * 4 ..][0..3], chunk.data[i * 3 ..][0..3]);
                    doc.palette[i * 4 + 3] = 255;
                }
            } else if (chunk.is("tRNS")) {
                if (idat or doc.transparency != null) return error.InvalidTransparency;
                switch (doc.header.color) {
                    0 => {
                        if (chunk.data.len != 2 or be16(chunk.data, 0) > sampleMax(doc.header.depth)) return error.InvalidTransparency;
                    },
                    2 => {
                        if (chunk.data.len != 6) return error.InvalidTransparency;
                        for (0..3) |i| if (be16(chunk.data, i * 2) > sampleMax(doc.header.depth)) return error.InvalidTransparency;
                    },
                    3 => {
                        if (doc.palette_count == 0 or chunk.data.len == 0 or chunk.data.len > doc.palette_count) return error.InvalidTransparency;
                        for (chunk.data, 0..) |alpha, i| doc.palette[i * 4 + 3] = alpha;
                    },
                    else => return error.InvalidTransparency,
                }
                doc.transparency = chunk.data;
            } else if (chunk.is("acTL")) {
                if (idat or doc.declared_frames != null or chunk.data.len != 8) return error.InvalidAnimation;
                const count = be32(chunk.data, 0);
                const plays = be32(chunk.data, 4);
                if (count == 0 or count > options.limits.max_frames or plays > std.math.maxInt(u31)) return error.DecodeLimit;
                doc.declared_frames = count;
                doc.plays = plays;
            } else if (chunk.is("fcTL")) {
                if (doc.declared_frames == null or chunk.data.len != 26 or doc.count >= doc.declared_frames.? or doc.count >= options.limits.max_frames) return error.InvalidAnimation;
                if (doc.count != 0 and doc.frames[doc.count - 1].range.size == 0) return error.InvalidAnimation;
                try sequence(&seq, be32(chunk.data, 0));
                const control = Control{ .width = be32(chunk.data, 4), .height = be32(chunk.data, 8), .x = be32(chunk.data, 12), .y = be32(chunk.data, 16), .delay_num = be16(chunk.data, 20), .delay_den = be16(chunk.data, 22), .dispose = chunk.data[24], .blend = chunk.data[25] };
                if (control.width == 0 or control.height == 0 or control.x > doc.header.width or control.y > doc.header.height or control.width > doc.header.width - control.x or control.height > doc.header.height - control.y or control.dispose > 2 or control.blend > 1) return error.InvalidAnimation;
                if (!idat) {
                    if (doc.count != 0 or control.x != 0 or control.y != 0 or control.width != doc.header.width or control.height != doc.header.height) return error.InvalidAnimation;
                    doc.default_is_frame = true;
                }
                doc.frames[doc.count] = .{ .control = control, .range = .{ .frame_data = idat } };
                doc.count += 1;
            } else if (chunk.is("fdAT")) {
                if (!idat or doc.declared_frames == null or doc.count == 0 or !doc.frames[doc.count - 1].range.frame_data or chunk.data.len < 4) return error.InvalidAnimation;
                try sequence(&seq, be32(chunk.data, 0));
                try doc.frames[doc.count - 1].range.add(chunk, 4);
            } else if (chunk.is("iCCP")) {
                if (idat or doc.palette_count != 0 or doc.icc_compressed != null) return error.InvalidMetadata;
                const end = std.mem.indexOfScalar(u8, chunk.data, 0) orelse return error.InvalidMetadata;
                if (end == 0 or end > 79 or chunk.data.len < end + 3 or chunk.data[end + 1] != 0 or chunk.data[0] == 32 or chunk.data[end - 1] == 32) return error.InvalidMetadata;
                var space = false;
                for (chunk.data[0..end]) |byte| {
                    if (!((byte >= 32 and byte <= 126) or byte >= 161) or (space and byte == 32)) return error.InvalidMetadata;
                    space = byte == 32;
                }
                doc.icc_compressed = chunk.data[end + 2 ..];
            } else if (chunk.is("eXIf")) {
                if (doc.exif != null or chunk.data.len > options.limits.max_metadata_bytes or chunk.data.len < 8 or !(std.mem.eql(u8, chunk.data[0..2], "II") or std.mem.eql(u8, chunk.data[0..2], "MM"))) return error.InvalidMetadata;
                _ = try @import("metadata/exif_layout.zig").validate(chunk.data);
                doc.exif = chunk.data;
            } else if (chunk.is("sRGB")) {
                if (idat or doc.palette_count != 0 or doc.srgb != null or chunk.data.len != 1 or chunk.data[0] > 3) return error.InvalidMetadata;
                doc.srgb = chunk.data[0];
            } else if (chunk.is("gAMA")) {
                if (idat or doc.palette_count != 0 or doc.gamma != null or chunk.data.len != 4 or be32(chunk.data, 0) == 0 or be32(chunk.data, 0) > std.math.maxInt(u31)) return error.InvalidMetadata;
                doc.gamma = be32(chunk.data, 0);
            } else if (chunk.is("cHRM")) {
                if (idat or doc.palette_count != 0 or doc.chromaticities != null or chunk.data.len != 32) return error.InvalidMetadata;
                var values: [8]u32 = undefined;
                for (&values, 0..) |*value, i| {
                    value.* = be32(chunk.data, i * 4);
                    if (value.* > std.math.maxInt(u31)) return error.InvalidMetadata;
                }
                doc.chromaticities = values;
            } else if (chunk.is("cICP")) {
                if (idat or doc.palette_count != 0 or doc.cicp != null or chunk.data.len != 4 or chunk.data[2] != 0 or chunk.data[3] > 1) return error.InvalidMetadata;
                doc.cicp = chunk.data[0..4].*;
            } else if (chunk.is("IEND")) {
                if (!idat or doc.default_range.size == 0 or chunk.data.len != 0 or reader.pos != data.len) return error.InvalidChunkOrder;
                if (doc.declared_frames) |count| {
                    if (count != doc.count) return error.InvalidAnimation;
                    for (doc.frames[0..doc.count]) |frame| if (frame.range.size == 0) return error.InvalidAnimation;
                }
                return doc;
            } else if (chunk.kind[0] & 32 == 0) return error.UnsupportedCriticalChunk;
        }
    }
};
fn sampleMax(depth: u8) u16 {
    return if (depth == 16) 65535 else (@as(u16, 1) << @intCast(depth)) - 1;
}

const Pass = struct { width: u32, height: u32, x: u32, y: u32, dx: u32, dy: u32, row: usize };
fn passFor(header: Header, index: usize) !Pass {
    const starts_x = [_]u32{ 0, 4, 0, 2, 0, 1, 0 };
    const starts_y = [_]u32{ 0, 0, 4, 0, 2, 0, 1 };
    const steps_x = [_]u32{ 8, 8, 4, 4, 2, 2, 1 };
    const steps_y = [_]u32{ 8, 8, 8, 4, 4, 2, 2 };
    const x = if (header.interlace) starts_x[index] else 0;
    const y = if (header.interlace) starts_y[index] else 0;
    const dx = if (header.interlace) steps_x[index] else 1;
    const dy = if (header.interlace) steps_y[index] else 1;
    const width = if (x >= header.width) 0 else (header.width - x - 1) / dx + 1;
    const height = if (y >= header.height) 0 else (header.height - y - 1) / dy + 1;
    return .{ .width = width, .height = height, .x = x, .y = y, .dx = dx, .dy = dy, .row = if (width == 0 or height == 0) 0 else try header.rowBytes(width) };
}
fn rawSize(header: Header) !usize {
    var total: usize = 0;
    for (0..@as(usize, if (header.interlace) 7 else 1)) |i| {
        const pass = try passFor(header, i);
        if (pass.row == 0) continue;
        total = try std.math.add(usize, total, try std.math.mul(usize, pass.row + 1, pass.height));
    }
    return total;
}
fn formatFor(doc: *const Document, expand: bool) Format {
    return switch (doc.header.color) {
        0 => if (doc.transparency == null) .gray else .rgba,
        2 => if (doc.transparency == null) .rgb else .rgba,
        3 => if (expand) .rgba else .indexed,
        4, 6 => .rgba,
        else => unreachable,
    };
}
fn channels(format: Format) usize {
    return switch (format) {
        .gray, .indexed => 1,
        .rgb => 3,
        .rgba => 4,
    };
}
fn outputBytes(header: Header, format: Format) !usize {
    const row = try std.math.mul(usize, header.width, channels(format) * @as(usize, if (header.depth == 16) 2 else 1));
    return std.math.mul(usize, row, header.height);
}
fn headerFor(base: Header, control: Control) Header {
    var header = base;
    header.width = control.width;
    header.height = control.height;
    return header;
}
fn checkPlan(doc: *const Document, options: Options) !void {
    const limits = options.limits;
    const format = formatFor(doc, options.expand_palette);
    var output = try outputBytes(doc.header, format);
    var scratch = try std.math.add(usize, doc.default_range.size, try std.math.mul(usize, try doc.header.rowBytes(doc.header.width), 2));
    _ = try rawSize(doc.header);
    for (doc.frames[0..doc.count]) |frame| {
        const header = headerFor(doc.header, frame.control);
        output = try std.math.add(usize, output, try outputBytes(header, format));
        scratch = @max(scratch, try std.math.add(usize, frame.range.size, try std.math.mul(usize, try header.rowBytes(header.width), 2)));
        _ = try rawSize(header);
    }
    if (output > limits.max_output_bytes) return error.DecodeLimit;
    var metadata: usize = if (doc.exif) |bytes| bytes.len else 0;
    if (doc.icc_compressed != null) {
        metadata = try std.math.add(usize, metadata, limits.max_metadata_bytes);
        scratch = @max(scratch, try std.math.mul(usize, limits.max_metadata_bytes, 2));
    }
    const fixed = @sizeOf(Document) + @sizeOf(Result) + doc.count * @sizeOf(Frame) + zlib.inflate_workspace_limit + 32768 + 4096;
    const total = try std.math.add(usize, try std.math.add(usize, output, metadata), try std.math.add(usize, fixed, scratch));
    if (total > limits.max_working_bytes) return error.WorkingLimit;
}
fn compressedCopy(allocator: std.mem.Allocator, data: []const u8, range: Range) ![]u8 {
    const bytes = try allocator.alloc(u8, range.size);
    errdefer allocator.free(bytes);
    var reader = Reader{ .data = data, .pos = range.start };
    var offset: usize = 0;
    while (reader.pos < range.end) {
        const chunk = try reader.next();
        if ((range.frame_data and chunk.is("fdAT")) or (!range.frame_data and chunk.is("IDAT"))) {
            const skip: usize = if (range.frame_data) 4 else 0;
            if (chunk.data.len < skip or chunk.data.len - skip > bytes.len - offset) return error.InvalidAnimation;
            const payload = chunk.data[skip..];
            @memcpy(bytes[offset..][0..payload.len], payload);
            offset += payload.len;
        }
    }
    if (reader.pos != range.end or offset != bytes.len) return error.InvalidAnimation;
    return bytes;
}
fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i16, a) + b - c;
    const da = @abs(p - a);
    const db = @abs(p - b);
    const dc = @abs(p - c);
    return if (da <= db and da <= dc) a else if (db <= dc) b else c;
}
fn sample(row: []const u8, index: usize, depth: u8) u16 {
    if (depth == 16) return be16(row, index * 2);
    if (depth == 8) return row[index];
    const bit = index * depth;
    const shift: u3 = @intCast(8 - depth - bit % 8);
    return (row[bit / 8] >> shift) & @as(u8, @intCast(sampleMax(depth)));
}
const Rows = struct {
    doc: *const Document,
    header: Header,
    target: *Raster,
    options: Options,
    previous: []u8,
    current: []u8,
    pass_index: usize = 0,
    pass: Pass = undefined,
    y: usize = 0,
    offset: usize = 0,
    filter: ?u8 = null,
    fn nextPass(self: *Rows) !void {
        const count: usize = if (self.header.interlace) 7 else 1;
        while (self.pass_index < count) : (self.pass_index += 1) {
            self.pass = try passFor(self.header, self.pass_index);
            if (self.pass.row == 0) continue;
            self.y = 0;
            self.offset = 0;
            self.filter = null;
            @memset(self.previous[0..self.pass.row], 0);
            return;
        }
    }
    pub fn writeAll(self: *Rows, bytes: []const u8) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            try self.options.checkpoint.check();
            if (self.pass_index >= @as(usize, if (self.header.interlace) 7 else 1)) return error.InvalidPixelData;
            if (self.filter == null) {
                self.filter = bytes[offset];
                if (self.filter.? > 4) return error.InvalidFilter;
                offset += 1;
            }
            const count = @min(bytes.len - offset, self.pass.row - self.offset);
            @memcpy(self.current[self.offset..][0..count], bytes[offset..][0..count]);
            self.offset += count;
            offset += count;
            if (self.offset == self.pass.row) {
                try self.finishRow();
                self.y += 1;
                self.offset = 0;
                self.filter = null;
                if (self.y == self.pass.height) {
                    self.pass_index += 1;
                    try self.nextPass();
                }
            }
        }
    }
    fn finishRow(self: *Rows) !void {
        const bpp = @max(1, (self.header.samples() * self.header.depth + 7) / 8);
        const row = self.current[0..self.pass.row];
        const previous = self.previous[0..self.pass.row];
        for (row, 0..) |*byte, i| {
            if (i % 32768 == 0) try self.options.checkpoint.check();
            const a = if (i >= bpp) row[i - bpp] else 0;
            const b = previous[i];
            const c = if (i >= bpp) previous[i - bpp] else 0;
            byte.* +%= switch (self.filter.?) {
                0 => @as(u8, 0),
                1 => a,
                2 => b,
                3 => @intCast((@as(u16, a) + b) / 2),
                4 => paeth(a, b, c),
                else => unreachable,
            };
        }
        const source_max = sampleMax(self.header.depth);
        const target_max: u16 = if (self.target.bits == 16) 65535 else 255;
        const out_channels = channels(self.target.format);
        const out_bytes: usize = self.target.bits / 8;
        for (0..self.pass.width) |x| {
            if (x % 4096 == 0) try self.options.checkpoint.check();
            var values: [4]u16 = .{ 0, 0, 0, target_max };
            const at = x * self.header.samples();
            switch (self.header.color) {
                0, 4 => {
                    const gray = sample(row, at, self.header.depth);
                    const scaled = if (self.header.depth < 8) @as(u16, @intCast(@as(u32, gray) * 255 / source_max)) else gray;
                    values[0..3].* = .{ scaled, scaled, scaled };
                    if (self.header.color == 4) values[3] = sample(row, at + 1, self.header.depth) else if (self.doc.transparency) |key| {
                        if (gray == be16(key, 0)) values[3] = 0;
                    }
                },
                2, 6 => {
                    for (0..3) |ch| values[ch] = sample(row, at + ch, self.header.depth);
                    if (self.header.color == 6) values[3] = sample(row, at + 3, self.header.depth) else if (self.doc.transparency) |key| {
                        if (values[0] == be16(key, 0) and values[1] == be16(key, 2) and values[2] == be16(key, 4)) values[3] = 0;
                    }
                },
                3 => {
                    const index = sample(row, x, self.header.depth);
                    if (index >= self.doc.palette_count) return error.InvalidPaletteIndex;
                    if (self.target.format == .indexed) {
                        values[0] = index;
                    } else {
                        for (0..4) |ch| values[ch] = self.doc.palette[@as(usize, index) * 4 + ch];
                    }
                },
                else => unreachable,
            }
            const dx = self.pass.x + x * self.pass.dx;
            const dy = self.pass.y + self.y * self.pass.dy;
            const dest = self.target.pixels[dy * self.target.stride + dx * out_channels * out_bytes ..];
            for (0..out_channels) |ch| {
                if (out_bytes == 1) dest[ch] = @intCast(values[ch]) else std.mem.writeInt(u16, dest[ch * 2 ..][0..2], values[ch], .little);
            }
        }
        std.mem.swap([]u8, &self.previous, &self.current);
    }
};
fn decodeRaster(allocator: std.mem.Allocator, data: []const u8, doc: *const Document, header: Header, range: Range, options: Options) !Raster {
    try options.checkpoint.check();
    const format = formatFor(doc, options.expand_palette);
    const bits: u8 = if (header.depth == 16) 16 else 8;
    const size = try outputBytes(header, format);
    const pixels = try allocator.alloc(u8, size);
    errdefer allocator.free(pixels);
    @memset(pixels, 0);
    var result = Raster{ .pixels = pixels, .width = header.width, .height = header.height, .stride = @as(usize, header.width) * channels(format) * (bits / 8), .format = format, .bits = bits };
    const compressed = try compressedCopy(allocator, data, range);
    defer allocator.free(compressed);
    const row_size = try header.rowBytes(header.width);
    const scratch = try allocator.alloc(u8, try std.math.mul(usize, row_size, 2));
    defer allocator.free(scratch);
    var rows = Rows{ .doc = doc, .header = header, .target = &result, .options = options, .previous = scratch[0..row_size], .current = scratch[row_size..] };
    try rows.nextPass();
    const expected = try rawSize(header);
    if (try zlib.inflateTo(allocator, compressed, &rows, expected) != expected or rows.filter != null or rows.pass_index != @as(usize, if (header.interlace) 7 else 1)) return error.InvalidPixelData;
    try options.checkpoint.check();
    return result;
}
/// Validate the whole PNG/APNG before allocation, then decode to independent
/// pixel/frame/metadata owners. No source slice survives. Returned samples are
/// little endian, straight-alpha, with source color metadata retained separately;
/// no gamma/gamut conversion, compositing or Exif auto-orientation is applied.
pub fn decode(allocator: std.mem.Allocator, data: []const u8, options: Options) !Result {
    const doc = try Document.parse(data, options);
    try checkPlan(&doc, options);
    var result = Result{ .allocator = allocator, .source_depth = doc.header.depth, .source_color = doc.header.color, .interlaced = doc.header.interlace, .plays = doc.plays, .default_is_frame = doc.default_is_frame, .palette = doc.palette, .palette_count = doc.palette_count };
    errdefer result.deinit();
    result.default_image = try decodeRaster(allocator, data, &doc, doc.header, doc.default_range, options);
    if (doc.count != 0) {
        const frames = try allocator.alloc(Frame, doc.count);
        errdefer allocator.free(frames);
        var done: usize = 0;
        errdefer for (frames[0..done]) |frame| allocator.free(frame.raster.pixels);
        for (doc.frames[0..doc.count], frames, 0..) |plan, *frame, index| {
            try options.checkpoint.check();
            const raster = if (index == 0 and doc.default_is_frame) blk: {
                var copy = result.default_image;
                copy.pixels = try allocator.dupe(u8, copy.pixels);
                break :blk copy;
            } else try decodeRaster(allocator, data, &doc, headerFor(doc.header, plan.control), plan.range, options);
            frame.* = .{ .raster = raster, .control = plan.control };
            done += 1;
        }
        result.frames = frames;
    }
    result.metadata = .{ .srgb = doc.srgb, .gamma = doc.gamma, .chromaticities = doc.chromaticities, .cicp = doc.cicp };
    if (doc.exif) |bytes| result.metadata.exif = try allocator.dupe(u8, bytes);
    if (doc.icc_compressed) |bytes| {
        const used = if (result.metadata.exif) |exif| exif.len else 0;
        if (used >= options.limits.max_metadata_bytes) return error.DecodeLimit;
        const profile = try zlib.inflateOwned(allocator, bytes, options.limits.max_metadata_bytes - used);
        result.metadata.icc = profile;
        _ = try @import("metadata/icc_layout.zig").validate(profile);
        const expected = if (doc.header.color == 0 or doc.header.color == 4) "GRAY" else "RGB ";
        if (!std.mem.eql(u8, profile[16..20], expected)) return error.InvalidProfile;
    }
    try options.checkpoint.check();
    return result;
}

const Encoder = @import("formats/raster_encoder.zig");
test "PNG bounded decoder retains gray RGB RGBA native words across all PNG filters and source retirement" {
    const t = std.testing;
    for ([_]pixel.Format{ .gray, .rgb, .rgba }) |format| for ([_]u8{ 8, 16 }) |bits| for ([_]std.builtin.Endian{ .little, .big }) |endian| {
        const bpp = format.channels() * (bits / 8);
        const width: u32 = 5;
        const height: u32 = 3;
        const row = width * bpp;
        const stride = row + 7;
        var input: [256]u8 = @splat(0xa5);
        for (0..height) |y| for (0..width) |x| for (0..format.channels()) |ch| {
            const value: u16 = @intCast((x * 1753 + y * 3197 + ch * 7769 + 0x1234) % 65536);
            const at = 1 + y * stride + (x * format.channels() + ch) * (bits / 8);
            if (bits == 8) input[at] = @intCast(value >> 8) else std.mem.writeInt(u16, input[at..][0..2], value, endian);
        };
        const view = pixel.View{ .data = input[1..], .width = width, .height = height, .stride = stride, .format = format, .bits = bits, .endian = endian };
        var expected = try pixel.Owned.copy(t.allocator, view, format, bits, .little);
        defer expected.deinit();
        for ([_]Encoder.Filter{ .adaptive, .none, .sub, .up, .average, .paeth }) |filter| {
            const encoded = try Encoder.png(t.allocator, view, .{ .filter = filter });
            defer t.allocator.free(encoded);
            var decoded = try decode(t.allocator, encoded, .{});
            defer decoded.deinit();
            try t.expectEqualSlices(u8, expected.view.data, decoded.default_image.pixels);
            try t.expectEqual(bits, decoded.default_image.bits);
            try t.expectEqual(@as(usize, 0), decoded.frames.len);
        }
    };
}
fn decodeFailureProbe(a: std.mem.Allocator, encoded: []const u8) !void {
    var result = try decode(a, encoded, .{});
    defer result.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 0x34, 0x12, 0x78, 0x56, 0xbc, 0x9a }, result.default_image.pixels);
}
test "PNG decoder unwinds all allocations and rejects complete-input truncations without partial owners" {
    const t = std.testing;
    const bytes = [_]u8{ 0x34, 0x12, 0x78, 0x56, 0xbc, 0x9a };
    const encoded = try Encoder.png(t.allocator, .{ .data = &bytes, .width = 1, .height = 1, .stride = 6, .format = .rgb, .bits = 16 }, .{});
    defer t.allocator.free(encoded);
    try std.testing.checkAllAllocationFailures(t.allocator, decodeFailureProbe, .{encoded});
    for (0..encoded.len) |length| {
        if (decode(t.allocator, encoded[0..length], .{})) |result| {
            var copy = result;
            copy.deinit();
            return error.AcceptedTruncation;
        } else |_| {}
    }
    var limits = Limits{};
    limits.max_output_bytes = 5;
    try t.expectError(error.DecodeLimit, decode(t.failing_allocator, encoded, .{ .limits = limits }));
    limits = .{};
    limits.max_working_bytes = 1;
    try t.expectError(error.WorkingLimit, decode(t.failing_allocator, encoded, .{ .limits = limits }));
    const Cancel = struct {
        fn call(_: ?*anyopaque) bool {
            return false;
        }
    };
    try t.expectError(error.Cancelled, decode(t.failing_allocator, encoded, .{ .checkpoint = .{ .call = Cancel.call } }));
}
test "APNG decoding preserves included and excluded poster frame rectangles words timing disposal and blend" {
    const t = std.testing;
    const animation = @import("formats/apng_encoder.zig");
    const canvas = [_]u8{ 0x34, 0x12, 0x78, 0x56, 0xbc, 0x9a, 0xdc, 0xfe, 0x98, 0xba, 0x54, 0x76 };
    const partial = [_]u8{ 0x01, 0x80, 0x02, 0x90, 0x03, 0xa0 };
    const view = pixel.View{ .data = &canvas, .width = 2, .height = 1, .stride = 12, .format = .rgb, .bits = 16 };
    const patch = pixel.View{ .data = &partial, .width = 1, .height = 1, .stride = 6, .format = .rgb, .bits = 16 };
    const frames = [_]animation.Frame{ .{ .view = view, .delay = .{ .numerator = 3, .denominator = 25 } }, .{ .view = patch, .x = 1, .delay = .{ .numerator = 7, .denominator = 0 }, .dispose = .previous, .blend = .over } };
    for ([_]bool{ false, true }) |poster| {
        const encoded = try animation.encode(t.allocator, .{ .width = 2, .height = 1, .default_image = if (poster) view else null, .frames = &frames, .plays = 7 });
        defer t.allocator.free(encoded);
        var result = try decode(t.allocator, encoded, .{});
        defer result.deinit();
        try t.expectEqual(!poster, result.default_is_frame);
        try t.expectEqual(@as(usize, 2), result.frames.len);
        try t.expectEqual(@as(u32, 7), result.plays);
        try t.expectEqualSlices(u8, &canvas, result.default_image.pixels);
        try t.expectEqualSlices(u8, &canvas, result.frames[0].raster.pixels);
        try t.expectEqualSlices(u8, &partial, result.frames[1].raster.pixels);
        try t.expectEqual(@as(u32, 1), result.frames[1].control.x);
        try t.expectEqual(@as(u16, 7), result.frames[1].control.delay_num);
        try t.expectEqual(@as(u16, 0), result.frames[1].control.delay_den);
        try t.expectEqual(@as(u8, 2), result.frames[1].control.dispose);
        try t.expectEqual(@as(u8, 1), result.frames[1].control.blend);
        result.frames[0].raster.pixels[0] = 0;
        try t.expectEqual(@as(u8, 0x34), result.default_image.pixels[0]);
    }
}

fn testChunk(list: *std.ArrayList(u8), name: *const [4]u8, bytes: []const u8) !void {
    const a = std.testing.allocator;
    var word: [4]u8 = undefined;
    std.mem.writeInt(u32, &word, @intCast(bytes.len), .big);
    try list.appendSlice(a, &word);
    try list.appendSlice(a, name);
    try list.appendSlice(a, bytes);
    var crc = std.hash.Crc32.init();
    crc.update(name);
    crc.update(bytes);
    std.mem.writeInt(u32, &word, crc.final(), .big);
    try list.appendSlice(a, &word);
}
fn testPng(raw: []const u8, header: [13]u8, extras: []const u8) ![]u8 {
    const a = std.testing.allocator;
    const compressed = try zlib.compress(a, raw, 1);
    defer a.free(compressed);
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(a);
    try list.appendSlice(a, signature);
    try testChunk(&list, "IHDR", &header);
    try list.appendSlice(a, extras);
    try testChunk(&list, "IDAT", compressed);
    try testChunk(&list, "IEND", &.{});
    return list.toOwnedSlice(a);
}
fn testHeader(depth: u8, color: u8) [13]u8 {
    return .{ 0, 0, 0, 1, 0, 0, 0, 1, depth, color, 0, 0, 0 };
}
fn testReject(bytes: []const u8) !void {
    if (decode(std.testing.allocator, bytes, .{})) |decoded| {
        var result = decoded;
        result.deinit();
        return error.AcceptedMalformedPng;
    } else |_| {}
}
fn testCrc(bytes: []u8, start: usize) void {
    const length = be32(bytes, start);
    const end = start + 12 + length;
    std.mem.writeInt(u32, bytes[end - 4 ..][0..4], std.hash.Crc32.hash(bytes[start + 4 .. end - 4]), .big);
}
test "PNG rejects CRC critical chunks invalid header and filter values checksums trailing data and extra pixels" {
    const a = std.testing.allocator;
    const valid = try testPng(&.{ 0, 11, 22, 33 }, testHeader(8, 2), &.{});
    defer a.free(valid);
    const mutable = try a.dupe(u8, valid);
    defer a.free(mutable);
    for ([_]usize{ 12, 16, 20, 24, 25, 26, 27, 28, valid.len - 1 }) |offset| {
        @memcpy(mutable, valid);
        mutable[offset] = 255;
        try testReject(mutable);
    }
    for ([_]usize{ 16, 20, 24, 25, 26, 27, 28 }) |offset| {
        @memcpy(mutable, valid);
        mutable[offset] = 255;
        testCrc(mutable, 8);
        try testReject(mutable);
    }
    for ([_][]const u8{ &.{ 5, 11, 22, 33 }, &.{ 0, 11, 22 }, &.{ 0, 11, 22, 33, 44 } }) |raw| {
        const input = try testPng(raw, testHeader(8, 2), &.{});
        defer a.free(input);
        try testReject(input);
    }
    var extras: std.ArrayList(u8) = .empty;
    defer extras.deinit(a);
    try testChunk(&extras, "ABCD", &.{});
    const critical = try testPng(&.{ 0, 11, 22, 33 }, testHeader(8, 2), extras.items);
    defer a.free(critical);
    try std.testing.expectError(error.UnsupportedCriticalChunk, decode(a, critical, .{}));
    const trailing = try std.mem.concat(a, u8, &.{ valid, &.{0} });
    defer a.free(trailing);
    try testReject(trailing);
    @memcpy(mutable, valid);
    // Keep chunk CRC valid so zlib itself must reject its bad Adler checksum.
    mutable[mutable.len - 17] ^= 1;
    testCrc(mutable, 33);
    try testReject(mutable);
}
test "PNG validates palette entries transparency and consecutive IDAT including arbitrary zlib splits" {
    const a = std.testing.allocator;
    var extras: std.ArrayList(u8) = .empty;
    defer extras.deinit(a);
    try testChunk(&extras, "PLTE", &.{ 10, 20, 30, 40, 50, 60 });
    try testChunk(&extras, "tRNS", &.{ 0, 91 });
    const packed_png = try testPng(&.{ 0, 0x40 }, testHeader(1, 3), extras.items);
    defer a.free(packed_png);
    var decoded = try decode(a, packed_png, .{});
    defer decoded.deinit();
    try std.testing.expectEqual(Format.indexed, decoded.default_image.format);
    try std.testing.expectEqualSlices(u8, &.{0}, decoded.default_image.pixels);
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30, 0, 40, 50, 60, 91 }, decoded.palette[0..8]);
    const invalid_index = try testPng(&.{ 0, 2 }, testHeader(8, 3), extras.items);
    defer a.free(invalid_index);
    try std.testing.expectError(error.InvalidPaletteIndex, decode(a, invalid_index, .{}));
    const valid = try testPng(&.{ 0, 11, 22, 33 }, testHeader(8, 2), &.{});
    defer a.free(valid);
    const chunk = valid[41 .. valid.len - 16];
    for (0..chunk.len + 1) |split| {
        var parts: std.ArrayList(u8) = .empty;
        defer parts.deinit(a);
        try parts.appendSlice(a, valid[0..33]);
        try testChunk(&parts, "IDAT", chunk[0..split]);
        try testChunk(&parts, "IDAT", &.{});
        try testChunk(&parts, "IDAT", chunk[split..]);
        try testChunk(&parts, "IEND", &.{});
        var result = try decode(a, parts.items, .{});
        defer result.deinit();
        try std.testing.expectEqualSlices(u8, &.{ 11, 22, 33 }, result.default_image.pixels);
        // An intervening ancillary chunk closes the IDAT group.
        var bad: std.ArrayList(u8) = .empty;
        defer bad.deinit(a);
        try bad.appendSlice(a, valid[0..33]);
        try testChunk(&bad, "IDAT", chunk[0..split]);
        try testChunk(&bad, "tEXt", "k\x00v");
        try testChunk(&bad, "IDAT", chunk[split..]);
        try testChunk(&bad, "IEND", &.{});
        try std.testing.expectError(error.InvalidChunkOrder, decode(a, bad.items, .{}));
    }
}
fn metadataFailureProbe(a: std.mem.Allocator, bytes: []const u8) !void {
    var result = try decode(a, bytes, .{ .limits = .{ .max_metadata_bytes = 1024 } });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 132), result.metadata.icc.?.len);
    try std.testing.expectEqual(@as(usize, 14), result.metadata.exif.?.len);
}
test "PNG owns validated ICC Exif and scalar color metadata without implicit conversion and unwinds failures" {
    const a = std.testing.allocator;
    var profile: [132]u8 = @splat(0);
    std.mem.writeInt(u32, profile[0..4], profile.len, .big);
    profile[8] = 4;
    @memcpy(profile[16..20], "RGB ");
    @memcpy(profile[20..24], "XYZ ");
    @memcpy(profile[36..40], "acsp");
    const compressed = try zlib.compress(a, &profile, 1);
    defer a.free(compressed);
    const iccp = try std.mem.concat(a, u8, &.{ "test\x00\x00", compressed });
    defer a.free(iccp);
    const exif = "II\x2a\x00\x08\x00\x00\x00\x00\x00\x00\x00\x00\x00";
    var extras: std.ArrayList(u8) = .empty;
    defer extras.deinit(a);
    try testChunk(&extras, "iCCP", iccp);
    try testChunk(&extras, "eXIf", exif);
    try testChunk(&extras, "gAMA", &.{ 0, 0, 0xb1, 0x8f });
    try testChunk(&extras, "cHRM", &(@as([32]u8, @splat(0))));
    try testChunk(&extras, "cICP", &.{ 9, 16, 0, 1 });
    const input = try testPng(&.{ 0, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc }, testHeader(16, 2), extras.items);
    defer a.free(input);
    try std.testing.checkAllAllocationFailures(a, metadataFailureProbe, .{input});
    var result = try decode(a, input, .{});
    defer result.deinit();
    @memset(input, 0);
    try std.testing.expectEqualSlices(u8, &profile, result.metadata.icc.?);
    try std.testing.expectEqualSlices(u8, exif, result.metadata.exif.?);
    try std.testing.expectEqualSlices(u8, &.{ 0x34, 0x12, 0x78, 0x56, 0xbc, 0x9a }, result.default_image.pixels);
    try std.testing.expectEqual(@as(?u32, 45455), result.metadata.gamma);
    try std.testing.expectEqual(@as(?[4]u8, .{ 9, 16, 0, 1 }), result.metadata.cicp);
    // Profile color interpretation must match the original sample color type.
    const gray = try testPng(&.{ 0, 12 }, testHeader(8, 0), extras.items);
    defer a.free(gray);
    try std.testing.expectError(error.InvalidProfile, decode(a, gray, .{}));
    const limited = try testPng(&.{ 0, 12, 34, 56 }, testHeader(8, 2), extras.items);
    defer a.free(limited);
    try std.testing.expectError(error.InflateOutputLimit, decode(a, limited, .{ .limits = .{ .max_metadata_bytes = 100 } }));
}
fn animationFailureProbe(a: std.mem.Allocator, bytes: []const u8) !void {
    var result = try decode(a, bytes, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.frames.len);
}
test "APNG rejects sequence controls counts and missing frame data with allocation and cancellation cleanup" {
    const a = std.testing.allocator;
    const animation = @import("formats/apng_encoder.zig");
    const frames = [_]animation.Frame{ .{ .view = .{ .data = &.{ 11, 22, 33 }, .width = 1, .height = 1, .stride = 3, .format = .rgb } }, .{ .view = .{ .data = &.{ 44, 55, 66 }, .width = 1, .height = 1, .stride = 3, .format = .rgb } } };
    const bytes = try animation.encode(a, .{ .width = 1, .height = 1, .frames = &frames });
    defer a.free(bytes);
    try std.testing.checkAllAllocationFailures(a, animationFailureProbe, .{bytes});
    const copy = try a.dupe(u8, bytes);
    defer a.free(copy);
    var reader = Reader{ .data = bytes };
    while (reader.pos < bytes.len) {
        const chunk = try reader.next();
        const offsets: []const usize = if (chunk.is("fcTL")) &.{ 0, 4, 8, 12, 16, 24, 25 } else if (chunk.is("fdAT")) &.{0} else if (chunk.is("acTL")) &.{0} else continue;
        for (offsets) |offset| {
            @memcpy(copy, bytes);
            copy[chunk.start + 8 + offset] = 255;
            testCrc(copy, chunk.start);
            try testReject(copy);
        }
    }
    const Cancel = struct {
        remaining: usize,
        fn call(context: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (self.remaining == 0) return false;
            self.remaining -= 1;
            return true;
        }
    };
    for (0..25) |count| {
        var counter = Cancel{ .remaining = count };
        if (decode(a, bytes, .{ .checkpoint = .{ .context = &counter, .call = Cancel.call } })) |result| {
            var owner = result;
            owner.deinit();
        } else |err| try std.testing.expectEqual(error.Cancelled, err);
    }
}

test "PNG wide-row filtering and sample expansion have bounded cancellation checkpoints" {
    const t = std.testing;
    const width = 65537;
    const input = try t.allocator.alloc(u8, width * 2);
    defer t.allocator.free(input);
    const output = try t.allocator.alloc(u8, width);
    defer t.allocator.free(output);
    const header = Header{ .width = width, .height = 1, .color = 0, .depth = 8, .interlace = false };
    const doc = Document{ .header = header };
    const Counter = struct {
        calls: usize = 0,
        limit: usize,
        fn call(ctx: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            return self.calls <= self.limit;
        }
    };
    // First filter checkpoint, first expanded sample, then within sample expansion.
    for ([_]usize{ 0, 3, 4 }) |limit| {
        @memset(input, 37);
        @memset(output, 0);
        var counter = Counter{ .limit = limit };
        var target = Raster{ .pixels = output, .width = width, .height = 1, .stride = width, .format = .gray, .bits = 8 };
        var rows = Rows{ .doc = &doc, .header = header, .target = &target, .options = .{ .checkpoint = .{ .context = &counter, .call = Counter.call } }, .current = input[0..width], .previous = input[width..], .filter = 0, .pass = try passFor(header, 0) };
        try t.expectError(error.Cancelled, rows.finishRow());
        try t.expectEqual(limit + 1, counter.calls);
    }
}

test "PNG color metadata requires an RGB matrix and Exif starts at its TIFF header" {
    const a = std.testing.allocator;
    for ([_][]const u8{ &.{ 9, 16, 1, 1 }, &.{ 9, 16, 0, 2 }, &.{ 9, 16, 0 } }) |cicp| {
        var extra: std.ArrayList(u8) = .empty;
        defer extra.deinit(a);
        try testChunk(&extra, "cICP", cicp);
        const input = try testPng(&.{ 0, 11, 22, 33 }, testHeader(8, 2), extra.items);
        defer a.free(input);
        try std.testing.expectError(error.InvalidMetadata, decode(std.testing.failing_allocator, input, .{}));
    }
    var extra: std.ArrayList(u8) = .empty;
    defer extra.deinit(a);
    try testChunk(&extra, "eXIf", "Exif\x00\x00II\x2a\x00\x08\x00\x00\x00\x00\x00\x00\x00\x00\x00");
    const input = try testPng(&.{ 0, 11, 22, 33 }, testHeader(8, 2), extra.items);
    defer a.free(input);
    try std.testing.expectError(error.InvalidMetadata, decode(std.testing.failing_allocator, input, .{}));
}
