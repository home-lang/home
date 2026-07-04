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

const Property = css.css_properties.Property;
const PropertyId = css.css_properties.PropertyId;
const isFlex2009 = css.prefixes.Feature.isFlex2009;

pub const FlexHandler = struct {
    /// The flex-direction property value and vendor prefix
    direction: ?struct { FlexDirection, VendorPrefix } = null,
    /// The box-orient property value and vendor prefix (legacy)
    box_orient: ?struct { BoxOrient, VendorPrefix } = null,
    /// The box-direction property value and vendor prefix (legacy)
    box_direction: ?struct { BoxDirection, VendorPrefix } = null,
    /// The flex-wrap property value and vendor prefix
    wrap: ?struct { FlexWrap, VendorPrefix } = null,
    /// The box-lines property value and vendor prefix (legacy)
    box_lines: ?struct { BoxLines, VendorPrefix } = null,
    /// The flex-grow property value and vendor prefix
    grow: ?struct { CSSNumber, VendorPrefix } = null,
    /// The box-flex property value and vendor prefix (legacy)
    box_flex: ?struct { CSSNumber, VendorPrefix } = null,
    /// The flex-positive property value and vendor prefix (legacy)
    flex_positive: ?struct { CSSNumber, VendorPrefix } = null,
    /// The flex-shrink property value and vendor prefix
    shrink: ?struct { CSSNumber, VendorPrefix } = null,
    /// The flex-negative property value and vendor prefix (legacy)
    flex_negative: ?struct { CSSNumber, VendorPrefix } = null,
    /// The flex-basis property value and vendor prefix
    basis: ?struct { LengthPercentageOrAuto, VendorPrefix } = null,
    /// The preferred-size property value and vendor prefix (legacy)
    preferred_size: ?struct { LengthPercentageOrAuto, VendorPrefix } = null,
    /// The order property value and vendor prefix
    order: ?struct { CSSInteger, VendorPrefix } = null,
    /// The box-ordinal-group property value and vendor prefix (legacy)
    box_ordinal_group: ?struct { BoxOrdinalGroup, VendorPrefix } = null,
    /// The flex-order property value and vendor prefix (legacy)
    flex_order: ?struct { CSSInteger, VendorPrefix } = null,
    /// Whether any flex-related properties have been set
    has_any: bool = false,

    pub fn handleProperty(
        this: *@This(),
        property: *const Property,
        dest: *css.DeclarationList,
        context: *css.PropertyHandlerContext,
    ) bool {
        const maybeFlush = struct {
            fn maybeFlush(
                self: *FlexHandler,
                d: *css.DeclarationList,
                ctx: *css.PropertyHandlerContext,
                comptime prop: []const u8,
                val: anytype,
                vp: *const VendorPrefix,
            ) void {
                // If two vendor prefixes for the same property have different
                // values, we need to flush what we have immediately to preserve order.
                if (@field(self, prop)) |*field| {
                    if (!std.meta.eql(field[0], val.*) and !bun.bits.contains(css.VendorPrefix, field[1], vp.*)) {
                        self.flush(d, ctx);
                    }
                }
            }
        }.maybeFlush;

        const propertyHelper = struct {
            fn propertyHelper(
                self: *FlexHandler,
                ctx: *css.PropertyHandlerContext,
                d: *css.DeclarationList,
                comptime prop: []const u8,
                val: anytype,
                vp: *const VendorPrefix,
            ) void {
                maybeFlush(self, d, ctx, prop, val, vp);

                // Otherwise, update the value and add the prefix
                if (@field(self, prop)) |*field| {
                    field[0] = css.generic.deepClone(@TypeOf(val.*), val, ctx.allocator);
                    bun.bits.insert(css.VendorPrefix, &field[1], vp.*);
                } else {
                    @field(self, prop) = .{
                        css.generic.deepClone(@TypeOf(val.*), val, ctx.allocator),
                        vp.*,
                    };
                    self.has_any = true;
                }
            }
        }.propertyHelper;

        switch (property.*) {
            .@"flex-direction" => |*val| {
                if (context.targets.browsers != null) {
                    this.box_direction = null;
                    this.box_orient = null;
                }
                propertyHelper(this, context, dest, "direction", &val[0], &val[1]);
            },
            .@"box-orient" => |*val| propertyHelper(this, context, dest, "box_orient", &val[0], &val[1]),
            .@"box-direction" => |*val| propertyHelper(this, context, dest, "box_direction", &val[0], &val[1]),
            .@"flex-wrap" => |*val| {
                if (context.targets.browsers != null) {
                    this.box_lines = null;
                }
                propertyHelper(this, context, dest, "wrap", &val[0], &val[1]);
            },
            .@"box-lines" => |*val| propertyHelper(this, context, dest, "box_lines", &val[0], &val[1]),
            .@"flex-flow" => |*val| {
                if (context.targets.browsers != null) {
                    this.box_direction = null;
                    this.box_orient = null;
                }
                propertyHelper(this, context, dest, "direction", &val[0].direction, &val[1]);
                propertyHelper(this, context, dest, "wrap", &val[0].wrap, &val[1]);
            },
            .@"flex-grow" => |*val| {
                if (context.targets.browsers != null) {
                    this.box_flex = null;
                    this.flex_positive = null;
                }
                propertyHelper(this, context, dest, "grow", &val[0], &val[1]);
            },
            .@"box-flex" => |*val| propertyHelper(this, context, dest, "box_flex", &val[0], &val[1]),
            .@"flex-positive" => |*val| propertyHelper(this, context, dest, "flex_positive", &val[0], &val[1]),
            .@"flex-shrink" => |*val| {
                if (context.targets.browsers != null) {
                    this.flex_negative = null;
                }
                propertyHelper(this, context, dest, "shrink", &val[0], &val[1]);
            },
            .@"flex-negative" => |*val| propertyHelper(this, context, dest, "flex_negative", &val[0], &val[1]),
            .@"flex-basis" => |*val| {
                if (context.targets.browsers != null) {
                    this.preferred_size = null;
                }
                propertyHelper(this, context, dest, "basis", &val[0], &val[1]);
            },
            .@"flex-preferred-size" => |*val| propertyHelper(this, context, dest, "preferred_size", &val[0], &val[1]),
            .flex => |*val| {
                if (context.targets.browsers != null) {
                    this.box_flex = null;
                    this.flex_positive = null;
                    this.flex_negative = null;
                    this.preferred_size = null;
                }
                maybeFlush(this, dest, context, "grow", &val[0].grow, &val[1]);
                maybeFlush(this, dest, context, "shrink", &val[0].shrink, &val[1]);
                maybeFlush(this, dest, context, "basis", &val[0].basis, &val[1]);
                propertyHelper(this, context, dest, "grow", &val[0].grow, &val[1]);
                propertyHelper(this, context, dest, "shrink", &val[0].shrink, &val[1]);
                propertyHelper(this, context, dest, "basis", &val[0].basis, &val[1]);
            },
            .order => |*val| {
                if (context.targets.browsers != null) {
                    this.box_ordinal_group = null;
                    this.flex_order = null;
                }
                propertyHelper(this, context, dest, "order", &val[0], &val[1]);
            },
            .@"box-ordinal-group" => |*val| propertyHelper(this, context, dest, "box_ordinal_group", &val[0], &val[1]),
            .@"flex-order" => |*val| propertyHelper(this, context, dest, "flex_order", &val[0], &val[1]),
            .unparsed => |*val| {
                if (isFlexProperty(&val.property_id)) {
                    this.flush(dest, context);
                    dest.append(context.allocator, property.deepClone(context.allocator)) catch unreachable;
                } else {
                    return false;
                }
            },
            else => return false,
        }

        return true;
    }

    pub fn finalize(this: *@This(), dest: *css.DeclarationList, context: *css.PropertyHandlerContext) void {
        this.flush(dest, context);
    }

    fn flush(this: *@This(), dest: *css.DeclarationList, context: *css.PropertyHandlerContext) void {
        if (!this.has_any) {
            return;
        }

        this.has_any = false;

        var direction: ?struct { FlexDirection, VendorPrefix } = bun.take(&this.direction);
        var wrap: ?struct { FlexWrap, VendorPrefix } = bun.take(&this.wrap);
        var grow: ?struct { CSSNumber, VendorPrefix } = bun.take(&this.grow);
        var shrink: ?struct { CSSNumber, VendorPrefix } = bun.take(&this.shrink);
        var basis = bun.take(&this.basis);
        var box_orient = bun.take(&this.box_orient);
        var box_direction = bun.take(&this.box_direction);
        var box_flex = bun.take(&this.box_flex);
        var box_ordinal_group = bun.take(&this.box_ordinal_group);
        var box_lines = bun.take(&this.box_lines);
        var flex_positive = bun.take(&this.flex_positive);
        var flex_negative = bun.take(&this.flex_negative);
        var preferred_size = bun.take(&this.preferred_size);
        var order = bun.take(&this.order);
        var flex_order = bun.take(&this.flex_order);

        // Legacy properties. These are only set if the final standard properties were unset.
        legacyProperty(this, "box-orient", bun.take(&box_orient), dest, context);
        legacyProperty(this, "box-direction", bun.take(&box_direction), dest, context);
        legacyProperty(this, "box-ordinal-group", bun.take(&box_ordinal_group), dest, context);
        legacyProperty(this, "box-flex", bun.take(&box_flex), dest, context);
        legacyProperty(this, "box-lines", bun.take(&box_lines), dest, context);
        legacyProperty(this, "flex-positive", bun.take(&flex_positive), dest, context);
        legacyProperty(this, "flex-negative", bun.take(&flex_negative), dest, context);
        legacyProperty(this, "flex-preferred-size", bun.take(&preferred_size), dest, context);
        legacyProperty(this, "flex-order", bun.take(&flex_order), dest, context);

        if (direction) |val| {
            const dir = val[0];
            if (context.targets.browsers) |targets| {
                const prefixes = context.targets.prefixes(css.VendorPrefix.NONE, css.prefixes.Feature.flex_direction);
                var prefixes_2009 = css.VendorPrefix{};
                if (isFlex2009(targets)) {
                    prefixes_2009.webkit = true;
                }
                if (prefixes.moz) {
                    prefixes_2009.moz = true;
                }
                if (!prefixes_2009.isEmpty()) {
                    const orient, const newdir = dir.to2009();
                    bun.handleOom(dest.append(context.allocator, Property{ .@"box-orient" = .{ orient, prefixes_2009 } }));
                    bun.handleOom(dest.append(context.allocator, Property{ .@"box-direction" = .{ newdir, prefixes_2009 } }));
                }
            }
        }

        if (direction != null and wrap != null) {
            const dir: *FlexDirection = &direction.?[0];
            const dir_prefix: *VendorPrefix = &direction.?[1];
            const wrapinner: *FlexWrap = &wrap.?[0];
            const wrap_prefix: *VendorPrefix = &wrap.?[1];

            const intersection = dir_prefix.bitwiseAnd(wrap_prefix.*);
            if (!intersection.isEmpty()) {
                var prefix = context.targets.prefixes(intersection, css.prefixes.Feature.flex_flow);
                // Firefox only implemented the 2009 spec prefixed.
                prefix.moz = false;
                dest.append(context.allocator, Property{ .@"flex-flow" = .{
                    FlexFlow{
                        .direction = dir.*,
                        .wrap = wrapinner.*,
                    },
                    prefix,
                } }) catch |err| bun.handleOom(err);
                bun.bits.remove(css.VendorPrefix, dir_prefix, intersection);
                bun.bits.remove(css.VendorPrefix, wrap_prefix, intersection);
            }
        }

        this.singleProperty("flex-direction", bun.take(&direction), null, null, dest, context, "flex_direction");
        this.singleProperty("flex-wrap", bun.take(&wrap), null, .{ BoxLines, "box-lines" }, dest, context, "flex_wrap");

        if (context.targets.browsers) |targets| {
            if (grow) |val| {
                const g = val[0];
                const prefixes = context.targets.prefixes(css.VendorPrefix.NONE, css.prefixes.Feature.flex_grow);
                var prefixes_2009 = css.VendorPrefix{};
                if (isFlex2009(targets)) {
                    prefixes_2009.webkit = true;
                }
                if (prefixes.moz) {
                    prefixes_2009.moz = true;
                }
                if (!prefixes_2009.isEmpty()) {
                    bun.handleOom(dest.append(context.allocator, Property{ .@"box-flex" = .{ g, prefixes_2009 } }));
                }
            }
        }

        if (grow != null and shrink != null and basis != null) {
            const g = grow.?[0];
            const g_prefix: *VendorPrefix = &grow.?[1];
            const s = shrink.?[0];
            const s_prefix: *VendorPrefix = &shrink.?[1];
            const b = basis.?[0];
            const b_prefix: *VendorPrefix = &basis.?[1];

            const intersection = g_prefix.bitwiseAnd(s_prefix.bitwiseAnd(b_prefix.*));
            if (!intersection.isEmpty()) {
                var prefix = context.targets.prefixes(intersection, css.prefixes.Feature.flex);
                // Firefox only implemented the 2009 spec prefixed.
                prefix.moz = false;
                dest.append(context.allocator, Property{ .flex = .{
                    Flex{
                        .grow = g,
                        .shrink = s,
                        .basis = b,
                    },
                    prefix,
                } }) catch |err| bun.handleOom(err);
                bun.bits.remove(css.VendorPrefix, g_prefix, intersection);
                bun.bits.remove(css.VendorPrefix, s_prefix, intersection);
                bun.bits.remove(css.VendorPrefix, b_prefix, intersection);
            }
        }

        this.singleProperty("flex-grow", bun.take(&grow), "flex-positive", null, dest, context, "flex_grow");
        this.singleProperty("flex-shrink", bun.take(&shrink), "flex-negative", null, dest, context, "flex_shrink");
        this.singleProperty("flex-basis", bun.take(&basis), "flex-preferred-size", null, dest, context, "flex_basis");
        this.singleProperty("order", bun.take(&order), "flex-order", .{ BoxOrdinalGroup, "box-ordinal-group" }, dest, context, "order");
    }

    fn singleProperty(
        this: *FlexHandler,
        comptime prop: []const u8,
        key: anytype,
        comptime prop_2012: ?[]const u8,
        comptime prop_2009: ?struct { type, []const u8 },
        dest: *css.DeclarationList,
        ctx: *css.PropertyHandlerContext,
        comptime feature_name: []const u8,
    ) void {
        _ = this; // autofix
        if (key) |value| {
            const val = value[0];
            var prefix = value[1];
            if (!prefix.isEmpty()) {
                prefix = ctx.targets.prefixes(prefix, @field(css.prefixes.Feature, feature_name));
                if (comptime prop_2009) |p2009| {
                    if (prefix.none) {
                        // 2009 spec, implemented by webkit and firefox
                        if (ctx.targets.browsers) |targets| {
                            var prefixes_2009 = css.VendorPrefix{};
                            if (isFlex2009(targets)) {
                                prefixes_2009.webkit = true;
                            }
                            if (prefix.moz) {
                                prefixes_2009.moz = true;
                            }
                            if (!prefixes_2009.isEmpty()) {
                                const s = brk: {
                                    const T = comptime p2009[0];
                                    if (comptime T == BoxOrdinalGroup) break :brk @as(?i32, val);
                                    break :brk p2009[0].fromStandard(&val);
                                };
                                if (s) |v| {
                                    dest.append(ctx.allocator, @unionInit(Property, p2009[1], .{
                                        v,
                                        prefixes_2009,
                                    })) catch |err| bun.handleOom(err);
                                }
                            }
                        }
                    }
                }

                if (comptime prop_2012) |p2012| {
                    var ms = true;
                    if (prefix.ms) {
                        dest.append(ctx.allocator, @unionInit(Property, p2012, .{
                            val,
                            css.VendorPrefix.MS,
                        })) catch |err| bun.handleOom(err);
                        ms = false;
                    }

                    if (!ms) {
                        prefix.ms = false;
                    }
                }

                // Firefox only implemented the 2009 spec prefixed.
                prefix.moz = false;
                dest.append(ctx.allocator, @unionInit(Property, prop, .{
                    val,
                    prefix,
                })) catch |err| bun.handleOom(err);
            }
        }
    }

    fn legacyProperty(this: *FlexHandler, comptime field_name: []const u8, key: anytype, dest: *css.DeclarationList, ctx: *css.PropertyHandlerContext) void {
        _ = this; // autofix
        if (key) |value| {
            const val = value[0];
            const prefix = value[1];
            if (!prefix.isEmpty()) {
                dest.append(ctx.allocator, @unionInit(Property, field_name, .{
                    val,
                    prefix,
                })) catch |err| bun.handleOom(err);
            }
        }
    }

    fn isFlexProperty(property_id: *const PropertyId) bool {
        return switch (property_id.*) {
            .@"flex-direction",
            .@"box-orient",
            .@"box-direction",
            .@"flex-wrap",
            .@"box-lines",
            .@"flex-flow",
            .@"flex-grow",
            .@"box-flex",
            .@"flex-positive",
            .@"flex-shrink",
            .@"flex-negative",
            .@"flex-basis",
            .@"flex-preferred-size",
            .flex,
            .order,
            .@"box-ordinal-group",
            .@"flex-order",
            => true,
            else => false,
        };
    }
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

    pub fn to2009(this: *const FlexDirection) struct { BoxOrient, BoxDirection } {
        return switch (this.*) {
            .row => .{ .horizontal, .normal },
            .column => .{ .vertical, .normal },
            .@"row-reverse" => .{ .horizontal, .reverse },
            .@"column-reverse" => .{ .vertical, .reverse },
        };
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

    pub fn fromStandard(@"align": *const css.css_properties.@"align".AlignItems) ?BoxAlign {
        return switch (@"align".*) {
            .self_position => |sp| if (sp.overflow == null) switch (sp.value) {
                .start, .@"flex-start" => .start,
                .end, .@"flex-end" => .end,
                .center => .center,
                else => null,
            } else null,
            .stretch => .stretch,
            else => null,
        };
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

    pub fn fromStandard(justify: *const css.css_properties.@"align".JustifyContent) ?BoxPack {
        return switch (justify.*) {
            .content_distribution => |cd| switch (cd) {
                .@"space-between" => .justify,
                else => null,
            },
            .content_position => |cp| if (cp.overflow == null) switch (cp.value) {
                .start, .@"flex-start" => .start,
                .end, .@"flex-end" => .end,
                .center => .center,
            } else null,
            else => null,
        };
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

    pub fn fromStandard(justify: *const css.css_properties.@"align".JustifyContent) ?FlexPack {
        return switch (justify.*) {
            .content_distribution => |cd| switch (cd) {
                .@"space-between" => .justify,
                .@"space-around" => .distribute,
                else => null,
            },
            .content_position => |cp| if (cp.overflow == null) switch (cp.value) {
                .start, .@"flex-start" => .start,
                .end, .@"flex-end" => .end,
                .center => .center,
            } else null,
            else => null,
        };
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

    pub fn fromStandard(justify: *const css.css_properties.@"align".AlignSelf) ?FlexItemAlign {
        return switch (justify.*) {
            .auto => .auto,
            .stretch => .stretch,
            .self_position => |sp| if (sp.overflow == null) switch (sp.value) {
                .start, .@"flex-start" => .start,
                .end, .@"flex-end" => .end,
                .center => .center,
                else => null,
            } else null,
            else => null,
        };
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

    pub fn fromStandard(justify: *const css.css_properties.@"align".AlignContent) ?FlexLinePack {
        return switch (justify.*) {
            .content_distribution => |cd| switch (cd) {
                .@"space-between" => .justify,
                .@"space-around" => .distribute,
                .stretch => .stretch,
                else => null,
            },
            .content_position => |cp| if (cp.overflow == null) switch (cp.value) {
                .start, .@"flex-start" => .start,
                .end, .@"flex-end" => .end,
                .center => .center,
            } else null,
            else => null,
        };
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
const bun = @import("bun");
