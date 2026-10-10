const std = @import("std");

const CompileCommand = struct {
    directory: []const u8,
    file: []const u8,
    arguments: []const []const u8,
};

var cached_process_object: ?std.Build.LazyPath = null;
var cached_registry_object: ?std.Build.LazyPath = null;
var cached_script_execution_context_object: ?std.Build.LazyPath = null;
var cached_napi_object: ?std.Build.LazyPath = null;
var cached_global_gc_object: ?std.Build.LazyPath = null;
var cached_message_port_object: ?std.Build.LazyPath = null;
var cached_message_port_pipe_object: ?std.Build.LazyPath = null;
var cached_worker_object: ?std.Build.LazyPath = null;
var cached_worker_scope_object: ?std.Build.LazyPath = null;
var cached_js_message_port_object: ?std.Build.LazyPath = null;
var cached_broadcast_channel_object: ?std.Build.LazyPath = null;
var cached_js_abort_signal_object: ?std.Build.LazyPath = null;
var cached_uws_object: ?std.Build.LazyPath = null;
var cached_crypto_object_0: ?std.Build.LazyPath = null;
var cached_crypto_object_1: ?std.Build.LazyPath = null;
var cached_serialized_script_value_object: ?std.Build.LazyPath = null;
var cached_async_hooks_object: ?std.Build.LazyPath = null;
var cached_native_modules: ?std.Build.LazyPath = null;
var cached_string_width_object: ?std.Build.LazyPath = null;
var cached_string_decoder_object: ?std.Build.LazyPath = null;
var cached_util_types_object: ?std.Build.LazyPath = null;
var cached_sqlite_statement_object: ?std.Build.LazyPath = null;
var cached_core_builtins_object: ?std.Build.LazyPath = null;

pub fn coreBuiltinsObject(b: *std.Build, object_root: []const u8) std.Build.LazyPath {
    if (cached_core_builtins_object) |object| return object;
    const build_root = std.fs.path.dirname(object_root) orelse @panic("invalid native object root");
    const generate = b.addSystemCommand(&.{ "bun", "run" });
    generate.addFileArg(b.path("build-support/bundle-core-builtins.ts"));
    generate.addArg(build_root);
    const output = generate.addOutputDirectoryArg("core-builtins");
    generate.setName("generate Home core builtin functions");
    generate.setCwd(b.path("."));
    for ([_][]const u8{
        "build-support/core_builtin_abi.ts",
        "build-support/native_module_abi.ts",
        "packages/runtime/upstream/src/codegen/bundle-functions.ts",
        "packages/runtime/upstream/src/codegen/builtin-parser.ts",
        "packages/runtime/upstream/src/codegen/client-js.ts",
        "packages/runtime/upstream/src/codegen/helpers.ts",
        "packages/runtime/upstream/src/codegen/replacements.ts",
        "packages/runtime/upstream/src/codegen/generate-js2native.ts",
        "packages/runtime/upstream/src/codegen/internal-module-registry-scanner.ts",
        "packages/runtime/upstream/src/jsc/bindings/ErrorCode.ts",
    }) |input| generate.addFileInput(b.path(input));
    for ([_][]const u8{
        "Bake",                             "BakeSSRResponse",          "BundlerPlugin",                   "CommonJS",                    "ConsoleObject",                "Glob",                        "ImportMetaObject", "Ipc",                      "JSBufferConstructor",       "JSBufferPrototype",               "NodeModuleObject",            "Peek",                    "ProcessObjectInternals", "UtilInspect",       "WasmStreaming",     "shell",
        "ByteLengthQueuingStrategy",        "CompressionStream",        "CountQueuingStrategy",            "DecompressionStream",         "ReadableByteStreamController", "ReadableByteStreamInternals", "ReadableStream",   "ReadableStreamBYOBReader", "ReadableStreamBYOBRequest", "ReadableStreamDefaultController", "ReadableStreamDefaultReader", "ReadableStreamInternals", "StreamInternals",        "TextDecoderStream", "TextEncoderStream", "TransformStream",
        "TransformStreamDefaultController", "TransformStreamInternals", "WritableStreamDefaultController", "WritableStreamDefaultWriter", "WritableStreamInternals",
    }) |family| generate.addFileInput(b.path(b.fmt("packages/runtime/upstream/src/js/builtins/{s}.ts", .{family})));
    for ([_][]const u8{ "WebCoreJSBuiltins.cpp", "WebCoreJSBuiltins.h", "InternalModuleRegistry+enum.h", "GeneratedJS2Native.h", "ErrorCode+List.h" }) |name|
        generate.addFileInput(.{ .cwd_relative = b.fmt("{s}/codegen/{s}", .{ build_root, name }) });
    const object = compileObject(b, object_root, "WebCoreJSBuiltins.cpp", output.path(b, "WebCoreJSBuiltins.cpp"));
    cached_core_builtins_object = object;
    return object;
}

/// Rebuild the Home-owned process binding with the headers and ABI flags that
/// produced the rest of the linked Bun objects. Never silently use the stale
/// external object when its source differs from Home's implementation.
pub fn processObject(b: *std.Build, object_root: []const u8) std.Build.LazyPath {
    if (cached_process_object) |object| return object;
    const files = b.addWriteFiles();
    const source = files.addCopyFile(b.path("packages/runtime/upstream/src/jsc/bindings/BunProcess.cpp"), "BunProcess.cpp");
    _ = files.addCopyFile(b.path("packages/runtime/upstream/src/jsc/bindings/HomeICUBinding.cpp"), "HomeICUBinding.cpp");
    const object = compileObject(b, object_root, "BunProcess.cpp", source);
    cached_process_object = object;
    return object;
}

pub fn napiObject(b: *std.Build, object_root: []const u8) std.Build.LazyPath {
    if (cached_napi_object) |object| return object;
    const files = b.addWriteFiles();
    const source = files.addCopyFile(b.path("packages/runtime/upstream/src/jsc/bindings/napi.cpp"), "napi.cpp");
    const object = compileObject(b, object_root, "napi.cpp", source);
    cached_napi_object = object;
    return object;
}

pub fn globalGcObject(b: *std.Build, object_root: []const u8) std.Build.LazyPath {
    if (cached_global_gc_object) |object| return object;
    const files = b.addWriteFiles();
    const source = files.addCopyFile(b.path("packages/runtime/src/native/global_gc.cpp"), "global_gc.cpp");
    const object = compileObject(b, object_root, "ZigGlobalObject.cpp", source);
    cached_global_gc_object = object;
    return object;
}

pub fn registryObject(b: *std.Build, object_root: []const u8) std.Build.LazyPath {
    if (cached_registry_object) |object| return object;
    const output = nativeModules(b, object_root);
    const object = compileObject(b, object_root, "UnifiedSource-src_jsc_bindings-1.cpp", output.path(b, "HomeInternalModuleRegistry.cpp"));
    cached_registry_object = object;
    return object;
}

/// Rebuild ScriptExecutionContext from Home so worker shutdown can close the
/// identifier registry before disposing queued C++ tasks. Like the other owned
/// units, the unity wrapper is generated from the linked build's own bundle, so
/// the sibling set cannot drift from the objects it replaces.
pub fn scriptExecutionContextObject(b: *std.Build, object_root: []const u8) std.Build.LazyPath {
    if (cached_script_execution_context_object) |object| return object;
    const output = nativeModules(b, object_root);
    const object = compileObject(b, object_root, "UnifiedSource-src_jsc_bindings-4.cpp", output.path(b, "HomeScriptExecutionContext.cpp"));
    cached_script_execution_context_object = object;
    return object;
}

