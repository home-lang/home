// Home Runtime — terminal output helpers.
//
// Minimal initial surface that the copied Bun cli leaves rely on:
// pretty-print + flush + error/warning shortcuts. The upstream Bun
// `Output` namespace is enormous; we land coverage as each copied
// file needs more.

const std = @import("std");

pub fn print(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

pub fn prettyln(comptime fmt: []const u8, args: anytype) void {
    // Home strips Bun's `<r>`/`<red>`/etc. markup at copy time; the
    // pretty layer renders them through the upstream macro. Until the
    // ansi parser lands here we emit plain text.
    std.debug.print(fmt ++ "\n", args);
}

pub fn prettyErrorln(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt ++ "\n", args);
}

pub fn errorln(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt ++ "\n", args);
}

pub fn flush() void {
    // The upstream `Output.flush()` reaches into an internal buffered
    // writer. `std.debug.print` is already line-buffered to stderr, so
    // flush is a no-op until Home routes through its own buffered
    // writer in a later sub-phase.
}

/// Minimal stub for `bun.Output.Visibility`. Upstream uses `.visible` /
/// `.hidden` to gate the env-var-driven `BUN_DEBUG_<TAG>` scoped logs.
pub const Visibility = enum { visible, hidden };

/// Minimal stub for `bun.Output.scoped(tag, visibility)`. Real upstream
/// returns a fn that prints when `BUN_DEBUG_<tag>` is set; our stub is a
/// no-op fn matching the `(comptime fmt, args)` signature so callers
/// compile through. TODO(phase-12-N): wire the env-var gating and the
/// `<r>`/`<red>` ansi parser.
pub fn scoped(comptime _: anytype, comptime _: Visibility) fn (comptime []const u8, anytype) void {
    return struct {
        fn log(comptime _: []const u8, _: anytype) void {}
    }.log;
}

/// Stub for `bun.Output.panic`. Mirrors `std.debug.panic` until Home's
/// crash handler is brought online.
pub fn panic(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.panic(fmt, args);
}

test "prettyln formats without crashing" {
    prettyln("hello {s}", .{"world"});
}
