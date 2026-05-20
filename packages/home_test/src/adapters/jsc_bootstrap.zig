const std = @import("std");
const home_rt = @import("home_rt");
const runner = @import("../runner.zig");

const Io = std.Io;

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
        cleanupServeHandles();
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
    }

    fn resetFileState(self: *Runtime, allocator: std.mem.Allocator) !void {
        cleanupServeHandles();
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

        const evaluation = try home_rt.jsc.evaluate.evaluateUtf8Detailed(
            allocator,
            self.engine.currentContext(),
            spec.source,
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

        const counters = self.readCounters(allocator) catch |err| {
            return runner.FileRun.failBorrowed(spec.path, @errorName(err));
        };
        if (counters.pending != 0) {
            return runner.FileRun.unsupportedBorrowed(spec.path, "pending async test promise requires event-loop support");
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

const ServeHandle = struct {
    id: usize,
    dev: home_rt.runtime.bake.DevServer,
    server: home_rt.runtime.server.Server,
    server_config: ?home_rt.runtime.server.ServerConfig.ServerConfig = null,
    html_bundle: ?home_rt.runtime.server.HTMLBundle.HTMLBundle = null,
    html_route: ?home_rt.runtime.server.HTMLBundle.Route = null,
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
    const actual_ctx = ctx.?;

    if (argument_count < 1 or arguments[0] == null) {
        setException(actual_ctx, exception, "Bun.serve() requires an options object");
        return null;
    }

    const allocator = std.heap.smp_allocator;
    const options = extern_fns.JSValueToObject(actual_ctx, arguments[0], exception) orelse return null;
    var serve_shape = validateBakeHtmlServeOptions(allocator, actual_ctx, options, exception) catch |err| {
        if (err == error.NativeException) return null;
        setExceptionFmt(actual_ctx, exception, "Bun.serve() failed: {s}", .{@errorName(err)});
        return null;
    };
    defer serve_shape.deinit(allocator);

    const handle = allocator.create(ServeHandle) catch {
        setException(actual_ctx, exception, "Bun.serve() failed: OutOfMemory");
        return null;
    };
    errdefer allocator.destroy(handle);

    const id = next_serve_id;
    next_serve_id +|= 1;
    handle.* = .{
        .id = id,
        .dev = home_rt.runtime.bake.DevServer.init(allocator),
        .server = home_rt.runtime.server.Server.init(),
    };
    errdefer handle.dev.deinit();
    handle.server.listener_active = true;
    handle.server.attachDevServer(&handle.dev);

    handle.html_bundle = home_rt.runtime.server.HTMLBundle.HTMLBundle.init(allocator, serve_shape.html_path) catch {
        setException(actual_ctx, exception, "Bun.serve() failed: OutOfMemory");
        return null;
    };
    errdefer handle.html_bundle.?.deinit();

    handle.html_route = handle.html_bundle.?.route();
    errdefer handle.html_route.?.deinit(allocator);

    handle.server_config = home_rt.runtime.server.ServerConfig.ServerConfig.init(allocator);
    handle.server_config.?.appendHTMLRoute(serve_shape.route_path, &handle.html_route.?) catch {
        setException(actual_ctx, exception, "Bun.serve() failed: OutOfMemory");
        return null;
    };
    home_rt.runtime.server.server_module.applyHTMLRouteToDevServer(&handle.dev, serve_shape.route_path, &handle.html_route.?) catch {
        setException(actual_ctx, exception, "Bun.serve() failed: OutOfMemory");
        return null;
    };

    serve_handles.put(allocator, id, handle) catch {
        setException(actual_ctx, exception, "Bun.serve() failed: OutOfMemory");
        return null;
    };
    return makeServeHandleResult(actual_ctx, id) catch |err| {
        _ = serve_handles.remove(id);
        handle.dev.deinit();
        allocator.destroy(handle);
        setExceptionFmt(actual_ctx, exception, "Bun.serve() failed: {s}", .{@errorName(err)});
        return null;
    };
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
        handle.server.beginRequest();
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
        handle.server.endRequest();
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
    const actual_ctx = ctx.?;
    if (argument_count < 3 or arguments[0] == null or arguments[1] == null or arguments[2] == null) {
        setException(actual_ctx, exception, "Bake static client script requires html, script, and bunfig inputs");
        return null;
    }

    const allocator = std.heap.smp_allocator;
    const has_script_path = argument_count >= 4 and arguments[3] != null;
    const html = valueToOwnedString(allocator, actual_ctx, arguments[0].?, exception) catch {
        setException(actual_ctx, exception, "Bake static client script failed to read html");
        return null;
    };
    defer allocator.free(html);
    const script_path = if (has_script_path)
        valueToOwnedString(allocator, actual_ctx, arguments[1].?, exception) catch {
            setException(actual_ctx, exception, "Bake static client script failed to read script path");
            return null;
        }
    else
        allocator.dupe(u8, "index.ts") catch {
            setException(actual_ctx, exception, "Bake static client script failed to index default script path");
            return null;
        };
    defer allocator.free(script_path);
    const script_source_argument = if (has_script_path) arguments[2].? else arguments[1].?;
    const script = valueToOwnedString(allocator, actual_ctx, script_source_argument, exception) catch {
        setException(actual_ctx, exception, "Bake static client script failed to read script");
        return null;
    };
    defer allocator.free(script);
    const bunfig_argument = if (has_script_path) arguments[3].? else arguments[2].?;
    const bunfig = valueToOwnedString(allocator, actual_ctx, bunfig_argument, exception) catch {
        setException(actual_ctx, exception, "Bake static client script failed to read bunfig");
        return null;
    };
    defer allocator.free(bunfig);

    var refs = home_rt.runtime.server.HTMLBundle.References.parse(allocator, html) catch {
        setException(actual_ctx, exception, "Bake static client script failed to parse html");
        return null;
    };
    defer refs.deinit(allocator);

    var files = std.StringHashMap([]const u8).init(allocator);
    defer files.deinit();
    files.put(script_path, script) catch {
        setException(actual_ctx, exception, "Bake static client script failed to index script");
        return null;
    };

    var define: home_rt.runtime.bake.DefineMap = .{};
    defer define.deinit(allocator);
    home_rt.runtime.bake.parseServeStaticDefineFromBunfig(allocator, bunfig, &define) catch {
        setException(actual_ctx, exception, "Bake static client script failed to parse serve.static.define");
        return null;
    };

    const output = home_rt.runtime.server.HTMLBundle.buildClientScript(allocator, &refs, &files, &define) catch {
        setException(actual_ctx, exception, "Bake static client script failed to build");
        return null;
    };
    defer allocator.free(output);

    return makeStringValue(actual_ctx, output) catch {
        setException(actual_ctx, exception, "Bake static client script failed to return output");
        return null;
    };
}

fn serveIdFromArguments(ctx: *JSContextRef, argument_count: usize, arguments: [*c]const ?*JSValue) ?usize {
    if (argument_count < 1 or arguments[0] == null) return null;
    const id_number = extern_fns.JSValueToNumber(ctx, arguments[0], null);
    if (!std.math.isFinite(id_number) or id_number < 0 or @floor(id_number) != id_number) return null;
    return @intFromFloat(id_number);
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
    const handle = serve_handles.get(id) orelse return;
    handle.server.stopListening(abrupt);
    destroyStoppedServeHandleIfIdle(id, handle);
}

fn destroyStoppedServeHandleIfIdle(id: usize, handle: *ServeHandle) void {
    if (handle.server.dev_server != null or handle.server.pending_requests != 0) return;
    _ = serve_handles.remove(id);
    deinitHmrSockets(handle);
    handle.hmr_sockets.deinit(std.heap.smp_allocator);
    deinitServeHandleCarriers(handle);
    std.heap.smp_allocator.destroy(handle);
}

fn destroyServeHandle(id: usize, abrupt: bool) void {
    const allocator = std.heap.smp_allocator;
    const handle = serve_handles.fetchRemove(id) orelse return;
    handle.value.server.stopListening(abrupt);
    deinitHmrSockets(handle.value);
    handle.value.hmr_sockets.deinit(allocator);
    deinitServeHandleCarriers(handle.value);
    allocator.destroy(handle.value);
}

fn deinitServeHandleCarriers(handle: *ServeHandle) void {
    const allocator = std.heap.smp_allocator;
    if (handle.server_config) |*config| {
        config.deinit();
        handle.server_config = null;
    }
    if (handle.html_route) |*route| {
        route.deinit(allocator);
        handle.html_route = null;
    }
    if (handle.html_bundle) |*bundle| {
        bundle.deinit();
        handle.html_bundle = null;
    }
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

    if (std.mem.eql(u8, argv_storage.items[0], "home")) {
        const self_path = try selfExePathAlloc(allocator);
        allocator.free(argv_storage.items[0]);
        argv_storage.items[0] = self_path;
    }
    try resolveCorpusArguments(allocator, &argv_storage);

    const cwd_raw = try readOptionalStringProperty(allocator, ctx, options, "cwd", exception);
    defer if (cwd_raw) |path| allocator.free(path);
    const cwd = try resolveSpawnCwd(allocator, cwd_raw);
    defer if (cwd.owned) allocator.free(cwd.path.?);

    const stdio = try readStdio(ctx, options, exception);

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

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

fn setExceptionFmt(ctx: *JSContextRef, exception: extern_fns.ExceptionRef, comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const message = std.fmt.bufPrint(&buf, fmt, args) catch "Bun.spawnSync() failed";
    setException(ctx, exception, message);
}

fn selfExePathAlloc(allocator: std.mem.Allocator) ![]u8 {
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

test "adapter recognizes HomeUnsupported exceptions" {
    try std.testing.expectEqualStrings("Async tests are not supported", unsupportedExceptionReason("HomeUnsupportedError: __home_unsupported__:Async tests are not supported").?);
    try std.testing.expectEqualStrings("Only Buffer.from is supported", unsupportedExceptionReason("Exception: HomeUnsupportedError: __home_unsupported__:Only Buffer.from is supported").?);
    try std.testing.expect(unsupportedExceptionReason("HomeUnsupportedError: assertion failed") == null);
    try std.testing.expect(unsupportedExceptionReason("Error: __home_unsupported__:assertion failed") == null);
    try std.testing.expect(unsupportedExceptionReason("Error: assertion failed") == null);
}
