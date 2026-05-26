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
const builtin = @import("builtin");

pub const upstream_sha = "fd0b6f1a271fca0b8124b69f230b100f4d636af6";
pub const callconv_inline: std.builtin.CallingConvention = if (builtin.mode == .Debug) .auto else .@"inline";
pub const callmod_inline: std.builtin.CallModifier = if (builtin.mode == .Debug) .auto else .always_inline;

// Faithful Bun-source import surface for the Node URL/querystring/assert/util
// and Web text-encoding parity slice. This namespace points at copied Bun Zig
// modules only; it does not provide JS fallback behavior.
pub const bun_node_web_parity = @import("bun/node_url_query_assert_util_encoding.zig");
pub const bun_cli_spawn_process_fs_file = @import("bun/cli_spawn_process_fs_file.zig");

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
pub const JSError = error{ JSError, OutOfMemory, JSTerminated };
pub const JSTerminated = error{JSTerminated};
pub const JSOOM = OOM || JSError;
pub const handleOom = Global.handleOom;
pub const default_allocator: std.mem.Allocator = std.heap.smp_allocator;

pub const String = @import("string/string.zig").String;

pub inline fn copy(comptime T: type, dest: []T, src: []const T) void {
    @memcpy(dest[0..src.len], src);
}

/// Memory is typically not decommitted immediately when freed. Zero the slice
/// before returning it to the allocator, matching Bun's sensitive-free helper.
pub fn freeSensitive(allocator: std.mem.Allocator, slice: anytype) void {
    std.crypto.secureZero(std.meta.Child(@TypeOf(slice)), @constCast(slice));
    allocator.free(slice);
}

/// Wave-15 Tier-1 grinder stub — Bun's `bun.hash(content)` is a trivial
/// Wyhash wrapper. Re-attaches to the full hash family (hashWithSeed,
/// hash32, fastRandom) when those land.
pub fn hash(content: []const u8) u64 {
    return std.hash.Wyhash.hash(0, content);
}

/// Wave-15 Tier-1 grinder stub — Bun's `bun.debugAssert` is a debug-only
/// assert that compiles to nothing in Release. Mirrors `assert` semantics.
pub inline fn debugAssert(ok: bool) void {
    if (Environment.allow_assert) {
        Global.assert(ok);
    }
}

pub inline fn cast(comptime To: type, value: anytype) To {
    if (@typeInfo(@TypeOf(value)) == .int) {
        return @ptrFromInt(@as(usize, value));
    }

    return @ptrCast(@alignCast(value));
}

/// Wave-15 Tier-1 grinder stub — Bun's `bun.destroy(ptr)` is the
/// allocator-aware mirror of `allocator.destroy`. Skips heap-breakdown +
/// RefCount sanity checks (`bun.heap_breakdown` / `bun.ptr.ref_count` not
/// yet ported).
pub inline fn destroy(pointer: anytype) void {
    default_allocator.destroy(pointer);
}

// Comptime string map (copied from Bun, JSC methods stripped — they'll
// be re-added under src/jsc/ once Phase 12.2 lands).
const comptime_string_map = @import("collections/comptime_string_map.zig");
pub const ComptimeStringMap = comptime_string_map.ComptimeStringMap;
pub const ComptimeStringMap16 = comptime_string_map.ComptimeStringMap16;
pub const ComptimeStringMapWithKeyType = comptime_string_map.ComptimeStringMapWithKeyType;

/// Wave-16 Tier-1 grinder stub — Bun's `bun.ComptimeEnumMap(T)` is a
/// thin wrapper that maps `@tagName(v)` → `v` for every variant of `T`.
/// Used by sql/mysql/AuthMethod.zig and other small enum dispatchers.
pub fn ComptimeEnumMap(comptime T: type) type {
    @setEvalBranchQuota(50_000);
    const values = std.enums.values(T);
    var entries: [values.len]struct { [:0]const u8, T } = undefined;
    for (values, &entries) |value, *entry| {
        entry.* = .{ @tagName(value), value };
    }
    return ComptimeStringMap(T, entries);
}

const identity_context = @import("collections/identity_context.zig");
pub const IdentityContext = identity_context.IdentityContext;
pub const ArrayIdentityContext = identity_context.ArrayIdentityContext;

pub const bit_set = @import("collections/bit_set.zig");
pub const AutoBitSet = bit_set.AutoBitSet;
pub const StaticBitSet = bit_set.StaticBitSet;
pub const IntegerBitSet = bit_set.IntegerBitSet;
pub const DynamicBitSet = bit_set.DynamicBitSet;
pub const DynamicBitSetUnmanaged = bit_set.DynamicBitSetUnmanaged;

const multi_array_list = @import("collections/multi_array_list.zig");
pub const MultiArrayList = multi_array_list.MultiArrayList;

const linear_fifo = @import("collections/linear_fifo.zig");
pub const LinearFifo = linear_fifo.LinearFifo;
pub const LinearFifoBufferType = linear_fifo.LinearFifoBufferType;

const static_hash_map = @import("collections/StaticHashMap.zig");
pub const AutoHashMap = static_hash_map.AutoHashMap;
pub const AutoStaticHashMap = static_hash_map.AutoStaticHashMap;
pub const StaticHashMap = static_hash_map.StaticHashMap;
pub const HashMap = static_hash_map.HashMap;
pub const SortedHashMap = static_hash_map.SortedHashMap;

const baby_list = @import("collections/baby_list.zig");
pub const BabyList = baby_list.BabyList;
pub const ByteList = baby_list.ByteList;
pub const OffsetByteList = baby_list.OffsetByteList;

// Fourth-wave collection additions (2026-05-17):
const hive_array = @import("collections/hive_array.zig");
pub const HiveArray = hive_array.HiveArray;
const object_pool = @import("collections/pool.zig");
pub const ObjectPool = object_pool.ObjectPool;

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
    /// Calling convention used by Bun JSC host functions.
    pub const conv: std.builtin.CallingConvention = if (Environment.isWindows and Environment.isX64)
        .{ .x86_64_sysv = .{} }
    else
        .c;

    pub const JSValue = @import("jsc/JSValue.zig").JSValue;
    pub const CallFrame = @import("jsc/CallFrame.zig").CallFrame;
    pub const JSGlobalObject = @import("jsc/JSGlobalObject.zig").JSGlobalObject;
    pub const ConsoleObject = @import("jsc/ConsoleObject.zig");
    pub const JSPromiseRejectionOperation = @import("jsc/JSPromiseRejectionOperation.zig").JSPromiseRejectionOperation;
    pub const ScriptExecutionStatus = @import("jsc/ScriptExecutionStatus.zig").ScriptExecutionStatus;
    pub const SourceType = @import("jsc/SourceType.zig").SourceType;
    pub const sizes = @import("jsc/sizes.zig");
    pub const JSRuntimeType = @import("jsc/JSRuntimeType.zig").JSRuntimeType;
    pub const GetterSetter = @import("jsc/GetterSetter.zig").GetterSetter;
    pub const StaticExport = @import("jsc/static_export.zig");
    pub const ErrorCode = @import("jsc/ErrorCode.zig").ErrorCode;
    pub const Error = anyerror;
    pub const CommonAbortReason = @import("jsc/CommonAbortReason.zig").CommonAbortReason;
    // Fourth-wave port batch (2026-05-17, 8-agent parallel dispatch):
    pub const Exception = @import("jsc/Exception.zig").Exception;
    pub const CppTask = @import("jsc/CppTask.zig").CppTask;
    pub const ConcurrentCppTask = @import("jsc/CppTask.zig").ConcurrentCppTask;
    pub const config = @import("jsc/config.zig");
    pub const codegen = @import("jsc/codegen.zig");
    pub const comptime_string_map_jsc = @import("jsc/comptime_string_map_jsc.zig");
    // Fifth-wave port batch (2026-05-18):
    pub const CachedBytecode = @import("jsc/CachedBytecode.zig").CachedBytecode;
    pub const JSMap = @import("jsc/JSMap.zig").JSMap;
    pub const JSBigInt = @import("jsc/JSBigInt.zig").JSBigInt;
    pub const JSArray = @import("jsc/JSArray.zig").JSArray;
    pub const JSFunction = @import("jsc/JSFunction.zig").JSFunction;
    pub const JSModuleLoader = @import("jsc/JSModuleLoader.zig").JSModuleLoader;
    pub const Errorable = @import("jsc/Errorable.zig").Errorable;
    pub const ErrorableString = Errorable(String);
    pub const DeferredError = @import("jsc/DeferredError.zig").DeferredError;
    pub const DecodedJSValue = @import("jsc/DecodedJSValue.zig").DecodedJSValue;
    pub const Strong = struct {
        pub const Deprecated = @import("jsc/DeprecatedStrong.zig");
    };
    pub const CPUProfiler = @import("jsc/BunCPUProfiler.zig").CPUProfiler;
    pub const CPUProfilerConfig = @import("jsc/BunCPUProfiler.zig").CPUProfilerConfig;
    pub const HeapProfiler = @import("jsc/BunHeapProfiler.zig").HeapProfiler;
    pub const HeapProfilerConfig = @import("jsc/BunHeapProfiler.zig").HeapProfilerConfig;
    // Sixth-wave port batch (2026-05-18):
    pub const CommonStrings = @import("jsc/CommonStrings.zig").CommonStrings;
    pub const RegularExpression = @import("jsc/RegularExpression.zig").RegularExpression;
    pub const URLSearchParams = @import("jsc/URLSearchParams.zig").URLSearchParams;
    pub const ZigErrorType = @import("jsc/ZigErrorType.zig").ZigErrorType;
    pub const TextCodec = @import("jsc/TextCodec.zig").TextCodec;
    pub const MarkedArgumentBuffer = @import("jsc/MarkedArgumentBuffer.zig").MarkedArgumentBuffer;
    pub const ConcurrentPromiseTask = @import("jsc/ConcurrentPromiseTask.zig").ConcurrentPromiseTask;
    // Seventh-wave port batch (2026-05-18):
    pub const AbortSignal = @import("jsc/AbortSignal.zig").AbortSignal;
    pub const JSString = @import("jsc/JSString.zig");
    pub const RefString = @import("jsc/RefString.zig").RefString;
    pub const StringBuilder = @import("jsc/StringBuilder.zig").StringBuilder;
    pub const ZigString = @import("jsc/ZigString.zig").ZigString;
    pub const SystemError = @import("jsc/SystemError.zig").SystemError;
    pub const WTF = @import("jsc/WTF.zig");
    pub const Weak = @import("jsc/Weak.zig");
    pub const javascript_core_c_api = @import("jsc/javascript_core_c_api.zig");
    pub const DOMURL = @import("jsc/DOMURL.zig").DOMURL;
    pub const JSArrayIterator = @import("jsc/JSArrayIterator.zig").JSArrayIterator;
    // Eighth-wave port batch (2026-05-18):
    pub const JSUint8Array = @import("jsc/JSUint8Array.zig").JSUint8Array;
    pub const VM = @import("jsc/VM.zig").VM;
    pub const URL = @import("jsc/URL.zig").URL;
    pub const DOMFormData = @import("jsc/DOMFormData.zig").DOMFormData;
    pub const TopExceptionScope = @import("jsc/TopExceptionScope.zig").TopExceptionScope;
    pub const ExceptionValidationScope = @import("jsc/TopExceptionScope.zig").ExceptionValidationScope;
    pub const JSPropertyIterator = @import("jsc/JSPropertyIterator.zig").JSPropertyIterator;
    pub const JSPropertyIteratorOptions = @import("jsc/JSPropertyIterator.zig").JSPropertyIteratorOptions;
    pub const ProcessAutoKiller = @import("jsc/ProcessAutoKiller.zig");
    pub const JSONLineBuffer = @import("jsc/JSONLineBuffer.zig").JSONLineBuffer;
    // Twelfth-wave port batch (2026-05-18). uuid.zig is the pure-Zig UUID
    // v4/v5/v7 impl (csprng parked on DefaultCsprng). resolve_path_jsc
    // and resolver_jsc carry C++-visible extern symbol declarations for
    // the node:module / require.main paths host fns; bodies park behind
    // Phase 12.2 JSC bridge.
    pub const uuid = @import("jsc/uuid.zig");
    pub const resolve_path_jsc = @import("jsc/resolve_path_jsc.zig");
    pub const resolver_jsc = @import("jsc/resolver_jsc.zig");
    // Thirteenth-wave port batch (2026-05-18). Registry of every Zig
    // type the C++ Codegen reflects to JS. Entries are opaque
    // placeholders until each downstream subsystem (api/webcore/jsc)
    // lands its real type.
    pub const generated_classes_list = @import("jsc/generated_classes_list.zig");
    // Phase 12.2 M1 (2026-05-19) — stub-runnable bridge scaffold per
    // `JSC_BRIDGE_SCOPE_2026-05-19.md` §M1. The `opaques` aggregator
    // names the ~10 core JSC opaque types (JSValue, JSGlobalObject,
    // JSCell, …); `extern_fns` declares ~30 core C-API entrypoints with
    // signatures only (bodies link-resolved, fail until M3); `types`
    // exposes the C-API `JSType` + `JSTypedArrayType` enums for the
    // "new code" pathway. Existing per-file leaves (JSGlobalObject.zig,
    // JSCell.zig, VM.zig, etc.) keep their richer per-type stubs.
    pub const opaques = @import("jsc/opaques.zig");
    pub const extern_fns = @import("jsc/extern_fns.zig");
    pub const c_api_types = @import("jsc/types.zig");
    // Phase 12.2 M3 prep (2026-05-19) — Engine stub. Bodies panic with
    // TODO(phase-12.2-M3) until the C++ engine wiring lands.
    pub const engine = @import("jsc/engine.zig");
    pub const evaluate = @import("jsc/evaluate.zig");
    // Phase 12.2 M4 (2026-05-19) — exception + coerce + array helpers
    // per `JSC_BRIDGE_SCOPE_2026-05-19.md` §M4. Each namespace exposes
    // a uniform Zig-shaped surface on top of the M1 extern fn set;
    // bodies panic with TODO(phase-12.2-M3) until the C++ engine
    // wiring lands. Downstream callers can be written against these
    // signatures today without waiting on linker resolution.
    pub const exception = @import("jsc/exception_helpers.zig");
    pub const coerce = @import("jsc/coerce.zig");
    pub const array = @import("jsc/array.zig");
    // Phase 12.2 M5 (2026-05-19) — function-call + host-callback
    // helpers per `JSC_BRIDGE_SCOPE_2026-05-19.md` §M5. `call` covers
    // "Zig invokes a JS function/method/constructor" (callFunction,
    // callMethod, constructObject, isCallable, isConstructor); `callback`
    // covers "Zig publishes a function JS can invoke"
    // (Callback struct + registerCallback + registerHostFunction).
    // Bodies panic with TODO(phase-12.2-M3) until the C++ engine
    // wiring lands.
    pub const call = @import("jsc/call.zig");
    pub const callback = @import("jsc/callback.zig");
    // Phase 12.2 M6 (2026-05-19) — final scaffold milestone:
    // JSON + Promise + Iterator + Global helpers. Bodies panic with
    // TODO(phase-12.2-M3) until the C++ engine wiring lands. After M6
    // the bridge surface is complete enough for ~30 of the ~800
    // unported files to depend on.
    pub const json = @import("jsc/json.zig");
    pub const promise = @import("jsc/promise.zig");
    pub const iterator = @import("jsc/iterator.zig");
    pub const global = @import("jsc/global.zig");
    pub const WebCore = @import("home_rt").runtime.webcore;
    pub const host_fn = @import("jsc/host_fn.zig");
    pub const JSHostFn = host_fn.JSHostFn;
    pub const JSHostFnZig = host_fn.JSHostFnZig;
    pub const JSHostFnZigWithContext = host_fn.JSHostFnZigWithContext;
    pub const JSHostFunctionTypeWithContext = host_fn.JSHostFunctionTypeWithContext;
    pub const toJSHostFn = host_fn.toJSHostFn;
    pub const toJSHostFnResult = host_fn.toJSHostFnResult;
    pub const toJSHostFnWithContext = host_fn.toJSHostFnWithContext;
    pub const toJSHostCall = host_fn.toJSHostCall;
    pub const fromJSHostCall = host_fn.fromJSHostCall;
    pub const fromJSHostCallGeneric = host_fn.fromJSHostCallGeneric;
};

