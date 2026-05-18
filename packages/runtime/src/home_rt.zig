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
    pub const CommonAbortReason = @import("jsc/CommonAbortReason.zig").CommonAbortReason;
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
    pub const Signals = @import("http/Signals.zig");
    pub const H2FrameParser = @import("http/H2FrameParser.zig");
};
pub const http_types = struct {
    pub const Encoding = @import("http_types/Encoding.zig").Encoding;
    pub const Method = @import("http_types/Method.zig").Method;
    pub const FetchRedirect = @import("http_types/FetchRedirect.zig").FetchRedirect;
    pub const FetchRequestMode = @import("http_types/FetchRequestMode.zig").FetchRequestMode;
    pub const FetchCacheMode = @import("http_types/FetchCacheMode.zig").FetchCacheMode;
    pub const mime_type_list_enum = @import("http_types/mime_type_list_enum.zig");
};
pub const options_types = struct {
    pub const OfflineMode = @import("options_types/OfflineMode.zig").OfflineMode;
    pub const OfflineModePrefer = @import("options_types/OfflineMode.zig").Prefer;
    // Third-wave port batch (2026-05-17):
    pub const CodeCoverageOptions = @import("options_types/CodeCoverageOptions.zig").CodeCoverageOptions;
    pub const CodeCoverageReporter = @import("options_types/CodeCoverageOptions.zig").Reporter;
    pub const CodeCoverageReporters = @import("options_types/CodeCoverageOptions.zig").Reporters;
    pub const CodeCoverageFraction = @import("options_types/CodeCoverageOptions.zig").Fraction;
};

// ---- src/meta/ ---------------------------------------------------------
// Type-classifier + bitfield helpers. Pure leaves (no `home_rt` deps).
pub const meta = struct {
    pub const bits = @import("meta/bits.zig");
    pub const traits = @import("meta/traits.zig");
};

// ---- src/crash_handler/ ------------------------------------------------
// Out-of-memory + crash reporting. Only the OOM wrapper is ported today;
// the full crash handler (stack walking, JSC stop-the-world, native
// signal handlers) re-lands in a later sub-phase.
pub const crash_handler = struct {
    pub const handle_oom = @import("crash_handler/handle_oom.zig");
};

// ---- src/bun_core/ -----------------------------------------------------
// Additional Tier-0 helpers — pure-Zig utilities the rest of the runtime
// leans on. (result.zig + tty.zig already wired below.)
pub const ExactSizeMatcher = @import("bun_core/string/immutable/exact_size_matcher.zig").ExactSizeMatcher;
pub const BoundedArray = @import("bun_core/bounded_array.zig").BoundedArray;
pub const BoundedArrayAligned = @import("bun_core/bounded_array.zig").BoundedArrayAligned;

// ---- src/install_types/ ------------------------------------------------
// Package manager type vocabulary. The full `install/PackageManager.zig`
// runtime is the Phase 12.9 destination; these split-out types are pure
// data and land first so other subsystems can name them.
pub const install_types = struct {
    pub const NodeLinker = @import("install_types/NodeLinker.zig").NodeLinker;
};

// ---- src/uws_sys/ ------------------------------------------------------
// Opaque bindings to the `us_*` C ABI in `packages/bun-usockets`.
// Currently only the QUIC opaques; the TCP/UDP/HTTP/3 + WebSocket
// surface lands as the broader uws subtree is ported.
pub const uws_sys = struct {
    pub const quic = struct {
        pub const Socket = @import("uws_sys/quic/Socket.zig").Socket;
        pub const PendingConnect = @import("uws_sys/quic/PendingConnect.zig").PendingConnect;
        pub const Stream = @import("uws_sys/quic/Stream.zig").Stream;
        pub const Header = @import("uws_sys/quic/Header.zig").Header;
        pub const Qpack = @import("uws_sys/quic/Header.zig").Qpack;
    };
};

// ---- src/event_loop/ ---------------------------------------------------
// Bun's event-loop substrate. Most files in this directory pull in
// `bun.jsc.*` / `bun.JSError` / `bun.Async` (not yet exported), so only
// the leaves that depend exclusively on `default_allocator` + `handleOom`
// can be copied today.
pub const event_loop = struct {
    pub const DeferredTaskQueue = @import("event_loop/DeferredTaskQueue.zig");
};

