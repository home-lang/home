// Copied from bun/src/css/rules/supports.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
// Imports rewritten: @import("../css_parser.zig") → @import("../css_parser_stub.zig").
//
// Strategy-B port over the stub. `SupportsCondition` is a tagged union with
// recursive (`*SupportsCondition`) + list (`ArrayList(SupportsCondition)`) +
// inline (`declaration: { property_id, value }`, `selector: []const u8`,
// `unknown: []const u8`) variants — all kept as pure data. `PropertyId`
// resolves via the stub (added in wave-10) and trips `@compileError` if a
// runtime method is reached.
//
// `parse`/`toCss`/`needsParens`/`toCssWithParensIfNeeded`/`deinit`/
// `cloneWithImportRecords`/`hash` all reach for `css.deepDeinit`,
// `css.serializer.serializeName`, `property_id.prefix()`/`name()`,
// `dest.writeStr` etc. — all behind `@compileError` and stripped here.
//
// `SupportsRule(R)` keeps `condition`/`rules: CssRuleList(R)`/`loc`. `toCss`/
// `minify` stripped.

pub const css = @import("../css_parser.zig");

const Printer = css.Printer;
const PrintErr = css.PrintErr;
const Location = @import("./rules.zig").Location;
const RealCssRuleList = @import("./rules.zig").CssRuleList;

const ArrayList = std.ArrayListUnmanaged;

