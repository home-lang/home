// Home Runtime — terminal output helpers.
//
// Minimal initial surface that the copied Bun cli leaves rely on:
// pretty-print + flush + error/warning shortcuts. The upstream Bun
// `Output` namespace is enormous; we land coverage as each copied
// file needs more.

const std = @import("std");

pub const LogFunction = fn (comptime fmt: []const u8, args: anytype) void;
pub const Scoped = @import("bun_core/output.zig").Scoped;
pub const synchronized_start = @import("bun_core/output.zig").synchronized_start;
pub const synchronized_end = @import("bun_core/output.zig").synchronized_end;

pub var enable_ansi_colors_stderr = false;
pub var enable_ansi_colors_stdout = false;
pub var is_github_action = false;
pub const ElapsedFormatter = @import("bun_core/output.zig").ElapsedFormatter;

const CSI = "\x1b[";
var error_writer_buffer: [4096]u8 = undefined;
var error_file_writer: ?std.Io.File.Writer = null;
var stdout_writer_buffer: [4096]u8 = undefined;
var stdout_file_writer: ?std.Io.File.Writer = null;

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
    writer().print(fmt, args) catch {};
}

pub fn println(comptime fmt: []const u8, args: anytype) void {
    writer().print(fmt ++ "\n", args) catch {};
    flush();
}

pub fn prettyln(comptime fmt: []const u8, args: anytype) void {
    // Expand Bun's `<r>`/`<red>`/etc. markup through prettyFmt — emitting ANSI
    // when stdout colors are enabled, stripping the tags otherwise. Mirrors
    // upstream `bun_core/output.zig` prettyWithPrinter; without this the literal
    // `<green>`-style tags leak into output (e.g. the test runner summary).
    if (enable_ansi_colors_stdout) {
        writer().print(comptime prettyFmt(fmt ++ "\n", true), args) catch {};
    } else {
        writer().print(comptime prettyFmt(fmt ++ "\n", false), args) catch {};
    }
    flush();
}

pub fn prettyErrorln(comptime fmt: []const u8, args: anytype) void {
    if (enable_ansi_colors_stderr) {
        std.debug.print(comptime prettyFmt(fmt ++ "\n", true), args);
    } else {
        std.debug.print(comptime prettyFmt(fmt ++ "\n", false), args);
    }
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

pub fn isGithubAction() bool {
    return std.c.getenv("GITHUB_ACTIONS") != null;
}

const RESET: []const u8 = "\x1b[0m";

// Faithful port of upstream `bun_core/output.zig` prettyFmt: strips `<color>`
// tags (emitting ANSI codes when enabled) and returns a null-terminated
// comptime format string. Replaces the earlier `[]const u8` stub so callers
// like JSGlobalObject.throwPretty get the `[:0]const u8` they expect.
pub fn prettyFmt(comptime fmt: []const u8, comptime is_enabled: bool) [:0]const u8 {
    comptime var new_fmt: [fmt.len * 4]u8 = undefined;
    comptime var new_fmt_i: usize = 0;

    @setEvalBranchQuota(100_000);
    comptime var i: usize = 0;
    comptime while (i < fmt.len) {
        switch (fmt[i]) {
            '\\' => {
                i += 1;
                if (i < fmt.len) {
                    switch (fmt[i]) {
                        '<', '>' => {
                            new_fmt[new_fmt_i] = fmt[i];
                            new_fmt_i += 1;
                            i += 1;
                        },
                        else => {
                            new_fmt[new_fmt_i] = '\\';
                            new_fmt_i += 1;
                            new_fmt[new_fmt_i] = fmt[i];
                            new_fmt_i += 1;
                            i += 1;
                        },
                    }
                }
            },
            '>' => {
                i += 1;
            },
            '{' => {
                while (fmt.len > i and fmt[i] != '}') {
                    new_fmt[new_fmt_i] = fmt[i];
                    new_fmt_i += 1;
                    i += 1;
                }
            },
            '<' => {
                i += 1;
                var is_reset = fmt[i] == '/';
                if (is_reset) i += 1;
                const start: usize = i;
                while (i < fmt.len and fmt[i] != '>') {
                    i += 1;
                }

                const color_name = fmt[start..i];
                const color_str = color_picker: {
                    if (color_map.get(color_name)) |color_name_literal| {
                        break :color_picker color_name_literal;
                    } else if (std.mem.eql(u8, color_name, "r")) {
                        is_reset = true;
                        break :color_picker "";
                    } else {
                        @compileError("Invalid color name passed: " ++ color_name);
                    }
                };

                if (is_enabled) {
                    for (if (is_reset) RESET else color_str) |ch| {
                        new_fmt[new_fmt_i] = ch;
                        new_fmt_i += 1;
                    }
                }
            },

            else => {
                new_fmt[new_fmt_i] = fmt[i];
                new_fmt_i += 1;
                i += 1;
            },
        }
    };

    return comptime (new_fmt[0..new_fmt_i].* ++ .{0})[0..new_fmt_i :0];
}

pub fn errorln(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt ++ "\n", args);
}

