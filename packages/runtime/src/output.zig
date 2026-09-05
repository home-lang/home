// Home Runtime — terminal output helpers.
//
// Minimal initial surface that the copied Bun cli leaves rely on:
// pretty-print + flush + error/warning shortcuts. The upstream Bun
// `Output` namespace is enormous; we land coverage as each copied
// file needs more.

const std = @import("std");
const builtin = @import("builtin");
const core_output = @import("bun_core/output.zig");

pub const LogFunction = core_output.LogFunction;
pub const Visibility = core_output.Visibility;
pub const Scoped = core_output.Scoped;
pub const scoped = core_output.scoped;
pub const synchronized_start = core_output.synchronized_start;
pub const synchronized_end = core_output.synchronized_end;
pub const disableScopedDebugWriter = core_output.disableScopedDebugWriter;
pub const enableScopedDebugWriter = core_output.enableScopedDebugWriter;

pub var enable_ansi_colors_stderr = false;
pub var enable_ansi_colors_stdout = false;
pub var is_github_action = false;
pub const ElapsedFormatter = @import("bun_core/output.zig").ElapsedFormatter;
pub const buffered_stdin = &@import("bun_core/output.zig").buffered_stdin;

const CSI = "\x1b[";
// Match Bun's per-thread streams: writer()/errorWriter() write directly,
// while print/pretty helpers select the buffered stream inside a buffering
// scope. Coverage tables and diagnostic printers use the direct writers.
threadlocal var error_writer_buffer: [4096]u8 = undefined;
threadlocal var error_file_writer: ?std.Io.File.Writer = null;
threadlocal var raw_error_file_writer: ?std.Io.File.Writer = null;
threadlocal var stdout_writer_buffer: [4096]u8 = undefined;
threadlocal var stdout_file_writer: ?std.Io.File.Writer = null;
threadlocal var raw_stdout_file_writer: ?std.Io.File.Writer = null;
pub var enable_buffering = true;
threadlocal var core_output_configured = false;

fn colorEnabled(force: ?bool, no_color: bool, is_tty: bool) bool {
    if (force) |enabled| return enabled;
    if (no_color) return false;
    return is_tty;
}

/// Initialize Home's output facade with Bun's FORCE_COLOR/NO_COLOR and TTY
/// precedence. Copied runtime code reads these facade variables directly, so
/// they must be configured before the CLI creates a VM.
pub fn configure() void {
    if (!core_output_configured) {
        const File = @import("home").sys.File;
        core_output.Source.setInit(
            File.from(@import("home").FD.stdout()),
            File.from(@import("home").FD.stderr()),
        );
        if (comptime @import("home").Environment.enable_logs) {
            core_output.initScopedDebugWriterAtStartup();
        }
        core_output_configured = true;
    }

    const forced: ?bool = if (core_output.Source.getForceColorDepth()) |depth| depth != .none else null;
    const no_color = core_output.Source.isNoColor();
    const stdin_tty = if (builtin.os.tag == .windows)
        core_output.bun_stdio_tty[0] != 0
    else
        @import("core/tty.zig").isatty(0);
    const stdout_tty = if (builtin.os.tag == .windows)
        core_output.bun_stdio_tty[1] != 0
    else
        @import("core/tty.zig").isatty(1);
    const stderr_tty = if (builtin.os.tag == .windows)
        core_output.bun_stdio_tty[2] != 0
    else
        @import("core/tty.zig").isatty(2);

    enable_ansi_colors_stdout = colorEnabled(forced, no_color, stdout_tty);
    enable_ansi_colors_stderr = colorEnabled(forced, no_color, stderr_tty);
    stdout_descriptor_type = if (stdout_tty) .terminal else .pipe;
    stderr_descriptor_type = if (stderr_tty) .terminal else .pipe;
    stdin_is_tty = stdin_tty;
}

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
    stdoutDestination().print(fmt, args) catch {};
}

pub fn println(comptime fmt: []const u8, args: anytype) void {
    const line = if (fmt.len == 0 or fmt[fmt.len - 1] != '\n') fmt ++ "\n" else fmt;
    print(line, args);
}

pub fn prettyln(comptime fmt: []const u8, args: anytype) void {
    // Expand Bun's `<r>`/`<red>`/etc. markup through prettyFmt — emitting ANSI
    // when stdout colors are enabled, stripping the tags otherwise. Mirrors
    // upstream `bun_core/output.zig` prettyWithPrinter; without this the literal
    // `<green>`-style tags leak into output (e.g. the test runner summary).
    const line = if (fmt.len == 0 or fmt[fmt.len - 1] != '\n') fmt ++ "\n" else fmt;
    if (enable_ansi_colors_stdout) {
        print(comptime prettyFmt(line, true), args);
    } else {
        print(comptime prettyFmt(line, false), args);
    }
}

pub fn prettyErrorln(comptime fmt: []const u8, args: anytype) void {
    const line = if (fmt.len == 0 or fmt[fmt.len - 1] != '\n') fmt ++ "\n" else fmt;
    if (enable_ansi_colors_stderr) {
        printError(comptime prettyFmt(line, true), args);
    } else {
        printError(comptime prettyFmt(line, false), args);
    }
}

pub fn printError(comptime fmt: []const u8, args: anytype) void {
    stderrDestination().print(fmt, args) catch {};
}

pub fn printErrorln(comptime fmt: []const u8, args: anytype) void {
    const line = if (fmt.len == 0 or fmt[fmt.len - 1] != '\n') fmt ++ "\n" else fmt;
    printError(line, args);
}