/// A [`<supports-condition>`](https://drafts.csswg.org/css-conditional-3/#typedef-supports-condition),
/// as used in the `@supports` and `@import` rules.
pub const SupportsCondition = union(enum) {
    /// A `not` expression.
    not: *SupportsCondition,

    /// An `and` expression.
    @"and": ArrayList(SupportsCondition),

    /// An `or` expression.
    @"or": ArrayList(SupportsCondition),

    /// A declaration to evaluate.
    declaration: struct {
        /// The property id for the declaration.
        property_id: css.PropertyId,
        /// The raw value of the declaration.
        ///
        /// What happens if the value is a URL? A URL in this context does nothing
        /// e.g. `@supports (background-image: url('example.png'))`
        value: []const u8,

        pub fn eql(this: *const @This(), other: *const @This()) bool {
            return css.implementEql(@This(), this, other);
        }

        pub fn deepClone(this: *const @This(), allocator: std.mem.Allocator) @This() {
            return css.implementDeepClone(@This(), this, allocator);
        }
    },

    /// A selector to evaluate.
    selector: []const u8,

    /// An unknown condition.
    unknown: []const u8,

    pub fn eql(this: *const SupportsCondition, other: *const SupportsCondition) bool {
        return css.implementEql(SupportsCondition, this, other);
    }

    pub fn deepClone(this: *const SupportsCondition, allocator: std.mem.Allocator) SupportsCondition {
        return css.implementDeepClone(SupportsCondition, this, allocator);
    }

    pub fn deinit(_: *const SupportsCondition, _: std.mem.Allocator) void {}

    const SeenDeclKey = struct {
        css.PropertyId,
        []const u8,
    };

    pub fn parse(input: *css.Parser) css.Result(SupportsCondition) {
        if (input.tryParse(css.Parser.expectIdentMatching, .{"not"}).isOk()) {
            const in_parens = switch (SupportsCondition.parseInParens(input)) {
                .result => |vv| vv,
                .err => |e| return .{ .err = e },
            };
            return .{ .result = .{ .not = bun.create(input.allocator(), SupportsCondition, in_parens) } };
        }

        const in_parens: SupportsCondition = switch (SupportsCondition.parseInParens(input)) {
            .result => |vv| vv,
            .err => |e| return .{ .err = e },
        };
        var expected_type: ?i32 = null;
        var conditions: ArrayList(SupportsCondition) = .empty;

        while (true) {
            const Closure = struct {
                expected_type: *?i32,
                pub fn tryParseFn(i: *css.Parser, this: *@This()) css.Result(SupportsCondition) {
                    const location = i.currentSourceLocation();
                    const s = switch (i.expectIdent()) {
                        .result => |vv| vv,
                        .err => |e| return .{ .err = e },
                    };
                    const found_type: i32 = found_type: {
                        if (bun.strings.eqlCaseInsensitiveASCIIICheckLength("and", s)) break :found_type 1;
                        if (bun.strings.eqlCaseInsensitiveASCIIICheckLength("or", s)) break :found_type 2;
                        return .{ .err = location.newUnexpectedTokenError(.{ .ident = s }) };
                    };

                    if (this.expected_type.*) |expected| {
                        if (found_type != expected) return .{ .err = location.newUnexpectedTokenError(.{ .ident = s }) };
                    } else {
                        this.expected_type.* = found_type;
                    }

                    return SupportsCondition.parseInParens(i);
                }
            };
            var closure = Closure{ .expected_type = &expected_type };
            const _condition = input.tryParse(Closure.tryParseFn, .{&closure});

            switch (_condition) {
                .result => |condition| {
                    if (conditions.items.len == 0) {
                        bun.handleOom(conditions.append(input.allocator(), in_parens.deepClone(input.allocator())));
                    }
                    bun.handleOom(conditions.append(input.allocator(), condition));
                },
                else => break,
            }
        }

        if (conditions.items.len == 1) {
            const ret = conditions.pop().?;
            conditions.deinit(input.allocator());
            return .{ .result = ret };
        }

        if (expected_type == 1) return .{ .result = .{ .@"and" = conditions } };
        if (expected_type == 2) return .{ .result = .{ .@"or" = conditions } };
        return .{ .result = in_parens };
    }

    pub fn parseDeclaration(input: *css.Parser) css.Result(SupportsCondition) {
        const property_id = switch (css.PropertyId.parse(input)) {
            .result => |v| v,
            .err => |e| return .{ .err = e },
        };
        if (input.expectColon().asErr()) |e| return .{ .err = e };
        input.skipWhitespace();
        const pos = input.position();
        if (input.expectNoErrorToken().asErr()) |e| return .{ .err = e };
        return .{ .result = SupportsCondition{ .declaration = .{
            .property_id = property_id,
            .value = input.sliceFrom(pos),
        } } };
    }

    fn parseInParens(input: *css.Parser) css.Result(SupportsCondition) {
        input.skipWhitespace();
        const location = input.currentSourceLocation();
        const pos = input.position();
        const tok = switch (input.next()) {
            .result => |vv| vv,
            .err => |e| return .{ .err = e },
        };
        switch (tok.*) {
            .function => |f| {
                if (bun.strings.eqlCaseInsensitiveASCIIICheckLength("selector", f)) {
                    const Fn = struct {
                        pub fn tryParseFn(i: *css.Parser) css.Result(SupportsCondition) {
                            return i.parseNestedBlock(SupportsCondition, {}, @This().parseNestedBlockFn);
                        }
                        pub fn parseNestedBlockFn(_: void, i: *css.Parser) css.Result(SupportsCondition) {
                            const p = i.position();
                            if (i.expectNoErrorToken().asErr()) |e| return .{ .err = e };
                            return .{ .result = SupportsCondition{ .selector = i.sliceFrom(p) } };
                        }
                    };
                    const res = input.tryParse(Fn.tryParseFn, .{});
                    if (res.isOk()) return res;
                }
            },
            .open_paren => {
                const res = input.tryParse(struct {
                    pub fn parseFn(i: *css.Parser) css.Result(SupportsCondition) {
                        return i.parseNestedBlock(SupportsCondition, {}, css.voidWrap(SupportsCondition, parse));
                    }
                }.parseFn, .{});
                if (res.isOk()) return res;
            },
            else => return .{ .err = location.newUnexpectedTokenError(tok.*) },
        }

        if (input.parseNestedBlock(void, {}, struct {
            pub fn parseFn(_: void, i: *css.Parser) css.Result(void) {
                return i.expectNoErrorToken();
            }
        }.parseFn).asErr()) |err| {
            return .{ .err = err };
        }

        return .{ .result = SupportsCondition{ .unknown = input.sliceFrom(pos) } };
    }

    pub fn cloneWithImportRecords(this: *const SupportsCondition, allocator: std.mem.Allocator, _: anytype) SupportsCondition {
        return this.deepClone(allocator);
    }

    pub fn toCss(this: *const SupportsCondition, dest: anytype) !void {
        switch (this.*) {
            .unknown => |text| try dest.writeStr(text),
            .selector => |sel| {
                try dest.writeStr("selector(");
                try dest.writeStr(sel);
                try dest.writeChar(')');
            },
            .declaration => |decl| {
                try dest.writeChar('(');
                css.serializer.serializeName(decl.property_id.name(), dest) catch return dest.addFmtError();
                try dest.delim(':', false);
                try dest.writeStr(decl.value);
                try dest.writeChar(')');
            },
            .not => |condition| {
                try dest.writeStr("not ");
                try condition.toCss(dest);
            },
            .@"and" => |list| {
                for (list.items, 0..) |*condition, i| {
                    if (i > 0) try dest.writeStr(" and ");
                    try condition.toCss(dest);
                }
            },
            .@"or" => |list| {
                for (list.items, 0..) |*condition, i| {
                    if (i > 0) try dest.writeStr(" or ");
                    try condition.toCss(dest);
                }
            },
        }
    }
};

