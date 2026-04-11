//! Checked numeric cast helpers.
//!
//! The native codegen has hundreds of `@intCast`/`@truncate`/`@ptrCast` sites.
//! Most of those are statically safe (e.g. casting a literal known at compile
//! time), but a meaningful subset converts user-controlled values from one
//! width to another. A silent truncation in any of those sites is a
//! miscompilation: the produced binary will read or write the wrong bytes
//! without any indication of why.
//!
//! These helpers wrap Zig's stdlib `std.math.cast` so the unsafe sites can be
//! migrated incrementally. Each helper:
//!   1. Returns the converted value when it fits.
//!   2. Returns `error.IntegerOverflow` (for signed/unsigned width changes)
//!      or panics with a clear message (for `assertingCast`) otherwise.
//!
//! Migration guidance:
//!   - Use `safeIntCast` at user-data boundaries (literals from source,
//!     argument counts, array sizes parsed from text).
//!   - Use `assertingCast` for sites the caller proves safe via context but
//!     where a regression should be caught loudly in debug builds.
//!   - Leave bare `@intCast` only where the source bit-width is statically
//!     guaranteed to fit (e.g. `@intCast(@as(u8, ...))` to a wider type).

const std = @import("std");

pub const CastError = error{IntegerOverflow};

/// Cast `value` to `Target`, returning `error.IntegerOverflow` if it would
/// truncate or wrap around. Works for any integer type combination.
pub fn safeIntCast(comptime Target: type, value: anytype) CastError!Target {
    return std.math.cast(Target, value) orelse error.IntegerOverflow;
}

/// Like `safeIntCast` but treats overflow as a programmer bug: panics with a
/// descriptive message in debug builds, falls back to `@intCast` in release.
/// Use only when the caller has *already proven* the value fits.
pub fn assertingCast(comptime Target: type, value: anytype) Target {
    if (std.debug.runtime_safety) {
        return std.math.cast(Target, value) orelse {
            std.debug.print(
                "assertingCast: value {} does not fit in {s}\n",
                .{ value, @typeName(Target) },
            );
            @panic("assertingCast overflow");
        };
    }
    return @intCast(value);
}

/// Convert a signed integer to an unsigned one, panicking if negative.
pub fn unsignedFromSigned(comptime Target: type, value: anytype) CastError!Target {
    if (value < 0) return error.IntegerOverflow;
    return safeIntCast(Target, value);
}

test "safeIntCast in range" {
    try std.testing.expectEqual(@as(u8, 42), try safeIntCast(u8, @as(u32, 42)));
    try std.testing.expectEqual(@as(i32, -7), try safeIntCast(i32, @as(i64, -7)));
}

test "safeIntCast overflow" {
    try std.testing.expectError(error.IntegerOverflow, safeIntCast(u8, @as(u32, 300)));
    try std.testing.expectError(error.IntegerOverflow, safeIntCast(i8, @as(i32, 200)));
    try std.testing.expectError(error.IntegerOverflow, safeIntCast(u32, @as(i32, -1)));
}

test "unsignedFromSigned" {
    try std.testing.expectEqual(@as(u32, 5), try unsignedFromSigned(u32, @as(i32, 5)));
    try std.testing.expectError(error.IntegerOverflow, unsignedFromSigned(u32, @as(i32, -1)));
}
