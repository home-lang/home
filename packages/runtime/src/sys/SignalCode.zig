// Copied from bun/src/sys/SignalCode.zig at upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// POSIX signal table + helpers for shell exit-code reporting.
//
// Three upstream surfaces are trimmed:
//   * `Map = bun.ComptimeEnumMap(SignalCode)` — `ComptimeEnumMap` isn't
//     exposed via home_rt yet. Re-attaches when it ports.
//   * `Fmt`/`fmt(SignalCode, bool)` — depends on `Output.prettyFmt`, which
//     is part of the colored-output substrate. Re-attaches alongside it.
//   * `fromJS` — JSC-bridge; re-lands in Phase 12.2.

pub const SignalCode = enum(u8) {
    SIGHUP = 1,
    SIGINT = 2,
    SIGQUIT = 3,
    SIGILL = 4,
    SIGTRAP = 5,
    SIGABRT = 6,
    SIGBUS = 7,
    SIGFPE = 8,
    SIGKILL = 9,
    SIGUSR1 = 10,
    SIGSEGV = 11,
    SIGUSR2 = 12,
    SIGPIPE = 13,
    SIGALRM = 14,
    SIGTERM = 15,
    SIG16 = 16,
    SIGCHLD = 17,
    SIGCONT = 18,
    SIGSTOP = 19,
    SIGTSTP = 20,
    SIGTTIN = 21,
    SIGTTOU = 22,
    SIGURG = 23,
    SIGXCPU = 24,
    SIGXFSZ = 25,
    SIGVTALRM = 26,
    SIGPROF = 27,
    SIGWINCH = 28,
    SIGIO = 29,
    SIGPWR = 30,
    SIGSYS = 31,
    _,

    // The `subprocess.kill()` method sends a signal to the child process. If no
    // argument is given, the process will be sent the 'SIGTERM' signal.
    pub const default = SignalCode.SIGTERM;
    // stubbed: `Map = home_rt.ComptimeEnumMap(SignalCode)` re-attaches when
    // `ComptimeEnumMap` is exposed via home_rt.

    pub fn name(value: SignalCode) ?[]const u8 {
        if (@intFromEnum(value) <= @intFromEnum(SignalCode.SIGSYS)) {
            return asByteSlice(@tagName(value));
        }

        return null;
    }

    pub fn fmt(value: SignalCode, _: bool) Formatter {
        return .{ .value = value };
    }

    pub const Formatter = struct {
        value: SignalCode,

        pub fn format(this: Formatter, writer: *std.Io.Writer) !void {
            try writer.writeAll(SignalCode.name(this.value) orelse "SIGUNKNOWN");
        }
    };

    pub fn valid(value: SignalCode) bool {
        return @intFromEnum(value) <= @intFromEnum(SignalCode.SIGSYS) and @intFromEnum(value) >= @intFromEnum(SignalCode.SIGHUP);
    }

    /// Parse a `SignalCode` from a JS value (number or signal-name string),
    /// mirroring Node/Bun semantics. `value`/`globalThis` are taken as
    /// `anytype` so this stays free of a direct JSC import (the methods resolve
    /// on the JSValue/JSGlobalObject the callers pass). Previously a stub that
    /// discarded the value and always returned `default` (SIGTERM), which made
    /// `Bun.spawn({ killSignal })` and `subprocess.kill(sig)` ignore the
    /// requested signal.
    pub fn fromJS(value: anytype, globalThis: anytype) !SignalCode {
        if (value.getNumber()) |sig64| {
            // NaN → default (matches Node).
            if (std.math.isNan(sig64)) {
                return SignalCode.default;
            }
            if (std.math.isInf(sig64) or @trunc(sig64) != sig64) {
                return globalThis.throwInvalidArguments("Unknown signal", .{});
            }
            if (sig64 < 0) {
                return globalThis.throwInvalidArguments("Invalid signal: must be >= 0", .{});
            }
            if (sig64 > 31) {
                return globalThis.throwInvalidArguments("Invalid signal: must be < 32", .{});
            }
            return @enumFromInt(@as(u8, @intFromFloat(sig64)));
        } else if (value.isString()) {
            // Parse the signal NAME manually: `SignalCode.Map` (ComptimeEnumMap)
            // isn't exposed yet, so JSValue.toEnum is unavailable. Signal names
            // are short, so a stack buffer avoids needing an allocator — this
            // file must not import `bun` (that would be a circular import, since
            // bun.zig re-exports SignalCode).
            var name_buf: [256]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&name_buf);
            const sig_slice = try value.toSlice(globalThis, fba.allocator());
            const name_str = sig_slice.slice();
            if (name_str.len == 0) {
                return SignalCode.default;
            }
            return std.meta.stringToEnum(SignalCode, name_str) orelse
                globalThis.throwInvalidArguments("Unknown signal: '{s}'", .{name_str});
        } else if (!value.isEmptyOrUndefinedOrNull()) {
            return globalThis.throwInvalidArguments("Invalid signal: must be a string or an integer", .{});
        }

        return SignalCode.default;
    }

    /// Shell scripts use exit codes 128 + signal number
    /// https://tldp.org/LDP/abs/html/exitcodes.html
    pub fn toExitCode(value: SignalCode) ?u8 {
        return switch (@intFromEnum(value)) {
            1...31 => 128 +% @intFromEnum(value),
            else => null,
        };
    }

    pub fn description(signal: SignalCode) ?[]const u8 {
        // Description names copied from fish
        // https://github.com/fish-shell/fish-shell/blob/00ffc397b493f67e28f18640d3de808af29b1434/fish-rust/src/signal.rs#L420
        return switch (signal) {
            .SIGHUP => "Terminal hung up",
            .SIGINT => "Quit request",
            .SIGQUIT => "Quit request",
            .SIGILL => "Illegal instruction",
            .SIGTRAP => "Trace or breakpoint trap",
            .SIGABRT => "Abort",
            .SIGBUS => "Misaligned address error",
            .SIGFPE => "Floating point exception",
            .SIGKILL => "Forced quit",
            .SIGUSR1 => "User defined signal 1",
            .SIGUSR2 => "User defined signal 2",
            .SIGSEGV => "Address boundary error",
            .SIGPIPE => "Broken pipe",
            .SIGALRM => "Timer expired",
            .SIGTERM => "Polite quit request",
            .SIGCHLD => "Child process status changed",
            .SIGCONT => "Continue previously stopped process",
            .SIGSTOP => "Forced stop",
            .SIGTSTP => "Stop request from job control (^Z)",
            .SIGTTIN => "Stop from terminal input",
            .SIGTTOU => "Stop from terminal output",
            .SIGURG => "Urgent socket condition",
            .SIGXCPU => "CPU time limit exceeded",
            .SIGXFSZ => "File size limit exceeded",
            .SIGVTALRM => "Virtual timefr expired",
            .SIGPROF => "Profiling timer expired",
            .SIGWINCH => "Window size change",
            .SIGIO => "I/O on asynchronous file descriptor is possible",
            .SIGSYS => "Bad system call",
            .SIGPWR => "Power failure",
            else => null,
        };
    }

    pub fn from(value: anytype) SignalCode {
        return @enumFromInt(std.mem.asBytes(&value)[0]);
    }

    // stubbed: `fmt(SignalCode, bool) Fmt` re-attaches when
    // `home_rt.Output.prettyFmt` lands.
    // stubbed: `fromJS` (JSC-bridge) re-lands in Phase 12.2.
};