// ---- src/unicode/ ------------------------------------------------------
// Unicode property tables + a pure-std 3-level LUT generator. Mirrors
// Bun's `src/unicode/uucode/` (application-facing wrapper) and
// `src/unicode/uucode_lib/` (vendored zigster/uucode library). Only
// Tier-0 leaves are present today — the full grapheme-break + width
// tables land alongside Phase 12.5.
pub const unicode = struct {
    pub const uucode = struct {
        pub const lut = @import("unicode/uucode/lut.zig");
    };
    pub const uucode_lib = struct {
        pub const ascii = @import("unicode/uucode_lib/src/ascii.zig");
        pub const utf8 = @import("unicode/uucode_lib/src/utf8.zig");
        pub const x = struct {
            pub const types = @import("unicode/uucode_lib/src/x/types.x.zig");
            pub const types_x = struct {
                pub const grapheme = @import("unicode/uucode_lib/src/x/types_x/grapheme.zig");
            };
        };
    };
};

// ---- src/runtime/ ------------------------------------------------------
// Bun's `src/runtime/` subtree. Directory shape mirrors upstream;
// individual files are flat copies as their bun.X deps allow.
pub const runtime = struct {
    pub const image = struct {
        pub const exif = @import("runtime/image/exif.zig");
    };
    pub const server = struct {
        pub const HTTPStatusText = @import("runtime/server/HTTPStatusText.zig");
    };
    pub const webcore = struct {
        pub const s3 = struct {
            pub const multipart_options = @import("runtime/webcore/s3/multipart_options.zig");
        };
    };
    pub const valkey = struct {
        // Per-VM Valkey state. JSC-bridge dispatch omitted — re-lands in Phase 12.2.
        pub const Context = @import("runtime/valkey_jsc/ValkeyContext.zig");
    };
};

// ---- src/node/ ---------------------------------------------------------
// Node.js compatibility shims. Sourced from bun/src/runtime/node/ — bun
// never grew a top-level src/node/, so this Home subtree is the namespace
// home for everything in the upstream node/ directory.
pub const node = struct {
    pub const error_code = @import("node/nodejs_error_code.zig");
    // node.assert.myers_diff is parked: upstream uses Zig-0.17+
    // `std.array_list.Managed(...)` and `std.heap.stackFallback`,
    // both of which moved in 0.17. Re-attach once an adapter lands.
};

