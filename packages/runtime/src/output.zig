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

test "prettyln formats without crashing" {
    prettyln("hello {s}", .{"world"});
}
