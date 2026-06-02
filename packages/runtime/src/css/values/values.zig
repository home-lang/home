// Copied from bun/src/css/values/values.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
// Imports rewritten: @import("../css_parser.zig") dropped. Upstream re-imports
// many sibling value modules (angle, ident, color, image, number, calc,
// percentage, length, position, syntax, alpha, ratio, size, rect, time,
// easing, url, resolution, gradient). Those leaves now exist in Home's copied
// tree, so keep the aggregator shape faithful to upstream.

pub const css_modules = struct {
    /// Defines where the class names referenced in the `composes` property are located.
    ///
    /// See [Composes](Composes).
    pub const Specifier = union(enum) {
        /// The referenced name is global.
        global,
        /// The referenced name comes from the specified file.
        file: []const u8,
        /// The referenced name comes from a source index (used during bundling).
        source_index: u32,
    };
};

pub const angle = @import("./angle.zig");
pub const ident = @import("./ident.zig");
pub const string = @import("./css_string.zig");
pub const color = @import("./color.zig");
pub const image = @import("./image.zig");
pub const number = @import("./number.zig");
pub const calc = @import("./calc.zig");
pub const percentage = @import("./percentage.zig");
pub const length = @import("./length.zig");
pub const position = @import("./position.zig");
pub const syntax = @import("./syntax.zig");
pub const alpha = @import("./alpha.zig");
pub const ratio = @import("./ratio.zig");
pub const size = @import("./size.zig");
pub const rect = @import("./rect.zig");
pub const time = @import("./time.zig");
pub const easing = @import("./easing.zig");
pub const url = @import("./url.zig");
pub const resolution = @import("./resolution.zig");
pub const gradient = @import("./gradient.zig");

test "Specifier.global is a tag-only variant" {
    const s: css_modules.Specifier = .global;
    try std.testing.expect(s == .global);
}

test "Specifier.file holds a path slice" {
    const s: css_modules.Specifier = .{ .file = "foo.css" };
    try std.testing.expect(s == .file);
    try std.testing.expectEqualStrings("foo.css", s.file);
}

test "Specifier.source_index holds a u32" {
    const s: css_modules.Specifier = .{ .source_index = 42 };
    try std.testing.expect(s == .source_index);
    try std.testing.expectEqual(@as(u32, 42), s.source_index);
}

const std = @import("std");
