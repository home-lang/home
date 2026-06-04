// Copied from bun/src/css/properties/flex.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
// Minimal real parser/printer surface for the generated properties table.

pub const css = @import("../css_parser.zig");

const Printer = css.Printer;
const PrintErr = css.PrintErr;

const CSSNumber = css.css_values.number.CSSNumber;
const CSSNumberFns = css.css_values.number.CSSNumberFns;
const LengthPercentage = css.css_values.length.LengthPercentage;
const LengthPercentageOrAuto = css.css_values.length.LengthPercentageOrAuto;

const VendorPrefix = css.VendorPrefix;

pub const FlexHandler = struct {
    pub fn handleProperty(_: *FlexHandler, _: anytype, _: anytype, _: anytype) bool {
        return false;
    }

    pub fn finalize(_: *FlexHandler, _: anytype, _: anytype) void {}
};

/// Upstream `CSSInteger` is `i32`; the stub doesn't surface it yet so we
/// alias locally to keep the typedef accurate.
pub const CSSInteger = i32;

/// A value for the [flex-direction](https://www.w3.org/TR/2018/CR-css-flexbox-1-20181119/#propdef-flex-direction) property.
pub const FlexDirection = enum {
    /// Flex items are laid out in a row.
    row,
    /// Flex items are laid out in a row, and reversed.
    @"row-reverse",
    /// Flex items are laid out in a column.
    column,
    /// Flex items are laid out in a column, and reversed.
    @"column-reverse",

    const css_impl = css.DefineEnumProperty(@This());
    pub const eql = css_impl.eql;
    pub const hash = css_impl.hash;
    pub const parse = css_impl.parse;
    pub const toCss = css_impl.toCss;
    pub const deepClone = css_impl.deepClone;

    pub fn default() FlexDirection {
        return .row;
    }
};

/// A value for the [flex-wrap](https://www.w3.org/TR/2018/CR-css-flexbox-1-20181119/#flex-wrap-property) property.
pub const FlexWrap = enum {
    /// The flex items do not wrap.
    nowrap,
    /// The flex items wrap.
    wrap,
    /// The flex items wrap, in reverse.
    @"wrap-reverse",

    const css_impl = css.DefineEnumProperty(@This());
    pub const eql = css_impl.eql;
    pub const hash = css_impl.hash;
    pub const parse = css_impl.parse;
    pub const toCss = css_impl.toCss;
    pub const deepClone = css_impl.deepClone;

    pub fn default() FlexWrap {
        return .nowrap;
    }

    pub fn fromStandard(this: *const FlexWrap) ?FlexWrap {
        return this.*;
    }
};

/// A value for the [flex-flow](https://www.w3.org/TR/2018/CR-css-flexbox-1-20181119/#flex-flow-property) shorthand property.
pub const FlexFlow = struct {
    /// The direction that flex items flow.
    direction: FlexDirection,
    /// How the flex items wrap.
    wrap: FlexWrap,

    pub const PropertyFieldMap = .{
        .direction = "flex-direction",
        .wrap = "flex-wrap",
    };

    pub const VendorPrefixMap = .{
        .direction = true,
        .wrap = true,
    };

    pub fn parse(input: *css.Parser) css.Result(FlexFlow) {
        var direction: ?FlexDirection = null;
        var wrap: ?FlexWrap = null;
        var parsed_any = false;

        while (true) {
            if (direction == null) {
                if (input.tryParse(FlexDirection.parse, .{}).asValue()) |value| {
                    direction = value;
                    parsed_any = true;
                    continue;
                }
            }
            if (wrap == null) {
                if (input.tryParse(FlexWrap.parse, .{}).asValue()) |value| {
                    wrap = value;
                    parsed_any = true;
                    continue;
                }
            }
            break;
        }

        if (!parsed_any) return .{ .err = input.newCustomError(css.ParserError.invalid_value) };
        return .{ .result = .{
            .direction = direction orelse FlexDirection.default(),
            .wrap = wrap orelse FlexWrap.default(),
        } };
    }

    pub fn toCss(this: *const @This(), dest: *Printer) PrintErr!void {
        try this.direction.toCss(dest);
        if (this.wrap != FlexWrap.default()) {
            try dest.writeChar(' ');
            try this.wrap.toCss(dest);
        }
    }

    pub fn deepClone(this: *const @This(), allocator: std.mem.Allocator) @This() {
        return css.implementDeepClone(@This(), this, allocator);
    }

    pub fn eql(lhs: *const @This(), rhs: *const @This()) bool {
        return css.implementEql(@This(), lhs, rhs);
    }
};

