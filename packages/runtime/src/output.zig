// Home Runtime — terminal output helpers.
//
// Minimal initial surface that the copied Bun cli leaves rely on:
// pretty-print + flush + error/warning shortcuts. The upstream Bun
// `Output` namespace is enormous; we land coverage as each copied
// file needs more.

const std = @import("std");

pub var enable_ansi_colors_stderr = false;
pub var enable_ansi_colors_stdout = false;

const CSI = "\x1b[";
var error_writer_buffer: [4096]u8 = undefined;
var error_file_writer: ?std.Io.File.Writer = null;

fn debugIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub const color_map = struct {
    const Entry = struct {
        key: []const u8,
        value: []const u8,
    };

    const entries = [_]Entry{
        .{ .key = "b", .value = CSI ++ "1m" },
        .{ .key = "d", .value = CSI ++ "2m" },
        .{ .key = "i", .value = CSI ++ "3m" },
        .{ .key = "u", .value = CSI ++ "4m" },
        .{ .key = "black", .value = CSI ++ "30m" },
        .{ .key = "red", .value = CSI ++ "31m" },
        .{ .key = "green", .value = CSI ++ "32m" },
        .{ .key = "yellow", .value = CSI ++ "33m" },
        .{ .key = "blue", .value = CSI ++ "34m" },
        .{ .key = "magenta", .value = CSI ++ "35m" },
        .{ .key = "cyan", .value = CSI ++ "36m" },
        .{ .key = "white", .value = CSI ++ "37m" },
        .{ .key = "bgred", .value = CSI ++ "41m" },
        .{ .key = "bggreen", .value = CSI ++ "42m" },
    };

    pub fn get(key: []const u8) ?[]const u8 {
        inline for (entries) |entry| {
            if (std.mem.eql(u8, key, entry.key)) return entry.value;
        }
        return null;
    }
};

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

pub fn printError(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

pub fn printErrorln(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt ++ "\n", args);
}

pub fn printElapsed(elapsed_ms: f64) void {
    std.debug.print("[{d:.2}ms]", .{elapsed_ms});
}

pub fn prettyFmt(comptime fmt: []const u8, comptime _: bool) []const u8 {
    return fmt;
}

pub fn errorln(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt ++ "\n", args);
}

pub fn debugWarn(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt ++ "\n", args);
}

pub fn flush() void {
    // The upstream `Output.flush()` reaches into an internal buffered
    // writer. `std.debug.print` is already line-buffered to stderr, so
    // flush is a no-op until Home routes through its own buffered
    // writer in a later sub-phase.
    if (error_file_writer) |*writer| writer.interface.flush() catch {};
}

pub fn resetTerminal() void {}

pub fn errorWriter() *std.Io.Writer {
    if (error_file_writer == null) {
        error_file_writer = std.Io.File.Writer.initStreaming(.stderr(), debugIo(), &error_writer_buffer);
    }
    return &error_file_writer.?.interface;
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
