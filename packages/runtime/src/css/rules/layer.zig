// Copied from bun/src/css/rules/layer.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
// Imports rewritten: @import("../css_parser.zig") → @import("../css_parser_stub.zig").
//
// Strategy-B port over the stub. `LayerName` carries a
// `SmallList([]const u8, 1)` (resolved via the stub); body methods (`parse`,
// `toCss`, `hash`, `format`, `HashMap`, `cloneWithImportRecords`) reach for
// `bun.strings.eql` / `bun.BabyList(bun.ImportRecord)` / `css.SmallList.append`
// / `css.serializer.serializeIdentifier` — all gone behind the stub or the
// upstream `bun` namespace, so they are stripped here. Pure-data shape
// (`v: SmallList(...)`) + `eql` over slices + `deepClone` are kept; `eql`
// uses raw `std.mem.eql` on each part instead of `bun.strings.eql`.
//
// `LayerBlockRule(R)` keeps `name: ?LayerName`, `rules: CssRuleList(R)`, `loc`;
// `toCss` strips (Printer methods trip `@compileError`). `LayerStatementRule`
// keeps `names: SmallList(LayerName, 1)` + `loc`; `toCss` stripped as well.

pub const css = @import("../css_parser.zig");
const Location = @import("./rules.zig").Location;
const CssRuleList = @import("./rules.zig").CssRuleList;
const SmallList = @import("../small_list.zig").SmallList;

/// Stored as a list of strings as dot notation can be used
/// to create sublayers.
pub const LayerName = struct {
    v: SmallList([]const u8, 1) = .{},

    pub fn deepClone(this: *const LayerName, allocator: std.mem.Allocator) LayerName {
        return LayerName{
            .v = this.v.clone(allocator),
        };
    }

    pub fn eql(lhs: *const LayerName, rhs: *const LayerName) bool {
        if (lhs.v.len() != rhs.v.len()) return false;
        for (lhs.v.slice(), rhs.v.slice()) |l, r| {
            if (!std.mem.eql(u8, l, r)) return false;
        }
        return true;
    }

    pub fn toCss(this: *const LayerName, dest: anytype) !void {
        for (this.v.slice(), 0..) |name, i| {
            if (i > 0) try dest.writeChar('.');
            try dest.writeStr(name);
        }
    }

    pub fn cloneWithImportRecords(this: *const LayerName, allocator: std.mem.Allocator, _: anytype) LayerName {
        return this.deepClone(allocator);
    }

    pub fn parse(input: *css.Parser) css.Result(LayerName) {
        var parts: css.SmallList([]const u8, 1) = .{};
        const ident = switch (input.expectIdent()) {
            .result => |v| v,
            .err => |e| return .{ .err = e },
        };
        parts.append(input.allocator(), ident);

        const Fn = struct {
            pub fn tryParseFn(i: *css.Parser) css.Result([]const u8) {
                {
                    const start_location = i.currentSourceLocation();
                    const tok = switch (i.nextIncludingWhitespace()) {
                        .err => |e| return .{ .err = e },
                        .result => |vvv| vvv,
                    };
                    if (!(tok.* == .delim and tok.delim == '.')) {
                        return .{ .err = start_location.newBasicUnexpectedTokenError(tok.*) };
                    }
                }
                const start_location = i.currentSourceLocation();
                const tok = switch (i.nextIncludingWhitespace()) {
                    .err => |e| return .{ .err = e },
                    .result => |vvv| vvv,
                };
                if (tok.* == .ident) {
                    return .{ .result = tok.ident };
                }
                return .{ .err = start_location.newBasicUnexpectedTokenError(tok.*) };
            }
        };

        while (true) {
            const name = switch (input.tryParse(Fn.tryParseFn, .{})) {
                .err => break,
                .result => |vvv| vvv,
            };
            parts.append(input.allocator(), name);
        }

        return .{ .result = LayerName{ .v = parts } };
    }
};

