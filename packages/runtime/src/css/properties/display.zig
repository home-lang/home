// Copied from bun/src/css/properties/display.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
// Minimal real parser/printer surface for the generated properties table.

pub const css = @import("../css_parser.zig");

const Printer = css.Printer;
const PrintErr = css.PrintErr;

/// A value for the [display](https://drafts.csswg.org/css-display-3/#the-display-properties) property.
pub const Display = union(enum) {
    /// A display keyword.
    keyword: DisplayKeyword,
    /// The inside and outside display values.
    pair: DisplayPair,

    pub fn parse(input: *css.Parser) css.Result(Display) {
        if (input.tryParse(DisplayKeyword.parse, .{}).asValue()) |keyword| {
            return .{ .result = .{ .keyword = keyword } };
        }
        return switch (DisplayPair.parse(input)) {
            .result => |pair| .{ .result = .{ .pair = pair } },
            .err => |e| .{ .err = e },
        };
    }

    pub fn toCss(this: *const @This(), dest: *Printer) PrintErr!void {
        return switch (this.*) {
            .keyword => |*keyword| keyword.toCss(dest),
            .pair => |*pair| pair.toCss(dest),
        };
    }

    pub fn deepClone(this: *const @This(), allocator: std.mem.Allocator) @This() {
        return css.implementDeepClone(@This(), this, allocator);
    }

    pub fn eql(lhs: *const @This(), rhs: *const @This()) bool {
        return css.implementEql(@This(), lhs, rhs);
    }
};

/// A value for the [visibility](https://drafts.csswg.org/css-display-3/#visibility) property.
pub const Visibility = enum {
    /// The element is visible.
    visible,
    /// The element is hidden.
    hidden,
    /// The element is collapsed.
    collapse,

    const css_impl = css.DefineEnumProperty(@This());
    pub const eql = css_impl.eql;
    pub const parse = css_impl.parse;
    pub const toCss = css_impl.toCss;
    pub const deepClone = css_impl.deepClone;
};

/// A `display` keyword.
pub const DisplayKeyword = enum {
    none,
    contents,
    @"table-row-group",
    @"table-header-group",
    @"table-footer-group",
    @"table-row",
    @"table-cell",
    @"table-column-group",
    @"table-column",
    @"table-caption",
    @"ruby-base",
    @"ruby-text",
    @"ruby-base-container",
    @"ruby-text-container",

    const css_impl = css.DefineEnumProperty(@This());
    pub const eql = css_impl.eql;
    pub const parse = css_impl.parse;
    pub const toCss = css_impl.toCss;
    pub const deepClone = css_impl.deepClone;
};

/// A pair of inside and outside display values, as used in the `display` property.
pub const DisplayPair = struct {
    /// The outside display value.
    outside: DisplayOutside,
    /// The inside display value.
    inside: DisplayInside,
    /// Whether this is a list item.
    is_list_item: bool,

    pub fn parse(input: *css.Parser) css.Result(DisplayPair) {
        var outside: ?DisplayOutside = null;
        var inside: ?DisplayInside = null;
        var is_list_item = false;
        var parsed_any = false;

        while (true) {
            if (!is_list_item and input.tryParse(css.Parser.expectIdentMatching, .{"list-item"}).isOk()) {
                is_list_item = true;
                parsed_any = true;
                continue;
            }
            if (outside == null) {
                if (input.tryParse(DisplayOutside.parse, .{}).asValue()) |value| {
                    outside = value;
                    parsed_any = true;
                    continue;
                }
            }
            if (inside == null) {
                if (input.tryParse(DisplayInside.parse, .{}).asValue()) |value| {
                    inside = value;
                    parsed_any = true;
                    continue;
                }
            }
            break;
        }

        if (!parsed_any) return .{ .err = input.newCustomError(css.ParserError.invalid_value) };
        return .{ .result = .{
            .outside = outside orelse .block,
            .inside = inside orelse .flow,
            .is_list_item = is_list_item,
        } };
    }

    pub fn toCss(this: *const @This(), dest: *Printer) PrintErr!void {
        try this.outside.toCss(dest);
        try dest.writeChar(' ');
        try this.inside.toCss(dest);
        if (this.is_list_item) {
            try dest.writeStr(" list-item");
        }
    }

    pub fn eql(lhs: *const @This(), rhs: *const @This()) bool {
        return css.implementEql(@This(), lhs, rhs);
    }
};