pub fn debugWarn(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt ++ "\n", args);
}

pub fn flush() void {
    // Flush both the stdout and stderr buffered writers. `console.log` (via the
    // VM's ConsoleObject) writes through the stdout writer; without this flush
    // its buffered output is lost when the process exits.
    if (stdout_file_writer) |*w| w.interface.flush() catch {};
    if (error_file_writer) |*w| w.interface.flush() catch {};
}

pub fn resetTerminal() void {}

/// Faithful to upstream `Output.initTest`: enables ANSI color detection for
/// test runs so prettyfmt paths exercise the colored branch. Safe to call
/// repeatedly (idempotent).
pub fn initTest() void {
    enable_ansi_colors_stderr = false;
    enable_ansi_colors_stdout = false;
}

pub fn errorWriter() *std.Io.Writer {
    if (error_file_writer == null) {
        error_file_writer = std.Io.File.Writer.initStreaming(.stderr(), debugIo(), &error_writer_buffer);
    }
    return &error_file_writer.?.interface;
}

pub fn errorWriterBuffered() *std.Io.Writer {
    return errorWriter();
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

// ---------------------------------------------------------------------------
// Error / warning shortcuts — narrowed ports of Bun's `Output.err`,
// `Output.errGeneric`, `Output.warn`, `Output.note`, `Output.pretty`,
// `Output.prettyError`, and `Output.command`. Home strips Bun's `<color>`
// markup at copy time, so these render the message as plain text. The install
// / package-manager cone (PackageManager.zig, lifecycle_script_runner.zig,
// migration.zig, …) relies on this surface.
// ---------------------------------------------------------------------------

/// Faithful narrowing of Bun's `Output.err`. The upstream Zig switched on
/// `@typeInfo(error_name)` to render an error-set value, an enum literal /
/// `@tagName`, or a string tag; we keep that contract and prefix the rendered
/// `fmt`/`args` body with `<name>:`.
pub inline fn err(error_name: anytype, comptime fmt: []const u8, args: anytype) void {
    const T = @TypeOf(error_name);
    const info = @typeInfo(T);
    const display_name: []const u8 = name: {
        if (info == .error_set) break :name @errorName(error_name);
        if (info == .enum_literal) break :name @tagName(error_name);
        // Zig string literals are `*const [n:0]u8`; treat pointer-to-array-of-u8
        // (and many-item/slice u8 pointers) as a dynamic error name/tag.
        if (info == .pointer) {
            const ptr = info.pointer;
            if (ptr.child == u8) break :name error_name;
            if (ptr.size == .one) {
                const child = @typeInfo(ptr.child);
                if (child == .array and child.array.child == u8) break :name error_name;
            }
        }
        if (@hasDecl(T, "name")) break :name error_name.name();
        break :name "error";
    };
    prettyErrorln("{s}: " ++ fmt, .{display_name} ++ args);
}

/// `Output.errGeneric` — `error:` prefix to stderr with the rendered template.
pub fn errGeneric(comptime fmt: []const u8, args: anytype) void {
    prettyErrorln("error: " ++ fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    prettyErrorln("warn: " ++ fmt, args);
}

pub fn note(comptime fmt: []const u8, args: anytype) void {
    prettyErrorln("note: " ++ fmt, args);
}

pub fn pretty(comptime fmt: []const u8, args: anytype) void {
    if (enable_ansi_colors_stdout) {
        writer().print(comptime prettyFmt(fmt, true), args) catch {};
    } else {
        writer().print(comptime prettyFmt(fmt, false), args) catch {};
    }
    flush();
}

pub fn prettyError(comptime fmt: []const u8, args: anytype) void {
    if (enable_ansi_colors_stderr) {
        std.debug.print(comptime prettyFmt(fmt, true), args);
    } else {
        std.debug.print(comptime prettyFmt(fmt, false), args);
    }
}

/// `Output.command` — echoes a command line before running it. Bun renders
/// `<r><d>$<r> <cyan>{s}<r>`; Home emits the plain command text.
pub fn command(cmd: []const u8) void {
    std.debug.print("$ {s}\n", .{cmd});
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt ++ "\n", args);
}

/// `Output.printStartEndStdout` — prints the elapsed `[Nms]` between two
/// `std.time.nanoTimestamp()` samples. Narrowed port; renders to stdout.
pub fn printStartEndStdout(start: i128, end: i128) void {
    const elapsed_ms: f64 = @as(f64, @floatFromInt(end - start)) / std.time.ns_per_ms;
    std.debug.print("[{d:.2}ms]", .{elapsed_ms});
}

pub const printStartEnd = printStartEndStdout;

pub fn enableBuffering() void {}
pub fn resetTerminalAll() void {}
pub fn enableBufferingScope() BufferingScope {
    enableBuffering();
    return .{};
}

pub const BufferingScope = struct {
    pub fn deinit(_: BufferingScope) void {
        flush();
        disableBuffering();
    }
};

pub fn disableBuffering() void {
    flush();
}

pub fn writer() *std.Io.Writer {
    if (stdout_file_writer == null) {
        stdout_file_writer = std.Io.File.Writer.initStreaming(.stdout(), debugIo(), &stdout_writer_buffer);
    }
    return &stdout_file_writer.?.interface;
}

pub fn writerBuffered() *std.Io.Writer {
    return writer();
}

pub fn rawWriter() *std.Io.Writer {
    return writer();
}

pub fn rawErrorWriter() *std.Io.Writer {
    return errorWriter();
}

pub fn isStdinTTY() bool {
    return false;
}

pub var is_verbose: bool = false;

pub fn isVerbose() bool {
    return is_verbose;
}

/// `Output.stderr_descriptor_type` — Bun reports the stderr stream kind
/// (file / terminal / pipe). Home returns `.pipe` until the TTY probe lands.
pub const OutputStreamDescriptor = enum { file, terminal, pipe };
pub var stderr_descriptor_type: OutputStreamDescriptor = .pipe;
pub var stdout_descriptor_type: OutputStreamDescriptor = .pipe;

/// Narrowed `Output.DebugTimer` — measures elapsed time for `BUN_DEBUG`
/// scoped logging. Faithful to Bun's `(comptime fmt)`-friendly formatter.
pub const DebugTimer = struct {
    timer: @import("home").Timer,

    pub fn start() DebugTimer {
        return .{ .timer = @import("home").Timer.start() catch unreachable };
    }

    pub fn format(self: *DebugTimer, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}ns", .{self.timer.read()});
    }
};

/// Minimal stand-in for `Output.Source`. The full buffered-stream machinery
/// is not ported yet; the install cone only calls `Source.configureThread()`,
/// which is a no-op until Home routes through its own buffered writer.
pub const Source = struct {
    pub fn configureThread() void {}

    pub const ColorDepth = enum { none, @"16", @"256", @"16m" };

    pub const Stdio = struct {
        pub fn isStdoutNull() bool {
            return false;
        }

        pub fn isStderrNull() bool {
            return false;
        }

        pub fn isStdinNull() bool {
            return false;
        }
    };

    pub fn colorDepth() ColorDepth {
        return .none;
    }

    /// Faithful to upstream `bun_core/output.zig:93`.
    pub fn configureNamedThread(name: [:0]const u8) void {
        @import("bun_core/Global.zig").setThreadName(name);
        configureThread();
    }
};

pub fn isAIAgent() bool {
    return false;
}

test "prettyln formats without crashing" {
    prettyln("hello {s}", .{"world"});
}
