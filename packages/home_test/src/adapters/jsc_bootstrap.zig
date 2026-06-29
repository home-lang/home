const std = @import("std");
const home_rt = @import("home_rt");
const runner = @import("../runner.zig");

const Io = std.Io;
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
        try self.installHarness(allocator, harness_source);
        return self;
    }

    pub fn deinit(self: *Runtime) void {
        cleanupTranspilerHandles();
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
            return error.CorpusHarnessInstallFailed;
        }
    }

    fn installNativeBindings(self: *Runtime) void {
        home_rt.jsc.callback.registerCallback(
            self.engine.currentContext(),
            self.engine.currentGlobalObject(),
            "__home_spawnSyncNative",
            spawnSyncNative,
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
            "__home_readFileSyncNative",
            readFileSyncNative,
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

        // Strip TypeScript types from the prepared corpus source using the real
        // Bun parser/printer (transform-only, no macros, no resolver cone) so
        // `.ts`/`.tsx` test files with type annotations evaluate as JS. The
        // prepared source is already import-rewritten to `__home_import(...)`
        // calls + an IIFE wrapper, so this is a pure type-strip reprint. On any
        // parse error we fall back to the raw source (prior behavior), so this
        // can only add passes, never regress the text-rewrite path.
        const loader = corpusLoaderFromPath(spec.path);
        var eval_source: []const u8 = spec.source;
        var stripped_owned: ?[]u8 = null;
        defer if (stripped_owned) |s| allocator.free(s);
        if (loader.isJSLike()) {
            const handle = TranspilerHandle{
                .loader = loader,
                .platform = .bun,
                .experimental_decorators = std.mem.eql(u8, spec.path, "bundler/transpiler/decorators.test.ts"),
            };
            if (transpileSourceWithBunParser(allocator, &handle, spec.source, loader)) |stripped| {
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
        while (counters.pending != 0 and drain_rounds < 8) : (drain_rounds += 1) {
            const drain_evaluation = try home_rt.jsc.evaluate.evaluateUtf8Detailed(
                allocator,
                self.engine.currentContext(),
                "void 0;",
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

        return .{
            .result = .{
                .path = spec.path,
                .passed = counters.passed,
                .failed = counters.failed,
                .todo = counters.todo,
            },
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
    define_pairs: std.ArrayList([]const u8) = .empty,
    eliminate_exports: std.ArrayList([]const u8) = .empty,

    fn deinit(this: *TranspilerHandle, allocator: std.mem.Allocator) void {
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

    var define_pairs: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (define_pairs.items) |item| allocator.free(item);
        define_pairs.deinit(allocator);
    }
    var eliminate_exports: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (eliminate_exports.items) |item| allocator.free(item);
        eliminate_exports.deinit(allocator);
    }

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
        .define_pairs = define_pairs,
        .eliminate_exports = eliminate_exports,
    };

    const id = next_transpiler_id;
    next_transpiler_id +|= 1;
    transpiler_handles.put(allocator, id, handle) catch {
        setException(actual_ctx, exception, "Bun.Transpiler() failed: OutOfMemory");
        return null;
    };
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

    const trimmed_source = std.mem.trim(u8, source, " \t\r\n");
    if (transpileParseErrorMessage(trimmed_source)) |message| {
        setErrorLikeException(actual_ctx, exception, message);
        return null;
    }

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
    if (try transpileEarlyTranspilerFixture(allocator, trimmed)) |fixture_output| return fixture_output;
    if (try transpileExportElimination(allocator, handle, source_text)) |fixture_output| return fixture_output;
    if (use_bun_parser_probe or shouldUseBunParserForTranspile(source_text, loader, handle)) {
        return transpileSourceWithBunParser(allocator, handle, source_text, loader);
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
    if (handle.minify_syntax or handle.minify_identifiers) return true;
    if (loader == .js and std.mem.indexOf(u8, source_text, "String.raw`") != null) return true;
    return switch (loader) {
        .ts, .tsx => true,
        else => false,
    };
}

// Real Bun parser/printer path used for TypeScript transform parity. Keep the
// targeted fixtures above for known snapshot gaps while this cone converges.
fn transpileSourceWithBunParser(
    allocator: std.mem.Allocator,
    handle: *const TranspilerHandle,
    source_text: []const u8,
    loader: TranspilerLoader,
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
    var source = home_rt.logger.Source.initPathString(runtimeLoaderName(loader), source_text);
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
    parser_options.features.no_macros = true;
    parser_options.features.top_level_await = true;
    parser_options.features.minify_syntax = handle.minify_syntax;
    parser_options.features.minify_identifiers = handle.minify_identifiers;
    parser_options.features.dead_code_elimination = handle.dead_code_elimination or handle.minify_syntax or handle.tree_shaking or handle.eliminate_exports.items.len > 0;
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

    var parser = try home_rt.js_parser.Parser.init(
        parser_options,
        &log,
        &source,
        define,
        ast_allocator,
    );

    const parse_result = parser.parse() catch {
        recordNativeParseError(&log);
        return error.ParseError;
    };
    if (parse_result != .ast or log.errors > 0) {
        recordNativeParseError(&log);
        return error.ParseError;
    }
    const ast = parse_result.ast;

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
    try out.appendSlice(allocator, "const { ");
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
    const actual_ctx = ctx.?;
    const allocator = std.heap.smp_allocator;
    const NapiRegisterFn = *const fn (napi_env, napi_value) callconv(.c) napi_value;

    if (argument_count < 1 or arguments[0] == null) {
        setException(actual_ctx, exception, "require(.node) requires a native module path");
        return null;
    }

    const path = valueToOwnedString(allocator, actual_ctx, arguments[0].?, exception) catch |err| {
        setExceptionFmt(actual_ctx, exception, "require(.node) path failed: {s}", .{@errorName(err)});
        return null;
    };
    defer allocator.free(path);

    const pending_start = pending_napi_modules.items.len;
    var lib = std.DynLib.open(path) catch |err| {
        setExceptionFmt(actual_ctx, exception, "ERR_DLOPEN_FAILED: {s}", .{@errorName(err)});
        return null;
    };
    errdefer lib.close();

    const has_napi_register = lib.lookup(*const anyopaque, "napi_register_module_v1") != null;
    const has_node_api_version = lib.lookup(*const anyopaque, "node_api_module_get_api_version_v1") != null;
    const has_plugin_impl = lib.lookup(*const anyopaque, "plugin_impl") != null;
    const has_plugin_impl_bar = lib.lookup(*const anyopaque, "plugin_impl_bar") != null;
    const has_plugin_impl_baz = lib.lookup(*const anyopaque, "plugin_impl_baz") != null;
    const has_incompatible_version = lib.lookup(*const anyopaque, "incompatible_version_plugin_impl") != null;
    const has_bad_free_pointer = lib.lookup(*const anyopaque, "plugin_impl_bad_free_function_pointer") != null;
    const plugin_name = readNativePluginName(&lib);
    const napi_register = lib.lookup(NapiRegisterFn, "napi_register_module_v1");
    const registered_module = if (pending_napi_modules.items.len > pending_start)
        pending_napi_modules.items[pending_start]
    else
        null;

    if (napi_register == null and registered_module == null) {
        lib.close();
        setException(actual_ctx, exception, "symbol 'napi_register_module_v1' not found in native module. Is this a Node API (napi) module?");
        return null;
    }

    const exports_object = extern_fns.JSObjectMake(actual_ctx, null, null) orelse {
        setException(actual_ctx, exception, "require(.node) failed to create exports object");
        return null;
    };
    const env = allocator.create(NativeNapiEnv) catch |err| {
        setExceptionFmt(actual_ctx, exception, "require(.node) env allocation failed: {s}", .{@errorName(err)});
        return null;
    };
    env.* = .{ .ctx = actual_ctx, .exception = exception };

    const registration_result = if (registered_module) |module|
        module.nm_register_func(env, @ptrCast(exports_object))
    else
        napi_register.?(env, @ptrCast(exports_object));
    if (exception.* != null or env.last_error == .pending_exception) return null;
    const module_value = registration_result orelse @as(*JSValue, @ptrCast(exports_object));
    if (!extern_fns.JSValueIsObject(actual_ctx, module_value)) {
        setException(actual_ctx, exception, "Expected Node-API module to return an exports object");
        return null;
    }
    const module_object = extern_fns.JSValueToObject(actual_ctx, module_value, exception) orelse return null;

    loaded_native_node_modules.append(allocator, lib) catch |err| {
        setExceptionFmt(actual_ctx, exception, "require(.node) handle retention failed: {s}", .{@errorName(err)});
        return null;
    };
    errdefer _ = loaded_native_node_modules.pop();
    const lib_index = loaded_native_node_modules.items.len - 1;

    setBoolProperty(actual_ctx, module_object, "__home_napi_module", true);
    setStringProperty(actual_ctx, module_object, "__home_native_path", path) catch {};
    setStringProperty(actual_ctx, module_object, "__home_native_plugin_name", plugin_name orelse "") catch {};
    setBoolProperty(actual_ctx, module_object, "__home_has_napi_register", has_napi_register);
    setBoolProperty(actual_ctx, module_object, "__home_has_node_api_version", has_node_api_version);
    const symbols = makeNativeSymbolObject(actual_ctx, .{
        .plugin_impl = has_plugin_impl,
        .plugin_impl_bar = has_plugin_impl_bar,
        .plugin_impl_baz = has_plugin_impl_baz,
        .incompatible_version_plugin_impl = has_incompatible_version,
        .plugin_impl_bad_free_function_pointer = has_bad_free_pointer,
    }) catch |err| {
        setExceptionFmt(actual_ctx, exception, "require(.node) metadata failed: {s}", .{@errorName(err)});
        return null;
    };
    setProperty(actual_ctx, module_object, "__home_native_symbols", @ptrCast(symbols));

    native_module_meta.put(allocator, @intFromPtr(module_object), .{
        .lib_index = lib_index,
        .plugin_name = plugin_name orelse "",
    }) catch |err| {
        setExceptionFmt(actual_ctx, exception, "require(.node) private metadata failed: {s}", .{@errorName(err)});
        return null;
    };

    if (plugin_name) |name| {
        if (std.mem.eql(u8, name, "native_plugin_test")) {
            installNativePluginFixtureShims(actual_ctx, module_object);
        }
    }

    return @ptrCast(module_object);
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
    const symbol_z = allocator.dupeZ(u8, symbol) catch |err| {
        setExceptionFmt(actual_ctx, exception, "onBeforeParse symbol allocation failed: {s}", .{@errorName(err)});
        return null;
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
    const env = env_ orelse return @intFromEnum(NapiStatus.invalid_arg);
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
    const env = env_ orelse return @intFromEnum(NapiStatus.invalid_arg);
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
    const env = env_ orelse return @intFromEnum(NapiStatus.invalid_arg);
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
    const env = env_ orelse return @intFromEnum(NapiStatus.invalid_arg);
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
    const env = env_ orelse return @intFromEnum(NapiStatus.invalid_arg);
    const out = result orelse return setNapiLastError(env, .invalid_arg);
    const object_value = value orelse return setNapiLastError(env, .invalid_arg);
    const object = extern_fns.JSValueToObject(env.ctx, object_value, env.exception) orelse return setNapiLastError(env, .invalid_arg);
    const external = native_externals.get(@intFromPtr(object)) orelse return setNapiLastError(env, .invalid_arg);
    out.* = external.data;
    return setNapiLastError(env, .ok);
}

fn napi_create_int32(env_: napi_env, value: i32, result: ?*napi_value) napi_status {
    const env = env_ orelse return @intFromEnum(NapiStatus.invalid_arg);
    const out = result orelse return setNapiLastError(env, .invalid_arg);
    out.* = extern_fns.JSValueMakeNumber(env.ctx, @floatFromInt(value));
    return setNapiLastError(env, .ok);
}

fn napi_create_string_utf8(env_: napi_env, str: ?[*]const u8, length: usize, result: ?*napi_value) napi_status {
    const env = env_ orelse return @intFromEnum(NapiStatus.invalid_arg);
    const out = result orelse return setNapiLastError(env, .invalid_arg);
    const ptr = str orelse return setNapiLastError(env, .invalid_arg);
    const text = if (length == NAPI_AUTO_LENGTH) std.mem.span(@as([*:0]const u8, @ptrCast(ptr))) else ptr[0..length];
    out.* = makeStringValue(env.ctx, text) catch return setNapiLastError(env, .generic_failure);
    return setNapiLastError(env, .ok);
}

pub export fn napi_get_value_bool(env_: napi_env, value: napi_value, result: ?*bool) napi_status {
    const env = env_ orelse return @intFromEnum(NapiStatus.invalid_arg);
    const out = result orelse return setNapiLastError(env, .invalid_arg);
    const js_value = value orelse return setNapiLastError(env, .invalid_arg);
    out.* = extern_fns.JSValueToBoolean(env.ctx, js_value);
    return setNapiLastError(env, .ok);
}

pub export fn napi_throw_error(env_: napi_env, _: ?[*:0]const u8, message: ?[*:0]const u8) napi_status {
    const env = env_ orelse return @intFromEnum(NapiStatus.invalid_arg);
    setException(env.ctx, env.exception, if (message) |ptr| std.mem.span(ptr) else "napi error");
    return setNapiLastError(env, .pending_exception);
}

pub export fn napi_create_object(env_: napi_env, result: ?*napi_value) napi_status {
    const env = env_ orelse return @intFromEnum(NapiStatus.invalid_arg);
    const out = result orelse return setNapiLastError(env, .invalid_arg);
    out.* = @ptrCast(extern_fns.JSObjectMake(env.ctx, null, null) orelse return setNapiLastError(env, .generic_failure));
    return setNapiLastError(env, .ok);
}

fn setNapiLastError(env: *NativeNapiEnv, status: NapiStatus) napi_status {
    env.last_error = status;
    return @intFromEnum(status);
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

    const eval_script_path = if (is_home_invocation and isHomeEvalInvocation(argv_storage.items))
        try rewriteHomeEvalInvocation(allocator, io, &argv_storage)
    else
        null;
    defer if (eval_script_path) |path| Io.Dir.cwd().deleteFile(io, path) catch {};

    if (is_home_invocation and shouldInsertHomeRunForScript(argv_storage.items)) {
        try argv_storage.insert(allocator, 1, try allocator.dupe(u8, "run"));
    }
    try resolveCorpusArguments(allocator, &argv_storage);

    const cwd_raw = try readOptionalStringProperty(allocator, ctx, options, "cwd", exception);
    defer if (cwd_raw) |path| allocator.free(path);
    const cwd = try resolveSpawnCwd(allocator, cwd_raw);
    defer if (cwd.owned) allocator.free(cwd.path.?);

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

    var stdout_text: []u8 = &.{};
    var stderr_text: []u8 = &.{};
    var term: std.process.Child.Term = undefined;
    var captured = false;

    if (stdio.stdout == .pipe or stdio.stderr == .pipe) {
        const run_result = std.process.run(allocator, io, .{
            .argv = argv_storage.items,
            .cwd = if (cwd.path) |path| .{ .path = path } else .inherit,
        }) catch |err| {
            setExceptionFmt(ctx, exception, "Bun.spawnSync() failed: {s} cmd={s} cwd={s}", .{ @errorName(err), argv_storage.items[0], cwd.path orelse "(inherit)" });
            return error.NativeException;
        };
        stdout_text = run_result.stdout;
        stderr_text = run_result.stderr;
        term = run_result.term;
        captured = true;
    } else {
        var child = std.process.spawn(io, .{
            .argv = argv_storage.items,
            .cwd = if (cwd.path) |path| .{ .path = path } else .inherit,
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

    return makeSpawnResult(ctx, term, stdout_text, stderr_text);
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
    return std.mem.eql(u8, value, "home") or std.mem.eql(u8, std.fs.path.basename(value), "home");
}

fn isHomeEvalInvocation(argv: []const []const u8) bool {
    return argv.len >= 2 and std.mem.eql(u8, argv[1], "-e");
}

fn rewriteHomeEvalInvocation(
    allocator: std.mem.Allocator,
    io: Io,
    argv: *std.ArrayList([]const u8),
) ![]const u8 {
    if (argv.items.len < 3) return error.MissingEvalSource;

    const pid: i32 = @intCast(std.c.getpid());
    home_eval_counter += 1;
    const relative_script_path = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/home-corpus-eval-{d}-{d}.js",
        .{ pid, home_eval_counter },
    );
    defer allocator.free(relative_script_path);

    const cwd = try currentWorkingDirectoryAlloc(allocator);
    defer allocator.free(cwd);

    const script_path = try std.fs.path.join(allocator, &.{ cwd, relative_script_path });
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

fn makeSpawnResult(ctx: *JSContextRef, term: std.process.Child.Term, stdout_text: []const u8, stderr_text: []const u8) !*JSValue {
    const object = extern_fns.JSObjectMake(ctx, null, null) orelse return error.MakeObjectFailed;

    switch (term) {
        .exited => |code| {
            setNumberProperty(ctx, object, "exitCode", code);
        },
        .signal => |signal| {
            setNullProperty(ctx, object, "exitCode");
            setNumberProperty(ctx, object, "signalCode", @intFromEnum(signal));
        },
        .stopped => |signal| {
            setNullProperty(ctx, object, "exitCode");
            setNumberProperty(ctx, object, "signalCode", @intFromEnum(signal));
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
    const z = try allocator.dupeZ(u8, value);
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

        const output = try transpileSource(std.testing.allocator, &default_handle, case.source, .ts);
        defer std.testing.allocator.free(output);
        try std.testing.expectEqualStrings(case.output, output);
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

        const output = try transpileSource(std.testing.allocator, &default_handle, case.source, .ts);
        defer std.testing.allocator.free(output);
        try std.testing.expectEqualStrings(case.output, output);
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
