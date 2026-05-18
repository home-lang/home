// Copied from bun/src/jsc/RegularExpression.zig at upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// `bun.String` is not yet ported. The extern Yarr__ functions take and return
// the C ABI of `bun.String`, so we stub it as an opaque-equivalent extern
// struct with the same layout. The JSC bridge re-attaches in Phase 12.2.

const std = @import("std");

// JSC bridge bun.String stubbed — re-attaches in Phase 12.2.
// `BunString` C ABI is `{tag: u8, impl: *anyopaque}` (see
// upstream src/string/BunString.h). We mirror the on-the-wire layout so
// pass-by-value extern signatures stay correct, without depending on the
// real String API.
const String = extern struct {
    tag: u8 = 0,
    _padding: [7]u8 = @splat(0),
    impl: ?*anyopaque = null,
};

pub const RegularExpression = opaque {
    pub const Flags = enum(u16) {
        none = 0,

        hasIndices = 1 << 0,
        global = 1 << 1,
        ignoreCase = 1 << 2,
        multiline = 1 << 3,
        dotAll = 1 << 4,
        unicode = 1 << 5,
        unicodeSets = 1 << 6,
        sticky = 1 << 7,
    };

    extern fn Yarr__RegularExpression__init(pattern: String, flags: u16) *RegularExpression;
    extern fn Yarr__RegularExpression__deinit(pattern: *RegularExpression) void;
    extern fn Yarr__RegularExpression__isValid(this: *RegularExpression) bool;
    extern fn Yarr__RegularExpression__matchedLength(this: *RegularExpression) i32;
    extern fn Yarr__RegularExpression__searchRev(this: *RegularExpression) i32;
    extern fn Yarr__RegularExpression__matches(this: *RegularExpression, string: String) i32;

    pub inline fn init(pattern: String, flags: Flags) error{InvalidRegExp}!*RegularExpression {
        var regex = Yarr__RegularExpression__init(pattern, @intFromEnum(flags));
        if (!regex.isValid()) {
            regex.deinit();
            return error.InvalidRegExp;
        }
        return regex;
    }

    pub inline fn isValid(this: *RegularExpression) bool {
        return Yarr__RegularExpression__isValid(this);
    }

    // Reserving `match` for a full match result.
    // pub inline fn match(this: *RegularExpression, str: String, startFrom: i32) MatchResult {
    // }

    // Simple boolean matcher
    pub inline fn matches(this: *RegularExpression, str: String) bool {
        return Yarr__RegularExpression__matches(this, str) >= 0;
    }

    // Note: upstream's `searchRev` calls `Yarr__RegularExpression__searchRev(this, str)`
    // even though the extern decl only takes `this`. We preserve the upstream
    // declaration verbatim — Zig allows the extra arg with a `// XXX` upstream
    // mismatch — by ignoring `str` here.
    pub inline fn searchRev(this: *RegularExpression, str: String) i32 {
        _ = str;
        return Yarr__RegularExpression__searchRev(this);
    }

    pub inline fn matchedLength(this: *RegularExpression) i32 {
        return Yarr__RegularExpression__matchedLength(this);
    }

    pub inline fn deinit(this: *RegularExpression) void {
        Yarr__RegularExpression__deinit(this);
    }
};

test "RegularExpression is opaque pointer-only" {
    try std.testing.expect(@sizeOf(*RegularExpression) == @sizeOf(usize));
}

test "Flags enum has the expected bit values" {
    try std.testing.expect(@intFromEnum(RegularExpression.Flags.none) == 0);
    try std.testing.expect(@intFromEnum(RegularExpression.Flags.hasIndices) == 1);
    try std.testing.expect(@intFromEnum(RegularExpression.Flags.global) == 2);
    try std.testing.expect(@intFromEnum(RegularExpression.Flags.ignoreCase) == 4);
    try std.testing.expect(@intFromEnum(RegularExpression.Flags.sticky) == 128);
}
