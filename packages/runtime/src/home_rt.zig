// Home Runtime aggregator.
//
// This module is the single import surface used by every other Home Runtime
// subsystem. Copied-from-Bun source files have their `@import("bun")` calls
// rewritten to `@import("home_rt")` at copy time, so this aggregator is the
// canonical replacement for Bun's `bun.zig` namespace inside Home.
//
// Each sub-phase appends its public surface here as the matching directory
// under `src/` is populated. Phase 12 status + per-file porting tables live
// in the subdirectory `PORTING_STATUS.md` files.

const std = @import("std");

pub const upstream_sha = "fd0b6f1a271fca0b8124b69f230b100f4d636af6";

// ---- Foundational primitives ------------------------------------------
// These are Home-original implementations of the small Bun stdlib subset
// that copied source needs to compile. Each function mirrors the
// upstream semantics — see file-level docs for divergences.
pub const strings = @import("strings.zig");
pub const Output = @import("output.zig");
pub const Global = @import("global.zig");
pub const Environment = @import("environment.zig");
pub const fmt = @import("fmt.zig");
pub const path = @import("path.zig");
pub const env_var = @import("env_var.zig");

// Re-exports so copied source can spell `home_rt.assert(...)` /
// `home_rt.OOM` etc. directly (mirrors Bun's flat `bun.assert` /
// `bun.OOM` namespace).
pub const assert = Global.assert;
pub const OOM = Global.OOM;
pub const handleOom = Global.handleOom;
pub const default_allocator: std.mem.Allocator = std.heap.smp_allocator;

// Comptime string map (copied from Bun, JSC methods stripped — they'll
// be re-added under src/jsc/ once Phase 12.2 lands).
const comptime_string_map = @import("collections/comptime_string_map.zig");
pub const ComptimeStringMap = comptime_string_map.ComptimeStringMap;
pub const ComptimeStringMap16 = comptime_string_map.ComptimeStringMap16;
pub const ComptimeStringMapWithKeyType = comptime_string_map.ComptimeStringMapWithKeyType;

const identity_context = @import("collections/identity_context.zig");
pub const IdentityContext = identity_context.IdentityContext;
pub const ArrayIdentityContext = identity_context.ArrayIdentityContext;

// ---- src/cli/ ----------------------------------------------------------
// Bun's CLI surface. Copy-in-progress; see src/cli/PORTING_STATUS.md.
pub const cli = struct {
    pub const which_npm_client = @import("cli/which_npm_client.zig");
    pub const yarn_commands = @import("cli/list-of-yarn-commands.zig");
};

// ---- src/jsc/ ----------------------------------------------------------
// JSC binding surface. Most of this is opaque types + enums until the
// JSC engine is brought up (Phase 12.2). The leaves we copy now establish
// the public-facing namespace so callers can spell things correctly.
pub const jsc = struct {
    pub const JSPromiseRejectionOperation = @import("jsc/JSPromiseRejectionOperation.zig").JSPromiseRejectionOperation;
    pub const ScriptExecutionStatus = @import("jsc/ScriptExecutionStatus.zig").ScriptExecutionStatus;
    pub const SourceType = @import("jsc/SourceType.zig").SourceType;
    pub const sizes = @import("jsc/sizes.zig");
    pub const JSRuntimeType = @import("jsc/JSRuntimeType.zig").JSRuntimeType;
    pub const GetterSetter = @import("jsc/GetterSetter.zig").GetterSetter;
    pub const StaticExport = @import("jsc/static_export.zig");
    pub const ErrorCode = @import("jsc/ErrorCode.zig").ErrorCode;
};

// ---- src/io/ -----------------------------------------------------------
// Event loop + file poll opaques. The Loop / KeepAlive / FilePoll names
// are kept so callers can spell their function signatures; full impls
// land in Phase 12.3.
pub const io = struct {
    pub const Loop = @import("io/stub_event_loop.zig").Loop;
    pub const KeepAlive = @import("io/stub_event_loop.zig").KeepAlive;
    pub const FilePoll = @import("io/stub_event_loop.zig").FilePoll;
};

// ---- src/http/ + src/http_types/ ---------------------------------------
// HTTP value types (encoding tags, cert structs, header parsing). Pure
// data; no JSC dependency. The full HTTP stack lands in Phase 12.5.
pub const http = struct {
    pub const HTTPCertError = @import("http/HTTPCertError.zig");
    pub const InitError = @import("http/InitError.zig").InitError;
    pub const CertificateInfo = @import("http/CertificateInfo.zig");
    pub const HeaderValueIterator = @import("http/HeaderValueIterator.zig");
};
pub const http_types = struct {
    pub const Encoding = @import("http_types/Encoding.zig").Encoding;
};

