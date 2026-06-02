// Home Runtime - Phase 12.7 `node:tty` Zig substrate.
//
// Bun's JS module (`src/js/node/tty.ts`) gets its native facts from
// ProcessBindingTTYWrap.cpp. Home keeps the JS class facade parked behind the
// JSC bridge, but exposes the native core now: isatty, window size, raw mode,
// color-depth environment rules, and lightweight stream state.

const std = @import("std");
const home_rt = @import("home");
const core_tty = home_rt.tty;

pub const Mode = core_tty.Mode;
pub const WindowSize = core_tty.WindowSize;

pub const ColorDepth = enum(u8) {
    colors_2 = 1,
    colors_16 = 4,
    colors_256 = 8,
    colors_16m = 24,
};

pub const EnvEntry = struct {
    key: []const u8,
    value: []const u8,
};

pub const StreamState = struct {
    fd: c_int,
    is_tty: bool,
    is_raw: bool = false,
    columns: ?u16 = null,
    rows: ?u16 = null,
    ref: bool = true,

    pub fn init(fd: c_int) StreamState {
        const tty = isatty(fd);
        const size = if (tty) getWindowSize(fd) else null;
        return .{
            .fd = fd,
            .is_tty = tty,
            .columns = if (size) |s| s.columns else null,
            .rows = if (size) |s| s.rows else null,
        };
    }

    pub fn setRawMode(self: *StreamState, enabled: bool) c_int {
        const rc = setMode(self.fd, if (enabled) .raw else .normal);
        if (rc == 0) self.is_raw = enabled;
        return rc;
    }

    pub fn refreshSize(self: *StreamState) bool {
        const size = getWindowSize(self.fd) orelse return false;
        const changed = self.columns != size.columns or self.rows != size.rows;
        self.columns = size.columns;
        self.rows = size.rows;
        return changed;
    }
};

pub fn isatty(fd: c_int) bool {
    return core_tty.isatty(fd);
}

pub fn getWindowSize(fd: c_int) ?WindowSize {
    return core_tty.getWindowSize(fd);
}

pub fn setMode(fd: c_int, mode: Mode) c_int {
    return core_tty.setMode(fd, mode);
}

pub fn getColorDepth(env: []const EnvEntry) ColorDepth {
    if (getEnv(env, "FORCE_COLOR")) |force_color| {
        if (force_color.len == 0 or std.mem.eql(u8, force_color, "1") or std.mem.eql(u8, force_color, "true")) {
            return .colors_16;
        }
        if (std.mem.eql(u8, force_color, "2")) return .colors_256;
        if (std.mem.eql(u8, force_color, "3")) return .colors_16m;
        return .colors_2;
    }

    if (hasEnv(env, "NODE_DISABLE_COLORS") or hasEnv(env, "NO_COLOR")) return .colors_2;
    if (getEnv(env, "TERM")) |term| {
        if (std.mem.eql(u8, term, "dumb")) return .colors_2;
    }

    if (hasEnv(env, "TMUX")) return .colors_256;

    if (hasEnv(env, "CI")) {
        const known_ci = [_][]const u8{
            "APPVEYOR",
            "BUILDKITE",
            "CIRCLECI",
            "DRONE",
            "GITHUB_ACTIONS",
            "GITLAB_CI",
            "TRAVIS",
        };
        for (known_ci) |key| {
            if (hasEnv(env, key)) return .colors_256;
        }
        if (getEnv(env, "CI_NAME")) |name| {
            if (std.mem.eql(u8, name, "codeship")) return .colors_256;
        }
        return .colors_2;
    }

    if (getEnv(env, "TEAMCITY_VERSION")) |version| {
        return if (teamCitySupportsColor(version)) .colors_16 else .colors_2;
    }

    if (getEnv(env, "TERM_PROGRAM")) |program| {
        if (std.mem.eql(u8, program, "iTerm.app")) {
            if (getEnv(env, "TERM_PROGRAM_VERSION")) |version| {
                if (version.len >= 2 and version[1] == '.' and version[0] >= '0' and version[0] <= '2') return .colors_256;
            } else {
                return .colors_256;
            }
            return .colors_16m;
        }
        if (std.mem.eql(u8, program, "HyperTerm") or
            std.mem.eql(u8, program, "ghostty") or
            std.mem.eql(u8, program, "WezTerm") or
            std.mem.eql(u8, program, "MacTerm"))
        {
            return .colors_16m;
        }
        if (std.mem.eql(u8, program, "Apple_Terminal")) return .colors_256;
    }

    if (getEnv(env, "COLORTERM")) |color_term| {
        if (std.mem.eql(u8, color_term, "truecolor") or std.mem.eql(u8, color_term, "24bit")) return .colors_16m;
    }

    if (getEnv(env, "TERM")) |term| {
        if (std.mem.startsWith(u8, term, "xterm-256")) return .colors_256;

        var lower_buf: [128]u8 = undefined;
        const lower = lowerAscii(&lower_buf, term);
        if (termEnvColorDepth(lower)) |depth| return depth;
        if (termMatches16Color(lower)) return .colors_16;
    }

    if (hasEnv(env, "COLORTERM")) return .colors_16;
    return .colors_2;
}