pub fn messagePortObject(b: *std.Build, object_root: []const u8) std.Build.LazyPath {
    if (cached_message_port_object) |object| return object;
    const output = nativeModules(b, object_root);
    const object = compileObject(b, object_root, "UnifiedSource-src_jsc_bindings_webcore-3.cpp", output.path(b, "HomeMessagePort.cpp"));
    cached_message_port_object = object;
    return object;
}

pub fn messagePortPipeObject(b: *std.Build, object_root: []const u8) std.Build.LazyPath {
    if (cached_message_port_pipe_object) |object| return object;
    const output = nativeModules(b, object_root);
    const object = compileObject(b, object_root, "UnifiedSource-src_jsc_bindings_webcore-4.cpp", output.path(b, "HomeMessagePortPipe.cpp"));
    cached_message_port_pipe_object = object;
    return object;
}

pub fn workerObject(b: *std.Build, object_root: []const u8) std.Build.LazyPath {
    if (cached_worker_object) |object| return object;
    const output = nativeModules(b, object_root);
    const object = compileObject(b, object_root, "UnifiedSource-src_jsc_bindings_webcore-5.cpp", output.path(b, "HomeWorker.cpp"));
    cached_worker_object = object;
    return object;
}

pub fn workerScopeObject(b: *std.Build, object_root: []const u8) std.Build.LazyPath {
    if (cached_worker_scope_object) |object| return object;
    const output = nativeModules(b, object_root);
    const object = compileObject(b, object_root, "UnifiedSource-src_jsc_bindings-0.cpp", output.path(b, "HomeBunWorkerGlobalScope.cpp"));
    cached_worker_scope_object = object;
    return object;
}

pub fn jsMessagePortObject(b: *std.Build, object_root: []const u8) std.Build.LazyPath {
    if (cached_js_message_port_object) |object| return object;
    const output = nativeModules(b, object_root);
    const object = compileObject(b, object_root, "UnifiedSource-src_jsc_bindings_webcore-2.cpp", output.path(b, "HomeJSMessagePort.cpp"));
    cached_js_message_port_object = object;
    return object;
}

/// Build the native cross-context channel and shared subscriber registry from
/// Home's source, retaining the linked unity object's remaining companions.
pub fn broadcastChannelObject(b: *std.Build, object_root: []const u8) std.Build.LazyPath {
    if (cached_broadcast_channel_object) |object| return object;
    const output = nativeModules(b, object_root);
    const object = compileObject(b, object_root, "UnifiedSource-src_jsc_bindings_webcore-0.cpp", output.path(b, "HomeBroadcastChannel.cpp"));
    cached_broadcast_channel_object = object;
    return object;
}

pub fn jsAbortSignalObject(b: *std.Build, object_root: []const u8) std.Build.LazyPath {
    if (cached_js_abort_signal_object) |object| return object;
    const output = nativeModules(b, object_root);
    const object = compileObject(b, object_root, "UnifiedSource-src_jsc_bindings_webcore-1.cpp", output.path(b, "HomeJSAbortSignalCustom.cpp"));
    cached_js_abort_signal_object = object;
    return object;
}

/// Compile the uWebSockets C ABI from Home's pinned source so parser fixes in
/// the mirrored bun-uws headers are part of the executable rather than dead
/// reference code beside Bun's external object.
pub fn uwsObject(b: *std.Build, object_root: []const u8) std.Build.LazyPath {
    if (cached_uws_object) |object| return object;
    const source = b.path("packages/runtime/upstream/src/uws_sys/HomeUws.cpp");
    const object = compileObject(b, object_root, "UnifiedSource-src_uws_sys-0.cpp", source);
    cached_uws_object = object;
    return object;
}

/// Compile Node crypto from Home's mirrored source. The native runtime links
/// Bun's object graph, so source changes here are otherwise inert unless the
/// matching upstream unity objects are replaced as a complete pair.
pub fn cryptoObject0(b: *std.Build, object_root: []const u8) std.Build.LazyPath {
    if (cached_crypto_object_0) |object| return object;
    const object = compileObject(
        b,
        object_root,
        "UnifiedSource-src_jsc_bindings_node_crypto-0.cpp",
        b.path("packages/runtime/src/native/node_crypto_unified_0.cpp"),
    );
    cached_crypto_object_0 = object;
    return object;
}

pub fn cryptoObject1(b: *std.Build, object_root: []const u8) std.Build.LazyPath {
    if (cached_crypto_object_1) |object| return object;
    const object = compileObject(
        b,
        object_root,
        "UnifiedSource-src_jsc_bindings_node_crypto-1.cpp",
        b.path("packages/runtime/src/native/node_crypto_unified_1.cpp"),
    );
    cached_crypto_object_1 = object;
    return object;
}

/// Compile structured cloning from Home so native KeyObject serialization can
/// preserve key types that the pinned BoringSSL EVP decoder cannot represent.
pub fn serializedScriptValueObject(b: *std.Build, object_root: []const u8) std.Build.LazyPath {
    if (cached_serialized_script_value_object) |object| return object;
    const files = b.addWriteFiles();
    const source = files.addCopyFile(
        b.path("packages/runtime/upstream/src/jsc/bindings/webcore/SerializedScriptValue.cpp"),
        "SerializedScriptValue.cpp",
    );
    const object = compileObject(b, object_root, "SerializedScriptValue.cpp", source);
    cached_serialized_script_value_object = object;
    return object;
}

pub fn asyncHooksObject(b: *std.Build, object_root: []const u8) std.Build.LazyPath {
    if (cached_async_hooks_object) |object| return object;
    const output = nativeModules(b, object_root);
    const object = compileObject(b, object_root, "UnifiedSource-src_jsc_bindings-3.cpp", output.path(b, "HomeNodeAsyncHooks.cpp"));
    cached_async_hooks_object = object;
    return object;
}

pub fn stringWidthObject(b: *std.Build, object_root: []const u8) std.Build.LazyPath {
    if (cached_string_width_object) |object| return object;
    const output = nativeModules(b, object_root);
    const object = compileObject(b, object_root, "UnifiedSource-src_jsc_bindings-5.cpp", output.path(b, "HomeStringWidth.cpp"));
    cached_string_width_object = object;
    return object;
}

pub fn stringDecoderObject(b: *std.Build, object_root: []const u8) std.Build.LazyPath {
    if (cached_string_decoder_object) |object| return object;
    const output = nativeModules(b, object_root);
    const object = compileObject(b, object_root, "UnifiedSource-src_jsc_bindings-2.cpp", output.path(b, "HomeJSStringDecoder.cpp"));
    cached_string_decoder_object = object;
    return object;
}

pub fn utilTypesObject(b: *std.Build, object_root: []const u8) std.Build.LazyPath {
    if (cached_util_types_object) |object| return object;
    const output = nativeModules(b, object_root);
    const object = compileObject(b, object_root, "UnifiedSource-src_jsc_modules-0.cpp", output.path(b, "HomeNodeUtilTypesModule.cpp"));
    cached_util_types_object = object;
    return object;
}

pub fn sqliteStatementObject(b: *std.Build, object_root: []const u8) std.Build.LazyPath {
    if (cached_sqlite_statement_object) |object| return object;
    const output = nativeModules(b, object_root);
    const object = compileObject(b, object_root, "JSSQLStatement.cpp", output.path(b, "JSSQLStatement.cpp"));
    cached_sqlite_statement_object = object;
    return object;
}

