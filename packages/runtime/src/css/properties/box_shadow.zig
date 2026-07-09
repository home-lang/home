// Copied from bun/src/css/properties/box_shadow.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
// Minimal real parser/printer surface for the generated properties table.

pub const css = @import("../css_parser.zig");

const Printer = css.Printer;
const PrintErr = css.PrintErr;

const CssColor = css.css_values.color.CssColor;
const Length = css.css_values.length.Length;

const VendorPrefix = css.VendorPrefix;

const Property = css.css_properties.Property;
const SmallList = css.SmallList;
const Feature = css.prefixes.Feature;

pub const BoxShadowHandler = struct {
    box_shadows: ?struct { SmallList(BoxShadow, 1), VendorPrefix } = null,
    flushed: bool = false,

    pub fn handleProperty(this: *@This(), property: *const Property, dest: *css.DeclarationList, context: *css.PropertyHandlerContext) bool {
        switch (property.*) {
            .@"box-shadow" => |*b| {
                const box_shadows: *const SmallList(BoxShadow, 1) = &b.*[0];
                const prefix: VendorPrefix = b.*[1];
                if (this.box_shadows != null and context.targets.browsers != null and !box_shadows.isCompatible(context.targets.browsers.?)) {
                    this.flush(dest, context);
                }

                if (this.box_shadows) |*bxs| {
                    const val: *SmallList(BoxShadow, 1) = &bxs.*[0];
                    const prefixes: *VendorPrefix = &bxs.*[1];
                    if (!val.eql(box_shadows) and !bun.bits.contains(VendorPrefix, prefixes.*, prefix)) {
                        this.flush(dest, context);
                        this.box_shadows = .{
                            box_shadows.deepClone(context.allocator),
                            prefix,
                        };
                    } else {
                        val.* = box_shadows.deepClone(context.allocator);
                        bun.bits.insert(VendorPrefix, prefixes, prefix);
                    }
                } else {
                    this.box_shadows = .{
                        box_shadows.deepClone(context.allocator),
                        prefix,
                    };
                }
            },
            .unparsed => |unp| {
                if (unp.property_id == .@"box-shadow") {
                    this.flush(dest, context);

                    var unparsed = unp.deepClone(context.allocator);
                    context.addUnparsedFallbacks(&unparsed);
                    bun.handleOom(dest.append(context.allocator, .{ .unparsed = unparsed }));
                    this.flushed = true;
                } else return false;
            },
            else => return false,
        }

        return true;
    }

    pub fn finalize(this: *@This(), dest: *css.DeclarationList, context: *css.PropertyHandlerContext) void {
        this.flush(dest, context);
        this.flushed = false;
    }

    pub fn flush(this: *@This(), dest: *css.DeclarationList, context: *css.PropertyHandlerContext) void {
        if (this.box_shadows == null) return;

        const box_shadows: SmallList(BoxShadow, 1), const prefixes2: VendorPrefix = bun.take(&this.box_shadows) orelse {
            this.flushed = true;
            return;
        };

        if (!this.flushed) {
            const ColorFallbackKind = css.ColorFallbackKind;
            var prefixes = context.targets.prefixes(prefixes2, Feature.box_shadow);
            var fallbacks = ColorFallbackKind{};
            for (box_shadows.slice()) |*shadow| {
                bun.bits.insert(ColorFallbackKind, &fallbacks, shadow.color.getNecessaryFallbacks(context.targets));
            }

            if (fallbacks.rgb) {
                var rgb = SmallList(BoxShadow, 1).initCapacity(context.allocator, box_shadows.len());
                rgb.setLen(box_shadows.len());
                for (box_shadows.slice(), rgb.slice_mut()) |*input, *output| {
                    output.color = input.color.toRGB(context.allocator) orelse input.color.deepClone(context.allocator);
                    const fields = bun.meta.fieldsOf(BoxShadow);
                    inline for (fields) |field| {
                        if (comptime std.mem.eql(u8, field.name, "color")) continue;
                        @field(output, field.name) = css.generic.deepClone(field.type, &@field(input, field.name), context.allocator);
                    }
                }

                bun.handleOom(dest.append(context.allocator, .{ .@"box-shadow" = .{ rgb, prefixes } }));
                if (prefixes.none) {
                    prefixes = VendorPrefix.NONE;
                } else {
                    // Only output RGB for prefixed property (e.g. -webkit-box-shadow)
                    return;
                }
            }

            if (fallbacks.p3) {
                var p3 = SmallList(BoxShadow, 1).initCapacity(context.allocator, box_shadows.len());
                p3.setLen(box_shadows.len());
                for (box_shadows.slice(), p3.slice_mut()) |*input, *output| {
                    output.color = input.color.toP3(context.allocator) orelse input.color.deepClone(context.allocator);
                    const fields = bun.meta.fieldsOf(BoxShadow);
                    inline for (fields) |field| {
                        if (comptime std.mem.eql(u8, field.name, "color")) continue;
                        @field(output, field.name) = css.generic.deepClone(field.type, &@field(input, field.name), context.allocator);
                    }
                }
                bun.handleOom(dest.append(context.allocator, .{ .@"box-shadow" = .{ p3, VendorPrefix.NONE } }));
            }

            if (fallbacks.lab) {
                var lab = SmallList(BoxShadow, 1).initCapacity(context.allocator, box_shadows.len());
                lab.setLen(box_shadows.len());
                for (box_shadows.slice(), lab.slice_mut()) |*input, *output| {
                    output.color = input.color.toLAB(context.allocator) orelse input.color.deepClone(context.allocator);
                    const fields = bun.meta.fieldsOf(BoxShadow);
                    inline for (fields) |field| {
                        if (comptime std.mem.eql(u8, field.name, "color")) continue;
                        @field(output, field.name) = css.generic.deepClone(field.type, &@field(input, field.name), context.allocator);
                    }
                }
                bun.handleOom(dest.append(context.allocator, .{ .@"box-shadow" = .{ lab, VendorPrefix.NONE } }));
            } else {
                bun.handleOom(dest.append(context.allocator, .{ .@"box-shadow" = .{ box_shadows, prefixes } }));
            }
        } else {
            bun.handleOom(dest.append(context.allocator, .{ .@"box-shadow" = .{ box_shadows, prefixes2 } }));
        }

        this.flushed = true;
    }
};