pub fn printElapsed(elapsed_ms: f64) void {
    printError("[{d:.2}ms]", .{elapsed_ms});
}

pub fn printElapsedStdoutTrim(elapsed_ms: f64) void {
    switch (@as(i64, @intFromFloat(@round(elapsed_ms)))) {
        0...1500 => pretty("<r><d>[<b>{d:>}ms<r><d>]<r>", .{elapsed_ms}),
        else => pretty("<r><d>[<b>{d:>}s<r><d>]<r>", .{elapsed_ms / 1000.0}),
    }
}

pub fn isGithubAction() bool {
    return @import("bun_core/env_var.zig").GITHUB_ACTIONS.get() and !isAIAgent();
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
    // Flush this thread's buffered stdout/stderr. Direct writers have no
    // pending bytes; CLI helpers retain output until their scope flushes.
    if (stdout_file_writer) |*w| w.interface.flush() catch {};
    if (error_file_writer) |*w| w.interface.flush() catch {};
}

pub fn resetTerminal() void {}

/// Faithful to upstream `Output.initTest`: enables ANSI color detection for
/// test runs so prettyfmt paths exercise the colored branch. Safe to call
/// repeatedly (idempotent).
pub fn initTest() void {
    configure();
}

pub fn errorWriter() *std.Io.Writer {
    if (raw_error_file_writer == null) {
        raw_error_file_writer = std.Io.File.Writer.initStreaming(.stderr(), debugIo(), &.{});
    }
    return &raw_error_file_writer.?.interface;
}

pub fn errorWriterBuffered() *std.Io.Writer {
    if (error_file_writer == null) {
        error_file_writer = std.Io.File.Writer.initStreaming(.stderr(), debugIo(), &error_writer_buffer);
    }
    return &error_file_writer.?.interface;
}

/// Stub for `bun.Output.panic`. Mirrors `std.debug.panic` until Home's
/// crash handler is brought online.
pub fn panic(comptime fmt: []const u8, args: anytype) noreturn {
    @import("home").crash_handler.beginPanic();
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

pub inline fn errFmt(formatter: anytype) void {
    return errGeneric("{f}", .{formatter});
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    prettyErrorln("warn: " ++ fmt, args);
}

pub fn note(comptime fmt: []const u8, args: anytype) void {
    prettyErrorln("note: " ++ fmt, args);
}

pub fn pretty(comptime fmt: []const u8, args: anytype) void {
    if (enable_ansi_colors_stdout) {
        print(comptime prettyFmt(fmt, true), args);
    } else {
        print(comptime prettyFmt(fmt, false), args);
    }
}

pub fn prettyError(comptime fmt: []const u8, args: anytype) void {
    if (enable_ansi_colors_stderr) {
        printError(comptime prettyFmt(fmt, true), args);
    } else {
        printError(comptime prettyFmt(fmt, false), args);
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
    print("[{d:.2}ms]", .{elapsed_ms});
}

pub fn printStartEnd(start: i128, end: i128) void {
    const elapsed_ms: f64 = @as(f64, @floatFromInt(end - start)) / std.time.ns_per_ms;
    printElapsed(elapsed_ms);
}

pub fn enableBuffering() void {
    enable_buffering = true;
}
pub fn resetTerminalAll() void {}
pub fn enableBufferingScope() BufferingScope {
    const previous = enable_buffering;
    enableBuffering();
    return .{ .previous = previous };
}

pub const BufferingScope = struct {
    previous: bool,

    pub fn deinit(this: BufferingScope) void {
        enable_buffering = this.previous;
    }
};

pub fn disableBuffering() void {
    flush();
    enable_buffering = false;
}

pub fn writer() *std.Io.Writer {
    if (raw_stdout_file_writer == null) {
        raw_stdout_file_writer = std.Io.File.Writer.initStreaming(.stdout(), debugIo(), &.{});
    }
    return &raw_stdout_file_writer.?.interface;
}

pub fn writerBuffered() *std.Io.Writer {
    if (stdout_file_writer == null) {
        stdout_file_writer = std.Io.File.Writer.initStreaming(.stdout(), debugIo(), &stdout_writer_buffer);
    }
    return &stdout_file_writer.?.interface;
}

fn stdoutDestination() *std.Io.Writer {
    return if (enable_buffering) writerBuffered() else writer();
}

fn stderrDestination() *std.Io.Writer {
    return if (enable_buffering) errorWriterBuffered() else errorWriter();
}

pub fn rawWriter() *std.Io.Writer {
    return writer();
}

pub fn rawErrorWriter() *std.Io.Writer {
    return errorWriter();
}

var stdin_is_tty = false;

pub fn isStdinTTY() bool {
    return stdin_is_tty;
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

    pub fn format(self: *const DebugTimer, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}ns", .{self.timer.read()});
    }
};

/// Home owns its output writers separately from Bun's `Output.Source`, but
/// thread configuration must retain Bun's non-output side effects. In
/// particular, recursive parsers read the WTF stack bounds initialized here.
pub const Source = struct {
    threadlocal var configured = false;

    pub fn configureThread() void {
        if (configured) return;
        configured = true;
        core_output.Source.configureThread();
        @import("home").StackCheck.configureThread();
    }

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

test "color precedence honors FORCE_COLOR before NO_COLOR and TTY state" {
    try std.testing.expect(colorEnabled(true, true, false));
    try std.testing.expect(!colorEnabled(false, false, true));
    try std.testing.expect(!colorEnabled(null, true, true));
    try std.testing.expect(colorEnabled(null, false, true));
    try std.testing.expect(!colorEnabled(null, false, false));
}