fn nativeModules(b: *std.Build, object_root: []const u8) std.Build.LazyPath {
    if (cached_native_modules) |output| return output;
    const build_root = std.fs.path.dirname(object_root) orelse @panic("invalid native object root");
    const bundler = b.findProgram(.{ .names = &.{"bun"} }) orelse @panic("Home builtin generation requires Bun at build time");
    const generate = b.addSystemCommand(&.{bundler});
    generate.addFileInput(.{ .cwd_relative = bundler });
    generate.setName("generate Home native builtin modules");
    generate.addFileArg(b.path("build-support/bundle-native-modules.ts"));
    generate.addArg(build_root);
    const output = generate.addOutputDirectoryArg2("native-modules", .{ .make_absolute = true });
    for ([_][]const u8{
        "build-support/native_module_abi.ts",
        "build-support/builtin_exports.ts",
        "packages/runtime/upstream/src/jsc/bindings/JSNodePerformanceHooksHistogram.cpp",
        "packages/runtime/upstream/src/jsc/bindings/JSNodePerformanceHooksHistogramConstructor.cpp",
        "packages/runtime/upstream/src/jsc/bindings/JSNodePerformanceHooksHistogramPrototype.cpp",
        "packages/runtime/upstream/src/jsc/bindings/ProcessBindingTTYWrap.cpp",
        "packages/runtime/upstream/src/jsc/bindings/JSNodePerformanceHooksHistogram.h",
        "packages/runtime/upstream/src/jsc/bindings/JSNodePerformanceHooksHistogramConstructor.h",
        "packages/runtime/upstream/src/jsc/bindings/JSNodePerformanceHooksHistogramPrototype.h",
        "packages/runtime/upstream/src/jsc/bindings/ProcessBindingTTYWrap.h",
        "packages/runtime/upstream/src/js/node/vm.ts",
        "packages/runtime/upstream/src/js/node/v8.ts",
        "packages/runtime/upstream/src/js/node/console.ts",
        "packages/runtime/upstream/src/js/node/trace_events.ts",
        "packages/runtime/upstream/src/js/node/repl.ts",
        "packages/runtime/upstream/src/js/node/inspector.ts",
        "packages/runtime/upstream/src/js/node/inspector.promises.ts",
        "packages/runtime/upstream/src/jsc/bindings/NodeVM.cpp",
        "packages/runtime/upstream/src/jsc/bindings/NodeVM.h",
        "packages/runtime/upstream/src/jsc/bindings/NodeVMModule.cpp",
        "packages/runtime/upstream/src/jsc/bindings/NodeVMModule.h",
        "packages/runtime/upstream/src/jsc/bindings/NodeVMScript.cpp",
        "packages/runtime/upstream/src/jsc/bindings/NodeVMScript.h",
        "packages/runtime/upstream/src/jsc/bindings/NodeVMSourceTextModule.cpp",
        "packages/runtime/upstream/src/jsc/bindings/NodeVMSourceTextModule.h",
        "packages/runtime/upstream/src/jsc/bindings/NodeVMSyntheticModule.cpp",
        "packages/runtime/upstream/src/jsc/bindings/NodeVMSyntheticModule.h",
        "packages/runtime/upstream/src/jsc/bindings/JSInspectorProfiler.cpp",
        "packages/runtime/upstream/src/jsc/bindings/JSInspectorProfiler.h",
        "packages/runtime/upstream/src/jsc/bindings/NodeVMScriptFetcher.h",
        "packages/runtime/upstream/src/js/thirdparty/ws.js",
        "packages/runtime/upstream/src/js/thirdparty/undici.js",
        "packages/runtime/upstream/src/js/thirdparty/node-fetch.ts",
        "packages/runtime/upstream/src/js/thirdparty/isomorphic-fetch.ts",
        "packages/runtime/upstream/src/js/thirdparty/vercel_fetch.js",
        "packages/runtime/upstream/src/js/internal/abort_listener.ts",
        "packages/runtime/upstream/src/js/internal/assert/assertion_error.ts",
        "packages/runtime/upstream/src/js/internal/assert/calltracker.ts",
        "packages/runtime/upstream/src/js/internal/assert/myers_diff.ts",
        "packages/runtime/upstream/src/js/internal/assert/utils.ts",
        "packages/runtime/upstream/src/js/internal/buffer.ts",
        "packages/runtime/upstream/src/js/internal/cluster/RoundRobinHandle.ts",
        "packages/runtime/upstream/src/js/internal/cluster/Worker.ts",
        "packages/runtime/upstream/src/js/internal/cluster/child.ts",
        "packages/runtime/upstream/src/js/internal/cluster/primary.ts",
        "packages/runtime/upstream/src/js/internal/fifo.ts",
        "packages/runtime/upstream/src/js/internal/fixed_queue.ts",
        "packages/runtime/upstream/src/js/internal/linkedlist.ts",
        "packages/runtime/upstream/src/jsc/bindings/NodeFetch.cpp",
        "packages/runtime/upstream/src/jsc/bindings/NodeFetch.h",
        "packages/runtime/upstream/src/jsc/bindings/Undici.cpp",
        "packages/runtime/upstream/src/jsc/bindings/Undici.h",
        "packages/runtime/upstream/src/jsc/bindings/webcore/EventTarget.cpp",
        "packages/runtime/upstream/src/jsc/bindings/webcore/EventTarget.h",
        "packages/runtime/upstream/src/jsc/bindings/webcore/JSEventTarget.cpp",
        "packages/runtime/upstream/src/jsc/bindings/webcore/JSEventTarget.h",
        "packages/runtime/upstream/src/jsc/bindings/webcore/RegisteredEventListener.cpp",
        "packages/runtime/upstream/src/jsc/bindings/webcore/RegisteredEventListener.h",
        "packages/runtime/upstream/src/jsc/bindings/webcore/HomeAbortListenerState.h",
        "packages/runtime/upstream/src/js/bun/ffi.ts",
        "packages/runtime/upstream/src/js/bun/sql.ts",
        "packages/runtime/upstream/src/js/bun/sqlite.ts",
        "packages/runtime/upstream/src/js/internal/sql/errors.ts",
        "packages/runtime/upstream/src/js/internal/sql/mysql.ts",
        "packages/runtime/upstream/src/js/internal/sql/postgres.ts",
        "packages/runtime/upstream/src/js/internal/sql/query.ts",
        "packages/runtime/upstream/src/js/internal/sql/shared.ts",
        "packages/runtime/upstream/src/js/internal/sql/sqlite.ts",
        "packages/runtime/upstream/src/jsc/bindings/JSFFIFunction.cpp",
        "packages/runtime/upstream/src/jsc/bindings/JSFFIFunction.h",
        "packages/runtime/upstream/src/jsc/bindings/sqlite/JSSQLStatement.cpp",
        "packages/runtime/upstream/src/jsc/bindings/sqlite/JSSQLStatement.h",
        "packages/runtime/upstream/src/jsc/bindings/sqlite/lazy_sqlite3.h",
        "packages/runtime/upstream/src/jsc/bindings/sqlite/sqlite3_error_codes.h",
        "packages/runtime/src/jsc/internal-stream-wrap.js",
        "packages/runtime/upstream/src/codegen/builtin-parser.ts",
        "packages/runtime/upstream/src/codegen/client-js.ts",
        "packages/runtime/upstream/src/codegen/generate-js2native.ts",
        "packages/runtime/upstream/src/codegen/helpers.ts",
        "packages/runtime/upstream/src/codegen/internal-module-registry-scanner.ts",
        "packages/runtime/upstream/src/codegen/replacements.ts",
        "packages/runtime/upstream/src/api/schema.js",
        "packages/runtime/upstream/src/jsc/bindings/ErrorCode.ts",
        "packages/runtime/upstream/src/jsc/bindings/ErrorCode.cpp",
        "packages/runtime/upstream/src/jsc/bindings/js_classes.ts",
        "packages/runtime/upstream/src/jsc/bindings/InternalModuleRegistry.cpp",
        "packages/runtime/upstream/src/jsc/bindings/IPC.cpp",
        "packages/runtime/upstream/src/jsc/bindings/Path.cpp",
        "packages/runtime/upstream/src/jsc/bindings/Path.h",
        "packages/runtime/upstream/src/jsc/bindings/NodeValidator.cpp",
        "packages/runtime/upstream/src/jsc/bindings/NodeValidator.h",
        "packages/runtime/upstream/src/jsc/bindings/NodeHTTP.cpp",
        "packages/runtime/upstream/src/jsc/bindings/NodeHTTP.h",
        "packages/runtime/upstream/src/jsc/bindings/NodeTLS.cpp",
        "packages/runtime/upstream/src/jsc/bindings/NodeTLS.h",
        "packages/runtime/upstream/src/jsc/bindings/stringWidth.cpp",
        "packages/runtime/upstream/src/jsc/bindings/stringWidth.h",
        "packages/runtime/upstream/src/jsc/bindings/sliceAnsi.cpp",
        "packages/runtime/upstream/src/jsc/bindings/sliceAnsi.h",
        "packages/runtime/upstream/src/jsc/bindings/stripANSI.cpp",
        "packages/runtime/upstream/src/jsc/bindings/stripANSI.h",
        "packages/runtime/upstream/src/jsc/bindings/wrapAnsi.cpp",
        "packages/runtime/upstream/src/jsc/bindings/wrapAnsi.h",
        "packages/runtime/upstream/src/jsc/bindings/napi_finalizer.cpp",
        "packages/runtime/upstream/src/jsc/bindings/napi_finalizer.h",

        "packages/runtime/upstream/src/jsc/bindings/ANSIHelpers.h",
        "packages/runtime/upstream/src/jsc/bindings/stringWidthTables.h",
        "packages/runtime/upstream/src/jsc/modules/NodeUtilTypesModule.cpp",
        "packages/runtime/upstream/src/jsc/modules/NodeUtilTypesModule.h",
        "packages/runtime/upstream/src/jsc/modules/NodeModuleModule.cpp",
        "packages/runtime/upstream/src/jsc/modules/NodeModuleModule.h",
        "packages/runtime/upstream/src/jsc/modules/NodeBufferModule.h",
        "packages/runtime/upstream/src/jsc/modules/NodeStringDecoderModule.h",
        "packages/runtime/upstream/src/jsc/bindings/JSStringDecoder.cpp",
        "packages/runtime/upstream/src/jsc/bindings/JSStringDecoder.h",
        "packages/runtime/upstream/src/jsc/bindings/webcore/JSMIMEParams.cpp",
        "packages/runtime/upstream/src/jsc/bindings/webcore/JSMIMEParams.h",

        "packages/runtime/upstream/src/jsc/bindings/EventLoopTaskNoContext.cpp",
        "packages/runtime/src/native/H2HeadersMaterializer.cpp",
        "packages/runtime/upstream/src/jsc/bindings/NodeAsyncHooks.cpp",
        "packages/runtime/upstream/src/jsc/bindings/NodeAsyncHooks.h",
        "packages/runtime/upstream/src/jsc/bindings/webcore/WebSocket.cpp",
        "packages/runtime/upstream/src/jsc/bindings/webcore/WebSocket.h",
        "packages/runtime/upstream/src/jsc/bindings/webcore/JSWebSocket.cpp",
        "packages/runtime/upstream/src/jsc/bindings/webcore/JSWebSocket.h",
        "packages/runtime/upstream/src/jsc/bindings/webcore/HomeWebSocketAsyncContext.h",
        "packages/runtime/upstream/src/jsc/bindings/AsyncContextFrame.cpp",
        "packages/runtime/upstream/src/jsc/bindings/AsyncContextFrame.h",
        "packages/runtime/upstream/src/jsc/bindings/BunWorkerGlobalScope.cpp",
        "packages/runtime/upstream/src/jsc/bindings/BunWorkerGlobalScope.h",
        "packages/runtime/upstream/src/jsc/bindings/BunAnalyzeTranspiledModule.cpp",
        "packages/runtime/upstream/src/jsc/bindings/BunAnalyzeTranspiledModule.h",
        "packages/runtime/upstream/src/jsc/bindings/webcore/BroadcastChannel.cpp",
        "packages/runtime/upstream/src/jsc/bindings/webcore/BroadcastChannel.h",
        "packages/runtime/upstream/src/jsc/bindings/webcore/BunBroadcastChannelRegistry.cpp",
        "packages/runtime/upstream/src/jsc/bindings/webcore/BunBroadcastChannelRegistry.h",
        "packages/runtime/upstream/src/jsc/bindings/webcore/JSBroadcastChannel.cpp",
        "packages/runtime/upstream/src/jsc/bindings/webcore/JSBroadcastChannel.h",
        "packages/runtime/upstream/src/jsc/bindings/webcore/MessageEvent.cpp",
        "packages/runtime/upstream/src/jsc/bindings/webcore/MessageEvent.h",
        "packages/runtime/upstream/src/jsc/bindings/webcore/JSMessageEvent.cpp",
        "packages/runtime/upstream/src/jsc/bindings/webcore/JSMessageEvent.h",
        "packages/runtime/upstream/src/jsc/bindings/webcore/JSAbortSignalCustom.cpp",
        "packages/runtime/upstream/src/jsc/bindings/webcore/AbortSignal.h",
        "packages/runtime/upstream/src/jsc/bindings/webcore/JSMessagePort.cpp",
        "packages/runtime/upstream/src/jsc/bindings/webcore/JSMessagePort.h",
        "packages/runtime/upstream/src/jsc/bindings/webcore/MessagePort.cpp",
        "packages/runtime/upstream/src/jsc/bindings/webcore/MessagePort.h",
        "packages/runtime/upstream/src/jsc/bindings/webcore/MessagePortPipe.cpp",
        "packages/runtime/upstream/src/jsc/bindings/webcore/MessagePortPipe.h",
        "packages/runtime/upstream/src/jsc/bindings/webcore/ReadableStream.cpp",
        "packages/runtime/upstream/src/jsc/bindings/webcore/ReadableStream.h",
        "packages/runtime/upstream/src/jsc/bindings/webcore/JSReadableStream.cpp",
        "packages/runtime/upstream/src/jsc/bindings/webcore/JSReadableStream.h",

        "packages/runtime/upstream/src/jsc/bindings/webcore/Worker.cpp",
        "packages/runtime/upstream/src/jsc/bindings/webcore/Worker.h",
        "packages/runtime/upstream/src/jsc/bindings/webcore/HomeMessagePortLifecycle.h",
        "packages/runtime/upstream/src/jsc/bindings/webcore/HomeWorkerSnapshots.h",
        "packages/runtime/upstream/src/jsc/bindings/webcore/JSWorker.cpp",
        "packages/runtime/upstream/src/jsc/bindings/webcore/JSWorker.h",
        "packages/runtime/upstream/src/jsc/modules/_NativeModule.h",
        "packages/runtime/upstream/src/js/node/url.ts",
        "packages/runtime/upstream/src/js/node/worker_threads.ts",
        "packages/runtime/upstream/src/js/node/querystring.ts",
        "packages/runtime/upstream/src/js/node/assert.ts",
        "packages/runtime/upstream/src/js/node/assert.strict.ts",
        "packages/runtime/upstream/src/js/node/events.ts",
        "packages/runtime/upstream/src/js/node/async_hooks.ts",
        "packages/runtime/upstream/src/js/node/dgram.ts",
        "packages/runtime/upstream/src/js/node/net.ts",
        "packages/runtime/upstream/src/js/node/timers.ts",
        "packages/runtime/upstream/src/js/node/timers.promises.ts",
        "packages/runtime/upstream/src/js/internal/async_hooks.ts",
        "packages/runtime/upstream/src/js/internal/async_hooks_tick.ts",
        "packages/runtime/upstream/src/js/node/path.ts",
        "packages/runtime/upstream/src/js/node/path.posix.ts",
        "packages/runtime/upstream/src/js/node/path.win32.ts",
        "packages/runtime/upstream/src/js/node/util.ts",
        "packages/runtime/upstream/src/js/node/domain.ts",
        "packages/runtime/upstream/src/js/node/punycode.ts",
        "packages/runtime/upstream/src/js/node/diagnostics_channel.ts",
        "packages/runtime/upstream/src/js/node/os.ts",
        "packages/runtime/upstream/src/js/node/dns.ts",
        "packages/runtime/upstream/src/js/node/dns.promises.ts",
        "packages/runtime/upstream/src/js/internal/shared.ts",
        "packages/runtime/upstream/src/js/internal/errors.ts",
        "packages/runtime/upstream/src/js/internal/validators.ts",
        "packages/runtime/upstream/src/js/internal/util/inspect.js",
        "packages/runtime/upstream/src/js/internal/util/colors.ts",
        "packages/runtime/upstream/src/js/internal/util/deprecate.ts",
        "packages/runtime/upstream/src/js/internal/util/mime.ts",
        "packages/runtime/upstream/src/js/internal/primordials.js",
        "packages/runtime/upstream/src/js/internal/streams/add-abort-signal.ts",
        "packages/runtime/upstream/src/js/internal/streams/compose.ts",
        "packages/runtime/upstream/src/js/internal/streams/destroy.ts",
        "packages/runtime/upstream/src/js/internal/streams/duplex.ts",
        "packages/runtime/upstream/src/js/internal/streams/duplexify.ts",
        "packages/runtime/upstream/src/js/internal/streams/duplexpair.ts",
        "packages/runtime/upstream/src/js/internal/streams/end-of-stream.ts",
        "packages/runtime/upstream/src/js/internal/streams/from.ts",
        "packages/runtime/upstream/src/js/internal/streams/iter/broadcast.ts",
        "packages/runtime/upstream/src/js/internal/streams/iter/classic.ts",
        "packages/runtime/upstream/src/js/internal/streams/iter/consumers.ts",
        "packages/runtime/upstream/src/js/internal/streams/iter/duplex.ts",
        "packages/runtime/upstream/src/js/internal/streams/iter/from.ts",
        "packages/runtime/upstream/src/js/internal/streams/iter/pull.ts",
        "packages/runtime/upstream/src/js/internal/streams/iter/push.ts",
        "packages/runtime/upstream/src/js/internal/streams/iter/ringbuffer.ts",
        "packages/runtime/upstream/src/js/internal/streams/iter/share.ts",
        "packages/runtime/upstream/src/js/internal/streams/iter/transform.ts",
        "packages/runtime/upstream/src/js/internal/streams/iter/types.ts",
        "packages/runtime/upstream/src/js/internal/streams/iter/utils.ts",
        "packages/runtime/upstream/src/js/internal/streams/lazy_transform.ts",
        "packages/runtime/upstream/src/js/internal/streams/legacy.ts",
        "packages/runtime/upstream/src/js/internal/streams/native-readable.ts",
        "packages/runtime/upstream/src/js/internal/streams/operators.ts",
        "packages/runtime/upstream/src/js/internal/streams/passthrough.ts",
        "packages/runtime/upstream/src/js/internal/streams/pipeline.ts",
        "packages/runtime/upstream/src/js/internal/streams/readable.ts",
        "packages/runtime/upstream/src/js/internal/streams/state.ts",
        "packages/runtime/upstream/src/js/internal/streams/transform.ts",
        "packages/runtime/upstream/src/js/internal/streams/utils.ts",
        "packages/runtime/upstream/src/js/internal/streams/writable.ts",
        "packages/runtime/upstream/src/js/internal/webstreams_adapters.ts",
        "packages/runtime/upstream/src/js/node/stream.consumers.ts",
        "packages/runtime/upstream/src/js/node/stream.iter.ts",
        "packages/runtime/upstream/src/js/node/stream.promises.ts",
        "packages/runtime/upstream/src/js/node/stream.ts",
        "packages/runtime/upstream/src/js/node/stream.web.ts",
        "packages/runtime/upstream/src/js/node/fs.ts",
        "packages/runtime/upstream/src/js/node/fs.promises.ts",
        "packages/runtime/upstream/src/js/node/child_process.ts",
        "packages/runtime/upstream/src/js/node/cluster.ts",
        "packages/runtime/upstream/src/js/internal/fs/binding.ts",
        "packages/runtime/upstream/src/js/internal/fs/cp-sync.ts",
        "packages/runtime/upstream/src/js/internal/fs/cp.ts",
        "packages/runtime/upstream/src/js/internal/fs/glob.ts",
        "packages/runtime/upstream/src/js/internal/fs/streams.ts",
        "packages/runtime/upstream/src/js/internal/fs/watch.ts",
        "packages/runtime/upstream/src/js/internal/fs/watchfile.ts",
        "packages/runtime/upstream/src/js/node/test.ts",
        "packages/runtime/upstream/src/js/node/crypto.ts",
        "packages/runtime/upstream/src/js/node/zlib.ts",
        "packages/runtime/upstream/src/js/node/zlib.iter.ts",
        "packages/runtime/upstream/src/js/internal/promisify.ts",
        "packages/runtime/upstream/src/js/node/_stream_duplex.ts",
        "packages/runtime/upstream/src/js/node/_stream_passthrough.ts",
        "packages/runtime/upstream/src/js/node/_stream_readable.ts",
        "packages/runtime/upstream/src/js/node/_stream_transform.ts",
        "packages/runtime/upstream/src/js/node/_stream_wrap.ts",
        "packages/runtime/upstream/src/js/node/_stream_writable.ts",
        "packages/runtime/upstream/src/js/node/http.ts",
        "packages/runtime/upstream/src/js/node/https.ts",
        "packages/runtime/upstream/src/js/node/_http_agent.ts",
        "packages/runtime/upstream/src/js/node/_http_client.ts",
        "packages/runtime/upstream/src/js/node/_http_common.ts",
        "packages/runtime/upstream/src/js/node/_http_incoming.ts",
        "packages/runtime/upstream/src/js/node/_http_outgoing.ts",
        "packages/runtime/upstream/src/js/node/_http_server.ts",
        "packages/runtime/upstream/src/js/node/tls.ts",
        "packages/runtime/upstream/src/js/node/_tls_common.ts",
        "packages/runtime/upstream/src/js/node/readline.ts",
        "packages/runtime/upstream/src/js/node/readline.promises.ts",
        "packages/runtime/upstream/src/js/node/tty.ts",
        "packages/runtime/upstream/src/js/internal/tty.ts",
        "packages/runtime/upstream/src/js/node/perf_hooks.ts",
        "packages/runtime/upstream/src/js/internal/perf_hooks/monitorEventLoopDelay.ts",
        "packages/runtime/upstream/src/js/node/http2.ts",
        "packages/runtime/upstream/src/js/node/_http2_upgrade.ts",
        "packages/runtime/upstream/src/js/internal/http.ts",
        "packages/runtime/upstream/src/js/internal/url.ts",
        "packages/runtime/upstream/src/js/internal/net/isIP.ts",
        "packages/runtime/upstream/src/js/internal/timers.ts",
        "packages/runtime/upstream/src/js/internal/freelist.ts",
        "packages/runtime/upstream/src/js/internal/http/FakeSocket.ts",
        "packages/runtime/upstream/src/js/internal/stream.ts",
        "packages/runtime/upstream/src/js/internal/cluster/isPrimary.ts",
        "packages/runtime/upstream/src/js/internal/tls.ts",
        "packages/runtime/upstream/src/js/internal/stream.promises.ts",

        "packages/runtime/upstream/src/js/internal/url.ts",
        "packages/runtime/upstream/src/js/internal/validators.ts",
    }) |input| generate.addFileInput(b.path(input));
    for ([_][]const u8{
        "codegen/InternalModuleRegistry+enum.h",
        "codegen/NativeModuleImpl.h",
        "codegen/InternalModuleRegistryConstants.h",
        "js/internal-for-testing.js",
        "codegen/GeneratedJS2Native.h",
        "codegen/ZigGeneratedClasses.cpp",
        "codegen/ErrorCode+List.h",
        "unified/UnifiedSource-src_jsc_bindings-1.cpp",
        "unified/UnifiedSource-src_jsc_bindings-0.cpp",
        "unified/UnifiedSource-src_jsc_bindings-2.cpp",
        "unified/UnifiedSource-src_jsc_bindings-3.cpp",
        "unified/UnifiedSource-src_jsc_bindings-5.cpp",
        "unified/UnifiedSource-src_jsc_modules-0.cpp",
        "unified/UnifiedSource-src_jsc_bindings-4.cpp",
        "unified/UnifiedSource-src_jsc_bindings_webcore-0.cpp",
        "unified/UnifiedSource-src_jsc_bindings_webcore-1.cpp",
        "unified/UnifiedSource-src_jsc_bindings_webcore-2.cpp",
        "unified/UnifiedSource-src_jsc_bindings_webcore-3.cpp",
        "unified/UnifiedSource-src_jsc_bindings_webcore-4.cpp",
        "unified/UnifiedSource-src_jsc_bindings_webcore-5.cpp",
    }) |input| generate.addFileInput(.{ .cwd_relative = b.fmt("{s}/{s}", .{ build_root, input }) });
    // Header comparisons are generation inputs, not merely clang inputs: a
    // changed external ABI must invalidate generation before any owned object
    // can be linked. Resolve against the selected unified source, including
    // absolute includes used by isolated build fixtures.
    const io = std.Io.Threaded.global_single_threaded.io();
    for ([_][3][]const u8{
        .{ "UnifiedSource-src_jsc_bindings-2.cpp", "JSStringDecoder.cpp", "JSStringDecoder.h" },
        .{ "UnifiedSource-src_jsc_bindings-2.cpp", "JSNodePerformanceHooksHistogram.cpp", "JSNodePerformanceHooksHistogram.h" },
        .{ "UnifiedSource-src_jsc_bindings-2.cpp", "JSNodePerformanceHooksHistogramConstructor.cpp", "JSNodePerformanceHooksHistogramConstructor.h" },
        .{ "UnifiedSource-src_jsc_bindings-2.cpp", "JSNodePerformanceHooksHistogramPrototype.cpp", "JSNodePerformanceHooksHistogramPrototype.h" },
        .{ "UnifiedSource-src_jsc_bindings-3.cpp", "ProcessBindingTTYWrap.cpp", "ProcessBindingTTYWrap.h" },
        .{ "UnifiedSource-src_jsc_bindings-3.cpp", "NodeVM.cpp", "NodeVM.h" },
        .{ "UnifiedSource-src_jsc_bindings-3.cpp", "NodeFetch.cpp", "NodeFetch.h" },
        .{ "UnifiedSource-src_jsc_bindings-4.cpp", "Undici.cpp", "Undici.h" },
        .{ "UnifiedSource-src_jsc_bindings_webcore-0.cpp", "EventTarget.cpp", "EventTarget.h" },
        .{ "UnifiedSource-src_jsc_bindings_webcore-2.cpp", "JSEventTarget.cpp", "JSEventTarget.h" },
        .{ "UnifiedSource-src_jsc_bindings_webcore-4.cpp", "RegisteredEventListener.cpp", "RegisteredEventListener.h" },

        .{ "UnifiedSource-src_jsc_bindings-3.cpp", "NodeVMModule.cpp", "NodeVMModule.h" },
        .{ "UnifiedSource-src_jsc_bindings-3.cpp", "NodeVMScript.cpp", "NodeVMScript.h" },
        .{ "UnifiedSource-src_jsc_bindings-3.cpp", "NodeVMSourceTextModule.cpp", "NodeVMSourceTextModule.h" },
        .{ "UnifiedSource-src_jsc_bindings-3.cpp", "NodeVMSyntheticModule.cpp", "NodeVMSyntheticModule.h" },
        .{ "UnifiedSource-src_jsc_bindings-2.cpp", "JSInspectorProfiler.cpp", "JSInspectorProfiler.h" },
        .{ "UnifiedSource-src_jsc_bindings-2.cpp", "JSFFIFunction.cpp", "JSFFIFunction.h" },

        .{ "UnifiedSource-src_jsc_bindings-3.cpp", "NodeAsyncHooks.cpp", "NodeAsyncHooks.h" },
        .{ "UnifiedSource-src_jsc_bindings-3.cpp", "Path.cpp", "Path.h" },
        .{ "UnifiedSource-src_jsc_bindings-3.cpp", "NodeValidator.cpp", "NodeValidator.h" },
        .{ "UnifiedSource-src_jsc_bindings-3.cpp", "NodeHTTP.cpp", "NodeHTTP.h" },
        .{ "UnifiedSource-src_jsc_bindings-3.cpp", "NodeTLS.cpp", "NodeTLS.h" },
        .{ "UnifiedSource-src_jsc_bindings-5.cpp", "stringWidth.cpp", "stringWidth.h" },
        .{ "UnifiedSource-src_jsc_bindings-5.cpp", "sliceAnsi.cpp", "sliceAnsi.h" },
        .{ "UnifiedSource-src_jsc_bindings-5.cpp", "stripANSI.cpp", "stripANSI.h" },
        .{ "UnifiedSource-src_jsc_bindings-5.cpp", "wrapAnsi.cpp", "wrapAnsi.h" },
        .{ "UnifiedSource-src_jsc_bindings-5.cpp", "napi_finalizer.cpp", "napi_finalizer.h" },

        .{ "UnifiedSource-src_jsc_modules-0.cpp", "NodeUtilTypesModule.cpp", "NodeUtilTypesModule.h" },
        .{ "UnifiedSource-src_jsc_bindings_webcore-2.cpp", "JSMIMEParams.cpp", "JSMIMEParams.h" },
        .{ "UnifiedSource-src_jsc_bindings_webcore-3.cpp", "JSWebSocket.cpp", "JSWebSocket.h" },
        .{ "UnifiedSource-src_jsc_bindings_webcore-5.cpp", "WebSocket.cpp", "WebSocket.h" },
        .{ "UnifiedSource-src_jsc_bindings-0.cpp", "AsyncContextFrame.cpp", "AsyncContextFrame.h" },
        .{ "UnifiedSource-src_jsc_bindings_webcore-0.cpp", "BroadcastChannel.cpp", "BroadcastChannel.h" },
        .{ "UnifiedSource-src_jsc_bindings_webcore-0.cpp", "BunBroadcastChannelRegistry.cpp", "BunBroadcastChannelRegistry.h" },
        .{ "UnifiedSource-src_jsc_bindings_webcore-1.cpp", "JSBroadcastChannel.cpp", "JSBroadcastChannel.h" },
        .{ "UnifiedSource-src_jsc_bindings_webcore-3.cpp", "MessageEvent.cpp", "MessageEvent.h" },
        .{ "UnifiedSource-src_jsc_bindings_webcore-2.cpp", "JSMessageEvent.cpp", "JSMessageEvent.h" },
        .{ "UnifiedSource-src_jsc_bindings_webcore-1.cpp", "JSAbortSignalCustom.cpp", "AbortSignal.h" },
        .{ "UnifiedSource-src_jsc_bindings_webcore-3.cpp", "MessagePort.cpp", "MessagePort.h" },
        .{ "UnifiedSource-src_jsc_bindings_webcore-3.cpp", "JSWorker.cpp", "JSWorker.h" },
        .{ "UnifiedSource-src_jsc_bindings_webcore-4.cpp", "MessagePortPipe.cpp", "MessagePortPipe.h" },
        .{ "UnifiedSource-src_jsc_bindings_webcore-5.cpp", "Worker.cpp", "Worker.h" },
        .{ "UnifiedSource-src_jsc_bindings-0.cpp", "BunWorkerGlobalScope.cpp", "BunWorkerGlobalScope.h" },
        .{ "UnifiedSource-src_jsc_bindings-0.cpp", "BunAnalyzeTranspiledModule.cpp", "BunAnalyzeTranspiledModule.h" },
        .{ "UnifiedSource-src_jsc_bindings_webcore-2.cpp", "JSMessagePort.cpp", "JSMessagePort.h" },
    }) |entry| {
        const unified_path = b.fmt("{s}/unified/{s}", .{ build_root, entry[0] });
        const unified = std.Io.Dir.cwd().readFileAlloc(io, unified_path, b.allocator, .limited(1024 * 1024)) catch |err|
            std.debug.panic("cannot read native unified source {s}: {s}", .{ unified_path, @errorName(err) });
        defer b.allocator.free(unified);
        const source = unifiedSourcePath(b.allocator, unified, unified_path, entry[1]) catch |err|
            std.debug.panic("invalid native unified source {s}: {s}", .{ unified_path, @errorName(err) });
        defer b.allocator.free(source);
        const header = b.fmt("{s}/{s}", .{ std.fs.path.dirname(source).?, entry[2] });
        generate.addFileInput(.{ .cwd_relative = header });
    }
    const modules_unity = b.fmt("{s}/unified/UnifiedSource-src_jsc_modules-0.cpp", .{build_root});
    const modules_source = std.Io.Dir.cwd().readFileAlloc(io, modules_unity, b.allocator, .limited(1024 * 1024)) catch @panic("cannot read native module unity");
    defer b.allocator.free(modules_source);
    const module_source = unifiedSourcePath(b.allocator, modules_source, modules_unity, "NodeModuleModule.cpp") catch @panic("cannot locate native module source");
    defer b.allocator.free(module_source);
    const sqlite_header = std.fs.path.resolve(b.allocator, &.{ std.fs.path.dirname(module_source).?, "../bindings/sqlite/JSSQLStatement.h" }) catch @panic("OOM");
    defer b.allocator.free(sqlite_header);
    generate.addFileInput(.{ .cwd_relative = sqlite_header });
    cached_native_modules = output;
    return output;
}

