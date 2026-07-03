// Copied from bun/src/css/rules/viewport.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
// Imports rewritten: @import("../css_parser.zig") → @import("../css_parser_stub.zig").
// The real css_parser substrate hasn't landed yet, so Printer / PrintErr /
// Location / VendorPrefix / DeclarationBlock come from the local stub. The
// `toCss` body still references stub methods that trip `@compileError` if
// exercised — the data shape (`vendor_prefix`/`declarations`/`loc`) compiles
// and that's what wave-7 needs.
//
// Path-relative import works under the home_rt aggregator (whose containment
// directory is `packages/runtime/src/`, spanning both `css/rules/` and the
// stub). Standalone per-file `zig test` requires the stub to be promoted to
// a sibling module via `--dep` (see PORTING_STATUS.md for the verifier
// command); the aggregator build (`zig build test`) is the canonical CI gate.

pub const css = @import("../css_parser.zig");
const Printer = css.Printer;
const PrintErr = css.PrintErr;
const Location = css.Location;

/// A [@viewport](https://drafts.csswg.org/css-device-adapt/#atviewport-rule) rule.
pub const ViewportRule = struct {
    /// The vendor prefix for this rule, e.g. `@-ms-viewport`.
    vendor_prefix: css.VendorPrefix,
    /// The declarations within the `@viewport` rule.
    declarations: css.DeclarationBlock,
    /// The location of the rule in the source file.
    loc: Location,

    const This = @This();

    pub fn toCss(this: *const This, dest: *Printer) PrintErr!void {
        // #[cfg(feature = "sourcemap")]
        // dest.add_mapping(self.loc);
        try dest.writeChar('@');
        try this.vendor_prefix.toCss(dest);
        try dest.writeStr("viewport");
        try this.declarations.toCssBlock(dest);
    }

    pub fn deepClone(this: *const @This(), allocator: std.mem.Allocator) This {
        return css.implementDeepClone(@This(), this, allocator);
    }
};

test "ViewportRule struct holds vendor_prefix, declarations, loc" {
    const rule = ViewportRule{
        .vendor_prefix = css.VendorPrefix.MS,
        .declarations = .{},
        .loc = css.Location.dummy(),
    };
    try std.testing.expect(rule.vendor_prefix.ms);
    try std.testing.expectEqual(std.math.maxInt(u32), rule.loc.source_index);
}

test "ViewportRule.deepClone is a shallow copy under the stub" {
    const rule = ViewportRule{
        .vendor_prefix = css.VendorPrefix.WEBKIT,
        .declarations = .{},
        .loc = .{ .source_index = 1, .line = 2, .column = 3 },
    };
    const cloned = rule.deepClone(std.testing.allocator);
    try std.testing.expectEqual(rule.loc.source_index, cloned.loc.source_index);
    try std.testing.expectEqual(rule.loc.line, cloned.loc.line);
    try std.testing.expectEqual(rule.loc.column, cloned.loc.column);
    try std.testing.expect(cloned.vendor_prefix.webkit);
}

const std = @import("std");
