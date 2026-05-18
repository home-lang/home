// Copied from bun/src/css/rules/namespace.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
// Imports rewritten:
//   @import("../css_parser.zig")    → @import("../css_parser_stub.zig")
//   @import("../values/values.zig") → dropped (re-exports unused inside this leaf)
// `Error = css.Error` is not referenced inside this leaf (lifted verbatim from
// upstream), so dropping the alias keeps the stub surface minimal. The `toCss`
// body still calls into stub methods that trip `@compileError` on the runtime
// path — the data shape (`prefix`/`url`/`loc`) is what wave-7 needs.

pub const css = @import("../css_parser_stub.zig");
const Printer = css.Printer;
const PrintErr = css.PrintErr;

/// A [@namespace](https://drafts.csswg.org/css-namespaces/#declaration) rule.
pub const NamespaceRule = struct {
    /// An optional namespace prefix to declare, or `None` to declare the default namespace.
    prefix: ?css.Ident,
    /// The url of the namespace.
    url: css.CSSString,
    /// The location of the rule in the source file.
    loc: css.Location,

    const This = @This();

    pub fn toCss(this: *const This, dest: *Printer) PrintErr!void {
        // #[cfg(feature = "sourcemap")]
        // dest.add_mapping(self.loc);

        try dest.writeStr("@namespace ");
        if (this.prefix) |*prefix| {
            try css.css_values.ident.IdentFns.toCss(prefix, dest);
            try dest.writeChar(' ');
        }

        try css.css_values.string.CSSStringFns.toCss(&this.url, dest);
        try dest.writeChar(';');
    }

    pub fn deepClone(this: *const @This(), allocator: std.mem.Allocator) This {
        return css.implementDeepClone(@This(), this, allocator);
    }
};

test "NamespaceRule with prefix" {
    const rule = NamespaceRule{
        .prefix = "svg",
        .url = "http://www.w3.org/2000/svg",
        .loc = css.Location.dummy(),
    };
    try std.testing.expectEqualStrings("svg", rule.prefix.?);
    try std.testing.expectEqualStrings("http://www.w3.org/2000/svg", rule.url);
}

test "NamespaceRule without prefix" {
    const rule = NamespaceRule{
        .prefix = null,
        .url = "http://example.org/ns",
        .loc = .{ .source_index = 0, .line = 1, .column = 1 },
    };
    try std.testing.expect(rule.prefix == null);
}

test "NamespaceRule.deepClone preserves url + loc" {
    const rule = NamespaceRule{
        .prefix = "xhtml",
        .url = "http://www.w3.org/1999/xhtml",
        .loc = .{ .source_index = 7, .line = 8, .column = 9 },
    };
    const cloned = rule.deepClone(std.testing.allocator);
    try std.testing.expectEqualStrings(rule.url, cloned.url);
    try std.testing.expectEqual(rule.loc.column, cloned.loc.column);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
