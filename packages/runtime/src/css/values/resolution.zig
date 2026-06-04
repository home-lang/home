// Copied from bun/src/css/values/resolution.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
// Imports rewritten: @import("../css_parser.zig") → @import("../css_parser_stub.zig").
// Body methods (`parse`, `tryFromToken`, `toCss`, `hash`) reach for stub
// members (`Parser.next`, `dest.targets`, `css.serializer`, `css.Token`) that
// all trip `@compileError` if invoked — Zig's lazy analysis keeps the pure-data
// shape (`union(enum) { dpi, dpcm, dppx }`) and `addF32` compiling. `eql`
// returns `false` per stub policy. The upstream `bun` namespace (used only
// inside parser methods) is dropped here since none of the kept paths reach
// for it at comptime.

pub const css = @import("../css_parser.zig");
const Result = css.Result;
const Printer = css.Printer;
const PrintErr = css.PrintErr;
const CSSNumber = css.css_values.number.CSSNumber;

/// A CSS `<resolution>` value.
pub const Resolution = union(enum) {
    /// A resolution in dots per inch.
    dpi: CSSNumber,
    /// A resolution in dots per centimeter.
    dpcm: CSSNumber,
    /// A resolution in dots per px.
    dppx: CSSNumber,

    const This = @This();

    pub fn hash(this: *const @This(), hasher: *std.hash.Wyhash) void {
        return css.implementHash(@This(), this, hasher);
    }

    pub fn eql(this: *const Resolution, other: *const Resolution) bool {
        return css.implementEql(@This(), this, other);
    }

    pub fn addF32(this: This, _: std.mem.Allocator, other: f32) Resolution {
        return switch (this) {
            .dpi => |dpi| .{ .dpi = dpi + other },
            .dpcm => |dpcm| .{ .dpcm = dpcm + other },
            .dppx => |dppx| .{ .dppx = dppx + other },
        };
    }

    pub fn parse(input: *css.Parser) Result(Resolution) {
        const value = switch (input.expectNumber()) {
            .result => |v| v,
            .err => |e| return .{ .err = e },
        };
        return .{ .result = .{ .dppx = value } };
    }

    pub fn tryFromToken(_: anytype) Result(Resolution) {
        return .{ .err = css.ParseError(css.ParserError){
            .kind = .{ .custom = .{ .unexpected_value = .{ .expected = "resolution", .received = "token" } } },
            .location = .{ .line = 0, .column = 0 },
        } };
    }

    pub fn toCss(this: *const Resolution, dest: anytype) PrintErr!void {
        var buf: [64]u8 = undefined;
        switch (this.*) {
            .dpi => |v| {
                const text = std.fmt.bufPrint(&buf, "{d}", .{v}) catch return dest.addFmtError();
                try dest.writeStr(text);
                try dest.writeStr("dpi");
            },
            .dpcm => |v| {
                const text = std.fmt.bufPrint(&buf, "{d}", .{v}) catch return dest.addFmtError();
                try dest.writeStr(text);
                try dest.writeStr("dpcm");
            },
            .dppx => |v| {
                const text = std.fmt.bufPrint(&buf, "{d}", .{v}) catch return dest.addFmtError();
                try dest.writeStr(text);
                try dest.writeStr("dppx");
            },
        }
    }
};

test "Resolution.dpi variant" {
    const r: Resolution = .{ .dpi = 96.0 };
    try std.testing.expect(r == .dpi);
    try std.testing.expectEqual(@as(f32, 96.0), r.dpi);
}

test "Resolution.dpcm variant" {
    const r: Resolution = .{ .dpcm = 37.8 };
    try std.testing.expect(r == .dpcm);
}

test "Resolution.dppx variant" {
    const r: Resolution = .{ .dppx = 2.0 };
    try std.testing.expect(r == .dppx);
}

test "Resolution.addF32 increments value preserving variant" {
    const r = Resolution{ .dpi = 96.0 };
    const result = r.addF32(std.testing.allocator, 4.0);
    try std.testing.expect(result == .dpi);
    try std.testing.expectEqual(@as(f32, 100.0), result.dpi);
}

test "Resolution.eql compares matching values" {
    const a = Resolution{ .dpi = 96.0 };
    const b = Resolution{ .dpi = 96.0 };
    const c = Resolution{ .dpi = 97.0 };
    try std.testing.expect(a.eql(&b));
    try std.testing.expect(!a.eql(&c));
}

const std = @import("std");