pub fn hasColors(count: u32, env: []const EnvEntry) bool {
    const depth = @intFromEnum(getColorDepth(env));
    return count <= (@as(u32, 1) << @intCast(depth));
}

fn getEnv(env: []const EnvEntry, key: []const u8) ?[]const u8 {
    for (env) |entry| {
        if (std.mem.eql(u8, entry.key, key)) return entry.value;
    }
    return null;
}

fn hasEnv(env: []const EnvEntry, key: []const u8) bool {
    return getEnv(env, key) != null;
}

fn lowerAscii(buffer: *[128]u8, input: []const u8) []const u8 {
    const len = @min(buffer.len, input.len);
    for (input[0..len], 0..) |byte, index| {
        buffer[index] = std.ascii.toLower(byte);
    }
    return buffer[0..len];
}

fn teamCitySupportsColor(version: []const u8) bool {
    if (std.mem.startsWith(u8, version, "9.")) {
        if (version.len < 3) return false;
        return version[2] != '0';
    }
    const dot = std.mem.indexOfScalar(u8, version, '.') orelse version.len;
    const major = std.fmt.parseInt(u32, version[0..dot], 10) catch return false;
    return major >= 10;
}

fn termEnvColorDepth(term: []const u8) ?ColorDepth {
    const known = [_]struct { []const u8, ColorDepth }{
        .{ "eterm", .colors_16 },
        .{ "cons25", .colors_16 },
        .{ "console", .colors_16 },
        .{ "cygwin", .colors_16 },
        .{ "dtterm", .colors_16 },
        .{ "gnome", .colors_16 },
        .{ "hurd", .colors_16 },
        .{ "jfbterm", .colors_16 },
        .{ "konsole", .colors_16 },
        .{ "kterm", .colors_16 },
        .{ "mlterm", .colors_16 },
        .{ "mosh", .colors_16m },
        .{ "putty", .colors_16 },
        .{ "st", .colors_16 },
        .{ "rxvt-unicode-24bit", .colors_16m },
        .{ "terminator", .colors_16m },
    };
    for (known) |entry| {
        if (std.mem.eql(u8, term, entry[0])) return entry[1];
    }
    return null;
}

fn termMatches16Color(term: []const u8) bool {
    if (std.mem.indexOf(u8, term, "ansi") != null) return true;
    if (std.mem.indexOf(u8, term, "color") != null) return true;
    if (std.mem.indexOf(u8, term, "linux") != null) return true;
    if (std.mem.startsWith(u8, term, "rxvt")) return true;
    if (std.mem.startsWith(u8, term, "screen")) return true;
    if (std.mem.startsWith(u8, term, "xterm")) return true;
    if (std.mem.startsWith(u8, term, "vt100")) return true;
    if (std.mem.startsWith(u8, term, "con") and std.mem.indexOfScalar(u8, term, 'x') != null) return true;
    return false;
}

const testing = std.testing;

test "tty invalid fd native helpers are non-throwing" {
    try testing.expect(!isatty(-1));
    try testing.expectEqual(@as(?WindowSize, null), getWindowSize(-1));
    try testing.expect(setMode(-1, .raw) != 0);
}

test "tty stream state mirrors fd facts" {
    const state = StreamState.init(-1);
    try testing.expectEqual(@as(c_int, -1), state.fd);
    try testing.expect(!state.is_tty);
    try testing.expectEqual(@as(?u16, null), state.columns);
}

test "tty color depth env matrix" {
    try testing.expectEqual(ColorDepth.colors_16m, getColorDepth(&[_]EnvEntry{.{ .key = "FORCE_COLOR", .value = "3" }}));
    try testing.expectEqual(ColorDepth.colors_2, getColorDepth(&[_]EnvEntry{.{ .key = "NO_COLOR", .value = "1" }}));
    try testing.expectEqual(ColorDepth.colors_2, getColorDepth(&[_]EnvEntry{.{ .key = "TERM", .value = "dumb" }}));
    try testing.expectEqual(ColorDepth.colors_256, getColorDepth(&[_]EnvEntry{.{ .key = "TMUX", .value = "1" }}));
    try testing.expectEqual(ColorDepth.colors_256, getColorDepth(&[_]EnvEntry{
        .{ .key = "CI", .value = "1" },
        .{ .key = "GITHUB_ACTIONS", .value = "true" },
    }));
    try testing.expectEqual(ColorDepth.colors_16m, getColorDepth(&[_]EnvEntry{.{ .key = "COLORTERM", .value = "truecolor" }}));
    try testing.expectEqual(ColorDepth.colors_256, getColorDepth(&[_]EnvEntry{.{ .key = "TERM", .value = "xterm-256color" }}));
    try testing.expectEqual(ColorDepth.colors_16, getColorDepth(&[_]EnvEntry{.{ .key = "TERM", .value = "xterm" }}));
}

test "tty hasColors uses color depth bits" {
    try testing.expect(hasColors(256, &[_]EnvEntry{.{ .key = "FORCE_COLOR", .value = "2" }}));
    try testing.expect(!hasColors(257, &[_]EnvEntry{.{ .key = "FORCE_COLOR", .value = "2" }}));
}