/// Local helper mirroring `bun.asByteSlice` — coerce a comptime/array string
/// into a runtime `[]const u8`. We inline it to keep the file leaf-portable
/// (it would otherwise need a `home_rt.asByteSlice` re-export).
fn asByteSlice(buffer: anytype) []const u8 {
    const T = @TypeOf(buffer);
    if (T == []const u8 or T == []u8) return buffer;
    return std.mem.sliceAsBytes(if (@typeInfo(T) == .pointer) buffer[0..] else &buffer);
}

const std = @import("std");

test "SignalCode.name and description round-trip for SIGTERM" {
    try std.testing.expectEqualStrings("SIGTERM", SignalCode.SIGTERM.name().?);
    try std.testing.expectEqualStrings("Polite quit request", SignalCode.SIGTERM.description().?);
}

test "SignalCode.valid rejects out-of-range values" {
    try std.testing.expect(SignalCode.SIGHUP.valid());
    try std.testing.expect(SignalCode.SIGSYS.valid());
    const beyond: SignalCode = @enumFromInt(99);
    try std.testing.expect(!beyond.valid());
    try std.testing.expect(beyond.name() == null);
}

test "SignalCode.toExitCode uses the 128 + N convention" {
    try std.testing.expectEqual(@as(?u8, 128 + 15), SignalCode.SIGTERM.toExitCode());
    try std.testing.expectEqual(@as(?u8, 128 + 9), SignalCode.SIGKILL.toExitCode());
    const beyond: SignalCode = @enumFromInt(99);
    try std.testing.expectEqual(@as(?u8, null), beyond.toExitCode());
}

test "SignalCode.default is SIGTERM" {
    try std.testing.expectEqual(SignalCode.SIGTERM, SignalCode.default);
}
