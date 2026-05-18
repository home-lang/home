// Copied from bun/src/css/values/values.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
// Imports rewritten: @import("../css_parser.zig") dropped. Upstream re-imports
// many sibling value modules (angle, ident, color, image, number, calc,
// percentage, length, position, syntax, alpha, ratio, size, rect, time,
// easing, url, resolution, gradient) — none of those are ported yet, so the
// re-exports are stripped here. Only the pure-data `css_modules.Specifier`
// union travels with this leaf; the rest re-lands as each sibling is ported.

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
