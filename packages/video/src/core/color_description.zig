//! Portable color descriptions and processed-stream negotiation policy.
//! Numeric IDs are descriptive codes, not codec/ISO color tags. No pixels,
//! gamma or primaries are transformed; callers supply actual backend metadata.
const std = @import("std");
pub const Primaries = enum(u32) { raw = 1, smpte170m = 2, rec709 = 3, rec2020 = 4 };
pub const Transfer = enum(u32) { linear = 1, srgb = 2, rec709 = 3 };
pub const Matrix = enum(u32) { none = 1, rec601 = 2, rec709 = 3, rec2020 = 4 };
pub const Range = enum(u32) { full = 1, limited = 2 };
pub const Preset = enum(u32) { srgb = 1, sycc = 2, smpte170m = 3, rec709 = 4, rec2020 = 5, raw = 6 };
pub const Description = struct {
    primaries: Primaries,
    transfer: Transfer,
    matrix: Matrix,
    range: Range,
    pub fn fromCodes(primaries: u32, transfer: u32, matrix: u32, range: u32) !Description {
        return .{
            .primaries = std.enums.fromInt(Primaries, primaries) orelse return error.InvalidColorSpace,
            .transfer = std.enums.fromInt(Transfer, transfer) orelse return error.InvalidColorSpace,
            .matrix = std.enums.fromInt(Matrix, matrix) orelse return error.InvalidColorSpace,
            .range = std.enums.fromInt(Range, range) orelse return error.InvalidColorSpace,
        };
    }
    pub fn eql(a: Description, b: Description) bool {
        return a.primaries == b.primaries and a.transfer == b.transfer and a.matrix == b.matrix and a.range == b.range;
    }
    /// Raw primaries cannot describe processed RGB/YUV. RGB preserves gamut and
    /// transfer, normalizing matrix/range. YUV must have an explicit matrix.
    pub fn processed(self: Description, yuv: bool) !Description {
        if (self.primaries == .raw) return error.InvalidColorSpace;
        if (yuv) {
            if (self.matrix == .none) return error.InvalidColorSpace;
            return self;
        }
        var result = self;
        result.matrix = .none;
        result.range = .full;
        return result;
    }
};
pub fn preset(value: Preset) Description {
    return switch (value) {
        .srgb => .{ .primaries = .rec709, .transfer = .srgb, .matrix = .none, .range = .full },
        .sycc => .{ .primaries = .rec709, .transfer = .srgb, .matrix = .rec601, .range = .full },
        .smpte170m => .{ .primaries = .smpte170m, .transfer = .rec709, .matrix = .rec601, .range = .limited },
        .rec709 => .{ .primaries = .rec709, .transfer = .rec709, .matrix = .rec709, .range = .limited },
        .rec2020 => .{ .primaries = .rec2020, .transfer = .rec709, .matrix = .rec2020, .range = .limited },
        .raw => .{ .primaries = .raw, .transfer = .linear, .matrix = .none, .range = .full },
    };
}
pub const Negotiation = struct {
    requested: Description,
    effective: Description,
    actual: ?Description,
    normalized: bool,
    adjusted: bool,
};
/// Unknown/absent actual metadata is an adjustment, never a guessed match.
/// A strict request rejects adjustments after format normalization.
pub fn negotiate(requested: Description, actual: ?Description, yuv: bool, strict: bool) !Negotiation {
    const effective = try requested.processed(yuv);
    const adjusted = if (actual) |value| !effective.eql(value) else true;
    if (strict and adjusted) return error.ColorSpaceAdjusted;
    return .{ .requested = requested, .effective = effective, .actual = actual, .normalized = !requested.eql(effective), .adjusted = adjusted };
}
test "presets preserve each distinct gamut transfer matrix and range" {
    const t = std.testing;
    const sycc = preset(.sycc);
    try t.expectEqual(Primaries.rec709, sycc.primaries);
    try t.expectEqual(Transfer.srgb, sycc.transfer);
    try t.expectEqual(Matrix.rec601, sycc.matrix);
    try t.expectEqual(Range.full, sycc.range);
    try t.expectEqual(Primaries.smpte170m, preset(.smpte170m).primaries);
    try t.expectEqual(Matrix.rec601, preset(.smpte170m).matrix);
    try t.expectEqual(Transfer.rec709, preset(.rec709).transfer);
    try t.expectEqual(Matrix.rec709, preset(.rec709).matrix);
    try t.expectEqual(Primaries.rec2020, preset(.rec2020).primaries);
    try t.expectEqual(Matrix.rec2020, preset(.rec2020).matrix);
    try t.expectEqual(Range.limited, preset(.rec2020).range);
    try t.expectEqual(Transfer.linear, preset(.raw).transfer);
}
test "RGB normalization preserves primaries transfer and caller request; YUV requires a matrix" {
    const t = std.testing;
    for ([_]Preset{ .srgb, .sycc, .smpte170m, .rec709, .rec2020 }) |value| {
        const requested = preset(value);
        const before = requested;
        const effective = try requested.processed(false);
        try t.expectEqual(requested.primaries, effective.primaries);
        try t.expectEqual(requested.transfer, effective.transfer);
        try t.expectEqual(Matrix.none, effective.matrix);
        try t.expectEqual(Range.full, effective.range);
        try t.expect(before.eql(requested));
        if (value == .srgb) try t.expectError(error.InvalidColorSpace, requested.processed(true)) else try t.expect(requested.eql(try requested.processed(true)));
    }
    try t.expectError(error.InvalidColorSpace, preset(.raw).processed(false));
    try t.expectError(error.InvalidColorSpace, preset(.raw).processed(true));
}
test "negotiation distinguishes normalized requests from adjusted or unknown results" {
    const t = std.testing;
    const requested = preset(.rec709);
    const rgb = try requested.processed(false);
    const accepted = try negotiate(requested, rgb, false, true);
    try t.expect(accepted.normalized and !accepted.adjusted);
    try t.expect(accepted.requested.eql(requested));
    const changed = try negotiate(requested, preset(.sycc), true, false);
    try t.expect(!changed.normalized and changed.adjusted);
    try t.expectError(error.ColorSpaceAdjusted, negotiate(requested, preset(.sycc), true, true));
    const absent = try negotiate(requested, null, true, false);
    try t.expect(absent.adjusted and absent.actual == null);
    try t.expectError(error.ColorSpaceAdjusted, negotiate(requested, null, true, true));
    var actual = requested;
    inline for (.{ "primaries", "transfer", "matrix", "range" }) |field| {
        actual = requested;
        @field(actual, field) = @field(preset(.sycc), field);
        if (comptime std.mem.eql(u8, field, "primaries")) actual.primaries = .rec2020;
        if (!actual.eql(requested)) {
            try t.expect((try negotiate(requested, actual, true, false)).adjusted);
            try t.expectError(error.ColorSpaceAdjusted, negotiate(requested, actual, true, true));
        }
    }
}
test "portable code parsing rejects unknown values before a description escapes" {
    const t = std.testing;
    for ([_]u32{ 0, 5, std.math.maxInt(u32) }) |value| try t.expectError(error.InvalidColorSpace, Description.fromCodes(value, 2, 2, 1));
    try t.expectError(error.InvalidColorSpace, Description.fromCodes(3, 4, 2, 1));
    try t.expectError(error.InvalidColorSpace, Description.fromCodes(3, 2, 5, 1));
    try t.expectError(error.InvalidColorSpace, Description.fromCodes(3, 2, 2, 3));
    for (std.enums.values(Preset)) |value| {
        const color = preset(value);
        try t.expect(color.eql(try Description.fromCodes(@intFromEnum(color.primaries), @intFromEnum(color.transfer), @intFromEnum(color.matrix), @intFromEnum(color.range))));
    }
}
