// Copied from bun/src/css/values/rect.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
// Imports rewritten: @import("../css_parser.zig") → @import("../css_parser_stub.zig").
// Wave-9 (2026-05-18). Pure generic — `Rect(T)` is a four-side box generic
// (top/right/bottom/left) used by `border`/`margin`/`padding`. The file is
// lazy in `T`: `Rect(T)` is only analyzed when instantiated, and our wave-9
// landings don't instantiate it yet. The `needsDeinit(T)` switch references
// `BorderImageSideWidth`/`BorderSideWidth` from un-ported sibling leaves —
// since `needsDeinit` is only invoked from inside `Rect(T)`, those names
// remain unanalyzed under lazy semantics. When border / border_image port,
// those switch prongs become live.

pub const css = @import("../css_parser_stub.zig");
const Result = css.Result;
const Printer = css.Printer;
const PrintErr = css.PrintErr;
const DimensionPercentage = css.css_values.percentage.DimensionPercentage;
const LengthPercentage = css.css_values.length.LengthPercentage;
const LengthOrNumber = css.css_values.length.LengthOrNumber;
const CssColor = css.css_values.color.CssColor;

fn needsDeinit(comptime T: type) bool {
    return switch (T) {
        f32, i32, u32, []const u8 => false,
        LengthPercentage => true,
        LengthOrNumber => true,
        css.css_values.percentage.NumberOrPercentage => false,
        css.css_properties.border_image.BorderImageSideWidth => true,
        *const css.css_values.percentage.DimensionPercentage(css.css_values.length.LengthValue) => true,
        CssColor => true,
        css.css_properties.border.LineStyle => false,
        css.css_properties.border.BorderSideWidth => true,
        css.css_values.length.LengthPercentageOrAuto => true,
        else => @compileError("Don't know if " ++ @typeName(T) ++ " needs deinit. Please add it to this switch statement."),
    };
}

/// A generic value that represents a value for four sides of a box,
/// e.g. border-width, margin, padding, etc.
///
/// When serialized, as few components as possible are written when
/// there are duplicate values.
pub fn Rect(comptime T: type) type {
    const needs_deinit = needsDeinit(T);
    return struct {
        /// The top component.
        top: T,
        /// The right component.
        right: T,
        /// The bottom component.
        bottom: T,
        /// The left component.
        left: T,

        const This = @This();

        pub fn eql(this: *const This, other: *const This) bool {
            return css.generic.eql(T, &this.top, &other.top) and css.generic.eql(T, &this.right, &other.right) and css.generic.eql(T, &this.bottom, &other.bottom) and css.generic.eql(T, &this.left, &other.left);
        }

        pub fn deepClone(this: *const This, allocator: std.mem.Allocator) This {
            if (comptime needs_deinit or T == *const css.css_values.percentage.DimensionPercentage(css.css_values.length.LengthValue)) {
                return This{
                    .top = this.top.deepClone(allocator),
                    .right = this.right.deepClone(allocator),
                    .bottom = this.bottom.deepClone(allocator),
                    .left = this.left.deepClone(allocator),
                };
            }
            return This{
                .top = this.top,
                .right = this.right,
                .bottom = this.bottom,
                .left = this.left,
            };
        }

        pub fn all(val: T) This {
            return This{
                .top = val,
                .right = val,
                .bottom = val,
                .left = val,
            };
        }

        pub fn deinit(this: *const This, allocator: std.mem.Allocator) void {
            if (comptime needs_deinit) {
                this.top.deinit(allocator);
                this.right.deinit(allocator);
                this.bottom.deinit(allocator);
                this.left.deinit(allocator);
            }
        }

        pub fn parse(input: *css.Parser) Result(This) {
            return This.parseWith(input, valParse);
        }

        pub fn parseWith(input: *css.Parser, comptime parse_fn: anytype) Result(This) {
            const first = switch (parse_fn(input)) {
                .result => |vv| vv,
                .err => |e| return .{ .err = e },
            };
            const second = switch (input.tryParse(parse_fn, .{})) {
                .result => |v| v,
                // <first>
                .err => return .{ .result = This{ .top = first, .right = first, .bottom = first, .left = first } },
            };
            const third = switch (input.tryParse(parse_fn, .{})) {
                .result => |v| v,
                // <first> <second>
                .err => return .{ .result = This{ .top = first, .right = second, .bottom = first, .left = second } },
            };
            const fourth = switch (input.tryParse(parse_fn, .{})) {
                .result => |v| v,
                // <first> <second> <third>
                .err => return .{ .result = This{ .top = first, .right = second, .bottom = third, .left = second } },
            };
            // <first> <second> <third> <fourth>
            return .{ .result = This{ .top = first, .right = second, .bottom = third, .left = fourth } };
        }

        pub fn toCss(this: *const This, dest: *Printer) PrintErr!void {
            try css.generic.toCss(T, &this.top, dest);
            const same_vertical = css.generic.eql(T, &this.top, &this.bottom);
            const same_horizontal = css.generic.eql(T, &this.right, &this.left);
            if (same_vertical and same_horizontal and css.generic.eql(T, &this.top, &this.right)) {
                return;
            }
            try dest.writeStr(" ");
            try css.generic.toCss(T, &this.right, dest);
            if (same_vertical and same_horizontal) {
                return;
            }
            try dest.writeStr(" ");
            try css.generic.toCss(T, &this.bottom, dest);
            if (same_horizontal) {
                return;
            }
            try dest.writeStr(" ");
            try css.generic.toCss(T, &this.left, dest);
        }

        pub fn valParse(i: *css.Parser) Result(T) {
            return css.generic.parse(T, i);
        }

        pub fn isCompatible(this: *const @This(), browsers: css.targets.Browsers) bool {
            return this.top.isCompatible(browsers) and this.right.isCompatible(browsers) and this.bottom.isCompatible(browsers) and this.left.isCompatible(browsers);
        }
    };
}

test "Rect generic type-decl is reachable" {
    // We don't instantiate `Rect(T)` here — the `needsDeinit` switch references
    // un-ported sibling types in some prongs. Type-decl resolution is enough
    // to confirm the leaf compiles under the wave-9 stub surface.
    const RectFn = @TypeOf(Rect);
    try std.testing.expect(@typeInfo(RectFn) == .@"fn");
}

const std = @import("std");
