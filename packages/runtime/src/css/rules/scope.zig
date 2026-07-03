// Copied from bun/src/css/rules/scope.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
// Imports rewritten: @import("../css_parser.zig") → @import("../css_parser_stub.zig").
// `css.selector.parser.SelectorList` is a small struct stub (`{v}`). The
// `toCss` body reaches for `dest.writeStr`, `dest.whitespace`,
// `css.selector.serialize.serializeSelectorList`, `dest.withContext`,
// `dest.withClearedContext` — all stub-deferred. Only the pure-data shape
// (`scope_start`, `scope_end`, `rules`, `loc`) lands. `deepClone` uses
// `implementDeepClone` (shallow under stub).

pub const css = @import("../css_parser.zig");
const Printer = css.Printer;
const PrintErr = css.PrintErr;
const Location = css.css_rules.Location;
const CssRuleList = css.CssRuleList;

/// A [@scope](https://drafts.csswg.org/css-cascade-6/#scope-atrule) rule.
///
/// @scope (<scope-start>) [to (<scope-end>)]? {
///  <stylesheet>
/// }
pub fn ScopeRule(comptime R: type) type {
    return struct {
        /// A selector list used to identify the scoping root(s).
        scope_start: ?css.selector.parser.SelectorList,
        /// A selector list used to identify any scoping limits.
        scope_end: ?css.selector.parser.SelectorList,
        /// Nested rules within the `@scope` rule.
        rules: css.CssRuleList(R),
        /// The location of the rule in the source file.
        loc: Location,

        const This = @This();

        pub fn toCss(this: *const This, dest: *Printer) PrintErr!void {
            try dest.writeStr("@scope");
            try dest.whitespace();
            if (this.scope_start) |*scope_start| {
                try dest.writeChar('(');
                try css.selector.serialize.serializeSelectorList(scope_start.v.slice(), dest, dest.context(), false);
                try dest.writeChar(')');
                try dest.whitespace();
            }
            if (this.scope_end) |*scope_end| {
                if (dest.minify) {
                    try dest.writeChar(' ');
                }
                try dest.writeStr("to (");
                // <scope-start> is treated as an ancestor of scope end.
                if (this.scope_start) |*scope_start| {
                    try dest.withContext(scope_start, scope_end, struct {
                        pub fn toCssFn(scope_end_: *const css.selector.parser.SelectorList, d: *Printer) PrintErr!void {
                            return css.selector.serialize.serializeSelectorList(scope_end_.v.slice(), d, d.context(), false);
                        }
                    }.toCssFn);
                } else {
                    return css.selector.serialize.serializeSelectorList(scope_end.v.slice(), dest, dest.context(), false);
                }
                try dest.writeChar(')');
                try dest.whitespace();
            }
            try dest.writeChar('{');
            dest.indent();
            try dest.newline();
            // Nested style rules within @scope are implicitly relative to the
            // <scope-start>, so clear the style context while printing them.
            try dest.withClearedContext(&this.rules, CssRuleList(R).toCss);
            dest.dedent();
            try dest.newline();
            try dest.writeChar('}');
        }

        pub fn deepClone(this: *const @This(), allocator: std.mem.Allocator) This {
            return css.implementDeepClone(@This(), this, allocator);
        }
    };
}

test "ScopeRule(void) data shape" {
    const T = ScopeRule(void);
    const r = T{
        .scope_start = null,
        .scope_end = null,
        .rules = .{},
        .loc = css.Location.dummy(),
    };
    try std.testing.expect(r.scope_start == null);
    try std.testing.expect(r.scope_end == null);
}

test "ScopeRule(u8).deepClone preserves loc" {
    const T = ScopeRule(u8);
    const r = T{
        .scope_start = null,
        .scope_end = null,
        .rules = .{},
        .loc = .{ .source_index = 1, .line = 2, .column = 3 },
    };
    const cloned = r.deepClone(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 2), cloned.loc.line);
}

const std = @import("std");