/// A value for the [flex](https://www.w3.org/TR/2018/CR-css-flexbox-1-20181119/#flex-property) shorthand property.
pub const Flex = struct {
    /// The flex grow factor.
    grow: CSSNumber,
    /// The flex shrink factor.
    shrink: CSSNumber,
    /// The flex basis.
    basis: LengthPercentageOrAuto,

    pub const PropertyFieldMap = .{
        .grow = "flex-grow",
        .shrink = "flex-shrink",
        .basis = "flex-basis",
    };

    pub const VendorPrefixMap = .{
        .grow = true,
        .shrink = true,
        .basis = true,
    };

    pub fn parse(input: *css.Parser) css.Result(Flex) {
        const grow = switch (CSSNumberFns.parse(input)) {
            .result => |value| value,
            .err => |e| return .{ .err = e },
        };
        const shrink = input.tryParse(CSSNumberFns.parse, .{}).unwrapOr(1.0);
        const basis = input.tryParse(LengthPercentageOrAuto.parse, .{}).unwrapOr(.auto);
        return .{ .result = .{
            .grow = grow,
            .shrink = shrink,
            .basis = basis,
        } };
    }

    pub fn toCss(this: *const @This(), dest: *Printer) PrintErr!void {
        try CSSNumberFns.toCss(&this.grow, dest);
        try dest.writeChar(' ');
        try CSSNumberFns.toCss(&this.shrink, dest);
        try dest.writeChar(' ');
        try this.basis.toCss(dest);
    }

    pub fn deepClone(this: *const @This(), allocator: std.mem.Allocator) @This() {
        return css.implementDeepClone(@This(), this, allocator);
    }

    pub fn eql(lhs: *const @This(), rhs: *const @This()) bool {
        return css.implementEql(@This(), lhs, rhs);
    }
};

/// A value for the legacy (prefixed) [box-orient](https://www.w3.org/TR/2009/WD-css3-flexbox-20090723/#orientation) property.
pub const BoxOrient = enum {
    horizontal,
    vertical,
    @"inline-axis",
    @"block-axis",

    const css_impl = css.DefineEnumProperty(@This());
    pub const eql = css_impl.eql;
    pub const hash = css_impl.hash;
    pub const parse = css_impl.parse;
    pub const toCss = css_impl.toCss;
    pub const deepClone = css_impl.deepClone;

    pub fn fromStandard(_: anytype) ?BoxAlign {
        return null;
    }
};

/// A value for the legacy (prefixed) [box-direction](https://www.w3.org/TR/2009/WD-css3-flexbox-20090723/#displayorder) property.
pub const BoxDirection = enum {
    normal,
    reverse,

    const css_impl = css.DefineEnumProperty(@This());
    pub const eql = css_impl.eql;
    pub const hash = css_impl.hash;
    pub const parse = css_impl.parse;
    pub const toCss = css_impl.toCss;
    pub const deepClone = css_impl.deepClone;

    pub fn fromStandard(_: anytype) ?BoxPack {
        return null;
    }
};

pub const FlexAlign = BoxAlign;

/// A value for the legacy (prefixed) [box-align](https://www.w3.org/TR/2009/WD-css3-flexbox-20090723/#alignment) property.
pub const BoxAlign = enum {
    start,
    end,
    center,
    baseline,
    stretch,

    const css_impl = css.DefineEnumProperty(@This());
    pub const eql = css_impl.eql;
    pub const hash = css_impl.hash;
    pub const parse = css_impl.parse;
    pub const toCss = css_impl.toCss;
    pub const deepClone = css_impl.deepClone;

    pub fn fromStandard(_: anytype) ?BoxAlign {
        return null;
    }
};

/// A value for the legacy (prefixed) [box-pack](https://www.w3.org/TR/2009/WD-css3-flexbox-20090723/#packing) property.
pub const BoxPack = enum {
    start,
    end,
    center,
    justify,

    const css_impl = css.DefineEnumProperty(@This());
    pub const eql = css_impl.eql;
    pub const hash = css_impl.hash;
    pub const parse = css_impl.parse;
    pub const toCss = css_impl.toCss;
    pub const deepClone = css_impl.deepClone;

    pub fn fromStandard(_: anytype) ?BoxPack {
        return null;
    }
};