// ---- src/bun_core/ + src/bun_alloc/ + src/safety/ ----------------------
// Result type, tty mode, c_allocator, thread-id sentinel. Pure-Zig
// utilities the rest of the runtime leans on.
pub const Result = @import("bun_core/result.zig").Result;
pub const tty = @import("bun_core/tty.zig");
pub const c_allocator = @import("bun_alloc/fallback.zig").c_allocator;
pub const z_allocator = @import("bun_alloc/fallback.zig").z_allocator;
pub const freeWithoutSize = @import("bun_alloc/fallback.zig").freeWithoutSize;
pub const safety = struct {
    pub const thread_id = @import("safety/thread_id.zig");
};

// ---- src/jsc_stub.zig --------------------------------------------------
// WASM-target opaque stubs. Mirrors Bun's `jsc_stub` namespace exactly.
pub const jsc_stub = @import("jsc_stub.zig");

// ---- src/sql/ ----------------------------------------------------------
// MySQL + Postgres value types, status enums, protocol type tags. Pure
// data — the wire-protocol encoders, statement runtime, and JS surface
// land in Phase 12.5 (Web standards + Home.SQL).
pub const sql = struct {
    pub const shared = struct {
        pub const ConnectionFlags = @import("sql/shared/ConnectionFlags.zig").ConnectionFlags;
    };
    pub const mysql = struct {
        pub const SSLMode = @import("sql/mysql/SSLMode.zig").SSLMode;
        pub const ConnectionState = @import("sql/mysql/ConnectionState.zig").ConnectionState;
        pub const TLSStatus = @import("sql/mysql/TLSStatus.zig").TLSStatus;
        pub const QueryStatus = @import("sql/mysql/QueryStatus.zig").Status;
        pub const protocol = struct {
            pub const PacketType = @import("sql/mysql/protocol/PacketType.zig").PacketType;
        };
    };
    pub const postgres = struct {
        pub const SSLMode = @import("sql/postgres/SSLMode.zig").SSLMode;
        pub const Status = @import("sql/postgres/Status.zig").Status;
        pub const TLSStatus = @import("sql/postgres/TLSStatus.zig").TLSStatus;
        pub const types = struct {
            pub const int_types = @import("sql/postgres/types/int_types.zig");
        };
        pub const protocol = struct {
            pub const TransactionStatusIndicator = @import("sql/postgres/protocol/TransactionStatusIndicator.zig").TransactionStatusIndicator;
            pub const PortalOrPreparedStatement = @import("sql/postgres/protocol/PortalOrPreparedStatement.zig").PortalOrPreparedStatement;
            pub const zHelpers = @import("sql/postgres/protocol/zHelpers.zig");
        };
    };
};

test "home_rt: substrate compiles" {
    try std.testing.expectEqualStrings(
        "fd0b6f1a271fca0b8124b69f230b100f4d636af6",
        upstream_sha,
    );
}

test "home_rt: cli.which_npm_client surface is exported" {
    const NPMClient = cli.which_npm_client.NPMClient;
    const c: NPMClient = .{ .bin = "home", .tag = .home };
    try std.testing.expectEqualStrings("home", c.bin);
    try std.testing.expect(c.tag == .home);
}

test "home_rt: cli.yarn_commands recognises canonical yarn verbs" {
    try std.testing.expect(cli.yarn_commands.all_yarn_commands.has("install"));
    try std.testing.expect(cli.yarn_commands.all_yarn_commands.has("add"));
    try std.testing.expect(cli.yarn_commands.all_yarn_commands.has("remove"));
    try std.testing.expect(cli.yarn_commands.all_yarn_commands.has("workspaces"));
    try std.testing.expect(!cli.yarn_commands.all_yarn_commands.has("not-a-yarn-command"));
}

test "home_rt: Environment flags exist" {
    try std.testing.expect(Environment.isPosix != Environment.isWindows);
}

test "home_rt: strings.indexOfChar reaches the colon-list parser" {
    try std.testing.expectEqual(@as(?usize, 3), strings.indexOfChar("foo:bar", ':'));
}