/// A [`<display-outside>`](https://drafts.csswg.org/css-display-3/#typedef-display-outside) value.
pub const DisplayOutside = enum {
    block,
    @"inline",
    @"run-in",

    const css_impl = css.DefineEnumProperty(@This());
    pub const eql = css_impl.eql;
    pub const parse = css_impl.parse;
    pub const toCss = css_impl.toCss;
    pub const deepClone = css_impl.deepClone;
};

/// A [`<display-inside>`](https://drafts.csswg.org/css-display-3/#typedef-display-inside) value.
pub const DisplayInside = union(enum) {
    flow,
    flow_root,
    table,
    flex: css.VendorPrefix,
    box: css.VendorPrefix,
    grid,
    ruby,

    pub fn eql(lhs: *const @This(), rhs: *const @This()) bool {
        return css.implementEql(@This(), lhs, rhs);
    }

    pub fn parse(input: *css.Parser) css.Result(DisplayInside) {
        const location = input.currentSourceLocation();
        const ident = switch (input.expectIdent()) {
            .result => |value| value,
            .err => |e| return .{ .err = e },
        };

        if (bun.strings.eqlCaseInsensitiveASCIIICheckLength(ident, "flow")) return .{ .result = .flow };
        if (bun.strings.eqlCaseInsensitiveASCIIICheckLength(ident, "flow-root")) return .{ .result = .flow_root };
        if (bun.strings.eqlCaseInsensitiveASCIIICheckLength(ident, "table")) return .{ .result = .table };
        if (bun.strings.eqlCaseInsensitiveASCIIICheckLength(ident, "flex")) return .{ .result = .{ .flex = css.VendorPrefix.NONE } };
        if (bun.strings.eqlCaseInsensitiveASCIIICheckLength(ident, "-webkit-flex")) return .{ .result = .{ .flex = css.VendorPrefix.WEBKIT } };
        if (bun.strings.eqlCaseInsensitiveASCIIICheckLength(ident, "box")) return .{ .result = .{ .box = css.VendorPrefix.NONE } };
        if (bun.strings.eqlCaseInsensitiveASCIIICheckLength(ident, "-webkit-box")) return .{ .result = .{ .box = css.VendorPrefix.WEBKIT } };
        if (bun.strings.eqlCaseInsensitiveASCIIICheckLength(ident, "grid")) return .{ .result = .grid };
        if (bun.strings.eqlCaseInsensitiveASCIIICheckLength(ident, "ruby")) return .{ .result = .ruby };

        return .{ .err = location.newUnexpectedTokenError(.{ .ident = ident }) };
    }

    pub fn toCss(this: *const @This(), dest: *Printer) PrintErr!void {
        switch (this.*) {
            .flow => try dest.writeStr("flow"),
            .flow_root => try dest.writeStr("flow-root"),
            .table => try dest.writeStr("table"),
            .flex => |*prefix| {
                try prefix.toCss(dest);
                try dest.writeStr("flex");
            },
            .box => |*prefix| {
                try prefix.toCss(dest);
                try dest.writeStr("box");
            },
            .grid => try dest.writeStr("grid"),
            .ruby => try dest.writeStr("ruby"),
        }
    }
};

test "DisplayKeyword has none tag" {
    const k: DisplayKeyword = .none;
    try std.testing.expect(k == .none);
}

test "Visibility has 3 tags" {
    try std.testing.expect(@as(Visibility, .visible) == .visible);
    try std.testing.expect(@as(Visibility, .hidden) == .hidden);
    try std.testing.expect(@as(Visibility, .collapse) == .collapse);
}

test "DisplayPair holds outside + inside + is_list_item" {
    const d = DisplayPair{
        .outside = .block,
        .inside = .flow,
        .is_list_item = false,
    };
    try std.testing.expect(d.outside == .block);
    try std.testing.expect(d.inside == .flow);
    try std.testing.expect(!d.is_list_item);
}

test "DisplayInside.flex carries a VendorPrefix" {
    const d: DisplayInside = .{ .flex = css.VendorPrefix.WEBKIT };
    try std.testing.expect(d == .flex);
    try std.testing.expect(d.flex.webkit);
}

test "Display.keyword variant" {
    const d: Display = .{ .keyword = .none };
    try std.testing.expect(d == .keyword);
    try std.testing.expect(d.keyword == .none);
}

test "Display.pair variant" {
    const d: Display = .{ .pair = DisplayPair{
        .outside = .@"inline",
        .inside = .flow,
        .is_list_item = false,
    } };
    try std.testing.expect(d == .pair);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const bun = @import("bun");