// ---- src/io/ -----------------------------------------------------------
// Event loop + file poll opaques. The Loop / KeepAlive / FilePoll names
// are kept so callers can spell their function signatures; full impls
// land in Phase 12.3.
pub const io = struct {
    pub const Loop = @import("io/stub_event_loop.zig").Loop;
    pub const KeepAlive = @import("io/stub_event_loop.zig").KeepAlive;
    pub const FilePoll = @import("io/stub_event_loop.zig").FilePoll;
    // Fourth-wave port batch (2026-05-17). pipes.zig is enum-only;
    // the PollOrFd union re-attaches with the full Async substrate.
    pub const FileType = @import("io/pipes.zig").FileType;
    pub const ReadState = @import("io/pipes.zig").ReadState;
    // Fifth-wave port batch (2026-05-18):
    pub const MaxBuf = @import("io/MaxBuf.zig");
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
    // Fourth-wave port batch (2026-05-17):
    pub const HTTPRequestBody = @import("http/HTTPRequestBody.zig").HTTPRequestBody;
    pub const SendFile = @import("http/HTTPRequestBody.zig").SendFile;
    // Eighth-wave port (2026-05-18). Real `ThreadSafeStreamBuffer` landed —
    // wraps `home_rt.threading.Mutex` + a local 2-thread refcount + a
    // minimal `StreamBuffer` subset. Supersedes the in-file stub
    // `HTTPRequestBody.ThreadSafeStreamBuffer`, which now stays only as
    // backward-compat shim for the field type in `HTTPRequestBody.stream`.
    pub const ThreadSafeStreamBuffer = @import("http/ThreadSafeStreamBuffer.zig");
    pub const websocket = @import("http/websocket.zig");
    pub const lshpack = @import("http/lshpack.zig");
    // Sixth-wave port batch (2026-05-18):
    pub const h3_client = struct {
        pub const AltSvc = @import("http/h3_client/AltSvc.zig");
        // Eighth-wave port batch (2026-05-18). Leaf data + lifecycle for
        // an in-flight HTTP/3 request and a DNS-pending QUIC connect.
        // ClientSession / ClientContext / callbacks / encode are parked
        // (full lsquic state machine + bun.http back-edges).
        pub const Stream = @import("http/h3_client/Stream.zig");
        pub const PendingConnect = @import("http/h3_client/PendingConnect.zig");
    };
    // Eighth-wave port batch (2026-05-18). HTTP/2 client leaves — Stream
    // (per-request) + PendingConnect (TLS-connect coalescer). Sibling
    // ClientSession / dispatch / encode are parked alongside the full
    // fetch() state machine.
    pub const h2_client = struct {
        pub const Stream = @import("http/h2_client/Stream.zig");
        pub const PendingConnect = @import("http/h2_client/PendingConnect.zig");
    };
};
pub const http_types = struct {
    pub const Encoding = @import("http_types/Encoding.zig").Encoding;
    pub const Method = @import("http_types/Method.zig").Method;
    pub const FetchRedirect = @import("http_types/FetchRedirect.zig").FetchRedirect;
    pub const FetchRequestMode = @import("http_types/FetchRequestMode.zig").FetchRequestMode;
    pub const FetchCacheMode = @import("http_types/FetchCacheMode.zig").FetchCacheMode;
    pub const mime_type_list_enum = @import("http_types/mime_type_list_enum.zig");
    // Fourth-wave port batch (2026-05-17):
    pub const ETag = @import("http_types/ETag.zig");
    pub const URLPath = @import("http_types/URLPath.zig");
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
    pub const typeBaseName = @import("meta/meta.zig").typeBaseName;
    pub const typeBaseNameT = @import("meta/meta.zig").typeBaseNameT;
    pub const bits = @import("meta/bits.zig");
    pub const traits = @import("meta/traits.zig");
};

// ---- src/crash_handler/ ------------------------------------------------
// Out-of-memory + crash reporting. Only the OOM wrapper is ported today;
// the full crash handler (stack walking, JSC stop-the-world, native
// signal handlers) re-lands in a later sub-phase.
pub const crash_handler = struct {
    pub const handle_oom = @import("crash_handler/handle_oom.zig");
    pub const StoredTrace = @import("crash_handler/StoredTrace.zig").StoredTrace;
    // Wave-16 Tier-1 grinder (2026-05-18):
    pub const CPUFeatures = @import("crash_handler/CPUFeatures.zig");
};

// ---- src/core/ -----------------------------------------------------
// Additional Tier-0 helpers — pure-Zig utilities the rest of the runtime
// leans on. (result.zig + tty.zig already wired below.)
pub const ExactSizeMatcher = @import("core/string/immutable/exact_size_matcher.zig").ExactSizeMatcher;
// Sixth-wave port batch (2026-05-18):
pub const feature_flags = @import("core/feature_flags.zig");
pub const util = @import("core/util.zig");
pub const grapheme = @import("core/string/immutable/grapheme.zig");
pub const BoundedArray = @import("core/bounded_array.zig").BoundedArray;
pub const BoundedArrayAligned = @import("core/bounded_array.zig").BoundedArrayAligned;

// ---- src/install_types/ ------------------------------------------------
// Package manager type vocabulary. The full `install/PackageManager.zig`
// runtime is the Phase 12.9 destination; these split-out types are pure
// data and land first so other subsystems can name them.
pub const install_types = struct {
    pub const NodeLinker = @import("install_types/NodeLinker.zig").NodeLinker;
    // Legacy install_types compatibility aliases for callers that still
    // name Bun's pre-split semver strings through install_types. The
    // Bun-compatible semver namespace is exported as home_rt.Semver below.
    pub const SemverString = @import("install_types/SemverString.zig").String;
    pub const ExternalString = @import("install_types/ExternalString.zig").ExternalString;
    pub const SlicedString = @import("install_types/SlicedString.zig").SlicedString;
};

// ---- src/semver/ -------------------------------------------------------
// Bun-compatible semver aggregator. The pure Zig leaves are local; the
// JSC-backed SemverObject remains blocked in semver/semver.zig until the
// semver_jsc bridge lands.
pub const Semver = @import("semver/semver.zig");

// ---- src/install/ ------------------------------------------------------
// Pure-Zig install/ leaves. Home replaces Bun's package manager with
// Pantry (docs/TS_PARITY_PLAN.md §12.9); only small leaves other
// runtime subsystems still need are copied.
pub const install = struct {
    pub const ids = @import("install/PackageID.zig");
    pub const PackageID = ids.PackageID;
    pub const DependencyID = ids.DependencyID;
    pub const invalid_package_id = ids.invalid_package_id;
    pub const invalid_dependency_id = ids.invalid_dependency_id;
    pub const PackageNameAndVersionHash = ids.PackageNameAndVersionHash;
    pub const PackageNameHash = ids.PackageNameHash;
    pub const TruncatedPackageNameHash = ids.TruncatedPackageNameHash;
    pub const external = @import("install/ExternalSlice.zig");
    pub const ExternalSlice = external.ExternalSlice;
    pub const ExternalStringMap = external.ExternalStringMap;
    pub const ExternalStringList = external.ExternalStringList;
    pub const ExternalPackageNameHashList = external.ExternalPackageNameHashList;
    pub const VersionSlice = external.VersionSlice;
    pub const versioned_url = @import("install/versioned_url.zig");
    pub const VersionedURL = versioned_url.VersionedURL;
    pub const OldV2VersionedURL = versioned_url.OldV2VersionedURL;
    pub const VersionedURLType = versioned_url.VersionedURLType;
    pub const padding_checker = @import("install/padding_checker.zig");
    pub const ConfigVersion = @import("install/ConfigVersion.zig").ConfigVersion;
};

// ---- src/ptr/ ----------------------------------------------------------
// Smart-pointer helpers — Cow + meta. The full RefCount / Owned /
// TaggedPointer family re-lands in a follow-up batch.
pub const ptr = struct {
    pub const meta = @import("ptr/meta.zig");
    pub const Cow = @import("ptr/Cow.zig").Cow;
    pub const RefCount = @import("ptr/ref_count.zig").RefCount;
    pub const ThreadSafeRefCount = @import("ptr/ref_count.zig").ThreadSafeRefCount;
    pub const TaggedPointer = @import("ptr/tagged_pointer.zig").TaggedPointer;
    pub const TaggedPointerUnion = @import("ptr/tagged_pointer.zig").TaggedPointerUnion;
    // Wave-15 Tier-1 grinder (2026-05-18):
    pub const WeakPtr = @import("ptr/weak_ptr.zig").WeakPtr;
    pub const WeakPtrData = @import("ptr/weak_ptr.zig").WeakPtrData;
    pub const ExternalShared = @import("ptr/external_shared.zig").ExternalShared;
};
pub const TaggedPointer = ptr.TaggedPointer;
pub const TaggedPointerUnion = ptr.TaggedPointerUnion;

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
        // Fifteenth-wave port batch (2026-05-18). lsquic engine + event-loop
        // wiring. Loop is a local forward-decl until uws_sys/Loop.zig lands.
        pub const Context = @import("uws_sys/quic/Context.zig").Context;
        // Fifteenth-wave port batch (2026-05-18). Sibling aggregator that
        // re-exports all five quic opaques + the `globalInit` entrypoint.
        pub const aggregator = @import("uws_sys/quic.zig");
    };
    // Twelfth-wave port batch (2026-05-18). Tier-0 uws_sys leaves whose
    // upstream deps collapse to opaques: Timer (Loop forward-decl),
    // the comptime VTable generator (ConnectingSocket sibling-import,
    // us_socket_t/us_bun_verify_error_t local opaques), and the
    // embedded-by-value SocketGroup (Loop/ListenSocket/SslCtx forward-decls).
    pub const Timer = @import("uws_sys/Timer.zig").Timer;
    pub const vtable = @import("uws_sys/vtable.zig");
    pub const SocketGroup = @import("uws_sys/SocketGroup.zig").SocketGroup;
};

