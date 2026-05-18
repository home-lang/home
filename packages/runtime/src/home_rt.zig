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
    pub const JSPromiseRejectionOperation = @import("jsc/JSPromiseRejectionOperation.zig").JSPromiseRejectionOperation;
    pub const ScriptExecutionStatus = @import("jsc/ScriptExecutionStatus.zig").ScriptExecutionStatus;
    pub const SourceType = @import("jsc/SourceType.zig").SourceType;
    pub const sizes = @import("jsc/sizes.zig");
    pub const JSRuntimeType = @import("jsc/JSRuntimeType.zig").JSRuntimeType;
    pub const GetterSetter = @import("jsc/GetterSetter.zig").GetterSetter;
    pub const StaticExport = @import("jsc/static_export.zig");
    pub const ErrorCode = @import("jsc/ErrorCode.zig").ErrorCode;
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
};

// ---- src/install/ ------------------------------------------------------
// Pure-Zig install/ leaves. Home replaces Bun's package manager with
// Pantry (docs/TS_PARITY_PLAN.md §12.9); only small leaves other
// runtime subsystems still need are copied.
pub const install = struct {
    pub const ExternalSlice = @import("install/ExternalSlice.zig").ExternalSlice;
    pub const padding_checker = @import("install/padding_checker.zig");
    pub const ConfigVersion = @import("install/ConfigVersion.zig").ConfigVersion;
};

// ---- src/ptr/ ----------------------------------------------------------
// Smart-pointer helpers — Cow + meta. The full RefCount / Owned /
// TaggedPointer family re-lands in a follow-up batch.
pub const ptr = struct {
    pub const meta = @import("ptr/meta.zig");
    pub const Cow = @import("ptr/Cow.zig").Cow;
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
    pub const image = struct {
        pub const exif = @import("runtime/image/exif.zig");
        // Sixth-wave port batch (2026-05-18):
        pub const thumbhash = @import("runtime/image/thumbhash.zig");
        pub const quantize = @import("runtime/image/quantize.zig");
    };
    pub const server = struct {
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
        pub const lolhtml_jsc = @import("runtime/api/lolhtml_jsc.zig");
        pub const cron_parser = @import("runtime/api/cron_parser.zig");
        pub const bun = struct {
            pub const x509 = @import("runtime/api/bun/x509.zig");
        };
    };
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
    pub const util = struct {
        pub const parse_args_utils = @import("node/util/parse_args_utils.zig");
    };
    // Eighth-wave port batch (2026-05-18). myers_diff unparked (Zig 0.17
    // compat fixes applied); node_fs_constant adds the POSIX file-flag
    // surface used by `node:fs.constants`.
    pub const node_fs_constant = @import("node/node_fs_constant.zig");
    pub const assert = struct {
        pub const myers_diff = @import("node/assert/myers_diff.zig");
    };
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
pub const io_heap = @import("io/heap.zig");
pub const perf = struct {
    // Zig 0.17 compat: perf/system_timer.zig depends on `std.time.Timer`,
    // which 0.17.0-dev.263 removed. Parked until a thin `std.Io.Clock`
    // adapter lands.
    pub const generated_perf_trace_events = @import("perf/generated_perf_trace_events.zig");
};
pub const safety = struct {
    pub const thread_id = @import("safety/thread_id.zig");
    // Fourth-wave port batch (2026-05-17):
    pub const asan = @import("safety/asan.zig");
    pub const CriticalSection = @import("safety/CriticalSection.zig");
    pub const ThreadLock = @import("safety/ThreadLock.zig");
};

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
};

// ---- src/paths/ --------------------------------------------------------
// Fifth-wave port batch (2026-05-18). `home_rt.path` (singular) is
// the existing std-wrapper namespace; the copied Bun surface lands as
// `home_rt.paths` (plural) to mirror upstream `src/paths/`.
pub const paths = struct {
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
};

// ---- src/*_sys/ --------------------------------------------------------
// Sixth-wave port batch (2026-05-18). Pure FFI extern wrappers around
// vendored native deps. Link-time contracts; no runtime logic.
pub const mimalloc_sys = struct {
    pub const mimalloc = @import("mimalloc_sys/mimalloc.zig");
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