test {
    // Pull nested module tests into the home_rt test runner so a single
    // `zig build test -Dfilter=home_rt` exercises the whole substrate.
    _ = strings;
    _ = Output;
    _ = Global;
    _ = Environment;
    _ = fmt;
    _ = path;
    _ = env_var;
    _ = comptime_string_map;
    _ = identity_context;
    _ = cli.which_npm_client;
    _ = cli.yarn_commands;
    _ = jsc;
    _ = io;
    _ = http;
    _ = http_types;
    _ = tty;
    _ = safety;
    _ = jsc_stub;
    _ = sql;
}

test "home_rt.sql.postgres.types.int_types.Int32 encodes big-endian" {
    const bytes = sql.postgres.types.int_types.Int32(@as(u32, 0x0a0b0c0d));
    try std.testing.expectEqualSlices(u8, &.{ 0x0a, 0x0b, 0x0c, 0x0d }, &bytes);
}

test "home_rt.sql.mysql.QueryStatus.isRunning identifies in-flight states" {
    try std.testing.expect(sql.mysql.QueryStatus.binding.isRunning());
    try std.testing.expect(sql.mysql.QueryStatus.running.isRunning());
    try std.testing.expect(sql.mysql.QueryStatus.partial_response.isRunning());
    try std.testing.expect(!sql.mysql.QueryStatus.pending.isRunning());
    try std.testing.expect(!sql.mysql.QueryStatus.success.isRunning());
}

test "home_rt.sql.postgres.protocol.zHelpers.zCount adds NUL byte" {
    try std.testing.expectEqual(@as(usize, 0), sql.postgres.protocol.zHelpers.zCount(""));
    try std.testing.expectEqual(@as(usize, 5), sql.postgres.protocol.zHelpers.zCount("home"));
}

test "home_rt.sql.postgres.protocol.PortalOrPreparedStatement tags correctly" {
    const Por = sql.postgres.protocol.PortalOrPreparedStatement;
    const p: Por = .{ .portal = "p1" };
    const ps: Por = .{ .prepared_statement = "s1" };
    try std.testing.expectEqual(@as(u8, 'P'), p.tag());
    try std.testing.expectEqual(@as(u8, 'S'), ps.tag());
    try std.testing.expectEqualStrings("p1", p.slice());
    try std.testing.expectEqualStrings("s1", ps.slice());
}

test "home_rt.jsc enums round-trip their tag values" {
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(jsc.JSPromiseRejectionOperation.Reject));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(jsc.JSPromiseRejectionOperation.Handle));
    try std.testing.expectEqual(@as(i32, 0), @intFromEnum(jsc.ScriptExecutionStatus.running));
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(jsc.SourceType.Program));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(jsc.SourceType.Module));
    try std.testing.expectEqual(@as(u16, 0x40), @intFromEnum(jsc.JSRuntimeType.String));
}

test "home_rt.jsc.sizes exposes generated layout constants" {
    try std.testing.expectEqual(@as(comptime_int, 6), jsc.sizes.Bun_FFI_PointerOffsetToArgumentsList);
    try std.testing.expectEqual(@as(comptime_int, 16), jsc.sizes.Bun_FFI_PointerOffsetToTypedArrayVector);
}

test "home_rt.jsc.ErrorCode round-trips through anyerror" {
    const err: anyerror = error.OutOfMemory;
    const code = jsc.ErrorCode.from(err);
    try std.testing.expectEqual(err, code.toError());
}

test "home_rt.io exposes the stub event-loop opaques" {
    // Only check that the names exist; full impl lands in Phase 12.3.
    _ = io.Loop;
    _ = io.KeepAlive;
    _ = io.FilePoll;
}

test "home_rt.http_types.Encoding flags compression families" {
    try std.testing.expect(http_types.Encoding.gzip.isCompressed());
    try std.testing.expect(!http_types.Encoding.identity.isCompressed());
    try std.testing.expect(http_types.Encoding.deflate.canUseLibDeflate());
}

test "home_rt.Result threads ok/err through union" {
    const R = Result(u32, []const u8);
    const ok: R = .{ .ok = 99 };
    const err: R = .{ .err = "nope" };
    try std.testing.expect(ok.asErr() == null);
    try std.testing.expectEqualStrings("nope", err.asErr().?);
}

test "home_rt.http types compose" {
    // Smoke test — the namespace re-exports compile cleanly.
    var iter = http.HeaderValueIterator.init("a, b");
    try std.testing.expectEqualStrings("a", iter.next().?);
    try std.testing.expectEqualStrings("b", iter.next().?);
}

test "home_rt.safety.thread_id.invalid is the max thread id" {
    try std.testing.expectEqual(std.math.maxInt(std.Thread.Id), safety.thread_id.invalid);
}