// ---- src/event_loop/ ---------------------------------------------------
// Bun's event-loop substrate. Most files in this directory pull in
// `bun.jsc.*` / `bun.JSError` / `bun.Async` (not yet exported), so only
// the leaves that depend exclusively on `default_allocator` + `handleOom`
// can be copied today.
pub const event_loop = struct {
    pub const DeferredTaskQueue = @import("event_loop/DeferredTaskQueue.zig");
    // Fourth-wave port batch (2026-05-17). ConcurrentTask parks on
    // UnboundedQueue + jsc.Task (TaggedPointerUnion, 8 bytes) +
    // TrivialNew/TrivialDeinit — re-attaches in Phase 12.2.
    pub const AnyTask = @import("event_loop/AnyTask.zig");
    pub const AnyTaskWithExtraContext = @import("event_loop/AnyTaskWithExtraContext.zig");
    pub const AutoFlusher = @import("event_loop/AutoFlusher.zig");
    pub const ManagedTask = @import("event_loop/ManagedTask.zig");
    // Seventh-wave port (2026-05-18). Unblocked by home_rt.threading.UnboundedQueue.
    pub const ConcurrentTask = @import("event_loop/ConcurrentTask.zig");
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
    pub const bake = @import("runtime/bake/bake.zig");
    pub const image = struct {
        pub const exif = @import("runtime/image/exif.zig");
        // Sixth-wave port batch (2026-05-18):
        pub const thumbhash = @import("runtime/image/thumbhash.zig");
        pub const quantize = @import("runtime/image/quantize.zig");
    };
    pub const server = struct {
        pub const server_module = @import("runtime/server/server.zig");
        pub const Server = server_module.Server;
        pub const HTMLBundle = @import("runtime/server/HTMLBundle.zig");
        pub const ServerConfig = @import("runtime/server/ServerConfig.zig");
        pub const HTTPStatusText = @import("runtime/server/HTTPStatusText.zig");
        // Sixth-wave port batch (2026-05-18):
        pub const RangeRequest = @import("runtime/server/RangeRequest.zig");
    };
    pub const webcore = struct {
        pub const s3 = struct {
            pub const multipart_options = @import("runtime/webcore/s3/multipart_options.zig");
        };
        // Sixth-wave port batch (2026-05-18):
        pub const EncodingLabel = @import("runtime/webcore/EncodingLabel.zig").EncodingLabel;
        // Thirteenth-wave port batch (2026-05-18). Pure-data webcore
        // leaves — the JSC-bridged `Body`/`PendingValue`/`Mixin` /
        // `AsyncFormData` / registry are parked until JSC lands.
        pub const Body = @import("runtime/webcore/Body.zig");
        pub const FormData = @import("runtime/webcore/FormData.zig").FormData;
        pub const ObjectURLRegistry = @import("runtime/webcore/ObjectURLRegistry.zig");
        pub const Sink = @import("runtime/webcore/Sink.zig");
    };
    pub const valkey = struct {
        // Per-VM Valkey state. JSC-bridge dispatch omitted — re-lands in Phase 12.2.
        pub const Context = @import("runtime/valkey_jsc/ValkeyContext.zig");
    };
    // Fifth-wave port batch (2026-05-18). Full CLI surface (commands,
    // opener, bunfig, args) lands when spawn + bunfig substrates re-attach.
    pub const cli = struct {
        pub const ci_info = @import("runtime/cli/ci_info.zig");
        pub const discord_command = @import("runtime/cli/discord_command.zig");
        // Wave-16 Tier-1 grinder (2026-05-18):
        pub const colon_list_type = @import("runtime/cli/colon_list_type.zig");
        pub const ColonListType = colon_list_type.ColonListType;
        pub const shell_completions = @import("runtime/cli/shell_completions.zig");
        pub const fuzzilli_command = @import("runtime/cli/fuzzilli_command.zig");
        // Wave-26 grinder (2026-05-19) — `which-npm-client` result
        // descriptor (npm client `bin` path + `Tag` enum). Pure data
        // — upstream `@import("bun")` was unused.
        pub const which_npm_client = @import("runtime/cli/which_npm_client.zig");
        pub const NPMClient = which_npm_client.NPMClient;
        pub const list_of_yarn_commands = @import("runtime/cli/list-of-yarn-commands.zig");
        // `test_` rather than `test` because `test` is a Zig keyword.
        pub const test_ = struct {
            pub const ParallelRunner = @import("runtime/cli/test/ParallelRunner.zig");
            pub const parallel = struct {
                pub const FileRange = @import("runtime/cli/test/parallel/FileRange.zig").FileRange;
                pub const Frame = @import("runtime/cli/test/parallel/Frame.zig");
            };
        };
    };
    // Eighth-wave port batch (2026-05-18). First runtime/api/ leaves —
    // pure-Zig helpers and small JSC bridges with stubbed JSC surfaces.
    pub const api = struct {
        pub const Subprocess = @import("runtime/api/bun/subprocess.zig");
        pub const lolhtml_jsc = @import("runtime/api/lolhtml_jsc.zig");
        pub const cron_parser = @import("runtime/api/cron_parser.zig");
        pub const bun = struct {
            pub const x509 = @import("runtime/api/bun/x509.zig");
        };
    };
    // Wave-15 Tier-1 grinder (2026-05-18). Pure-Zig shell helpers; full
    // shell surface lands once `bun.Output.scoped` + the shell parser port.
    pub const shell = struct {
        pub const RefCountedStr = @import("runtime/shell/RefCountedStr.zig");
    };
};
pub const api = runtime.api;
// ---- src/string/ -------------------------------------------------------
// Wave-15 Tier-1 grinder (2026-05-18). Pure-Zig string helpers.
// JSC-bridge surface (`jsEscapeRegExp`, JSC PathString conversion) parks
// behind Phase 12.2.
pub const string = struct {
    pub const HashedString = @import("string/HashedString.zig");
    pub const escapeRegExp = @import("string/escapeRegExp.zig").escapeRegExp;
    pub const escapeRegExpForPackageNameMatching = @import("string/escapeRegExp.zig").escapeRegExpForPackageNameMatching;
};

// ---- Home.* — JS-facing globals (formerly Bun.*) ----------------------
// Thirteenth-wave port batch (2026-05-18). Bun's `Bun.*` JavaScript
// surface lands here as Home's `Home.*` so callers can spell upstream's
// `bun.api.*` / `bun.api.bun.*` shape via `home_rt.Home.*`. Each leaf
// is the pure-Zig substrate of the corresponding JS class — the JSC
// bindings (constructor / call frames / argument coercion) are parked
// until the matching `home_rt.jsc` substrate lands.
pub const Home = struct {
    pub const Terminal = @import("runtime/api/bun/Terminal.zig");
    pub const spawn = @import("runtime/api/bun/spawn.zig");
    pub const Glob = @import("runtime/api/glob.zig");
};

// ---- src/node/ ---------------------------------------------------------
// Node.js compatibility shims. Sourced from bun/src/runtime/node/ — bun
// never grew a top-level src/node/, so this Home subtree is the namespace
// home for everything in the upstream node/ directory.
pub const node = struct {
    pub const error_code = @import("node/nodejs_error_code.zig");
    // Seventh-wave port batch (2026-05-18):
    pub const time_like = @import("node/time_like.zig");
    pub const os_constants = @import("node/os_constants.zig");
    // Phase 12.7 round-7 (2026-05-19) — `node:events` EventEmitter
    // substrate. Generic EventEmitter(EventName, Listener) + 12 methods
    // (on/off/once/emit/listenerCount/listeners/removeAllListeners/
    // setMax/getMaxListeners/eventNames/prependListener/prependOnceListener).
    // EventEmitterDefault alias for the typical string-keyed case.
    pub const events = @import("node/events.zig");
    // Phase 12.7 round-10 (2026-05-19) — `node:stream` Zig substrate.
    // Readable/Writable/Duplex/Transform/PassThrough on top of
    // node:events. Pull-mode + push-mode + pipe trampolines. The
    // round-10 `pub const buffer = …` entry that landed alongside
    // this one was a duplicate of the round-9 declaration further
    // below; wave-23 dropped the duplicate to restore home_rt smoke
    // green (the canonical entry lives next to fs/util).
    pub const stream = @import("node/stream.zig");
    // Phase 12.7 port (2026-05-19) — `node:util` Zig substrate. Top-level
    // surface (inspect/format/formatWithOptions/isDeepStrictEqual/
    // deprecate/debuglog/debug/promisify/callbackify + InspectOptions +
    // Logger + types.*) re-exports from `node/util.zig`. Zig 0.17 removed
    // `usingnamespace`, so each public symbol is aliased explicitly.
    // `parse_args_utils` is the pre-existing parse-args helper. The JS
    // shim re-attaches once the Phase 12.2 JSC bridge is live.
    pub const util = struct {
        const util_substrate = @import("node/util.zig");
        pub const InspectOptions = util_substrate.InspectOptions;
        pub const Logger = util_substrate.Logger;
        pub const max_inspect_depth = util_substrate.max_inspect_depth;
        pub const max_inspect_bytes = util_substrate.max_inspect_bytes;
        pub const inspect = util_substrate.inspect;
        pub const format = util_substrate.format;
        pub const formatWithOptions = util_substrate.formatWithOptions;
        pub const isDeepStrictEqual = util_substrate.isDeepStrictEqual;
        pub const deprecate = util_substrate.deprecate;
        pub const debuglog = util_substrate.debuglog;
        pub const debug = util_substrate.debug;
        pub const promisify = util_substrate.promisify;
        pub const callbackify = util_substrate.callbackify;
        pub const lastOutput = util_substrate.lastOutput;
        pub const clearLastOutput = util_substrate.clearLastOutput;
        pub const types = util_substrate.types;
        pub const parse_args_utils = @import("node/util/parse_args_utils.zig");
    };
    // Eighth-wave port batch (2026-05-18). myers_diff unparked (Zig 0.17
    // compat fixes applied); node_fs_constant adds the POSIX file-flag
    // surface used by `node:fs.constants`.
    pub const node_fs_constant = @import("node/node_fs_constant.zig");
    // Phase 12.7 port (2026-05-19) — `node:assert` Zig substrate. The JS
    // wrapper re-attaches once the Phase 12.2 JSC bridge is live; this
    // file exposes the Zig-callable surface that the JS layer will
    // delegate to (ok/equal/deepEqual/throws/match/...). The legacy
    // `assert.myers_diff` leaf is re-namespaced under `assert_utils` so
    // the top-level `assert` namespace can be the substrate module
    // itself.
    pub const assert = @import("node/assert.zig");
    pub const assert_utils = struct {
        pub const myers_diff = @import("node/assert/myers_diff.zig");
    };
    pub const path = @import("node/path.zig");
    // Phase 12.7 port (2026-05-19) — `node:buffer` Zig substrate.
    // Foundational dependency for node:stream, node:fs binary mode,
    // node:crypto wrappers, and many node:* tests. Self-contained
    // `Buffer` (owned/borrowed `[]u8` + optional allocator) +
    // `Encoding` enum + module-level byteLength/isBuffer/concat.
    // Numeric readers/writers are little-endian only for now; BE
    // variants re-attach when consumers need them.
    pub const buffer = @import("node/buffer.zig");
    // Phase 12.7 port (2026-05-19) — `node:fs` sync Zig substrate.
    // Exposes the std.Io.Dir-backed sync surface (readFileSync /
    // writeFileSync / existsSync / mkdirSync / rmSync / statSync /
    // readdirSync / copyFileSync / chmodSync / realpathSync / ...).
    // The async `promises` namespace stays parked behind
    // @panic("TODO(phase-12.2-M3)") until JSC + event-loop land.
    pub const fs = @import("node/fs.zig");
    // Phase 12.7 port (2026-05-19) — `node:os` Zig substrate. System
    // info helpers (hostname / platform / arch / release / type /
    // endianness / cpus / freemem / totalmem / uptime / loadavg /
    // tmpdir / homedir / userInfo / networkInterfaces / EOL) plus
    // re-exports of `os_constants`. Used by node:fs + many node:*
    // tests for cross-platform path handling. The JS shim re-attaches
    // once the Phase 12.2 JSC bridge is live.
    pub const os = @import("node/os.zig");
    // Phase 12.7 port (2026-05-19) — `node:url` Zig substrate. WHATWG
    // `URL` + `URLSearchParams` (with full get/set/has/append/delete/
    // keys/values) plus the legacy `url.parse` / `url.format` /
    // `url.resolve` / `pathToFileURL` / `fileURLToPath` /
    // `domainToASCII` / `domainToUnicode` surface. Self-contained
    // RFC-3986-leaning parser; the JS shim re-attaches once the
    // Phase 12.2 JSC bridge is live.
    pub const url = @import("node/url.zig");
    // Phase 12.7 (2026-05-19) — `node:querystring` Zig substrate. Legacy
    // `application/x-www-form-urlencoded` parser kept around for the
    // legacy `url.parse` flow + many `node:*` tests. Pure-Zig, no JSC
    // dependency. Surface: `parse` / `stringify` / `escape` /
    // `unescape` + `encode` / `decode` aliases + `ParseOptions` /
    // `StringifyOptions`.
    pub const querystring = @import("node/querystring.zig");
    // Phase 12.7 round-12 (2026-05-19) — `node:crypto` minimal substrate
    // built on std.crypto (CSPRNG + Hash family Md5/Sha1/Sha2/Sha3 +
    // HMAC). OpenSSL-backed surfaces (pbkdf2, scrypt, cipher streams,
    // sign/verify, ECDH, X509, KeyObject) stub-panic with TODO until
    // the BoringSSL bindings port.
    pub const crypto = @import("node/crypto.zig");
    // Phase 12.7 round-13 — `node:process` host-fact substrate.
    // JSC exports and EventEmitter/nextTick semantics still attach in
    // Phase 12.2, but cwd/chdir, env, pid/ppid, platform/arch,
    // hrtime, uptime, memoryUsage, and cpuUsage are native today.
    pub const process = @import("node/process.zig");
    // Phase 12.7 round-14 — `node:string_decoder` stateful byte decoder.
    // Preserves incomplete UTF-8 / UTF-16LE / base64 groups across writes
    // with the same public shape the JS shim will expose as StringDecoder.
    pub const string_decoder = @import("node/string_decoder.zig");
    // Phase 12.7 round-15 — `node:tty` native terminal facts. Provides
    // isatty/window-size/raw-mode/color-depth substrate for future
    // ReadStream/WriteStream JS wrappers.
    pub const tty = @import("node/tty.zig");
};

