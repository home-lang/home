// Copied from bun/src/runtime/node/time_like.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Pure conversion helpers between numeric/JS-date inputs and the
// platform-specific `TimeLike` shape that `utimens()`/`uv_fs_utime()`
// expects. The upstream `fromJS` entrypoint parks until the jsc surface
// (JSGlobalObject + JSValue toNumber / getUnixTimestamp / jsType) re-lands;
// the three private converters (`fromSeconds`, `fromMilliseconds`,
// `fromNow`) are pure and ported verbatim.
//
// Imports rewritten: @import("bun") → @import("home") for the
// `Environment` namespace. `bun.c.UTIME_NOW` (macOS sys/stat.h) is inlined
// as a private constant — Home doesn't yet vendor the `bun.c.*` libc shim.

const std = @import("std");
const builtin = @import("builtin");

const home_rt = @import("home");
const Environment = home_rt.Environment;

/// On windows, this is what libuv expects.
/// On unix it is what the utimens api expects.
pub const TimeLike = if (Environment.isWindows) f64 else std.posix.timespec;

/// macOS `<sys/stat.h>` — `#define UTIME_NOW -1`. Equivalent semantics on
/// FreeBSD. Linux exposes the same value via `std.os.linux.UTIME.NOW`.
const UTIME_NOW: c_long = -1;

pub fn fromSeconds(seconds: f64) TimeLike {
    if (Environment.isWindows) {
        return seconds;
    }
    return .{
        .sec = @intFromFloat(seconds),
        .nsec = @intFromFloat(@mod(seconds, 1) * std.time.ns_per_s),
    };
}

pub fn fromMilliseconds(milliseconds: f64) TimeLike {
    if (Environment.isWindows) {
        return milliseconds / 1000.0;
    }

    var sec: f64 = @divFloor(milliseconds, std.time.ms_per_s);
    var nsec: f64 = @mod(milliseconds, std.time.ms_per_s) * std.time.ns_per_ms;

    if (nsec < 0) {
        nsec += std.time.ns_per_s;
        sec -= 1;
    }

    return .{
        .sec = @intFromFloat(sec),
        .nsec = @intFromFloat(nsec),
    };
}

pub fn fromNow() TimeLike {
    if (Environment.isWindows) {
        const nanos = std.time.nanoTimestamp();
        return @as(TimeLike, @floatFromInt(nanos)) / std.time.ns_per_s;
    }

    // Permissions requirements
    //        To set both file timestamps to the current time (i.e., times is
    //        NULL, or both tv_nsec fields specify UTIME_NOW), either:
    //
    //        •  the caller must have write access to the file;
    //
    //        •  the caller's effective user ID must match the owner of the
    //           file; or
    //
    //        •  the caller must have appropriate privileges.
    //
    //        To make any change other than setting both timestamps to the
    //        current time (i.e., times is not NULL, and neither tv_nsec field
    //        is UTIME_NOW and neither tv_nsec field is UTIME_OMIT), either
    //        condition 2 or 3 above must apply.
    //
    //        If both tv_nsec fields are specified as UTIME_OMIT, then no file
    //        ownership or permission checks are performed, and the file
    //        timestamps are not modified, but other error conditions may still
    return .{
        .sec = 0,
        .nsec = if (Environment.isLinux) std.os.linux.UTIME.NOW else UTIME_NOW,
    };
}

test "time_like: fromSeconds preserves integer + fractional parts on POSIX" {
    if (Environment.isWindows) return error.SkipZigTest;
    const t = fromSeconds(12.5);
    try std.testing.expectEqual(@as(@TypeOf(t.sec), 12), t.sec);
    // 0.5s = 500,000,000ns
    try std.testing.expectEqual(@as(@TypeOf(t.nsec), 500_000_000), t.nsec);
}

test "time_like: fromMilliseconds normalises negative nsec on POSIX" {
    if (Environment.isWindows) return error.SkipZigTest;
    // -1ms = -0.001s. After the borrow normalisation: sec = -1, nsec = 999ms.
    const t = fromMilliseconds(-1.0);
    try std.testing.expectEqual(@as(@TypeOf(t.sec), -1), t.sec);
    try std.testing.expectEqual(@as(@TypeOf(t.nsec), 999_000_000), t.nsec);
}

test "time_like: fromNow uses UTIME_NOW sentinel on POSIX" {
    if (Environment.isWindows) return error.SkipZigTest;
    const t = fromNow();
    try std.testing.expectEqual(@as(@TypeOf(t.sec), 0), t.sec);
    const expected: @TypeOf(t.nsec) = if (Environment.isLinux)
        @intCast(std.os.linux.UTIME.NOW)
    else
        @intCast(UTIME_NOW);
    try std.testing.expectEqual(expected, t.nsec);
}