fn unifiedSourcePath(allocator: std.mem.Allocator, unified: []const u8, unified_path: []const u8, basename: []const u8) ![]const u8 {
    var selected: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, unified, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, "#include \"") or !std.mem.endsWith(u8, trimmed, "\"")) continue;
        const included = trimmed[10 .. trimmed.len - 1];
        if (!std.mem.eql(u8, std.fs.path.basename(included), basename)) continue;
        if (selected != null) return error.DuplicateOwnedSource;
        selected = included;
    }
    const included = selected orelse return error.MissingOwnedSource;
    return std.fs.path.resolve(allocator, &.{ std.fs.path.dirname(unified_path) orelse return error.InvalidUnifiedPath, included });
}

test "owned unified source resolves selected relative and absolute header roots" {
    const relative = try unifiedSourcePath(std.testing.allocator, "#include \"../../../src/OtherMessagePortPipe.cpp\"\n#include \"../../../src/webcore/MessagePortPipe.cpp\"\n", "/bun/build/release/unified/unit.cpp", "MessagePortPipe.cpp");
    defer std.testing.allocator.free(relative);
    try std.testing.expectEqualStrings("/bun/src/webcore/MessagePortPipe.cpp", relative);
    const absolute = try unifiedSourcePath(std.testing.allocator, "#include \"/fixture/webcore/MessagePort.cpp\"\r\n", "/fixture/build/unified/unit.cpp", "MessagePort.cpp");
    defer std.testing.allocator.free(absolute);
    try std.testing.expectEqualStrings("/fixture/webcore/MessagePort.cpp", absolute);
    try std.testing.expectError(error.MissingOwnedSource, unifiedSourcePath(std.testing.allocator, "#include \"OtherMessagePort.cpp\"\n", "/build/unit.cpp", "MessagePort.cpp"));
    try std.testing.expectError(error.DuplicateOwnedSource, unifiedSourcePath(std.testing.allocator, "#include \"MessagePort.cpp\"\n#include \"other/MessagePort.cpp\"\n", "/build/unit.cpp", "MessagePort.cpp"));
}