// ---- src/bun_core/ + src/bun_alloc/ + src/safety/ ----------------------
// Result type, tty mode, c_allocator, thread-id sentinel. Pure-Zig
// utilities the rest of the runtime leans on.
pub const Result = @import("bun_core/result.zig").Result;
pub const tty = @import("bun_core/tty.zig");
pub const c_allocator = @import("bun_alloc/fallback.zig").c_allocator;
pub const z_allocator = @import("bun_alloc/fallback.zig").z_allocator;
pub const freeWithoutSize = @import("bun_alloc/fallback.zig").freeWithoutSize;
// Sub-namespace for the zero-init allocator. Re-exports the canonical
// `z_allocator` above plus the internal helpers needed by callers that
// want to spell `home_rt.bun_alloc.fallback.z.alloc(...)` like upstream.
pub const bun_alloc = struct {
    pub const fallback = struct {
        pub const z = @import("bun_alloc/fallback/z.zig");
    };
};
pub const io_heap = @import("io/heap.zig");
pub const perf = struct {
    // Zig 0.17 compat: perf/system_timer.zig depends on `std.time.Timer`,
    // which 0.17.0-dev.263 removed. Parked until a thin `std.Io.Clock`
    // adapter lands.
    pub const generated_perf_trace_events = @import("perf/generated_perf_trace_events.zig");
};
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
        pub const SQLQueryResultMode = @import("sql/shared/SQLQueryResultMode.zig").SQLQueryResultMode;
    };
    pub const mysql = struct {
        pub const SSLMode = @import("sql/mysql/SSLMode.zig").SSLMode;
        pub const ConnectionState = @import("sql/mysql/ConnectionState.zig").ConnectionState;
        pub const TLSStatus = @import("sql/mysql/TLSStatus.zig").TLSStatus;
        pub const QueryStatus = @import("sql/mysql/QueryStatus.zig").Status;
        pub const MySQLQueryResult = @import("sql/mysql/MySQLQueryResult.zig");
        pub const MySQLTypes = @import("sql/mysql/MySQLTypes.zig");
        pub const protocol = struct {
            pub const PacketType = @import("sql/mysql/protocol/PacketType.zig").PacketType;
            pub const PacketHeader = @import("sql/mysql/protocol/PacketHeader.zig");
        };
    };
    pub const postgres = struct {
        pub const SSLMode = @import("sql/postgres/SSLMode.zig").SSLMode;
        pub const Status = @import("sql/postgres/Status.zig").Status;
        pub const TLSStatus = @import("sql/postgres/TLSStatus.zig").TLSStatus;
        pub const AnyPostgresError = @import("sql/postgres/AnyPostgresError.zig").AnyPostgresError;
        pub const PostgresErrorOptions = @import("sql/postgres/AnyPostgresError.zig").PostgresErrorOptions;
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
    _ = options_types;
    _ = install_types;
    _ = uws_sys;
    _ = event_loop;
    _ = unicode;
    _ = runtime;
    _ = node;
    _ = meta;
    _ = crash_handler;
    // Pull nested module tests through their actual file imports so
    // the home_rt test runner exercises every copied leaf.
    _ = @import("event_loop/DeferredTaskQueue.zig");
    _ = @import("unicode/uucode/lut.zig");
    _ = @import("unicode/uucode_lib/src/ascii.zig");
    _ = @import("unicode/uucode_lib/src/utf8.zig");
    _ = @import("unicode/uucode_lib/src/x/types.x.zig");
    _ = @import("unicode/uucode_lib/src/x/types_x/grapheme.zig");
    _ = @import("runtime/image/exif.zig");
    _ = @import("runtime/server/HTTPStatusText.zig");
    _ = @import("runtime/webcore/s3/multipart_options.zig");
    _ = @import("runtime/valkey_jsc/ValkeyContext.zig");
    _ = @import("node/nodejs_error_code.zig");
    // myers_diff parked on Zig 0.17 compat.
    _ = @import("uws_sys/quic/Header.zig");
    _ = @import("sql/mysql/protocol/PacketHeader.zig");
    // Second-wave port batch (2026-05-17, agent A–H follow-up):
    _ = @import("bun_alloc/fallback/z.zig");
    _ = @import("http/H2FrameParser.zig");
    _ = @import("http/Signals.zig");
    _ = @import("http_types/mime_type_list_enum.zig");
    _ = @import("io/heap.zig");
    _ = @import("perf/generated_perf_trace_events.zig");
    _ = @import("sql/mysql/MySQLTypes.zig");
    // Third-wave port batch (2026-05-17, parallel-agent integration):
    _ = @import("bun_core/string/immutable/exact_size_matcher.zig");
    _ = @import("bun_core/bounded_array.zig");
    _ = @import("meta/bits.zig");
    _ = @import("meta/traits.zig");
    _ = @import("crash_handler/handle_oom.zig");
    _ = @import("options_types/CodeCoverageOptions.zig");
}

test "home_rt.install_types.NodeLinker.fromStr maps canonical strings" {
    try std.testing.expectEqual(install_types.NodeLinker.hoisted, install_types.NodeLinker.fromStr("hoisted").?);
    try std.testing.expectEqual(install_types.NodeLinker.isolated, install_types.NodeLinker.fromStr("isolated").?);
    try std.testing.expect(install_types.NodeLinker.fromStr("nope") == null);
}

test "home_rt.uws_sys.quic exposes the QUIC opaques" {
    _ = uws_sys.quic.Socket;
    _ = uws_sys.quic.PendingConnect;
}

test "home_rt.http_types.Method.find round-trips canonical verbs" {
    try std.testing.expectEqual(http_types.Method.GET, http_types.Method.find("GET").?);
    try std.testing.expectEqual(http_types.Method.POST, http_types.Method.find("post").?);
    try std.testing.expectEqual(http_types.Method.PATCH, http_types.Method.find("PATCH").?);
    try std.testing.expect(http_types.Method.find("INVALID") == null);
}

test "home_rt.http_types.Method.isIdempotent" {
    try std.testing.expect(http_types.Method.GET.isIdempotent());
    try std.testing.expect(http_types.Method.PUT.isIdempotent());
    try std.testing.expect(!http_types.Method.POST.isIdempotent());
    try std.testing.expect(!http_types.Method.PATCH.isIdempotent());
}

test "home_rt.http_types.FetchRedirect.Map maps strings to enum tags" {
    try std.testing.expectEqual(http_types.FetchRedirect.follow, http_types.FetchRedirect.Map.get("follow").?);
    try std.testing.expectEqual(http_types.FetchRedirect.@"error", http_types.FetchRedirect.Map.get("error").?);
}

test "home_rt.options_types.OfflineMode.Prefer maps strings to enum tags" {
    try std.testing.expectEqual(options_types.OfflineMode.offline, options_types.OfflineModePrefer.get("offline").?);
    try std.testing.expectEqual(options_types.OfflineMode.latest, options_types.OfflineModePrefer.get("latest").?);
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
