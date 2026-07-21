// Home Runtime — environment variable access.
//
// Bun source reaches the environment as `bun.env_var.CI.get()` etc.
// This module exposes a small typed surface for the env vars copied
// source actually reads. Coverage expands as each copy lands.

const std = @import("std");
const Environment = @import("environment.zig");

pub const feature_flag = @import("bun_core/env_var.zig").feature_flag;

/// Returns the raw env value if set, otherwise null. POSIX-only — the
/// upstream Bun implementation uses native syscalls on Windows; until
/// Phase 12 brings that across we use `std.process.getEnvVarOwned`
/// with a process-arena.
fn rawGet(name: []const u8) ?[]const u8 {
    if (Environment.isWindows) return null; // TODO(phase-12-3): wide env on Windows
    const c = std.c;
    var buf: [256]u8 = undefined;
    if (name.len + 1 > buf.len) return null;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    const z: [*:0]const u8 = buf[0..name.len :0];
    const result = c.getenv(z) orelse return null;
    return std.mem.span(result);
}

fn StringEnv(comptime name: []const u8) type {
    return struct {
        pub fn get() ?[]const u8 {
            return rawGet(name);
        }

        pub fn getNotEmpty() ?[]const u8 {
            const raw = rawGet(name) orelse return null;
            if (raw.len == 0) return null;
            return raw;
        }
    };
}

pub const GITHUB_WORKSPACE = StringEnv("GITHUB_WORKSPACE");

fn BoolEnv(comptime name: []const u8, comptime default: bool) type {
    return struct {
        pub fn get() bool {
            const raw = rawGet(name) orelse return default;
            if (raw.len == 0) return default;
            if (std.mem.eql(u8, raw, "0")) return false;
            if (std.mem.eql(u8, raw, "false")) return false;
            return true;
        }
    };
}

pub const PATH = StringEnv("PATH");
pub const BUN_OPTIONS = StringEnv("BUN_OPTIONS");
pub const BUN_CONFIG_HTTP_IDLE_TIMEOUT = IntEnv("BUN_CONFIG_HTTP_IDLE_TIMEOUT", 0);
pub const BUN_WATCHER_TRACE = StringEnv("BUN_WATCHER_TRACE");
pub const BUN_TMPDIR = StringEnv("BUN_TMPDIR");
pub const BUN_TCC_OPTIONS = StringEnv("BUN_TCC_OPTIONS");
pub const SDKROOT = StringEnv("SDKROOT");
pub const C_INCLUDE_PATH = StringEnv("C_INCLUDE_PATH");
pub const LIBRARY_PATH = StringEnv("LIBRARY_PATH");
pub const BUN_INSTALL_GLOBAL_DIR = StringEnv("BUN_INSTALL_GLOBAL_DIR");
pub const BUN_INSTALL = StringEnv("BUN_INSTALL");
pub const NODE_CHANNEL_FD = StringEnv("NODE_CHANNEL_FD");
pub const TMPDIR = StringEnv("TMPDIR");
pub const TMP = StringEnv("TMP");

fn IntEnv(comptime name: []const u8, comptime default: u64) type {
    return struct {
        pub fn get() u64 {
            const raw = rawGet(name) orelse return default;
            return std.fmt.parseInt(u64, raw, 10) catch default;
        }
    };
}
pub const TEMP = StringEnv("TEMP");
pub const GITHUB_RUN_ID = StringEnv("GITHUB_RUN_ID");
pub const GITHUB_SERVER_URL = StringEnv("GITHUB_SERVER_URL");
pub const GITHUB_REPOSITORY = StringEnv("GITHUB_REPOSITORY");
pub const GITHUB_SHA = StringEnv("GITHUB_SHA");
pub const CI_JOB_URL = StringEnv("CI_JOB_URL");
pub const CI_COMMIT_SHA = StringEnv("CI_COMMIT_SHA");
pub const GIT_SHA = StringEnv("GIT_SHA");
pub const BUN_SSG_DISABLE_STATIC_ROUTE_VISITOR = BoolEnv("BUN_SSG_DISABLE_STATIC_ROUTE_VISITOR", false);
pub const BUN_TRACK_LAST_FN_NAME = BoolEnv("BUN_TRACK_LAST_FN_NAME", false);

pub const BUN_INSTALL_STREAMING_MIN_SIZE = struct {
    pub fn get() usize {
        const raw = rawGet("BUN_INSTALL_STREAMING_MIN_SIZE") orelse return 1024 * 1024;
        return std.fmt.parseUnsigned(usize, raw, 10) catch 1024 * 1024;
    }
};

pub const CI = struct {
    pub fn get() ?bool {
        const raw = rawGet("CI") orelse return null;
        if (raw.len == 0) return null;
        // Truthy values per Bun's upstream check: anything except 0 / false.
        if (std.mem.eql(u8, raw, "0")) return false;
        if (std.mem.eql(u8, raw, "false")) return false;
        return true;
    }
};

pub const SHELL = struct {
    pub fn get() ?[]const u8 {
        return rawGet("SHELL");
    }
};

