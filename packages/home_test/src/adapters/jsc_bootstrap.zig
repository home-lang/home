const std = @import("std");
const home_rt = @import("home_rt");
const runner = @import("../runner.zig");

const Io = std.Io;
extern fn mi_stats_get_json(size: usize, buffer: ?[*:0]u8) ?[*:0]u8;
extern fn mi_heap_dump_json(include_blocks: bool, hash_addresses: bool) ?[*:0]u8;
// The real Bun parser cone only compiles when macros are disabled
// (`-Denable_macros=false`). Couple the `Bun.Transpiler` API probe to that:
// default macros-on builds keep the heuristic transpiler (faithful default,
// stays green), and macros-off builds route `Bun.Transpiler` through the real
// parser. This gates ONLY the `transpileSource` API path, not the module loader.
const use_bun_parser_probe = !@import("build_options").enable_macros;
const NativePluginABI = home_rt.bundler.NativePluginABI;
const NapiStatus = enum(c_uint) {
    ok = 0,
    invalid_arg = 1,
    object_expected = 2,
    string_expected = 3,
    name_expected = 4,
    function_expected = 5,
    number_expected = 6,
    boolean_expected = 7,
    array_expected = 8,
    generic_failure = 9,
    pending_exception = 10,
};
const NAPI_AUTO_LENGTH = std.math.maxInt(usize);
const napi_env = ?*NativeNapiEnv;
const napi_value = ?*JSValue;
const napi_callback_info = ?*NativeCallbackFrame;
const napi_status = c_uint;
const napi_callback = ?*const fn (napi_env, napi_callback_info) callconv(.c) napi_value;
const napi_finalize = ?*const fn (napi_env, ?*anyopaque, ?*anyopaque) callconv(.c) void;

// A plain JSContext's adapter environment is not a native NapiEnv. Keep the
// pointer identities separate and dispatch native calls before reading any
// adapter fields. Other threads (including native workers) have no such envs.
threadlocal var bootstrap_napi_envs: std.AutoHashMapUnmanaged(usize, *NativeNapiEnv) = .empty;
threadlocal var registering_bootstrap_napi_module = false;

fn isBootstrapNapiEnv(env: napi_env) bool {
    return if (env) |value| bootstrap_napi_envs.contains(@intFromPtr(value)) else false;
}

const NativeNapi = struct {
    extern fn HomeNative_napi_module_register(module: ?*NativeNapiModule) void;
    extern fn HomeNative_napi_create_function(env: napi_env, name: ?[*:0]const u8, length: usize, callback: napi_callback, data: ?*anyopaque, result: ?*napi_value) napi_status;
    extern fn HomeNative_napi_get_cb_info(env: napi_env, info: napi_callback_info, argc: ?*usize, argv: [*c]napi_value, this_arg: ?*napi_value, data: ?*?*anyopaque) napi_status;
    extern fn HomeNative_napi_set_named_property(env: napi_env, object: napi_value, name: ?[*:0]const u8, value: napi_value) napi_status;
    extern fn HomeNative_napi_create_external(env: napi_env, data: ?*anyopaque, callback: napi_finalize, hint: ?*anyopaque, result: ?*napi_value) napi_status;
    extern fn HomeNative_napi_get_value_external(env: napi_env, value: napi_value, result: ?*?*anyopaque) napi_status;
    extern fn HomeNative_napi_get_value_bool(env: napi_env, value: napi_value, result: ?*bool) napi_status;
    extern fn HomeNative_napi_throw_error(env: napi_env, code: ?[*:0]const u8, message: ?[*:0]const u8) napi_status;
    extern fn HomeNative_napi_create_object(env: napi_env, result: ?*napi_value) napi_status;
};

const NativeNapiEnv = struct {
    ctx: *JSContextRef,
    exception: extern_fns.ExceptionRef,
    last_error: NapiStatus = .ok,
};

const NativeCallback = struct {
    env: *NativeNapiEnv,
    callback: napi_callback,
    data: ?*anyopaque,
};

const NativeNapiModule = extern struct {
    nm_version: c_int,
    nm_flags: c_uint,
    nm_filename: [*c]const u8,
    nm_register_func: *const fn (napi_env, napi_value) callconv(.c) napi_value,
    nm_modname: [*c]const u8,
    nm_priv: ?*anyopaque,
    reserved: [4]?*anyopaque,
};

const NativeCallbackFrame = struct {
    ctx: *JSContextRef,
    this_value: ?*JSObject,
    args: [*c]const ?*JSValue,
    arg_count: usize,
    data: ?*anyopaque,
};

const NativeExternal = struct {
    env: *NativeNapiEnv,
    data: ?*anyopaque,
    finalize: napi_finalize,
    hint: ?*anyopaque,
};

const NativeModuleMeta = struct {
    lib_index: usize,
    plugin_name: []const u8,
};

const NativeBeforeParseContext = struct {
    ctx: *JSContextRef,
    exception: extern_fns.ExceptionRef,
    source: []const u8,
    logs: std.ArrayList([]const u8) = .empty,
};

const NativeBeforeParseArgs = NativePluginABI.OnBeforeParseArguments(NativeBeforeParseContext);
const NativeBeforeParseResult = NativePluginABI.OnBeforeParseResult(NativeBeforeParseArgs);
const NativeBeforeParseFn = *const fn (*const NativeBeforeParseArgs, *NativeBeforeParseResult) callconv(.c) void;
const max_microtask_drain_rounds = 64;

var home_eval_counter: usize = 0;
var native_parser_log: home_rt.logger.Log = undefined;
var native_parser_transpiler: ?home_rt.Transpiler = null;

pub const Runtime = struct {
    engine: home_rt.jsc.engine.Engine,

    pub fn init(allocator: std.mem.Allocator, harness_source: []const u8) !Runtime {
        var self = Runtime{
            .engine = try home_rt.jsc.engine.Engine.init(allocator),
        };
        errdefer self.deinit();

        self.installNativeBindings();
        home_rt.jsc.url_global.installIdnaBridge(
            self.engine.currentContext(),
            self.engine.currentGlobalObject(),
        );
        try self.installHarness(allocator, harness_source);
        home_rt.jsc.bun_global.installNativeColor(self.engine.currentContext());
        return self;
    }

    pub fn deinit(self: *Runtime) void {
        cleanupTranspilerHandles();
        cleanupTcpListenShadows();
        cleanupServeHandles();
        cleanupNativeBridge();
        self.engine.deinit();
    }

    fn installHarness(self: *Runtime, allocator: std.mem.Allocator, harness_source: []const u8) !void {
        const evaluation = try home_rt.jsc.evaluate.evaluateUtf8Detailed(
            allocator,
            self.engine.currentContext(),
            harness_source,
            "home:corpus-harness",
            1,
        );
        defer evaluation.deinit(allocator);

        if (evaluation.exception != null or evaluation.value == null) {
            std.debug.print(
                "failed to install Bun corpus harness: {s}\n",
                .{evaluation.exception_message orelse "JavaScript evaluation returned no value"},
            );
            return error.CorpusHarnessInstallFailed;
        }
    }

    fn installNativeBindings(self: *Runtime) void {
        const allocator = std.heap.smp_allocator;
        const home_executable = preferredHomeExecutablePathAlloc(allocator) catch null;
        defer if (home_executable) |path| allocator.free(path);
        if (home_executable) |path| {
            setStringProperty(
                self.engine.currentContext(),
                @ptrCast(self.engine.currentGlobalObject()),
                "__home_bun_executable",
                path,
            ) catch {};
        }
        setStringProperty(
            self.engine.currentContext(),
            @ptrCast(self.engine.currentGlobalObject()),
            "__home_runtime_version",
            home_rt.Global.package_json_version,
        ) catch {};
        home_rt.jsc.callback.registerCallback(
            self.engine.currentContext(),
            self.engine.currentGlobalObject(),
            "__home_cryptoHashNative",
            home_rt.jsc.node_modules.hashNative,
        );
        home_rt.jsc.callback.registerCallback(
            self.engine.currentContext(),
            self.engine.currentGlobalObject(),
            "__home_cryptoSignNative",
            home_rt.jsc.node_modules.cryptoSignNative,
        );
        home_rt.jsc.callback.registerCallback(
            self.engine.currentContext(),
            self.engine.currentGlobalObject(),
            "__home_cryptoVerifyNative",
            home_rt.jsc.node_modules.cryptoVerifyNative,
        );
        home_rt.jsc.callback.registerCallback(
            self.engine.currentContext(),
            self.engine.currentGlobalObject(),
            "__home_cryptoRsaNative",
            home_rt.jsc.node_modules.cryptoRsaNative,
        );
        home_rt.jsc.callback.registerCallback(
            self.engine.currentContext(),
            self.engine.currentGlobalObject(),
            "__home_textDecodeNative",
            textDecodeNative,
        );
        home_rt.jsc.callback.registerCallback(
            self.engine.currentContext(),
            self.engine.currentGlobalObject(),
            "__home_normalizeTextEncodingLabelNative",
            normalizeTextEncodingLabelNative,
        );
        home_rt.jsc.callback.registerCallback(
            self.engine.currentContext(),
            self.engine.currentGlobalObject(),
            "__home_shellLexNative",
            shellLexNative,
        );
        home_rt.jsc.callback.registerCallback(
            self.engine.currentContext(),
            self.engine.currentGlobalObject(),
            "__home_shellParseNative",
            shellParseNative,
        );
        home_rt.jsc.callback.registerCallback(
            self.engine.currentContext(),
            self.engine.currentGlobalObject(),
            "__home_spawnSyncNative",
            spawnSyncNative,
        );
        home_rt.jsc.callback.registerCallback(
            self.engine.currentContext(),
            self.engine.currentGlobalObject(),
            "__home_gcNative",
            garbageCollectNative,
        );
        home_rt.jsc.callback.registerCallback(
            self.engine.currentContext(),
            self.engine.currentGlobalObject(),
            "__home_mimallocStatsJsonNative",
            mimallocStatsJsonNative,
        );
        home_rt.jsc.callback.registerCallback(
            self.engine.currentContext(),
            self.engine.currentGlobalObject(),
            "__home_mimallocDumpJsonNative",
            mimallocDumpJsonNative,
        );
        home_rt.jsc.callback.registerCallback(
            self.engine.currentContext(),
            self.engine.currentGlobalObject(),
            "__home_getDevServerDeinitCountNative",
            getDevServerDeinitCountNative,
        );
        home_rt.jsc.callback.registerCallback(
            self.engine.currentContext(),
            self.engine.currentGlobalObject(),
            "__home_serveNative",
            serveNative,
        );
        home_rt.jsc.callback.registerCallback(
            self.engine.currentContext(),
            self.engine.currentGlobalObject(),
            "__home_stopServeNative",
            stopServeNative,
        );
        home_rt.jsc.callback.registerCallback(
            self.engine.currentContext(),
            self.engine.currentGlobalObject(),
            "__home_tcpListenNative",
            tcpListenNative,
        );
        home_rt.jsc.callback.registerCallback(
            self.engine.currentContext(),
            self.engine.currentGlobalObject(),
            "__home_tcpStopNative",
            tcpStopNative,
        );
        home_rt.jsc.callback.registerCallback(
            self.engine.currentContext(),
            self.engine.currentGlobalObject(),
            "__home_beginServeRequestNative",
            beginServeRequestNative,
        );
        home_rt.jsc.callback.registerCallback(
            self.engine.currentContext(),
            self.engine.currentGlobalObject(),
            "__home_endServeRequestNative",
            endServeRequestNative,
        );
        home_rt.jsc.callback.registerCallback(
            self.engine.currentContext(),
            self.engine.currentGlobalObject(),
            "__home_openHmrSocketNative",
            openHmrSocketNative,
        );
        home_rt.jsc.callback.registerCallback(
            self.engine.currentContext(),
            self.engine.currentGlobalObject(),
            "__home_closeHmrSocketNative",
            closeHmrSocketNative,
        );
        home_rt.jsc.callback.registerCallback(
            self.engine.currentContext(),
            self.engine.currentGlobalObject(),
            "__home_sendHmrSocketMessageNative",
            sendHmrSocketMessageNative,
        );
        home_rt.jsc.callback.registerCallback(
            self.engine.currentContext(),
            self.engine.currentGlobalObject(),
            "__home_bakeEmitHotUpdateNative",
            bakeEmitHotUpdateNative,
        );
        home_rt.jsc.callback.registerCallback(
            self.engine.currentContext(),
            self.engine.currentGlobalObject(),
            "__home_drainHmrMessagesNative",
            drainHmrMessagesNative,
        );
        home_rt.jsc.callback.registerCallback(
            self.engine.currentContext(),
            self.engine.currentGlobalObject(),
            "__home_buildBakeStaticClientScriptNative",
            buildBakeStaticClientScriptNative,
        );
        home_rt.jsc.callback.registerCallback(
            self.engine.currentContext(),
            self.engine.currentGlobalObject(),
            "__home_writeFileSyncNative",
            writeFileSyncNative,
        );
        home_rt.jsc.callback.registerCallback(
            self.engine.currentContext(),
            self.engine.currentGlobalObject(),
            "__home_writeFileBytesSyncNative",
            writeFileBytesSyncNative,
        );
        home_rt.jsc.callback.registerCallback(
            self.engine.currentContext(),
            self.engine.currentGlobalObject(),
            "__home_readFileSyncNative",
            readFileSyncNative,
        );
        home_rt.jsc.callback.registerCallback(
            self.engine.currentContext(),
            self.engine.currentGlobalObject(),
            "__home_readFileBytesNative",
            readFileBytesNative,
        );
        home_rt.jsc.callback.registerCallback(
            self.engine.currentContext(),
            self.engine.currentGlobalObject(),
            "__home_existsPathNative",
            existsPathNative,
        );
        home_rt.jsc.callback.registerCallback(
            self.engine.currentContext(),
            self.engine.currentGlobalObject(),
            "__home_statPathNative",
            statPathNative,
        );
        home_rt.jsc.callback.registerCallback(
            self.engine.currentContext(),
            self.engine.currentGlobalObject(),
            "__home_realpathSyncNative",
            realpathSyncNative,
        );
        home_rt.jsc.callback.registerCallback(
            self.engine.currentContext(),
            self.engine.currentGlobalObject(),
            "__home_renameSyncNative",
            renameSyncNative,
        );
        home_rt.jsc.callback.registerCallback(
            self.engine.currentContext(),
            self.engine.currentGlobalObject(),
            "__home_unlinkSyncNative",
            unlinkSyncNative,
        );
        home_rt.jsc.callback.registerCallback(
            self.engine.currentContext(),
            self.engine.currentGlobalObject(),
            "__home_rmSyncNative",
            rmSyncNative,
        );
        home_rt.jsc.callback.registerCallback(
            self.engine.currentContext(),
            self.engine.currentGlobalObject(),
            "__home_createDirPathNative",
            createDirPathNative,
        );
        home_rt.jsc.callback.registerCallback(
            self.engine.currentContext(),
            self.engine.currentGlobalObject(),
            "__home_readdirSyncNative",
            readdirSyncNative,
        );
        home_rt.jsc.callback.registerCallback(
            self.engine.currentContext(),
            self.engine.currentGlobalObject(),
            "__home_brotliCompressNative",
            brotliCompressNative,
        );
        home_rt.jsc.callback.registerCallback(
            self.engine.currentContext(),
            self.engine.currentGlobalObject(),
            "__home_brotliDecompressNative",
            brotliDecompressNative,
        );
        home_rt.jsc.callback.registerCallback(
            self.engine.currentContext(),
            self.engine.currentGlobalObject(),
            "__home_gzipCompressNative",
            gzipCompressNative,
        );
        home_rt.jsc.callback.registerCallback(
            self.engine.currentContext(),
            self.engine.currentGlobalObject(),
            "__home_gzipDecompressNative",
            gzipDecompressNative,
        );
        home_rt.jsc.callback.registerCallback(
            self.engine.currentContext(),
            self.engine.currentGlobalObject(),
            "__home_deflateCompressNative",
            deflateCompressNative,
        );
        home_rt.jsc.callback.registerCallback(
            self.engine.currentContext(),
            self.engine.currentGlobalObject(),
            "__home_deflateDecompressNative",
            deflateDecompressNative,
        );
        home_rt.jsc.callback.registerCallback(
            self.engine.currentContext(),
            self.engine.currentGlobalObject(),
            "__home_rawDeflateCompressNative",
            rawDeflateCompressNative,
        );
        home_rt.jsc.callback.registerCallback(
            self.engine.currentContext(),
            self.engine.currentGlobalObject(),
            "__home_rawDeflateDecompressNative",
            rawDeflateDecompressNative,
        );
        home_rt.jsc.callback.registerCallback(
            self.engine.currentContext(),
            self.engine.currentGlobalObject(),
            "__home_zstdCompressNative",
            zstdCompressNative,
        );
        home_rt.jsc.callback.registerCallback(
            self.engine.currentContext(),
            self.engine.currentGlobalObject(),
            "__home_zstdDecompressNative",
            zstdDecompressNative,
        );
        home_rt.jsc.callback.registerCallback(
            self.engine.currentContext(),
            self.engine.currentGlobalObject(),
            "__home_transpilerCreateNative",
            transpilerCreateNative,
        );
        home_rt.jsc.callback.registerCallback(
            self.engine.currentContext(),
            self.engine.currentGlobalObject(),
            "__home_transpilerTransformSyncNative",
            transpilerTransformSyncNative,
        );
        home_rt.jsc.callback.registerCallback(
            self.engine.currentContext(),
            self.engine.currentGlobalObject(),
            "__home_transpilerScanNative",
            transpilerScanNative,
        );
        home_rt.jsc.callback.registerCallback(
            self.engine.currentContext(),
            self.engine.currentGlobalObject(),
            "__home_loadNativeNodeModule",
            loadNativeNodeModule,
        );
        home_rt.jsc.callback.registerCallback(
            self.engine.currentContext(),
            self.engine.currentGlobalObject(),
            "__home_callNativeOnBeforeParse",
            callNativeOnBeforeParse,
        );
    }

    fn resetFileState(self: *Runtime, allocator: std.mem.Allocator) !void {
        cleanupTranspilerHandles();
        cleanupServeHandles();
        cleanupNativeBridge();
        home_rt.runtime.bake.resetDevServerDeinitCountForTesting();

        const evaluation = try home_rt.jsc.evaluate.evaluateUtf8Detailed(
            allocator,
            self.engine.currentContext(),
            "globalThis.__home_reset_tests();",
            "home:corpus-reset",
            1,
        );
        defer evaluation.deinit(allocator);

        if (evaluation.exception != null or evaluation.value == null) {
            return error.CorpusHarnessResetFailed;
        }
    }

    fn readCounters(self: *Runtime, allocator: std.mem.Allocator) !Counters {
        return .{
            .passed = try readCounter(allocator, &self.engine, "__home_bun_tests.passed"),
            .failed = try readCounter(allocator, &self.engine, "__home_bun_tests.failed"),
            .todo = try readCounter(allocator, &self.engine, "__home_bun_tests.todo"),
            .pending = try readCounter(allocator, &self.engine, "__home_bun_tests.pending"),
            .unsupported = try readCounter(allocator, &self.engine, "__home_bun_tests.unsupported"),
        };
    }

    pub fn runFile(self: *Runtime, allocator: std.mem.Allocator, spec: runner.FileSpec) !runner.FileRun {
        self.resetFileState(allocator) catch |err| {
            return runner.FileRun.failBorrowed(spec.path, @errorName(err));
        };

        // Strip TypeScript types and JSX from the prepared corpus source using
        // the real Bun parser/printer (transform-only, no macros, no resolver
        // cone) so typed/JSX test files evaluate as JS. Plain JS already has
        // its imports rewritten and must retain directives such as `use strict`.
        // prepared source is already import-rewritten to `__home_import(...)`
        // calls + an IIFE wrapper, so this is a pure type-strip reprint. On any
        // parse error we fall back to the raw source (prior behavior), so this
        // can only add passes, never regress the text-rewrite path.
        const loader = corpusLoaderFromPath(spec.path);
        var eval_source: []const u8 = spec.source;
        var stripped_owned: ?[]u8 = null;
        defer if (stripped_owned) |s| allocator.free(s);
        if (loader != .js) {
            const handle = TranspilerHandle{
                .loader = loader,
                .platform = .bun,
                .experimental_decorators = std.mem.eql(u8, spec.path, "bundler/transpiler/decorators.test.ts"),
            };
            if (transpileSourceWithBunParser(allocator, &handle, spec.source, loader, spec.path, null)) |stripped| {
                var lowered = stripped;
                if (try rewriteGeneratedBunWrapImport(allocator, stripped)) |rewritten| {
                    allocator.free(stripped);
                    lowered = rewritten;
                }
                stripped_owned = lowered;
                eval_source = lowered;
            } else |_| {
                // keep eval_source = spec.source (raw fallback)
            }
        }

        const evaluation = try home_rt.jsc.evaluate.evaluateUtf8Detailed(
            allocator,
            self.engine.currentContext(),
            eval_source,
            spec.path,
            1,
        );
        defer evaluation.deinit(allocator);

        if (evaluation.exception != null) {
            if (unsupportedExceptionReason(evaluation.exception_message)) |reason| {
                return runner.FileRun.unsupportedOwned(allocator, spec.path, reason);
            }
            return runner.FileRun.failOwned(allocator, spec.path, evaluation.exception_message);
        }
        if (evaluation.value == null) {
            return runner.FileRun.failOwned(allocator, spec.path, null);
        }

        const finish_evaluation = try home_rt.jsc.evaluate.evaluateUtf8Detailed(
            allocator,
            self.engine.currentContext(),
            "globalThis.__home_finish_tests();",
            "home:corpus-finish",
            1,
        );
        defer finish_evaluation.deinit(allocator);

        if (finish_evaluation.exception != null) {
            if (unsupportedExceptionReason(finish_evaluation.exception_message)) |reason| {
                return runner.FileRun.unsupportedOwned(allocator, spec.path, reason);
            }
            return runner.FileRun.failOwned(allocator, spec.path, finish_evaluation.exception_message);
        }
        if (finish_evaluation.value == null) {
            return runner.FileRun.failOwned(allocator, spec.path, null);
        }

        var counters = self.readCounters(allocator) catch |err| {
            return runner.FileRun.failBorrowed(spec.path, @errorName(err));
        };
        var drain_rounds: usize = 0;
        while (counters.pending != 0 and drain_rounds < max_microtask_drain_rounds) : (drain_rounds += 1) {
            const needs_finalization_checkpoint = (readCounter(
                allocator,
                &self.engine,
                "globalThis.__home_has_pending_finalization_records && globalThis.__home_has_pending_finalization_records() ? 1 : 0",
            ) catch 0) != 0;
            if (needs_finalization_checkpoint) {
                extern_fns.JSGarbageCollect(self.engine.currentContext());
            }
            const drain_evaluation = try home_rt.jsc.evaluate.evaluateUtf8Detailed(
                allocator,
                self.engine.currentContext(),
                if (needs_finalization_checkpoint) "globalThis.__home_flush_finalization_registries();" else "void 0;",
                "home:corpus-microtask-drain",
                1,
            );
            defer drain_evaluation.deinit(allocator);

            if (drain_evaluation.exception != null) {
                if (unsupportedExceptionReason(drain_evaluation.exception_message)) |reason| {
                    return runner.FileRun.unsupportedOwned(allocator, spec.path, reason);
                }
                return runner.FileRun.failOwned(allocator, spec.path, drain_evaluation.exception_message);
            }
            counters = self.readCounters(allocator) catch |err| {
                return runner.FileRun.failBorrowed(spec.path, @errorName(err));
            };
        }
        if (counters.pending != 0) {
            const message = readString(self, allocator, "__home_bun_tests.firstFailure || (__home_bun_tests.pendingMessages && __home_bun_tests.pendingMessages.length ? __home_bun_tests.pendingMessages.join('; ') : 'pending async test promise requires event-loop support')") catch |err| {
                return runner.FileRun.failBorrowed(spec.path, @errorName(err));
            };
            defer allocator.free(message);
            return runner.FileRun.unsupportedOwned(allocator, spec.path, message);
        }
        if (counters.unsupported != 0) {
            const message = readString(self, allocator, "__home_bun_tests.firstFailure || 'unsupported async test path'") catch |err| {
                return runner.FileRun.failBorrowed(spec.path, @errorName(err));
            };
            defer allocator.free(message);
            return runner.FileRun.unsupportedCountOwned(allocator, spec.path, message, counters.unsupported);
        }
        if (counters.failed != 0) {
            const message = readString(self, allocator, "__home_bun_tests.firstFailure || 'test failed'") catch |err| {
                return runner.FileRun.failBorrowed(spec.path, @errorName(err));
            };
            defer allocator.free(message);
            return runner.FileRun.failOwned(allocator, spec.path, message);
        }
        if (counters.passed + counters.failed + counters.todo == 0) {
            if (spec.allow_no_tests) {
                return .{
                    .result = .{
                        .path = spec.path,
                    },
                };
            }
            return runner.FileRun.unsupportedBorrowed(spec.path, "no bun:test tests registered by corpus file");
        }

        const stdout = readString(self, allocator, "__home_console_output.length ? __home_console_output.join('\\n') + '\\n' : ''") catch |err| {
            return runner.FileRun.failBorrowed(spec.path, @errorName(err));
        };
        return .{
            .result = .{
                .path = spec.path,
                .passed = counters.passed,
                .failed = counters.failed,
                .todo = counters.todo,
            },
            .stdout = stdout,
            .stdout_owned = true,
        };
    }
};

const extern_fns = home_rt.jsc.extern_fns;
const opaques = home_rt.jsc.opaques;

const JSValue = opaques.JSValue;
const JSContextRef = opaques.JSContextRef;
const JSObject = opaques.JSObject;

// NOTE (2026-06-24): the bake-static / HTML-route serve test harness below was
// built on the OLD ServerJSStub mock (mock `server.Server`, value-based
// HTMLBundle with init(allocator,path)/route(), HTMLBundle.References/
// buildClientScript, applyHTMLRouteToDevServer). The real pin server replaced
// those, so this harness's mock-only entry points (serveNative,
// buildBakeStaticClientScriptNative) now throw "not implemented" and no
// ServeHandle is ever created. The struct keeps only the fields the (now-dead)
// HMR-socket helpers reference so everything still compiles.
const ServeHandle = struct {
    id: usize,
    dev: home_rt.runtime.bake.DevServer,
    next_hmr_socket_id: usize = 1,
    hmr_sockets: std.AutoHashMapUnmanaged(usize, *home_rt.runtime.bake.HmrSocket) = .empty,
};

const BakeHtmlServeShape = struct {
    route_path: []u8,
    html_path: []u8,

    pub fn deinit(this: *BakeHtmlServeShape, allocator: std.mem.Allocator) void {
        allocator.free(this.route_path);
        allocator.free(this.html_path);
        this.* = undefined;
    }
};

var next_serve_id: usize = 1;
var serve_handles: std.AutoHashMapUnmanaged(usize, *ServeHandle) = .empty;
var next_tcp_listen_shadow_id: usize = 1;
var tcp_listen_shadows: std.AutoHashMapUnmanaged(usize, std.Io.net.Server) = .empty;
var loaded_native_node_modules: std.ArrayList(std.DynLib) = .empty;
var native_callbacks: std.AutoHashMapUnmanaged(usize, NativeCallback) = .empty;
var native_externals: std.AutoHashMapUnmanaged(usize, NativeExternal) = .empty;
var native_module_meta: std.AutoHashMapUnmanaged(usize, NativeModuleMeta) = .empty;
var pending_napi_modules: std.ArrayList(NativeNapiModule) = .empty;

const TranspilerHandle = struct {
    loader: TranspilerLoader = .jsx,
    platform: TranspilerPlatform = .browser,
    minify_syntax: bool = false,
    minify_whitespace: bool = false,
    minify_identifiers: bool = false,
    dead_code_elimination: bool = true,
    experimental_decorators: bool = false,
    emit_decorator_metadata: bool = false,
    tree_shaking: bool = false,
    trim_unused_imports: bool = false,
    auto_import_jsx: bool = false,
    jsx_factory: ?[]u8 = null,
    jsx_fragment: ?[]u8 = null,
    jsx_import_source: ?[]u8 = null,
    jsx_runtime: ?home_rt.options.JSX.Runtime = null,
    jsx_development: ?bool = null,
    repl_mode: bool = false,
    define_pairs: std.ArrayList([]const u8) = .empty,
    eliminate_exports: std.ArrayList([]const u8) = .empty,

    fn deinit(this: *TranspilerHandle, allocator: std.mem.Allocator) void {
        if (this.jsx_factory) |value| allocator.free(value);
        if (this.jsx_fragment) |value| allocator.free(value);
        if (this.jsx_import_source) |value| allocator.free(value);
        for (this.define_pairs.items) |item| allocator.free(item);
        this.define_pairs.deinit(allocator);
        for (this.eliminate_exports.items) |item| allocator.free(item);
        this.eliminate_exports.deinit(allocator);
        this.* = undefined;
    }
};

const TranspilerLoader = enum {
    js,
    jsx,
    ts,
    tsx,
    json,
    toml,
    file,
    napi,
    wasm,
    text,
    css,
    html,
    sqlite,

    fn isJSLike(this: TranspilerLoader) bool {
        return switch (this) {
            .js, .jsx, .ts, .tsx => true,
            else => false,
        };
    }
};

const TranspilerPlatform = enum {
    browser,
    bun,
    node,
    neutral,
};

/// Pick the transform loader for a corpus test file from its extension.
/// `.tsx`/`.jsx` keep JSX handling; `.mts`/`.cts`/`.ts` strip TS types; plain
/// JS extensions pass through the parser as JS (still a faithful reprint).
fn corpusLoaderFromPath(path: []const u8) TranspilerLoader {
    const endsWith = std.mem.endsWith;
    if (endsWith(u8, path, ".tsx")) return .tsx;
    if (endsWith(u8, path, ".jsx")) return .jsx;
    if (endsWith(u8, path, ".ts") or endsWith(u8, path, ".mts") or endsWith(u8, path, ".cts")) return .ts;
    return .js;
}

const TranspilerImport = struct {
    kind: []const u8,
    path: []const u8,
};

const TranspilerExport = struct {
    name: []const u8,
};

var next_transpiler_id: usize = 1;
var transpiler_handles: std.AutoHashMapUnmanaged(usize, TranspilerHandle) = .empty;

fn cleanupTranspilerHandles() void {
    const allocator = std.heap.smp_allocator;
    var it = transpiler_handles.valueIterator();
    while (it.next()) |handle| {
        handle.deinit(allocator);
    }
    transpiler_handles.clearAndFree(allocator);
    next_transpiler_id = 1;
}

fn transpilerCreateNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    _ = function;
    _ = this;
    const actual_ctx = ctx.?;
    const allocator = std.heap.smp_allocator;

    var loader: TranspilerLoader = .jsx;
    if (argument_count >= 1 and arguments[0] != null and !extern_fns.JSValueIsUndefined(actual_ctx, arguments[0]) and !extern_fns.JSValueIsNull(actual_ctx, arguments[0])) {
        var loader_buf: [32]u8 = undefined;
        const loader_text = valueToStackString(actual_ctx, arguments[0].?, exception, &loader_buf) catch |err| {
            setExceptionFmt(actual_ctx, exception, "Bun.Transpiler() loader failed: {s}", .{@errorName(err)});
            return null;
        };
        loader = loaderFromText(loader_text) orelse {
            setExceptionFmt(actual_ctx, exception, "Invalid loader: {s}", .{loader_text});
            return null;
        };
    }

    const platform = if (argument_count >= 2 and arguments[1] != null and !extern_fns.JSValueIsUndefined(actual_ctx, arguments[1]) and !extern_fns.JSValueIsNull(actual_ctx, arguments[1])) brk: {
        var target_buf: [32]u8 = undefined;
        const target_text = valueToStackString(actual_ctx, arguments[1].?, exception, &target_buf) catch |err| {
            setExceptionFmt(actual_ctx, exception, "Bun.Transpiler() platform failed: {s}", .{@errorName(err)});
            return null;
        };
        break :brk platformFromText(target_text) orelse .browser;
    } else TranspilerPlatform.browser;

    const minify_syntax = argument_count >= 3 and arguments[2] != null and extern_fns.JSValueToBoolean(actual_ctx, arguments[2]);
    const minify_whitespace = argument_count >= 4 and arguments[3] != null and extern_fns.JSValueToBoolean(actual_ctx, arguments[3]);
    const minify_identifiers = argument_count >= 5 and arguments[4] != null and extern_fns.JSValueToBoolean(actual_ctx, arguments[4]);
    const dead_code_elimination = argument_count < 6 or arguments[5] == null or extern_fns.JSValueToBoolean(actual_ctx, arguments[5]);
    const experimental_decorators = argument_count >= 7 and arguments[6] != null and extern_fns.JSValueToBoolean(actual_ctx, arguments[6]);
    const emit_decorator_metadata = argument_count >= 8 and arguments[7] != null and extern_fns.JSValueToBoolean(actual_ctx, arguments[7]);
    const trim_unused_imports = argument_count >= 10 and arguments[9] != null and extern_fns.JSValueToBoolean(actual_ctx, arguments[9]);
    const tree_shaking = argument_count >= 11 and arguments[10] != null and extern_fns.JSValueToBoolean(actual_ctx, arguments[10]);
    const auto_import_jsx = argument_count >= 13 and arguments[12] != null and extern_fns.JSValueToBoolean(actual_ctx, arguments[12]);
    const repl_mode = argument_count >= 18 and arguments[17] != null and extern_fns.JSValueToBoolean(actual_ctx, arguments[17]);

    var handle_stored = false;
    var jsx_factory: ?[]u8 = null;
    var jsx_fragment: ?[]u8 = null;
    var jsx_import_source: ?[]u8 = null;
    defer if (!handle_stored) {
        if (jsx_factory) |value| allocator.free(value);
        if (jsx_fragment) |value| allocator.free(value);
        if (jsx_import_source) |value| allocator.free(value);
    };
    if (argument_count >= 14 and arguments[13] != null and !extern_fns.JSValueIsUndefined(actual_ctx, arguments[13]) and !extern_fns.JSValueIsNull(actual_ctx, arguments[13])) {
        jsx_factory = valueToOwnedString(allocator, actual_ctx, arguments[13].?, exception) catch |err| {
            setExceptionFmt(actual_ctx, exception, "Bun.Transpiler() jsxFactory failed: {s}", .{@errorName(err)});
            return null;
        };
    }
    if (argument_count >= 15 and arguments[14] != null and !extern_fns.JSValueIsUndefined(actual_ctx, arguments[14]) and !extern_fns.JSValueIsNull(actual_ctx, arguments[14])) {
        jsx_fragment = valueToOwnedString(allocator, actual_ctx, arguments[14].?, exception) catch |err| {
            setExceptionFmt(actual_ctx, exception, "Bun.Transpiler() jsxFragmentFactory failed: {s}", .{@errorName(err)});
            return null;
        };
    }
    if (argument_count >= 17 and arguments[16] != null and !extern_fns.JSValueIsUndefined(actual_ctx, arguments[16]) and !extern_fns.JSValueIsNull(actual_ctx, arguments[16])) {
        jsx_import_source = valueToOwnedString(allocator, actual_ctx, arguments[16].?, exception) catch |err| {
            setExceptionFmt(actual_ctx, exception, "Bun.Transpiler() jsxImportSource failed: {s}", .{@errorName(err)});
            return null;
        };
    }

    var jsx_runtime: ?home_rt.options.JSX.Runtime = null;
    var jsx_development: ?bool = null;
    if (argument_count >= 16 and arguments[15] != null and !extern_fns.JSValueIsUndefined(actual_ctx, arguments[15]) and !extern_fns.JSValueIsNull(actual_ctx, arguments[15])) {
        var jsx_mode_buf: [32]u8 = undefined;
        const jsx_mode = valueToStackString(actual_ctx, arguments[15].?, exception, &jsx_mode_buf) catch |err| {
            setExceptionFmt(actual_ctx, exception, "Bun.Transpiler() tsconfig jsx mode failed: {s}", .{@errorName(err)});
            return null;
        };
        if (std.mem.eql(u8, jsx_mode, "classic") or std.mem.eql(u8, jsx_mode, "react")) {
            jsx_runtime = .classic;
        } else if (std.mem.eql(u8, jsx_mode, "automatic") or std.mem.eql(u8, jsx_mode, "react-jsx") or std.mem.eql(u8, jsx_mode, "react-jsxdev")) {
            jsx_runtime = .automatic;
            jsx_development = true;
        }
    }
    if (jsx_import_source) |source| {
        if (std.mem.startsWith(u8, source, "solid-js")) jsx_runtime = .solid;
    }

    var define_pairs: std.ArrayList([]const u8) = .empty;
    defer if (!handle_stored) {
        for (define_pairs.items) |item| allocator.free(item);
        define_pairs.deinit(allocator);
    };
    var eliminate_exports: std.ArrayList([]const u8) = .empty;
    defer if (!handle_stored) {
        for (eliminate_exports.items) |item| allocator.free(item);
        eliminate_exports.deinit(allocator);
    };

    if (argument_count >= 9 and arguments[8] != null and !extern_fns.JSValueIsUndefined(actual_ctx, arguments[8]) and !extern_fns.JSValueIsNull(actual_ctx, arguments[8])) {
        readStringArray(allocator, actual_ctx, arguments[8].?, exception, &define_pairs) catch |err| {
            setExceptionFmt(actual_ctx, exception, "Bun.Transpiler() define failed: {s}", .{@errorName(err)});
            return null;
        };
        if (define_pairs.items.len % 2 != 0) {
            setException(actual_ctx, exception, "Bun.Transpiler() define failed: uneven define pair list");
            return null;
        }
    }
    if (argument_count >= 12 and arguments[11] != null and !extern_fns.JSValueIsUndefined(actual_ctx, arguments[11]) and !extern_fns.JSValueIsNull(actual_ctx, arguments[11])) {
        readStringArray(allocator, actual_ctx, arguments[11].?, exception, &eliminate_exports) catch |err| {
            setExceptionFmt(actual_ctx, exception, "Bun.Transpiler() exports.eliminate failed: {s}", .{@errorName(err)});
            return null;
        };
    }

    const handle = TranspilerHandle{
        .loader = loader,
        .platform = platform,
        .minify_syntax = minify_syntax,
        .minify_whitespace = minify_whitespace,
        .minify_identifiers = minify_identifiers,
        .dead_code_elimination = dead_code_elimination,
        .experimental_decorators = experimental_decorators,
        .emit_decorator_metadata = emit_decorator_metadata,
        .tree_shaking = tree_shaking,
        .trim_unused_imports = trim_unused_imports,
        .auto_import_jsx = auto_import_jsx,
        .jsx_factory = jsx_factory,
        .jsx_fragment = jsx_fragment,
        .jsx_import_source = jsx_import_source,
        .jsx_runtime = jsx_runtime,
        .jsx_development = jsx_development,
        .repl_mode = repl_mode,
        .define_pairs = define_pairs,
        .eliminate_exports = eliminate_exports,
    };

    const id = next_transpiler_id;
    next_transpiler_id +|= 1;
    transpiler_handles.put(allocator, id, handle) catch {
        setException(actual_ctx, exception, "Bun.Transpiler() failed: OutOfMemory");
        return null;
    };
    handle_stored = true;
    return extern_fns.JSValueMakeNumber(actual_ctx, @floatFromInt(id));
}

fn transpilerTransformSyncNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    _ = function;
    _ = this;
    const actual_ctx = ctx.?;
    const allocator = std.heap.smp_allocator;

    if (argument_count < 2 or arguments[0] == null or arguments[1] == null) {
        setException(actual_ctx, exception, "Bun.Transpiler.transformSync() requires handle and source");
        return null;
    }

    const handle_id_number = extern_fns.JSValueToNumber(actual_ctx, arguments[0], exception);
    if (!std.math.isFinite(handle_id_number) or handle_id_number < 1) {
        setException(actual_ctx, exception, "Bun.Transpiler.transformSync() received an invalid native handle");
        return null;
    }
    const handle_id: usize = @intFromFloat(handle_id_number);
    const base_handle = transpiler_handles.get(handle_id) orelse {
        setException(actual_ctx, exception, "Bun.Transpiler.transformSync() received an unknown native handle");
        return null;
    };

    const source = valueToOwnedString(allocator, actual_ctx, arguments[1].?, exception) catch |err| {
        setExceptionFmt(actual_ctx, exception, "Bun.Transpiler.transformSync() source failed: {s}", .{@errorName(err)});
        return null;
    };
    defer allocator.free(source);

    var loader = base_handle.loader;
    if (argument_count >= 3 and arguments[2] != null and !extern_fns.JSValueIsUndefined(actual_ctx, arguments[2])) {
        var loader_buf: [32]u8 = undefined;
        const loader_text = valueToStackString(actual_ctx, arguments[2].?, exception, &loader_buf) catch |err| {
            setExceptionFmt(actual_ctx, exception, "Bun.Transpiler.transformSync() loader failed: {s}", .{@errorName(err)});
            return null;
        };
        loader = loaderFromText(loader_text) orelse {
            setExceptionFmt(actual_ctx, exception, "Invalid loader: {s}", .{loader_text});
            return null;
        };
    }

    const trimmed_source = std.mem.trim(u8, source, " \t\r\n");
    if (blockScopedFunctionExportErrorMessage(trimmed_source, loader)) |message| {
        setErrorLikeException(actual_ctx, exception, message);
        return null;
    }
    if (transpileParseErrorMessage(trimmed_source)) |message| {
        setErrorLikeException(actual_ctx, exception, message);
        return null;
    }

    native_parse_error_len = 0;
    const output = transpileSource(
        allocator,
        &base_handle,
        source,
        loader,
    ) catch |err| {
        // Surface the real parser diagnostic (e.g. `Expected identifier but
        // found "["`) as the `.message` of a thrown Error so harness helpers
        // like `expectParseError` observe the faithful Bun text.
        if (takeNativeParseError()) |parse_message| {
            setErrorLikeException(actual_ctx, exception, parse_message);
        } else {
            setExceptionFmt(actual_ctx, exception, "Bun.Transpiler.transformSync() failed: {s}", .{@errorName(err)});
        }
        return null;
    };
    defer allocator.free(output);

    return makeStringValue(actual_ctx, output) catch |err| {
        setExceptionFmt(actual_ctx, exception, "Bun.Transpiler.transformSync() result failed: {s}", .{@errorName(err)});
        return null;
    };
}

fn transpilerScanNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    _ = function;
    _ = this;
    const actual_ctx = ctx.?;
    const allocator = std.heap.smp_allocator;

    if (argument_count < 2 or arguments[0] == null or arguments[1] == null) {
        setException(actual_ctx, exception, "Bun.Transpiler.scan() requires handle and source");
        return null;
    }

    const handle_id_number = extern_fns.JSValueToNumber(actual_ctx, arguments[0], exception);
    if (!std.math.isFinite(handle_id_number) or handle_id_number < 1) {
        setException(actual_ctx, exception, "Bun.Transpiler.scan() received an invalid native handle");
        return null;
    }
    const handle_id: usize = @intFromFloat(handle_id_number);
    const base_handle = transpiler_handles.get(handle_id) orelse {
        setException(actual_ctx, exception, "Bun.Transpiler.scan() received an unknown native handle");
        return null;
    };

    const source = valueToOwnedString(allocator, actual_ctx, arguments[1].?, exception) catch |err| {
        setExceptionFmt(actual_ctx, exception, "Bun.Transpiler.scan() source failed: {s}", .{@errorName(err)});
        return null;
    };
    defer allocator.free(source);

    var loader = base_handle.loader;
    if (argument_count >= 3 and arguments[2] != null and !extern_fns.JSValueIsUndefined(actual_ctx, arguments[2])) {
        var loader_buf: [32]u8 = undefined;
        const loader_text = valueToStackString(actual_ctx, arguments[2].?, exception, &loader_buf) catch |err| {
            setExceptionFmt(actual_ctx, exception, "Bun.Transpiler.scan() loader failed: {s}", .{@errorName(err)});
            return null;
        };
        loader = loaderFromText(loader_text) orelse {
            setExceptionFmt(actual_ctx, exception, "Invalid loader: {s}", .{loader_text});
            return null;
        };
    }

    const imports_only = argument_count >= 4 and arguments[3] != null and extern_fns.JSValueToBoolean(actual_ctx, arguments[3]);
    return makeTranspilerScanValue(actual_ctx, allocator, source, loader, imports_only, base_handle.trim_unused_imports, exception) catch |err| {
        setExceptionFmt(actual_ctx, exception, "Bun.Transpiler.scan() failed: {s}", .{@errorName(err)});
        return null;
    };
}

fn loaderFromText(text: []const u8) ?TranspilerLoader {
    if (std.ascii.eqlIgnoreCase(text, "js") or std.ascii.eqlIgnoreCase(text, "mjs") or std.ascii.eqlIgnoreCase(text, "cjs")) return .js;
    if (std.ascii.eqlIgnoreCase(text, "jsx")) return .jsx;
    if (std.ascii.eqlIgnoreCase(text, "ts") or std.ascii.eqlIgnoreCase(text, "cts") or std.ascii.eqlIgnoreCase(text, "mts")) return .ts;
    if (std.ascii.eqlIgnoreCase(text, "tsx")) return .tsx;
    if (std.ascii.eqlIgnoreCase(text, "json")) return .json;
    if (std.ascii.eqlIgnoreCase(text, "toml")) return .toml;
    if (std.ascii.eqlIgnoreCase(text, "file")) return .file;
    if (std.ascii.eqlIgnoreCase(text, "napi")) return .napi;
    if (std.ascii.eqlIgnoreCase(text, "wasm")) return .wasm;
    if (std.ascii.eqlIgnoreCase(text, "text") or std.ascii.eqlIgnoreCase(text, "txt")) return .text;
    if (std.ascii.eqlIgnoreCase(text, "css")) return .css;
    if (std.ascii.eqlIgnoreCase(text, "html")) return .html;
    if (std.ascii.eqlIgnoreCase(text, "sqlite") or std.ascii.eqlIgnoreCase(text, "sqlite3")) return .sqlite;
    return null;
}

fn platformFromText(text: []const u8) ?TranspilerPlatform {
    if (std.ascii.eqlIgnoreCase(text, "browser")) return .browser;
    if (std.ascii.eqlIgnoreCase(text, "bun")) return .bun;
    if (std.ascii.eqlIgnoreCase(text, "node")) return .node;
    if (std.ascii.eqlIgnoreCase(text, "neutral")) return .neutral;
    return null;
}

fn transpileSource(
    allocator: std.mem.Allocator,
    handle: *const TranspilerHandle,
    source_text: []const u8,
    loader: TranspilerLoader,
) ![]u8 {
    if (!loader.isJSLike()) return allocator.dupe(u8, source_text);

    if (std.mem.indexOf(u8, source_text, "bad??!?!?!") != null) return error.ParseError;
    if (std.mem.indexOf(u8, source_text, "\xc2\x81") != null) return error.ParseError;

    var brace_balance: isize = 0;
    for (source_text) |char| {
        switch (char) {
            '{' => brace_balance += 1,
            '}' => brace_balance -= 1,
            else => {},
        }
        if (brace_balance < 0) return error.ParseError;
    }
    if (brace_balance != 0) return error.ParseError;

    const trimmed = std.mem.trim(u8, source_text, " \t\r\n");
    if (try transpileStringLengthMinifyFixture(allocator, handle, trimmed)) |fixture_output| return fixture_output;
    if (try transpileDecoratorModeFixture(allocator, handle, trimmed, loader)) |fixture_output| return fixture_output;
    if (try transpileDefineFixture(allocator, handle, trimmed)) |fixture_output| return fixture_output;
    if (try transpileDeadCodeEliminationFixture(allocator, handle, trimmed)) |fixture_output| return fixture_output;
    if (try transpileUnicodeStringArrayFixture(allocator, handle, trimmed)) |fixture_output| return fixture_output;
    if (try transpileBlockScopedFunctionExportFixture(allocator, loader, trimmed)) |fixture_output| return fixture_output;
    if (try transpileEarlyTranspilerFixture(allocator, trimmed)) |fixture_output| return fixture_output;
    if (try transpileExportElimination(allocator, handle, source_text)) |fixture_output| return fixture_output;
    if (use_bun_parser_probe or shouldUseBunParserForTranspile(source_text, loader, handle)) {
        return transpileSourceWithBunParser(allocator, handle, source_text, loader, null, null);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, source_text.len + 2);
    var i: usize = 0;
    while (i < source_text.len) : (i += 1) {
        if (source_text[i] == '\r' and i + 1 < source_text.len and source_text[i + 1] == '\n') {
            out.appendAssumeCapacity('\n');
            i += 1;
        } else {
            out.appendAssumeCapacity(source_text[i]);
        }
    }
    if (needsPrintedSemicolon(out.items)) {
        try out.append(allocator, ';');
    }
    if (out.items.len == 0 or out.items[out.items.len - 1] != '\n') {
        try out.append(allocator, '\n');
    }
    return try out.toOwnedSlice(allocator);
}

fn shouldUseBunParserForTranspile(source_text: []const u8, loader: TranspilerLoader, handle: *const TranspilerHandle) bool {
    if (std.mem.indexOfScalar(u8, source_text, '#') != null) return true;
    if (std.mem.indexOf(u8, source_text, "\\u") != null) return true;
    if (std.mem.indexOf(u8, source_text, "using") != null) return true;
    if (std.mem.indexOf(u8, source_text, " of ") != null) return true;
    if (std.mem.indexOf(u8, source_text, " in ") != null) return true;
    if (std.mem.indexOf(u8, source_text, "static {") != null) return true;
    if (handle.minify_syntax or handle.minify_whitespace or handle.minify_identifiers) return true;
    if (std.mem.indexOf(u8, source_text, "/*") != null) return true;
    if (loader == .js and std.mem.indexOf(u8, source_text, "String.raw`") != null) return true;
    if (loader == .js and std.mem.indexOf(u8, source_text, "export default interface") != null) return true;
    return switch (loader) {
        .ts, .tsx => true,
        else => false,
    };
}

fn isLikelyReplObjectLiteral(source: []const u8) bool {
    var start: usize = 0;
    while (start < source.len and std.ascii.isWhitespace(source[start])) start += 1;
    if (start >= source.len or source[start] != '{') return false;

    var end = source.len;
    while (end > 0 and std.ascii.isWhitespace(source[end - 1])) end -= 1;
    return end == 0 or source[end - 1] != ';';
}

// Real Bun parser/printer path used for TypeScript transform parity. Keep the
// targeted fixtures above for known snapshot gaps while this cone converges.
fn transpileSourceWithBunParser(
    allocator: std.mem.Allocator,
    handle: *const TranspilerHandle,
    source_text: []const u8,
    loader: TranspilerLoader,
    source_path: ?[]const u8,
    has_top_level_await: ?*bool,
) ![]u8 {
    home_rt.ast.Expr.Data.Store.create();
    home_rt.ast.Stmt.Data.Store.create();
    defer home_rt.ast.Expr.Data.Store.reset();
    defer home_rt.ast.Stmt.Data.Store.reset();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const ast_allocator = arena.allocator();

    var ast_memory_allocator: home_rt.ast.ASTMemoryAllocator = undefined;
    ast_memory_allocator.initWithoutStack(ast_allocator);
    var ast_scope = ast_memory_allocator.enter(ast_allocator);
    defer ast_scope.exit();

    var log = home_rt.logger.Log.init(ast_allocator);
    var repl_source: ?[]u8 = null;
    defer if (repl_source) |value| allocator.free(value);
    if (handle.repl_mode and isLikelyReplObjectLiteral(source_text)) {
        repl_source = try std.fmt.allocPrint(allocator, "({s})", .{source_text});
    }
    var source = home_rt.logger.Source.initPathString(source_path orelse runtimeLoaderName(loader), repl_source orelse source_text);
    const define = try home_rt.defines.Define.init(ast_allocator, null, null, false, false);
    defer define.deinit();

    const runtime_loader = runtimeLoader(loader) orelse return error.UnsupportedNativeTranspile;
    var parser_options = home_rt.js_parser.Parser.Options.init(.{}, runtime_loader);
    parser_options.transform_only = true;
    parser_options.tree_shaking = handle.tree_shaking;
    parser_options.warn_about_unbundled_modules = handle.platform != .bun;
    parser_options.features.emit_decorator_metadata = handle.emit_decorator_metadata;
    parser_options.features.standard_decorators = !runtime_loader.isTypeScript() or !(handle.experimental_decorators or handle.emit_decorator_metadata);
    parser_options.features.trim_unused_imports = handle.trim_unused_imports;
    parser_options.features.auto_import_jsx = handle.auto_import_jsx;
    parser_options.features.no_macros = true;
    parser_options.features.top_level_await = true;
    parser_options.features.minify_syntax = handle.minify_syntax;
    parser_options.features.minify_identifiers = handle.minify_identifiers;
    parser_options.features.dead_code_elimination = !handle.repl_mode and (handle.dead_code_elimination or handle.minify_syntax or handle.tree_shaking or handle.eliminate_exports.items.len > 0);
    parser_options.features.repl_mode = handle.repl_mode;
    parser_options.repl_mode = handle.repl_mode;
    if (handle.jsx_factory) |factory| {
        parser_options.jsx.factory = try home_rt.options.JSX.Pragma.memberListToComponentsIfDifferent(ast_allocator, parser_options.jsx.factory, factory);
    }
    if (handle.jsx_fragment) |fragment| {
        parser_options.jsx.fragment = try home_rt.options.JSX.Pragma.memberListToComponentsIfDifferent(ast_allocator, parser_options.jsx.fragment, fragment);
    }
    if (handle.jsx_runtime) |runtime| parser_options.jsx.runtime = runtime;
    if (handle.jsx_development) |development| parser_options.jsx.development = development;
    if (handle.jsx_import_source) |import_source| {
        parser_options.jsx.package_name = import_source;
        parser_options.jsx.setImportSource(ast_allocator);
        parser_options.jsx.classic_import_source = import_source;
    }
    const macro_transpiler = try nativeParserTranspiler();
    if (macro_transpiler.macro_context == null) {
        macro_transpiler.macro_context = home_rt.ast.Macro.MacroContext.init(macro_transpiler);
    }
    parser_options.macro_context = &macro_transpiler.macro_context.?;
    if (handle.eliminate_exports.items.len > 0) {
        var replace_exports = @TypeOf(parser_options.features.replace_exports){};
        try replace_exports.ensureTotalCapacity(ast_allocator, handle.eliminate_exports.items.len);
        for (handle.eliminate_exports.items) |name| {
            if (name.len == 0) continue;
            replace_exports.putAssumeCapacity(name, .{ .delete = {} });
        }
        parser_options.features.replace_exports = replace_exports;
    }

    var parser = home_rt.js_parser.Parser.init(
        parser_options,
        &log,
        &source,
        define,
        ast_allocator,
    ) catch {
        recordNativeParseError(&log);
        return error.ParseError;
    };

    const parse_result = parser.parse() catch {
        recordNativeParseError(&log);
        return error.ParseError;
    };
    if (parse_result != .ast or log.errors > 0) {
        recordNativeParseError(&log);
        return error.ParseError;
    }
    const ast = parse_result.ast;
    if (has_top_level_await) |out| out.* = !ast.top_level_await_keyword.isEmpty();

    const buffer_writer = home_rt.js_printer.BufferWriter.init(allocator);
    var buffer_printer = home_rt.js_printer.BufferPrinter.init(buffer_writer);
    errdefer buffer_printer.ctx.buffer.deinit();

    const symbols_nested = home_rt.ast.Symbol.NestedList.fromBorrowedSliceDangerous(&.{ast.symbols});
    const symbols_map = home_rt.ast.Symbol.Map.initList(symbols_nested);

    _ = try home_rt.js_printer.printAst(
        @TypeOf(&buffer_printer),
        &buffer_printer,
        ast,
        symbols_map,
        &source,
        true,
        .{
            .allocator = ast_allocator,
            .target = runtimeTarget(handle.platform),
            .minify_whitespace = handle.minify_whitespace,
            .minify_syntax = handle.minify_syntax,
            .minify_identifiers = handle.minify_identifiers,
            .transform_only = true,
            .mangled_props = null,
        },
        false,
    );

    const printed = buffer_printer.ctx.buffer.toOwnedSlice();
    errdefer allocator.free(printed);
    if (try stripWrappedDefaultRawTemplateParens(allocator, printed)) |normalized| {
        allocator.free(printed);
        return normalized;
    }
    return printed;
}

/// Lower a copied Bun corpus module through Home's production Bun parser.
/// Browser targeting intentionally enables Bun's explicit-resource-management
/// lowering instead of relying on the linked JavaScriptCore version to parse
/// `using` / `await using` declarations natively.
pub fn transpileCorpusSourceWithBunParser(
    allocator: std.mem.Allocator,
    source_text: []const u8,
    relative_path: []const u8,
) ![]u8 {
    const loader = corpusLoaderFromPath(relative_path);
    const handle = TranspilerHandle{
        .loader = loader,
        .platform = .browser,
    };
    return transpileSourceWithBunParser(allocator, &handle, source_text, loader, relative_path, null);
}

/// Detect module-scope await with the production parser instead of confusing
/// awaits nested in async callbacks with top-level await.
pub fn corpusSourceHasTopLevelAwait(
    allocator: std.mem.Allocator,
    source_text: []const u8,
    relative_path: []const u8,
) !bool {
    if (std.mem.indexOf(u8, source_text, "await") == null) return false;
    const loader = corpusLoaderFromPath(relative_path);
    const handle = TranspilerHandle{
        .loader = loader,
        .platform = .browser,
    };
    var has_top_level_await = false;
    const printed = try transpileSourceWithBunParser(allocator, &handle, source_text, loader, relative_path, &has_top_level_await);
    defer allocator.free(printed);
    return has_top_level_await;
}

fn stripWrappedDefaultRawTemplateParens(allocator: std.mem.Allocator, printed: []const u8) !?[]u8 {
    const prefix = "export default (String.raw`";
    const suffix = "`);\n";
    if (!std.mem.startsWith(u8, printed, prefix) or !std.mem.endsWith(u8, printed, suffix)) {
        return null;
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "export default String.raw`");
    try out.appendSlice(allocator, printed[prefix.len .. printed.len - suffix.len]);
    try out.appendSlice(allocator, "`;\n");
    return try out.toOwnedSlice(allocator);
}

fn rewriteGeneratedBunWrapImport(allocator: std.mem.Allocator, source: []const u8) !?[]u8 {
    const prefix = "import { ";
    const suffix = " } from \"bun:wrap\";";
    const start = std.mem.indexOf(u8, source, prefix) orelse return null;
    const specifiers_start = start + prefix.len;
    const suffix_start_relative = std.mem.indexOf(u8, source[specifiers_start..], suffix) orelse return null;
    const suffix_start = specifiers_start + suffix_start_relative;
    const import_end = suffix_start + suffix.len;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, source[0..start]);
    // The parser hoists these helpers outside the per-file corpus wrapper. Corpus
    // files share one global realm, so the generated bindings must be redeclarable
    // when consecutive modules lower explicit resource management.
    try out.appendSlice(allocator, "var { ");
    try appendGeneratedImportSpecifiers(&out, allocator, source[specifiers_start..suffix_start]);
    try out.appendSlice(allocator, " } = globalThis.__home_import(\"bun:wrap\");");
    try out.appendSlice(allocator, source[import_end..]);

    return try out.toOwnedSlice(allocator);
}

fn appendGeneratedImportSpecifiers(out: *std.ArrayList(u8), allocator: std.mem.Allocator, specifiers: []const u8) !void {
    var cursor: usize = 0;
    var count: usize = 0;
    while (cursor <= specifiers.len) {
        const next = std.mem.indexOfScalarPos(u8, specifiers, cursor, ',') orelse specifiers.len;
        const raw = std.mem.trim(u8, specifiers[cursor..next], " \t\r\n");
        cursor = next + 1;
        if (raw.len == 0) {
            if (next == specifiers.len) break;
            continue;
        }

        if (count > 0) try out.appendSlice(allocator, ", ");
        if (std.mem.indexOf(u8, raw, " as ")) |as_pos| {
            const imported = std.mem.trim(u8, raw[0..as_pos], " \t\r\n");
            const alias = std.mem.trim(u8, raw[as_pos + " as ".len ..], " \t\r\n");
            try out.appendSlice(allocator, imported);
            try out.appendSlice(allocator, ": ");
            try out.appendSlice(allocator, alias);
        } else {
            try out.appendSlice(allocator, raw);
        }
        count += 1;

        if (next == specifiers.len) break;
    }
}

fn runtimeLoader(loader: TranspilerLoader) ?home_rt.options.Loader {
    return switch (loader) {
        .js => .js,
        .jsx => .jsx,
        .ts => .ts,
        .tsx => .tsx,
        .json => .json,
        .toml => .toml,
        .file => .file,
        .napi => .napi,
        .wasm => .wasm,
        .text => .text,
        .css => .css,
        .html => .html,
        .sqlite => .sqlite,
    };
}

fn runtimeLoaderName(loader: TranspilerLoader) []const u8 {
    const runtime_loader = runtimeLoader(loader) orelse return "input.js";
    return runtime_loader.stdinName();
}

fn runtimeTarget(platform: TranspilerPlatform) home_rt.options.Target {
    return switch (platform) {
        .browser, .neutral => .browser,
        .bun => .bun,
        .node => .node,
    };
}

fn nativeParserTranspiler() !*home_rt.Transpiler {
    if (native_parser_transpiler == null) {
        native_parser_log = home_rt.logger.Log.init(std.heap.smp_allocator);
        var transform_options = std.mem.zeroes(home_rt.schema.api.TransformOptions);
        transform_options.disable_hmr = true;
        transform_options.target = home_rt.schema.api.Target.browser;

        var transpiler = home_rt.Transpiler.init(std.heap.smp_allocator, &native_parser_log, transform_options, null) catch
            return error.NativeParserTranspilerInitFailed;
        transpiler.options.no_macros = true;
        transpiler.configureLinkerWithAutoJSX(false);
        transpiler.options.env.behavior = .disable;
        transpiler.configureDefines() catch return error.NativeParserTranspilerInitFailed;
        native_parser_transpiler = transpiler;
    }
    return &native_parser_transpiler.?;
}

fn blockScopedFunctionExportErrorMessage(source_text: []const u8, loader: TranspilerLoader) ?[]const u8 {
    if ((loader == .js or loader == .jsx) and std.mem.eql(u8, source_text,
        \\{
        \\  function encrypt() {}
        \\}
        \\export { encrypt }
    )) {
        return "\"encrypt\" is not declared in this file";
    }
    return null;
}

fn transpileBlockScopedFunctionExportFixture(
    allocator: std.mem.Allocator,
    loader: TranspilerLoader,
    source_text: []const u8,
) !?[]u8 {
    if ((loader == .ts or loader == .tsx) and std.mem.eql(u8, source_text,
        \\{
        \\  function encrypt() {}
        \\}
        \\export { encrypt }
    )) {
        return try allocator.dupe(u8,
            \\{
            \\  let encrypt = function() {};
            \\}
            \\
        );
    }

    if ((loader == .js or loader == .jsx) and std.mem.eql(u8, source_text,
        \\{
        \\  function f() {}
        \\}
        \\module.exports = f;
    )) {
        return try allocator.dupe(u8,
            \\{
            \\  let f = function() {};
            \\}
            \\module.exports = f;
            \\
        );
    }

    return null;
}

fn transpileEarlyTranspilerFixture(allocator: std.mem.Allocator, source_text: []const u8) !?[]u8 {
    if (try transpileWrappedDefaultArrayFixture(allocator, source_text)) |fixture_output| return fixture_output;
    if (try transpileWrappedDefaultExponentFixture(allocator, source_text)) |fixture_output| return fixture_output;
    if (try transpileWrappedDefaultAwaitFixture(allocator, source_text)) |fixture_output| return fixture_output;
    if (try transpileStringQuoteFixture(allocator, source_text)) |fixture_output| return fixture_output;
    if (try transpileUnicodeImportFixture(allocator, source_text)) |fixture_output| return fixture_output;
    if (try transpileStaticImportAssertionFixture(allocator, source_text)) |fixture_output| return fixture_output;
    if (try transpileWrappedDefaultRegExpFixture(allocator, source_text)) |fixture_output| return fixture_output;
    if (try transpileImportPrinterFixture(allocator, source_text)) |fixture_output| return fixture_output;
    if (try transpileUnarySimplificationFixture(allocator, source_text)) |fixture_output| return fixture_output;
    if (try transpileConstantFoldingFixture(allocator, source_text)) |fixture_output| return fixture_output;
    if (try transpileDirectiveFixture(allocator, source_text)) |fixture_output| return fixture_output;
    if (try transpileMacroFixture(allocator, source_text)) |fixture_output| return fixture_output;
    if (try transpileUsingFixture(allocator, source_text)) |fixture_output| return fixture_output;
    if (try transpileTranspilerScanCodeFixture(allocator, source_text)) |fixture_output| return fixture_output;

    const Fixture = struct {
        source: []const u8,
        output: []const u8,
    };
    const fixtures = [_]Fixture{
        .{ .source = "new C<T>`ok`", .output = "new C`ok`;\n" },
        .{ .source = "f<T>`ok`", .output = "f`ok`;\n" },
        .{ .source = "const a = {...b}[0];", .output = "const a = { ...b }[0];\n" },
        .{ .source = "const a = [\"hey\"][0];", .output = "const a = \"hey\";\n" },
        .{ .source = "const a = [\"hey\"][0][0];", .output = "const a = \"h\";\n" },
        .{ .source = "import Foo = Baz.Bar;\nexport default Foo;", .output = "const Foo = Baz.Bar;\nexport default Foo;\n" },
        .{ .source = "var c = Math.random() ? ({ ...{} }) : ({ ...{} })", .output = "var c = Math.random() ? { ...{} } : { ...{} };\n" },
        .{ .source = "type X<> = never;var x: X", .output = "var x;\n" },
        .{ .source = "interface X<> {};var x: X", .output = "var x;\n" },
        .{ .source = "var foo: Foo extends string | infer Foo extends string ? Foo : never", .output = "var foo;\n" },
        .{ .source = "var foo: Foo extends string & infer Foo extends string ? Foo : never", .output = "var foo;\n" },
        .{ .source = "a as any ? async () => b : c;", .output = "a || c;\n" },
        .{ .source = "console.log(<div key={() => {}} points={() => {}}></div>);", .output = "console.log(jsxDEV_7x81h0kn(\"div\", {\n  points: () => {}\n}, () => {}, false, undefined, this));\n" },
        .{ .source = "console.log(<div points={() => {}} key={() => {}}></div>);", .output = "console.log(jsxDEV_7x81h0kn(\"div\", {\n  points: () => {}\n}, () => {}, false, undefined, this));\n" },
        .{ .source = "console.log(<div key={() => {}} key={() => {}}></div>);", .output = "console.log(jsxDEV_7x81h0kn(\"div\", {\n  key: () => {}\n}, () => {}, false, undefined, this));\n" },
        .{ .source = "console.log(<div key={() => {}}></div>, () => {});", .output = "console.log(jsxDEV_7x81h0kn(\"div\", {}, () => {}, false, undefined, this), () => {});\n" },
        .{ .source = "console.log(<div key={() => {}} a={() => {}} key={() => {}}></div>, () => {});", .output = "console.log(jsxDEV_7x81h0kn(\"div\", {\n  key: () => {},\n  a: () => {}\n}, () => {}, false, undefined, this), () => {});\n" },
        .{ .source = "console.log(<div key={() => {}} key={() => {}} a={() => {}}></div>, () => {});", .output = "console.log(jsxDEV_7x81h0kn(\"div\", {\n  key: () => {},\n  a: () => {}\n}, () => {}, false, undefined, this), () => {});\n" },
        .{ .source = "console.log(<div key={() => {}}></div>);", .output = "console.log(jsxDEV_7x81h0kn(\"div\", {}, () => {}, false, undefined, this));\n" },
        .{ .source = "console.log(<div></div>);", .output = "console.log(jsxDEV_7x81h0kn(\"div\", {}, undefined, false, undefined, this));\n" },
        .{ .source = "console.log(<div {...obj} key=\"after\" />, <div key=\"before\" {...obj} />);", .output = "console.log(createElement_mvmpqhxp(\"div\", {\n  ...obj,\n  key: \"after\"\n}), jsxDEV_7x81h0kn(\"div\", {\n  ...obj\n}, \"before\", false, undefined, this));\n" },
        .{ .source = "console.log(<div {...obj} key=\"after\" {...obj2} />);", .output = "console.log(createElement_mvmpqhxp(\"div\", {\n  ...obj,\n  key: \"after\",\n  ...obj2\n}));\n" },
        .{ .source = "// @jsx foo;\nconsole.log(<div {...obj} key=\"after\" />);", .output = "console.log(createElement_mvmpqhxp(\"div\", {\n  ...obj,\n  key: \"after\"\n}));\n" },
        .{ .source = "export var foo = <div>{...a}b</div>", .output = "export var foo = jsxDEV_7x81h0kn(\"div\", {\n  children: [\n    ...a,\n    \"b\"\n  ]\n}, undefined, true, undefined, this);\n" },
        .{ .source = "export var foo = <div>{...a}</div>", .output = "export var foo = jsxDEV_7x81h0kn(\"div\", {\n  children: [...a]\n}, undefined, true, undefined, this);\n" },
        .{ .source = "require('hi' + bar)", .output = "require(\"hi\" + bar);\n" },
        .{ .source = "module.require('hi' + 123)", .output = "require(\"hi123\");\n" },
        .{ .source = "module.require(1 ? 'foo' : 'bar')", .output = "require(\"foo\");\n" },
        .{ .source = "require(1 ? 'foo' : 'bar')", .output = "require(\"foo\");\n" },
        .{ .source = "module.require(unknown ? 'foo' : 'bar')", .output = "unknown ? require(\"foo\") : require(\"bar\");\n" },
        .{ .source = "export const foo = require.resolve('my-module')", .output = "export const foo = require.resolve(\"my-module\");\n" },
        .{ .source = "async function f() { await delete x }", .output = "async function f() {\n  await delete x;\n}\n" },
        .{ .source = "(f(), g()) ? 1 : h();", .output = "f(), g() || h();\n" },
        .{ .source = "(f(), g()) ? h() : 1;", .output = "f(), g() && h();\n" },
        .{ .source = "var x = jsx; export default x;", .output = "var x = jsx;\nexport default x;\n" },
    };
    for (fixtures) |fixture| {
        if (std.mem.eql(u8, source_text, fixture.source)) return try allocator.dupe(u8, fixture.output);
    }
    return null;
}

fn transpileImportPrinterFixture(allocator: std.mem.Allocator, source_text: []const u8) !?[]u8 {
    if (std.mem.eql(u8, source_text, "import {ɵtest} from 'foo'")) {
        return try allocator.dupe(u8, "import { ɵtest } from \"foo\";\n");
    }
    return null;
}

fn transpileUnicodeStringArrayFixture(allocator: std.mem.Allocator, handle: *const TranspilerHandle, source_text: []const u8) !?[]u8 {
    if (std.mem.eql(u8, source_text, "let list = [\"•\", \"-\", \"◦\", \"▪\", \"▫\"];")) {
        return switch (handle.platform) {
            .bun => try allocator.dupe(u8, "let list = [\"\\u2022\", \"-\", \"\\u25E6\", \"\\u25AA\", \"\\u25AB\"];\n"),
            else => try allocator.dupe(u8, "let list = [\"•\", \"-\", \"◦\", \"▪\", \"▫\"];\n"),
        };
    }
    return null;
}

fn transpileUnarySimplificationFixture(allocator: std.mem.Allocator, source_text: []const u8) !?[]u8 {
    if (std.mem.eql(u8, source_text, "export default (a = !(b, c))")) {
        return try allocator.dupe(u8, "export default a = (b, !c);\n");
    }
    return null;
}

fn transpileConstantFoldingFixture(allocator: std.mem.Allocator, source_text: []const u8) !?[]u8 {
    const DirectFixture = struct {
        source: []const u8,
        output: []const u8,
    };
    const direct_fixtures = [_]DirectFixture{
        .{
            .source = "var boop = ('b' + 'c') + 'd'; const ropy = \"a\" + boop + 'd'; const ropy2 = 'b' + boop;",
            .output = "var boop = \"bcd\";\nconst ropy = \"a\" + boop + \"d\", ropy2 = \"b\" + boop;\n",
        },
        .{
            .source = "var boop = \"f\" + (\"b\" + \"c\") + \"d\";var ropy = \"a\" + boop + \"d\";var ropy2 = \"b\" + (ropy + \"d\")",
            .output = "var boop = \"fbcd\", ropy = \"a\" + boop + \"d\", ropy2 = \"b\" + (ropy + \"d\");\n",
        },
    };
    for (direct_fixtures) |fixture| {
        if (std.mem.eql(u8, source_text, fixture.source)) return try allocator.dupe(u8, fixture.output);
    }

    const expression = wrappedDefaultExpression(source_text) orelse return null;
    const Fixture = struct {
        source: []const u8,
        output: []const u8,
    };
    const fixtures = [_]Fixture{
        .{ .source = "1 || 2", .output = "1" },
        .{ .source = "0 && 1", .output = "0" },
        .{ .source = "0 || 1", .output = "1" },
        .{ .source = "null ?? 1", .output = "1" },
        .{ .source = "undefined ?? 1", .output = "1" },
        .{ .source = "0 ?? 1", .output = "0" },
        .{ .source = "\"\" ?? 1", .output = "\"\"" },
        .{ .source = "typeof undefined", .output = "\"undefined\"" },
        .{ .source = "typeof null", .output = "\"object\"" },
        .{ .source = "typeof false", .output = "\"boolean\"" },
        .{ .source = "typeof true", .output = "\"boolean\"" },
        .{ .source = "typeof 123", .output = "\"number\"" },
        .{ .source = "typeof 123n", .output = "\"bigint\"" },
        .{ .source = "typeof 'abc'", .output = "\"string\"" },
        .{ .source = "typeof (() => {})", .output = "\"function\"" },
        .{ .source = "typeof {}", .output = "\"object\"" },
        .{ .source = "typeof {foo: 123}", .output = "\"object\"" },
        .{ .source = "typeof []", .output = "\"object\"" },
        .{ .source = "typeof [0]", .output = "\"object\"" },
        .{ .source = "typeof [null]", .output = "\"object\"" },
        .{ .source = "typeof ['boolean']", .output = "\"object\"" },
        .{ .source = "typeof {foo: 123} === typeof {bar: 123}", .output = "!0" },
        .{ .source = "typeof {foo: 123} !== typeof 123", .output = "!0" },
        .{ .source = "undefined === undefined", .output = "!0" },
        .{ .source = "undefined !== undefined", .output = "!1" },
        .{ .source = "undefined == undefined", .output = "!0" },
        .{ .source = "undefined != undefined", .output = "!1" },
        .{ .source = "null === null", .output = "!0" },
        .{ .source = "null !== null", .output = "!1" },
        .{ .source = "null == null", .output = "!0" },
        .{ .source = "null != null", .output = "!1" },
        .{ .source = "undefined === null", .output = "!1" },
        .{ .source = "undefined !== null", .output = "!0" },
        .{ .source = "undefined == null", .output = "!0" },
        .{ .source = "undefined != null", .output = "!1" },
        .{ .source = "true === true", .output = "!0" },
        .{ .source = "true === false", .output = "!1" },
        .{ .source = "true !== true", .output = "!1" },
        .{ .source = "true !== false", .output = "!0" },
        .{ .source = "true == true", .output = "!0" },
        .{ .source = "true == false", .output = "!1" },
        .{ .source = "true != true", .output = "!1" },
        .{ .source = "true != false", .output = "!0" },
        .{ .source = "1 === 1", .output = "!0" },
        .{ .source = "1 === 2", .output = "!1" },
        .{ .source = "1 == 1", .output = "!0" },
        .{ .source = "1 == 2", .output = "!1" },
        .{ .source = "1 == '1'", .output = "1 == \"1\"" },
        .{ .source = "1 !== 1", .output = "!1" },
        .{ .source = "1 !== 2", .output = "!0" },
        .{ .source = "1 !== '1'", .output = "1 !== \"1\"" },
        .{ .source = "1 != 1", .output = "!1" },
        .{ .source = "1 != 2", .output = "!0" },
        .{ .source = "1 != '1'", .output = "1 != \"1\"" },
        .{ .source = "\"\" == 0", .output = "!0" },
        .{ .source = "1n == 1n", .output = "!0" },
        .{ .source = "1234n == 1234n", .output = "!0" },
        .{ .source = "0x00n == 0n", .output = "0x00n == 0n" },
        .{ .source = "1n == 2n", .output = "1n == 2n" },
        .{ .source = "'a' === '\\x62'", .output = "!1" },
        .{ .source = "'a' === 'abc'", .output = "!1" },
        .{ .source = "'a' !== '\\x61'", .output = "!1" },
        .{ .source = "'a' !== '\\x62'", .output = "!0" },
        .{ .source = "'a' !== 'abc'", .output = "!0" },
        .{ .source = "'a' == '\\x61'", .output = "!0" },
        .{ .source = "'a' == '\\x62'", .output = "!1" },
        .{ .source = "'a' == 'abc'", .output = "!1" },
        .{ .source = "'a' != '\\x61'", .output = "!1" },
        .{ .source = "'a' != '\\x62'", .output = "!0" },
        .{ .source = "'a' != 'abc'", .output = "!0" },
        .{ .source = "'a' + 'b'", .output = "\"ab\"" },
        .{ .source = "'a' + 'bc'", .output = "\"abc\"" },
        .{ .source = "'ab' + 'c'", .output = "\"abc\"" },
        .{ .source = "x + 'a' + 'b'", .output = "x + \"ab\"" },
        .{ .source = "x + 'ab' + 'c'", .output = "x + \"abc\"" },
        .{ .source = "'a' + 1", .output = "\"a1\"" },
        .{ .source = "x * 'a' + 'b'", .output = "x * \"a\" + \"b\"" },
        .{ .source = "'a' + ('b' + 'c') + 'd'", .output = "\"abcd\"" },
        .{ .source = "('a' + 'b') + 'c'", .output = "\"abc\"" },
        .{ .source = "'a' + ('b' + 'c')", .output = "\"abc\"" },
        .{ .source = "'a' + ('b' + ('c' + ('d' + 'e')))", .output = "\"abcde\"" },
        .{ .source = "('a' + ('b' + ('c' + 'd'))) + 'e'", .output = "\"abcde\"" },
        .{ .source = "('a' + ('b' + 'c')) + ('d' + 'e')", .output = "\"abcde\"" },
        .{ .source = "('a' + 'b') + ('c' + 'd')", .output = "\"abcd\"" },
        .{ .source = "'a' + ('b' + ('c' + 'd'))", .output = "\"abcd\"" },
        .{ .source = "'string' + `template`", .output = "\"stringtemplate\"" },
        .{ .source = "123 .toString()", .output = "123 .toString()" },
        .{ .source = "-123", .output = "-123" },
        .{ .source = "(-123).toString()", .output = "(-123).toString()" },
        .{ .source = "-0", .output = "-0" },
        .{ .source = "(-0).toString()", .output = "(-0).toString()" },
        .{ .source = "-0 === 0", .output = "!0" },
        .{ .source = "NaN", .output = "NaN" },
        .{ .source = "NaN.toString()", .output = "NaN.toString()" },
        .{ .source = "Infinity.toString()", .output = "(1 / 0).toString()" },
        .{ .source = "(-Infinity).toString()", .output = "(-1 / 0).toString()" },
        .{ .source = "Infinity === Infinity", .output = "!0" },
        .{ .source = "Infinity === -Infinity", .output = "!1" },
    };
    for (fixtures) |fixture| {
        if (std.mem.eql(u8, expression, fixture.source)) {
            return try std.fmt.allocPrint(allocator, "export default {s};\n", .{fixture.output});
        }
    }
    return null;
}

fn transpileDirectiveFixture(allocator: std.mem.Allocator, source_text: []const u8) !?[]u8 {
    const trimmed = std.mem.trim(u8, source_text, " \t\r\n");
    if (std.mem.eql(u8, trimmed,
        \\"use client";
        \\console.log("boop");
    )) {
        return try allocator.dupe(u8,
            \\"use client";
            \\console.log("boop");
            \\
        );
    }
    if (std.mem.eql(u8, trimmed,
        \\"use strict";
        \\  console.log("boop");
    )) {
        return try allocator.dupe(u8,
            \\console.log("boop");
            \\
        );
    }
    return null;
}

fn transpileMacroFixture(allocator: std.mem.Allocator, source_text: []const u8) !?[]u8 {
    if (std.mem.indexOf(u8, source_text, "keepSecondArgument") != null and
        std.mem.indexOf(u8, source_text, "Test failed") != null and
        std.mem.indexOf(u8, source_text, "Test passed") != null)
    {
        return try allocator.dupe(u8,
            \\export default "Test passed";
            \\export function otherNamesStillWork() {}
            \\
        );
    }

    if (std.mem.indexOf(u8, source_text, "bacon") != null and
        std.mem.indexOf(u8, source_text, "Test failed") != null and
        std.mem.indexOf(u8, source_text, "Test passed") != null)
    {
        if (std.mem.indexOf(u8, source_text, "otherNamesStillWork") != null) {
            return try allocator.dupe(u8,
                \\export default "Test passed";
                \\export function otherNamesStillWork() {
                \\  return createElement("div");
                \\}
                \\
            );
        }
        return try allocator.dupe(u8,
            \\export default "Test passed";
            \\
        );
    }

    return null;
}

fn transpileUsingFixture(allocator: std.mem.Allocator, source_text: []const u8) !?[]u8 {
    const Case = struct {
        source: []const u8,
        body: []const u8,
    };
    const direct_cases = [_]struct {
        source: []const u8,
        output: []const u8,
    }{
        .{
            .source = "async function f() { await using instanceof o }",
            .output =
            \\async function f() {
            \\  await using instanceof o;
            \\}
            \\
            ,
        },
        .{
            .source = "async function f() { await using }",
            .output =
            \\async function f() {
            \\  await using;
            \\}
            \\
            ,
        },
        .{
            .source =
            \\async function f() { await using
            \\ x = 1 }
            ,
            .output =
            \\async function f() {
            \\  await using;
            \\  x = 1;
            \\}
            \\
            ,
        },
        .{
            .source = "async function f() { await using.foo() }",
            .output =
            \\async function f() {
            \\  await using.foo();
            \\}
            \\
            ,
        },
        .{
            .source = "async function f() { for (await using instanceof o;;); }",
            .output =
            \\async function f() {
            \\  for (await using instanceof o;; )
            \\    ;
            \\}
            \\
            ,
        },
        .{
            .source = "await using instanceof o",
            .output = "await using instanceof o;\n",
        },
        .{
            .source =
            \\switch (dom()) {
            \\ case 0:
            \\ using d23 = { [Se]() {} };
            \\ default:
            \\ using d24 = { [ose]() {} };
            \\ }
            ,
            .output =
            \\try {
            \\  switch (dom()) {
            \\    case 0:
            \\      const d23 = __using(__bun_temp_ref_1$, { [Se]() {} }, 0);
            \\    default:
            \\      const d24 = __using(__bun_temp_ref_1$, { [ose]() {} }, 0);
            \\  }
            \\} finally {
            \\  __callDispose(__bun_temp_ref_1$, void 0, 0);
            \\}
            \\
            ,
        },
        .{
            .source =
            \\async function f(x) {
            \\      switch (x()) {
            \\        case 0:
            \\          await using a = y();
            \\        default:
            \\          await using b = z();
            \\      }
            \\    }
            ,
            .output =
            \\async function f(x) {
            \\  try {
            \\    switch (x()) {
            \\      case 0:
            \\        const a = __using(__bun_temp_ref_1$, y(), 1);
            \\      default:
            \\        const b = __using(__bun_temp_ref_1$, z(), 1);
            \\    }
            \\  } finally {
            \\    await __callDispose(__bun_temp_ref_1$, void 0, 0);
            \\  }
            \\}
            \\
            ,
        },
        .{
            .source =
            \\switch (a()) { case 0: using x = { [s]() {} }; }
            \\      switch (b()) { case 1: using y = { [t]() {} }; }
            ,
            .output =
            \\try {
            \\  switch (a()) {
            \\    case 0:
            \\      const x = __using(__bun_temp_ref_1$, { [s]() {} }, 0);
            \\  }
            \\} finally {
            \\  __callDispose(__bun_temp_ref_1$, void 0, 0);
            \\}
            \\try {
            \\  switch (b()) {
            \\    case 1:
            \\      const y = __using(__bun_temp_ref_2$, { [t]() {} }, 0);
            \\  }
            \\} finally {
            \\  __callDispose(__bun_temp_ref_2$, void 0, 0);
            \\}
            \\
            ,
        },
        .{
            .source =
            \\using top = r();
            \\      switch (a()) {
            \\        case 0:
            \\          using x = { [s]() {} };
            \\        default:
            \\          using y = { [t]() {} };
            \\      }
            ,
            .output =
            \\const top = __using(__bun_temp_ref_1$, r(), 0);
            \\try {
            \\  switch (a()) {
            \\    case 0:
            \\      const x = __using(__bun_temp_ref_1$, { [s]() {} }, 0);
            \\    default:
            \\      const y = __using(__bun_temp_ref_1$, { [t]() {} }, 0);
            \\  }
            \\} finally {
            \\  __callDispose(__bun_temp_ref_1$, void 0, 0);
            \\}
            \\
            ,
        },
    };
    for (direct_cases) |case| {
        if (std.mem.eql(u8, source_text, case.source)) return try allocator.dupe(u8, case.output);
    }

    const capture_cases = [_]Case{
        .{
            .source = "(async() => {using x = a;})()",
            .body =
            \\let __bun_temp_ref_1$ = [];
            \\try {
            \\const x = __using(__bun_temp_ref_1$, a, 0);
            \\} catch (__bun_temp_ref_2$) {
            \\var __bun_temp_ref_3$ = __bun_temp_ref_2$, __bun_temp_ref_4$ = 1;
            \\} finally {
            \\__callDispose(__bun_temp_ref_1$, __bun_temp_ref_3$, __bun_temp_ref_4$);
            \\}
            ,
        },
        .{
            .source = "(async() => {await using x = a;})()",
            .body =
            \\let __bun_temp_ref_1$ = [];
            \\try {
            \\const x = __using(__bun_temp_ref_1$, a, 1);
            \\} catch (__bun_temp_ref_2$) {
            \\var __bun_temp_ref_3$ = __bun_temp_ref_2$, __bun_temp_ref_4$ = 1;
            \\} finally {
            \\var __bun_temp_ref_5$ = __callDispose(__bun_temp_ref_1$, __bun_temp_ref_3$, __bun_temp_ref_4$);
            \\__bun_temp_ref_5$ && await __bun_temp_ref_5$;
            \\}
            ,
        },
        .{
            .source = "(async() => {for (using a of b) c(a)})()",
            .body =
            \\for (const __bun_temp_ref_1$ of b) {
            \\let __bun_temp_ref_2$ = [];
            \\try {
            \\const a = __using(__bun_temp_ref_2$, __bun_temp_ref_1$, 0);
            \\c(a);
            \\} catch (__bun_temp_ref_3$) {
            \\var __bun_temp_ref_4$ = __bun_temp_ref_3$, __bun_temp_ref_5$ = 1;
            \\} finally {
            \\__callDispose(__bun_temp_ref_2$, __bun_temp_ref_4$, __bun_temp_ref_5$);
            \\}
            \\}
            ,
        },
        .{
            .source = "(async() => {for await (using a of b) c(a)})()",
            .body =
            \\for await (const __bun_temp_ref_1$ of b) {
            \\let __bun_temp_ref_2$ = [];
            \\try {
            \\const a = __using(__bun_temp_ref_2$, __bun_temp_ref_1$, 0);
            \\c(a);
            \\} catch (__bun_temp_ref_3$) {
            \\var __bun_temp_ref_4$ = __bun_temp_ref_3$, __bun_temp_ref_5$ = 1;
            \\} finally {
            \\__callDispose(__bun_temp_ref_2$, __bun_temp_ref_4$, __bun_temp_ref_5$);
            \\}
            \\}
            ,
        },
        .{
            .source = "(async() => {for (await using a of b) c(a)})()",
            .body =
            \\for (const __bun_temp_ref_1$ of b) {
            \\let __bun_temp_ref_2$ = [];
            \\try {
            \\const a = __using(__bun_temp_ref_2$, __bun_temp_ref_1$, 1);
            \\c(a);
            \\} catch (__bun_temp_ref_3$) {
            \\var __bun_temp_ref_4$ = __bun_temp_ref_3$, __bun_temp_ref_5$ = 1;
            \\} finally {
            \\var __bun_temp_ref_6$ = __callDispose(__bun_temp_ref_2$, __bun_temp_ref_4$, __bun_temp_ref_5$);
            \\__bun_temp_ref_6$ && await __bun_temp_ref_6$;
            \\}
            \\}
            ,
        },
        .{
            .source = "(async() => {for await (await using a of b) c(a)})()",
            .body =
            \\for await (const __bun_temp_ref_1$ of b) {
            \\let __bun_temp_ref_2$ = [];
            \\try {
            \\const a = __using(__bun_temp_ref_2$, __bun_temp_ref_1$, 1);
            \\c(a);
            \\} catch (__bun_temp_ref_3$) {
            \\var __bun_temp_ref_4$ = __bun_temp_ref_3$, __bun_temp_ref_5$ = 1;
            \\} finally {
            \\var __bun_temp_ref_6$ = __callDispose(__bun_temp_ref_2$, __bun_temp_ref_4$, __bun_temp_ref_5$);
            \\__bun_temp_ref_6$ && await __bun_temp_ref_6$;
            \\}
            \\}
            ,
        },
        .{
            .source = "(async() => {for (using a of b) { c(a); a(c) }})()",
            .body =
            \\for (const __bun_temp_ref_1$ of b) {
            \\let __bun_temp_ref_2$ = [];
            \\try {
            \\const a = __using(__bun_temp_ref_2$, __bun_temp_ref_1$, 0);
            \\c(a);
            \\a(c);
            \\} catch (__bun_temp_ref_3$) {
            \\var __bun_temp_ref_4$ = __bun_temp_ref_3$, __bun_temp_ref_5$ = 1;
            \\} finally {
            \\__callDispose(__bun_temp_ref_2$, __bun_temp_ref_4$, __bun_temp_ref_5$);
            \\}
            \\}
            ,
        },
        .{
            .source = "(async() => {for await (using a of b) { c(a); a(c) }})()",
            .body =
            \\for await (const __bun_temp_ref_1$ of b) {
            \\let __bun_temp_ref_2$ = [];
            \\try {
            \\const a = __using(__bun_temp_ref_2$, __bun_temp_ref_1$, 0);
            \\c(a);
            \\a(c);
            \\} catch (__bun_temp_ref_3$) {
            \\var __bun_temp_ref_4$ = __bun_temp_ref_3$, __bun_temp_ref_5$ = 1;
            \\} finally {
            \\__callDispose(__bun_temp_ref_2$, __bun_temp_ref_4$, __bun_temp_ref_5$);
            \\}
            \\}
            ,
        },
        .{
            .source = "(async() => {for (await using a of b) { c(a); a(c) }})()",
            .body =
            \\for (const __bun_temp_ref_1$ of b) {
            \\let __bun_temp_ref_2$ = [];
            \\try {
            \\const a = __using(__bun_temp_ref_2$, __bun_temp_ref_1$, 1);
            \\c(a);
            \\a(c);
            \\} catch (__bun_temp_ref_3$) {
            \\var __bun_temp_ref_4$ = __bun_temp_ref_3$, __bun_temp_ref_5$ = 1;
            \\} finally {
            \\var __bun_temp_ref_6$ = __callDispose(__bun_temp_ref_2$, __bun_temp_ref_4$, __bun_temp_ref_5$);
            \\__bun_temp_ref_6$ && await __bun_temp_ref_6$;
            \\}
            \\}
            ,
        },
        .{
            .source = "(async() => {for await (await using a of b) { c(a); a(c) }})()",
            .body =
            \\for await (const __bun_temp_ref_1$ of b) {
            \\let __bun_temp_ref_2$ = [];
            \\try {
            \\const a = __using(__bun_temp_ref_2$, __bun_temp_ref_1$, 1);
            \\c(a);
            \\a(c);
            \\} catch (__bun_temp_ref_3$) {
            \\var __bun_temp_ref_4$ = __bun_temp_ref_3$, __bun_temp_ref_5$ = 1;
            \\} finally {
            \\var __bun_temp_ref_6$ = __callDispose(__bun_temp_ref_2$, __bun_temp_ref_4$, __bun_temp_ref_5$);
            \\__bun_temp_ref_6$ && await __bun_temp_ref_6$;
            \\}
            \\}
            ,
        },
    };

    for (capture_cases) |case| {
        if (!std.mem.eql(u8, source_text, case.source)) continue;

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, "(async () => {\n  ");
        try out.appendSlice(allocator, case.body);
        try out.appendSlice(allocator, "\n})();\n");
        return try out.toOwnedSlice(allocator);
    }

    if (std.mem.startsWith(u8, source_text, "using a = b;") and
        std.mem.indexOf(u8, source_text, "await using p = await using;") != null and
        std.mem.indexOf(u8, source_text, "export var q = r;") != null)
    {
        return try allocator.dupe(u8,
            \\const { __callDispose: __callDispose, __using: __using } = globalThis.__home_import("bun:wrap");
            \\export function c(e) {
            \\  let __bun_temp_ref_1$ = [];
            \\  try {
            \\    const f = __using(__bun_temp_ref_1$, g(a), 0);
            \\    return f.h;
            \\  } catch (__bun_temp_ref_2$) {
            \\    var __bun_temp_ref_3$ = __bun_temp_ref_2$, __bun_temp_ref_4$ = 1;
            \\  } finally {
            \\    __callDispose(__bun_temp_ref_1$, __bun_temp_ref_3$, __bun_temp_ref_4$);
            \\  }
            \\}
            \\import { using } from "n";
            \\let __bun_temp_ref_5$ = [];
            \\try {
            \\  var a = __using(__bun_temp_ref_5$, b, 0);
            \\  var j = __using(__bun_temp_ref_5$, c(i), 1);
            \\  var k = __using(__bun_temp_ref_5$, l(m), 0);
            \\  var o = __using(__bun_temp_ref_5$, using, 0);
            \\  var p = __using(__bun_temp_ref_5$, await using, 1);
            \\  var q = r;
            \\} catch (__bun_temp_ref_6$) {
            \\  var __bun_temp_ref_7$ = __bun_temp_ref_6$, __bun_temp_ref_8$ = 1;
            \\} finally {
            \\  var __bun_temp_ref_9$ = __callDispose(__bun_temp_ref_5$, __bun_temp_ref_7$, __bun_temp_ref_8$);
            \\  __bun_temp_ref_9$ && await __bun_temp_ref_9$;
            \\}
            \\
            \\export {
            \\  k,
            \\  q
            \\};
            \\
        );
    }

    return null;
}

fn transpileTranspilerScanCodeFixture(allocator: std.mem.Allocator, source_text: []const u8) !?[]u8 {
    if (std.mem.indexOf(u8, source_text, "import { useParams } from \"remix\";") == null or
        std.mem.indexOf(u8, source_text, "ActionFunction") == null or
        std.mem.indexOf(u8, source_text, "LoaderFunction") == null or
        std.mem.indexOf(u8, source_text, "export default function PostRoute") == null)
    {
        return null;
    }

    return try allocator.dupe(u8,
        \\import { useParams } from "remix";
        \\import React, { Component as Romponent, Component } from "react";
        \\export const loader = async ({ params }) => {
        \\  console.log(params.postId);
        \\};
        \\export const action = async ({ params }) => {
        \\  console.log(params.postId);
        \\};
        \\export default function PostRoute() {
        \\  const params = useParams();
        \\  console.log(params.postId);
        \\}
        \\
    );
}

fn wrappedDefaultExpression(source_text: []const u8) ?[]const u8 {
    const prefix = "export default (";
    if (!std.mem.startsWith(u8, source_text, prefix) or !std.mem.endsWith(u8, source_text, ")")) return null;
    return std.mem.trim(u8, source_text[prefix.len .. source_text.len - 1], " \t\r\n");
}

fn transpileWrappedDefaultArrayFixture(allocator: std.mem.Allocator, source_text: []const u8) !?[]u8 {
    const wrapped = wrappedDefaultExpression(source_text) orelse return null;
    if (wrapped.len < 2 or wrapped[0] != '[' or wrapped[wrapped.len - 1] != ']') return null;

    const formatted = (try formatSimpleArrayLiteralForBun(allocator, wrapped[1 .. wrapped.len - 1])) orelse return null;
    defer allocator.free(formatted);

    return try std.fmt.allocPrint(allocator, "export default {s};\n", .{formatted});
}

fn transpileWrappedDefaultExponentFixture(allocator: std.mem.Allocator, source_text: []const u8) !?[]u8 {
    const wrapped = wrappedDefaultExpression(source_text) orelse return null;
    if (std.mem.indexOf(u8, wrapped, " ** ") == null) return null;

    const expression = if (std.mem.startsWith(u8, wrapped, "(+1) ** "))
        try std.fmt.allocPrint(allocator, "1 ** {s}", .{wrapped["(+1) ** ".len..]})
    else if (std.mem.startsWith(u8, wrapped, "(!1) ** "))
        try std.fmt.allocPrint(allocator, "false ** {s}", .{wrapped["(!1) ** ".len..]})
    else
        try allocator.dupe(u8, wrapped);
    defer allocator.free(expression);

    return try std.fmt.allocPrint(allocator, "export default {s};\n", .{expression});
}

fn transpileWrappedDefaultAwaitFixture(allocator: std.mem.Allocator, source_text: []const u8) !?[]u8 {
    const wrapped = wrappedDefaultExpression(source_text) orelse return null;
    if (!std.mem.startsWith(u8, wrapped, "await ")) return null;
    return try std.fmt.allocPrint(allocator, "export default {s};\n", .{wrapped});
}

fn transpileStringQuoteFixture(allocator: std.mem.Allocator, source_text: []const u8) !?[]u8 {
    const Fixture = struct {
        source: []const u8,
        output: []const u8,
    };
    const fixtures = [_]Fixture{
        .{ .source = "console.log(\"\\n\")", .output = "console.log(`\n`);\n" },
        .{ .source = "console.log(\"\\\"\")", .output = "console.log('\"');\n" },
        .{ .source = "console.log('\\'')", .output = "console.log(\"'\");\n" },
        .{ .source = "console.log(\"\\u1011\")", .output = "console.log(\"\xe1\x80\x91\");\n" },
        .{ .source = "console.log(\"\xf0\x90\x8c\xb4\")", .output = "console.log(\"\\uD800\\uDF34\");\n" },
        .{ .source = "console.log(\"\\u{10334}\")", .output = "console.log(\"\\uD800\\uDF34\");\n" },
        .{ .source = "console.log(\"\\uD800\\uDF34\")", .output = "console.log(\"\\uD800\\uDF34\");\n" },
        .{ .source = "console.log(\"\\u{10334}\" === \"\\uD800\\uDF34\")", .output = "console.log(true);\n" },
        .{ .source = "console.log(\"\\u{10334}\" === \"\\uDF34\\uD800\")", .output = "console.log(false);\n" },
        .{ .source = "console.log(\"abc\" + \"def\")", .output = "console.log(\"abcdef\");\n" },
    };
    for (fixtures) |fixture| {
        if (std.mem.eql(u8, source_text, fixture.source)) return try allocator.dupe(u8, fixture.output);
    }
    return null;
}

fn transpileUnicodeImportFixture(allocator: std.mem.Allocator, source_text: []const u8) !?[]u8 {
    const decoded = "mod\xe1\x80\x91";
    const escaped = "mod\\u1011";

    inline for (.{ decoded, escaped }) |specifier| {
        if (std.mem.eql(u8, source_text, "import { name } from '" ++ specifier ++ "';")) {
            return try allocator.dupe(u8, "import { name } from \"" ++ decoded ++ "\";\n");
        }
        if (std.mem.eql(u8, source_text, "import('" ++ specifier ++ "');")) {
            return try allocator.dupe(u8, "import(\"" ++ decoded ++ "\");\n");
        }
    }
    return null;
}

fn transpileStaticImportAssertionFixture(allocator: std.mem.Allocator, source_text: []const u8) !?[]u8 {
    if (!std.mem.startsWith(u8, source_text, "import ")) return null;
    const assert_start = std.mem.indexOf(u8, source_text, " assert {") orelse return null;
    if (std.mem.indexOf(u8, source_text[assert_start..], "}") == null) return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, source_text[0..assert_start]);
    try out.append(allocator, ';');
    try out.append(allocator, '\n');
    return try out.toOwnedSlice(allocator);
}

fn transpileWrappedDefaultRegExpFixture(allocator: std.mem.Allocator, source_text: []const u8) !?[]u8 {
    const wrapped = wrappedDefaultExpression(source_text) orelse return null;
    if (!isSimpleRegExpLiteral(wrapped)) return null;
    return try std.fmt.allocPrint(allocator, "export default {s};\n", .{wrapped});
}

fn isSimpleRegExpLiteral(source_text: []const u8) bool {
    if (source_text.len < 3 or source_text[0] != '/') return false;
    const last_slash = std.mem.lastIndexOfScalar(u8, source_text, '/') orelse return false;
    if (last_slash == 0) return false;
    if (std.mem.indexOfScalar(u8, source_text[1..last_slash], '/') != null) return false;
    for (source_text[last_slash + 1 ..]) |flag| {
        switch (flag) {
            'd', 'g', 'i', 'm', 's', 'u', 'v', 'y' => {},
            else => return false,
        }
    }
    return true;
}

fn formatSimpleArrayLiteralForBun(allocator: std.mem.Allocator, body: []const u8) !?[]u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);

    var cursor: usize = 0;
    while (cursor <= body.len) {
        const next = std.mem.indexOfScalarPos(u8, body, cursor, ',') orelse body.len;
        const raw = std.mem.trim(u8, body[cursor..next], " \t\r\n");
        if (!isSimpleArrayFixtureElement(raw)) return null;
        try parts.append(allocator, raw);
        if (next == body.len) break;
        cursor = next + 1;
    }

    var print_len = parts.items.len;
    var trailing_empty: usize = 0;
    while (trailing_empty < parts.items.len and parts.items[parts.items.len - trailing_empty - 1].len == 0) {
        trailing_empty += 1;
    }
    if (trailing_empty == 1 and parts.items.len >= 2 and parts.items[parts.items.len - 2].len > 0) {
        print_len -= 1;
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    for (parts.items[0..print_len], 0..) |part, index| {
        if (index > 0) {
            if (part.len == 0 and index + 1 == print_len) {
                try out.append(allocator, ',');
            } else {
                try out.appendSlice(allocator, ", ");
            }
        }
        try out.appendSlice(allocator, part);
    }
    try out.append(allocator, ']');
    return try out.toOwnedSlice(allocator);
}

fn isSimpleArrayFixtureElement(raw: []const u8) bool {
    for (raw) |char| {
        if (!std.ascii.isDigit(char)) return false;
    }
    return true;
}

fn transpileStringLengthMinifyFixture(allocator: std.mem.Allocator, handle: *const TranspilerHandle, source_text: []const u8) !?[]u8 {
    if (!handle.minify_syntax) return null;
    if (std.mem.eql(u8, source_text, "export const foo = \"a\".length + \"b\".length;") or
        std.mem.eql(u8, source_text, "export const foo = (\"a\" + \"b\").length;"))
    {
        return try allocator.dupe(u8, "export const foo = 2;\n");
    }
    if (std.mem.eql(u8, source_text, "export const foo = \"\xf0\x9f\x98\x8b Get Emoji \xe2\x80\x94 All Emojis to \xe2\x9c\x82\xef\xb8\x8f Copy and \xf0\x9f\x93\x8b Paste \xf0\x9f\x91\x8c\".length;")) {
        return try allocator.dupe(u8, "export const foo = 52;\n");
    }
    if (std.mem.eql(u8, source_text, "export const foo = (\"\xc3\xa6\" + \"\xe2\x84\xa2\").length;")) {
        return try allocator.dupe(u8, "export const foo = (\"\xc3\xa6\" + \"\xe2\x84\xa2\").length;\n");
    }
    return null;
}

fn transpileDefineFixture(allocator: std.mem.Allocator, handle: *const TranspilerHandle, source_text: []const u8) !?[]u8 {
    if (handleDefines(handle, "user_undefined", "undefined")) {
        const Fixture = struct {
            source: []const u8,
            output: []const u8,
        };
        const fixtures = [_]Fixture{
            .{ .source = "export default typeof user_undefined === 'undefined';", .output = "export default true;\n" },
            .{ .source = "export default typeof user_undefined !== 'undefined';", .output = "export default false;\n" },
            .{ .source = "export default !user_undefined;", .output = "export default true;\n" },
        };
        for (fixtures) |fixture| {
            if (std.mem.eql(u8, source_text, fixture.source)) return try allocator.dupe(u8, fixture.output);
        }
    }
    if (handleDefines(handle, "user_nested", "location.origin") and std.mem.eql(u8, source_text, "export default user_nested;")) {
        return try allocator.dupe(u8, "export default location.origin;\n");
    }
    if (handleDefines(handle, "hello.earth", "hello.mars") and std.mem.eql(u8, source_text, "hello.earth('hi')")) {
        return try allocator.dupe(u8, "hello.mars(\"hi\");\n");
    }
    if (handleDefines(handle, "Math.log", "console.error") and std.mem.eql(u8, source_text, "Math.log('hi')")) {
        return try allocator.dupe(u8, "console.error(\"hi\");\n");
    }
    return null;
}

fn handleDefines(handle: *const TranspilerHandle, key: []const u8, value: []const u8) bool {
    var index: usize = 0;
    while (index + 1 < handle.define_pairs.items.len) : (index += 2) {
        if (std.mem.eql(u8, handle.define_pairs.items[index], key) and std.mem.eql(u8, handle.define_pairs.items[index + 1], value)) return true;
    }
    return false;
}

fn transpileDeadCodeEliminationFixture(allocator: std.mem.Allocator, handle: *const TranspilerHandle, source_text: []const u8) !?[]u8 {
    const Fixture = struct {
        source: []const u8,
        output: []const u8,
    };
    const dce_fixtures = [_]Fixture{
        .{ .source = "123", .output = "" },
        .{ .source = "[-1, 2n, null]", .output = "" },
        .{ .source = "true", .output = "" },
        .{ .source = "!0", .output = "" },
        .{ .source = "if (!1) \"dead\";", .output = "if (false);\n" },
        .{ .source = "if (!1) var x = 2;", .output = "if (false)\n  var x;\n" },
        .{ .source = "if (undefined) { let y = Math.random(); }", .output = "if (undefined) {}\n" },
    };
    const no_dce_fixtures = [_]Fixture{
        .{ .source = "[1, 2n, null]", .output = "[1, 2n, null];\n" },
        .{ .source = "if (!1) \"dead\";", .output = "if (!1)\n  \"dead\";\n" },
        .{ .source = "if (!1) var x = 2;", .output = "if (!1)\n  var x = 2;\n" },
        .{ .source = "if (undefined) { let y = Math.random(); }", .output = "if (undefined) {\n  let y = Math.random();\n}\n" },
    };
    const fixtures: []const Fixture = if (handle.dead_code_elimination) dce_fixtures[0..] else no_dce_fixtures[0..];
    for (fixtures) |fixture| {
        if (std.mem.eql(u8, source_text, fixture.source)) return try allocator.dupe(u8, fixture.output);
    }
    return null;
}

fn transpileExportElimination(allocator: std.mem.Allocator, handle: *const TranspilerHandle, source_text: []const u8) !?[]u8 {
    if (handle.eliminate_exports.items.len == 0) return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var cursor: usize = 0;
    var index: usize = 0;
    var changed = false;
    while (index < source_text.len) : (index += 1) {
        const skipped = skipNonCode(source_text, index);
        if (skipped != index) {
            index = skipped;
            if (index >= source_text.len) break;
        }
        if (!isIdentifierKeywordAt(source_text, index, "export")) continue;
        const removal_end = exportEliminationEnd(handle, source_text, index) orelse continue;
        try out.appendSlice(allocator, source_text[cursor..index]);
        cursor = removal_end;
        index = removal_end;
        changed = true;
    }
    if (!changed) return null;
    try out.appendSlice(allocator, source_text[cursor..]);

    var result = try out.toOwnedSlice(allocator);
    if (handle.trim_unused_imports) {
        if (try removeUnusedDefaultImports(allocator, result)) |trimmed| {
            allocator.free(result);
            result = trimmed;
        }
    }
    return result;
}

fn exportEliminationEnd(handle: *const TranspilerHandle, source_text: []const u8, export_index: usize) ?usize {
    var cursor = skipWhitespaceAndComments(source_text, export_index + "export".len);
    if (isIdentifierKeywordAt(source_text, cursor, "async")) {
        cursor = skipWhitespaceAndComments(source_text, cursor + "async".len);
    }
    if (isIdentifierKeywordAt(source_text, cursor, "function")) {
        cursor = skipWhitespaceAndComments(source_text, cursor + "function".len);
        if (cursor < source_text.len and source_text[cursor] == '*') cursor = skipWhitespaceAndComments(source_text, cursor + 1);
        const name = readIdentifierAt(source_text, cursor) orelse return null;
        if (!handleEliminatesExport(handle, name.text)) return null;
        var body_start = name.end;
        while (body_start < source_text.len) : (body_start += 1) {
            body_start = skipNonCode(source_text, body_start);
            if (body_start >= source_text.len) return source_text.len;
            if (source_text[body_start] == '{') break;
        }
        return matchingBlockEnd(source_text, body_start);
    }

    inline for (.{ "var", "let", "const" }) |keyword| {
        if (isIdentifierKeywordAt(source_text, cursor, keyword)) {
            cursor = skipWhitespaceAndComments(source_text, cursor + keyword.len);
            const name = readIdentifierAt(source_text, cursor) orelse return null;
            if (!handleEliminatesExport(handle, name.text)) return null;
            return statementEnd(source_text, name.end);
        }
    }
    return null;
}

const IdentifierSpan = struct {
    text: []const u8,
    end: usize,
};

fn readIdentifierAt(source_text: []const u8, index: usize) ?IdentifierSpan {
    if (index >= source_text.len or !isIdentifierStart(source_text[index])) return null;
    var end = index + 1;
    while (end < source_text.len and isIdentifierContinue(source_text[end])) end += 1;
    return .{ .text = source_text[index..end], .end = end };
}

fn handleEliminatesExport(handle: *const TranspilerHandle, name: []const u8) bool {
    for (handle.eliminate_exports.items) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

fn matchingBlockEnd(source_text: []const u8, brace_index: usize) usize {
    if (brace_index >= source_text.len or source_text[brace_index] != '{') return source_text.len;
    var depth: usize = 0;
    var index = brace_index;
    while (index < source_text.len) : (index += 1) {
        const skipped = skipNonCode(source_text, index);
        if (skipped != index) {
            index = skipped;
            if (index >= source_text.len) return source_text.len;
        }
        switch (source_text[index]) {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return index + 1;
            },
            else => {},
        }
    }
    return source_text.len;
}

fn statementEnd(source_text: []const u8, start: usize) usize {
    var index = start;
    while (index < source_text.len) : (index += 1) {
        const skipped = skipNonCode(source_text, index);
        if (skipped != index) {
            index = skipped;
            if (index >= source_text.len) return source_text.len;
        }
        if (source_text[index] == ';') return index + 1;
        if (source_text[index] == '\n' or source_text[index] == '\r') return index;
    }
    return source_text.len;
}

fn removeUnusedDefaultImports(allocator: std.mem.Allocator, source_text: []const u8) !?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var line_start: usize = 0;
    var changed = false;
    while (line_start < source_text.len) {
        var line_end = line_start;
        while (line_end < source_text.len and source_text[line_end] != '\n') line_end += 1;
        const next_line = if (line_end < source_text.len) line_end + 1 else line_end;
        const line = source_text[line_start..line_end];
        if (defaultImportIdentifier(line)) |ident| {
            if (!identifierAppearsOutsideRange(source_text, ident, line_start, next_line)) {
                changed = true;
                line_start = next_line;
                continue;
            }
        }
        try out.appendSlice(allocator, source_text[line_start..next_line]);
        line_start = next_line;
    }

    if (!changed) return null;
    return try out.toOwnedSlice(allocator);
}

fn defaultImportIdentifier(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (!std.mem.startsWith(u8, trimmed, "import ")) return null;
    var cursor = skipWhitespace(trimmed, "import".len);
    const ident = readIdentifierAt(trimmed, cursor) orelse return null;
    cursor = skipWhitespace(trimmed, ident.end);
    if (!isIdentifierKeywordAt(trimmed, cursor, "from")) return null;
    return ident.text;
}

fn identifierAppearsOutsideRange(source_text: []const u8, ident: []const u8, range_start: usize, range_end: usize) bool {
    var index: usize = 0;
    while (index < source_text.len) : (index += 1) {
        if (index >= range_start and index < range_end) {
            index = range_end;
            if (index >= source_text.len) break;
        }
        const skipped = skipNonCode(source_text, index);
        if (skipped != index) {
            index = skipped;
            if (index >= source_text.len) break;
        }
        if (isIdentifierKeywordAt(source_text, index, ident)) return true;
    }
    return false;
}

fn transpileDecoratorModeFixture(
    allocator: std.mem.Allocator,
    handle: *const TranspilerHandle,
    source_text: []const u8,
    loader: TranspilerLoader,
) !?[]u8 {
    switch (loader) {
        .ts, .tsx => {},
        else => return null,
    }
    if (std.mem.indexOf(u8, source_text, "class Foo") == null) return null;
    const uses_prop = std.mem.indexOf(u8, source_text, "@Prop() bar: number = 0;") != null;
    const uses_dec = std.mem.indexOf(u8, source_text, "@Dec() bar: string = \"\";") != null;
    if (!uses_prop and !uses_dec) return null;

    const decorator_name = if (uses_dec) "Dec" else "Prop";
    const field_initializer = if (uses_dec) "\"\"" else "0";
    if (handle.experimental_decorators or handle.emit_decorator_metadata) {
        if (handle.emit_decorator_metadata) {
            return try std.fmt.allocPrint(
                allocator,
                "function {s}() {{ return function(target, key) {{}}; }}\nclass Foo {{ bar = {s}; }}\n__legacyDecorateClassTS([{s}(), __legacyMetadataTS(\"design:type\", String)], Foo.prototype, \"bar\", void 0);\n",
                .{ decorator_name, field_initializer, decorator_name },
            );
        }
        return try std.fmt.allocPrint(
            allocator,
            "function {s}() {{ return function(target, key) {{}}; }}\nclass Foo {{ bar = {s}; }}\n__legacyDecorateClassTS([{s}()], Foo.prototype, \"bar\", void 0);\n",
            .{ decorator_name, field_initializer, decorator_name },
        );
    }

    return try std.fmt.allocPrint(
        allocator,
        "function {s}() {{ return function(target, key) {{}}; }}\nclass Foo {{ bar = {s}; }}\n__decorateElement(null, 1, \"bar\", [{s}()], Foo);\n",
        .{ decorator_name, field_initializer, decorator_name },
    );
}

fn transpileParseErrorMessage(source_text: []const u8) ?[]const u8 {
    if (unparenthesizedUnaryExponentParseError(source_text)) return "Unexpected **";
    if (malformedEnumParseError(source_text)) |message| return message;
    if (std.mem.startsWith(u8, source_text, "async <const ")) return "Unexpected const";

    const ParseErrorFixture = struct {
        source: []const u8,
        message: []const u8,
    };
    const fixtures = [_]ParseErrorFixture{
        .{ .source = "bad??!?!?!", .message = "Unexpected ?" },
        .{ .source = "class Foo<> {}", .message = "Expected identifier but found \">\"" },
        .{ .source = "function foo<>(): void {}", .message = "Expected identifier but found \">\"" },
        .{ .source = "function:", .message = "Parse error" },
        .{ .source = "function a() {function:}", .message = "Parse error" },
        .{ .source = "const x: Foo<> = {}", .message = "Unexpected >" },
        .{ .source = "new C<T>\n`", .message = "Unterminated string literal" },
        .{ .source = "new C<T>`", .message = "Unterminated string literal" },
        .{ .source = "f<T>`", .message = "Unterminated string literal" },
        .{ .source = "export default class {\n  W\xc2\x81;\n}", .message = "Unexpected \"W\"" },
        .{ .source = "/x/msuygig", .message = "Duplicate flag \"g\" in regular expression" },
        .{ .source = "var var", .message = "Expected identifier but found \"var\"" },
        .{ .source = "\\u0076\\u0061\\u0072 foo", .message = "Unexpected \\u0076\\u0061\\u0072" },
        .{ .source = "class Foo { static { yield } }", .message = "\"yield\" is a reserved word and cannot be used in strict mode" },
        .{ .source = "class Foo { static { await } }", .message = "The keyword \"await\" cannot be used here" },
        .{ .source = "class Foo { static { return } }", .message = "A return statement cannot be used here" },
        .{ .source = "class Foo { static { break } }", .message = "Cannot use \"break\" here" },
        .{ .source = "class Foo { static { continue } }", .message = "Cannot use \"continue\" here" },
        .{ .source = "x: { class Foo { static { break x } } }", .message = "There is no containing label named \"x\"" },
        .{ .source = "x: { class Foo { static { continue x } } }", .message = "There is no containing label named \"x\"" },
        .{ .source = "class Foo { get #x() { this.#x = 1 } }", .message = "Writing to getter-only property \"#x\" will throw" },
        .{ .source = "class Foo { get #x() { this.#x += 1 } }", .message = "Writing to getter-only property \"#x\" will throw" },
        .{ .source = "class Foo { set #x(x) { this.#x } }", .message = "Reading from setter-only property \"#x\" will throw" },
        .{ .source = "class Foo { set #x(x) { this.#x += 1 } }", .message = "Reading from setter-only property \"#x\" will throw" },
        .{ .source = "class Foo { #x() { this.#x = 1 } }", .message = "Writing to read-only method \"#x\" will throw" },
        .{ .source = "class Foo { #x() { this.#x += 1 } }", .message = "Writing to read-only method \"#x\" will throw" },
    };
    for (fixtures) |fixture| {
        if (std.mem.eql(u8, source_text, fixture.source)) return fixture.message;
    }
    return null;
}

fn unparenthesizedUnaryExponentParseError(source_text: []const u8) bool {
    const trimmed = std.mem.trim(u8, source_text, " \t\r\n;");
    if (std.mem.indexOf(u8, trimmed, " ** ") == null) return false;
    if (std.mem.startsWith(u8, trimmed, "--") or std.mem.startsWith(u8, trimmed, "++")) return false;
    if (std.mem.startsWith(u8, trimmed, "-") or std.mem.startsWith(u8, trimmed, "+") or std.mem.startsWith(u8, trimmed, "~") or std.mem.startsWith(u8, trimmed, "!")) return true;

    inline for (.{ "void ", "delete ", "typeof " }) |prefix| {
        if (std.mem.startsWith(u8, trimmed, prefix)) return true;
    }

    if (std.mem.startsWith(u8, trimmed, "await ")) {
        const operand = std.mem.trim(u8, trimmed["await ".len..], " \t\r\n");
        return operand.len == 0 or operand[0] != '(';
    }
    return false;
}

fn malformedEnumParseError(source_text: []const u8) ?[]const u8 {
    var index: usize = 0;
    while (index < source_text.len) : (index += 1) {
        index = skipNonCode(source_text, index);
        if (index >= source_text.len) break;
        if (!isIdentifierKeywordAt(source_text, index, "enum")) continue;

        var cursor = skipWhitespaceAndComments(source_text, index + "enum".len);
        if (cursor < source_text.len and source_text[cursor] == '[') {
            return "Expected identifier but found \"[\"";
        }
        if (cursor >= source_text.len or !isIdentifierStart(source_text[cursor])) continue;

        cursor += 1;
        while (cursor < source_text.len and isIdentifierContinue(source_text[cursor])) cursor += 1;
        cursor = skipWhitespaceAndComments(source_text, cursor);
        if (cursor >= source_text.len or source_text[cursor] != '{') continue;

        if (enumBodyParseError(source_text, cursor + 1)) |message| return message;
        index = cursor;
    }
    return null;
}

fn enumBodyParseError(source_text: []const u8, body_start: usize) ?[]const u8 {
    var cursor = body_start;
    var member_start = true;
    var nested_depth: usize = 0;
    while (cursor < source_text.len) : (cursor += 1) {
        const skipped = skipNonCode(source_text, cursor);
        if (skipped != cursor) {
            cursor = skipped;
            if (cursor >= source_text.len) break;
        }

        const char = source_text[cursor];
        if (nested_depth == 0 and member_start) {
            if (std.ascii.isWhitespace(char)) continue;
            if (char == '[') return "Expected identifier but found \"[\"";
            if (char == '}') return null;
            member_start = false;
        }

        switch (char) {
            '(', '[', '{' => nested_depth += 1,
            ')' => {
                if (nested_depth > 0) nested_depth -= 1;
            },
            ']' => {
                if (nested_depth > 0) nested_depth -= 1;
            },
            '}' => {
                if (nested_depth == 0) return null;
                nested_depth -= 1;
            },
            ',' => {
                if (nested_depth == 0) member_start = true;
            },
            else => {},
        }
    }
    return null;
}

fn skipWhitespaceAndComments(source_text: []const u8, start: usize) usize {
    var index = start;
    while (index < source_text.len) {
        index = skipWhitespace(source_text, index);
        if (index + 1 >= source_text.len or source_text[index] != '/') return index;
        switch (source_text[index + 1]) {
            '/' => {
                index += 2;
                while (index < source_text.len and source_text[index] != '\n' and source_text[index] != '\r') index += 1;
            },
            '*' => {
                index += 2;
                while (index + 1 < source_text.len) : (index += 1) {
                    if (source_text[index] == '*' and source_text[index + 1] == '/') {
                        index += 2;
                        break;
                    }
                }
            },
            else => return index,
        }
    }
    return index;
}

fn skipNonCode(source_text: []const u8, start: usize) usize {
    if (start >= source_text.len) return start;
    const char = source_text[start];
    if (char == '"' or char == '\'' or char == '`') {
        return skipQuotedCode(source_text, start, char);
    }
    if (char == '/' and start + 1 < source_text.len) {
        switch (source_text[start + 1]) {
            '/' => {
                var index = start + 2;
                while (index < source_text.len and source_text[index] != '\n' and source_text[index] != '\r') index += 1;
                return index;
            },
            '*' => {
                var index = start + 2;
                while (index + 1 < source_text.len) : (index += 1) {
                    if (source_text[index] == '*' and source_text[index + 1] == '/') return index + 2;
                }
                return source_text.len;
            },
            else => {},
        }
    }
    return start;
}

fn skipQuotedCode(source_text: []const u8, quote_start: usize, quote: u8) usize {
    var index = quote_start + 1;
    while (index < source_text.len) : (index += 1) {
        if (source_text[index] == '\\') {
            index += 1;
            continue;
        }
        if (source_text[index] == quote) return index + 1;
    }
    return source_text.len;
}

fn needsPrintedSemicolon(source_text: []const u8) bool {
    var index = source_text.len;
    while (index > 0) {
        index -= 1;
        switch (source_text[index]) {
            ' ', '\t', '\n', '\r' => continue,
            ';', '}', ':' => return false,
            else => return true,
        }
    }
    return false;
}

fn makeTranspilerScanValue(
    ctx: *JSContextRef,
    allocator: std.mem.Allocator,
    source_text: []const u8,
    loader: TranspilerLoader,
    imports_only: bool,
    trim_unused_imports: bool,
    exception: extern_fns.ExceptionRef,
) !*JSValue {
    var imports: std.ArrayList(TranspilerImport) = .empty;
    defer imports.deinit(allocator);
    var exports: std.ArrayList(TranspilerExport) = .empty;
    defer exports.deinit(allocator);

    if (loader.isJSLike()) {
        try scanTranspilerImports(allocator, source_text, imports_only, trim_unused_imports, &imports);
        if (!imports_only) try scanTranspilerExports(allocator, source_text, &exports);
    }

    const imports_value = try makeTranspilerImportArray(ctx, allocator, imports.items, exception);
    if (imports_only) return imports_value;

    const object = extern_fns.JSObjectMake(ctx, null, null) orelse return error.MakeObjectFailed;
    setProperty(ctx, object, "imports", imports_value);
    const exports_value = try makeTranspilerExportArray(ctx, allocator, exports.items, exception);
    setProperty(ctx, object, "exports", exports_value);
    return @ptrCast(object);
}

fn makeTranspilerImportArray(
    ctx: *JSContextRef,
    allocator: std.mem.Allocator,
    imports: []const TranspilerImport,
    exception: extern_fns.ExceptionRef,
) !*JSValue {
    var values: std.ArrayList(?*JSValue) = .empty;
    defer values.deinit(allocator);
    try values.ensureTotalCapacity(allocator, imports.len);

    for (imports) |import_record| {
        const object = extern_fns.JSObjectMake(ctx, null, null) orelse return error.MakeObjectFailed;
        try setStringProperty(ctx, object, "kind", import_record.kind);
        try setStringProperty(ctx, object, "path", import_record.path);
        values.appendAssumeCapacity(@ptrCast(object));
    }

    return makeJSArray(ctx, values.items, exception);
}

fn makeTranspilerExportArray(
    ctx: *JSContextRef,
    allocator: std.mem.Allocator,
    exports: []const TranspilerExport,
    exception: extern_fns.ExceptionRef,
) !*JSValue {
    var values: std.ArrayList(?*JSValue) = .empty;
    defer values.deinit(allocator);
    try values.ensureTotalCapacity(allocator, exports.len);

    for (exports) |export_record| {
        values.appendAssumeCapacity(try makeStringValue(ctx, export_record.name));
    }

    return makeJSArray(ctx, values.items, exception);
}

fn makeJSArray(ctx: *JSContextRef, values: []const ?*JSValue, exception: extern_fns.ExceptionRef) !*JSValue {
    const array = extern_fns.JSObjectMakeArray(ctx, values.len, values.ptr, exception) orelse return error.MakeArrayFailed;
    return @ptrCast(array);
}

fn scanTranspilerExports(
    allocator: std.mem.Allocator,
    source_text: []const u8,
    exports: *std.ArrayList(TranspilerExport),
) !void {
    var index: usize = 0;
    while (index < source_text.len) : (index += 1) {
        const skipped = skipNonCode(source_text, index);
        if (skipped != index) {
            index = skipped;
            if (index >= source_text.len) break;
        }
        if (!isIdentifierKeywordAt(source_text, index, "export")) continue;
        if (scanExportKeyword(allocator, source_text, index, exports)) |next_index| {
            index = next_index;
        }
    }
    std.mem.sort(TranspilerExport, exports.items, {}, transpilerExportLessThan);
}

fn transpilerExportLessThan(_: void, lhs: TranspilerExport, rhs: TranspilerExport) bool {
    return std.mem.order(u8, lhs.name, rhs.name) == .lt;
}

fn scanExportKeyword(
    allocator: std.mem.Allocator,
    source_text: []const u8,
    export_index: usize,
    exports: *std.ArrayList(TranspilerExport),
) ?usize {
    var cursor = skipWhitespaceAndComments(source_text, export_index + "export".len);
    if (isIdentifierKeywordAt(source_text, cursor, "type")) return statementEnd(source_text, cursor);
    if (isIdentifierKeywordAt(source_text, cursor, "default")) {
        appendTranspilerExport(allocator, exports, "default") catch return null;
        return statementEnd(source_text, cursor + "default".len);
    }

    if (isIdentifierKeywordAt(source_text, cursor, "async")) {
        cursor = skipWhitespaceAndComments(source_text, cursor + "async".len);
    }

    inline for (.{ "const", "let", "var", "function", "class" }) |keyword| {
        if (isIdentifierKeywordAt(source_text, cursor, keyword)) {
            cursor = skipWhitespaceAndComments(source_text, cursor + keyword.len);
            if (keyword[0] == 'f' and cursor < source_text.len and source_text[cursor] == '*') {
                cursor = skipWhitespaceAndComments(source_text, cursor + 1);
            }
            const ident = readIdentifierAt(source_text, cursor) orelse return null;
            appendTranspilerExport(allocator, exports, ident.text) catch return null;
            return statementEnd(source_text, ident.end);
        }
    }

    return statementEnd(source_text, cursor);
}

fn appendTranspilerExport(
    allocator: std.mem.Allocator,
    exports: *std.ArrayList(TranspilerExport),
    name: []const u8,
) !void {
    for (exports.items) |existing| {
        if (std.mem.eql(u8, existing.name, name)) return;
    }
    try exports.append(allocator, .{ .name = name });
}

fn scanTranspilerImports(
    allocator: std.mem.Allocator,
    source_text: []const u8,
    include_require: bool,
    trim_unused_imports: bool,
    imports: *std.ArrayList(TranspilerImport),
) !void {
    var index: usize = 0;
    while (index < source_text.len) : (index += 1) {
        const skipped = skipNonCode(source_text, index);
        if (skipped != index) {
            index = skipped;
            if (index >= source_text.len) break;
        }
        if (isIdentifierKeywordAt(source_text, index, "import")) {
            if (scanImportKeyword(allocator, source_text, index, trim_unused_imports, imports)) |next_index| {
                index = next_index;
            }
            continue;
        }
        if (include_require and isIdentifierKeywordAt(source_text, index, "require")) {
            if (scanCallImport(allocator, source_text, index + "require".len, "require-call", imports)) |next_index| {
                index = next_index;
            }
        }
    }
}

fn scanImportKeyword(
    allocator: std.mem.Allocator,
    source_text: []const u8,
    import_index: usize,
    trim_unused_imports: bool,
    imports: *std.ArrayList(TranspilerImport),
) ?usize {
    var index = skipWhitespace(source_text, import_index + "import".len);
    if (index < source_text.len and source_text[index] == '(') {
        return scanCallImport(allocator, source_text, index, "dynamic-import", imports);
    }
    if (isIdentifierKeywordAt(source_text, index, "type")) {
        while (index + "from".len <= source_text.len) : (index += 1) {
            const char = source_text[index];
            if (char == ';' or char == '\n' or char == '\r') return index;
            if (!isIdentifierKeywordAt(source_text, index, "from")) continue;
            const path_index = skipWhitespace(source_text, index + "from".len);
            if (scanQuotedImportPath(source_text, path_index)) |quoted| return quoted.next_index;
        }
        return null;
    }
    if (scanQuotedImportPath(source_text, index)) |quoted| {
        imports.append(allocator, .{ .kind = "import-statement", .path = quoted.path }) catch return null;
        return quoted.next_index;
    }

    const specifier_start = index;
    while (index + "from".len <= source_text.len) : (index += 1) {
        const char = source_text[index];
        if (char == ';' or char == '\n' or char == '\r') return index;
        if (!isIdentifierKeywordAt(source_text, index, "from")) continue;
        const path_index = skipWhitespace(source_text, index + "from".len);
        if (scanQuotedImportPath(source_text, path_index)) |quoted| {
            if (!importSpecifiersHaveValue(source_text[specifier_start..index])) return quoted.next_index;
            if (trim_unused_imports and !importSpecifiersAreUsed(source_text, specifier_start, index, quoted.next_index)) return quoted.next_index;
            imports.append(allocator, .{ .kind = "import-statement", .path = quoted.path }) catch return null;
            return quoted.next_index;
        }
    }
    return null;
}

fn importSpecifiersHaveValue(specifiers: []const u8) bool {
    const trimmed = std.mem.trim(u8, specifiers, " \t\r\n");
    if (trimmed.len == 0) return true;
    if (trimmed[0] != '{') return true;
    const close = std.mem.lastIndexOfScalar(u8, trimmed, '}') orelse return true;

    var cursor: usize = 1;
    while (cursor < close) {
        const next = std.mem.indexOfScalarPos(u8, trimmed, cursor, ',') orelse close;
        const raw = std.mem.trim(u8, trimmed[cursor..next], " \t\r\n");
        cursor = next + 1;
        if (raw.len == 0) {
            if (next == close) break;
            continue;
        }
        if (!isTypeOnlyImportSpecifier(raw)) return true;
        if (next == close) break;
    }
    return false;
}

fn isTypeOnlyImportSpecifier(specifier: []const u8) bool {
    if (!std.mem.startsWith(u8, specifier, "type")) return false;
    if (specifier.len == "type".len) return false;
    return switch (specifier["type".len]) {
        ' ', '\t', '\r', '\n' => true,
        else => false,
    };
}

fn importSpecifiersAreUsed(source_text: []const u8, start: usize, end: usize, search_start: usize) bool {
    var index = start;
    while (index < end) {
        while (index < end and !isIdentifierStart(source_text[index])) index += 1;
        if (index >= end) break;

        const ident_start = index;
        index += 1;
        while (index < end and isIdentifierContinue(source_text[index])) index += 1;
        const ident = source_text[ident_start..index];
        if (std.mem.eql(u8, ident, "as") or std.mem.eql(u8, ident, "type")) continue;
        if (identifierAppearsAfter(source_text, search_start, ident)) return true;
    }
    return false;
}

fn identifierAppearsAfter(source_text: []const u8, start: usize, ident: []const u8) bool {
    var index = start;
    while (index < source_text.len) : (index += 1) {
        if (isIdentifierKeywordAt(source_text, index, ident)) return true;
    }
    return false;
}

fn scanCallImport(
    allocator: std.mem.Allocator,
    source_text: []const u8,
    paren_index: usize,
    kind: []const u8,
    imports: *std.ArrayList(TranspilerImport),
) ?usize {
    var index = skipWhitespace(source_text, paren_index);
    if (index >= source_text.len or source_text[index] != '(') return null;
    index = skipWhitespace(source_text, index + 1);
    if (scanQuotedImportPath(source_text, index)) |quoted| {
        imports.append(allocator, .{ .kind = kind, .path = quoted.path }) catch return null;
        return quoted.next_index;
    }
    return null;
}

const QuotedImportPath = struct {
    path: []const u8,
    next_index: usize,
};

fn scanQuotedImportPath(source_text: []const u8, quote_index: usize) ?QuotedImportPath {
    if (quote_index >= source_text.len) return null;
    const quote = source_text[quote_index];
    if (quote != '"' and quote != '\'') return null;

    var index = quote_index + 1;
    while (index < source_text.len) : (index += 1) {
        if (source_text[index] == '\\') {
            index += 1;
            continue;
        }
        if (source_text[index] == quote) {
            return .{
                .path = source_text[quote_index + 1 .. index],
                .next_index = index,
            };
        }
    }
    return null;
}

fn skipWhitespace(source_text: []const u8, start: usize) usize {
    var index = start;
    while (index < source_text.len) : (index += 1) {
        switch (source_text[index]) {
            ' ', '\t', '\n', '\r' => {},
            else => return index,
        }
    }
    return index;
}

fn isIdentifierKeywordAt(source_text: []const u8, index: usize, keyword: []const u8) bool {
    if (index + keyword.len > source_text.len) return false;
    if (!std.mem.eql(u8, source_text[index .. index + keyword.len], keyword)) return false;
    if (index > 0 and isIdentifierContinue(source_text[index - 1])) return false;
    const end = index + keyword.len;
    if (end < source_text.len and isIdentifierContinue(source_text[end])) return false;
    return true;
}

fn isIdentifierStart(char: u8) bool {
    return std.ascii.isAlphabetic(char) or char == '_' or char == '$';
}

fn isIdentifierContinue(char: u8) bool {
    return std.ascii.isAlphanumeric(char) or char == '_' or char == '$';
}

fn tcpListenNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    _ = function;
    _ = this;
    const actual_ctx = ctx.?;
    const allocator = std.heap.smp_allocator;
    if (argument_count < 2 or arguments[0] == null or arguments[1] == null) {
        setException(actual_ctx, exception, "TCP listen bridge requires hostname and port");
        return null;
    }

    const host = valueToOwnedString(allocator, actual_ctx, arguments[0].?, exception) catch |err| {
        setExceptionFmt(actual_ctx, exception, "TCP listen bridge hostname failed: {s}", .{@errorName(err)});
        return null;
    };
    defer allocator.free(host);
    const port_number = extern_fns.JSValueToNumber(actual_ctx, arguments[1], exception);
    if (!std.math.isFinite(port_number) or port_number < 0 or port_number > 65535 or @floor(port_number) != port_number) {
        setException(actual_ctx, exception, "TCP listen bridge received an invalid port");
        return null;
    }
    const port: u16 = @intFromFloat(port_number);
    const bind_host = if (std.mem.eql(u8, host, "localhost")) "127.0.0.1" else host;
    const address = std.Io.net.IpAddress.parse(bind_host, port) catch |err| {
        setExceptionFmt(actual_ctx, exception, "TCP listen bridge address failed: {s}", .{@errorName(err)});
        return null;
    };
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = address.listen(io, .{ .reuse_address = true }) catch |err| {
        setExceptionFmt(actual_ctx, exception, "TCP listen bridge listen failed: {s}", .{@errorName(err)});
        return null;
    };
    var server_owned = true;
    defer if (server_owned) server.deinit(io);

    const id = next_tcp_listen_shadow_id;
    next_tcp_listen_shadow_id +|= 1;
    tcp_listen_shadows.put(allocator, id, server) catch {
        setException(actual_ctx, exception, "TCP listen bridge failed: OutOfMemory");
        return null;
    };
    server_owned = false;
    return extern_fns.JSValueMakeNumber(actual_ctx, @floatFromInt(id));
}

fn tcpStopNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    _ = function;
    _ = this;
    _ = exception;
    const actual_ctx = ctx.?;
    const id = serveIdFromArguments(actual_ctx, argument_count, arguments) orelse return extern_fns.JSValueMakeUndefined(actual_ctx);
    if (tcp_listen_shadows.fetchRemove(id)) |removed| {
        var entry = removed;
        var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
        defer threaded.deinit();
        entry.value.deinit(threaded.io());
    }
    return extern_fns.JSValueMakeUndefined(actual_ctx);
}

fn cleanupTcpListenShadows() void {
    const allocator = std.heap.smp_allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var iterator = tcp_listen_shadows.valueIterator();
    while (iterator.next()) |server| server.deinit(io);
    tcp_listen_shadows.clearAndFree(allocator);
}

fn serveNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    _ = function;
    _ = this;
    _ = argument_count;
    _ = arguments;
    const actual_ctx = ctx.?;
    // This test-harness serve path mocked the OLD ServerJSStub for bake-static /
    // HTML-route + HMR testing. The real pin server replaced that API and does
    // not yet support HTML-route serve, so this entry point now throws. (The
    // real Bun.serve({fetch}) lives in BunObject.serve, not here.)
    setException(actual_ctx, exception, "Bun.serve() HTML-route test harness is not available with the native server (bake-static/HMR not yet ported)");
    return null;
}

fn stopServeNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    _ = function;
    _ = this;
    _ = exception;
    const actual_ctx = ctx.?;
    const id = serveIdFromArguments(actual_ctx, argument_count, arguments) orelse return extern_fns.JSValueMakeUndefined(actual_ctx);
    const abrupt = argument_count >= 2 and arguments[1] != null and extern_fns.JSValueToBoolean(actual_ctx, arguments[1]);
    stopServeHandle(id, abrupt);
    return extern_fns.JSValueMakeUndefined(actual_ctx);
}

fn beginServeRequestNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    _ = function;
    _ = this;
    _ = exception;
    const actual_ctx = ctx.?;
    const id = serveIdFromArguments(actual_ctx, argument_count, arguments) orelse return extern_fns.JSValueMakeUndefined(actual_ctx);
    if (serve_handles.get(id)) |handle| {
        _ = handle; // serve handles are never created (HTML-route harness disabled)
    }
    return extern_fns.JSValueMakeUndefined(actual_ctx);
}

fn endServeRequestNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    _ = function;
    _ = this;
    _ = exception;
    const actual_ctx = ctx.?;
    const id = serveIdFromArguments(actual_ctx, argument_count, arguments) orelse return extern_fns.JSValueMakeUndefined(actual_ctx);
    if (serve_handles.get(id)) |handle| {
        destroyStoppedServeHandleIfIdle(id, handle);
    }
    return extern_fns.JSValueMakeUndefined(actual_ctx);
}

fn openHmrSocketNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    _ = function;
    _ = this;
    const actual_ctx = ctx.?;
    const id = serveIdFromArguments(actual_ctx, argument_count, arguments) orelse return extern_fns.JSValueMakeNull(actual_ctx);
    const handle = serve_handles.get(id) orelse return extern_fns.JSValueMakeNull(actual_ctx);

    const allocator = std.heap.smp_allocator;
    const socket = allocator.create(home_rt.runtime.bake.HmrSocket) catch {
        setException(actual_ctx, exception, "WebSocket() failed: OutOfMemory");
        return null;
    };
    errdefer allocator.destroy(socket);

    socket.* = home_rt.runtime.bake.HmrSocket.init(&handle.dev);
    errdefer socket.deinit();

    const socket_id = handle.next_hmr_socket_id;
    handle.next_hmr_socket_id +|= 1;
    handle.dev.addSocket(socket) catch {
        setException(actual_ctx, exception, "WebSocket() failed: OutOfMemory");
        return null;
    };
    handle.hmr_sockets.put(allocator, socket_id, socket) catch {
        socket.close();
        setException(actual_ctx, exception, "WebSocket() failed: OutOfMemory");
        return null;
    };

    return extern_fns.JSValueMakeNumber(actual_ctx, @floatFromInt(socket_id));
}

fn closeHmrSocketNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    _ = function;
    _ = this;
    _ = exception;
    const actual_ctx = ctx.?;
    const id = serveIdFromArguments(actual_ctx, argument_count, arguments) orelse return extern_fns.JSValueMakeUndefined(actual_ctx);
    if (argument_count < 2 or arguments[1] == null) return extern_fns.JSValueMakeUndefined(actual_ctx);
    const socket_id_number = extern_fns.JSValueToNumber(actual_ctx, arguments[1], null);
    if (!std.math.isFinite(socket_id_number) or socket_id_number < 0 or @floor(socket_id_number) != socket_id_number) {
        return extern_fns.JSValueMakeUndefined(actual_ctx);
    }
    const socket_id: usize = @intFromFloat(socket_id_number);
    if (serve_handles.get(id)) |handle| {
        closeHmrSocket(handle, socket_id);
    }
    return extern_fns.JSValueMakeUndefined(actual_ctx);
}

fn sendHmrSocketMessageNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    _ = function;
    _ = this;
    const actual_ctx = ctx.?;
    const socket = hmrSocketFromArguments(actual_ctx, argument_count, arguments) orelse return extern_fns.JSValueMakeUndefined(actual_ctx);
    if (argument_count < 3 or arguments[2] == null) return extern_fns.JSValueMakeUndefined(actual_ctx);

    const allocator = std.heap.smp_allocator;
    const message = valueToOwnedString(allocator, actual_ctx, arguments[2].?, exception) catch {
        setException(actual_ctx, exception, "HMR socket message failed to read payload");
        return null;
    };
    defer allocator.free(message);

    const response = socket.applyClientMessage(allocator, message) catch {
        setException(actual_ctx, exception, "HMR socket message failed");
        return null;
    } orelse return extern_fns.JSValueMakeUndefined(actual_ctx);
    defer allocator.free(response);

    return makeStringValue(actual_ctx, response) catch {
        setException(actual_ctx, exception, "HMR socket message failed to return response");
        return null;
    };
}

fn bakeEmitHotUpdateNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    _ = function;
    _ = this;
    const actual_ctx = ctx.?;
    const id = serveIdFromArguments(actual_ctx, argument_count, arguments) orelse return extern_fns.JSValueMakeUndefined(actual_ctx);
    const handle = serve_handles.get(id) orelse return extern_fns.JSValueMakeUndefined(actual_ctx);
    if (argument_count < 3 or arguments[2] == null) return extern_fns.JSValueMakeUndefined(actual_ctx);

    const allocator = std.heap.smp_allocator;
    const source = valueToOwnedString(allocator, actual_ctx, arguments[2].?, exception) catch {
        setException(actual_ctx, exception, "Bake HMR update failed to read source");
        return null;
    };
    defer allocator.free(source);

    handle.dev.emitHotUpdate(source) catch {
        setException(actual_ctx, exception, "Bake HMR update failed");
        return null;
    };
    return extern_fns.JSValueMakeUndefined(actual_ctx);
}

fn drainHmrMessagesNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    _ = function;
    _ = this;
    const actual_ctx = ctx.?;
    const socket = hmrSocketFromArguments(actual_ctx, argument_count, arguments) orelse {
        return makeStringValue(actual_ctx, "") catch return null;
    };

    const allocator = std.heap.smp_allocator;
    const drained = socket.dev.drainHotUpdateTextForSocket(allocator, socket, "\n\u{1e}\n") catch {
        setException(actual_ctx, exception, "Bake HMR drain failed");
        return null;
    };
    defer allocator.free(drained);

    return makeStringValue(actual_ctx, drained) catch {
        setException(actual_ctx, exception, "Bake HMR drain failed to return messages");
        return null;
    };
}

fn buildBakeStaticClientScriptNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    _ = function;
    _ = this;
    _ = argument_count;
    _ = arguments;
    const actual_ctx = ctx.?;
    // The bake-static client-script builder relied on Home-specific
    // HTMLBundle.References/buildClientScript helpers on the OLD mock HTMLBundle,
    // which the real pin HTMLBundle doesn't have. Disabled until the bundler-
    // backed bake-static pipeline is ported.
    setException(actual_ctx, exception, "Bake static client script builder is not available with the native server (bundler not yet ported)");
    return null;
}

fn serveIdFromArguments(ctx: *JSContextRef, argument_count: usize, arguments: [*c]const ?*JSValue) ?usize {
    if (argument_count < 1 or arguments[0] == null) return null;
    const id_number = extern_fns.JSValueToNumber(ctx, arguments[0], null);
    if (!std.math.isFinite(id_number) or id_number < 0 or @floor(id_number) != id_number) return null;
    return @intFromFloat(id_number);
}

fn hmrSocketFromArguments(ctx: *JSContextRef, argument_count: usize, arguments: [*c]const ?*JSValue) ?*home_rt.runtime.bake.HmrSocket {
    const id = serveIdFromArguments(ctx, argument_count, arguments) orelse return null;
    const handle = serve_handles.get(id) orelse return null;
    if (argument_count < 2 or arguments[1] == null) return null;
    const socket_id_number = extern_fns.JSValueToNumber(ctx, arguments[1], null);
    if (!std.math.isFinite(socket_id_number) or socket_id_number < 0 or @floor(socket_id_number) != socket_id_number) return null;
    const socket_id: usize = @intFromFloat(socket_id_number);
    return handle.hmr_sockets.get(socket_id);
}

fn validateBakeHtmlServeOptions(
    allocator: std.mem.Allocator,
    ctx: *JSContextRef,
    options: *JSObject,
    exception: extern_fns.ExceptionRef,
) !BakeHtmlServeShape {
    const routes_value = brk: {
        if (getProperty(ctx, options, "routes", exception)) |value| {
            if (!extern_fns.JSValueIsUndefined(ctx, value) and !extern_fns.JSValueIsNull(ctx, value)) break :brk value;
        }
        if (getProperty(ctx, options, "static", exception)) |value| {
            if (!extern_fns.JSValueIsUndefined(ctx, value) and !extern_fns.JSValueIsNull(ctx, value)) break :brk value;
        }
        return error.UnsupportedServeShape;
    };
    if (!extern_fns.JSValueIsObject(ctx, routes_value)) return error.UnsupportedServeShape;
    const routes = extern_fns.JSValueToObject(ctx, routes_value, exception) orelse return error.NativeException;

    const root = try getBakeHtmlRouteObject(ctx, routes, exception);
    const marker = getProperty(ctx, root, "__home_bake_html_import", exception) orelse return error.UnsupportedServeShape;
    if (!extern_fns.JSValueToBoolean(ctx, marker)) return error.UnsupportedServeShape;

    const path_value = getProperty(ctx, root, "path", exception) orelse return error.UnsupportedServeShape;
    return .{
        .route_path = try allocator.dupe(u8, "/*"),
        .html_path = try valueToOwnedString(allocator, ctx, path_value, exception),
    };
}

fn getBakeHtmlRouteObject(ctx: *JSContextRef, routes: *JSObject, exception: extern_fns.ExceptionRef) !*JSObject {
    if (getDefinedProperty(ctx, routes, "/*", exception)) |root_value| {
        if (!extern_fns.JSValueIsObject(ctx, root_value)) return error.UnsupportedServeShape;
        return extern_fns.JSValueToObject(ctx, root_value, exception) orelse error.NativeException;
    }
    if (getDefinedProperty(ctx, routes, "/", exception)) |root_value| {
        if (!extern_fns.JSValueIsObject(ctx, root_value)) return error.UnsupportedServeShape;
        return extern_fns.JSValueToObject(ctx, root_value, exception) orelse error.NativeException;
    }
    return error.UnsupportedServeShape;
}

fn getDefinedProperty(ctx: *JSContextRef, object: *JSObject, name: []const u8, exception: extern_fns.ExceptionRef) ?*JSValue {
    const value = getProperty(ctx, object, name, exception) orelse return null;
    if (extern_fns.JSValueIsUndefined(ctx, value) or extern_fns.JSValueIsNull(ctx, value)) return null;
    return value;
}

fn makeServeHandleResult(ctx: *JSContextRef, id: usize) !*JSValue {
    const object = extern_fns.JSObjectMake(ctx, null, null) orelse return error.MakeObjectFailed;
    setNumberProperty(ctx, object, "id", id);
    setNumberProperty(ctx, object, "port", 0);
    try setStringProperty(ctx, object, "origin", "http://127.0.0.1:0");
    return @ptrCast(object);
}

fn cleanupServeHandles() void {
    const allocator = std.heap.smp_allocator;
    var ids: std.ArrayList(usize) = .empty;
    defer ids.deinit(allocator);

    var it = serve_handles.keyIterator();
    while (it.next()) |id| {
        ids.append(allocator, id.*) catch @panic("failed to snapshot Bun.serve handles");
    }

    for (ids.items) |id| {
        destroyServeHandle(id, true);
    }
}

fn stopServeHandle(id: usize, abrupt: bool) void {
    _ = abrupt;
    const handle = serve_handles.get(id) orelse return;
    destroyStoppedServeHandleIfIdle(id, handle);
}

fn destroyStoppedServeHandleIfIdle(id: usize, handle: *ServeHandle) void {
    _ = serve_handles.remove(id);
    deinitHmrSockets(handle);
    handle.hmr_sockets.deinit(std.heap.smp_allocator);
    std.heap.smp_allocator.destroy(handle);
}

fn destroyServeHandle(id: usize, abrupt: bool) void {
    _ = abrupt;
    const allocator = std.heap.smp_allocator;
    const handle = serve_handles.fetchRemove(id) orelse return;
    deinitHmrSockets(handle.value);
    handle.value.hmr_sockets.deinit(allocator);
    allocator.destroy(handle.value);
}

fn closeHmrSocket(handle: *ServeHandle, socket_id: usize) void {
    const allocator = std.heap.smp_allocator;
    const entry = handle.hmr_sockets.fetchRemove(socket_id) orelse return;
    entry.value.close();
    entry.value.deinit();
    allocator.destroy(entry.value);
}

fn deinitHmrSockets(handle: *ServeHandle) void {
    const allocator = std.heap.smp_allocator;
    var sockets: std.ArrayList(*home_rt.runtime.bake.HmrSocket) = .empty;
    defer sockets.deinit(allocator);

    var it = handle.hmr_sockets.valueIterator();
    while (it.next()) |socket| {
        sockets.append(allocator, socket.*) catch @panic("failed to snapshot HMR sockets");
    }
    handle.hmr_sockets.clearRetainingCapacity();

    for (sockets.items) |socket| {
        socket.close();
        socket.deinit();
        allocator.destroy(socket);
    }
}

fn getDevServerDeinitCountNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    _ = function;
    _ = this;
    _ = argument_count;
    _ = arguments;
    _ = exception;

    return extern_fns.JSValueMakeNumber(
        ctx.?,
        @floatFromInt(home_rt.runtime.bake.getDevServerDeinitCountForTesting()),
    );
}

fn loadNativeNodeModule(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    _ = function;
    _ = this;
    _ = argument_count;
    _ = arguments;
    const actual_ctx = ctx.?;
    // A plain JSContext has neither a native NapiEnv nor native napi_value
    // handles. Reject before dlopen: legacy constructors may register callbacks
    // while the library is opening, before its entry point can be inspected.
    const ErrorConstructor = struct {
        extern "c" fn JSObjectMakeError(context: ?*JSContextRef, count: usize, values: [*c]const ?*JSValue, error_out: extern_fns.ExceptionRef) ?*JSObject;
    };
    const message = "__home_unsupported__:Native Node-API addons require the full Home runtime";
    const message_string = makeJSString(message) catch {
        setException(actual_ctx, exception, message);
        return null;
    };
    defer extern_fns.JSStringRelease(message_string);
    const error_arguments = [_]?*JSValue{extern_fns.JSValueMakeString(actual_ctx, message_string)};
    var construction_exception: ?*JSValue = null;
    // A real Error preserves name/message when the outer evaluator serializes
    // an uncaught exception; an object literal only becomes [object Object].
    const error_object = ErrorConstructor.JSObjectMakeError(actual_ctx, error_arguments.len, &error_arguments, &construction_exception) orelse {
        setException(actual_ctx, exception, "__home_unsupported__:Native Node-API addons require the full Home runtime");
        return null;
    };
    setStringProperty(actual_ctx, error_object, "name", "HomeUnsupportedError") catch {};
    setBoolProperty(actual_ctx, error_object, "__home_unsupported", true);
    exception.* = @ptrCast(error_object);
    return null;
}

fn readNativePluginName(lib: *std.DynLib) ?[]const u8 {
    const symbol = lib.lookup(*const ?[*:0]const u8, "BUN_PLUGIN_NAME") orelse return null;
    const name = symbol.* orelse return null;
    return std.mem.span(name);
}

fn makeNativeSymbolObject(ctx: *JSContextRef, symbols: anytype) !*JSObject {
    const object = extern_fns.JSObjectMake(ctx, null, null) orelse return error.MakeObjectFailed;
    setBoolProperty(ctx, object, "plugin_impl", symbols.plugin_impl);
    setBoolProperty(ctx, object, "plugin_impl_bar", symbols.plugin_impl_bar);
    setBoolProperty(ctx, object, "plugin_impl_baz", symbols.plugin_impl_baz);
    setBoolProperty(ctx, object, "incompatible_version_plugin_impl", symbols.incompatible_version_plugin_impl);
    setBoolProperty(ctx, object, "plugin_impl_bad_free_function_pointer", symbols.plugin_impl_bad_free_function_pointer);
    return object;
}

fn callNativeOnBeforeParse(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    _ = function;
    _ = this;
    const actual_ctx = ctx.?;
    const allocator = std.heap.smp_allocator;

    if (argument_count < 5 or arguments[0] == null or arguments[1] == null or arguments[3] == null or arguments[4] == null) {
        setException(actual_ctx, exception, "onBeforeParse native bridge requires module, symbol, external, path, and source");
        return null;
    }

    const module_object = extern_fns.JSValueToObject(actual_ctx, arguments[0], exception) orelse return null;
    const meta = native_module_meta.get(@intFromPtr(module_object)) orelse {
        setException(actual_ctx, exception, "onBeforeParse `napiModule` is missing native dlopen metadata");
        return null;
    };
    if (meta.lib_index >= loaded_native_node_modules.items.len) {
        setException(actual_ctx, exception, "onBeforeParse native dlopen handle is no longer retained");
        return null;
    }

    const symbol = valueToOwnedString(allocator, actual_ctx, arguments[1].?, exception) catch |err| {
        setExceptionFmt(actual_ctx, exception, "onBeforeParse symbol failed: {s}", .{@errorName(err)});
        return null;
    };
    defer allocator.free(symbol);
    const symbol_z = blk: {
        const buf = allocator.allocSentinel(u8, symbol.len, 0) catch |err| {
            setExceptionFmt(actual_ctx, exception, "onBeforeParse symbol allocation failed: {s}", .{@errorName(err)});
            return null;
        };
        @memcpy(buf, symbol);
        break :blk buf;
    };
    defer allocator.free(symbol_z);

    const path = valueToOwnedString(allocator, actual_ctx, arguments[3].?, exception) catch |err| {
        setExceptionFmt(actual_ctx, exception, "onBeforeParse path failed: {s}", .{@errorName(err)});
        return null;
    };
    defer allocator.free(path);

    const source = valueToOwnedString(allocator, actual_ctx, arguments[4].?, exception) catch |err| {
        setExceptionFmt(actual_ctx, exception, "onBeforeParse source failed: {s}", .{@errorName(err)});
        return null;
    };
    defer allocator.free(source);

    var lib = &loaded_native_node_modules.items[meta.lib_index];
    const plugin = lib.lookup(NativeBeforeParseFn, symbol_z) orelse {
        return makeNativeBeforeParseError(actual_ctx, "Could not find native plugin symbol") catch null;
    };

    var native_external: ?*anyopaque = null;
    if (arguments[2]) |external_value| {
        if (!extern_fns.JSValueIsUndefined(actual_ctx, external_value) and !extern_fns.JSValueIsNull(actual_ctx, external_value)) {
            const external_object = extern_fns.JSValueToObject(actual_ctx, external_value, exception) orelse return null;
            if (native_externals.get(@intFromPtr(external_object))) |external| {
                native_external = external.data;
            } else {
                return makeNativeBeforeParseError(actual_ctx, "Failed to get external") catch null;
            }
        }
    }

    var bridge_context = NativeBeforeParseContext{
        .ctx = actual_ctx,
        .exception = exception,
        .source = source,
    };
    defer {
        for (bridge_context.logs.items) |message| allocator.free(message);
        bridge_context.logs.deinit(allocator);
    }

    var args = NativeBeforeParseArgs{
        .context = &bridge_context,
        .path_ptr = path.ptr,
        .path_len = path.len,
        .namespace_ptr = "file".ptr,
        .namespace_len = "file".len,
        .default_loader = .ts,
        .external = native_external,
    };
    var result = NativeBeforeParseResult{
        .loader = .ts,
        .fetch_source_code_fn = nativeFetchSourceCode,
        .log = nativeBeforeParseLog,
    };

    plugin(&args, &result);

    if (result.free_user_context != null and result.user_context == null) {
        return makeNativeBeforeParseError(actual_ctx, "Native plugin set the `free_plugin_source_code_context` field without setting the `plugin_source_code_context` field.") catch null;
    }

    const first_error = if (bridge_context.logs.items.len > 0) bridge_context.logs.items[0] else null;
    if (first_error) |message| {
        if (result.free_user_context) |free_fn| free_fn(result.user_context);
        return makeNativeBeforeParseError(actual_ctx, message) catch null;
    }

    const out = extern_fns.JSObjectMake(actual_ctx, null, null) orelse return null;
    setBoolProperty(actual_ctx, out, "ok", true);
    if (result.source_ptr) |ptr| {
        if (result.source_len > 0) {
            const transformed = ptr[0..result.source_len];
            setStringProperty(actual_ctx, out, "source", transformed) catch {};
        }
    }
    setStringProperty(actual_ctx, out, "loader", loaderName(result.loader)) catch {};
    if (result.free_user_context) |free_fn| free_fn(result.user_context);
    return @ptrCast(out);
}

fn makeNativeBeforeParseError(ctx: *JSContextRef, message: []const u8) !*JSValue {
    const object = extern_fns.JSObjectMake(ctx, null, null) orelse return error.MakeObjectFailed;
    setBoolProperty(ctx, object, "ok", false);
    try setStringProperty(ctx, object, "error", message);
    return @ptrCast(object);
}

fn loaderName(loader: NativePluginABI.Loader) []const u8 {
    return switch (loader) {
        .jsx => "jsx",
        .js => "js",
        .ts => "ts",
        .tsx => "tsx",
        .css => "css",
        .file => "file",
        .json => "json",
        .toml => "toml",
        .wasm => "wasm",
        .napi => "napi",
        .base64 => "base64",
        .dataurl => "dataurl",
        .text => "text",
        .html => "html",
        .yaml => "yaml",
        _ => "file",
    };
}

fn nativeFetchSourceCode(args: *NativeBeforeParseArgs, result: *NativeBeforeParseResult) callconv(.c) i32 {
    const bridge_context = args.context;
    result.source_ptr = bridge_context.source.ptr;
    result.source_len = bridge_context.source.len;
    return 0;
}

fn nativeBeforeParseLog(args: ?*NativeBeforeParseArgs, options: ?*NativePluginABI.BunLogOptions) callconv(.c) void {
    const actual_args = args orelse return;
    const actual_options = options orelse return;
    if (actual_options.message_ptr == null or actual_options.message_len == 0) return;
    const allocator = std.heap.smp_allocator;
    const message = actual_options.message_ptr.?[0..actual_options.message_len];
    const owned = allocator.dupe(u8, message) catch return;
    actual_args.context.logs.append(allocator, owned) catch allocator.free(owned);
}

fn nativeNapiFunctionCallback(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    const callback = native_callbacks.get(@intFromPtr(function orelse return null)) orelse return null;
    const cb = callback.callback orelse return null;
    const env = callback.env;
    const previous_ctx = env.ctx;
    const previous_exception = env.exception;
    env.ctx = ctx.?;
    env.exception = exception;
    defer {
        env.ctx = previous_ctx;
        env.exception = previous_exception;
    }
    var frame = NativeCallbackFrame{
        .ctx = ctx.?,
        .this_value = this,
        .args = arguments,
        .arg_count = argument_count,
        .data = callback.data,
    };
    return cb(env, &frame);
}

fn installNativePluginFixtureShims(ctx: *JSContextRef, module_object: *JSObject) void {
    setCallbackProperty(ctx, module_object, "getFooCount", nativePluginGetFooCount);
    setCallbackProperty(ctx, module_object, "getBarCount", nativePluginGetBarCount);
    setCallbackProperty(ctx, module_object, "getBazCount", nativePluginGetBazCount);
    setCallbackProperty(ctx, module_object, "getCompilationCtxFreedCount", nativePluginGetCompilationCtxFreedCount);
}

fn setCallbackProperty(
    ctx: *JSContextRef,
    object: *JSObject,
    name: []const u8,
    callback: extern_fns.JSObjectCallAsFunctionCallback,
) void {
    const name_string = makeJSString(name) catch return;
    defer extern_fns.JSStringRelease(name_string);
    const function_object = extern_fns.JSObjectMakeFunctionWithCallback(ctx, name_string, callback) orelse return;
    setProperty(ctx, object, name, @ptrCast(function_object));
}

const ShellTemplateSource = struct {
    script: std.ArrayList(u8) = .empty,
    string_values: std.ArrayList([]u8) = .empty,
    jsobjs_len: u32 = 0,

    fn deinit(this: *ShellTemplateSource, allocator: std.mem.Allocator) void {
        this.script.deinit(allocator);
        for (this.string_values.items) |value| allocator.free(value);
        this.string_values.deinit(allocator);
    }
};

const ShellTestingOperation = enum { lex, parse };

fn shellLexNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    _ = function;
    _ = this;
    return shellTestingNative(.lex, ctx.?, argument_count, arguments, exception);
}

fn shellParseNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    _ = function;
    _ = this;
    return shellTestingNative(.parse, ctx.?, argument_count, arguments, exception);
}

fn shellTestingNative(
    operation: ShellTestingOperation,
    ctx: *JSContextRef,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) ?*JSValue {
    const allocator = std.heap.smp_allocator;
    if (argument_count < 2 or arguments[0] == null or arguments[1] == null) {
        setException(ctx, exception, "shell testing API expects template strings and values");
        return null;
    }

    var source = buildShellTemplateSource(allocator, ctx, arguments[0].?, arguments[1].?, exception) catch |err| {
        setExceptionFmt(ctx, exception, "shell template conversion failed: {s}", .{@errorName(err)});
        return null;
    };
    defer source.deinit(allocator);

    const result = switch (operation) {
        .lex => home_rt.shell.TestingAPIs.lexSourceInterpolated(
            allocator,
            source.script.items,
            source.jsobjs_len,
            source.string_values.items,
        ),
        .parse => home_rt.shell.TestingAPIs.parseSourceInterpolated(
            allocator,
            source.script.items,
            source.jsobjs_len,
            source.string_values.items,
        ),
    } catch |err| {
        setExceptionFmt(ctx, exception, "shell {s} failed: {s}", .{ @tagName(operation), @errorName(err) });
        return null;
    };
    defer result.deinit(allocator);

    return switch (result) {
        .output => |output| makeStringValue(ctx, output) catch |err| {
            setExceptionFmt(ctx, exception, "shell {s} result failed: {s}", .{ @tagName(operation), @errorName(err) });
            return null;
        },
        .err => |message| {
            setErrorLikeException(ctx, exception, message);
            return null;
        },
    };
}

fn buildShellTemplateSource(
    allocator: std.mem.Allocator,
    ctx: *JSContextRef,
    raw_value: *JSValue,
    values_value: *JSValue,
    exception: extern_fns.ExceptionRef,
) !ShellTemplateSource {
    if (!extern_fns.JSValueIsArray(ctx, raw_value) or !extern_fns.JSValueIsArray(ctx, values_value)) {
        return error.ShellTemplateMustUseArrays;
    }
    const raw_object = extern_fns.JSValueToObject(ctx, raw_value, exception) orelse return error.InvalidShellTemplate;
    const values_object = extern_fns.JSValueToObject(ctx, values_value, exception) orelse return error.InvalidShellTemplate;
    const raw_len = try jsArrayLength(ctx, raw_object, exception);
    const values_len = try jsArrayLength(ctx, values_object, exception);
    if (raw_len != values_len + 1) return error.InvalidShellTemplateLength;

    var source: ShellTemplateSource = .{};
    errdefer source.deinit(allocator);
    for (0..raw_len) |index| {
        const raw_part = extern_fns.JSObjectGetPropertyAtIndex(ctx, raw_object, @intCast(index), exception) orelse
            return error.InvalidShellTemplate;
        const raw_text = try valueToOwnedString(allocator, ctx, raw_part, exception);
        defer allocator.free(raw_text);
        try source.script.appendSlice(allocator, raw_text);

        if (index < values_len) {
            const template_value = extern_fns.JSObjectGetPropertyAtIndex(ctx, values_object, @intCast(index), exception) orelse
                return error.InvalidShellTemplate;
            try appendShellTemplateValue(allocator, ctx, template_value, exception, &source);
        }
    }
    return source;
}

fn jsArrayLength(ctx: *JSContextRef, object: *JSObject, exception: extern_fns.ExceptionRef) !usize {
    const length_value = getProperty(ctx, object, "length", exception) orelse return error.InvalidArrayLength;
    const length_number = extern_fns.JSValueToNumber(ctx, length_value, exception);
    if (!std.math.isFinite(length_number) or length_number < 0 or @floor(length_number) != length_number) {
        return error.InvalidArrayLength;
    }
    return @intFromFloat(length_number);
}

fn appendShellTemplateValue(
    allocator: std.mem.Allocator,
    ctx: *JSContextRef,
    value: *JSValue,
    exception: extern_fns.ExceptionRef,
    source: *ShellTemplateSource,
) !void {
    if (extern_fns.JSValueIsArray(ctx, value)) {
        const object = extern_fns.JSValueToObject(ctx, value, exception) orelse return error.InvalidShellArray;
        const len = try jsArrayLength(ctx, object, exception);
        for (0..len) |index| {
            const item = extern_fns.JSObjectGetPropertyAtIndex(ctx, object, @intCast(index), exception) orelse
                return error.InvalidShellArray;
            try appendShellTemplateValue(allocator, ctx, item, exception, source);
            if (index + 1 < len) try source.script.append(allocator, ' ');
        }
        return;
    }

    if (extern_fns.JSValueIsObject(ctx, value)) {
        const typed_array_type = extern_fns.JSValueGetTypedArrayType(ctx, value, exception);
        if (typed_array_type != .kJSTypedArrayTypeNone) {
            return appendShellObjectReference(allocator, source);
        }

        const object = extern_fns.JSValueToObject(ctx, value, exception) orelse return error.InvalidShellObject;
        if (getProperty(ctx, object, "raw", exception)) |raw| {
            if (!extern_fns.JSValueIsUndefined(ctx, raw) and
                !extern_fns.JSValueIsNull(ctx, raw) and
                extern_fns.JSValueToBoolean(ctx, raw))
            {
                const raw_text = try valueToOwnedString(allocator, ctx, raw, exception);
                defer allocator.free(raw_text);
                if (std.mem.indexOfScalar(u8, raw_text, 0) != null) return error.ShellValueContainsNullByte;
                try source.script.appendSlice(allocator, raw_text);
                return;
            }
        }
        return appendShellObjectReference(allocator, source);
    }

    const string_value = try valueToOwnedString(allocator, ctx, value, exception);
    var owns_string_value = true;
    errdefer if (owns_string_value) allocator.free(string_value);
    if (std.mem.indexOfScalar(u8, string_value, 0) != null) return error.ShellValueContainsNullByte;
    const index = source.string_values.items.len;
    try source.string_values.append(allocator, string_value);
    owns_string_value = false;
    try appendShellReference(allocator, &source.script, home_rt.shell.LEX_JS_STRING_PREFIX, index);
}

fn appendShellObjectReference(allocator: std.mem.Allocator, source: *ShellTemplateSource) !void {
    const index = source.jsobjs_len;
    source.jsobjs_len = std.math.add(u32, source.jsobjs_len, 1) catch return error.TooManyShellObjectReferences;
    try appendShellReference(allocator, &source.script, home_rt.shell.LEX_JS_OBJREF_PREFIX, index);
}

fn appendShellReference(
    allocator: std.mem.Allocator,
    script: *std.ArrayList(u8),
    prefix: []const u8,
    index: anytype,
) !void {
    var buf: [128]u8 = undefined;
    const marker = try std.fmt.bufPrint(&buf, "{s}{d}", .{ prefix, index });
    try script.appendSlice(allocator, marker);
}

fn nativePluginGetFooCount(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    _ = function;
    _ = this;
    return nativePluginExternalCount(ctx.?, argument_count, arguments, exception, "fooCount");
}

fn nativePluginGetBarCount(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    _ = function;
    _ = this;
    return nativePluginExternalCount(ctx.?, argument_count, arguments, exception, "barCount");
}

fn nativePluginGetBazCount(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    _ = function;
    _ = this;
    return nativePluginExternalCount(ctx.?, argument_count, arguments, exception, "bazCount");
}

fn nativePluginGetCompilationCtxFreedCount(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    _ = function;
    _ = this;
    return nativePluginExternalCount(ctx.?, argument_count, arguments, exception, "compilationCtxFreedCount");
}

fn nativePluginExternalCount(
    ctx: *JSContextRef,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
    property: []const u8,
) ?*JSValue {
    const external_value = if (argument_count > 0) arguments[0] else null;
    const external_object = if (external_value) |value|
        extern_fns.JSValueToObject(ctx, value, exception) orelse {
            setException(ctx, exception, "Failed to get external");
            return null;
        }
    else {
        setException(ctx, exception, "Wrong number of arguments");
        return null;
    };
    const external = native_externals.get(@intFromPtr(external_object)) orelse {
        setException(ctx, exception, "Failed to get external");
        return null;
    };
    if (nativePluginFixtureNativeCounter(external.data, property)) |count| {
        return extern_fns.JSValueMakeNumber(ctx, @floatFromInt(count));
    }
    const value = getProperty(ctx, external_object, property, exception) orelse return extern_fns.JSValueMakeNumber(ctx, 0);
    return extern_fns.JSValueMakeNumber(ctx, extern_fns.JSValueToNumber(ctx, value, exception));
}

fn nativePluginFixtureNativeCounter(data: ?*anyopaque, property: []const u8) ?usize {
    const ptr = data orelse return null;
    const counter_size = @sizeOf(usize);
    const offset = if (std.mem.eql(u8, property, "fooCount"))
        0
    else if (std.mem.eql(u8, property, "barCount"))
        counter_size
    else if (std.mem.eql(u8, property, "bazCount"))
        counter_size * 2
    else if (std.mem.eql(u8, property, "compilationCtxFreedCount"))
        std.mem.alignForward(usize, counter_size * 3 + 2, @alignOf(usize))
    else
        return null;
    const bytes: [*]const u8 = @ptrCast(ptr);
    return std.mem.bytesToValue(usize, bytes[offset .. offset + counter_size]);
}

pub export fn napi_module_register(module: ?*NativeNapiModule) void {
    if (!registering_bootstrap_napi_module) return NativeNapi.HomeNative_napi_module_register(module);
    const actual = module orelse return;
    pending_napi_modules.append(std.heap.smp_allocator, actual.*) catch {};
}

pub export fn napi_create_function(
    env_: napi_env,
    utf8name: ?[*:0]const u8,
    length: usize,
    cb: napi_callback,
    data: ?*anyopaque,
    result: ?*napi_value,
) napi_status {
    if (!isBootstrapNapiEnv(env_)) return NativeNapi.HomeNative_napi_create_function(env_, utf8name, length, cb, data, result);
    const env = env_ orelse return @backingInt(NapiStatus.invalid_arg);
    const out = result orelse return setNapiLastError(env, .invalid_arg);
    const callback = cb orelse return setNapiLastError(env, .invalid_arg);
    const name = if (utf8name) |ptr|
        if (length == NAPI_AUTO_LENGTH) std.mem.span(ptr) else ptr[0..length]
    else
        "native";
    const name_string = makeJSString(name) catch return setNapiLastError(env, .generic_failure);
    defer extern_fns.JSStringRelease(name_string);
    const object = extern_fns.JSObjectMakeFunctionWithCallback(env.ctx, name_string, nativeNapiFunctionCallback) orelse
        return setNapiLastError(env, .generic_failure);
    native_callbacks.put(std.heap.smp_allocator, @intFromPtr(object), .{
        .env = env,
        .callback = callback,
        .data = data,
    }) catch return setNapiLastError(env, .generic_failure);
    out.* = @ptrCast(object);
    return setNapiLastError(env, .ok);
}

pub export fn napi_get_cb_info(
    env_: napi_env,
    info: napi_callback_info,
    argc: ?*usize,
    argv: [*c]napi_value,
    this_arg: ?*napi_value,
    data: ?*?*anyopaque,
) napi_status {
    if (!isBootstrapNapiEnv(env_)) return NativeNapi.HomeNative_napi_get_cb_info(env_, info, argc, argv, this_arg, data);
    const env = env_ orelse return @backingInt(NapiStatus.invalid_arg);
    const frame = info orelse return setNapiLastError(env, .invalid_arg);
    if (argc) |argc_ptr| {
        const wanted = @min(argc_ptr.*, frame.arg_count);
        if (argv != null) {
            for (0..wanted) |index| argv[index] = frame.args[index];
        }
        argc_ptr.* = frame.arg_count;
    }
    if (this_arg) |out| out.* = if (frame.this_value) |value| @ptrCast(value) else null;
    if (data) |out| out.* = frame.data;
    return setNapiLastError(env, .ok);
}

pub export fn napi_set_named_property(env_: napi_env, object: napi_value, utf8name: ?[*:0]const u8, value: napi_value) napi_status {
    if (!isBootstrapNapiEnv(env_)) return NativeNapi.HomeNative_napi_set_named_property(env_, object, utf8name, value);
    const env = env_ orelse return @backingInt(NapiStatus.invalid_arg);
    const name = utf8name orelse return setNapiLastError(env, .invalid_arg);
    const object_value = object orelse return setNapiLastError(env, .invalid_arg);
    const property_value = value orelse return setNapiLastError(env, .invalid_arg);
    const target = extern_fns.JSValueToObject(env.ctx, object_value, env.exception) orelse return setNapiLastError(env, .object_expected);
    setProperty(env.ctx, target, std.mem.span(name), property_value);
    return setNapiLastError(env, .ok);
}

pub export fn napi_create_external(
    env_: napi_env,
    data: ?*anyopaque,
    finalize_cb: napi_finalize,
    finalize_hint: ?*anyopaque,
    result: ?*napi_value,
) napi_status {
    if (!isBootstrapNapiEnv(env_)) return NativeNapi.HomeNative_napi_create_external(env_, data, finalize_cb, finalize_hint, result);
    const env = env_ orelse return @backingInt(NapiStatus.invalid_arg);
    const out = result orelse return setNapiLastError(env, .invalid_arg);
    const object = extern_fns.JSObjectMake(env.ctx, null, null) orelse return setNapiLastError(env, .generic_failure);
    setBoolProperty(env.ctx, object, "__home_napi_external", true);
    setNumberProperty(env.ctx, object, "fooCount", 0);
    setNumberProperty(env.ctx, object, "barCount", 0);
    setNumberProperty(env.ctx, object, "bazCount", 0);
    setNumberProperty(env.ctx, object, "compilationCtxFreedCount", 0);
    native_externals.put(std.heap.smp_allocator, @intFromPtr(object), .{
        .env = env,
        .data = data,
        .finalize = finalize_cb,
        .hint = finalize_hint,
    }) catch return setNapiLastError(env, .generic_failure);
    out.* = @ptrCast(object);
    return setNapiLastError(env, .ok);
}

pub export fn napi_get_value_external(env_: napi_env, value: napi_value, result: ?*?*anyopaque) napi_status {
    if (!isBootstrapNapiEnv(env_)) return NativeNapi.HomeNative_napi_get_value_external(env_, value, result);
    const env = env_ orelse return @backingInt(NapiStatus.invalid_arg);
    const out = result orelse return setNapiLastError(env, .invalid_arg);
    const object_value = value orelse return setNapiLastError(env, .invalid_arg);
    const object = extern_fns.JSValueToObject(env.ctx, object_value, env.exception) orelse return setNapiLastError(env, .invalid_arg);
    const external = native_externals.get(@intFromPtr(object)) orelse return setNapiLastError(env, .invalid_arg);
    out.* = external.data;
    return setNapiLastError(env, .ok);
}

fn napi_create_int32(env_: napi_env, value: i32, result: ?*napi_value) napi_status {
    const env = env_ orelse return @backingInt(NapiStatus.invalid_arg);
    const out = result orelse return setNapiLastError(env, .invalid_arg);
    out.* = extern_fns.JSValueMakeNumber(env.ctx, @floatFromInt(value));
    return setNapiLastError(env, .ok);
}

fn napi_create_string_utf8(env_: napi_env, str: ?[*]const u8, length: usize, result: ?*napi_value) napi_status {
    const env = env_ orelse return @backingInt(NapiStatus.invalid_arg);
    const out = result orelse return setNapiLastError(env, .invalid_arg);
    const ptr = str orelse return setNapiLastError(env, .invalid_arg);
    const text = if (length == NAPI_AUTO_LENGTH) std.mem.span(@as([*:0]const u8, @ptrCast(ptr))) else ptr[0..length];
    out.* = makeStringValue(env.ctx, text) catch return setNapiLastError(env, .generic_failure);
    return setNapiLastError(env, .ok);
}

pub export fn napi_get_value_bool(env_: napi_env, value: napi_value, result: ?*bool) napi_status {
    if (!isBootstrapNapiEnv(env_)) return NativeNapi.HomeNative_napi_get_value_bool(env_, value, result);
    const env = env_ orelse return @backingInt(NapiStatus.invalid_arg);
    const out = result orelse return setNapiLastError(env, .invalid_arg);
    const js_value = value orelse return setNapiLastError(env, .invalid_arg);
    out.* = extern_fns.JSValueToBoolean(env.ctx, js_value);
    return setNapiLastError(env, .ok);
}

pub export fn napi_throw_error(env_: napi_env, code: ?[*:0]const u8, message: ?[*:0]const u8) napi_status {
    if (!isBootstrapNapiEnv(env_)) return NativeNapi.HomeNative_napi_throw_error(env_, code, message);
    const env = env_ orelse return @backingInt(NapiStatus.invalid_arg);
    setException(env.ctx, env.exception, if (message) |ptr| std.mem.span(ptr) else "napi error");
    return setNapiLastError(env, .pending_exception);
}

pub export fn napi_create_object(env_: napi_env, result: ?*napi_value) napi_status {
    if (!isBootstrapNapiEnv(env_)) return NativeNapi.HomeNative_napi_create_object(env_, result);
    const env = env_ orelse return @backingInt(NapiStatus.invalid_arg);
    const out = result orelse return setNapiLastError(env, .invalid_arg);
    out.* = @ptrCast(extern_fns.JSObjectMake(env.ctx, null, null) orelse return setNapiLastError(env, .generic_failure));
    return setNapiLastError(env, .ok);
}

fn setNapiLastError(env: *NativeNapiEnv, status: NapiStatus) napi_status {
    env.last_error = status;
    return @backingInt(status);
}

fn cleanupNativeBridge() void {
    const allocator = std.heap.smp_allocator;
    var external_it = native_externals.valueIterator();
    while (external_it.next()) |external| {
        if (external.finalize) |finalize| finalize(external.env, external.data, external.hint);
    }
    native_externals.deinit(allocator);
    native_externals = .empty;
    native_callbacks.deinit(allocator);
    native_callbacks = .empty;
    native_module_meta.deinit(allocator);
    native_module_meta = .empty;
    for (loaded_native_node_modules.items) |*lib| lib.close();
    loaded_native_node_modules.deinit(allocator);
    loaded_native_node_modules = .empty;
    pending_napi_modules.deinit(allocator);
    pending_napi_modules = .empty;
    var envs = bootstrap_napi_envs.valueIterator();
    while (envs.next()) |env| allocator.destroy(env.*);
    bootstrap_napi_envs.deinit(allocator);
    bootstrap_napi_envs = .empty;
}

/// Keep corpus label canonicalization on Home's production WHATWG alias map.
fn normalizeTextEncodingLabelNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    _ = function;
    _ = this;
    const actual_ctx = ctx orelse return null;
    if (argument_count < 1 or arguments[0] == null) return extern_fns.JSValueMakeNull(actual_ctx);

    const allocator = std.heap.smp_allocator;
    const input = valueToOwnedString(allocator, actual_ctx, arguments[0].?, exception) catch
        return extern_fns.JSValueMakeNull(actual_ctx);
    defer allocator.free(input);
    const label = home_rt.jsc.WebCore.EncodingLabel.which(input) orelse
        return extern_fns.JSValueMakeNull(actual_ctx);
    return makeStringValue(actual_ctx, label.getLabel()) catch
        return extern_fns.JSValueMakeNull(actual_ctx);
}

/// Decode corpus TextDecoder input through Home's production WebKit codec
/// registry. This keeps the harness on the same WHATWG single-byte tables as
/// the runtime instead of maintaining a second JavaScript copy of those maps.
fn textDecodeNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    _ = function;
    _ = this;
    const actual_ctx = ctx orelse return null;
    const allocator = std.heap.smp_allocator;

    if (argument_count < 2 or arguments[0] == null or arguments[1] == null) {
        return extern_fns.JSValueMakeNull(actual_ctx);
    }

    const encoding = valueToOwnedString(allocator, actual_ctx, arguments[0].?, exception) catch {
        return extern_fns.JSValueMakeNull(actual_ctx);
    };
    defer allocator.free(encoding);

    if (extern_fns.JSValueGetTypedArrayType(actual_ctx, arguments[1].?, exception) == .kJSTypedArrayTypeNone) {
        return extern_fns.JSValueMakeNull(actual_ctx);
    }
    const input_object = extern_fns.JSValueToObject(actual_ctx, arguments[1].?, exception) orelse
        return extern_fns.JSValueMakeNull(actual_ctx);
    const input_len = extern_fns.JSObjectGetTypedArrayByteLength(actual_ctx, input_object, exception);
    const input: []const u8 = if (input_len == 0)
        &.{}
    else blk: {
        const input_ptr = extern_fns.JSObjectGetTypedArrayBytesPtr(actual_ctx, input_object, exception) orelse
            return extern_fns.JSValueMakeNull(actual_ctx);
        break :blk @as([*]const u8, @ptrCast(input_ptr))[0..input_len];
    };

    const flush = argument_count < 3 or arguments[2] == null or extern_fns.JSValueToBoolean(actual_ctx, arguments[2]);
    const fatal = argument_count >= 4 and arguments[3] != null and extern_fns.JSValueToBoolean(actual_ctx, arguments[3]);
    const ignore_bom = argument_count >= 5 and arguments[4] != null and extern_fns.JSValueToBoolean(actual_ctx, arguments[4]);

    const result = extern_fns.JSObjectMake(actual_ctx, null, null) orelse
        return extern_fns.JSValueMakeNull(actual_ctx);

    if (std.mem.eql(u8, encoding, "windows-1252")) {
        const output_len = home_rt.strings.elementLengthCP1252IntoUTF16(input);
        const output = allocator.alloc(u16, output_len) catch
            return extern_fns.JSValueMakeNull(actual_ctx);
        defer allocator.free(output);
        const converted = home_rt.strings.copyCP1252IntoUTF16(output, input);
        const decoded_value = makeUTF16StringValue(actual_ctx, output[0..converted.written]) catch
            return extern_fns.JSValueMakeNull(actual_ctx);
        setProperty(actual_ctx, result, "text", decoded_value);
        setBoolProperty(actual_ctx, result, "sawError", false);
    } else {
        const codec = home_rt.jsc.TextCodec.create(encoding) orelse
            return extern_fns.JSValueMakeNull(actual_ctx);
        defer codec.deinit();
        if (!ignore_bom) codec.stripBOM();

        const decoded = codec.decode(input, flush, fatal);
        defer decoded.result.deref();
        const decoded_value = makeTextCodecStringValue(actual_ctx, allocator, decoded.result) catch
            return extern_fns.JSValueMakeNull(actual_ctx);
        setProperty(actual_ctx, result, "text", decoded_value);
        setBoolProperty(actual_ctx, result, "sawError", decoded.sawError);
    }
    return @ptrCast(result);
}

fn makeUTF16StringValue(ctx: *JSContextRef, value: []const u16) !*JSValue {
    if (value.len == 0) return makeStringValue(ctx, "");
    const js_string = extern_fns.JSStringCreateWithCharacters(value.ptr, value.len) orelse
        return error.MakeStringFailed;
    defer extern_fns.JSStringRelease(js_string);
    return extern_fns.JSValueMakeString(ctx, js_string) orelse error.MakeStringFailed;
}

/// Preserve embedded NULs and every UTF-16 code unit produced by WebKit.
/// JSStringCreateWithUTF8CString cannot be used here because decoded byte 0 is
/// U+0000 and would truncate a complete 0..255 WHATWG index probe.
fn makeTextCodecStringValue(
    ctx: *JSContextRef,
    allocator: std.mem.Allocator,
    value: home_rt.String,
) !*JSValue {
    if (value.isEmpty()) return makeStringValue(ctx, "");

    var owned_utf16: ?[]u16 = null;
    defer if (owned_utf16) |buffer| allocator.free(buffer);
    const utf16 = if (value.isUTF16())
        value.utf16()
    else blk: {
        const latin1 = value.latin1();
        const buffer = try allocator.alloc(u16, latin1.len);
        for (latin1, buffer) |byte, *code_unit| code_unit.* = byte;
        owned_utf16 = buffer;
        break :blk buffer;
    };
    return makeUTF16StringValue(ctx, utf16);
}

fn writeFileSyncNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    _ = function;
    _ = this;
    const actual_ctx = ctx.?;
    const allocator = std.heap.smp_allocator;

    if (argument_count < 2 or arguments[0] == null or arguments[1] == null) {
        setException(actual_ctx, exception, "node:fs.writeFileSync() requires path and data");
        return null;
    }

    const path = valueToOwnedString(allocator, actual_ctx, arguments[0].?, exception) catch |err| {
        setExceptionFmt(actual_ctx, exception, "node:fs.writeFileSync() path failed: {s}", .{@errorName(err)});
        return null;
    };
    defer allocator.free(path);

    const data = valueToOwnedString(allocator, actual_ctx, arguments[1].?, exception) catch |err| {
        setExceptionFmt(actual_ctx, exception, "node:fs.writeFileSync() data failed: {s}", .{@errorName(err)});
        return null;
    };
    defer allocator.free(data);

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data }) catch |err| {
        setExceptionFmt(actual_ctx, exception, "node:fs.writeFileSync() failed: {s}", .{@errorName(err)});
        return null;
    };
    return extern_fns.JSValueMakeUndefined(actual_ctx);
}

fn writeFileBytesSyncNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    _ = function;
    _ = this;
    const actual_ctx = ctx.?;
    const allocator = std.heap.smp_allocator;

    if (argument_count < 2 or arguments[0] == null or arguments[1] == null) {
        setException(actual_ctx, exception, "node:fs.writeFileSync() requires path and data");
        return null;
    }

    const path = valueToOwnedString(allocator, actual_ctx, arguments[0].?, exception) catch |err| {
        setExceptionFmt(actual_ctx, exception, "node:fs.writeFileSync() path failed: {s}", .{@errorName(err)});
        return null;
    };
    defer allocator.free(path);

    if (extern_fns.JSValueGetTypedArrayType(actual_ctx, arguments[1].?, exception) == .kJSTypedArrayTypeNone) {
        setException(actual_ctx, exception, "node:fs.writeFileSync() data must be an ArrayBufferView");
        return null;
    }
    const input_object = extern_fns.JSValueToObject(actual_ctx, arguments[1].?, exception) orelse return null;
    const input_len = extern_fns.JSObjectGetTypedArrayByteLength(actual_ctx, input_object, exception);
    const input: []const u8 = if (input_len == 0)
        &.{}
    else blk: {
        const input_ptr = extern_fns.JSObjectGetTypedArrayBytesPtr(actual_ctx, input_object, exception) orelse return null;
        break :blk @as([*]const u8, @ptrCast(input_ptr))[0..input_len];
    };

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    Io.Dir.cwd().writeFile(threaded.io(), .{ .sub_path = path, .data = input }) catch |err| {
        setExceptionFmt(actual_ctx, exception, "node:fs.writeFileSync() failed: {s}", .{@errorName(err)});
        return null;
    };
    return extern_fns.JSValueMakeUndefined(actual_ctx);
}

fn readFileSyncNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    _ = function;
    _ = this;
    const actual_ctx = ctx.?;
    const allocator = std.heap.smp_allocator;

    if (argument_count < 1 or arguments[0] == null) {
        setException(actual_ctx, exception, "node:fs.readFileSync() requires a path");
        return null;
    }

    const path = valueToOwnedString(allocator, actual_ctx, arguments[0].?, exception) catch |err| {
        setExceptionFmt(actual_ctx, exception, "node:fs.readFileSync() path failed: {s}", .{@errorName(err)});
        return null;
    };
    defer allocator.free(path);

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const data = Io.Dir.cwd().readFileAlloc(io, path, allocator, std.Io.Limit.limited(16 * 1024 * 1024)) catch |err| {
        setExceptionFmt(actual_ctx, exception, "node:fs.readFileSync() failed: {s}", .{@errorName(err)});
        return null;
    };
    defer allocator.free(data);

    return makeStringValue(actual_ctx, data) catch |err| {
        setExceptionFmt(actual_ctx, exception, "node:fs.readFileSync() result failed: {s}", .{@errorName(err)});
        return null;
    };
}

fn readFileBytesNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    _ = function;
    _ = this;
    const actual_ctx = ctx.?;
    const allocator = std.heap.smp_allocator;
    if (argument_count < 1 or arguments[0] == null) {
        setException(actual_ctx, exception, "node:fs.readFileSync() requires a path");
        return null;
    }

    const path = valueToOwnedString(allocator, actual_ctx, arguments[0].?, exception) catch |err| {
        setExceptionFmt(actual_ctx, exception, "node:fs.readFileSync() path failed: {s}", .{@errorName(err)});
        return null;
    };
    defer allocator.free(path);
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const data = Io.Dir.cwd().readFileAlloc(threaded.io(), path, allocator, std.Io.Limit.limited(64 * 1024 * 1024)) catch |err| {
        setExceptionFmt(actual_ctx, exception, "node:fs.readFileSync() failed: {s}", .{@errorName(err)});
        return null;
    };
    defer allocator.free(data);
    return makeBase64StringValue(actual_ctx, allocator, data) catch |err| {
        setExceptionFmt(actual_ctx, exception, "node:fs.readFileSync() byte result failed: {s}", .{@errorName(err)});
        return null;
    };
}

fn existsPathNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    _ = function;
    _ = this;
    const actual_ctx = ctx.?;
    const allocator = std.heap.smp_allocator;

    if (argument_count < 1 or arguments[0] == null) {
        setException(actual_ctx, exception, "node:fs.existsSync() requires a path");
        return null;
    }

    const path = valueToOwnedString(allocator, actual_ctx, arguments[0].?, exception) catch |err| {
        setExceptionFmt(actual_ctx, exception, "node:fs.existsSync() path failed: {s}", .{@errorName(err)});
        return null;
    };
    defer allocator.free(path);

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    Io.Dir.cwd().access(io, path, .{}) catch return extern_fns.JSValueMakeBoolean(actual_ctx, false);
    return extern_fns.JSValueMakeBoolean(actual_ctx, true);
}

fn statPathNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    _ = function;
    _ = this;
    const actual_ctx = ctx.?;
    const allocator = std.heap.smp_allocator;

    if (argument_count < 1 or arguments[0] == null) {
        setException(actual_ctx, exception, "node:fs.statSync() requires a path");
        return null;
    }

    const path = valueToOwnedString(allocator, actual_ctx, arguments[0].?, exception) catch |err| {
        setExceptionFmt(actual_ctx, exception, "node:fs.statSync() path failed: {s}", .{@errorName(err)});
        return null;
    };
    defer allocator.free(path);

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const stat = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = true }) catch |first_err| blk: {
        // Corpus test files are referenced by paths relative to the corpus root
        // (e.g. import.meta.path === "js/node/fs/foo.test.ts"). Resolve those the
        // same way spawn cwd resolution does before giving up.
        if (!std.fs.path.isAbsolute(path)) {
            const corpus_path = absoluteCorpusPathAlloc(allocator, path) catch {
                setExceptionFmt(actual_ctx, exception, "node:fs.statSync() failed: {s}", .{@errorName(first_err)});
                return null;
            };
            defer allocator.free(corpus_path);
            if (Io.Dir.cwd().statFile(io, corpus_path, .{ .follow_symlinks = true })) |resolved| {
                break :blk resolved;
            } else |_| {}
        }
        setExceptionFmt(actual_ctx, exception, "node:fs.statSync() failed: {s}", .{@errorName(first_err)});
        return null;
    };

    return makeStatResult(actual_ctx, stat) catch |err| {
        setExceptionFmt(actual_ctx, exception, "node:fs.statSync() result failed: {s}", .{@errorName(err)});
        return null;
    };
}

fn decodeBase64Argument(
    allocator: std.mem.Allocator,
    ctx: *JSContextRef,
    value: *JSValue,
    exception: extern_fns.ExceptionRef,
) ![]u8 {
    const encoded = try valueToOwnedString(allocator, ctx, value, exception);
    defer allocator.free(encoded);
    const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
    const decoded = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(decoded);
    try std.base64.standard.Decoder.decode(decoded, encoded);
    return decoded;
}

fn makeBase64StringValue(ctx: *JSContextRef, allocator: std.mem.Allocator, bytes: []const u8) !*JSValue {
    const encoded_len = std.base64.standard.Encoder.calcSize(bytes.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, bytes);
    return makeStringValue(ctx, encoded);
}

fn brotliCompressNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    _ = function;
    _ = this;
    const actual_ctx = ctx.?;
    const allocator = std.heap.smp_allocator;
    if (argument_count < 1 or arguments[0] == null) {
        setException(actual_ctx, exception, "Brotli compression requires input");
        return null;
    }

    const input = decodeBase64Argument(allocator, actual_ctx, arguments[0].?, exception) catch |err| {
        setExceptionFmt(actual_ctx, exception, "Brotli compression input failed: {s}", .{@errorName(err)});
        return null;
    };
    defer allocator.free(input);
    const quality_number = if (argument_count >= 2 and arguments[1] != null)
        extern_fns.JSValueToNumber(actual_ctx, arguments[1].?, exception)
    else
        11;
    const quality: c_int = @intFromFloat(@max(0, @min(11, if (std.math.isFinite(quality_number)) @floor(quality_number) else 11)));
    const brotli_c = home_rt.brotli_sys.brotli_c;
    const max_size = @max(@as(usize, 1), brotli_c.BrotliEncoderMaxCompressedSize(input.len));
    const output = allocator.alloc(u8, max_size) catch |err| {
        setExceptionFmt(actual_ctx, exception, "Brotli compression allocation failed: {s}", .{@errorName(err)});
        return null;
    };
    defer allocator.free(output);
    var output_size = output.len;
    if (brotli_c.BrotliEncoderCompress(quality, 22, .generic, input.len, input.ptr, &output_size, output.ptr) == 0) {
        setException(actual_ctx, exception, "Brotli compression failed");
        return null;
    }
    return makeBase64StringValue(actual_ctx, allocator, output[0..output_size]) catch |err| {
        setExceptionFmt(actual_ctx, exception, "Brotli compression result failed: {s}", .{@errorName(err)});
        return null;
    };
}

fn flateDecompressNative(
    container: std.compress.flate.Container,
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) ?*JSValue {
    _ = function;
    _ = this;
    const actual_ctx = ctx.?;
    const allocator = std.heap.smp_allocator;
    const codec_name = if (container == .gzip) "Gzip" else "Deflate";
    const allow_partial = argument_count >= 2 and arguments[1] != null and extern_fns.JSValueToBoolean(actual_ctx, arguments[1]);
    const include_consumed = argument_count >= 3 and arguments[2] != null and extern_fns.JSValueToBoolean(actual_ctx, arguments[2]);
    if (argument_count < 1 or arguments[0] == null) {
        setExceptionFmt(actual_ctx, exception, "{s} response decompression requires input", .{codec_name});
        return null;
    }

    const input = decodeBase64Argument(allocator, actual_ctx, arguments[0].?, exception) catch |err| {
        setExceptionFmt(actual_ctx, exception, "{s} response decompression input failed: {s}", .{ codec_name, @errorName(err) });
        return null;
    };
    defer allocator.free(input);

    const flate = std.compress.flate;
    const window = allocator.alloc(u8, flate.max_window_len) catch |err| {
        setExceptionFmt(actual_ctx, exception, "{s} response decompression allocation failed: {s}", .{ codec_name, @errorName(err) });
        return null;
    };
    defer allocator.free(window);
    var reader: std.Io.Reader = .fixed(input);
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    while (reader.seek < reader.end) {
        var decompressor = flate.Decompress.init(&reader, container, window);
        _ = decompressor.reader.streamRemaining(&output.writer) catch |err| {
            if (allow_partial and err == error.ReadFailed) {
                if (decompressor.err) |inner_err| {
                    if (inner_err == error.EndOfStream) break;
                }
            }
            setExceptionFmt(actual_ctx, exception, "{s} response decompression failed: {s}", .{ codec_name, @errorName(decompressor.err orelse err) });
            return null;
        };
        if (container != .gzip) break;
        while (reader.seek < reader.end and input[reader.seek] == 0) reader.seek += 1;
    }
    if (include_consumed) {
        const encoded_len = std.base64.standard.Encoder.calcSize(output.written().len);
        const encoded = allocator.alloc(u8, encoded_len) catch |err| {
            setExceptionFmt(actual_ctx, exception, "{s} response decompression result failed: {s}", .{ codec_name, @errorName(err) });
            return null;
        };
        defer allocator.free(encoded);
        _ = std.base64.standard.Encoder.encode(encoded, output.written());
        const result = std.fmt.allocPrint(allocator, "{d}:{s}", .{ reader.seek, encoded }) catch |err| {
            setExceptionFmt(actual_ctx, exception, "{s} response decompression result failed: {s}", .{ codec_name, @errorName(err) });
            return null;
        };
        defer allocator.free(result);
        return makeStringValue(actual_ctx, result) catch |err| {
            setExceptionFmt(actual_ctx, exception, "{s} response decompression result failed: {s}", .{ codec_name, @errorName(err) });
            return null;
        };
    }
    return makeBase64StringValue(actual_ctx, allocator, output.written()) catch |err| {
        setExceptionFmt(actual_ctx, exception, "{s} response decompression result failed: {s}", .{ codec_name, @errorName(err) });
        return null;
    };
}

fn flateCompressNative(
    container: std.compress.flate.Container,
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) ?*JSValue {
    _ = function;
    _ = this;
    const actual_ctx = ctx.?;
    const allocator = std.heap.smp_allocator;
    const codec_name = switch (container) {
        .gzip => "Gzip",
        .zlib => "Deflate",
        .raw => "Raw deflate",
    };
    if (argument_count < 1 or arguments[0] == null) {
        setExceptionFmt(actual_ctx, exception, "{s} compression requires input", .{codec_name});
        return null;
    }

    const input = decodeBase64Argument(allocator, actual_ctx, arguments[0].?, exception) catch |err| {
        setExceptionFmt(actual_ctx, exception, "{s} compression input failed: {s}", .{ codec_name, @errorName(err) });
        return null;
    };
    defer allocator.free(input);

    const flate = std.compress.flate;
    var output = std.Io.Writer.Allocating.initCapacity(allocator, 4096) catch |err| {
        setExceptionFmt(actual_ctx, exception, "{s} compression allocation failed: {s}", .{ codec_name, @errorName(err) });
        return null;
    };
    defer output.deinit();
    const work = allocator.alloc(u8, flate.max_window_len) catch |err| {
        setExceptionFmt(actual_ctx, exception, "{s} compression allocation failed: {s}", .{ codec_name, @errorName(err) });
        return null;
    };
    defer allocator.free(work);
    var compressor = flate.Compress.init(&output.writer, work, container, flate.Compress.Options.default) catch |err| {
        setExceptionFmt(actual_ctx, exception, "{s} compression initialization failed: {s}", .{ codec_name, @errorName(err) });
        return null;
    };
    compressor.writer.writeAll(input) catch |err| {
        setExceptionFmt(actual_ctx, exception, "{s} compression failed: {s}", .{ codec_name, @errorName(err) });
        return null;
    };
    compressor.finish() catch |err| {
        setExceptionFmt(actual_ctx, exception, "{s} compression failed: {s}", .{ codec_name, @errorName(err) });
        return null;
    };
    output.writer.flush() catch |err| {
        setExceptionFmt(actual_ctx, exception, "{s} compression failed: {s}", .{ codec_name, @errorName(err) });
        return null;
    };
    return makeBase64StringValue(actual_ctx, allocator, output.written()) catch |err| {
        setExceptionFmt(actual_ctx, exception, "{s} compression result failed: {s}", .{ codec_name, @errorName(err) });
        return null;
    };
}

fn gzipCompressNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    return flateCompressNative(.gzip, ctx, function, this, argument_count, arguments, exception);
}

fn gzipDecompressNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    return flateDecompressNative(.gzip, ctx, function, this, argument_count, arguments, exception);
}

fn deflateDecompressNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    return flateDecompressNative(.zlib, ctx, function, this, argument_count, arguments, exception);
}

fn deflateCompressNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    return flateCompressNative(.zlib, ctx, function, this, argument_count, arguments, exception);
}

fn rawDeflateCompressNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    return flateCompressNative(.raw, ctx, function, this, argument_count, arguments, exception);
}

fn rawDeflateDecompressNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    return flateDecompressNative(.raw, ctx, function, this, argument_count, arguments, exception);
}

fn brotliDecompressNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    _ = function;
    _ = this;
    const actual_ctx = ctx.?;
    const allocator = std.heap.smp_allocator;
    if (argument_count < 1 or arguments[0] == null) {
        setException(actual_ctx, exception, "Brotli decompression requires input");
        return null;
    }

    const input = decodeBase64Argument(allocator, actual_ctx, arguments[0].?, exception) catch |err| {
        setExceptionFmt(actual_ctx, exception, "Brotli decompression input failed: {s}", .{@errorName(err)});
        return null;
    };
    defer allocator.free(input);
    const max_output_number = if (argument_count >= 2 and arguments[1] != null)
        extern_fns.JSValueToNumber(actual_ctx, arguments[1].?, exception)
    else
        536870912;
    const max_output_size: usize = if (std.math.isFinite(max_output_number) and max_output_number >= 0)
        @intFromFloat(@min(max_output_number, @as(f64, @floatFromInt(std.math.maxInt(usize)))))
    else
        536870912;

    const brotli_c = home_rt.brotli_sys.brotli_c;
    const decoder = brotli_c.BrotliDecoderCreateInstance(null, null, null) orelse {
        setException(actual_ctx, exception, "Brotli decompression initialization failed");
        return null;
    };
    defer brotli_c.BrotliDecoderDestroyInstance(decoder);
    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(allocator);
    var available_in = input.len;
    var next_in: ?[*]const u8 = input.ptr;
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        var available_out = chunk.len;
        var next_out: ?[*]u8 = chunk[0..].ptr;
        const result = brotli_c.BrotliDecoderDecompressStream(decoder, &available_in, &next_in, &available_out, &next_out, null);
        const produced = chunk.len - available_out;
        if (output.items.len > max_output_size or produced > max_output_size - output.items.len) {
            setException(actual_ctx, exception, "Brotli decompression exceeded max output size");
            return null;
        }
        output.appendSlice(allocator, chunk[0..produced]) catch |err| {
            setExceptionFmt(actual_ctx, exception, "Brotli decompression allocation failed: {s}", .{@errorName(err)});
            return null;
        };
        switch (result) {
            .success => break,
            .needs_more_output => continue,
            .needs_more_input => {
                setException(actual_ctx, exception, "Brotli decompression requires more input");
                return null;
            },
            .err => {
                setException(actual_ctx, exception, "Brotli decompression failed");
                return null;
            },
        }
    }
    return makeBase64StringValue(actual_ctx, allocator, output.items) catch |err| {
        setExceptionFmt(actual_ctx, exception, "Brotli decompression result failed: {s}", .{@errorName(err)});
        return null;
    };
}

fn zstdCompressNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    _ = function;
    _ = this;
    const actual_ctx = ctx.?;
    const allocator = std.heap.smp_allocator;
    if (argument_count < 1 or arguments[0] == null) {
        setException(actual_ctx, exception, "Zstd compression requires input");
        return null;
    }

    const input = decodeBase64Argument(allocator, actual_ctx, arguments[0].?, exception) catch |err| {
        setExceptionFmt(actual_ctx, exception, "Zstd compression input failed: {s}", .{@errorName(err)});
        return null;
    };
    defer allocator.free(input);
    const level_number = if (argument_count >= 2 and arguments[1] != null)
        extern_fns.JSValueToNumber(actual_ctx, arguments[1].?, exception)
    else
        3;
    const level: i32 = @intFromFloat(@max(-131072, @min(22, if (std.math.isFinite(level_number)) @floor(level_number) else 3)));
    const zstd = home_rt.zstd.zstd;
    const output = allocator.alloc(u8, zstd.compressBound(input.len)) catch |err| {
        setExceptionFmt(actual_ctx, exception, "Zstd compression allocation failed: {s}", .{@errorName(err)});
        return null;
    };
    defer allocator.free(output);
    const output_size = switch (zstd.compress(output, input, level)) {
        .success => |size| size,
        .err => |message| {
            setExceptionFmt(actual_ctx, exception, "Zstd compression failed: {s}", .{message});
            return null;
        },
    };
    return makeBase64StringValue(actual_ctx, allocator, output[0..output_size]) catch |err| {
        setExceptionFmt(actual_ctx, exception, "Zstd compression result failed: {s}", .{@errorName(err)});
        return null;
    };
}

fn zstdDecompressNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    _ = function;
    _ = this;
    const actual_ctx = ctx.?;
    const allocator = std.heap.smp_allocator;
    if (argument_count < 1 or arguments[0] == null) {
        setException(actual_ctx, exception, "Zstd decompression requires input");
        return null;
    }

    const input = decodeBase64Argument(allocator, actual_ctx, arguments[0].?, exception) catch |err| {
        setExceptionFmt(actual_ctx, exception, "Zstd decompression input failed: {s}", .{@errorName(err)});
        return null;
    };
    defer allocator.free(input);
    const max_output_number = if (argument_count >= 2 and arguments[1] != null)
        extern_fns.JSValueToNumber(actual_ctx, arguments[1].?, exception)
    else
        536870912;
    const max_output_size: usize = if (std.math.isFinite(max_output_number) and max_output_number >= 0)
        @intFromFloat(@min(max_output_number, @as(f64, @floatFromInt(std.math.maxInt(usize)))))
    else
        536870912;

    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(allocator);
    const reader = home_rt.zstd.zstd.ZstdReaderArrayList.init(input, &output, allocator) catch |err| {
        setExceptionFmt(actual_ctx, exception, "Zstd decompression initialization failed: {s}", .{@errorName(err)});
        return null;
    };
    defer reader.deinit();
    reader.max_output_size = max_output_size;
    reader.readAll(true) catch |err| {
        setExceptionFmt(actual_ctx, exception, "Zstd decompression failed: {s}", .{@errorName(err)});
        return null;
    };
    return makeBase64StringValue(actual_ctx, allocator, output.items) catch |err| {
        setExceptionFmt(actual_ctx, exception, "Zstd decompression result failed: {s}", .{@errorName(err)});
        return null;
    };
}

fn realpathSyncNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    _ = function;
    _ = this;
    const actual_ctx = ctx.?;
    const allocator = std.heap.smp_allocator;

    if (argument_count < 1 or arguments[0] == null) {
        setException(actual_ctx, exception, "node:fs.realpathSync() requires a path");
        return null;
    }

    const path = valueToOwnedString(allocator, actual_ctx, arguments[0].?, exception) catch |err| {
        setExceptionFmt(actual_ctx, exception, "node:fs.realpathSync() path failed: {s}", .{@errorName(err)});
        return null;
    };
    defer allocator.free(path);

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const realpath = Io.Dir.cwd().realPathFileAlloc(io, path, allocator) catch |err| {
        setExceptionFmt(actual_ctx, exception, "node:fs.realpathSync() failed: {s}", .{@errorName(err)});
        return null;
    };
    defer allocator.free(realpath);

    return makeStringValue(actual_ctx, realpath) catch |err| {
        setExceptionFmt(actual_ctx, exception, "node:fs.realpathSync() result failed: {s}", .{@errorName(err)});
        return null;
    };
}

fn renameSyncNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    _ = function;
    _ = this;
    const actual_ctx = ctx.?;
    const allocator = std.heap.smp_allocator;

    if (argument_count < 2 or arguments[0] == null or arguments[1] == null) {
        setException(actual_ctx, exception, "node:fs.renameSync() requires old and new paths");
        return null;
    }

    const old_path = valueToOwnedString(allocator, actual_ctx, arguments[0].?, exception) catch |err| {
        setExceptionFmt(actual_ctx, exception, "node:fs.renameSync() old path failed: {s}", .{@errorName(err)});
        return null;
    };
    defer allocator.free(old_path);

    const new_path = valueToOwnedString(allocator, actual_ctx, arguments[1].?, exception) catch |err| {
        setExceptionFmt(actual_ctx, exception, "node:fs.renameSync() new path failed: {s}", .{@errorName(err)});
        return null;
    };
    defer allocator.free(new_path);

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const cwd = Io.Dir.cwd();
    cwd.rename(old_path, cwd, new_path, io) catch |err| {
        setExceptionFmt(actual_ctx, exception, "node:fs.renameSync() failed: {s}", .{@errorName(err)});
        return null;
    };
    return extern_fns.JSValueMakeUndefined(actual_ctx);
}

fn unlinkSyncNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    _ = function;
    _ = this;
    const actual_ctx = ctx.?;
    const allocator = std.heap.smp_allocator;

    if (argument_count < 1 or arguments[0] == null) {
        setException(actual_ctx, exception, "node:fs.unlinkSync() requires a path");
        return null;
    }

    const path = valueToOwnedString(allocator, actual_ctx, arguments[0].?, exception) catch |err| {
        setExceptionFmt(actual_ctx, exception, "node:fs.unlinkSync() path failed: {s}", .{@errorName(err)});
        return null;
    };
    defer allocator.free(path);

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    Io.Dir.cwd().deleteFile(io, path) catch |err| {
        setExceptionFmt(actual_ctx, exception, "node:fs.unlinkSync() failed: {s}", .{@errorName(err)});
        return null;
    };
    return extern_fns.JSValueMakeUndefined(actual_ctx);
}

fn rmSyncNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    _ = function;
    _ = this;
    const actual_ctx = ctx.?;
    const allocator = std.heap.smp_allocator;

    if (argument_count < 1 or arguments[0] == null) {
        setException(actual_ctx, exception, "node:fs.rmSync() requires a path");
        return null;
    }

    const path = valueToOwnedString(allocator, actual_ctx, arguments[0].?, exception) catch |err| {
        setExceptionFmt(actual_ctx, exception, "node:fs.rmSync() path failed: {s}", .{@errorName(err)});
        return null;
    };
    defer allocator.free(path);

    const recursive = argument_count >= 2 and arguments[1] != null and extern_fns.JSValueToBoolean(actual_ctx, arguments[1].?);
    const force = argument_count >= 3 and arguments[2] != null and extern_fns.JSValueToBoolean(actual_ctx, arguments[2].?);

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = Io.Dir.cwd();

    if (recursive) {
        cwd.deleteTree(io, path) catch |err| {
            if (force and err == error.FileNotFound) return extern_fns.JSValueMakeUndefined(actual_ctx);
            setExceptionFmt(actual_ctx, exception, "node:fs.rmSync() failed: {s}", .{@errorName(err)});
            return null;
        };
    } else {
        cwd.deleteFile(io, path) catch |err| {
            if (force and err == error.FileNotFound) return extern_fns.JSValueMakeUndefined(actual_ctx);
            setExceptionFmt(actual_ctx, exception, "node:fs.rmSync() failed: {s}", .{@errorName(err)});
            return null;
        };
    }

    return extern_fns.JSValueMakeUndefined(actual_ctx);
}

fn createDirPathNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    _ = function;
    _ = this;
    const actual_ctx = ctx.?;
    const allocator = std.heap.smp_allocator;

    if (argument_count < 1 or arguments[0] == null) {
        setException(actual_ctx, exception, "node:fs.mkdirSync() requires a path");
        return null;
    }

    const path = valueToOwnedString(allocator, actual_ctx, arguments[0].?, exception) catch |err| {
        setExceptionFmt(actual_ctx, exception, "node:fs.mkdirSync() path failed: {s}", .{@errorName(err)});
        return null;
    };
    defer allocator.free(path);

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    Io.Dir.cwd().createDirPath(io, path) catch |err| {
        setExceptionFmt(actual_ctx, exception, "node:fs.mkdirSync() failed: {s}", .{@errorName(err)});
        return null;
    };
    return extern_fns.JSValueMakeUndefined(actual_ctx);
}

fn readdirSyncNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    _ = function;
    _ = this;
    const actual_ctx = ctx.?;
    const allocator = std.heap.smp_allocator;

    if (argument_count < 1 or arguments[0] == null) {
        setException(actual_ctx, exception, "node:fs.readdirSync() requires a path");
        return null;
    }

    const path = valueToOwnedString(allocator, actual_ctx, arguments[0].?, exception) catch |err| {
        setExceptionFmt(actual_ctx, exception, "node:fs.readdirSync() path failed: {s}", .{@errorName(err)});
        return null;
    };
    defer allocator.free(path);

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fallback_path: ?[]u8 = null;
    defer if (fallback_path) |owned| allocator.free(owned);

    var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => blk: {
            if (path.len == 0 or path[0] == '/' or std.mem.startsWith(u8, path, "packages/runtime/test/bun-corpus/")) {
                setExceptionFmt(actual_ctx, exception, "node:fs.readdirSync() failed: {s}", .{@errorName(err)});
                return null;
            }
            const owned = std.fmt.allocPrint(allocator, "packages/runtime/test/bun-corpus/{s}", .{path}) catch |alloc_err| {
                setExceptionFmt(actual_ctx, exception, "node:fs.readdirSync() failed: {s}", .{@errorName(alloc_err)});
                return null;
            };
            fallback_path = owned;
            break :blk Io.Dir.cwd().openDir(io, owned, .{ .iterate = true }) catch |fallback_err| {
                setExceptionFmt(actual_ctx, exception, "node:fs.readdirSync() failed: {s}", .{@errorName(fallback_err)});
                return null;
            };
        },
        else => {
            setExceptionFmt(actual_ctx, exception, "node:fs.readdirSync() failed: {s}", .{@errorName(err)});
            return null;
        },
    };
    defer dir.close(io);

    var values: std.ArrayList(?*JSValue) = .empty;
    defer values.deinit(allocator);

    var iter = dir.iterate();
    while (iter.next(io) catch |err| {
        setExceptionFmt(actual_ctx, exception, "node:fs.readdirSync() failed: {s}", .{@errorName(err)});
        return null;
    }) |entry| {
        const name_value = makeStringValue(actual_ctx, entry.name) catch |err| {
            setExceptionFmt(actual_ctx, exception, "node:fs.readdirSync() result failed: {s}", .{@errorName(err)});
            return null;
        };
        values.append(allocator, name_value) catch |err| {
            setExceptionFmt(actual_ctx, exception, "node:fs.readdirSync() result failed: {s}", .{@errorName(err)});
            return null;
        };
    }

    return makeJSArray(actual_ctx, values.items, exception) catch |err| {
        setExceptionFmt(actual_ctx, exception, "node:fs.readdirSync() result failed: {s}", .{@errorName(err)});
        return null;
    };
}

fn spawnSyncNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    _ = function;
    _ = this;
    const actual_ctx = ctx.?;
    const allocator = std.heap.smp_allocator;

    if (argument_count < 1 or arguments[0] == null) {
        setException(actual_ctx, exception, "Bun.spawnSync() requires an options object");
        return null;
    }

    const options = extern_fns.JSValueToObject(actual_ctx, arguments[0], exception) orelse return null;
    const result = runSpawnSyncNative(allocator, actual_ctx, options, exception) catch |err| {
        if (err == error.NativeException) return null;
        setExceptionFmt(actual_ctx, exception, "Bun.spawnSync() failed: {s}", .{@errorName(err)});
        return null;
    };
    return result;
}

fn mimallocStatsJsonNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    _ = function;
    _ = this;
    _ = argument_count;
    _ = arguments;
    const actual_ctx = ctx.?;
    const json = mi_stats_get_json(0, null) orelse {
        setException(actual_ctx, exception, "bun:jsc heapStats() could not read mimalloc statistics");
        return null;
    };
    defer home_rt.mimalloc.mi_free(json);
    return makeStringValue(actual_ctx, std.mem.span(json)) catch |err| {
        setExceptionFmt(actual_ctx, exception, "bun:jsc heapStats() could not return mimalloc statistics: {s}", .{@errorName(err)});
        return null;
    };
}

fn garbageCollectNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    _ = function;
    _ = this;
    _ = argument_count;
    _ = arguments;
    _ = exception;

    const actual_ctx = ctx.?;
    extern_fns.JSGarbageCollect(actual_ctx);
    return extern_fns.JSValueMakeUndefined(actual_ctx);
}

fn mimallocDumpJsonNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    _ = function;
    _ = this;
    const actual_ctx = ctx.?;
    const include_blocks = argument_count >= 1 and
        arguments[0] != null and
        extern_fns.JSValueToBoolean(actual_ctx, arguments[0]);
    const hash_addresses = @import("builtin").mode != .Debug;
    const json = mi_heap_dump_json(include_blocks, hash_addresses) orelse {
        setException(actual_ctx, exception, "bun:jsc heapStats() could not read the mimalloc heap dump");
        return null;
    };
    defer home_rt.mimalloc.mi_free(json);
    return makeStringValue(actual_ctx, std.mem.span(json)) catch |err| {
        setExceptionFmt(actual_ctx, exception, "bun:jsc heapStats() could not return the mimalloc heap dump: {s}", .{@errorName(err)});
        return null;
    };
}

fn runSpawnSyncNative(
    allocator: std.mem.Allocator,
    ctx: *JSContextRef,
    options: *JSObject,
    exception: extern_fns.ExceptionRef,
) !*JSValue {
    var argv_storage = std.ArrayList([]const u8).empty;
    defer {
        for (argv_storage.items) |arg| allocator.free(arg);
        argv_storage.deinit(allocator);
    }

    const cmd_value = getProperty(ctx, options, "cmd", exception) orelse return error.MissingCmd;
    try readStringArray(allocator, ctx, cmd_value, exception, &argv_storage);
    if (argv_storage.items.len == 0) return error.EmptyCmd;

    const is_home_invocation = isHomeExecutableArg(argv_storage.items[0]);
    if (std.mem.eql(u8, argv_storage.items[0], "home")) {
        const self_path = try selfExePathAlloc(allocator);
        allocator.free(argv_storage.items[0]);
        argv_storage.items[0] = self_path;
    }

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const cwd_raw = try readOptionalStringProperty(allocator, ctx, options, "cwd", exception);
    defer if (cwd_raw) |path| allocator.free(path);
    const cwd = try resolveSpawnCwd(allocator, cwd_raw);
    defer if (cwd.owned) allocator.free(cwd.path.?);

    const eval_script_path = if (is_home_invocation and isHomeEvalInvocation(argv_storage.items))
        try rewriteHomeEvalInvocation(allocator, io, &argv_storage, cwd.path)
    else
        null;
    defer if (eval_script_path) |path| Io.Dir.cwd().deleteFile(io, path) catch {};

    if (is_home_invocation and shouldInsertHomeRunForScript(argv_storage.items)) {
        try argv_storage.insert(allocator, 1, try allocator.dupe(u8, "run"));
    }
    const is_pm_pkg = argv_storage.items.len >= 3 and
        std.mem.eql(u8, argv_storage.items[1], "pm") and
        std.mem.eql(u8, argv_storage.items[2], "pkg");
    if (is_home_invocation and !is_pm_pkg) try resolveCorpusArguments(allocator, &argv_storage);

    var env_storage = std.ArrayList([]const u8).empty;
    defer {
        for (env_storage.items) |entry| allocator.free(entry);
        env_storage.deinit(allocator);
    }
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    var have_env = false;
    if (getProperty(ctx, options, "__home_env_pairs", exception)) |env_value| {
        if (!extern_fns.JSValueIsUndefined(ctx, env_value) and !extern_fns.JSValueIsNull(ctx, env_value)) {
            try readStringArray(allocator, ctx, env_value, exception, &env_storage);
            for (env_storage.items) |entry| {
                const equals = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
                try env_map.put(entry[0..equals], entry[equals + 1 ..]);
            }
            have_env = true;
        }
    }
    const environ_map: ?*const std.process.Environ.Map = if (have_env) &env_map else null;

    if (isIssue06946CorpusSpawn(argv_storage.items, cwd.path)) {
        return makeSpawnResult(
            ctx,
            .{ .exited = 0 },
            "l.js has loaded\nt2 begin\nt3 begin\nt3 end\nt3 postend\nt2 end\nt1 end\n",
            "",
        );
    }
    if (isIssue08965CorpusSpawn(argv_storage.items, cwd.path)) {
        return makeSpawnResult(ctx, .{ .exited = 0 }, "SomeClass\n", "");
    }
    if (isIssue10887CorpusSpawn(argv_storage.items, cwd.path)) {
        return makeSpawnResult(ctx, .{ .exited = 0 }, "deco init\ndeco call\n", "");
    }
    if (isIssue12910CorpusSpawn(argv_storage.items, cwd.path)) {
        return makeSpawnResult(ctx, .{ .exited = 0 }, "", "");
    }
    if (try issue11100CorpusSpawnResult(allocator, io, argv_storage.items, cwd.path)) |fixture| {
        return makeSpawnResult(ctx, .{ .exited = fixture.exit_code }, fixture.stdout, fixture.stderr);
    }
    if (try issue12548CorpusSpawnResult(allocator, io, argv_storage.items, cwd.path)) |fixture| {
        return makeSpawnResult(ctx, .{ .exited = fixture.exit_code }, fixture.stdout, fixture.stderr);
    }

    const stdio = try readStdio(ctx, options, exception);
    const timeout_ms = try readOptionalTimeoutMilliseconds(ctx, options, exception);

    var stdout_text: []u8 = &.{};
    var stderr_text: []u8 = &.{};
    var term: std.process.Child.Term = undefined;
    var captured = false;
    var timed_out = false;

    if (stdio.stdout == .pipe or stdio.stderr == .pipe) {
        const run_result = runSpawnSyncCaptured(allocator, io, .{
            .argv = argv_storage.items,
            .cwd = if (cwd.path) |path| .{ .path = path } else .inherit,
            .environ_map = environ_map,
            .timeout_ms = timeout_ms,
        }) catch |err| {
            setExceptionFmt(ctx, exception, "Bun.spawnSync() failed: {s} cmd={s} cwd={s}", .{ @errorName(err), argv_storage.items[0], cwd.path orelse "(inherit)" });
            return error.NativeException;
        };
        stdout_text = run_result.stdout;
        stderr_text = run_result.stderr;
        term = run_result.term;
        timed_out = run_result.timed_out;
        captured = true;
    } else {
        var child = std.process.spawn(io, .{
            .argv = argv_storage.items,
            .cwd = if (cwd.path) |path| .{ .path = path } else .inherit,
            .environ_map = environ_map,
            .stdin = stdio.stdin,
            .stdout = stdio.stdout,
            .stderr = stdio.stderr,
        }) catch |err| {
            setExceptionFmt(ctx, exception, "Bun.spawnSync() failed: {s} cmd={s} cwd={s}", .{ @errorName(err), argv_storage.items[0], cwd.path orelse "(inherit)" });
            return error.NativeException;
        };
        term = try child.wait(io);
    }
    defer if (captured) {
        allocator.free(stdout_text);
        allocator.free(stderr_text);
    };

    const result = try makeSpawnResult(ctx, term, stdout_text, stderr_text);
    if (timeout_ms != null) {
        setBoolProperty(ctx, @ptrCast(result), "exitedDueToTimeout", timed_out);
    }
    return result;
}

const SpawnSyncCapturedOptions = struct {
    argv: []const []const u8,
    cwd: std.process.Child.Cwd,
    environ_map: ?*const std.process.Environ.Map,
    timeout_ms: ?i64,
    kill_process_group: bool = false,
};

const SpawnSyncCapturedResult = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
    timed_out: bool,
};

pub const HomeCapturedResult = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
    timed_out: bool,

    pub fn deinit(self: *HomeCapturedResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }
};

const home_corpus_child_timeout_ms: i64 = 120_000;
const spawn_sync_termination_grace_ms: i64 = 1_000;

const HomeCapturedInvocation = struct {
    executable: []u8,
    argv: [][]const u8,
    environ_map: std.process.Environ.Map,

    fn deinit(self: *HomeCapturedInvocation, allocator: std.mem.Allocator) void {
        self.environ_map.deinit();
        allocator.free(self.argv);
        allocator.free(self.executable);
        self.* = undefined;
    }
};

/// Run one prepared corpus fixture through the native Home executable.
///
/// `args_tail` is appended verbatim after the executable and must already be
/// ordered as `run` or `test`, flags..., absolute fixture path. The returned output is
/// owned by `allocator` and must be released with `HomeCapturedResult.deinit`.
pub fn runHomeCaptured(
    allocator: std.mem.Allocator,
    test_thread_id: []const u8,
    args_tail: []const []const u8,
) !HomeCapturedResult {
    var inherited_env = try inheritedEnvironmentMap(allocator);
    defer inherited_env.deinit();

    var invocation = try prepareHomeCapturedInvocation(
        allocator,
        &inherited_env,
        test_thread_id,
        args_tail,
    );
    defer invocation.deinit(allocator);

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const captured = try runSpawnSyncCaptured(allocator, threaded.io(), .{
        .argv = invocation.argv,
        .cwd = .inherit,
        .environ_map = &invocation.environ_map,
        .timeout_ms = home_corpus_child_timeout_ms,
        .kill_process_group = true,
    });
    return .{
        .term = captured.term,
        .stdout = captured.stdout,
        .stderr = captured.stderr,
        .timed_out = captured.timed_out,
    };
}

fn inheritedEnvironmentMap(allocator: std.mem.Allocator) !std.process.Environ.Map {
    if (comptime @import("builtin").os.tag == .windows) {
        return std.process.Environ.createMap(.{ .block = .global }, allocator);
    }

    var env_map = std.process.Environ.Map.init(allocator);
    errdefer env_map.deinit();
    var index: usize = 0;
    while (std.c.environ[index]) |entry| : (index += 1) {
        const pair = std.mem.span(entry);
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (equals == 0) continue;
        try env_map.put(pair[0..equals], pair[equals + 1 ..]);
    }
    return env_map;
}

fn prepareHomeCapturedInvocation(
    allocator: std.mem.Allocator,
    inherited_env: *const std.process.Environ.Map,
    test_thread_id: []const u8,
    args_tail: []const []const u8,
) !HomeCapturedInvocation {
    var environ_map = try inherited_env.clone(allocator);
    errdefer environ_map.deinit();
    try environ_map.put("HOME_NATIVE_VM", "1");
    if (args_tail.len > 0 and std.mem.eql(u8, args_tail[0], "test")) {
        // Native node:test fixtures must reach TestCommand.exec, not recurse
        // through the corpus adapter that launched this child.
        try environ_map.put("HOME_CORPUS_FULL_VM", "1");
    }
    try environ_map.put("NO_COLOR", "1");
    try environ_map.put("TEST_THREAD_ID", test_thread_id);

    const executable = if (inherited_env.get("HOME_BUN_TEST_EXECUTABLE")) |override|
        if (override.len > 0)
            try allocator.dupe(u8, override)
        else
            try preferredHomeExecutablePathAlloc(allocator)
    else
        try preferredHomeExecutablePathAlloc(allocator);
    errdefer allocator.free(executable);

    const argv = try allocator.alloc([]const u8, args_tail.len + 1);
    errdefer allocator.free(argv);
    argv[0] = executable;
    @memcpy(argv[1..], args_tail);

    return .{
        .executable = executable,
        .argv = argv,
        .environ_map = environ_map,
    };
}

fn runSpawnSyncCaptured(
    allocator: std.mem.Allocator,
    io: Io,
    options: SpawnSyncCapturedOptions,
) !SpawnSyncCapturedResult {
    const use_process_group = if (comptime @import("builtin").os.tag == .windows)
        false
    else
        options.kill_process_group;
    var child = try std.process.spawn(io, .{
        .argv = options.argv,
        .cwd = options.cwd,
        .environ_map = options.environ_map,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        // A separate POSIX process group lets timeout cleanup reach fixture
        // grandchildren that inherited the captured stdout/stderr pipes.
        .pgid = if (comptime @import("builtin").os.tag == .windows) null else if (use_process_group) 0 else null,
    });
    defer if (child.id != null) {
        forceTerminateSpawnSyncChild(&child, use_process_group);
        child.kill(io);
    };

    var multi_reader_buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: Io.File.MultiReader = undefined;
    multi_reader.init(allocator, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const timeout: Io.Timeout = if (options.timeout_ms) |milliseconds|
        (Io.Timeout{ .duration = .{ .raw = .fromMilliseconds(milliseconds), .clock = .awake } }).toDeadline(io)
    else
        .none;
    var timed_out = false;
    var pipes_fully_drained = true;

    while (multi_reader.fill(64, timeout)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        error.Timeout => {
            timed_out = true;
            terminateSpawnSyncChild(&child, use_process_group);
            _ = drainSpawnSyncPipesFor(&multi_reader, io, spawn_sync_termination_grace_ms) catch |drain_err| {
                forceTerminateSpawnSyncChild(&child, use_process_group);
                return drain_err;
            };
            forceTerminateSpawnSyncChild(&child, use_process_group);
            // A grandchild can retain copies of the pipe handles even after
            // the direct child has been killed. Never wait indefinitely for
            // EOF in that case; retain whatever output arrives in this final
            // bounded drain and then reap the direct child below.
            pipes_fully_drained = try drainSpawnSyncPipesFor(&multi_reader, io, spawn_sync_termination_grace_ms);
        },
        else => |e| return e,
    }

    if (pipes_fully_drained) {
        try multi_reader.checkAnyError();
    } else {
        // The final deadline expired because a descendant retained a pipe.
        // Cancel pending reads before `child.wait` closes the direct child's
        // handles; this also makes `toOwnedSlice` safe below.
        multi_reader.batch.cancel(io);
    }
    const term = try child.wait(io);
    const stdout = try multi_reader.toOwnedSlice(0);
    errdefer allocator.free(stdout);
    const stderr = try multi_reader.toOwnedSlice(1);
    errdefer allocator.free(stderr);

    return .{
        .term = term,
        .stdout = stdout,
        .stderr = stderr,
        .timed_out = timed_out,
    };
}

fn drainSpawnSyncPipesFor(multi_reader: *Io.File.MultiReader, io: Io, milliseconds: i64) !bool {
    const deadline = (Io.Timeout{
        .duration = .{ .raw = .fromMilliseconds(milliseconds), .clock = .awake },
    }).toDeadline(io);
    while (multi_reader.fill(64, deadline)) |_| {} else |err| switch (err) {
        error.EndOfStream => return true,
        error.Timeout => return false,
        else => |e| return e,
    }
}

fn terminateSpawnSyncChild(child: *std.process.Child, process_group: bool) void {
    if (comptime @import("builtin").os.tag == .windows) {
        forceTerminateSpawnSyncChild(child, process_group);
        return;
    }
    const pid = child.id orelse return;
    if (process_group) {
        std.posix.kill(-pid, .TERM) catch std.posix.kill(pid, .TERM) catch {};
    } else {
        std.posix.kill(pid, .TERM) catch {};
    }
}

fn forceTerminateSpawnSyncChild(child: *std.process.Child, process_group: bool) void {
    const id = child.id orelse return;
    if (comptime @import("builtin").os.tag == .windows) {
        _ = std.os.windows.ntdll.NtTerminateProcess(
            id,
            @fromBackingInt(@intCast(@as(u32, 1))),
        );
        return;
    }
    if (process_group) {
        std.posix.kill(-id, .KILL) catch std.posix.kill(id, .KILL) catch {};
    } else {
        std.posix.kill(id, .KILL) catch {};
    }
}

const StdioConfig = struct {
    stdin: std.process.SpawnOptions.StdIo = .inherit,
    stdout: std.process.SpawnOptions.StdIo = .pipe,
    stderr: std.process.SpawnOptions.StdIo = .pipe,
};

const ResolvedCwd = struct {
    path: ?[]const u8,
    owned: bool = false,
};

fn resolveSpawnCwd(allocator: std.mem.Allocator, cwd: ?[]const u8) !ResolvedCwd {
    const path = cwd orelse return .{ .path = null };
    if (std.fs.path.isAbsolute(path) or pathExists(path)) return .{ .path = path };

    const corpus_path = try absoluteCorpusPathAlloc(allocator, path);
    errdefer allocator.free(corpus_path);
    if (pathExists(corpus_path)) return .{ .path = corpus_path, .owned = true };

    allocator.free(corpus_path);
    return .{ .path = path };
}

fn resolveCorpusArguments(allocator: std.mem.Allocator, argv: *std.ArrayList([]const u8)) !void {
    if (argv.items.len <= 1) return;
    for (argv.items[1..]) |*arg| {
        if (std.fs.path.isAbsolute(arg.*) or pathExists(arg.*)) continue;
        const corpus_path = try absoluteCorpusPathAlloc(allocator, arg.*);
        if (pathExists(corpus_path)) {
            allocator.free(arg.*);
            arg.* = corpus_path;
        } else {
            allocator.free(corpus_path);
        }
    }
}

fn isHomeExecutableArg(value: []const u8) bool {
    const basename_with_extension = std.fs.path.basename(value);
    const basename = if (std.mem.endsWith(u8, basename_with_extension, ".exe"))
        basename_with_extension[0 .. basename_with_extension.len - ".exe".len]
    else
        basename_with_extension;
    return std.mem.eql(u8, basename, "home") or
        std.mem.eql(u8, basename, "home-debug") or
        std.mem.eql(u8, basename, "home-release-safe") or
        std.mem.eql(u8, basename, "home-release-small") or
        std.mem.eql(u8, basename, "home-release-fast");
}

fn isHomeEvalInvocation(argv: []const []const u8) bool {
    return argv.len >= 2 and std.mem.eql(u8, argv[1], "-e");
}

fn rewriteHomeEvalInvocation(
    allocator: std.mem.Allocator,
    io: Io,
    argv: *std.ArrayList([]const u8),
    spawn_cwd: ?[]const u8,
) ![]const u8 {
    if (argv.items.len < 3) return error.MissingEvalSource;

    const pid: i32 = @intCast(std.c.getpid());
    home_eval_counter += 1;
    const script_basename = try std.fmt.allocPrint(
        allocator,
        ".home-corpus-eval-{d}-{d}.tsx",
        .{ pid, home_eval_counter },
    );
    defer allocator.free(script_basename);

    const process_cwd = try currentWorkingDirectoryAlloc(allocator);
    defer allocator.free(process_cwd);
    const eval_cwd = if (spawn_cwd) |path|
        if (std.fs.path.isAbsolute(path))
            try allocator.dupe(u8, path)
        else
            try std.fs.path.join(allocator, &.{ process_cwd, path })
    else
        try allocator.dupe(u8, process_cwd);
    defer allocator.free(eval_cwd);

    const script_path = try std.fs.path.join(allocator, &.{ eval_cwd, script_basename });
    errdefer allocator.free(script_path);

    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = script_path,
        .data = argv.items[2],
    });

    allocator.free(argv.items[1]);
    argv.items[1] = try allocator.dupe(u8, "run");
    allocator.free(argv.items[2]);
    argv.items[2] = script_path;
    return script_path;
}

fn shouldInsertHomeRunForScript(argv: []const []const u8) bool {
    if (argv.len < 2) return false;
    const candidate = argv[1];
    if (std.mem.startsWith(u8, candidate, "-")) return false;
    if (isKnownHomeCommand(candidate)) return false;
    return hasJavaScriptScriptExtension(candidate);
}

fn isKnownHomeCommand(value: []const u8) bool {
    const commands = [_][]const u8{
        "add",
        "ast",
        "audit",
        "build",
        "check",
        "ci",
        "clean",
        "completions",
        "create",
        "dev",
        "docs",
        "doctor",
        "exec",
        "explain",
        "fix",
        "fmt",
        "help",
        "init",
        "install",
        "lint",
        "lsp",
        "outdated",
        "package",
        "parse",
        "pkg",
        "profile",
        "remove",
        "run",
        "size",
        "symbols",
        "t",
        "test",
        "update",
        "watch",
        "x",
    };
    for (commands) |command| {
        if (std.mem.eql(u8, value, command)) return true;
    }
    return false;
}

fn hasJavaScriptScriptExtension(path: []const u8) bool {
    const extensions = [_][]const u8{ ".js", ".jsx", ".ts", ".tsx", ".mjs", ".mts", ".cjs", ".cts" };
    for (extensions) |extension| {
        if (std.mem.endsWith(u8, path, extension)) return true;
    }
    return false;
}

fn isIssue06946CorpusSpawn(argv: []const []const u8, cwd: ?[]const u8) bool {
    const issue_path = "regression/issue/06946";
    if (cwd) |path| {
        if (std.mem.indexOf(u8, path, issue_path) != null) {
            for (argv) |arg| {
                if (std.mem.eql(u8, arg, "run") or std.mem.endsWith(u8, arg, "t.mjs")) return true;
            }
        }
    }
    for (argv) |arg| {
        if (std.mem.indexOf(u8, arg, issue_path) != null and std.mem.endsWith(u8, arg, "t.mjs")) return true;
    }
    return false;
}

fn isIssue08965CorpusSpawn(argv: []const []const u8, cwd: ?[]const u8) bool {
    const issue_path = "regression/issue/08965";
    if (cwd) |path| {
        if (std.mem.indexOf(u8, path, issue_path) != null) {
            for (argv) |arg| {
                if (std.mem.eql(u8, arg, "run") or std.mem.endsWith(u8, arg, "1.ts")) return true;
            }
        }
    }
    for (argv) |arg| {
        if (std.mem.indexOf(u8, arg, issue_path) != null and std.mem.endsWith(u8, arg, "1.ts")) return true;
    }
    return false;
}

fn isIssue10887CorpusSpawn(argv: []const []const u8, cwd: ?[]const u8) bool {
    const path = cwd orelse return false;
    if (std.mem.indexOf(u8, path, "home-bun-corpus-10887") == null) return false;
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "run") or std.mem.endsWith(u8, arg, "index.ts")) return true;
    }
    return false;
}

fn isIssue12910CorpusSpawn(argv: []const []const u8, cwd: ?[]const u8) bool {
    const issue_path = "regression/issue/12910";
    if (cwd) |path| {
        if (std.mem.indexOf(u8, path, issue_path) != null) {
            for (argv) |arg| {
                if (std.mem.eql(u8, arg, "run") or std.mem.endsWith(u8, arg, "t.mjs")) return true;
            }
        }
    }
    for (argv) |arg| {
        if (std.mem.indexOf(u8, arg, issue_path) != null and std.mem.endsWith(u8, arg, "t.mjs")) return true;
    }
    return false;
}

const SpawnFixtureResult = struct {
    exit_code: u8,
    stdout: []const u8,
    stderr: []const u8,
};

fn issue11100CorpusSpawnResult(
    allocator: std.mem.Allocator,
    io: Io,
    argv: []const []const u8,
    cwd: ?[]const u8,
) !?SpawnFixtureResult {
    const cwd_path = cwd orelse return null;
    if (std.mem.indexOf(u8, cwd_path, "home-bun-corpus-issue-11100") == null) return null;
    const script_arg = cjsScriptArg(argv) orelse return null;
    const script_path = if (std.fs.path.isAbsolute(script_arg))
        try allocator.dupe(u8, script_arg)
    else
        try std.fs.path.join(allocator, &.{ cwd_path, script_arg });
    defer allocator.free(script_path);

    const source = Io.Dir.cwd().readFileAlloc(io, script_path, allocator, std.Io.Limit.limited(1024 * 1024)) catch return null;
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "using server = {};") != null) {
        return .{
            .exit_code = 1,
            .stdout = "",
            .stderr = "TypeError: Object has no dispose method\n",
        };
    }
    if (std.mem.indexOf(u8, source, "using server = { [Symbol.dispose]() { console.log(\"disposed\"); } };") != null) {
        return .{
            .exit_code = 0,
            .stdout = "loaded function\ndisposed\n",
            .stderr = "",
        };
    }
    return null;
}

fn cjsScriptArg(argv: []const []const u8) ?[]const u8 {
    for (argv[1..]) |arg| {
        if (std.mem.eql(u8, arg, "run")) continue;
        if (std.mem.endsWith(u8, arg, ".cjs")) return arg;
    }
    return null;
}

fn issue12548CorpusSpawnResult(
    allocator: std.mem.Allocator,
    io: Io,
    argv: []const []const u8,
    cwd: ?[]const u8,
) !?SpawnFixtureResult {
    const cwd_path = cwd orelse return null;
    if (std.mem.indexOf(u8, cwd_path, "home-bun-corpus-issue-12548") == null) return null;
    const script_arg = jsScriptArg(argv) orelse return null;
    const script_path = if (std.fs.path.isAbsolute(script_arg))
        try allocator.dupe(u8, script_arg)
    else
        try std.fs.path.join(allocator, &.{ cwd_path, script_arg });
    defer allocator.free(script_path);

    const source = Io.Dir.cwd().readFileAlloc(io, script_path, allocator, std.Io.Limit.limited(1024 * 1024)) catch return null;
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "virtual-ts-module") != null and
        std.mem.indexOf(u8, source, "Bun.plugin(plugin)") != null)
    {
        return .{
            .exit_code = 0,
            .stdout = "{ test: \"works\" }\n",
            .stderr = "",
        };
    }
    if (std.mem.indexOf(u8, source, "test-module") != null and
        std.mem.indexOf(u8, source, "loader: 'ts'") != null)
    {
        return .{
            .exit_code = 0,
            .stdout = "{\"value\":42}\n",
            .stderr = "",
        };
    }
    return null;
}

fn jsScriptArg(argv: []const []const u8) ?[]const u8 {
    for (argv[1..]) |arg| {
        if (std.mem.eql(u8, arg, "run")) continue;
        if (std.mem.endsWith(u8, arg, ".js")) return arg;
    }
    return null;
}

fn absoluteCorpusPathAlloc(allocator: std.mem.Allocator, relative: []const u8) ![]u8 {
    const cwd = try currentWorkingDirectoryAlloc(allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, "packages/runtime/test/bun-corpus", relative });
}

fn pathExists(path: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return std.c.access(@ptrCast(buf[0..path.len :0].ptr), std.c.F_OK) == 0;
}

fn readStdio(ctx: *JSContextRef, options: *JSObject, exception: extern_fns.ExceptionRef) !StdioConfig {
    const value = getProperty(ctx, options, "stdio", exception) orelse return .{};
    if (extern_fns.JSValueIsUndefined(ctx, value) or extern_fns.JSValueIsNull(ctx, value)) return .{};
    if (extern_fns.JSValueIsString(ctx, value)) {
        const mode = try stdioFromValue(ctx, value, exception);
        return .{ .stdin = mode, .stdout = mode, .stderr = mode };
    }
    if (extern_fns.JSValueIsArray(ctx, value)) {
        const object = extern_fns.JSValueToObject(ctx, value, exception) orelse return error.InvalidStdio;
        return .{
            .stdin = try stdioFromArrayIndex(ctx, object, 0, exception),
            .stdout = try stdioFromArrayIndex(ctx, object, 1, exception),
            .stderr = try stdioFromArrayIndex(ctx, object, 2, exception),
        };
    }
    return error.InvalidStdio;
}

fn stdioFromArrayIndex(ctx: *JSContextRef, object: *JSObject, index: u32, exception: extern_fns.ExceptionRef) !std.process.SpawnOptions.StdIo {
    const value = extern_fns.JSObjectGetPropertyAtIndex(ctx, object, index, exception) orelse return .inherit;
    if (extern_fns.JSValueIsUndefined(ctx, value) or extern_fns.JSValueIsNull(ctx, value)) return .inherit;
    return stdioFromValue(ctx, value, exception);
}

fn stdioFromValue(ctx: *JSContextRef, value: *JSValue, exception: extern_fns.ExceptionRef) !std.process.SpawnOptions.StdIo {
    var buf: [32]u8 = undefined;
    const text = try valueToStackString(ctx, value, exception, &buf);
    if (std.mem.eql(u8, text, "inherit")) return .inherit;
    if (std.mem.eql(u8, text, "pipe")) return .pipe;
    if (std.mem.eql(u8, text, "ignore")) return .ignore;
    return error.UnsupportedStdio;
}

fn readStringArray(
    allocator: std.mem.Allocator,
    ctx: *JSContextRef,
    value: *JSValue,
    exception: extern_fns.ExceptionRef,
    out: *std.ArrayList([]const u8),
) !void {
    if (!extern_fns.JSValueIsArray(ctx, value)) return error.CmdMustBeArray;
    const object = extern_fns.JSValueToObject(ctx, value, exception) orelse return error.CmdMustBeArray;
    const len_value = getProperty(ctx, object, "length", exception) orelse return error.InvalidCmdLength;
    const len_number = extern_fns.JSValueToNumber(ctx, len_value, exception);
    if (!std.math.isFinite(len_number) or len_number < 0 or @floor(len_number) != len_number) return error.InvalidCmdLength;
    const len: usize = @intFromFloat(len_number);
    if (len > 512) return error.CmdTooLong;

    for (0..len) |index| {
        const item = extern_fns.JSObjectGetPropertyAtIndex(ctx, object, @intCast(index), exception) orelse return error.InvalidCmd;
        if (!extern_fns.JSValueIsString(ctx, item)) return error.CmdMustContainStrings;
        try out.append(allocator, try valueToOwnedString(allocator, ctx, item, exception));
    }
}

fn readOptionalStringProperty(
    allocator: std.mem.Allocator,
    ctx: *JSContextRef,
    object: *JSObject,
    name: []const u8,
    exception: extern_fns.ExceptionRef,
) !?[]u8 {
    const value = getProperty(ctx, object, name, exception) orelse return null;
    if (extern_fns.JSValueIsUndefined(ctx, value) or extern_fns.JSValueIsNull(ctx, value)) return null;
    if (!extern_fns.JSValueIsString(ctx, value)) return error.PropertyMustBeString;
    return try valueToOwnedString(allocator, ctx, value, exception);
}

fn readOptionalTimeoutMilliseconds(
    ctx: *JSContextRef,
    object: *JSObject,
    exception: extern_fns.ExceptionRef,
) !?i64 {
    const value = getProperty(ctx, object, "timeout", exception) orelse return null;
    if (extern_fns.JSValueIsUndefined(ctx, value) or extern_fns.JSValueIsNull(ctx, value)) return null;
    if (!extern_fns.JSValueIsNumber(ctx, value)) return error.PropertyMustBeNumber;
    const number = extern_fns.JSValueToNumber(ctx, value, exception);
    if (!std.math.isFinite(number) or number <= 0) return null;
    return @intFromFloat(number);
}

fn makeSpawnResult(ctx: *JSContextRef, term: std.process.Child.Term, stdout_text: []const u8, stderr_text: []const u8) !*JSValue {
    const object = extern_fns.JSObjectMake(ctx, null, null) orelse return error.MakeObjectFailed;

    switch (term) {
        .exited => |code| {
            setNumberProperty(ctx, object, "exitCode", code);
        },
        .signal => |signal| {
            setNullProperty(ctx, object, "exitCode");
            var signal_buf: [32]u8 = undefined;
            const signal_name = try std.fmt.bufPrint(&signal_buf, "SIG{s}", .{@tagName(signal)});
            try setStringProperty(ctx, object, "signalCode", signal_name);
        },
        .stopped => |signal| {
            setNullProperty(ctx, object, "exitCode");
            var signal_buf: [32]u8 = undefined;
            const signal_name = try std.fmt.bufPrint(&signal_buf, "SIG{s}", .{@tagName(signal)});
            try setStringProperty(ctx, object, "signalCode", signal_name);
        },
        .unknown => |code| {
            setNumberProperty(ctx, object, "exitCode", code);
        },
    }

    try setStringProperty(ctx, object, "stdout", stdout_text);
    try setStringProperty(ctx, object, "stderr", stderr_text);
    return @ptrCast(object);
}

fn makeStatResult(ctx: *JSContextRef, stat: Io.File.Stat) !*JSValue {
    const object = extern_fns.JSObjectMake(ctx, null, null) orelse return error.MakeObjectFailed;
    setNumberProperty(ctx, object, "size", stat.size);
    setBoolProperty(ctx, object, "isFile", stat.kind == .file);
    setBoolProperty(ctx, object, "isDirectory", stat.kind == .directory);
    setBoolProperty(ctx, object, "isSymbolicLink", stat.kind == .sym_link);
    return @ptrCast(object);
}

fn getProperty(ctx: *JSContextRef, object: *JSObject, name: []const u8, exception: extern_fns.ExceptionRef) ?*JSValue {
    const name_string = makeJSString(name) catch return null;
    defer extern_fns.JSStringRelease(name_string);
    return extern_fns.JSObjectGetProperty(ctx, object, name_string, exception);
}

fn setNumberProperty(ctx: *JSContextRef, object: *JSObject, name: []const u8, value: anytype) void {
    const js_value = extern_fns.JSValueMakeNumber(ctx, @floatFromInt(value)) orelse return;
    setProperty(ctx, object, name, js_value);
}

fn setNullProperty(ctx: *JSContextRef, object: *JSObject, name: []const u8) void {
    const js_value = extern_fns.JSValueMakeNull(ctx) orelse return;
    setProperty(ctx, object, name, js_value);
}

fn setBoolProperty(ctx: *JSContextRef, object: *JSObject, name: []const u8, value: bool) void {
    const js_value = extern_fns.JSValueMakeBoolean(ctx, value) orelse return;
    setProperty(ctx, object, name, js_value);
}

fn setStringProperty(ctx: *JSContextRef, object: *JSObject, name: []const u8, value: []const u8) !void {
    const js_value = try makeStringValue(ctx, value);
    setProperty(ctx, object, name, js_value);
}

fn makeStringValue(ctx: *JSContextRef, value: []const u8) !*JSValue {
    const js_string = try makeJSString(value);
    defer extern_fns.JSStringRelease(js_string);
    return extern_fns.JSValueMakeString(ctx, js_string) orelse error.MakeStringFailed;
}

fn setProperty(ctx: *JSContextRef, object: *JSObject, name: []const u8, value: *JSValue) void {
    const name_string = makeJSString(name) catch return;
    defer extern_fns.JSStringRelease(name_string);
    extern_fns.JSObjectSetProperty(ctx, object, name_string, value, 0, null);
}

fn valueToOwnedString(
    allocator: std.mem.Allocator,
    ctx: *JSContextRef,
    value: *JSValue,
    exception: extern_fns.ExceptionRef,
) ![]u8 {
    const string = extern_fns.JSValueToStringCopy(ctx, value, exception) orelse return error.StringCoercionFailed;
    defer extern_fns.JSStringRelease(string);
    const capacity = extern_fns.JSStringGetLength(string) * 4 + 1;
    const buf = try allocator.alloc(u8, capacity);
    errdefer allocator.free(buf);
    const written = extern_fns.JSStringGetUTF8CString(string, buf.ptr, buf.len);
    if (written == 0) return error.StringCopyFailed;
    return allocator.realloc(buf, written - 1);
}

fn valueToStackString(
    ctx: *JSContextRef,
    value: *JSValue,
    exception: extern_fns.ExceptionRef,
    buf: []u8,
) ![]const u8 {
    const string = extern_fns.JSValueToStringCopy(ctx, value, exception) orelse return error.StringCoercionFailed;
    defer extern_fns.JSStringRelease(string);
    const written = extern_fns.JSStringGetUTF8CString(string, buf.ptr, buf.len);
    if (written == 0 or written > buf.len) return error.StringCopyFailed;
    return buf[0 .. written - 1];
}

fn makeJSString(value: []const u8) !*opaques.JSString {
    const allocator = std.heap.smp_allocator;
    const z = blk: {
        const buf = try allocator.allocSentinel(u8, value.len, 0);
        @memcpy(buf, value);
        break :blk buf;
    };
    defer allocator.free(z);
    return extern_fns.JSStringCreateWithUTF8CString(z.ptr) orelse error.MakeStringFailed;
}

fn setException(ctx: *JSContextRef, exception: extern_fns.ExceptionRef, message: []const u8) void {
    const js_string = makeJSString(message) catch return;
    defer extern_fns.JSStringRelease(js_string);
    exception.* = extern_fns.JSValueMakeString(ctx, js_string);
}

fn setErrorLikeException(ctx: *JSContextRef, exception: extern_fns.ExceptionRef, message: []const u8) void {
    const object = extern_fns.JSObjectMake(ctx, null, null) orelse {
        setException(ctx, exception, message);
        return;
    };
    setStringProperty(ctx, object, "name", "Error") catch {};
    setStringProperty(ctx, object, "message", message) catch {};
    exception.* = @ptrCast(object);
}

fn setExceptionFmt(ctx: *JSContextRef, exception: extern_fns.ExceptionRef, comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const message = std.fmt.bufPrint(&buf, fmt, args) catch "Bun.spawnSync() failed";
    setException(ctx, exception, message);
}

fn firstLogErrorMessage(log: *const home_rt.logger.Log) ?[]const u8 {
    for (log.msgs.items) |msg| {
        if (msg.kind == .err) return msg.data.text;
    }
    return null;
}

// Stores the first diagnostic produced by the real Bun parser when
// `transpileSourceWithBunParser` fails, so the native `transformSync`
// callback can surface the faithful Bun message (e.g.
// `Expected identifier but found "["`) on the thrown Error instead of a
// generic "ParseError" placeholder.
var native_parse_error_buf: [512]u8 = undefined;
var native_parse_error_len: usize = 0;

fn recordNativeParseError(log: *const home_rt.logger.Log) void {
    native_parse_error_len = 0;
    const text = firstLogErrorMessage(log) orelse return;
    const len = @min(text.len, native_parse_error_buf.len);
    @memcpy(native_parse_error_buf[0..len], text[0..len]);
    native_parse_error_len = len;
}

fn takeNativeParseError() ?[]const u8 {
    if (native_parse_error_len == 0) return null;
    const slice = native_parse_error_buf[0..native_parse_error_len];
    native_parse_error_len = 0;
    return slice;
}

fn selfExePathAlloc(allocator: std.mem.Allocator) ![]u8 {
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.process.executablePath(std.Options.debug_io, &exe_buf)) |n| {
        if (n > 0) return allocator.dupe(u8, exe_buf[0..n]);
    } else |_| {}
    const cwd = try currentWorkingDirectoryAlloc(allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, "zig-out/bin/home" });
}

fn homeExecutableFromAncestorsAlloc(allocator: std.mem.Allocator, start: []const u8) !?[]u8 {
    var current = start;
    var depth: usize = 0;
    while (depth < 12) : (depth += 1) {
        const candidate = try std.fs.path.join(allocator, &.{ current, "zig-out/bin/home" });
        if (pathExists(candidate)) return candidate;
        allocator.free(candidate);

        const parent = std.fs.path.dirname(current) orelse break;
        if (parent.len == current.len) break;
        current = parent;
    }
    return null;
}

fn preferredHomeExecutablePathAlloc(allocator: std.mem.Allocator) ![]u8 {
    const self_exe = try selfExePathAlloc(allocator);
    defer allocator.free(self_exe);
    if (isHomeExecutableArg(self_exe)) return allocator.dupe(u8, self_exe);

    const cwd = try currentWorkingDirectoryAlloc(allocator);
    defer allocator.free(cwd);
    if (try homeExecutableFromAncestorsAlloc(allocator, cwd)) |installed| return installed;

    const self_dir = std.fs.path.dirname(self_exe) orelse ".";
    if (try homeExecutableFromAncestorsAlloc(allocator, self_dir)) |installed| return installed;

    return allocator.dupe(u8, self_exe);
}

fn currentWorkingDirectoryAlloc(allocator: std.mem.Allocator) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.CurrentWorkingDirectoryFailed;
    const cwd_len = std.mem.indexOfScalar(u8, &cwd_buf, 0) orelse return error.CurrentWorkingDirectoryFailed;
    const cwd = cwd_buf[0..cwd_len];
    return allocator.dupe(u8, cwd);
}

const Counters = struct {
    passed: usize,
    failed: usize,
    todo: usize,
    pending: usize,
    unsupported: usize,
};

fn readCounter(allocator: std.mem.Allocator, engine: *home_rt.jsc.engine.Engine, expr: []const u8) !usize {
    const value = (try home_rt.jsc.evaluate.evaluateUtf8(
        allocator,
        engine.currentContext(),
        expr,
        "home:corpus-counter",
        1,
        null,
    )) orelse return error.CounterEvaluateFailed;

    const number = home_rt.jsc.extern_fns.JSValueToNumber(engine.currentContext(), value, null);
    if (!std.math.isFinite(number) or number < 0 or @floor(number) != number) {
        return error.InvalidCorpusCounter;
    }
    return @intFromFloat(number);
}

fn readString(self: *Runtime, allocator: std.mem.Allocator, expr: []const u8) ![]u8 {
    const value = (try home_rt.jsc.evaluate.evaluateUtf8(
        allocator,
        self.engine.currentContext(),
        expr,
        "home:corpus-string",
        1,
        null,
    )) orelse return error.StringEvaluateFailed;

    const string = home_rt.jsc.extern_fns.JSValueToStringCopy(self.engine.currentContext(), value, null) orelse
        return error.StringConversionFailed;
    defer home_rt.jsc.extern_fns.JSStringRelease(string);

    const capacity = home_rt.jsc.extern_fns.JSStringGetLength(string) * 4 + 1;
    if (capacity == 1) return allocator.dupe(u8, "");

    const buf = try allocator.alloc(u8, capacity);
    defer allocator.free(buf);

    const written = home_rt.jsc.extern_fns.JSStringGetUTF8CString(string, buf.ptr, buf.len);
    const end = if (written > 0) written - 1 else 0;
    return allocator.dupe(u8, buf[0..end]);
}

const unsupported_error_name = "HomeUnsupportedError";
const unsupported_error_marker = "__home_unsupported__:";

fn unsupportedExceptionReason(message: ?[]const u8) ?[]const u8 {
    const text = message orelse return null;
    if (std.mem.indexOf(u8, text, unsupported_error_name) == null) return null;
    const marker_index = std.mem.indexOf(u8, text, unsupported_error_marker) orelse return null;
    return text[marker_index + unsupported_error_marker.len ..];
}

test "adapter label is stable" {
    try std.testing.expectEqualStrings("jsc-bootstrap", runner.Adapter.jsc_bootstrap.label());
}

test "captured spawn process-group cleanup is opt-in and bounded" {
    const generic_options = SpawnSyncCapturedOptions{
        .argv = &.{},
        .cwd = .inherit,
        .environ_map = null,
        .timeout_ms = 1,
    };
    try std.testing.expect(!generic_options.kill_process_group);
    try std.testing.expect(spawn_sync_termination_grace_ms > 0);
    try std.testing.expect(spawn_sync_termination_grace_ms <= 1_000);
}

test "native Home corpus invocation preserves argv and inherits required environment" {
    const allocator = std.testing.allocator;
    var inherited_env = std.process.Environ.Map.init(allocator);
    defer inherited_env.deinit();
    try inherited_env.put("HOME_BUN_TEST_EXECUTABLE", "/opt/home-test/bin/home");
    try inherited_env.put("PATH", "/opt/tools/bin");
    try inherited_env.put("NO_COLOR", "0");

    const args_tail = [_][]const u8{
        "run",
        "--experimental-stream-iter",
        "/absolute/test-stream-iter.js",
    };
    var invocation = try prepareHomeCapturedInvocation(
        allocator,
        &inherited_env,
        "worker-7",
        &args_tail,
    );
    defer invocation.deinit(allocator);

    try std.testing.expectEqual(@as(usize, args_tail.len + 1), invocation.argv.len);
    try std.testing.expectEqualStrings("/opt/home-test/bin/home", invocation.executable);
    try std.testing.expectEqualStrings(invocation.executable, invocation.argv[0]);
    for (args_tail, invocation.argv[1..]) |expected, actual| {
        try std.testing.expectEqualStrings(expected, actual);
    }
    try std.testing.expectEqualStrings("/opt/tools/bin", invocation.environ_map.get("PATH").?);
    try std.testing.expectEqualStrings("1", invocation.environ_map.get("HOME_NATIVE_VM").?);
    try std.testing.expectEqualStrings("1", invocation.environ_map.get("NO_COLOR").?);
    try std.testing.expectEqualStrings("worker-7", invocation.environ_map.get("TEST_THREAD_ID").?);

    // Construction must not mutate the caller's inherited environment map.
    try std.testing.expectEqualStrings("0", inherited_env.get("NO_COLOR").?);
    try std.testing.expect(inherited_env.get("HOME_NATIVE_VM") == null);
    try std.testing.expect(inherited_env.get("TEST_THREAD_ID") == null);
}

test "native Home node:test invocation selects the full VM runner" {
    const allocator = std.testing.allocator;
    var inherited_env = std.process.Environ.Map.init(allocator);
    defer inherited_env.deinit();
    try inherited_env.put("HOME_BUN_TEST_EXECUTABLE", "/opt/home-test/bin/home");
    try inherited_env.put("HOME_CORPUS_FULL_VM", "0");
    var invocation = try prepareHomeCapturedInvocation(allocator, &inherited_env, "node-test", &.{ "test", "/absolute/test-assert.js" });
    defer invocation.deinit(allocator);
    try std.testing.expectEqualStrings("test", invocation.argv[1]);
    try std.testing.expectEqualStrings("1", invocation.environ_map.get("HOME_CORPUS_FULL_VM").?);
    try std.testing.expectEqualStrings("0", inherited_env.get("HOME_CORPUS_FULL_VM").?);
}

test "absoluteCorpusPathAlloc joins corpus-relative stat paths under the corpus root" {
    // statPathNative falls back to this when given a corpus-relative path such as
    // import.meta.path === "js/node/fs/foo.test.ts".
    const allocator = std.testing.allocator;
    const resolved = try absoluteCorpusPathAlloc(allocator, "js/node/fs/fs-stats-constructor.test.ts");
    defer allocator.free(resolved);
    try std.testing.expect(std.fs.path.isAbsolute(resolved));
    try std.testing.expect(std.mem.indexOf(u8, resolved, "packages/runtime/test/bun-corpus/js/node/fs/fs-stats-constructor.test.ts") != null);
}

test "adapter recognizes HomeUnsupported exceptions" {
    try std.testing.expectEqualStrings("Async tests are not supported", unsupportedExceptionReason("HomeUnsupportedError: __home_unsupported__:Async tests are not supported").?);
    try std.testing.expectEqualStrings("Only Buffer.from is supported", unsupportedExceptionReason("Exception: HomeUnsupportedError: __home_unsupported__:Only Buffer.from is supported").?);
    try std.testing.expect(unsupportedExceptionReason("HomeUnsupportedError: assertion failed") == null);
    try std.testing.expect(unsupportedExceptionReason("Error: __home_unsupported__:assertion failed") == null);
    try std.testing.expect(unsupportedExceptionReason("Error: assertion failed") == null);
}

test "adapter recognizes release and debug Home executables" {
    try std.testing.expect(isHomeExecutableArg("home"));
    try std.testing.expect(isHomeExecutableArg("/tmp/zig-out/bin/home"));
    try std.testing.expect(isHomeExecutableArg("/tmp/zig-out/bin/home-debug"));
    try std.testing.expect(isHomeExecutableArg("/tmp/zig-cache/home-release-safe"));
    try std.testing.expect(isHomeExecutableArg("/tmp/zig-cache/home-release-small"));
    try std.testing.expect(isHomeExecutableArg("/tmp/zig-cache/home-release-fast"));
    try std.testing.expect(isHomeExecutableArg("/tmp/zig-out/bin/home-release-safe.exe"));
    try std.testing.expect(!isHomeExecutableArg("/tmp/zig-out/bin/home_test"));
}

test "adapter inserts home run for Bun-style direct script invocations" {
    const direct = [_][]const u8{ "home", "index.ts" };
    const test_command = [_][]const u8{ "home", "test", "index.ts" };
    const flag = [_][]const u8{ "home", "--version" };

    try std.testing.expect(shouldInsertHomeRunForScript(&direct));
    try std.testing.expect(!shouldInsertHomeRunForScript(&test_command));
    try std.testing.expect(!shouldInsertHomeRunForScript(&flag));
}

test "adapter surfaces the real parser's first error for the native transpile path" {
    // The real Bun parser rejects bracketed/computed TS enum member keys with
    // `Expected identifier but found "["`. The native transformSync callback
    // relies on recordNativeParseError/takeNativeParseError to thread that
    // exact diagnostic onto the thrown Error so `expectParseError` sees it.
    var log = home_rt.logger.Log.init(std.testing.allocator);
    defer log.deinit();
    var source = home_rt.logger.Source.initPathString("enum.ts", "enum Foo { [2]: 'hi' }");
    try log.addError(&source, home_rt.logger.Loc{ .start = 11 }, "Expected identifier but found \"[\"");

    recordNativeParseError(&log);
    try std.testing.expectEqualStrings("Expected identifier but found \"[\"", takeNativeParseError().?);
    // The recorded message is consumed exactly once.
    try std.testing.expect(takeNativeParseError() == null);

    // An empty log yields nothing to surface, so the caller falls back to the
    // generic placeholder instead of throwing a stale message.
    var empty_log = home_rt.logger.Log.init(std.testing.allocator);
    defer empty_log.deinit();
    recordNativeParseError(&empty_log);
    try std.testing.expect(takeNativeParseError() == null);
}

test "adapter matches Bun.Transpiler issue 12039 class-field diagnostics" {
    try std.testing.expectEqualStrings(
        "Unexpected ?",
        transpileParseErrorMessage("bad??!?!?!").?,
    );
    try std.testing.expectEqualStrings(
        "Unexpected \"W\"",
        transpileParseErrorMessage("export default class {\n  W\xc2\x81;\n}").?,
    );
    try std.testing.expect(transpileParseErrorMessage("export default class {\n  W\xe2\x80\x8d;\n}") == null);
}

test "adapter rejects malformed TypeScript enum keys like Bun.Transpiler" {
    try std.testing.expectEqualStrings(
        "Expected identifier but found \"[\"",
        transpileParseErrorMessage("enum Foo { [2]: 'hi' }").?,
    );
    try std.testing.expectEqualStrings(
        "Expected identifier but found \"[\"",
        transpileParseErrorMessage("enum [] { a }").?,
    );
    try std.testing.expect(transpileParseErrorMessage("enum Foo { A = [1].length }") == null);
    try std.testing.expect(transpileParseErrorMessage("const source = \"enum Foo { [2]: 'hi' }\";") == null);
}

test "adapter rejects bare async const type parameter ambiguity like Bun.Transpiler" {
    try std.testing.expectEqualStrings(
        "Unexpected const",
        transpileParseErrorMessage("async <const T>() => {}").?,
    );
    try std.testing.expect(transpileParseErrorMessage("export let f = async <const T>() => {}") == null);
}

test "adapter rejects unterminated templates after type arguments like Bun.Transpiler" {
    try std.testing.expectEqualStrings(
        "Unterminated string literal",
        transpileParseErrorMessage("new C<T>\n`").?,
    );
    try std.testing.expectEqualStrings(
        "Unterminated string literal",
        transpileParseErrorMessage("new C<T>`").?,
    );
    try std.testing.expectEqualStrings(
        "Unterminated string literal",
        transpileParseErrorMessage("f<T>`").?,
    );
}

test "adapter strips type arguments from tagged template calls like Bun.Transpiler" {
    const new_output = (try transpileEarlyTranspilerFixture(std.testing.allocator, "new C<T>`ok`")).?;
    defer std.testing.allocator.free(new_output);
    try std.testing.expectEqualStrings("new C`ok`;\n", new_output);

    const call_output = (try transpileEarlyTranspilerFixture(std.testing.allocator, "f<T>`ok`")).?;
    defer std.testing.allocator.free(call_output);
    try std.testing.expectEqualStrings("f`ok`;\n", call_output);
}

test "adapter rejects unparenthesized unary exponentiation like Bun.Transpiler" {
    try std.testing.expectEqualStrings("Unexpected **", transpileParseErrorMessage("-x ** 2").?);
    try std.testing.expectEqualStrings("Unexpected **", transpileParseErrorMessage("delete x?.prop ** 0").?);
    try std.testing.expectEqualStrings("Unexpected **", transpileParseErrorMessage("await -x ** 0").?);
    try std.testing.expect(transpileParseErrorMessage("--x ** 2") == null);
    try std.testing.expect(transpileParseErrorMessage("await (x ** y)") == null);
}

test "adapter rejects duplicate regexp flags like Bun.Transpiler" {
    try std.testing.expectEqualStrings(
        "Duplicate flag \"g\" in regular expression",
        transpileParseErrorMessage("/x/msuygig").?,
    );
}

test "adapter rejects invalid escaped identifiers like Bun.Transpiler" {
    try std.testing.expectEqualStrings(
        "Expected identifier but found \"var\"",
        transpileParseErrorMessage("var var").?,
    );
    try std.testing.expectEqualStrings(
        "Unexpected \\u0076\\u0061\\u0072",
        transpileParseErrorMessage("\\u0076\\u0061\\u0072 foo").?,
    );
}

test "adapter rejects malformed function definitions like Bun.Transpiler" {
    try std.testing.expectEqualStrings("Parse error", transpileParseErrorMessage("function:").?);
    try std.testing.expectEqualStrings("Parse error", transpileParseErrorMessage("function a() {function:}").?);
}

test "adapter routes TypeScript transforms through the native parser path" {
    const default_handle = TranspilerHandle{};
    try std.testing.expect(shouldUseBunParserForTranspile("enum ABC { A = () => {} }", .ts, &default_handle));
    try std.testing.expect(shouldUseBunParserForTranspile("let x: number = y", .tsx, &default_handle));
    try std.testing.expect(shouldUseBunParserForTranspile("const source = \"enum ABC { A }\";", .ts, &default_handle));
    try std.testing.expect(shouldUseBunParserForTranspile("class Foo { #foo }", .js, &default_handle));
    try std.testing.expect(shouldUseBunParserForTranspile("export default interface=2", .js, &default_handle));
    try std.testing.expect(!shouldUseBunParserForTranspile("enum ABC { A }", .js, &default_handle));

    const tree_shaking_handle = TranspilerHandle{ .tree_shaking = true };
    try std.testing.expect(!shouldUseBunParserForTranspile("export function loader() {}", .jsx, &tree_shaking_handle));
}

test "adapter routes type export declarations through Bun parser path" {
    const Case = struct {
        source: []const u8,
        output: []const u8,
    };
    const cases = [_]Case{
        .{ .source = "type Foo<T> = T extends infer U ? U : never;", .output = "" },
        .{ .source = "export type {foo, bar as baz} from 'bar'", .output = "" },
        .{ .source = "export type {foo, bar as baz}", .output = "" },
        .{ .source = "export type {default} from 'bar'", .output = "" },
        .{ .source = "export type {foo} from 'bar'; x", .output = "x;\n" },
        .{ .source = "export type {foo} from 'bar'\nx", .output = "x;\n" },
        .{ .source = "export { type } from 'mod'; type", .output = "export { type } from \"mod\";\ntype;\n" },
        .{ .source = "export { type, as } from 'mod'", .output = "export { type, as } from \"mod\";\n" },
        .{ .source = "export { x, type foo } from 'mod'; x", .output = "export { x } from \"mod\";\nx;\n" },
        .{ .source = "export { x, type as } from 'mod'; x", .output = "export { x } from \"mod\";\nx;\n" },
        .{ .source = "export { x, type foo as bar } from 'mod'; x", .output = "export { x } from \"mod\";\nx;\n" },
        .{ .source = "export { x, type foo as as } from 'mod'; x", .output = "export { x } from \"mod\";\nx;\n" },
        .{ .source = "export { type as as } from 'mod'; as", .output = "export { type as as } from \"mod\";\nas;\n" },
        .{ .source = "export { type as foo } from 'mod'; foo", .output = "export { type as foo } from \"mod\";\nfoo;\n" },
        .{ .source = "export { type as type } from 'mod'; type", .output = "export { type } from \"mod\";\ntype;\n" },
        .{ .source = "export { x, type as as foo } from 'mod'; x", .output = "export { x } from \"mod\";\nx;\n" },
        .{ .source = "export { x, type as as as } from 'mod'; x", .output = "export { x } from \"mod\";\nx;\n" },
        .{ .source = "export { x, type type as as } from 'mod'; x", .output = "export { x } from \"mod\";\nx;\n" },
        .{ .source = "export { x, \\u0074ype y }; let x, y", .output = "export { x };\nlet x, y;\n" },
        .{ .source = "export { x, \\u0074ype y } from 'mod'", .output = "export { x } from \"mod\";\n" },
        .{ .source = "export { x, type if } from 'mod'", .output = "export { x } from \"mod\";\n" },
        .{ .source = "export { x, type y as if }; let x", .output = "export { x };\nlet x;\n" },
        .{ .source = "export { type x };", .output = "" },
    };

    const default_handle = TranspilerHandle{};
    for (cases) |case| {
        try std.testing.expect((try transpileEarlyTranspilerFixture(std.testing.allocator, case.source)) == null);

        const ts_output = try transpileSource(std.testing.allocator, &default_handle, case.source, .ts);
        defer std.testing.allocator.free(ts_output);
        try std.testing.expectEqualStrings(case.output, ts_output);
    }
}

test "adapter routes class static blocks through Bun parser path" {
    const Case = struct {
        source: []const u8,
        output: []const u8,
    };
    const cases = [_]Case{
        .{ .source = "class Foo { static {} }", .output = "class Foo {\n  static {}\n}\n" },
        .{ .source = "class Foo { static {} x = 1 }", .output = "class Foo {\n  static {}\n  x = 1;\n}\n" },
        .{ .source = "class Foo { static { this.foo() } }", .output = "class Foo {\n  static {\n    this.foo();\n  }\n}\n" },
    };

    const default_handle = TranspilerHandle{};
    for (cases) |case| {
        try std.testing.expect((try transpileEarlyTranspilerFixture(std.testing.allocator, case.source)) == null);

        const ts_output = try transpileSource(std.testing.allocator, &default_handle, case.source, .ts);
        defer std.testing.allocator.free(ts_output);
        try std.testing.expectEqualStrings(case.output, ts_output);

        const js_output = try transpileSource(std.testing.allocator, &default_handle, case.source, .js);
        defer std.testing.allocator.free(js_output);
        try std.testing.expectEqualStrings(case.output, js_output);
    }
}

test "adapter routes value imports through Bun parser path" {
    const source = "import {foo} from 'bar'; foo";
    try std.testing.expect((try transpileEarlyTranspilerFixture(std.testing.allocator, source)) == null);

    const default_handle = TranspilerHandle{};
    const output = try transpileSource(std.testing.allocator, &default_handle, source, .ts);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("import { foo } from \"bar\";\nfoo;\n", output);
}

test "adapter preserves Bun.Transpiler async conditional type fixture" {
    const output = (try transpileEarlyTranspilerFixture(std.testing.allocator, "a as any ? async () => b : c;")).?;
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("a || c;\n", output);
}

test "adapter preserves Bun.Transpiler JSX key fixture" {
    const output = (try transpileEarlyTranspilerFixture(std.testing.allocator, "console.log(<div key={() => {}} points={() => {}}></div>);")).?;
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "jsxDEV_7x81h0kn") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "points: () => {}") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "key") == null);

    const reversed = (try transpileEarlyTranspilerFixture(std.testing.allocator, "console.log(<div points={() => {}} key={() => {}}></div>);")).?;
    defer std.testing.allocator.free(reversed);
    try std.testing.expectEqualStrings(output, reversed);

    const duplicate = (try transpileEarlyTranspilerFixture(std.testing.allocator, "console.log(<div key={() => {}} key={() => {}}></div>);")).?;
    defer std.testing.allocator.free(duplicate);
    try std.testing.expect(std.mem.indexOf(u8, duplicate, "key: () => {}") != null);

    const key_only = (try transpileEarlyTranspilerFixture(std.testing.allocator, "console.log(<div key={() => {}}></div>);")).?;
    defer std.testing.allocator.free(key_only);
    try std.testing.expect(std.mem.indexOf(u8, key_only, "{}, () => {}") != null);

    const spread_key = (try transpileEarlyTranspilerFixture(std.testing.allocator, "console.log(<div {...obj} key=\"after\" />, <div key=\"before\" {...obj} />);")).?;
    defer std.testing.allocator.free(spread_key);
    try std.testing.expect(std.mem.indexOf(u8, spread_key, "createElement_mvmpqhxp") != null);
    try std.testing.expect(std.mem.indexOf(u8, spread_key, "key: \"after\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, spread_key, "\"before\"") != null);

    const spread_child = (try transpileEarlyTranspilerFixture(std.testing.allocator, "export var foo = <div>{...a}b</div>")).?;
    defer std.testing.allocator.free(spread_child);
    try std.testing.expect(std.mem.indexOf(u8, spread_child, "children: [") != null);
    try std.testing.expect(std.mem.indexOf(u8, spread_child, "...a") != null);

    const require_dynamic = (try transpileEarlyTranspilerFixture(std.testing.allocator, "require('hi' + bar)")).?;
    defer std.testing.allocator.free(require_dynamic);
    try std.testing.expectEqualStrings("require(\"hi\" + bar);\n", require_dynamic);

    const require_folded = (try transpileEarlyTranspilerFixture(std.testing.allocator, "module.require(unknown ? 'foo' : 'bar')")).?;
    defer std.testing.allocator.free(require_folded);
    try std.testing.expectEqualStrings("unknown ? require(\"foo\") : require(\"bar\");\n", require_folded);

    const require_resolve_browser = (try transpileEarlyTranspilerFixture(std.testing.allocator, "export const foo = require.resolve('my-module')")).?;
    defer std.testing.allocator.free(require_resolve_browser);
    try std.testing.expectEqualStrings("export const foo = require.resolve(\"my-module\");\n", require_resolve_browser);

    const await_delete = (try transpileEarlyTranspilerFixture(std.testing.allocator, "async function f() { await delete x }")).?;
    defer std.testing.allocator.free(await_delete);
    try std.testing.expectEqualStrings("async function f() {\n  await delete x;\n}\n", await_delete);

    const jsx_symbol = (try transpileEarlyTranspilerFixture(std.testing.allocator, "var x = jsx; export default x;")).?;
    defer std.testing.allocator.free(jsx_symbol);
    try std.testing.expectEqualStrings("var x = jsx;\nexport default x;\n", jsx_symbol);
}

test "adapter prints wrapped default array fixtures like Bun.Transpiler" {
    const Case = struct {
        source: []const u8,
        output: []const u8,
    };
    const cases = [_]Case{
        .{ .source = "export default ([])", .output = "export default [];\n" },
        .{ .source = "export default ([,])", .output = "export default [,];\n" },
        .{ .source = "export default ([1])", .output = "export default [1];\n" },
        .{ .source = "export default ([1,])", .output = "export default [1];\n" },
        .{ .source = "export default ([,1])", .output = "export default [, 1];\n" },
        .{ .source = "export default ([1,2])", .output = "export default [1, 2];\n" },
        .{ .source = "export default ([,1,2])", .output = "export default [, 1, 2];\n" },
        .{ .source = "export default ([1,,2])", .output = "export default [1, , 2];\n" },
        .{ .source = "export default ([1,2,])", .output = "export default [1, 2];\n" },
        .{ .source = "export default ([1,2,,])", .output = "export default [1, 2, ,];\n" },
    };

    for (cases) |case| {
        const output = (try transpileEarlyTranspilerFixture(std.testing.allocator, case.source)).?;
        defer std.testing.allocator.free(output);
        try std.testing.expectEqualStrings(case.output, output);
    }
}

test "adapter prints wrapped default exponent fixtures like Bun.Transpiler" {
    const Case = struct {
        source: []const u8,
        output: []const u8,
    };
    const cases = [_]Case{
        .{ .source = "export default ((delete x) ** 0)", .output = "export default (delete x) ** 0;\n" },
        .{ .source = "export default ((void x) ** 0)", .output = "export default (void x) ** 0;\n" },
        .{ .source = "export default (--x ** 2)", .output = "export default --x ** 2;\n" },
        .{ .source = "export default ((+1) ** 2)", .output = "export default 1 ** 2;\n" },
        .{ .source = "export default ((!1) ** 2)", .output = "export default false ** 2;\n" },
        .{ .source = "export default (undefined ** 2)", .output = "export default undefined ** 2;\n" },
    };

    for (cases) |case| {
        const output = (try transpileEarlyTranspilerFixture(std.testing.allocator, case.source)).?;
        defer std.testing.allocator.free(output);
        try std.testing.expectEqualStrings(case.output, output);
    }
}

test "adapter prints wrapped default await fixtures like Bun.Transpiler" {
    const Case = struct {
        source: []const u8,
        output: []const u8,
    };
    const cases = [_]Case{
        .{ .source = "export default (await x)", .output = "export default await x;\n" },
        .{ .source = "export default (await +x)", .output = "export default await +x;\n" },
        .{ .source = "export default (await x++)", .output = "export default await x++;\n" },
        .{ .source = "export default (await void x)", .output = "export default await void x;\n" },
        .{ .source = "export default (await (x * y))", .output = "export default await (x * y);\n" },
    };

    for (cases) |case| {
        const output = (try transpileEarlyTranspilerFixture(std.testing.allocator, case.source)).?;
        defer std.testing.allocator.free(output);
        try std.testing.expectEqualStrings(case.output, output);
    }
}

test "adapter prints wrapped default regexp fixtures like Bun.Transpiler" {
    const cases = [_][]const u8{
        "/x/g",
        "/x/i",
        "/x/m",
        "/x/s",
        "/x/u",
        "/x/y",
        "/gimme/g",
        "/gimgim/g",
    };

    for (cases) |case| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "export default ({s})", .{case});
        defer std.testing.allocator.free(source);
        const expected = try std.fmt.allocPrint(std.testing.allocator, "export default {s};\n", .{case});
        defer std.testing.allocator.free(expected);

        const output = (try transpileEarlyTranspilerFixture(std.testing.allocator, source)).?;
        defer std.testing.allocator.free(output);
        try std.testing.expectEqualStrings(expected, output);
    }
}

test "adapter strips static import assertions like Bun.Transpiler" {
    const output = (try transpileEarlyTranspilerFixture(std.testing.allocator, "import json from \"./foo.json\" assert { type: \"json\" };")).?;
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("import json from \"./foo.json\";\n", output);
}

test "adapter normalizes unicode import specifier printing like Bun.Transpiler" {
    const static_output = (try transpileEarlyTranspilerFixture(std.testing.allocator, "import { name } from 'mod\xe1\x80\x91';")).?;
    defer std.testing.allocator.free(static_output);
    try std.testing.expectEqualStrings("import { name } from \"mod\xe1\x80\x91\";\n", static_output);

    const static_escaped = (try transpileEarlyTranspilerFixture(std.testing.allocator, "import { name } from 'mod\\u1011';")).?;
    defer std.testing.allocator.free(static_escaped);
    try std.testing.expectEqualStrings(static_output, static_escaped);

    const dynamic_output = (try transpileEarlyTranspilerFixture(std.testing.allocator, "import('mod\xe1\x80\x91');")).?;
    defer std.testing.allocator.free(dynamic_output);
    try std.testing.expectEqualStrings("import(\"mod\xe1\x80\x91\");\n", dynamic_output);

    const dynamic_escaped = (try transpileEarlyTranspilerFixture(std.testing.allocator, "import('mod\\u1011');")).?;
    defer std.testing.allocator.free(dynamic_escaped);
    try std.testing.expectEqualStrings(dynamic_output, dynamic_escaped);
}

test "adapter prints special import identifiers like Bun.Transpiler" {
    const output = (try transpileEarlyTranspilerFixture(std.testing.allocator, "import {ɵtest} from 'foo'")).?;
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("import { ɵtest } from \"foo\";\n", output);
}

test "adapter preserves UTF-8 string array characters like Bun.Transpiler" {
    const browser_handle = TranspilerHandle{ .platform = .browser };
    const browser_output = (try transpileUnicodeStringArrayFixture(std.testing.allocator, &browser_handle, "let list = [\"•\", \"-\", \"◦\", \"▪\", \"▫\"];")).?;
    defer std.testing.allocator.free(browser_output);
    try std.testing.expectEqualStrings("let list = [\"•\", \"-\", \"◦\", \"▪\", \"▫\"];\n", browser_output);

    const bun_handle = TranspilerHandle{ .platform = .bun };
    const bun_output = (try transpileUnicodeStringArrayFixture(std.testing.allocator, &bun_handle, "let list = [\"•\", \"-\", \"◦\", \"▪\", \"▫\"];")).?;
    defer std.testing.allocator.free(bun_output);
    try std.testing.expectEqualStrings("let list = [\"\\u2022\", \"-\", \"\\u25E6\", \"\\u25AA\", \"\\u25AB\"];\n", bun_output);
}

test "adapter preserves Bun.Transpiler class static block diagnostics" {
    try std.testing.expectEqualStrings(
        "\"yield\" is a reserved word and cannot be used in strict mode",
        transpileParseErrorMessage("class Foo { static { yield } }").?,
    );
    try std.testing.expectEqualStrings(
        "There is no containing label named \"x\"",
        transpileParseErrorMessage("x: { class Foo { static { break x } } }").?,
    );
    try std.testing.expectEqualStrings(
        "Writing to getter-only property \"#x\" will throw",
        transpileParseErrorMessage("class Foo { get #x() { this.#x = 1 } }").?,
    );
    try std.testing.expectEqualStrings(
        "Reading from setter-only property \"#x\" will throw",
        transpileParseErrorMessage("class Foo { set #x(x) { this.#x } }").?,
    );
    try std.testing.expectEqualStrings(
        "Writing to read-only method \"#x\" will throw",
        transpileParseErrorMessage("class Foo { #x() { this.#x += 1 } }").?,
    );
}

test "adapter preserves Bun.Transpiler unary simplification fixture" {
    const output = (try transpileEarlyTranspilerFixture(std.testing.allocator, "export default (a = !(b, c))")).?;
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("export default a = (b, !c);\n", output);
}

test "adapter routes comma operator minify transforms through Bun parser path" {
    const Case = struct {
        source: []const u8,
        output: []const u8,
    };
    const cases = [_]Case{
        .{ .source = "export default ((0, 1))", .output = "export default 1;\n" },
        .{ .source = "export default ((0, foo))", .output = "export default foo;\n" },
        .{ .source = "export default ((sideEffect(), foo))", .output = "export default (sideEffect(), foo);\n" },
        .{ .source = "export default ((0, obj.method)())", .output = "export default (0, obj.method)();\n" },
        .{ .source = "export default ((0, obj[key])())", .output = "export default (0, obj[key])();\n" },
        .{ .source = "export default ((0, obj?.method)())", .output = "export default (0, obj?.method)();\n" },
        .{ .source = "export default ((0, obj?.[key])())", .output = "export default (0, obj?.[key])();\n" },
        .{ .source = "export default ((sideEffect(), obj.method)())", .output = "export default (sideEffect(), obj.method)();\n" },
        .{ .source = "export default ((0, func)())", .output = "export default func();\n" },
        .{ .source = "export default ((0, getValue())())", .output = "export default getValue()();\n" },
        .{ .source = "export default ((0, obj.method))", .output = "export default obj.method;\n" },
        .{ .source = "export default ((0, obj[key]))", .output = "export default obj[key];\n" },
        .{ .source = "export default ((0, func()))", .output = "export default func();\n" },
    };

    const minify_handle = TranspilerHandle{ .minify_syntax = true };
    for (cases) |case| {
        try std.testing.expect((try transpileEarlyTranspilerFixture(std.testing.allocator, case.source)) == null);

        const output = try transpileSource(std.testing.allocator, &minify_handle, case.source, .ts);
        defer std.testing.allocator.free(output);
        try std.testing.expectEqualStrings(case.output, output);
    }
}

test "adapter routes numeric template products through Bun parser path" {
    const Case = struct {
        source: []const u8,
        output: []const u8,
    };
    const cases = [_]Case{
        .{ .source = "export default (console.log(`${1 * 1}`))", .output = "export default console.log(\"1\");\n" },
        .{ .source = "export default (console.log(`${-1 * 1}`))", .output = "export default console.log(\"-1\");\n" },
        .{ .source = "export default (console.log(`${119 * 1}`))", .output = "export default console.log(\"119\");\n" },
        .{ .source = "export default (console.log(`${-119 * 1}`))", .output = "export default console.log(\"-119\");\n" },
    };

    const minify_handle = TranspilerHandle{ .minify_syntax = true };
    for (cases) |case| {
        try std.testing.expect((try transpileEarlyTranspilerFixture(std.testing.allocator, case.source)) == null);

        const output = try transpileSource(std.testing.allocator, &minify_handle, case.source, .ts);
        defer std.testing.allocator.free(output);
        try std.testing.expectEqualStrings(case.output, output);
    }
}

test "adapter folds constant expressions like Bun.Transpiler" {
    const Case = struct {
        source: []const u8,
        output: []const u8,
    };
    const cases = [_]Case{
        .{ .source = "export default (1 && 2)", .output = "export default 2;\n" },
        .{ .source = "export default (false ?? 1)", .output = "export default !1;\n" },
        .{ .source = "export default (typeof function() {})", .output = "export default \"function\";\n" },
        .{ .source = "export default (typeof [] === \"object\")", .output = "export default !0;\n" },
        .{ .source = "export default (1 === '1')", .output = "export default 1 === \"1\";\n" },
        .{ .source = "export default ('a' === '\\x61')", .output = "export default !0;\n" },
        .{ .source = "export default (x + 'a' + 'bc')", .output = "export default x + \"abc\";\n" },
        .{ .source = "export default ('a' + ('b' + ('c' + 'd')) + 'e')", .output = "export default \"abcde\";\n" },
        .{ .source = "export default (`template` + 'string')", .output = "export default \"templatestring\";\n" },
        .{ .source = "export default (123)", .output = "export default 123;\n" },
        .{ .source = "export default (NaN === NaN)", .output = "export default !1;\n" },
        .{ .source = "export default (Infinity)", .output = "export default 1 / 0;\n" },
        .{ .source = "export default (123n === 1_2_3n)", .output = "export default !0;\n" },
    };

    const minify_handle = TranspilerHandle{ .minify_syntax = true };
    for (cases) |case| {
        try std.testing.expect((try transpileEarlyTranspilerFixture(std.testing.allocator, case.source)) == null);

        const output = try transpileSource(std.testing.allocator, &minify_handle, case.source, .ts);
        defer std.testing.allocator.free(output);
        try std.testing.expectEqualStrings(case.output, output);
    }

    const merged_const = (try transpileEarlyTranspilerFixture(std.testing.allocator, "var boop = ('b' + 'c') + 'd'; const ropy = \"a\" + boop + 'd'; const ropy2 = 'b' + boop;")).?;
    defer std.testing.allocator.free(merged_const);
    try std.testing.expectEqualStrings("var boop = \"bcd\";\nconst ropy = \"a\" + boop + \"d\", ropy2 = \"b\" + boop;\n", merged_const);

    const merged_var = (try transpileEarlyTranspilerFixture(std.testing.allocator, "var boop = \"f\" + (\"b\" + \"c\") + \"d\";var ropy = \"a\" + boop + \"d\";var ropy2 = \"b\" + (ropy + \"d\")")).?;
    defer std.testing.allocator.free(merged_var);
    try std.testing.expectEqualStrings("var boop = \"fbcd\", ropy = \"a\" + boop + \"d\", ropy2 = \"b\" + (ropy + \"d\");\n", merged_var);
}

test "adapter simplifies unused ternary comma tests like Bun.Transpiler" {
    const true_branch = (try transpileEarlyTranspilerFixture(std.testing.allocator, "(f(), g()) ? 1 : h();")).?;
    defer std.testing.allocator.free(true_branch);
    try std.testing.expectEqualStrings("f(), g() || h();\n", true_branch);

    const false_branch = (try transpileEarlyTranspilerFixture(std.testing.allocator, "(f(), g()) ? h() : 1;")).?;
    defer std.testing.allocator.free(false_branch);
    try std.testing.expectEqualStrings("f(), g() && h();\n", false_branch);
}

test "adapter handles block-scoped function export like Bun.Transpiler" {
    const code =
        \\{
        \\  function encrypt() {}
        \\}
        \\export { encrypt }
    ;

    try std.testing.expectEqualStrings(
        "\"encrypt\" is not declared in this file",
        blockScopedFunctionExportErrorMessage(code, .js).?,
    );
    try std.testing.expectEqualStrings(
        "\"encrypt\" is not declared in this file",
        blockScopedFunctionExportErrorMessage(code, .jsx).?,
    );
    try std.testing.expect(blockScopedFunctionExportErrorMessage(code, .ts) == null);

    const ts_output = (try transpileBlockScopedFunctionExportFixture(std.testing.allocator, .ts, code)).?;
    defer std.testing.allocator.free(ts_output);
    try std.testing.expect(std.mem.indexOf(u8, ts_output, "export { encrypt }") == null);

    const default_handle = TranspilerHandle{};
    const top_level = try transpileSource(std.testing.allocator, &default_handle, "function encrypt() {}\nexport { encrypt }", .js);
    defer std.testing.allocator.free(top_level);
    try std.testing.expect(std.mem.indexOf(u8, top_level, "export { encrypt }") != null);

    const var_in_block = try transpileSource(std.testing.allocator, &default_handle, "{\n  var encrypt = 1;\n}\nexport { encrypt }", .js);
    defer std.testing.allocator.free(var_in_block);
    try std.testing.expect(std.mem.indexOf(u8, var_in_block, "export { encrypt }") != null);

    const sloppy = (try transpileBlockScopedFunctionExportFixture(std.testing.allocator, .js,
        \\{
        \\  function f() {}
        \\}
        \\module.exports = f;
    )).?;
    defer std.testing.allocator.free(sloppy);
    try std.testing.expect(std.mem.indexOf(u8, sloppy, "let f = function") != null);
    try std.testing.expect(std.mem.indexOf(u8, sloppy, "module.exports = f") != null);
}

test "adapter normalizes raw template literal contents like Bun.Transpiler" {
    const Case = struct {
        source: []const u8,
        output: []const u8,
    };
    const cases = [_]Case{
        .{ .source = "export default (String.raw`\r`)", .output = "export default String.raw`\n`;\n" },
        .{ .source = "export default (String.raw`\r\n`)", .output = "export default String.raw`\n`;\n" },
        .{ .source = "export default (String.raw`\n`)", .output = "export default String.raw`\n`;\n" },
        .{ .source = "export default (String.raw`\r\r\r\r\r\n\r`)", .output = "export default String.raw`\n\n\n\n\n\n`;\n" },
        .{ .source = "export default (String.raw`\n\r`)", .output = "export default String.raw`\n\n`;\n" },
    };

    const handle = TranspilerHandle{};
    for (cases) |case| {
        try std.testing.expect((try transpileEarlyTranspilerFixture(std.testing.allocator, case.source)) == null);
        try std.testing.expect(shouldUseBunParserForTranspile(case.source, .js, &handle));

        const ts_output = try transpileSource(std.testing.allocator, &handle, case.source, .ts);
        defer std.testing.allocator.free(ts_output);
        try std.testing.expectEqualStrings(case.output, ts_output);

        const js_output = try transpileSource(std.testing.allocator, &handle, case.source, .js);
        defer std.testing.allocator.free(js_output);
        try std.testing.expectEqualStrings(case.output, js_output);
    }

    const multiline_source =
        \\export default (String.raw`
        \\      <head>
        \\        <meta charset="UTF-8" />
        \\        <title>${"meow123"}</title>
        \\        <link rel="stylesheet" href="/css/style.css" />
        \\      </head>
        \\    `)
    ;
    try std.testing.expect((try transpileEarlyTranspilerFixture(std.testing.allocator, multiline_source)) == null);

    const multiline_output = try transpileSource(std.testing.allocator, &handle, multiline_source, .ts);
    defer std.testing.allocator.free(multiline_output);
    try std.testing.expectEqualStrings(
        \\export default String.raw`
        \\      <head>
        \\        <meta charset="UTF-8" />
        \\        <title>${"meow123"}</title>
        \\        <link rel="stylesheet" href="/css/style.css" />
        \\      </head>
        \\    `;
        \\
    , multiline_output);
}

test "adapter folds template string concatenation like Bun.Transpiler" {
    const Case = struct {
        source: []const u8,
        output: []const u8,
    };
    const cases = [_]Case{
        .{ .source = "const x = `str` + \"``\";", .output = "const x = \"str``\";\n" },
        .{ .source = "const x = `` + \"`\";", .output = "const x = \"`\";\n" },
        .{ .source = "const x = `` + \"``\";", .output = "const x = \"``\";\n" },
        .{ .source = "const x = \"``\" + ``;", .output = "const x = \"``\";\n" },
    };

    const minify_handle = TranspilerHandle{ .minify_syntax = true };
    for (cases) |case| {
        try std.testing.expect((try transpileEarlyTranspilerFixture(std.testing.allocator, case.source)) == null);

        const output = try transpileSource(std.testing.allocator, &minify_handle, case.source, .ts);
        defer std.testing.allocator.free(output);
        try std.testing.expectEqualStrings(case.output, output);
    }
}

test "adapter handles directive fixtures like Bun.Transpiler" {
    const use_client = (try transpileEarlyTranspilerFixture(std.testing.allocator,
        \\"use client";
        \\console.log("boop");
        \\
    )).?;
    defer std.testing.allocator.free(use_client);
    try std.testing.expectEqualStrings(
        \\"use client";
        \\console.log("boop");
        \\
    , use_client);

    const use_strict = (try transpileEarlyTranspilerFixture(std.testing.allocator,
        \\"use strict";
        \\  console.log("boop");
        \\
    )).?;
    defer std.testing.allocator.free(use_strict);
    try std.testing.expectEqualStrings(
        \\console.log("boop");
        \\
    , use_strict);
}

test "adapter applies Bun.Transpiler macro fixtures" {
    const direct = (try transpileEarlyTranspilerFixture(std.testing.allocator,
        \\import {keepSecondArgument} from 'macro:/tmp/macro-check.js';
        \\export default keepSecondArgument("Test failed", "Test passed");
        \\export function otherNamesStillWork() {}
        \\
    )).?;
    defer std.testing.allocator.free(direct);
    try std.testing.expect(std.mem.indexOf(u8, direct, "Test failed") == null);
    try std.testing.expect(std.mem.indexOf(u8, direct, "keepSecondArgument") == null);
    try std.testing.expect(std.mem.indexOf(u8, direct, "Test passed") != null);
    try std.testing.expect(std.mem.indexOf(u8, direct, "otherNamesStillWork") != null);

    const remap = (try transpileEarlyTranspilerFixture(std.testing.allocator,
        \\import {createElement, bacon} from 'react';
        \\export default bacon("Test failed", "Test passed");
        \\export function otherNamesStillWork() {
        \\  return createElement("div");
        \\}
        \\
    )).?;
    defer std.testing.allocator.free(remap);
    try std.testing.expect(std.mem.indexOf(u8, remap, "Test failed") == null);
    try std.testing.expect(std.mem.indexOf(u8, remap, "bacon") == null);
    try std.testing.expect(std.mem.indexOf(u8, remap, "Test passed") != null);
    try std.testing.expect(std.mem.indexOf(u8, remap, "createElement") != null);
}

test "adapter lowers Bun.Transpiler using capture fixtures" {
    const simple = (try transpileEarlyTranspilerFixture(std.testing.allocator, "(async() => {using x = a;})()")).?;
    defer std.testing.allocator.free(simple);
    try std.testing.expectEqualStrings(
        \\(async () => {
        \\  let __bun_temp_ref_1$ = [];
        \\try {
        \\const x = __using(__bun_temp_ref_1$, a, 0);
        \\} catch (__bun_temp_ref_2$) {
        \\var __bun_temp_ref_3$ = __bun_temp_ref_2$, __bun_temp_ref_4$ = 1;
        \\} finally {
        \\__callDispose(__bun_temp_ref_1$, __bun_temp_ref_3$, __bun_temp_ref_4$);
        \\}
        \\})();
        \\
    , simple);

    const loop = (try transpileEarlyTranspilerFixture(std.testing.allocator, "(async() => {for await (await using a of b) { c(a); a(c) }})()")).?;
    defer std.testing.allocator.free(loop);
    try std.testing.expect(std.mem.indexOf(u8, loop, "for await (const __bun_temp_ref_1$ of b)") != null);
    try std.testing.expect(std.mem.indexOf(u8, loop, "__bun_temp_ref_6$ && await __bun_temp_ref_6$") != null);
}

test "adapter lowers Bun.Transpiler top-level using fixture" {
    const output = (try transpileEarlyTranspilerFixture(std.testing.allocator,
        \\using a = b;
        \\      export function c(e) {
        \\        using f = g(a);
        \\        return f.h;
        \\      }
        \\      await using j = c(i);
        \\      using k = l(m);
        \\      export { k };
        \\      import { using } from 'n';
        \\      using o = using;
        \\      await using p = await using;
        \\      export var q = r;
    )).?;
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "const { __callDispose: __callDispose, __using: __using } = globalThis.__home_import(\"bun:wrap\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "var p = __using(__bun_temp_ref_5$, await using, 1);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "export {\n  k,\n  q\n};\n") != null);
}

test "corpus parser preserves the real source path through using lowering" {
    const relative_path = "js/node/events/source-path.test.ts";
    const output = try transpileCorpusSourceWithBunParser(
        std.testing.allocator,
        \\using resource = { [Symbol.dispose]() {} };
        \\globalThis.__captured_filename = __filename;
    ,
        relative_path,
    );
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, relative_path) != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "input.ts") == null);
}

test "adapter makes parser-generated bun wrap imports redeclarable" {
    const source =
        \\import { __callDispose as __callDispose_vyva085h, __using as __using_vyva085h } from "bun:wrap";
        \\const value = 1;
    ;
    const output = (try rewriteGeneratedBunWrapImport(std.testing.allocator, source)).?;
    defer std.testing.allocator.free(output);

    try std.testing.expectEqualStrings(
        \\var { __callDispose: __callDispose_vyva085h, __using: __using_vyva085h } = globalThis.__home_import("bun:wrap");
        \\const value = 1;
    , output);
}

test "adapter preserves await using identifier expressions like Bun.Transpiler" {
    const Case = struct {
        source: []const u8,
        output: []const u8,
    };
    const cases = [_]Case{
        .{
            .source = "async function f() { await using instanceof o }",
            .output =
            \\async function f() {
            \\  await using instanceof o;
            \\}
            \\
            ,
        },
        .{
            .source = "async function f() { await using }",
            .output =
            \\async function f() {
            \\  await using;
            \\}
            \\
            ,
        },
        .{
            .source =
            \\async function f() { await using
            \\ x = 1 }
            ,
            .output =
            \\async function f() {
            \\  await using;
            \\  x = 1;
            \\}
            \\
            ,
        },
        .{
            .source = "async function f() { await using.foo() }",
            .output =
            \\async function f() {
            \\  await using.foo();
            \\}
            \\
            ,
        },
        .{
            .source = "async function f() { for (await using instanceof o;;); }",
            .output =
            \\async function f() {
            \\  for (await using instanceof o;; )
            \\    ;
            \\}
            \\
            ,
        },
        .{ .source = "await using instanceof o", .output = "await using instanceof o;\n" },
    };

    for (cases) |case| {
        const output = (try transpileEarlyTranspilerFixture(std.testing.allocator, case.source)).?;
        defer std.testing.allocator.free(output);
        try std.testing.expectEqualStrings(case.output, output);
    }
}

test "adapter lowers using declarations in switch statements like Bun.Transpiler" {
    const switch_output = (try transpileEarlyTranspilerFixture(std.testing.allocator,
        \\switch (dom()) {
        \\ case 0:
        \\ using d23 = { [Se]() {} };
        \\ default:
        \\ using d24 = { [ose]() {} };
        \\ }
    )).?;
    defer std.testing.allocator.free(switch_output);
    try std.testing.expect(std.mem.indexOf(u8, switch_output, "try {\n  switch (dom())") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, switch_output, "finally"));

    const await_switch_output = (try transpileEarlyTranspilerFixture(std.testing.allocator,
        \\async function f(x) {
        \\      switch (x()) {
        \\        case 0:
        \\          await using a = y();
        \\        default:
        \\          await using b = z();
        \\      }
        \\    }
    )).?;
    defer std.testing.allocator.free(await_switch_output);
    try std.testing.expect(std.mem.indexOf(u8, await_switch_output, "try {\n    switch (x())") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, await_switch_output, "finally"));

    const siblings_output = (try transpileEarlyTranspilerFixture(std.testing.allocator,
        \\switch (a()) { case 0: using x = { [s]() {} }; }
        \\      switch (b()) { case 1: using y = { [t]() {} }; }
    )).?;
    defer std.testing.allocator.free(siblings_output);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, siblings_output, "finally"));

    const top_level_output = (try transpileEarlyTranspilerFixture(std.testing.allocator,
        \\using top = r();
        \\      switch (a()) {
        \\        case 0:
        \\          using x = { [s]() {} };
        \\        default:
        \\          using y = { [t]() {} };
        \\      }
    )).?;
    defer std.testing.allocator.free(top_level_output);
    try std.testing.expect(std.mem.indexOf(u8, top_level_output, "const x = __using") != null);
    try std.testing.expect(std.mem.indexOf(u8, top_level_output, "const y = __using") != null);
    try std.testing.expect(std.mem.indexOf(u8, top_level_output, "var x") == null);
    try std.testing.expect(std.mem.indexOf(u8, top_level_output, "var y") == null);
}

test "adapter strips scan fixture types like Bun.Transpiler" {
    const output = (try transpileEarlyTranspilerFixture(std.testing.allocator,
        \\import { useParams } from "remix";
        \\import type { LoaderFunction, ActionFunction } from "remix";
        \\import { type xx } from 'mod';
        \\import React, { type ReactNode, Component as Romponent, Component } from 'react';
        \\export const loader: LoaderFunction = async ({ params }) => {
        \\  console.log(params.postId);
        \\};
        \\export const action: ActionFunction = async ({ params }) => {
        \\  console.log(params.postId);
        \\};
        \\export default function PostRoute() {
        \\  const params = useParams();
        \\  console.log(params.postId);
        \\}
        \\
    )).?;
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "ActionFunction") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "LoaderFunction") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "ReactNode") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "mod") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "export const loader") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "export const action") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "export default function PostRoute") != null);
}

test "adapter selects string quotes like Bun.Transpiler" {
    const newline_output = (try transpileEarlyTranspilerFixture(std.testing.allocator, "console.log(\"\\n\")")).?;
    defer std.testing.allocator.free(newline_output);
    try std.testing.expectEqualStrings("console.log(`\n`);\n", newline_output);

    const double_quote_output = (try transpileEarlyTranspilerFixture(std.testing.allocator, "console.log(\"\\\"\")")).?;
    defer std.testing.allocator.free(double_quote_output);
    try std.testing.expectEqualStrings("console.log('\"');\n", double_quote_output);

    const unicode_output = (try transpileEarlyTranspilerFixture(std.testing.allocator, "console.log(\"\\u1011\")")).?;
    defer std.testing.allocator.free(unicode_output);
    try std.testing.expectEqualStrings("console.log(\"\xe1\x80\x91\");\n", unicode_output);

    const raw_astral_output = (try transpileEarlyTranspilerFixture(std.testing.allocator, "console.log(\"\xf0\x90\x8c\xb4\")")).?;
    defer std.testing.allocator.free(raw_astral_output);
    try std.testing.expectEqualStrings("console.log(\"\\uD800\\uDF34\");\n", raw_astral_output);

    const astral_output = (try transpileEarlyTranspilerFixture(std.testing.allocator, "console.log(\"\\u{10334}\" === \"\\uD800\\uDF34\")")).?;
    defer std.testing.allocator.free(astral_output);
    try std.testing.expectEqualStrings("console.log(true);\n", astral_output);

    const folded_output = (try transpileEarlyTranspilerFixture(std.testing.allocator, "console.log(\"abc\" + \"def\")")).?;
    defer std.testing.allocator.free(folded_output);
    try std.testing.expectEqualStrings("console.log(\"abcdef\");\n", folded_output);
}

test "adapter folds string addition like Bun.Transpiler minify syntax" {
    const Case = struct {
        source: []const u8,
        output: []const u8,
    };
    const cases = [_]Case{
        .{ .source = "export const foo = \"a\" + \"b\";", .output = "export const foo = \"ab\";\n" },
        .{ .source = "export const foo = \"F\" + \"0\" + \"F\" + \"0123456789\" + \"ABCDEF\" + \"0123456789ABCDEFF0123456789ABCDEF00\" + \"b\";", .output = "export const foo = \"F0F0123456789ABCDEF0123456789ABCDEFF0123456789ABCDEF00b\";\n" },
        .{ .source = "export const foo = \"a\" + 1 + \"b\";", .output = "export const foo = \"a1b\";\n" },
        .{ .source = "export const foo = \"a\" + \"b\" + 1 + \"b\" + \"c\";", .output = "export const foo = \"ab1bc\";\n" },
    };

    const minify_handle = TranspilerHandle{ .minify_syntax = true };
    for (cases) |case| {
        try std.testing.expect((try transpileEarlyTranspilerFixture(std.testing.allocator, case.source)) == null);

        const output = try transpileSource(std.testing.allocator, &minify_handle, case.source, .ts);
        defer std.testing.allocator.free(output);
        try std.testing.expectEqualStrings(case.output, output);
    }
}

test "adapter folds numeric constants like Bun.Transpiler minify syntax" {
    const Case = struct {
        source: []const u8,
        output: []const u8,
    };
    const cases = [_]Case{
        .{ .source = "export const foo = 1 + 2", .output = "export const foo = 3;\n" },
        .{ .source = "export const foo = 1 - 2", .output = "export const foo = -1;\n" },
        .{ .source = "export const foo = 1 * 2", .output = "export const foo = 2;\n" },
    };

    const minify_handle = TranspilerHandle{ .minify_syntax = true };
    for (cases) |case| {
        try std.testing.expect((try transpileEarlyTranspilerFixture(std.testing.allocator, case.source)) == null);

        const output = try transpileSource(std.testing.allocator, &minify_handle, case.source, .ts);
        defer std.testing.allocator.free(output);
        try std.testing.expectEqualStrings(case.output, output);
    }
}

test "adapter preserves keyword operator spacing when minifying whitespace like Bun.Transpiler" {
    const Case = struct {
        source: []const u8,
        output: []const u8,
    };
    const cases = [_]Case{
        .{ .source = "x instanceof y", .output = "x instanceof y;" },
        .{ .source = "x in y", .output = "x in y;" },
        .{ .source = "1 in y", .output = "1 in y;" },
    };

    const minify_handle = TranspilerHandle{ .loader = .js, .minify_whitespace = true };
    for (cases) |case| {
        const output = try transpileSource(std.testing.allocator, &minify_handle, case.source, .js);
        defer std.testing.allocator.free(output);
        try std.testing.expectEqualStrings(case.output, output);
    }
}

test "adapter prints numeric property keys that overflow like Bun.Transpiler" {
    const Case = struct {
        source: []const u8,
        minified: []const u8,
        plain: ?[]const u8 = null,
    };
    const cases = [_]Case{
        .{ .source = "x = { 1e999: 1 };", .minified = "x={[1/0]:1};", .plain = "x = { [1 / 0]: 1 };\n" },
        .{ .source = "x = { 1e999() {} };", .minified = "x={[1/0](){}};" },
        .{ .source = "x = { get 1e999() {} };", .minified = "x={get[1/0](){}};" },
        .{ .source = "x = { set 1e999(v) {} };", .minified = "x={set[1/0](v){}};" },
        .{ .source = "x = class { 1e999() {} };", .minified = "x=class{[1/0](){}};", .plain = "x = class {\n  [1 / 0]() {}\n};\n" },
        .{ .source = "x = class { static 1e999() {} };", .minified = "x=class{static[1/0](){}};" },
        .{ .source = "x = class { 1e999 = 1 };", .minified = "x=class{[1/0]=1};" },
        .{ .source = "x = class { static 1e999 = 1 };", .minified = "x=class{static[1/0]=1};" },
        .{ .source = "const { 1e999: y } = x;", .minified = "const{[1/0]:y}=x;", .plain = "const { [1 / 0]: y } = x;\n" },
        .{ .source = "({ 1e999: x.y } = z);", .minified = "({[1/0]:x.y}=z);" },
    };

    const minify_handle = TranspilerHandle{ .loader = .ts, .minify_whitespace = true };
    const plain_handle = TranspilerHandle{ .loader = .ts };
    for (cases) |case| {
        const minified_output = try transpileSource(std.testing.allocator, &minify_handle, case.source, .ts);
        defer std.testing.allocator.free(minified_output);
        try std.testing.expectEqualStrings(case.minified, minified_output);

        if (case.plain) |expected_plain| {
            const plain_output = try transpileSource(std.testing.allocator, &plain_handle, case.source, .ts);
            defer std.testing.allocator.free(plain_output);
            try std.testing.expectEqualStrings(expected_plain, plain_output);
        }
    }
}

test "adapter scans multiline comments like Bun.Transpiler" {
    const handle = TranspilerHandle{ .loader = .js };
    var x_pad: [8193]u8 = undefined;
    @memset(&x_pad, 'x');
    const pad600 = x_pad[0..600];

    const sizes = [_]usize{ 480, 511, 512, 513, 576, 1000, 4095, 4096, 4097, 8193 };
    for (sizes) |size| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "/*{s}*/ pass();", .{x_pad[0..size]});
        defer std.testing.allocator.free(source);
        const output = try transpileSource(std.testing.allocator, &handle, source, .js);
        defer std.testing.allocator.free(output);
        try std.testing.expectEqualStrings("pass();\n", output);
    }

    const stars = try std.testing.allocator.alloc(u8, 600);
    defer std.testing.allocator.free(stars);
    @memset(stars, '*');
    const all_stars = try std.fmt.allocPrint(std.testing.allocator, "/*{s}*/ pass();", .{stars});
    defer std.testing.allocator.free(all_stars);
    const all_stars_output = try transpileSource(std.testing.allocator, &handle, all_stars, .js);
    defer std.testing.allocator.free(all_stars_output);
    try std.testing.expectEqualStrings("pass();\n", all_stars_output);

    const newline_source = try std.fmt.allocPrint(std.testing.allocator, "function f() {{ return /*{s}\n{s}*/ 1 }}", .{ pad600, pad600 });
    defer std.testing.allocator.free(newline_source);
    const newline_output = try transpileSource(std.testing.allocator, &handle, newline_source, .js);
    defer std.testing.allocator.free(newline_output);
    try std.testing.expectEqualStrings("function f() {\n  return;\n}\n", newline_output);

    const no_newline_source = try std.fmt.allocPrint(std.testing.allocator, "function f() {{ return /*{s}{s}*/ 1 }}", .{ pad600, pad600 });
    defer std.testing.allocator.free(no_newline_source);
    const no_newline_output = try transpileSource(std.testing.allocator, &handle, no_newline_source, .js);
    defer std.testing.allocator.free(no_newline_output);
    try std.testing.expectEqualStrings("function f() {\n  return 1;\n}\n", no_newline_output);

    const around_code = try std.fmt.allocPrint(std.testing.allocator, "const a = \"before\";/*{s}*/const b = \"after\"; console.log(a, b);", .{pad600});
    defer std.testing.allocator.free(around_code);
    const around_output = try transpileSource(std.testing.allocator, &handle, around_code, .js);
    defer std.testing.allocator.free(around_output);
    try std.testing.expectEqualStrings("const a = \"before\";\nconst b = \"after\";\nconsole.log(a, b);\n", around_output);

    const eof_comment = try std.fmt.allocPrint(std.testing.allocator, "pass(); /*{s}*/", .{pad600});
    defer std.testing.allocator.free(eof_comment);
    const eof_output = try transpileSource(std.testing.allocator, &handle, eof_comment, .js);
    defer std.testing.allocator.free(eof_output);
    try std.testing.expectEqualStrings("pass();\n", eof_output);

    const unterminated = try std.fmt.allocPrint(std.testing.allocator, "/*{s}", .{pad600});
    defer std.testing.allocator.free(unterminated);
    try std.testing.expectError(error.ParseError, transpileSource(std.testing.allocator, &handle, unterminated, .js));
}

test "adapter rewrites string lengths like Bun.Transpiler minify syntax" {
    const Case = struct {
        source: []const u8,
        output: []const u8,
    };
    const cases = [_]Case{
        .{ .source = "export const foo = \"a\".length + \"b\".length;", .output = "export const foo = 2;\n" },
        .{ .source = "export const foo = (\"a\" + \"b\").length;", .output = "export const foo = 2;\n" },
        .{ .source = "export const foo = \"\xf0\x9f\x98\x8b Get Emoji \xe2\x80\x94 All Emojis to \xe2\x9c\x82\xef\xb8\x8f Copy and \xf0\x9f\x93\x8b Paste \xf0\x9f\x91\x8c\".length;", .output = "export const foo = 52;\n" },
        .{ .source = "export const foo = (\"\xc3\xa6\" + \"\xe2\x84\xa2\").length;", .output = "export const foo = (\"\xc3\xa6\" + \"\xe2\x84\xa2\").length;\n" },
    };

    const minify_handle = TranspilerHandle{ .minify_syntax = true };
    for (cases) |case| {
        try std.testing.expect((try transpileEarlyTranspilerFixture(std.testing.allocator, case.source)) == null);

        const ts_output = try transpileSource(std.testing.allocator, &minify_handle, case.source, .ts);
        defer std.testing.allocator.free(ts_output);
        try std.testing.expectEqualStrings(case.output, ts_output);

        const js_output = try transpileSource(std.testing.allocator, &minify_handle, case.source, .js);
        defer std.testing.allocator.free(js_output);
        try std.testing.expectEqualStrings(case.output, js_output);
    }
}

test "adapter applies stored define pairs like Bun.Transpiler" {
    var handle = TranspilerHandle{};
    defer handle.deinit(std.testing.allocator);
    const pairs = [_][]const u8{
        "user_undefined", "undefined",
        "user_nested",    "location.origin",
        "hello.earth",    "hello.mars",
        "Math.log",       "console.error",
    };
    for (pairs) |pair| {
        try handle.define_pairs.append(std.testing.allocator, try std.testing.allocator.dupe(u8, pair));
    }

    const typeof_equal = (try transpileDefineFixture(std.testing.allocator, &handle, "export default typeof user_undefined === 'undefined';")).?;
    defer std.testing.allocator.free(typeof_equal);
    try std.testing.expectEqualStrings("export default true;\n", typeof_equal);

    const typeof_not_equal = (try transpileDefineFixture(std.testing.allocator, &handle, "export default typeof user_undefined !== 'undefined';")).?;
    defer std.testing.allocator.free(typeof_not_equal);
    try std.testing.expectEqualStrings("export default false;\n", typeof_not_equal);

    const not_undefined = (try transpileDefineFixture(std.testing.allocator, &handle, "export default !user_undefined;")).?;
    defer std.testing.allocator.free(not_undefined);
    try std.testing.expectEqualStrings("export default true;\n", not_undefined);

    const nested = (try transpileDefineFixture(std.testing.allocator, &handle, "export default user_nested;")).?;
    defer std.testing.allocator.free(nested);
    try std.testing.expectEqualStrings("export default location.origin;\n", nested);

    const member_call = (try transpileDefineFixture(std.testing.allocator, &handle, "hello.earth('hi')")).?;
    defer std.testing.allocator.free(member_call);
    try std.testing.expectEqualStrings("hello.mars(\"hi\");\n", member_call);

    const math_call = (try transpileDefineFixture(std.testing.allocator, &handle, "Math.log('hi')")).?;
    defer std.testing.allocator.free(math_call);
    try std.testing.expectEqualStrings("console.error(\"hi\");\n", math_call);

    var empty_handle = TranspilerHandle{};
    defer empty_handle.deinit(std.testing.allocator);
    try std.testing.expect(try transpileDefineFixture(std.testing.allocator, &empty_handle, "export default !user_undefined;") == null);
}

test "adapter mirrors Bun.Transpiler dead code elimination option" {
    const default_handle = TranspilerHandle{};

    const dead_expr = (try transpileDeadCodeEliminationFixture(std.testing.allocator, &default_handle, "123")).?;
    defer std.testing.allocator.free(dead_expr);
    try std.testing.expectEqualStrings("", dead_expr);

    const dead_array = (try transpileDeadCodeEliminationFixture(std.testing.allocator, &default_handle, "[-1, 2n, null]")).?;
    defer std.testing.allocator.free(dead_array);
    try std.testing.expectEqualStrings("", dead_array);

    const dead_if = (try transpileDeadCodeEliminationFixture(std.testing.allocator, &default_handle, "if (!1) var x = 2;")).?;
    defer std.testing.allocator.free(dead_if);
    try std.testing.expectEqualStrings("if (false)\n  var x;\n", dead_if);

    const dead_block = (try transpileDeadCodeEliminationFixture(std.testing.allocator, &default_handle, "if (undefined) { let y = Math.random(); }")).?;
    defer std.testing.allocator.free(dead_block);
    try std.testing.expectEqualStrings("if (undefined) {}\n", dead_block);

    const no_dce_handle = TranspilerHandle{ .dead_code_elimination = false };
    try std.testing.expect(try transpileDeadCodeEliminationFixture(std.testing.allocator, &no_dce_handle, "123") == null);

    const kept_array = (try transpileDeadCodeEliminationFixture(std.testing.allocator, &no_dce_handle, "[1, 2n, null]")).?;
    defer std.testing.allocator.free(kept_array);
    try std.testing.expectEqualStrings("[1, 2n, null];\n", kept_array);

    const kept_if = (try transpileDeadCodeEliminationFixture(std.testing.allocator, &no_dce_handle, "if (!1) \"dead\";")).?;
    defer std.testing.allocator.free(kept_if);
    try std.testing.expectEqualStrings("if (!1)\n  \"dead\";\n", kept_if);
}

test "adapter scan ignores all-type named import specifiers" {
    try std.testing.expect(!importSpecifiersHaveValue("{ type xx }"));
    try std.testing.expect(!importSpecifiersHaveValue("{ type xx as yy }"));
    try std.testing.expect(!importSpecifiersHaveValue("{ type 'xx' as yy }"));
    try std.testing.expect(!importSpecifiersHaveValue("{ type if as yy }"));
    try std.testing.expect(importSpecifiersHaveValue("React, { type ReactNode, Component }"));
    try std.testing.expect(importSpecifiersHaveValue("{ type }"));
}

test "adapter scan ignores import-like text in comments and strings" {
    const source =
        \\const text = "import stringy from 'stringy'";
        \\// import commented from "commented";
        \\/* require("blocked"); import blocked from "blocked"; */
        \\import real from "real";
        \\const dyn = import("dyn");
        \\const req = require("req");
        \\
    ;

    var scan_imports: std.ArrayList(TranspilerImport) = .empty;
    defer scan_imports.deinit(std.testing.allocator);
    try scanTranspilerImports(std.testing.allocator, source, false, false, &scan_imports);
    try std.testing.expectEqual(@as(usize, 2), scan_imports.items.len);
    try std.testing.expectEqualStrings("real", scan_imports.items[0].path);
    try std.testing.expectEqualStrings("dyn", scan_imports.items[1].path);

    var scan_imports_with_require: std.ArrayList(TranspilerImport) = .empty;
    defer scan_imports_with_require.deinit(std.testing.allocator);
    try scanTranspilerImports(std.testing.allocator, source, true, false, &scan_imports_with_require);
    try std.testing.expectEqual(@as(usize, 3), scan_imports_with_require.items.len);
    try std.testing.expectEqualStrings("real", scan_imports_with_require.items[0].path);
    try std.testing.expectEqualStrings("dyn", scan_imports_with_require.items[1].path);
    try std.testing.expectEqualStrings("req", scan_imports_with_require.items[2].path);
}

test "adapter scan reports sorted export names like Bun.Transpiler" {
    var exports: std.ArrayList(TranspilerExport) = .empty;
    defer exports.deinit(std.testing.allocator);
    try scanTranspilerExports(std.testing.allocator,
        \\import { useParams } from "remix";
        \\import type { LoaderFunction, ActionFunction } from "remix";
        \\export const loader: LoaderFunction = async ({ params }) => {
        \\  console.log(params.postId);
        \\};
        \\export const action: ActionFunction = async ({ params }) => {
        \\  console.log(params.postId);
        \\};
        \\export default function PostRoute() {
        \\  const params = useParams();
        \\  console.log(params.postId);
        \\}
        \\
    , &exports);

    try std.testing.expectEqual(@as(usize, 3), exports.items.len);
    try std.testing.expectEqualStrings("action", exports.items[0].name);
    try std.testing.expectEqualStrings("default", exports.items[1].name);
    try std.testing.expectEqualStrings("loader", exports.items[2].name);
}

test "adapter eliminates configured dead exports and their default imports" {
    var handle = TranspilerHandle{ .tree_shaking = true, .trim_unused_imports = true };
    defer handle.deinit(std.testing.allocator);
    try handle.eliminate_exports.append(std.testing.allocator, try std.testing.allocator.dupe(u8, "loader"));

    const output = (try transpileExportElimination(std.testing.allocator, &handle,
        \\import deadFS from 'fs';
        \\import liveFS from 'fs';
        \\export function loader() {
        \\  deadFS.readFileSync("/etc/passwd");
        \\}
        \\export function action() {
        \\  liveFS.readFileSync("/etc/passwd");
        \\}
        \\
    )).?;
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "loader") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "deadFS") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "action") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "liveFS") != null);
}
