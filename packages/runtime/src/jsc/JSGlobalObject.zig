// Copied from bun/src/jsc/JSGlobalObject.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// `JSGlobalObject` is an opaque WebKit type. The upstream file is ~1000 lines
// of methods that need `JSValue`, `bun.String`, `VirtualMachine`, `JSError`,
// `bun.cpp.Bun__*`, etc. — none of which are wired here yet (Phase 12.2). What
// we keep is just the opaque shell plus the `GregorianDateTime` plain-data
// struct (no JSC fields) so callers that name the type compile. Every method
// re-lands once the JSC bridge re-attaches.

const std = @import("std");
const home_rt = @import("home_rt");

pub const JSGlobalObject = opaque {
    /// Plain (year, month, day, hh:mm:ss, weekday) tuple. Returned by the
    /// `Bun__msToGregorianDateTime` C++ binding once it re-attaches.
    pub const GregorianDateTime = struct {
        year: i32,
        month: i32,
        day: i32,
        hour: i32,
        minute: i32,
        second: i32,
        weekday: i32,
    };
};

test "JSGlobalObject is an opaque type" {
    try std.testing.expectEqual(@sizeOf(*JSGlobalObject), @sizeOf(usize));
}

test "GregorianDateTime is a POD" {
    const dt = JSGlobalObject.GregorianDateTime{
        .year = 2025,
        .month = 1,
        .day = 1,
        .hour = 0,
        .minute = 0,
        .second = 0,
        .weekday = 3,
    };
    try std.testing.expectEqual(@as(i32, 2025), dt.year);
    try std.testing.expectEqual(@as(i32, 3), dt.weekday);
}

comptime {
    _ = home_rt;
}