// ---- src/core/ + src/alloc/ + src/safety/ ----------------------
// Result type, tty mode, c_allocator, thread-id sentinel. Pure-Zig
// utilities the rest of the runtime leans on.
pub const Result = @import("core/result.zig").Result;
pub const tty = @import("core/tty.zig");
pub const c_allocator = @import("alloc/fallback.zig").c_allocator;
pub const z_allocator = @import("alloc/fallback.zig").z_allocator;
pub const freeWithoutSize = @import("alloc/fallback.zig").freeWithoutSize;
// Sub-namespace for the zero-init allocator. Re-exports the canonical
// `z_allocator` above plus the internal helpers needed by callers that
// want to spell `home_rt.alloc.fallback.z.alloc(...)`.
pub const alloc = struct {
    pub const fallback = struct {
        pub const z = @import("alloc/fallback/z.zig");
    };
};
pub const memory = @import("bun_alloc/memory.zig");
pub const allocators = struct {
    pub const c_allocator = std.heap.c_allocator;
    pub const z_allocator = @import("bun_alloc/fallback/z.zig").allocator;
    pub const freeWithoutSize = @import("bun_alloc/fallback.zig").freeWithoutSize;

    pub const NullableAllocator = @import("bun_alloc/NullableAllocator.zig");
    pub const MaxHeapAllocator = @import("bun_alloc/MaxHeapAllocator.zig");
    pub const BufferFallbackAllocator = @import("bun_alloc/BufferFallbackAllocator.zig");
    pub const MaybeOwned = @import("bun_alloc/maybe_owned.zig").MaybeOwned;

    pub fn isDefault(allocator: std.mem.Allocator) bool {
        return allocator.vtable == @This().c_allocator.vtable;
    }

    pub fn asStd(allocator: anytype) std.mem.Allocator {
        return if (comptime @TypeOf(allocator) == std.mem.Allocator)
            allocator
        else
            allocator.allocator();
    }

    pub fn Borrowed(comptime Allocator: type) type {
        return if (comptime @hasDecl(Allocator, "Borrowed"))
            Allocator.Borrowed
        else
            Allocator;
    }

    pub fn borrow(allocator: anytype) Borrowed(@TypeOf(allocator)) {
        return if (comptime @hasDecl(@TypeOf(allocator), "Borrowed"))
            allocator.borrow()
        else
            allocator;
    }

    pub fn Nullable(comptime Allocator: type) type {
        return if (comptime Allocator == std.mem.Allocator)
            NullableAllocator
        else if (comptime @hasDecl(Allocator, "Nullable"))
            Allocator.Nullable
        else
            ?Allocator;
    }

    pub fn initNullable(comptime Allocator: type, allocator: ?Allocator) Nullable(Allocator) {
        return if (comptime Allocator == std.mem.Allocator or @hasDecl(Allocator, "Nullable"))
            .init(allocator)
        else
            allocator;
    }

    pub fn unpackNullable(comptime Allocator: type, allocator: Nullable(Allocator)) ?Allocator {
        return if (comptime Allocator == std.mem.Allocator or @hasDecl(Allocator, "Nullable"))
            allocator.get()
        else
            allocator;
    }

    pub const Default = struct {
        pub fn allocator(self: Default) std.mem.Allocator {
            _ = self;
            return allocators.c_allocator;
        }

        pub const deinit = void;
    };
};
pub const io_heap = @import("io/heap.zig");
pub const perf = struct {
    // Zig 0.17 compat: perf/system_timer.zig depends on `std.time.Timer`,
    // which 0.17.0-dev.263 removed. Parked until a thin `std.Io.Clock`
    // adapter lands.
    pub const generated_perf_trace_events = @import("perf/generated_perf_trace_events.zig");
    // Wave-19 unmined-corner port (2026-05-19). Unbarriered TSC reader from
    // `bun/src/perf/hw_timer.zig`. Adds `Environment.isAarch64` /
    // `Environment.isX64` to the substrate so the asm-volatile paths gate
    // correctly.
    pub const hw_timer = @import("perf/hw_timer.zig");
};
pub const safety = struct {
    pub const thread_id = @import("safety/thread_id.zig");
    // Fourth-wave port batch (2026-05-17):
    pub const asan = @import("safety/asan.zig");
    pub const CriticalSection = @import("safety/CriticalSection.zig");
    pub const ThreadLock = @import("safety/ThreadLock.zig");
    pub const alloc = @import("safety/alloc.zig");
    pub const CheckedAllocator = @import("safety/alloc.zig").CheckedAllocator;
    // Thirteenth-wave port batch (2026-05-18). Upstream's `safety/safety.zig`
    // aggregator — re-exports `alloc`, `CheckedAllocator`, `CriticalSection`,
    // `ThreadLock` exactly the way Bun does. Wired as a sibling namespace so
    // callers can spell `home_rt.safety.aggregator.CheckedAllocator` when
    // they want the upstream-style flat surface.
    pub const aggregator = @import("safety/safety.zig");
};
pub const asan = safety.asan;

// ---- src/threading/ ----------------------------------------------------
// Fifth-wave port batch (2026-05-18). Mutex/Condition/Futex + WaitGroup
// + an unbounded mpsc queue + Guarded smart pointers. Channel /
// ThreadPool / WorkPool are parked (Channel pulls in LinearFifo;
// ThreadPool depends on mimalloc + jsc.wtf).
pub const threading = struct {
    pub const Mutex = @import("threading/Mutex.zig");
    pub const Futex = @import("threading/Futex.zig");
    pub const Condition = @import("threading/Condition.zig");
    pub const WaitGroup = @import("threading/WaitGroup.zig");
    pub const guarded = @import("threading/guarded.zig");
    pub const Guarded = guarded.Guarded;
    pub const GuardedBy = guarded.GuardedBy;
    pub const DebugGuarded = guarded.Debug;
    pub const UnboundedQueue = @import("threading/unbounded_queue.zig").UnboundedQueue;
};

// ---- src/sys/ ----------------------------------------------------------
// Fifth-wave port batch (2026-05-18). Pure-data sys leaves; the
// big sys.zig substrate (4703 lines) is a future port. Lots of files
// blocked on `bun.sys.SystemErrno` + `bun.sys.Maybe` until that lands.
pub const sys = struct {
    pub const Dir = @import("sys/dir.zig").Dir;
    pub const SignalCode = @import("sys/SignalCode.zig").SignalCode;
    // Seventh-wave port (2026-05-18):
    pub const Tag = @import("sys/tag.zig").Tag;
    // Eighth-wave port (2026-05-18). Generic `Maybe(T, E)` extracted from
    // upstream `src/sys/sys.zig` line 337 + `src/runtime/node.zig` line 64
    // (the underlying factory). Carves out the part of the 4703-line
    // sys.zig substrate that downstream files want without dragging in
    // every syscall wrapper. `kindFromMode` and a Zig-0.17-compat
    // `FileKind` enum tag along for the ride.
    pub const maybe = @import("sys/maybe.zig");
    pub const Maybe = maybe.Maybe;
    pub const FileKind = maybe.FileKind;
    pub const kindFromMode = maybe.kindFromMode;
    // Wave-20 Tier-2 substrate (2026-05-19). `SystemErrno` proxies the
    // per-platform dispatcher in `errno/errno.zig` so copied source can
    // spell `home_rt.sys.SystemErrno` (mirrors upstream `bun.sys.SystemErrno`).
    // The strerror tables below are pure-data `EnumMap` instances keyed
    // off `SystemErrno`; they cover Node.js's `uv_strerror` table and
    // coreutils' `strerror` table respectively.
    pub const SystemErrno = @import("errno/errno.zig").SystemErrno;
    pub const libuv_error_map = @import("sys/libuv_error_map.zig").libuv_error_map;
    pub const coreutils_error_map = @import("sys/coreutils_error_map.zig").coreutils_error_map;
};

// ---- src/paths/ --------------------------------------------------------
// Fifth-wave port batch (2026-05-18). `home_rt.path` (singular) is
// the existing std-wrapper namespace; the copied Bun surface lands as
// `home_rt.paths` (plural) to mirror upstream `src/paths/`.
pub const paths = struct {
    pub const Path = @import("paths/paths.zig").Path;
    pub const AbsPath = @import("paths/paths.zig").AbsPath;
    pub const AutoAbsPath = @import("paths/paths.zig").AutoAbsPath;
    pub const RelPath = @import("paths/paths.zig").RelPath;
    pub const AutoRelPath = @import("paths/paths.zig").AutoRelPath;
    pub const EnvPath = @import("paths/EnvPath.zig").EnvPath;
    pub const MAX_PATH_BYTES = @import("paths/paths.zig").MAX_PATH_BYTES;
    pub const PathBuffer = @import("paths/paths.zig").PathBuffer;
    pub const WPathBuffer = @import("paths/paths.zig").WPathBuffer;
    pub const OSPathChar = @import("paths/paths.zig").OSPathChar;
    pub const OSPathSlice = @import("paths/paths.zig").OSPathSlice;
    pub const OSPathSliceZ = @import("paths/paths.zig").OSPathSliceZ;
    pub const OSPathBuffer = @import("paths/paths.zig").OSPathBuffer;
    pub const path_buffer_pool = @import("paths/path_buffer_pool.zig").path_buffer_pool;
    pub const w_path_buffer_pool = @import("paths/path_buffer_pool.zig").w_path_buffer_pool;
    pub const os_path_buffer_pool = @import("paths/path_buffer_pool.zig").os_path_buffer_pool;
};
pub const Path = paths.Path;
pub const AbsPath = paths.AbsPath;
pub const AutoAbsPath = paths.AutoAbsPath;
pub const RelPath = paths.RelPath;
pub const AutoRelPath = paths.AutoRelPath;
pub const MAX_PATH_BYTES = paths.MAX_PATH_BYTES;
pub const PathBuffer = paths.PathBuffer;
pub const PATH_MAX_WIDE = @import("paths/paths.zig").PATH_MAX_WIDE;
pub const WPathBuffer = paths.WPathBuffer;
pub const OSPathChar = paths.OSPathChar;
pub const OSPathSlice = paths.OSPathSlice;
pub const OSPathSliceZ = paths.OSPathSliceZ;
pub const OSPathBuffer = paths.OSPathBuffer;
pub const path_buffer_pool = paths.path_buffer_pool;
pub const w_path_buffer_pool = paths.w_path_buffer_pool;
pub const os_path_buffer_pool = paths.os_path_buffer_pool;