fn compileObject(b: *std.Build, object_root: []const u8, basename: []const u8, source: std.Build.LazyPath) std.Build.LazyPath {
    const io = std.Io.Threaded.global_single_threaded.io();
    const build_root = std.fs.path.dirname(object_root) orelse
        std.debug.panic("invalid HOME_BUN_OBJ_ROOT: {s}", .{object_root});
    const database_path = b.fmt("{s}/compile_commands.json", .{build_root});
    const database = std.Io.Dir.cwd().readFileAlloc(io, database_path, b.allocator, .limited(16 * 1024 * 1024)) catch |err|
        std.debug.panic("Home-owned {s} requires {s}: {s}", .{ basename, database_path, @errorName(err) });
    defer b.allocator.free(database);
    const parsed = std.json.parseFromSlice([]CompileCommand, b.allocator, database, .{
        .ignore_unknown_fields = true,
    }) catch |err| std.debug.panic("invalid native compile database {s}: {s}", .{ database_path, @errorName(err) });
    defer parsed.deinit();

    const command = findCommand(parsed.value, basename) orelse
        std.debug.panic("no {s} command in {s}", .{ basename, database_path });
    if (command.arguments.len == 0) std.debug.panic("empty native compile command in {s}", .{database_path});
    if ((std.mem.eql(u8, basename, "UnifiedSource-src_jsc_bindings-1.cpp") or std.mem.eql(u8, basename, "WebCoreJSBuiltins.cpp")) and hasDynamicBuiltinLoading(command.arguments)) {
        std.debug.panic("Home-owned builtin modules require embedded native artifacts; BUN_DYNAMIC_JS_LOAD_PATH would bypass Home's generated literals", .{});
    }
    const process_command = findCommand(parsed.value, "BunProcess.cpp") orelse
        std.debug.panic("no BunProcess.cpp command for native header root in {s}", .{database_path});

    // Copy only the implementation into the build cache. Its quoted includes
    // must resolve against the ABI-matched upstream header set, not another
    // version of those headers beside Home's mirrored source.
    const compiler = nativeCompiler(b, build_root, command.arguments[0]);
    const compile = b.addSystemCommand(&.{compiler});
    compile.addFileInput(.{ .cwd_relative = compiler });
    compile.setName(b.fmt("compile Home {s} binding", .{basename}));
    compile.setCwd(.{ .cwd_relative = command.directory });
    compile.addFileInput(.{ .cwd_relative = database_path });
    if (std.mem.eql(u8, basename, "napi.cpp")) {
        // The plain-context corpus adapter has a separate environment ABI.
        // Its public entry points dispatch real NapiEnv values here before
        // touching the adapter layout. Do not weaken either implementation.
        for ([_][]const u8{
            "napi_create_external", "napi_create_function",    "napi_create_object",
            "napi_get_cb_info",     "napi_get_value_bool",     "napi_get_value_external",
            "napi_module_register", "napi_set_named_property", "napi_throw_error",
        }) |symbol| compile.addArg(b.fmt("-D{s}=HomeNative_{s}", .{ symbol, symbol }));
    }

    var i: usize = 1;
    while (i < command.arguments.len) : (i += 1) {
        const arg = command.arguments[i];
        if (std.mem.eql(u8, arg, command.file) or std.mem.eql(u8, arg, "-c")) continue;
        if (isOutputOption(arg)) {
            if (i + 1 >= command.arguments.len) std.debug.panic("missing value after {s} in native compile command", .{arg});
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "-MD") or std.mem.eql(u8, arg, "-MMD") or std.mem.eql(u8, arg, "-MP")) continue;
        if (std.mem.eql(u8, arg, "-include-pch")) {
            if (i + 1 >= command.arguments.len) std.debug.panic("missing native precompiled header path", .{});
            i += 1;
            // A saved PCH can belong to a different compiler version than the
            // compile database. Parse its source header instead; the depfile
            // below tracks all transitively included headers for caching.
            compile.addArg("-include");
            const source_dir = std.fs.path.dirname(process_command.file) orelse
                std.debug.panic("BunProcess source path has no directory", .{});
            compile.addFileArg2(.{ .cwd_relative = b.fmt("{s}/root-pch.h", .{source_dir}) }, .{ .make_absolute = true });
            continue;
        }
        const normalized = normalizeDefine(b.allocator, arg) catch @panic("OOM");
        defer b.allocator.free(normalized);
        compile.addArg(normalized);
    }
    compile.addArg("-c");
    // Depfile paths are consumed by Zig from Home's build directory, whereas
    // clang runs in the upstream build directory. Emit absolute inputs so
    // both agree on their meaning.
    compile.addFileArg2(source, .{ .make_absolute = true });
    compile.addArg("-o");
    const object = compile.addOutputFileArg2(b.fmt("{s}.o", .{basename}), .{ .make_absolute = true });
    compile.addArgs(&.{ "-MD", "-MF" });
    _ = compile.addDepFileOutputArg2(b.fmt("{s}.d", .{basename}), .{ .make_absolute = true });
    return object;
}

