// Copied from bun/src/css/rules/style.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
// Minimal real parser/printer surface for the generated rule table.

pub const css = @import("../css_parser.zig");

const Printer = css.Printer;
const PrintErr = css.PrintErr;
const Location = css.css_rules.Location;

pub fn StyleRule(comptime R: type) type {
    return struct {
        const This = @This();

        /// The selectors for the style rule.
        selectors: css.selector.parser.SelectorList,
        /// A vendor prefix override, used during selector printing.
        vendor_prefix: css.VendorPrefix,
        /// The declarations within the style rule.
        declarations: css.DeclarationBlock,
        /// Nested rules within the style rule.
        rules: css.CssRuleList(R),
        /// The location of the rule in the source file.
        loc: Location,

        pub fn deepClone(this: *const @This(), allocator: std.mem.Allocator) @This() {
            return css.implementDeepClone(@This(), this, allocator);
        }

        pub fn toCss(this: *const This, dest: *Printer) PrintErr!void {
            if (this.vendor_prefix.isEmpty()) {
                try this.toCssBase(dest);
            } else {
                var first_rule = true;
                inline for (css.VendorPrefix.FIELDS) |field| {
                    if (@field(this.vendor_prefix, field)) {
                        if (first_rule) {
                            first_rule = false;
                        } else {
                            if (!dest.minify) {
                                try dest.writeChar('\n'); // no indent
                            }
                            try dest.newline();
                        }
                        const prefix = css.VendorPrefix.fromName(field);
                        dest.vendor_prefix = prefix;
                        try this.toCssBase(dest);
                    }
                }
                dest.vendor_prefix = .{};
            }
        }

        fn toCssBase(this: *const This, dest: *Printer) PrintErr!void {
            // If supported, or there are no targets, preserve nesting. Otherwise, write nested rules after parent.
            const supports_nesting = this.rules.v.items.len == 0 or
                !css.Targets.shouldCompileSame(&dest.targets, .nesting);

            const len = this.declarations.declarations.items.len + this.declarations.important_declarations.items.len;
            const has_declarations = supports_nesting or len > 0 or this.rules.v.items.len == 0;

            if (has_declarations) {
                try css.selector.serialize.serializeSelectorList(this.selectors.v.slice(), dest, dest.context(), false);
                try dest.whitespace();
                try dest.writeChar('{');
                dest.indent();

                var i: usize = 0;
                const DECLS = .{ "declarations", "important_declarations" };
                inline for (DECLS) |decl_field_name| {
                    const important = comptime std.mem.eql(u8, decl_field_name, "important_declarations");
                    const decls = &@field(this.declarations, decl_field_name);

                    for (decls.items) |*decl| {
                        // The CSS modules `composes` property is handled specially, and omitted during printing.
                        if (decl.* == .composes) {
                            const composes = &decl.composes;
                            if (dest.isNested() and dest.css_module != null) {
                                return dest.newError(css.PrinterErrorKind.invalid_composes_nesting, composes.cssparser_loc);
                            }

                            if (dest.css_module) |*css_module| {
                                if (css_module.handleComposes(
                                    dest,
                                    &this.selectors,
                                    composes,
                                    this.loc.source_index,
                                ).asErr()) |error_kind| {
                                    return dest.newError(error_kind, composes.cssparser_loc);
                                }
                                continue;
                            }
                        }

                        try dest.newline();
                        try decl.toCss(dest, important);
                        if (i != len - 1 or !dest.minify or (supports_nesting and this.rules.v.items.len > 0)) {
                            try dest.writeChar(';');
                        }

                        i += 1;
                    }
                }
            }

            const Helpers = struct {
                pub fn newline(self: *const This, d: *Printer, supports_nesting2: bool, len1: usize) PrintErr!void {
                    if (!d.minify and (supports_nesting2 or len1 > 0) and self.rules.v.items.len > 0) {
                        if (len1 > 0) {
                            try d.writeChar('\n');
                        }
                        try d.newline();
                    }
                }

                pub fn end(d: *Printer, has_decls: bool) PrintErr!void {
                    if (has_decls) {
                        d.dedent();
                        try d.newline();
                        try d.writeChar('}');
                    }
                }
            };

            // Write nested rules after the parent.
            if (supports_nesting) {
                try Helpers.newline(this, dest, supports_nesting, len);
                try this.rules.toCss(dest);
                try Helpers.end(dest, has_declarations);
            } else {
                try Helpers.end(dest, has_declarations);
                try Helpers.newline(this, dest, supports_nesting, len);
                try dest.withContext(&this.selectors, this, struct {
                    pub fn toCss(self: *const This, d: *Printer) PrintErr!void {
                        return self.rules.toCss(d);
                    }
                }.toCss);
            }
        }

        pub fn minify(this: *This, context: *css.MinifyContext, parent_is_unused: bool) css.MinifyErr!bool {
            var unused = false;
            if (context.unused_symbols.count() > 0) {
                if (css.selector.isUnused(this.selectors.v.slice(), context.unused_symbols, &context.extra.symbols, parent_is_unused)) {
                    if (this.rules.v.items.len == 0) {
                        return true;
                    }
                    this.declarations.declarations.clearRetainingCapacity();
                    this.declarations.important_declarations.clearRetainingCapacity();
                    unused = true;
                }
            }

            context.handler_context.context = .style_rule;
            this.declarations.minify(context.handler, context.important_handler, &context.handler_context);
            context.handler_context.context = .none;

            if (this.rules.v.items.len > 0) {
                var handler_context = context.handler_context.child(.style_rule);
                std.mem.swap(css.PropertyHandlerContext, &context.handler_context, &handler_context);
                try this.rules.minify(context, unused);
                std.mem.swap(css.PropertyHandlerContext, &context.handler_context, &handler_context);
                if (unused and this.rules.v.items.len == 0) {
                    return true;
                }
            }

            return false;
        }

        pub fn isCompatible(_: *const @This(), _: anytype) bool {
            return true;
        }

        pub fn isEmpty(_: *const @This()) bool {
            return false;
        }

        pub fn hashKey(_: *const @This()) u64 {
            return 0;
        }

        pub fn isDuplicate(_: *const @This(), _: *const @This()) bool {
            return false;
        }

        pub fn updatePrefix(_: *@This(), _: anytype) void {}
    };
}

test "StyleRule(void) has expected shape" {
    const T = StyleRule(void);
    const r = T{
        .selectors = .{},
        .vendor_prefix = css.VendorPrefix.NONE,
        .declarations = .{},
        .rules = .{},
        .loc = css.Location.dummy(),
    };
    try std.testing.expect(r.vendor_prefix.none);
    try std.testing.expectEqual(std.math.maxInt(u32), r.loc.source_index);
}

test "StyleRule(u8) deepClone preserves loc + vendor_prefix" {
    const T = StyleRule(u8);
    const r = T{
        .selectors = .{},
        .vendor_prefix = css.VendorPrefix.WEBKIT,
        .declarations = .{},
        .rules = .{},
        .loc = .{ .source_index = 9, .line = 8, .column = 7 },
    };
    const cloned = r.deepClone(std.testing.allocator);
    try std.testing.expect(cloned.vendor_prefix.webkit);
    try std.testing.expectEqual(@as(u32, 8), cloned.loc.line);
}

const std = @import("std");