/// A value for the legacy (prefixed) [box-lines](https://www.w3.org/TR/2009/WD-css3-flexbox-20090723/#multiple) property.
pub const BoxLines = enum {
    single,
    multiple,

    const css_impl = css.DefineEnumProperty(@This());
    pub const eql = css_impl.eql;
    pub const hash = css_impl.hash;
    pub const parse = css_impl.parse;
    pub const toCss = css_impl.toCss;
    pub const deepClone = css_impl.deepClone;

    pub fn fromStandard(wrap: *const FlexWrap) ?BoxLines {
        return switch (wrap.*) {
            .nowrap => .single,
            .wrap => .multiple,
            else => null,
        };
    }
};

/// A value for the legacy (prefixed) [flex-pack](https://www.w3.org/TR/2012/WD-css3-flexbox-20120322/#flex-pack) property.
pub const FlexPack = enum {
    start,
    end,
    center,
    justify,
    distribute,

    const css_impl = css.DefineEnumProperty(@This());
    pub const eql = css_impl.eql;
    pub const hash = css_impl.hash;
    pub const parse = css_impl.parse;
    pub const toCss = css_impl.toCss;
    pub const deepClone = css_impl.deepClone;

    pub fn fromStandard(_: anytype) ?FlexPack {
        return null;
    }
};

/// A value for the legacy (prefixed) [flex-item-align](https://www.w3.org/TR/2012/WD-css3-flexbox-20120322/#flex-align) property.
pub const FlexItemAlign = enum {
    auto,
    start,
    end,
    center,
    baseline,
    stretch,

    const css_impl = css.DefineEnumProperty(@This());
    pub const eql = css_impl.eql;
    pub const hash = css_impl.hash;
    pub const parse = css_impl.parse;
    pub const toCss = css_impl.toCss;
    pub const deepClone = css_impl.deepClone;

    pub fn fromStandard(_: anytype) ?FlexItemAlign {
        return null;
    }
};

/// A value for the legacy (prefixed) [flex-line-pack](https://www.w3.org/TR/2012/WD-css3-flexbox-20120322/#flex-line-pack) property.
pub const FlexLinePack = enum {
    start,
    end,
    center,
    justify,
    distribute,
    stretch,

    const css_impl = css.DefineEnumProperty(@This());
    pub const eql = css_impl.eql;
    pub const hash = css_impl.hash;
    pub const parse = css_impl.parse;
    pub const toCss = css_impl.toCss;
    pub const deepClone = css_impl.deepClone;

    pub fn fromStandard(_: anytype) ?FlexLinePack {
        return null;
    }
};

pub const BoxOrdinalGroup = CSSInteger;

test "FlexDirection default is row" {
    try std.testing.expect(FlexDirection.default() == .row);
}

test "FlexWrap default is nowrap" {
    try std.testing.expect(FlexWrap.default() == .nowrap);
}

test "FlexFlow holds direction + wrap" {
    const f = FlexFlow{ .direction = .column, .wrap = .wrap };
    try std.testing.expect(f.direction == .column);
    try std.testing.expect(f.wrap == .wrap);
}

test "Flex holds grow/shrink/basis" {
    const flex = Flex{ .grow = 1.0, .shrink = 1.0, .basis = .auto };
    try std.testing.expectEqual(@as(f32, 1.0), flex.grow);
    try std.testing.expect(flex.basis == .auto);
}

test "BoxLines.fromStandard maps FlexWrap" {
    var nowrap: FlexWrap = .nowrap;
    var wrap: FlexWrap = .wrap;
    var wrap_reverse: FlexWrap = .@"wrap-reverse";
    try std.testing.expectEqual(@as(?BoxLines, .single), BoxLines.fromStandard(&nowrap));
    try std.testing.expectEqual(@as(?BoxLines, .multiple), BoxLines.fromStandard(&wrap));
    try std.testing.expectEqual(@as(?BoxLines, null), BoxLines.fromStandard(&wrap_reverse));
}

test "BoxOrdinalGroup is CSSInteger (= i32)" {
    const v: BoxOrdinalGroup = 7;
    try std.testing.expectEqual(@as(i32, 7), v);
}

test "FlexFlow.PropertyFieldMap exposes legacy keys" {
    try std.testing.expectEqualStrings("flex-direction", FlexFlow.PropertyFieldMap.direction);
}

const std = @import("std");