fn nativeCompiler(b: *std.Build, build_root: []const u8, fallback: []const u8) []const u8 {
    // Bun's compile database can record /usr/bin/clang++ even when its object
    // graph and PCH were produced by the pinned LLVM toolchain in pantry. A
    // different C++ compiler can disagree on ABI details for non-trivial return
    // values crossing between Home-owned and Bun-owned objects.
    const bun_root = std.fs.path.dirname(std.fs.path.dirname(build_root) orelse return fallback) orelse return fallback;
    const candidate = b.fmt("{s}/pantry/llvm.org/v21.1.8/bin/clang++", .{bun_root});
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().access(io, candidate, .{}) catch return fallback;
    return candidate;
}

fn findCommand(commands: []const CompileCommand, basename: []const u8) ?CompileCommand {
    for (commands) |command| {
        if (std.mem.eql(u8, std.fs.path.basename(command.file), basename)) return command;
    }
    return null;
}

fn isOutputOption(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "-MF") or
        std.mem.eql(u8, arg, "-MT") or std.mem.eql(u8, arg, "-MQ");
}

fn hasDynamicBuiltinLoading(arguments: []const []const u8) bool {
    for (arguments, 0..) |arg, i| {
        const define = if (std.mem.startsWith(u8, arg, "-D")) arg[2..] else if (i > 0 and std.mem.eql(u8, arguments[i - 1], "-D")) arg else continue;
        if (std.mem.eql(u8, define, "BUN_DYNAMIC_JS_LOAD_PATH") or std.mem.startsWith(u8, define, "BUN_DYNAMIC_JS_LOAD_PATH=")) return true;
    }
    return false;
}