// ---- src/picohttp_sys/ -------------------------------------------------
// Fifth-wave port batch (2026-05-18). Vendored picohttpparser FFI
// surface. Pure extern decls.
pub const picohttp_sys = struct {
    pub const picohttpparser = @import("picohttp_sys/picohttpparser.zig");
};

// ---- src/wyhash/ -------------------------------------------------------
// Fifth-wave port batch (2026-05-18). Fast non-cryptographic 64-bit
// hash (Zig stdlib v0.11 vintage forked here so it doesn't move
// underneath the resolver lockfile hash).
pub const wyhash = struct {
    pub const Wyhash11 = @import("wyhash/wyhash.zig").Wyhash11;
};

// ---- src/glob/ ---------------------------------------------------------
// Fifth-wave port batch (2026-05-18). Glob syntax detection only;
// matcher + walker re-attach with bun.sys + bun.path normalizer.
pub const glob = struct {
    pub const detectGlobSyntax = @import("glob/glob.zig").detectGlobSyntax;
};

// ---- src/highway/ ------------------------------------------------------
// Fifth-wave port batch (2026-05-18). Google Highway SIMD string ops
// (C ABI surface). Links against the matching Highway library.
pub const highway = @import("highway/highway.zig");

// ---- src/sourcemap/ ----------------------------------------------------
// Fifth-wave port batch (2026-05-18). VLQ codec only; Chunk /
// Mapping / LineOffsetTable / InternalSourceMap re-attach later.
pub const sourcemap = struct {
    pub const VLQ = @import("sourcemap/VLQ.zig");
    // Seventh-wave port batch (2026-05-18):
    pub const SourceMapState = @import("sourcemap/SourceMapState.zig").SourceMapState;
    pub const DebugIDFormatter = @import("sourcemap/DebugIDFormatter.zig").DebugIDFormatter;
    pub const SourceContentHandling = @import("sourcemap/types.zig").SourceContentHandling;
    pub const SourceMapLoadHint = @import("sourcemap/types.zig").SourceMapLoadHint;
    pub const SourceContent = @import("sourcemap/types.zig").SourceContent;
};

// ---- src/bundler/ ------------------------------------------------------
// Fifteenth-wave port batch (2026-05-18). The bundler-tree lives mostly
// under `packages/bundler/`; only a handful of pure-data leaves that
// other subsystems still need are mirrored here.
pub const bundler = struct {
    pub const IndexStringMap = @import("bundler/IndexStringMap.zig");
};

// ---- src/http_jsc/ -----------------------------------------------------
// Fifteenth-wave port batch (2026-05-18). JSC bridges for the pure-data
// types in `http_types/`. Each file is an `extern fn` declaration whose
// definition resolves at link time once the JSC C++ host fns land in
// Phase 12.2; the Zig surface stays minimal so callers can spell the
// `toJS` entry-points today.
pub const http_jsc = struct {
    pub const method_jsc = @import("http_jsc/method_jsc.zig");
    pub const fetch_enums_jsc = @import("http_jsc/fetch_enums_jsc.zig");
};

// ---- src/platform/ -----------------------------------------------------
// Fifteenth-wave port batch (2026-05-18). Platform-specific syscall + log
// surfaces. Darwin is fully self-contained (`$NOCANCEL` libc variants +
// `os_log_create` / signpost externs); Linux/Windows are parked on
// `bun.allocators.LinuxMemFdAllocator` / `bun.windows.*`.
pub const platform = struct {
    pub const darwin = @import("platform/darwin.zig");
};

// ---- src/ast/ ----------------------------------------------------------
// Sixth-wave port batch (2026-05-18). Pure-data AST leaves only;
// Ref/Index, the `use client`/`use server` directive parser, and the
// server-components boundary table. Wider AST (Expr/Stmt/Symbol/G/…)
// re-attaches alongside the JS parser port.
pub const ast = struct {
    pub const Index = @import("ast/base.zig").Index;
    pub const Ref = @import("ast/base.zig").Ref;
    pub const RefHashCtx = @import("ast/base.zig").RefHashCtx;
    pub const RefCtx = @import("ast/base.zig").RefCtx;
    pub const UseDirective = @import("ast/use_directive.zig").UseDirective;
    pub const ServerComponentBoundary = @import("ast/server_component_boundary.zig");
};

// ---- src/css/ ----------------------------------------------------------
// Sixth-wave port batch (2026-05-18). Only the pure-data leaves that
// don't reach into `css_parser.zig` are ported today; the broader
// values/rules/properties tree re-attaches once `css_parser.zig`
// lands. Strategy A (self-contained-only) per agent #5's analysis.
pub const css = struct {
    pub const logical = @import("css/logical.zig");
    pub const sourcemap = @import("css/sourcemap.zig");
    pub const css_parser_stub = @import("css/css_parser_stub.zig");
    pub const values = struct {
        pub const values = @import("css/values/values.zig");
        // Seventh-wave port batch (2026-05-18, css Strategy B over stub):
        pub const css_string = @import("css/values/css_string.zig");
        pub const ratio = @import("css/values/ratio.zig");
        pub const alpha = @import("css/values/alpha.zig");
        // Eighth-wave port batch (2026-05-18):
        pub const number = @import("css/values/number.zig");
        pub const resolution = @import("css/values/resolution.zig");
        pub const size = @import("css/values/size.zig");
    };
    pub const properties = struct {
        pub const outline = @import("css/properties/outline.zig");
        // Eighth-wave port batch (2026-05-18):
        pub const display = @import("css/properties/display.zig");
        pub const overflow = @import("css/properties/overflow.zig");
        pub const position = @import("css/properties/position.zig");
        // Wave-15 Tier-1 grinder (2026-05-18). FillRule + AlphaValue
        // — pure-data shape leaves over the css_parser_stub.
        pub const shape = @import("css/properties/shape.zig");
        // Wave-16 Tier-1 grinder (2026-05-18). ContainerType +
        // ContainerNameList + Container — pure-data containment leaves.
        pub const contain = @import("css/properties/contain.zig");
        // Wave-18 Tier-1 grinder (2026-05-18). Text properties — pure
        // data shapes over the css_parser stub; `TextShadow.parse/toCss`
        // bodies dropped per stub policy (see file header).
        pub const text = @import("css/properties/text.zig");
    };
    pub const PropertyCategory = logical.PropertyCategory;
    pub const LogicalGroup = logical.LogicalGroup;
    // Seventh-wave port (2026-05-18) — stub-based CSS rule leaves.
    pub const rules = struct {
        pub const counter_style = @import("css/rules/counter_style.zig");
        pub const namespace = @import("css/rules/namespace.zig");
        pub const nesting = @import("css/rules/nesting.zig");
        pub const starting_style = @import("css/rules/starting_style.zig");
        pub const viewport = @import("css/rules/viewport.zig");
        pub const unknown = @import("css/rules/unknown.zig");
        pub const document = @import("css/rules/document.zig");
        // Eighth-wave port batch (2026-05-18):
        pub const custom_media = @import("css/rules/custom_media.zig");
        pub const media = @import("css/rules/media.zig");
        pub const tailwind = @import("css/rules/tailwind.zig");
        pub const scope = @import("css/rules/scope.zig");
    };
};

// ---- src/analytics/ ----------------------------------------------------
// Sixth-wave port batch (2026-05-18). The pure-std schema codec plus
// the JSC-free analytics gate. `Features` / `PackedFeatures` /
// `GenerateHeader` stay parked on bun.jsc.ModuleLoader + bun.Semver +
// bun.c.uname.
pub const analytics = struct {
    pub const schema = @import("analytics/schema.zig");
    pub const gate = @import("analytics/analytics.zig");
    pub const Features = @import("analytics/Features.zig");
};

// ---- src/*_sys/ --------------------------------------------------------
// Sixth-wave port batch (2026-05-18). Pure FFI extern wrappers around
// vendored native deps. Link-time contracts; no runtime logic.
pub const mimalloc_sys = struct {
    // Round-4 (2026-05-19): swap from the upstream wrapper to the libc
    // shim so `mi_malloc`/`mi_free`/`mi_calloc`/`mi_realloc` resolve at
    // link time without requiring a vendored mimalloc-bun build.
    // The real wrapper at `mimalloc_sys/mimalloc.zig` stays on disk and
    // re-enables when Phase 12.2 lands mimalloc-bun (revert this line).
    pub const mimalloc = @import("mimalloc_shim.zig");
};
pub const tcc_sys = struct {
    pub const tcc = @import("tcc_sys/tcc.zig");
};
pub const brotli_sys = struct {
    pub const brotli_c = @import("brotli_sys/brotli_c.zig");
};
pub const libdeflate_sys = struct {
    pub const libdeflate = @import("libdeflate_sys/libdeflate.zig");
};
pub const simdutf_sys = struct {
    pub const simdutf = @import("simdutf_sys/simdutf.zig");
};

// ---- src/cares_sys/ ----------------------------------------------------
// Eighth-wave port batch (2026-05-18). Vendored c-ares DNS FFI (1644 lines).
// The 22 `*ToJSResponse` JSC-bridge sentinels are local opaques; Windows
// EAI branch falls back to ENOTFOUND until libuv_sys lands.
pub const cares_sys = struct {
    pub const c_ares = @import("cares_sys/c_ares.zig");
};

// ---- src/libarchive_sys/ -----------------------------------------------
// Eighth-wave port batch (2026-05-18). Vendored libarchive FFI (1497 lines).
// `writeZerosToFile` + `readDataIntoFd` armed with `@compileError` until
// `home_rt.sys.File.{pwriteAll, writeAll, setFileOffset, ftruncate}` ports.
pub const libarchive_sys = struct {
    pub const bindings = @import("libarchive_sys/bindings.zig");
};

// ---- src/zlib_sys/ -----------------------------------------------------
// Wave-14 port batch (2026-05-18). Vendored zlib FFI shape: the shared
// `Z_OK` / `Z_BINARY` / `Z_NO_FLUSH` enum mirrors + the POSIX
// `z_stream_s` extern struct + `inflate`/`deflate` init wrappers.
// Pure declarations — link-time contract against the shared zlib in
// `packages/bun-usockets`.
pub const zlib_sys = struct {
    pub const shared = @import("zlib_sys/shared.zig");
    pub const posix = @import("zlib_sys/posix.zig");
    // Sixteenth-wave port batch (2026-05-18). Translate-c'd zlib.h
    // Windows-LLP64 shape; routes through shared.zig at compile time.
    pub const win32 = @import("zlib_sys/win32.zig");
};

// ---- src/md/ -----------------------------------------------------------
// Sixteenth-wave port batch (2026-05-18). Pure-data markdown tables:
// unicode case-fold map + HTML named entity table.
pub const md = struct {
    pub const unicode = @import("md/unicode.zig");
    pub const entity = @import("md/entity.zig");
};

// ---- src/windows_sys/ --------------------------------------------------
// Sixteenth-wave port batch (2026-05-18). Raw Win32 extern decls
// (aliases over std.os.windows).
pub const windows_sys = struct {
    pub const externs = @import("windows_sys/externs.zig");
};

// ---- src/codegen/ ------------------------------------------------------
// Sixteenth-wave port batch (2026-05-18). Translate-c post-processing
// tool for Windows headers.
pub const codegen = struct {
    pub const process_windows_translate_c = @import("codegen/process_windows_translate_c.zig");
};

// ---- src/s3_signing/ ---------------------------------------------------
// Eighth-wave port batch (2026-05-18). Pure-Zig S3 helpers: canned-ACL
// + storage-class enums + error code/message lookup. Credentials +
// signer parked on JSC + webcore surface.
pub const s3_signing = struct {
    pub const ACL = @import("s3_signing/acl.zig").ACL;
    pub const StorageClass = @import("s3_signing/storage_class.zig").StorageClass;
    pub const sign_error = @import("s3_signing/error.zig");
};

// ---- src/errno/ --------------------------------------------------------
// Seventh-wave port batch (2026-05-18). POSIX errno tables per platform.
// Each file inlines a small `uv_constants` block for the few UV_E* codes
// that have no native POSIX counterpart; those are replaced by
// `home_rt.libuv_sys.libuv.UV_E*` once libuv_sys lands. Windows skipped
// (needs windows.Win32Error + libuv_sys).
pub const errno = struct {
    pub const darwin = @import("errno/darwin_errno.zig");
    pub const linux = @import("errno/linux_errno.zig");
    pub const freebsd = @import("errno/freebsd_errno.zig");
};

// ---- src/exe_format/ ---------------------------------------------------
// Seventh-wave port batch (2026-05-18). Standalone-executable section
// writers used by `home build --compile`. Only PE is self-contained;
// ELF/Mach-O parked on bun.sys (ELF) and bun.sha.SHA256 (Mach-O codesign).
pub const exe_format = struct {
    pub const pe = @import("exe_format/pe.zig");
};