pub const USER = struct {
    pub fn get() ?[]const u8 {
        return rawGet("USER");
    }
};

pub const HOME = struct {
    pub fn get() ?[]const u8 {
        return rawGet("HOME");
    }
};

pub const XDG_CACHE_HOME = struct {
    pub fn get() ?[]const u8 {
        return rawGet("XDG_CACHE_HOME");
    }
};

pub const XDG_CONFIG_HOME = StringEnv("XDG_CONFIG_HOME");

/// `DO_NOT_TRACK=1` (per https://consoledonottrack.com/) opts callers out
/// of any telemetry / crash-reporter wakeups. Bun reads this through
/// `bun.env_var.DO_NOT_TRACK.get()` which returns a bool — the only call
/// site (`analytics.isEnabled()`) treats *any* non-empty value as truthy,
/// matching the upstream `parseBool` behavior in `bun_core/env_var.rs`.
pub const DO_NOT_TRACK = struct {
    pub fn get() bool {
        const raw = rawGet("DO_NOT_TRACK") orelse return false;
        if (raw.len == 0) return false;
        if (std.mem.eql(u8, raw, "0")) return false;
        if (std.mem.eql(u8, raw, "false")) return false;
        return true;
    }
};

/// Hyperfine's per-iteration env-randomization offset. Bun's analytics
/// gate disables telemetry when a benchmark harness is in the loop so
/// the benchmark doesn't get a tail-latency spike from a network call.
pub const HYPERFINE_RANDOMIZED_ENVIRONMENT_OFFSET = struct {
    pub fn get() ?[]const u8 {
        return rawGet("HYPERFINE_RANDOMIZED_ENVIRONMENT_OFFSET");
    }
};

/// Bun's `DebugSocketMonitorReader` / `DebugSocketMonitorWriter` use these
/// to mirror inbound/outbound Postgres TLS reads/writes into a local file
/// (debug builds only). Added in wave-15 alongside the monitor leaf ports.
/// TODO(phase-12-N): generalise — Bun has a hand-rolled
/// `bun.env_var.BUN_<name>` namespace; we only expose the two callers need.
pub const BUN_POSTGRES_SOCKET_MONITOR_READER = struct {
    pub fn get() ?[]const u8 {
        return rawGet("BUN_POSTGRES_SOCKET_MONITOR_READER");
    }
};

pub const BUN_POSTGRES_SOCKET_MONITOR_WRITER = struct {
    pub fn get() ?[]const u8 {
        return rawGet("BUN_POSTGRES_SOCKET_MONITOR_WRITER");
    }
};

pub const BUN_DEBUG_ENABLE_RESTORE_FROM_TRANSPILER_CACHE = struct {
    pub fn get() bool {
        const raw = rawGet("BUN_DEBUG_ENABLE_RESTORE_FROM_TRANSPILER_CACHE") orelse return false;
        if (raw.len == 0) return false;
        if (std.mem.eql(u8, raw, "0")) return false;
        if (std.mem.eql(u8, raw, "false")) return false;
        return true;
    }
};

pub const BUN_DEBUG_TEST_TEXT_LOCKFILE = struct {
    pub fn get() bool {
        const raw = rawGet("BUN_DEBUG_TEST_TEXT_LOCKFILE") orelse return false;
        if (raw.len == 0) return false;
        if (std.mem.eql(u8, raw, "0")) return false;
        if (std.mem.eql(u8, raw, "false")) return false;
        return true;
    }
};

pub const BUN_DEBUG_CSS_ORDER = struct {
    pub fn get() bool {
        const raw = rawGet("BUN_DEBUG_CSS_ORDER") orelse return false;
        if (raw.len == 0) return false;
        if (std.mem.eql(u8, raw, "0")) return false;
        if (std.mem.eql(u8, raw, "false")) return false;
        return true;
    }
};

pub const BUN_INSPECT = struct {
    pub fn get() []const u8 {
        return rawGet("BUN_INSPECT") orelse "";
    }
};

pub const BUN_INSPECT_CONNECT_TO = struct {
    pub fn get() []const u8 {
        return rawGet("BUN_INSPECT_CONNECT_TO") orelse "";
    }
};

pub const BUN_RUNTIME_TRANSPILER_CACHE_PATH = struct {
    pub fn get() ?[]const u8 {
        return rawGet("BUN_RUNTIME_TRANSPILER_CACHE_PATH");
    }
};

test "CI.get reads from the environment" {
    // We can't assume any specific env value is set, so just check
    // the call doesn't crash and the result is a valid optional bool.
    const v = CI.get();
    _ = v;
}

test "SHELL.get reads from the environment" {
    const v = SHELL.get();
    _ = v;
}

test "DO_NOT_TRACK.get returns a bool" {
    const v = DO_NOT_TRACK.get();
    _ = v;
}

test "HYPERFINE_RANDOMIZED_ENVIRONMENT_OFFSET.get returns optional slice" {
    const v = HYPERFINE_RANDOMIZED_ENVIRONMENT_OFFSET.get();
    _ = v;
}