test "owned builtin binding rejects dynamic external source loading" {
    try std.testing.expect(hasDynamicBuiltinLoading(&.{"-DBUN_DYNAMIC_JS_LOAD_PATH=\"/external/js\""}));
    try std.testing.expect(hasDynamicBuiltinLoading(&.{ "-D", "BUN_DYNAMIC_JS_LOAD_PATH=/external/js" }));
    try std.testing.expect(hasDynamicBuiltinLoading(&.{"-DBUN_DYNAMIC_JS_LOAD_PATH"}));
    try std.testing.expect(!hasDynamicBuiltinLoading(&.{ "-DNDEBUG", "-DBUN_DYNAMIC_JS_LOAD_PATH_OTHER=1" }));
}

/// Bun's compile database can retain shell escaping around string-valued
/// definitions. Run executes argv directly (no shell), so remove only the
/// backslashes immediately preceding quotes in -D arguments.
fn normalizeDefine(allocator: std.mem.Allocator, arg: []const u8) ![]u8 {
    if (!std.mem.startsWith(u8, arg, "-D")) return allocator.dupe(u8, arg);
    var normalized: std.ArrayList(u8) = .empty;
    errdefer normalized.deinit(allocator);
    var i: usize = 0;
    while (i < arg.len) {
        if (arg[i] == '\\') {
            var end = i;
            while (end < arg.len and arg[end] == '\\') : (end += 1) {}
            if (end < arg.len and arg[end] == '"') {
                try normalized.append(allocator, '"');
                i = end + 1;
                continue;
            }
        }
        try normalized.append(allocator, arg[i]);
        i += 1;
    }
    return normalized.toOwnedSlice(allocator);
}