/// A [@layer block](https://drafts.csswg.org/css-cascade-5/#layer-block) rule.
pub fn LayerBlockRule(comptime R: type) type {
    return struct {
        /// The name of the layer to declare, or null to declare an anonymous layer.
        name: ?LayerName,
        /// The rules within the `@layer` rule.
        rules: CssRuleList(R),
        /// The location of the rule in the source file.
        loc: Location,

        pub fn toCss(this: *const @This(), dest: anytype) !void {
            try dest.writeStr("@layer");
            if (this.name) |*name| {
                try dest.writeChar(' ');
                try name.toCss(dest);
            }
            try dest.whitespace();
            try dest.writeChar('{');
            dest.indent();
            try dest.newline();
            try this.rules.toCss(dest);
            dest.dedent();
            try dest.newline();
            try dest.writeChar('}');
        }

        pub fn deepClone(this: *const @This(), allocator: std.mem.Allocator) @This() {
            return css.implementDeepClone(@This(), this, allocator);
        }
    };
}

/// A [@layer statement](https://drafts.csswg.org/css-cascade-5/#layer-empty) rule.
///
/// See also [LayerBlockRule](LayerBlockRule).
pub const LayerStatementRule = struct {
    /// The layer names to declare.
    names: SmallList(LayerName, 1),
    /// The location of the rule in the source file.
    loc: Location,

    pub fn toCss(this: *const @This(), dest: anytype) !void {
        if (this.names.len() > 0) {
            try dest.writeStr("@layer ");
            for (this.names.slice(), 0..) |*name, i| {
                if (i > 0) {
                    try dest.writeChar(',');
                    try dest.whitespace();
                }
                try name.toCss(dest);
            }
            try dest.writeChar(';');
        } else {
            try dest.writeStr("@layer;");
        }
    }

    pub fn deepClone(this: *const @This(), allocator: std.mem.Allocator) @This() {
        return css.implementDeepClone(@This(), this, allocator);
    }
};

test "LayerName default has zero parts" {
    const n = LayerName{};
    try std.testing.expectEqual(@as(usize, 0), n.v.len());
}

test "LayerName.eql compares part by part" {
    const a = LayerName{ .v = SmallList([]const u8, 1).initInlined(&.{"foo"}) };
    const b = LayerName{ .v = SmallList([]const u8, 1).initInlined(&.{"foo"}) };
    const c = LayerName{ .v = SmallList([]const u8, 1).initInlined(&.{"bar"}) };
    try std.testing.expect(LayerName.eql(&a, &b));
    try std.testing.expect(!LayerName.eql(&a, &c));
}

test "LayerName.eql returns false for different lengths" {
    const a = LayerName{ .v = SmallList([]const u8, 1).initInlined(&.{"x"}) };
    var b = LayerName{};
    b.v.append(std.testing.allocator, "x");
    b.v.append(std.testing.allocator, "y");
    defer b.v.deinit(std.testing.allocator);
    try std.testing.expect(!LayerName.eql(&a, &b));
}

test "LayerBlockRule(void) has expected shape" {
    const T = LayerBlockRule(void);
    const r = T{
        .name = LayerName{},
        .rules = .{},
        .loc = Location.dummy(),
    };
    try std.testing.expect(r.name != null);
    try std.testing.expectEqual(std.math.maxInt(u32), r.loc.source_index);
}

test "LayerBlockRule(u8) accepts null name (anonymous layer)" {
    const T = LayerBlockRule(u8);
    const r = T{
        .name = null,
        .rules = .{},
        .loc = .{ .source_index = 1, .line = 2, .column = 3 },
    };
    try std.testing.expect(r.name == null);
}

test "LayerStatementRule has names + loc" {
    const r = LayerStatementRule{
        .names = .{},
        .loc = .{ .source_index = 7, .line = 8, .column = 9 },
    };
    try std.testing.expectEqual(@as(usize, 0), r.names.len());
    try std.testing.expectEqual(@as(u32, 8), r.loc.line);
}

const std = @import("std");