/// A value for the [box-shadow](https://drafts.csswg.org/css-backgrounds/#box-shadow) property.
pub const BoxShadow = struct {
    /// The color of the box shadow.
    color: CssColor,
    /// The x offset of the shadow.
    x_offset: Length,
    /// The y offset of the shadow.
    y_offset: Length,
    /// The blur radius of the shadow.
    blur: Length,
    /// The spread distance of the shadow.
    spread: Length,
    /// Whether the shadow is inset within the box.
    inset: bool,

    pub fn parse(input: *css.Parser) css.Result(BoxShadow) {
        var color: ?CssColor = null;
        var inset = false;

        while (true) {
            if (color == null) {
                if (input.tryParse(CssColor.parse, .{}).asValue()) |value| {
                    color = value;
                    continue;
                }
            }
            if (!inset and input.tryParse(css.Parser.expectIdentMatching, .{"inset"}).isOk()) {
                inset = true;
                continue;
            }
            break;
        }

        const x_offset = switch (Length.parse(input)) {
            .result => |value| value,
            .err => |e| return .{ .err = e },
        };
        const y_offset = switch (Length.parse(input)) {
            .result => |value| value,
            .err => |e| return .{ .err = e },
        };
        const blur = input.tryParse(Length.parse, .{}).unwrapOr(Length.zero());
        const spread = input.tryParse(Length.parse, .{}).unwrapOr(Length.zero());

        while (true) {
            if (color == null) {
                if (input.tryParse(CssColor.parse, .{}).asValue()) |value| {
                    color = value;
                    continue;
                }
            }
            if (!inset and input.tryParse(css.Parser.expectIdentMatching, .{"inset"}).isOk()) {
                inset = true;
                continue;
            }
            break;
        }

        return .{ .result = .{
            .color = color orelse CssColor.current_color,
            .x_offset = x_offset,
            .y_offset = y_offset,
            .blur = blur,
            .spread = spread,
            .inset = inset,
        } };
    }

    pub fn toCss(this: *const @This(), dest: *Printer) PrintErr!void {
        if (this.inset) {
            try dest.writeStr("inset ");
        }
        try this.x_offset.toCss(dest);
        try dest.writeChar(' ');
        try this.y_offset.toCss(dest);
        if (!this.blur.isZero() or !this.spread.isZero()) {
            try dest.writeChar(' ');
            try this.blur.toCss(dest);

            if (!this.spread.isZero()) {
                try dest.writeChar(' ');
                try this.spread.toCss(dest);
            }
        }
        if (this.color != .current_color) {
            try dest.writeChar(' ');
            try this.color.toCss(dest);
        }
    }

    pub fn deepClone(this: *const @This(), allocator: std.mem.Allocator) @This() {
        return css.implementDeepClone(@This(), this, allocator);
    }

    pub fn eql(lhs: *const @This(), rhs: *const @This()) bool {
        return css.implementEql(@This(), lhs, rhs);
    }

    pub fn isCompatible(this: *const @This(), browsers: css.targets.Browsers) bool {
        return this.color.isCompatible(browsers) and
            this.x_offset.isCompatible(browsers) and
            this.y_offset.isCompatible(browsers) and
            this.blur.isCompatible(browsers) and
            this.spread.isCompatible(browsers);
    }
};

test "BoxShadow holds pure-data fields" {
    const s = BoxShadow{
        .color = .current_color,
        .x_offset = Length.zero(),
        .y_offset = Length.zero(),
        .blur = Length.zero(),
        .spread = Length.zero(),
        .inset = false,
    };
    try std.testing.expect(s.color == .current_color);
    try std.testing.expect(!s.inset);
}

test "BoxShadow.inset flag round-trips" {
    const a = BoxShadow{
        .color = .current_color,
        .x_offset = Length.zero(),
        .y_offset = Length.zero(),
        .blur = Length.zero(),
        .spread = Length.zero(),
        .inset = true,
    };
    try std.testing.expect(a.inset);
}

test "BoxShadow.deepClone is a shallow copy" {
    const s = BoxShadow{
        .color = .current_color,
        .x_offset = Length.zero(),
        .y_offset = Length.zero(),
        .blur = Length.zero(),
        .spread = Length.zero(),
        .inset = false,
    };
    const cloned = s.deepClone(std.testing.allocator);
    try std.testing.expect(cloned.color == .current_color);
    try std.testing.expect(cloned.inset == s.inset);
}

const std = @import("std");
const bun = @import("bun");
