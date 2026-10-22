//! Bounded SPS conformance-window edits for the native single-layer 8-bit I420 encoder.
//! NAL bytes exclude start codes/lengths. The opaque SPS suffix (including VUI) is
//! preserved bit-for-bit through rbsp_stop_one_bit. This is not a general HEVC validator.
//! No allocation; source and destination may overlap. Failed edits leave destination intact.
const std = @import("std");
const Reader = @import("bit_reader.zig").Reader;
pub const maximum_nal = 2048;
pub const maximum_output = 4096;
pub const Size = struct { width: u32, height: u32 };
const Window = struct { left: u32 = 0, right: u32 = 0, top: u32 = 0, bottom: u32 = 0 };
const Prefix = struct { size: Size, window: Window, start: usize, end: usize };
const Writer = struct {
    data: []u8,
    bits: usize = 0,
    fn bit(self: *Writer, value: u1) !void {
        if (self.bits / 8 >= self.data.len) return error.OutputTooSmall;
        if (self.bits % 8 == 0) self.data[self.bits / 8] = 0;
        self.data[self.bits / 8] |= @as(u8, value) << @intCast(7 - self.bits % 8);
        self.bits += 1;
    }
    fn ue(self: *Writer, value: u32) !void {
        const v = @as(u64, value) + 1;
        const n: u6 = @intCast(63 - @clz(v));
        for (0..n) |_| try self.bit(0);
        var count: usize = @as(usize, n) + 1;
        while (count > 0) {
            count -= 1;
            try self.bit(@truncate(v >> @intCast(count)));
        }
    }
    fn copy(self: *Writer, data: []const u8, start: usize, end: usize) !void {
        for (start..end) |at| try self.bit(@truncate(data[at / 8] >> @intCast(7 - at % 8)));
    }
};
fn unescape(nal: []const u8, dest: []u8) ![]u8 {
    if (nal.len < 3 or nal.len > maximum_nal or nal[0] != 66 or nal[1] != 1) return error.UnsupportedSps;
    var n: usize = 0;
    var zeros: usize = 0;
    var at: usize = 2;
    while (at < nal.len) : (at += 1) {
        const byte = nal[at];
        if (zeros == 2) {
            if (byte <= 2) return error.InvalidEmulationPrevention;
            if (byte == 3) {
                if (at + 1 == nal.len or nal[at + 1] > 3) return error.InvalidEmulationPrevention;
                zeros = 0;
                continue;
            }
        }
        if (n == dest.len) return error.OutputTooSmall;
        dest[n] = byte;
        n += 1;
        zeros = if (byte == 0) zeros + 1 else 0;
    }
    if (n == 0 or dest[n - 1] == 0) return error.InvalidTrailingBits;
    return dest[0..n];
}
fn escape(rbsp: []const u8, dest: []u8) ![]u8 {
    if (dest.len < 2) return error.OutputTooSmall;
    dest[0] = 66;
    dest[1] = 1;
    var n: usize = 2;
    var zeros: usize = 0;
    for (rbsp) |byte| {
        if (zeros == 2 and byte <= 3) {
            if (n == dest.len) return error.OutputTooSmall;
            dest[n] = 3;
            n += 1;
            zeros = 0;
        }
        if (n == dest.len) return error.OutputTooSmall;
        dest[n] = byte;
        n += 1;
        zeros = if (byte == 0) zeros + 1 else 0;
    }
    return dest[0..n];
}
fn prefix(rbsp: []const u8) !Prefix {
    var r = Reader.init(rbsp);
    const first = try r.readBits(8);
    // SPS max_sub_layers_minus1 == 0 and temporal nesting == 1; PTL is 96 bits.
    if (first & 15 != 1) return error.UnsupportedSps;
    try r.skipBits(96);
    if (try r.readUE() > 15 or try r.readUE() != 1) return error.UnsupportedSps;
    const width = try r.readUE();
    const height = try r.readUE();
    if (width == 0 or height == 0 or width > 8192 or height > 8192 or (width | height) & 1 != 0) return error.InvalidGeometry;
    const start: usize = @intCast(r.getBitPosition());
    var window: Window = .{};
    if (try r.readBit() != 0) window = .{ .left = try r.readUE(), .right = try r.readUE(), .top = try r.readUE(), .bottom = try r.readUE() };
    const end: usize = @intCast(r.getBitPosition());
    if (try r.readUE() != 0 or try r.readUE() != 0) return error.UnsupportedSps;
    return .{ .size = .{ .width = width, .height = height }, .window = window, .start = start, .end = end };
}
fn visible(p: Prefix) !Size {
    const x = (@as(u64, p.window.left) + p.window.right) * 2;
    const y = (@as(u64, p.window.top) + p.window.bottom) * 2;
    if (x >= p.size.width or y >= p.size.height) return error.InvalidGeometry;
    return .{ .width = p.size.width - @as(u32, @intCast(x)), .height = p.size.height - @as(u32, @intCast(y)) };
}
/// Add right/bottom crop to a vendor SPS whose current visible size is expected.
/// Existing vendor padding/crops are retained; requested is even I420, at least 16x16.
pub fn rewrite(nal: []const u8, expected: Size, requested: Size, dest: []u8) ![]u8 {
    if (requested.width < 16 or requested.height < 16 or (requested.width | requested.height) & 1 != 0 or
        requested.width > expected.width or requested.height > expected.height) return error.InvalidGeometry;
    var raw: [maximum_nal]u8 = undefined;
    const rbsp = try unescape(nal, &raw);
    const p = try prefix(rbsp);
    const old = try visible(p);
    if (old.width != expected.width or old.height != expected.height) return error.InvalidGeometry;
    const stop = rbsp.len * 8 - @as(usize, @ctz(rbsp[rbsp.len - 1]));
    // At least the two bit-depth codes and a distinct stop bit must remain.
    if (stop <= p.end + 2) return error.InvalidTrailingBits;
    var edited: [maximum_nal + 32]u8 = undefined;
    var w: Writer = .{ .data = &edited };
    try w.copy(rbsp, 0, p.start);
    try w.bit(1);
    try w.ue(p.window.left);
    try w.ue(p.window.right + (expected.width - requested.width) / 2);
    try w.ue(p.window.top);
    try w.ue(p.window.bottom + (expected.height - requested.height) / 2);
    try w.copy(rbsp, p.end, stop);
    var output: [maximum_output]u8 = undefined;
    const result = try escape(edited[0 .. (w.bits + 7) / 8], &output);
    if (result.len > dest.len) return error.OutputTooSmall;
    @memcpy(dest[0..result.len], result);
    return dest[0..result.len];
}