test "native binding selects only the process implementation" {
    const commands = [_]CompileCommand{
        .{ .directory = "/build", .file = "/src/OtherBunProcess.cpp", .arguments = &.{} },
        .{ .directory = "/build", .file = "/src/BunProcess.cpp", .arguments = &.{"clang++"} },
    };
    try std.testing.expectEqualStrings("/src/BunProcess.cpp", findCommand(&commands, "BunProcess.cpp").?.file);
    try std.testing.expect(findCommand(commands[0..1], "BunProcess.cpp") == null);
    try std.testing.expect(isOutputOption("-o"));
    try std.testing.expect(isOutputOption("-MF"));
    try std.testing.expect(!isOutputOption("-O3"));
}

test "native binding normalizes shell-escaped definitions without changing paths" {
    const cases = .{
        .{ "-DVERSION=\\\"1.2.3\\\"", "-DVERSION=\"1.2.3\"" },
        .{ "-DVERSION=\\\\\\\"1.2.3\\\\\\\"", "-DVERSION=\"1.2.3\"" },
        .{ "-DVERSION=\"1.2.3\"", "-DVERSION=\"1.2.3\"" },
        .{ "-DCOUNT=147", "-DCOUNT=147" },
        .{ "-IC:\\headers\\include", "-IC:\\headers\\include" },
        .{ "-DPATH=C:\\headers", "-DPATH=C:\\headers" },
    };
    inline for (cases) |pair| {
        const result = try normalizeDefine(std.testing.allocator, pair[0]);
        defer std.testing.allocator.free(result);
        try std.testing.expectEqualStrings(pair[1], result);
    }
}