/// A [@supports](https://drafts.csswg.org/css-conditional-3/#at-supports) rule.
pub fn SupportsRule(comptime R: type) type {
    return struct {
        /// The supports condition.
        condition: SupportsCondition,
        /// The rules within the `@supports` rule.
        rules: RealCssRuleList(R),
        /// The location of the rule in the source file.
        loc: Location,

        pub fn deepClone(this: *const @This(), allocator: std.mem.Allocator) @This() {
            return css.implementDeepClone(@This(), this, allocator);
        }

        pub fn toCss(this: *const @This(), dest: anytype) PrintErr!void {
            try dest.writeStr("@supports ");
            try this.condition.toCss(dest);
            try dest.whitespace();
            try dest.writeChar('{');
            dest.indent();
            try dest.newline();
            try this.rules.toCss(dest);
            dest.dedent();
            try dest.newline();
            try dest.writeChar('}');
        }

        pub fn minify(_: *@This(), _: anytype, _: bool) !bool {
            return false;
        }
    };
}

test "SupportsCondition selector + unknown variants carry raw strings" {
    const s: SupportsCondition = .{ .selector = "a > b" };
    const u: SupportsCondition = .{ .unknown = "weird()" };
    try std.testing.expectEqualStrings("a > b", s.selector);
    try std.testing.expectEqualStrings("weird()", u.unknown);
}

test "SupportsCondition.and is an ArrayList (empty default)" {
    const empty: ArrayList(SupportsCondition) = .empty;
    const c: SupportsCondition = .{ .@"and" = empty };
    try std.testing.expectEqual(@as(usize, 0), c.@"and".items.len);
}

test "SupportsCondition.declaration carries property_id + value" {
    const c: SupportsCondition = .{ .declaration = .{
        .property_id = .color,
        .value = "1px solid red",
    } };
    try std.testing.expectEqualStrings("1px solid red", c.declaration.value);
}

test "SupportsRule(void) keeps the three fields" {
    const T = SupportsRule(void);
    const r = T{
        .condition = .{ .selector = "*" },
        .rules = .{},
        .loc = Location.dummy(),
    };
    try std.testing.expect(r.condition == .selector);
    try std.testing.expectEqual(std.math.maxInt(u32), r.loc.source_index);
}

const std = @import("std");
const bun = @import("bun");