// A prefix fixture with an opaque marker tail, not a decodable complete SPS.
fn fixture(size: Size, window: ?Window, dest: []u8) ![]u8 {
    var raw: [256]u8 = undefined;
    var w: Writer = .{ .data = &raw };
    try w.copy(&.{1}, 0, 8);
    for (0..96) |_| try w.bit(0);
    try w.ue(0);
    try w.ue(1);
    try w.ue(size.width);
    try w.ue(size.height);
    try w.bit(@intFromBool(window != null));
    if (window) |win| {
        try w.ue(win.left);
        try w.ue(win.right);
        try w.ue(win.top);
        try w.ue(win.bottom);
    }
    try w.ue(0);
    try w.ue(0);
    try w.copy(&.{ 0x5a, 0x80 }, 0, 9);
    return escape(raw[0 .. (w.bits + 7) / 8], dest);
}
test "crop preserves existing vendor offsets, opaque suffix and emulation prevention" {
    const t = std.testing;
    var input: [maximum_output]u8 = undefined;
    var output: [maximum_output]u8 = undefined;
    var raw: [maximum_nal]u8 = undefined;
    for ([_]Size{ .{ .width = 16, .height = 16 }, .{ .width = 18, .height = 22 }, .{ .width = 32, .height = 24 }, .{ .width = 32, .height = 32 } }) |requested| {
        const source = try fixture(.{ .width = 40, .height = 36 }, .{ .left = 1, .right = 3, .top = 1, .bottom = 1 }, &input);
        const result = try rewrite(source, .{ .width = 32, .height = 32 }, requested, &output);
        const rbsp = try unescape(result, &raw);
        const p = try prefix(rbsp);
        const size = try visible(p);
        try t.expectEqual(requested, size);
        try t.expectEqual(@as(u32, 1), p.window.left);
        try t.expectEqual(@as(u32, 1), p.window.top);
        var suffix = Reader.init(rbsp);
        try suffix.skipBits(@intCast(p.end));
        try t.expectEqual(@as(u32, 0), try suffix.readUE());
        try t.expectEqual(@as(u32, 0), try suffix.readUE());
        try t.expectEqual(@as(u32, 0x5a), try suffix.readBits(8));
        try t.expectEqual(@as(u1, 1), try suffix.readBit());
    }
}
test "crop inserts absent window, supports overlap and rejects capacity without mutation" {
    const t = std.testing;
    var input: [maximum_output]u8 = undefined;
    const source = try fixture(.{ .width = 32, .height = 32 }, null, &input);
    var short: [2]u8 = .{ 0xa5, 0xa5 };
    try t.expectError(error.OutputTooSmall, rewrite(source, .{ .width = 32, .height = 32 }, .{ .width = 16, .height = 16 }, &short));
    try t.expectEqualSlices(u8, &.{ 0xa5, 0xa5 }, &short);
    const result = try rewrite(source, .{ .width = 32, .height = 32 }, .{ .width = 16, .height = 16 }, &input);
    var raw: [maximum_nal]u8 = undefined;
    try t.expectEqual(Size{ .width = 16, .height = 16 }, try visible(try prefix(try unescape(result, &raw))));
}
test "crop rejects mismatched geometry, invalid prefixes and truncated or escaped input" {
    const t = std.testing;
    var input: [maximum_output]u8 = undefined;
    var output: [maximum_output]u8 = @splat(0xa5);
    const source = try fixture(.{ .width = 32, .height = 32 }, null, &input);
    const expected: Size = .{ .width = 32, .height = 32 };
    for ([_]Size{ .{ .width = 15, .height = 16 }, .{ .width = 17, .height = 16 }, .{ .width = 34, .height = 32 }, .{ .width = 16, .height = 8192 } }) |bad| try t.expectError(error.InvalidGeometry, rewrite(source, expected, bad, &output));
    try t.expectError(error.InvalidGeometry, rewrite(source, .{ .width = 34, .height = 32 }, expected, &output));
    // Every truncation inside the fixed PTL prefix must reject. The opaque
    // suffix is intentionally not fully parsed, so its truncation is not claimed.
    for (0..20) |len| {
        if (rewrite(source[0..len], expected, expected, &output)) |_| return error.AcceptedTruncation else |_| {}
    }
    for ([_][]const u8{ &.{ 66, 1, 0, 0, 3 }, &.{ 66, 1, 0, 0, 3, 4 }, &.{ 66, 1, 0, 0, 1 }, &.{ 66, 1, 0 } }) |bad| {
        if (rewrite(bad, expected, expected, &output)) |_| return error.AcceptedInvalidInput else |_| {}
    }
    source[0] = 68;
    try t.expectError(error.UnsupportedSps, rewrite(source, expected, expected, &output));
    for (output) |byte| try t.expectEqual(@as(u8, 0xa5), byte);
}
test "bounded SPS mutation coverage never panics or writes on errors" {
    const t = std.testing;
    var input: [maximum_output]u8 = undefined;
    const source = try fixture(.{ .width = 32, .height = 32 }, null, &input);
    for (0..source.len) |at| for (0..256) |v| {
        var mutated: [maximum_output]u8 = undefined;
        @memcpy(mutated[0..source.len], source);
        mutated[at] = @intCast(v);
        var output: [maximum_output]u8 = @splat(0xa5);
        if (rewrite(mutated[0..source.len], .{ .width = 32, .height = 32 }, .{ .width = 16, .height = 16 }, &output)) |result| {
            var raw: [maximum_nal]u8 = undefined;
            try t.expectEqual(Size{ .width = 16, .height = 16 }, try visible(try prefix(try unescape(result, &raw))));
        } else |_| for (output) |byte| try t.expectEqual(@as(u8, 0xa5), byte);
    };
}