// ---- src/zstd/ ---------------------------------------------------------
// Seventh-wave port batch (2026-05-18). Vendored facebook/zstd FFI surface
// + the streaming-decompress reader. Upstream pulled the `ZSTD_*` extern
// symbols from `bun.c` (translate-c over `<zstd.h>`); we inline them as
// `extern fn` decls in `zstd.c` since translate-c isn't wired up yet.
pub const zstd = struct {
    pub const zstd = @import("zstd/zstd.zig");
};

// ---- src/boringssl_sys/ ------------------------------------------------
// Seventh-wave port batch (2026-05-18). Vendored google/boringssl C ABI
// surface — SSL_*, BIO_*, X509_*, EVP_*, RSA_*, EC_*, ERR_*, and the rest
// of libcrypto/libssl. 19 306 lines, near-verbatim copy. The only deviation
// from upstream is that `bun.uws.us_bun_verify_error_t` is inlined as
// `SSL.us_bun_verify_error_t` (`uws.zig` carries a JSC-tied helper that
// hasn't been ported yet).
pub const boringssl_sys = struct {
    pub const boringssl = @import("boringssl_sys/boringssl.zig");
};

// ---- src/lolhtml_sys/ --------------------------------------------------
// Seventh-wave port batch (2026-05-18). Vendored cloudflare/lol-html C ABI
// surface (`lol_html_*`). `HTMLString.toString` + `HTMLString.toJS` are
// stubbed because they reach into `bun.String` and the JSC-tied
// `runtime/api/lolhtml_jsc.zig`; everything else is verbatim.
pub const lolhtml_sys = struct {
    pub const lol_html = @import("lolhtml_sys/lol_html.zig");
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
        // Wave-18 Tier-0 grinder (2026-05-18). Stub union with
        // `.owned`/`.temporary`/`.inline_storage`/`.empty` variants —
        // packet decoders/encoders that field-store `Data` compile;
        // `toOwned`/`zdeinit`/`create` defer to Phase 12.2.
        pub const Data = @import("sql/shared/Data.zig").Data;
        // Wave-22 grinder (2026-05-19). JSC distinguishes index-vs-name
        // property names, so column identifiers parse decimal-only names
        // into `.index : u32` ahead of time. `.duplicate` flags sibling
        // collision. Pure data over the wave-18 Data stub.
        pub const ColumnIdentifier = @import("sql/shared/ColumnIdentifier.zig").ColumnIdentifier;
    };
    pub const mysql = struct {
        pub const SSLMode = @import("sql/mysql/SSLMode.zig").SSLMode;
        pub const ConnectionState = @import("sql/mysql/ConnectionState.zig").ConnectionState;
        pub const TLSStatus = @import("sql/mysql/TLSStatus.zig").TLSStatus;
        pub const QueryStatus = @import("sql/mysql/QueryStatus.zig").Status;
        pub const MySQLQueryResult = @import("sql/mysql/MySQLQueryResult.zig");
        pub const MySQLTypes = @import("sql/mysql/MySQLTypes.zig");
        // Wave-25 grinder (2026-05-19) — pure `Param` descriptor used
        // by the wire-protocol encoders. Drops in on top of the
        // wave-23 ColumnDefinition41 + MySQLTypes ports.
        pub const MySQLParam = @import("sql/mysql/MySQLParam.zig");
        pub const Param = MySQLParam.Param;
        // Wave-16 Tier-1 grinder (2026-05-18):
        pub const AuthMethod = @import("sql/mysql/AuthMethod.zig").AuthMethod;
        pub const protocol = struct {
            pub const PacketType = @import("sql/mysql/protocol/PacketType.zig").PacketType;
            pub const PacketHeader = @import("sql/mysql/protocol/PacketHeader.zig");
            // Wave-14 port batch (2026-05-18). Length-encoded integer
            // codec (MySQL wire-protocol primitive). Depends only on
            // `home_rt.BoundedArray`.
            pub const EncodeInt = @import("sql/mysql/protocol/EncodeInt.zig");
            // Wave-18/28 MySQL wire-protocol reader factory plus packet
            // leaves that decode over its method table.
            pub const NewReader = @import("sql/mysql/protocol/NewReader.zig").NewReader;
            pub const decoderWrap = @import("sql/mysql/protocol/NewReader.zig").decoderWrap;
            pub const EOFPacket = @import("sql/mysql/protocol/EOFPacket.zig");
            pub const StmtPrepareOKPacket = @import("sql/mysql/protocol/StmtPrepareOKPacket.zig");
            pub const LocalInfileRequest = @import("sql/mysql/protocol/LocalInfileRequest.zig");
            pub const OKPacket = @import("sql/mysql/protocol/OKPacket.zig");
            // Wave-22/28 MySQL wire-protocol writer factory +
            // `writeWrap` glue.
            pub const NewWriter = @import("sql/mysql/protocol/NewWriter.zig").NewWriter;
            pub const writeWrap = @import("sql/mysql/protocol/NewWriter.zig").writeWrap;
            // Wave-27 grinder (2026-05-20). MySQL in-memory reader copied
            // from Bun: offset/message-start tracking, bounded reads,
            // backwards skip, and NUL-terminated field reads.
            pub const StackReader = @import("sql/mysql/protocol/StackReader.zig");
            // Wave-27 grinder (2026-05-20). COM_QUERY writer leaf copied
            // from Bun.
            pub const Query = @import("sql/mysql/protocol/Query.zig");
            // Wave-27 grinder (2026-05-20). Client authentication
            // response packet writer copied from Bun. Connect attributes
            // use std.StringHashMapUnmanaged until the Bun alias lands.
            pub const HandshakeResponse41 = @import("sql/mysql/protocol/HandshakeResponse41.zig");
            // Wave-22 grinder (2026-05-19). Three additional MySQL
            // wire-protocol leaves from less-mined corners:
            //   - ResultSetHeader (`field_count`): leading row-set
            //     marker carrying the upcoming ColumnDefinition41 count.
            //   - AuthSwitchResponse: client → server reply after a
            //     server-side auth switch (header 0xfe).
            //   - ErrorPacket: server → client error response (0xff
            //     header, optional SQL state, error message). JSC-bridge
            //     `createMySQLError` + `toJS` re-exports omitted —
            //     Phase 12.2.
            pub const ResultSetHeader = @import("sql/mysql/protocol/ResultSetHeader.zig");
            pub const AuthSwitchResponse = @import("sql/mysql/protocol/AuthSwitchResponse.zig");
            pub const ErrorPacket = @import("sql/mysql/protocol/ErrorPacket.zig");
            // Wave-23 grinder (2026-05-19). Additional MySQL wire-protocol
            // leaves mined from less-touched corners:
            //   - SSLRequest: 32-byte TLS-upgrade negotiation packet sent
            //     right before HandshakeResponse41 once CLIENT_SSL is set.
            //   - HandshakeV10: server → client opening handshake carrying
            //     server version, connection id, auth scramble + capability
            //     flags.
            //   - ColumnDefinition41: per-column metadata record nested in
            //     ResultSet response (catalog/schema/table/name/type/...).
            //   - MySQLRequest (top-level): trivial COM_QUERY +
            //     COM_STMT_PREPARE writer helpers.
            // All bodies reach into wave-21 NewReader/NewWriter stub method
            // surfaces — compile errors out only if exercised.
            pub const SSLRequest = @import("sql/mysql/protocol/SSLRequest.zig");
            pub const HandshakeV10 = @import("sql/mysql/protocol/HandshakeV10.zig");
            pub const ColumnDefinition41 = @import("sql/mysql/protocol/ColumnDefinition41.zig");
        };
        pub const MySQLRequest = @import("sql/mysql/MySQLRequest.zig");
    };
    pub const postgres = struct {
        pub const SSLMode = @import("sql/postgres/SSLMode.zig").SSLMode;
        pub const Status = @import("sql/postgres/Status.zig").Status;
        pub const TLSStatus = @import("sql/postgres/TLSStatus.zig").TLSStatus;
        pub const CommandTag = @import("sql/postgres/CommandTag.zig").CommandTag;
        pub const AnyPostgresError = @import("sql/postgres/AnyPostgresError.zig").AnyPostgresError;
        pub const PostgresErrorOptions = @import("sql/postgres/AnyPostgresError.zig").PostgresErrorOptions;
        // Fifteenth-wave port batch (2026-05-18). Debug-only socket-monitor
        // mirrors that copy inbound/outbound Postgres bytes to a file when
        // `BUN_POSTGRES_SOCKET_MONITOR_{READER,WRITER}` are set. Both lean
        // on the wave-15 `home_rt.Output.scoped` no-op stub.
        pub const DebugSocketMonitorReader = @import("sql/postgres/DebugSocketMonitorReader.zig");
        pub const DebugSocketMonitorWriter = @import("sql/postgres/DebugSocketMonitorWriter.zig");
        // Wave-17 grinder (2026-05-19) — debug socket monitor aggregator.
        pub const SocketMonitor = @import("sql/postgres/SocketMonitor.zig");
        pub const types = struct {
            pub const int_types = @import("sql/postgres/types/int_types.zig");
        };
        pub const protocol = struct {
            pub const TransactionStatusIndicator = @import("sql/postgres/protocol/TransactionStatusIndicator.zig").TransactionStatusIndicator;
            pub const PortalOrPreparedStatement = @import("sql/postgres/protocol/PortalOrPreparedStatement.zig").PortalOrPreparedStatement;
            pub const zHelpers = @import("sql/postgres/protocol/zHelpers.zig");
            // Sixteenth-wave port batch (2026-05-18). Generic
            // decoder/writer factories + concrete BackendKeyData
            // packet leaf.
            pub const DecoderWrap = @import("sql/postgres/protocol/DecoderWrap.zig").DecoderWrap;
            pub const WriteWrap = @import("sql/postgres/protocol/WriteWrap.zig").WriteWrap;
            pub const BackendKeyData = @import("sql/postgres/protocol/BackendKeyData.zig");
            pub const NewReaderWrap = @import("sql/postgres/protocol/NewReader.zig").NewReaderWrap;
            pub const NewReader = @import("sql/postgres/protocol/NewReader.zig").NewReader;
            pub const NewWriterWrap = @import("sql/postgres/protocol/NewWriter.zig").NewWriterWrap;
            pub const NewWriter = @import("sql/postgres/protocol/NewWriter.zig").NewWriter;
            // Wave-18 Tier-0 grinder (2026-05-18). Postgres
            // wire-protocol writer/reader packet leaves. All reach
            // into the wave-16 NewReader/NewWriter method surface.
            pub const PasswordMessage = @import("sql/postgres/protocol/PasswordMessage.zig");
            pub const SASLResponse = @import("sql/postgres/protocol/SASLResponse.zig");
            pub const SASLInitialResponse = @import("sql/postgres/protocol/SASLInitialResponse.zig");
            pub const CopyOutResponse = @import("sql/postgres/protocol/CopyOutResponse.zig");
            pub const Parse = @import("sql/postgres/protocol/Parse.zig");
            pub const ReadyForQuery = @import("sql/postgres/protocol/ReadyForQuery.zig");
            pub const ParameterStatus = @import("sql/postgres/protocol/ParameterStatus.zig");
            pub const DataRow = @import("sql/postgres/protocol/DataRow.zig");
            // Wave-18 Tier-1 grinder (2026-05-18). Additional
            // Postgres wire-protocol packet leaves over the wave-16
            // NewReader/NewWriter stubs + shared.Data stub. Decoder /
            // encoder bodies stay verbatim — they trip `@compileError`
            // on actual call until the real reader/writer + bun.ByteList
            // land.
            pub const Close = @import("sql/postgres/protocol/Close.zig").Close;
            pub const Describe = @import("sql/postgres/protocol/Describe.zig");
            pub const Execute = @import("sql/postgres/protocol/Execute.zig");
            pub const CopyInResponse = @import("sql/postgres/protocol/CopyInResponse.zig");
            pub const CommandComplete = @import("sql/postgres/protocol/CommandComplete.zig");
            pub const CopyData = @import("sql/postgres/protocol/CopyData.zig");
            pub const CopyFail = @import("sql/postgres/protocol/CopyFail.zig");
            // Wave-22 grinder (2026-05-19). Postgres backend
            // RowDescription ('T') + nested FieldDescription record
            // (1-per-column) + extended-query ParameterDescription ('t').
            // All three decode via the wave-16 NewReader stub method
            // surface; exercising decode() trips a natural compile
            // error until the real reader lands (Phase 12.2).
            pub const FieldDescription = @import("sql/postgres/protocol/FieldDescription.zig");
            pub const RowDescription = @import("sql/postgres/protocol/RowDescription.zig");
            pub const ParameterDescription = @import("sql/postgres/protocol/ParameterDescription.zig");
            // Wave-22 grinder (2026-05-19). Postgres startup packet
            // (`user` / `database` / `client_encoding` + protocol
            // version 196608). Writer body reaches into the wave-16
            // NewWriter stub method surface.
            pub const StartupMessage = @import("sql/postgres/protocol/StartupMessage.zig");
            // Wave-23 grinder (2026-05-19). Postgres `R` Authentication
            // packet — tagged-union over the 10+ auth-code subtypes
            // (Ok / ClearTextPassword / MD5Password / SASL family /
            // SASLContinue / SASLFinal / ...). Decoder body lives
            // inside a comptime-generic `decodeInternal` so the
            // `home_rt.strings.split` + `reader.bytes(...)` calls
            // only get analyzed at instantiation; the file is
            // compile-clean today.
            pub const Authentication = @import("sql/postgres/protocol/Authentication.zig").Authentication;
            // Wave-25 grinder (2026-05-19). Postgres `A`
            // (NotificationResponse) backend packet. Pid + channel +
            // payload from a `LISTEN`/`NOTIFY` publication. Uses the
            // wave-18 `shared.Data.ByteList` stub for `channel` /
            // `payload`; decoder body reaches into the wave-16 NewReader
            // stub method surface (length/int4/readZ).
            pub const NotificationResponse = @import("sql/postgres/protocol/NotificationResponse.zig");
            // Wave-26 grinder (2026-05-19). FieldMessage tagged-union
            // (one per `T<value>` record inside an ErrorResponse /
            // NoticeResponse body) + the two backend packets that
            // hold a stream of them. Upstream `bun.String` is
            // substituted with a heap-owned `[]u8` slice (`cloneUTF8`
            // / `deref` / `slice` / `format` — same public shape).
            pub const FieldMessage = @import("sql/postgres/protocol/FieldMessage.zig").FieldMessage;
            pub const ErrorResponse = @import("sql/postgres/protocol/ErrorResponse.zig");
            pub const NoticeResponse = @import("sql/postgres/protocol/NoticeResponse.zig");
            pub const NegotiateProtocolVersion = @import("sql/postgres/protocol/NegotiateProtocolVersion.zig");
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
    _ = Semver;
    _ = uws_sys;
    _ = event_loop;
    _ = unicode;
    _ = runtime;
    _ = @import("runtime/bake/bake.zig");
    _ = @import("runtime/bake/DevServer.zig");
    _ = @import("runtime/bake/DevServer/HmrSocket.zig");
    _ = @import("runtime/bake/DevServer/RouteBundle.zig");
    _ = @import("runtime/bake/DevServer/SourceMapStore.zig");
    _ = @import("runtime/server/HTMLBundle.zig");
    _ = @import("runtime/server/server.zig");
    _ = node;
    _ = meta;
    _ = crash_handler;
    _ = install;
    _ = ptr;
    _ = threading;
    _ = sys;
    _ = paths;
    _ = picohttp_sys;
    _ = wyhash;
    _ = glob;
    _ = highway;
    _ = sourcemap;
    _ = ast;
    _ = css;
    _ = analytics;
    _ = mimalloc_sys;
    _ = tcc_sys;
    _ = brotli_sys;
    _ = libdeflate_sys;
    _ = simdutf_sys;
    _ = zstd;
    _ = boringssl_sys;
    _ = lolhtml_sys;
    _ = errno;
    _ = exe_format;
    _ = s3_signing;
    _ = cares_sys;
    _ = libarchive_sys;
    _ = @import("bun/cli_spawn_process_fs_file.zig");
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
    _ = @import("alloc/fallback/z.zig");
    _ = @import("http/H2FrameParser.zig");
    _ = @import("http/Signals.zig");
    _ = @import("http_types/mime_type_list_enum.zig");
    _ = @import("io/heap.zig");
    _ = @import("perf/generated_perf_trace_events.zig");
    _ = @import("sql/mysql/MySQLTypes.zig");
    // Third-wave port batch (2026-05-17, parallel-agent integration):
    _ = @import("core/string/immutable/exact_size_matcher.zig");
    _ = @import("core/bounded_array.zig");
    _ = @import("meta/bits.zig");
    _ = @import("meta/traits.zig");
    _ = @import("crash_handler/handle_oom.zig");
    _ = @import("options_types/CodeCoverageOptions.zig");
    // Fourth-wave port batch (2026-05-17, 8-agent parallel dispatch):
    _ = @import("jsc/Exception.zig");
    _ = @import("jsc/CppTask.zig");
    _ = @import("jsc/config.zig");
    _ = @import("jsc/codegen.zig");
    _ = @import("jsc/comptime_string_map_jsc.zig");
    _ = @import("http/HTTPRequestBody.zig");
    _ = @import("http/websocket.zig");
    _ = @import("http/lshpack.zig");
    _ = @import("install/ConfigVersion.zig");
    _ = @import("http_types/ETag.zig");
    _ = @import("http_types/URLPath.zig");
    _ = @import("event_loop/AnyTask.zig");
    _ = @import("event_loop/AnyTaskWithExtraContext.zig");
    _ = @import("event_loop/AutoFlusher.zig");
    _ = @import("event_loop/ManagedTask.zig");
    _ = @import("ptr/meta.zig");
    _ = @import("ptr/Cow.zig");
    _ = @import("safety/asan.zig");
    _ = @import("safety/CriticalSection.zig");
    _ = @import("safety/ThreadLock.zig");
    _ = @import("io/pipes.zig");
    _ = @import("collections/hive_array.zig");
    _ = @import("collections/pool.zig");
    // Fifth-wave port batch (2026-05-18, 6-agent parallel dispatch):
    _ = @import("jsc/CachedBytecode.zig");
    _ = @import("jsc/JSMap.zig");
    _ = @import("jsc/JSBigInt.zig");
    _ = @import("jsc/JSArray.zig");
    _ = @import("jsc/JSFunction.zig");
    _ = @import("jsc/JSModuleLoader.zig");
    _ = @import("jsc/Errorable.zig");
    _ = @import("jsc/DeferredError.zig");
    _ = @import("jsc/DecodedJSValue.zig");
    _ = @import("jsc/DeprecatedStrong.zig");
    _ = @import("jsc/BunCPUProfiler.zig");
    _ = @import("jsc/BunHeapProfiler.zig");
    _ = @import("io/MaxBuf.zig");
    _ = @import("sys/dir.zig");
    _ = @import("sys/SignalCode.zig");
    _ = @import("paths/EnvPath.zig");
    _ = @import("paths/paths.zig");
    _ = @import("paths/path_buffer_pool.zig");
    _ = @import("threading/Mutex.zig");
    _ = @import("threading/Futex.zig");
    _ = @import("threading/Condition.zig");
    _ = @import("threading/WaitGroup.zig");
    _ = @import("threading/guarded.zig");
    _ = @import("threading/unbounded_queue.zig");
    _ = @import("threading/threading.zig");
    _ = @import("runtime/cli/ci_info.zig");
    _ = @import("runtime/cli/discord_command.zig");
    _ = @import("runtime/cli/test/ParallelRunner.zig");
    _ = @import("runtime/cli/test/parallel/FileRange.zig");
    _ = @import("runtime/cli/test/parallel/Frame.zig");
    _ = @import("bun/node_url_query_assert_util_encoding.zig");
    _ = @import("picohttp_sys/picohttpparser.zig");
    _ = @import("wyhash/wyhash.zig");
    _ = @import("glob/glob.zig");
    _ = @import("highway/highway.zig");
    _ = @import("sourcemap/VLQ.zig");
    // Sixth-wave port batch (2026-05-18, 7-agent parallel dispatch):
    _ = @import("jsc/CommonStrings.zig");
    _ = @import("jsc/RegularExpression.zig");
    _ = @import("jsc/URLSearchParams.zig");
    _ = @import("jsc/ZigErrorType.zig");
    _ = @import("jsc/TextCodec.zig");
    _ = @import("jsc/MarkedArgumentBuffer.zig");
    _ = @import("jsc/ConcurrentPromiseTask.zig");
    _ = @import("core/feature_flags.zig");
    _ = @import("core/util.zig");
    _ = @import("core/string/immutable/grapheme.zig");
    _ = @import("core/string/immutable/grapheme_tables.zig");
    _ = @import("runtime/image/thumbhash.zig");
    _ = @import("runtime/image/quantize.zig");
    _ = @import("runtime/server/RangeRequest.zig");
    _ = @import("runtime/webcore/EncodingLabel.zig");
    _ = @import("analytics/schema.zig");
    _ = @import("analytics/analytics.zig");
    _ = @import("ast/base.zig");
    _ = @import("ast/use_directive.zig");
    _ = @import("ast/server_component_boundary.zig");
    _ = @import("css/logical.zig");
    _ = @import("css/sourcemap.zig");
    _ = @import("css/values/values.zig");
    _ = @import("http/h3_client/AltSvc.zig");
    _ = @import("mimalloc_sys/mimalloc.zig");
    _ = @import("tcc_sys/tcc.zig");
    _ = @import("brotli_sys/brotli_c.zig");
    _ = @import("libdeflate_sys/libdeflate.zig");
    _ = @import("simdutf_sys/simdutf.zig");
    _ = @import("zstd/zstd.zig");
    _ = @import("boringssl_sys/boringssl.zig");
    _ = @import("lolhtml_sys/lol_html.zig");
    // Seventh-wave port batch (2026-05-18):
    _ = @import("jsc/AbortSignal.zig");
    _ = @import("jsc/JSString.zig");
    _ = @import("jsc/RefString.zig");
    _ = @import("jsc/StringBuilder.zig");
    _ = @import("jsc/SystemError.zig");
    _ = @import("jsc/WTF.zig");
    _ = @import("jsc/Weak.zig");
    _ = @import("jsc/javascript_core_c_api.zig");
    _ = @import("event_loop/ConcurrentTask.zig");
    _ = @import("node/time_like.zig");
    _ = @import("node/os_constants.zig");
    _ = @import("node/util/parse_args_utils.zig");
    _ = @import("sys/tag.zig");
    _ = @import("errno/darwin_errno.zig");
    _ = @import("errno/linux_errno.zig");
    _ = @import("errno/freebsd_errno.zig");
    _ = @import("exe_format/pe.zig");
    _ = @import("sourcemap/SourceMapState.zig");
    _ = @import("sourcemap/DebugIDFormatter.zig");
    _ = @import("sourcemap/types.zig");
    _ = @import("css/rules/counter_style.zig");
    _ = @import("css/rules/namespace.zig");
    _ = @import("css/rules/nesting.zig");
    _ = @import("css/rules/starting_style.zig");
    _ = @import("css/rules/viewport.zig");
    _ = @import("css/rules/unknown.zig");
    _ = @import("css/rules/document.zig");
    _ = @import("css/css_parser_stub.zig");
    _ = @import("css/values/css_string.zig");
    _ = @import("css/values/ratio.zig");
    _ = @import("css/values/alpha.zig");
    _ = @import("css/properties/outline.zig");
    _ = @import("jsc/DOMURL.zig");
    _ = @import("jsc/JSArrayIterator.zig");
    // Eighth-wave port batch (2026-05-18):
    _ = @import("sys/maybe.zig");
    _ = @import("http/ThreadSafeStreamBuffer.zig");
    _ = @import("jsc/JSUint8Array.zig");
    _ = @import("jsc/VM.zig");
    _ = @import("jsc/URL.zig");
    _ = @import("jsc/DOMFormData.zig");
    _ = @import("jsc/TopExceptionScope.zig");
    _ = @import("jsc/JSPropertyIterator.zig");
    _ = @import("jsc/ProcessAutoKiller.zig");
    _ = @import("jsc/JSONLineBuffer.zig");
    _ = @import("http/h2_client/Stream.zig");
    _ = @import("http/h2_client/PendingConnect.zig");
    _ = @import("http/h3_client/Stream.zig");
    _ = @import("http/h3_client/PendingConnect.zig");
    _ = @import("runtime/api/lolhtml_jsc.zig");
    _ = @import("runtime/api/cron_parser.zig");
    _ = @import("runtime/api/bun/x509.zig");
    _ = @import("node/node_fs_constant.zig");
    _ = @import("node/assert/myers_diff.zig");
    _ = @import("node/assert.zig");
    _ = @import("node/util.zig");
    _ = @import("node/events.zig");
    _ = @import("node/buffer.zig");
    _ = @import("node/stream.zig");
    _ = @import("node/os.zig");
    _ = @import("s3_signing/acl.zig");
    _ = @import("s3_signing/storage_class.zig");
    _ = @import("s3_signing/error.zig");
    _ = @import("css/values/number.zig");
    _ = @import("css/values/resolution.zig");
    _ = @import("css/values/size.zig");
    _ = @import("css/properties/display.zig");
    _ = @import("css/properties/overflow.zig");
    _ = @import("css/properties/position.zig");
    _ = @import("css/rules/custom_media.zig");
    _ = @import("css/rules/media.zig");
    _ = @import("css/rules/tailwind.zig");
    _ = @import("css/rules/scope.zig");
    _ = @import("cares_sys/c_ares.zig");
    _ = @import("libarchive_sys/bindings.zig");
    // Ninth-wave port batch (2026-05-18):
    _ = @import("jsc/AnyPromise.zig");
    _ = @import("jsc/JSRef.zig");
    _ = @import("jsc/ResolvedSource.zig");
    _ = @import("jsc/bindgen_test.zig");
    _ = @import("jsc/Strong.zig");
    _ = @import("runtime/api/UnsafeObject.zig");
    _ = @import("runtime/api/JSONCObject.zig");
    _ = @import("runtime/api/TOMLObject.zig");
    _ = @import("runtime/api/HashObject.zig");
    _ = @import("runtime/api/standalone_graph_jsc.zig");
    _ = @import("runtime/api/crash_handler_jsc.zig");
    _ = @import("runtime/webcore/CookieMap.zig");
    _ = @import("runtime/webcore/ScriptExecutionContext.zig");
    _ = @import("node/fs_events.zig");
    _ = @import("node/node_error_binding.zig");
    _ = @import("install/Origin.zig");
    _ = @import("install/PreinstallState.zig");
    _ = @import("install/Aligner.zig");
    // Bundler-tree leaves now live in `packages/bundler/` (formerly
    // `packages/ts_bundler/`) — runtime no longer mirrors them.
    _ = @import("ast/op.zig");
    _ = @import("js_parser/lexer_tables.zig");
    _ = @import("uws_sys/SocketKind.zig");
    _ = @import("uws_sys/ConnectingSocket.zig");
    _ = @import("uws_sys/udp.zig");
    _ = @import("uws_sys/Timer.zig");
    _ = @import("uws_sys/vtable.zig");
    _ = @import("uws_sys/SocketGroup.zig");
    _ = @import("collections/bit_set.zig");
    _ = @import("collections/multi_array_list.zig");
    _ = @import("safety/alloc.zig");
    // Tenth-wave port batch (2026-05-18):
    _ = @import("jsc/CallFrame.zig");
    _ = @import("jsc/ZigStackFrame.zig");
    _ = @import("jsc/ZigStackTrace.zig");
    _ = @import("jsc/ZigException.zig");
    _ = @import("runtime/api/bun/SSLContextCache.zig");
    _ = @import("runtime/api/bun/SecureContext.zig");
    _ = @import("runtime/api/NativePromiseContext.zig");
    _ = @import("runtime/api/csrf_jsc.zig");
    _ = @import("runtime/server/InspectorBunFrontendDevServerAgent.zig");
    _ = @import("install/PackageID.zig");
    _ = @import("install/Features.zig");
    _ = @import("install/Behavior.zig");
    _ = @import("node/Stat.zig");
    _ = @import("node/StatFS.zig");
    _ = @import("node/node_net_binding.zig");
    _ = @import("http/H2Client.zig");
    _ = @import("http/H3Client.zig");
    _ = @import("http/websocket_http_client.zig");
    _ = @import("css/properties/effects.zig");
    _ = @import("css/values/position.zig");
    _ = @import("css/values/rect.zig");
    _ = @import("sourcemap/LineOffsetTable.zig");
    _ = @import("sourcemap/LineColumnOffset.zig");
    // Eleventh-wave port batch (2026-05-18):
    _ = @import("jsc/JSObject.zig");
    _ = @import("jsc/JSGlobalObject.zig");
    _ = @import("jsc/PosixSignalHandle.zig");
    _ = @import("jsc/EventLoopHandle.zig");
    _ = @import("jsc/fmt_jsc.zig");
    _ = @import("jsc/ZigString.zig");
    _ = @import("css/rules/layer.zig");
    _ = @import("css/rules/supports.zig");
    _ = @import("css/rules/style.zig");
    _ = @import("css/properties/box_shadow.zig");
    _ = @import("css/properties/border_radius.zig");
    _ = @import("css/properties/flex.zig");
    _ = @import("css/values/easing.zig");
    _ = @import("css/values/time.zig");
    _ = @import("runtime/api/JSON5Object.zig");
    _ = @import("runtime/api/YAMLObject.zig");
    _ = @import("runtime/api/MarkdownObject.zig");
    _ = @import("node/types.zig");
    _ = @import("node/dir_iterator.zig");
    _ = @import("node/uv_signal_handle_windows.zig");
    _ = @import("runtime/server/ServerConfig.zig");
    _ = @import("standalone_graph/StandaloneModuleGraph.zig");
    _ = @import("install_types/SemverString.zig");
    _ = @import("sourcemap/SourceMapShifts.zig");
    _ = @import("sourcemap/ParseUrlResultHint.zig");
    _ = @import("brotli/brotli.zig");
    _ = @import("zlib/zlib.zig");
    _ = @import("http/Decompressor.zig");
    _ = @import("http/zlib.zig");
    // Thirteenth-wave port batch (2026-05-18) — orphan-wave wiring.
    // Pull each newly-aggregated leaf into the test runner so inline
    // tests fire under `zig build test -Dfilter=home_rt`.
    _ = @import("analytics/Features.zig");
    _ = @import("node/path.zig");
    _ = @import("node/buffer.zig");
    _ = @import("node/fs.zig");
    _ = @import("node/url.zig");
    _ = @import("node/querystring.zig");
    _ = @import("node/crypto.zig");
    _ = @import("node/process.zig");
    _ = @import("node/string_decoder.zig");
    _ = @import("node/tty.zig");
    _ = @import("jsc/generated_classes_list.zig");
    _ = @import("runtime/api/bun/Terminal.zig");
    _ = @import("runtime/api/bun/spawn.zig");
    _ = @import("runtime/api/glob.zig");
    _ = @import("runtime/webcore/Body.zig");
    _ = @import("runtime/webcore/FormData.zig");
    _ = @import("runtime/webcore/ObjectURLRegistry.zig");
    _ = @import("runtime/webcore/Sink.zig");
    _ = @import("safety/safety.zig");
    // Wave-15 Tier-1 grinder (2026-05-18):
    _ = @import("runtime/shell/RefCountedStr.zig");
    _ = @import("string/HashedString.zig");
    _ = @import("string/escapeRegExp.zig");
    _ = string;
    _ = @import("ptr/weak_ptr.zig");
    _ = @import("ptr/external_shared.zig");
    _ = @import("css/properties/shape.zig");
    // Wave-16 Tier-1 grinder (2026-05-18):
    _ = @import("crash_handler/CPUFeatures.zig");
    _ = @import("runtime/cli/colon_list_type.zig");
    _ = @import("runtime/cli/shell_completions.zig");
    _ = @import("runtime/cli/fuzzilli_command.zig");
    _ = @import("sql/mysql/AuthMethod.zig");
    _ = @import("css/properties/contain.zig");
    // Wave-16 Tier-0 grinder (2026-05-18):
    _ = @import("md/unicode.zig");
    _ = @import("md/entity.zig");
    _ = @import("windows_sys/externs.zig");
    _ = @import("codegen/process_windows_translate_c.zig");
    _ = @import("zlib_sys/win32.zig");
    _ = @import("sql/postgres/protocol/DecoderWrap.zig");
    _ = @import("sql/postgres/protocol/WriteWrap.zig");
    _ = @import("sql/postgres/protocol/NewReader.zig");
    _ = @import("sql/postgres/protocol/NewWriter.zig");
    _ = @import("sql/postgres/protocol/BackendKeyData.zig");
    // Phase 12.2 M1 (2026-05-19) — JSC bridge scaffold smoke imports.
    _ = @import("jsc/opaques.zig");
    _ = @import("jsc/extern_fns.zig");
    _ = @import("jsc/types.zig");
    _ = @import("jsc/engine.zig");
    _ = @import("jsc/evaluate.zig");
    // Wave-18 Tier-0 grinder (2026-05-18) — sql wire-protocol leaves.
    _ = @import("sql/shared/Data.zig");
    _ = @import("sql/mysql/protocol/NewReader.zig");
    _ = @import("sql/mysql/protocol/EOFPacket.zig");
    _ = @import("sql/mysql/protocol/StmtPrepareOKPacket.zig");
    _ = @import("sql/mysql/protocol/LocalInfileRequest.zig");
    _ = @import("sql/mysql/protocol/OKPacket.zig");
    _ = @import("sql/mysql/protocol/StackReader.zig");
    _ = @import("sql/mysql/protocol/Query.zig");
    _ = @import("sql/mysql/protocol/HandshakeResponse41.zig");
    _ = @import("sql/postgres/protocol/PasswordMessage.zig");
    _ = @import("sql/postgres/protocol/SASLResponse.zig");
    _ = @import("sql/postgres/protocol/SASLInitialResponse.zig");
    _ = @import("sql/postgres/protocol/CopyOutResponse.zig");
    _ = @import("sql/postgres/protocol/Parse.zig");
    _ = @import("sql/postgres/protocol/ReadyForQuery.zig");
    _ = @import("sql/postgres/protocol/ParameterStatus.zig");
    _ = @import("sql/postgres/protocol/DataRow.zig");
    // Wave-18 Tier-1 grinder (2026-05-18) — additional sql wire-protocol
    // leaves + css/properties/text.
    _ = @import("sql/postgres/protocol/Close.zig");
    _ = @import("sql/postgres/protocol/Describe.zig");
    _ = @import("sql/postgres/protocol/Execute.zig");
    _ = @import("sql/postgres/protocol/CopyInResponse.zig");
    _ = @import("sql/postgres/protocol/CommandComplete.zig");
    _ = @import("sql/postgres/protocol/CopyData.zig");
    _ = @import("sql/postgres/protocol/CopyFail.zig");
    _ = @import("sql/postgres/protocol/NegotiateProtocolVersion.zig");
    _ = @import("css/properties/text.zig");
    // Wave-19 unmined-corner port (2026-05-19). Adds bun/src/perf/hw_timer.zig
    // (TSC reader) — the perf/ directory is otherwise lightly mined here.
    _ = @import("perf/hw_timer.zig");
}

test "home_rt.install_types.NodeLinker.fromStr maps canonical strings" {
    try std.testing.expectEqual(install_types.NodeLinker.hoisted, install_types.NodeLinker.fromStr("hoisted").?);
    try std.testing.expectEqual(install_types.NodeLinker.isolated, install_types.NodeLinker.fromStr("isolated").?);
    try std.testing.expect(install_types.NodeLinker.fromStr("nope") == null);
}

test "home_rt.Semver exposes Bun semver leaves" {
    const version_input = "1.2.3";
    const version = Semver.Version.parseUTF8(version_input);
    try std.testing.expect(version.valid);

    const range_input = "^1.0.0";
    const group = try Semver.Query.parse(std.testing.allocator, range_input, Semver.SlicedString.init(range_input, range_input));
    defer group.deinit();

    try std.testing.expect(group.satisfies(version.version.min(), range_input, version_input));
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

test "home_rt.sql.postgres.CommandTag parses command rows" {
    try std.testing.expectEqual(sql.postgres.CommandTag{ .UPDATE = 2 }, sql.postgres.CommandTag.init("UPDATE 2"));
    try std.testing.expectEqual(sql.postgres.CommandTag{ .INSERT = 3 }, sql.postgres.CommandTag.init("INSERT 0 3"));
    try std.testing.expectEqualStrings("VACUUM", sql.postgres.CommandTag.init("VACUUM").other);
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

test "home_rt.sql.postgres.protocol.Close composes a portal target" {
    const c: sql.postgres.protocol.Close = .{ .p = .{ .portal = "x" } };
    try std.testing.expectEqualStrings("x", c.p.slice());
    try std.testing.expectEqual(@as(u8, 'P'), c.p.tag());
}

test "home_rt.sql.postgres.protocol.Execute defaults max_rows to 0" {
    const e: sql.postgres.protocol.Execute = .{ .p = .{ .portal = "p" } };
    try std.testing.expectEqual(@as(u32, 0), e.max_rows);
}

test "home_rt.css.properties.text packs TextDecorationLine into a byte" {
    const TextDecorationLine = css.properties.text.TextDecorationLine;
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(TextDecorationLine));
    const t = TextDecorationLine{ .underline = true };
    try std.testing.expect(t.underline);
    try std.testing.expect(!t.overline);
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

test "home_rt.perf.hw_timer.is_supported tracks aarch64/x64" {
    const expected = Environment.isAarch64 or Environment.isX64;
    try std.testing.expectEqual(expected, perf.hw_timer.is_supported);
}

test "home_rt.safety.thread_id.invalid is the max thread id" {
    try std.testing.expectEqual(std.math.maxInt(std.Thread.Id), safety.thread_id.invalid);
}
