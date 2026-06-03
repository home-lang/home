// Copied/adapted from Bun (https://github.com/oven-sh/bun) — MIT-licensed.
// Original: src/runtime/server/server.zig
// See LICENSE.bun.md for full license text.
//
// Lifetime-only subset. Bun's full server owns uWS apps, request contexts,
// WebSocket contexts, JS bindings, TLS state, and static route handlers. This
// Home carrier preserves the DevServer teardown gate used by Bake: the server
// may detach and deinit its Bake DevServer only after no requests, listener,
// or active websockets remain.

const std = @import("std");
const bake = @import("../bake/bake.zig");
pub const HTMLBundleModule = @import("HTMLBundle.zig");
pub const HTMLBundle = HTMLBundleModule.HTMLBundle;

const bun = @import("home");
const jsc = bun.jsc;

pub const ServerJSStub = struct {
    js_value: jsc.Strong.Optional = .empty,

    pub const js = struct {
        pub fn routeListSetCached(_: jsc.JSValue, _: *jsc.JSGlobalObject, _: jsc.JSValue) void {}
    };

    pub fn init(_: *ServerConfig, _: *jsc.JSGlobalObject) !*ServerJSStub {
        return bun.new(ServerJSStub, .{});
    }

    pub fn listen(_: *ServerJSStub) jsc.JSValue {
        return .zero;
    }

    pub fn toJS(_: *ServerJSStub, _: *jsc.JSGlobalObject) jsc.JSValue {
        return .zero;
    }

    pub fn onReloadFromZig(_: *ServerJSStub, _: *ServerConfig, _: *jsc.JSGlobalObject) void {}

    pub fn memoryCost(_: *ServerJSStub) usize {
        return @sizeOf(ServerJSStub);
    }

    pub fn finalize(_: *ServerJSStub) void {}

    pub fn dispose(_: *ServerJSStub, _: *jsc.JSGlobalObject, _: *jsc.CallFrame) jsc.JSValue {
        return .zero;
    }

    pub fn getAddress(_: *ServerJSStub, _: *jsc.JSGlobalObject) jsc.JSValue {
        return .zero;
    }

    pub fn closeIdleConnections(_: *ServerJSStub, _: *jsc.JSGlobalObject, _: *jsc.CallFrame) jsc.JSValue {
        return .zero;
    }

    pub fn getDevelopment(_: *ServerJSStub, _: *jsc.JSGlobalObject) jsc.JSValue {
        return .zero;
    }

    pub fn doFetch(_: *ServerJSStub, _: *jsc.JSGlobalObject, _: *jsc.CallFrame) jsc.JSValue {
        return .zero;
    }

    pub fn getHostname(_: *ServerJSStub, _: *jsc.JSGlobalObject) jsc.JSValue {
        return .zero;
    }

    pub fn getId(_: *ServerJSStub, _: *jsc.JSGlobalObject) jsc.JSValue {
        return .zero;
    }

    pub fn getPendingRequests(_: *ServerJSStub, _: *jsc.JSGlobalObject) jsc.JSValue {
        return .zero;
    }

    pub fn getPendingWebSockets(_: *ServerJSStub, _: *jsc.JSGlobalObject) jsc.JSValue {
        return .zero;
    }

    pub fn getPort(_: *ServerJSStub, _: *jsc.JSGlobalObject) jsc.JSValue {
        return .zero;
    }

    pub fn getProtocol(_: *ServerJSStub, _: *jsc.JSGlobalObject) jsc.JSValue {
        return .zero;
    }

    pub fn doPublish(_: *ServerJSStub, _: *jsc.JSGlobalObject, _: *jsc.CallFrame) jsc.JSValue {
        return .zero;
    }

    pub fn doRef(_: *ServerJSStub, _: *jsc.JSGlobalObject, _: *jsc.CallFrame) jsc.JSValue {
        return .zero;
    }

    pub fn doReload(_: *ServerJSStub, _: *jsc.JSGlobalObject, _: *jsc.CallFrame) jsc.JSValue {
        return .zero;
    }

    pub fn doRequestIP(_: *ServerJSStub, _: *jsc.JSGlobalObject, _: *jsc.CallFrame) jsc.JSValue {
        return .zero;
    }

    pub fn doStop(_: *ServerJSStub, _: *jsc.JSGlobalObject, _: *jsc.CallFrame) jsc.JSValue {
        return .zero;
    }

    pub fn doSubscriberCount(_: *ServerJSStub, _: *jsc.JSGlobalObject, _: *jsc.CallFrame) jsc.JSValue {
        return .zero;
    }

    pub fn doTimeout(_: *ServerJSStub, _: *jsc.JSGlobalObject, _: *jsc.CallFrame) jsc.JSValue {
        return .zero;
    }

    pub fn doUnref(_: *ServerJSStub, _: *jsc.JSGlobalObject, _: *jsc.CallFrame) jsc.JSValue {
        return .zero;
    }

    pub fn doUpgrade(_: *ServerJSStub, _: *jsc.JSGlobalObject, _: *jsc.CallFrame) jsc.JSValue {
        return .zero;
    }

    pub fn getURL(_: *ServerJSStub, _: *jsc.JSGlobalObject) jsc.JSValue {
        return .zero;
    }
};

pub const DebugHTTPSServer = ServerJSStub;
pub const DebugHTTPServer = ServerJSStub;
pub const HTTPSServer = ServerJSStub;
pub const HTTPServer = ServerJSStub;
pub const AnyServer = ServerJSStub;
pub const AnyRequestContext = struct {
    pub const AdditionalOnAbortCallback = @import("./RequestContext.zig").AdditionalOnAbortCallback;
    pub const Null: AnyRequestContext = .{};

    pub fn init(_: anytype) AnyRequestContext {
        return .{};
    }

    pub fn setAdditionalOnAbortCallback(_: AnyRequestContext, _: ?AdditionalOnAbortCallback) void {}
    pub fn memoryCost(_: AnyRequestContext) usize {
        return 0;
    }
    pub fn get(_: AnyRequestContext, comptime T: type) ?*T {
        return null;
    }
    pub fn setTimeout(_: AnyRequestContext, _: c_uint) bool {
        return false;
    }
    pub fn setCookies(_: AnyRequestContext, _: ?*jsc.WebCore.CookieMap) void {}
    pub fn enableTimeoutEvents(_: AnyRequestContext) void {}
    pub fn getRemoteSocketInfo(_: AnyRequestContext) ?bun.uws.SocketAddress {
        return null;
    }
    pub fn detachRequest(_: AnyRequestContext) void {}
    pub fn setRequest(_: AnyRequestContext, _: *bun.uws.Request) void {}
    pub fn getRequest(_: AnyRequestContext) ?*bun.uws.Request {
        return null;
    }
    pub fn onAbort(_: AnyRequestContext, _: bun.uws.AnyResponse) void {}
    pub fn ref(_: AnyRequestContext) void {}
    pub fn setSignalAborted(_: AnyRequestContext, _: jsc.CommonAbortReason) void {}
    pub fn devServer(_: AnyRequestContext) ?*bun.bake.DevServer {
        return null;
    }
    pub fn deref(_: AnyRequestContext) void {}
};
pub const NodeHTTPResponse = struct {
    pub fn finalize(_: *NodeHTTPResponse) void {}
    pub fn abort(_: *NodeHTTPResponse, _: *jsc.JSGlobalObject, _: *jsc.CallFrame) jsc.JSValue { return .zero; }
    pub fn cork(_: *NodeHTTPResponse, _: *jsc.JSGlobalObject, _: *jsc.CallFrame) jsc.JSValue { return .zero; }
    pub fn drainRequestBody(_: *NodeHTTPResponse, _: *jsc.JSGlobalObject, _: *jsc.CallFrame) jsc.JSValue { return .zero; }
    pub fn dumpRequestBody(_: *NodeHTTPResponse, _: *jsc.JSGlobalObject, _: *jsc.CallFrame, _: jsc.JSValue) jsc.JSValue { return .zero; }
    pub fn end(_: *NodeHTTPResponse, _: *jsc.JSGlobalObject, _: *jsc.CallFrame) jsc.JSValue { return .zero; }
    pub fn flushHeaders(_: *NodeHTTPResponse, _: *jsc.JSGlobalObject, _: *jsc.CallFrame) jsc.JSValue { return .zero; }
    pub fn getBytesWritten(_: *NodeHTTPResponse, _: *jsc.JSGlobalObject, _: *jsc.CallFrame) jsc.JSValue { return .zero; }
    pub fn doPause(_: *NodeHTTPResponse, _: *jsc.JSGlobalObject, _: *jsc.CallFrame, _: jsc.JSValue) jsc.JSValue { return .zero; }
    pub fn jsRef(_: *NodeHTTPResponse, _: *jsc.JSGlobalObject, _: *jsc.CallFrame) jsc.JSValue { return .zero; }
    pub fn doResume(_: *NodeHTTPResponse, _: *jsc.JSGlobalObject, _: *jsc.CallFrame) jsc.JSValue { return .zero; }
    pub fn jsUnref(_: *NodeHTTPResponse, _: *jsc.JSGlobalObject, _: *jsc.CallFrame) jsc.JSValue { return .zero; }
    pub fn write(_: *NodeHTTPResponse, _: *jsc.JSGlobalObject, _: *jsc.CallFrame) jsc.JSValue { return .zero; }
    pub fn writeContinue(_: *NodeHTTPResponse, _: *jsc.JSGlobalObject, _: *jsc.CallFrame) jsc.JSValue { return .zero; }
    pub fn writeHead(_: *NodeHTTPResponse, _: *jsc.JSGlobalObject, _: *jsc.CallFrame) jsc.JSValue { return .zero; }

    pub fn getAborted(_: *NodeHTTPResponse, _: *jsc.JSGlobalObject) jsc.JSValue { return .zero; }
    pub fn getBufferedAmount(_: *NodeHTTPResponse, _: *jsc.JSGlobalObject) jsc.JSValue { return .zero; }
    pub fn getEnded(_: *NodeHTTPResponse, _: *jsc.JSGlobalObject) jsc.JSValue { return .zero; }
    pub fn getFinished(_: *NodeHTTPResponse, _: *jsc.JSGlobalObject) jsc.JSValue { return .zero; }
    pub fn getFlags(_: *NodeHTTPResponse, _: *jsc.JSGlobalObject) jsc.JSValue { return .zero; }
    pub fn getHasBody(_: *NodeHTTPResponse, _: *jsc.JSGlobalObject) jsc.JSValue { return .zero; }
    pub fn getHasCustomOnData(_: *NodeHTTPResponse, _: *jsc.JSGlobalObject) jsc.JSValue { return .zero; }
    pub fn getOnAbort(_: *NodeHTTPResponse, _: jsc.JSValue, _: *jsc.JSGlobalObject) jsc.JSValue { return .zero; }
    pub fn getOnData(_: *NodeHTTPResponse, _: jsc.JSValue, _: *jsc.JSGlobalObject) jsc.JSValue { return .zero; }
    pub fn getOnWritable(_: *NodeHTTPResponse, _: jsc.JSValue, _: *jsc.JSGlobalObject) jsc.JSValue { return .zero; }
    pub fn getUpgraded(_: *NodeHTTPResponse, _: *jsc.JSGlobalObject) jsc.JSValue { return .zero; }
    pub fn setHasCustomOnData(_: *NodeHTTPResponse, _: *jsc.JSGlobalObject, _: jsc.JSValue) void {}
    pub fn setOnAbort(_: *NodeHTTPResponse, _: jsc.JSValue, _: *jsc.JSGlobalObject, _: jsc.JSValue) void {}
    pub fn setOnData(_: *NodeHTTPResponse, _: jsc.JSValue, _: *jsc.JSGlobalObject, _: jsc.JSValue) void {}
    pub fn setOnWritable(_: *NodeHTTPResponse, _: jsc.JSValue, _: *jsc.JSGlobalObject, _: jsc.JSValue) void {}

    pub fn onAborted(_: *NodeHTTPResponse) void {}
    pub fn onData(_: *NodeHTTPResponse) void {}
    pub fn onWritable(_: *NodeHTTPResponse) void {}
};

pub const ServerWebSocket = struct {
    pub fn memoryCost(_: *ServerWebSocket) usize { return @sizeOf(ServerWebSocket); }
    pub fn finalize(_: *ServerWebSocket) void {}
    pub fn constructor(_: *jsc.JSGlobalObject, _: *jsc.CallFrame) bun.JSError!*ServerWebSocket { return error.OutOfMemory; }
    pub fn close(_: *ServerWebSocket, _: *jsc.JSGlobalObject, _: *jsc.CallFrame, _: jsc.JSValue) jsc.JSValue { return .zero; }
    pub fn cork(_: *ServerWebSocket, _: *jsc.JSGlobalObject, _: *jsc.CallFrame, _: jsc.JSValue) jsc.JSValue { return .zero; }
    pub fn isSubscribed(_: *ServerWebSocket, _: *jsc.JSGlobalObject, _: *jsc.CallFrame) jsc.JSValue { return .zero; }
    pub fn ping(_: *ServerWebSocket, _: *jsc.JSGlobalObject, _: *jsc.CallFrame) jsc.JSValue { return .zero; }
    pub fn pong(_: *ServerWebSocket, _: *jsc.JSGlobalObject, _: *jsc.CallFrame) jsc.JSValue { return .zero; }
    pub fn publish(_: *ServerWebSocket, _: *jsc.JSGlobalObject, _: *jsc.CallFrame) jsc.JSValue { return .zero; }
    pub fn publishBinary(_: *ServerWebSocket, _: *jsc.JSGlobalObject, _: *jsc.CallFrame) jsc.JSValue { return .zero; }
    pub fn publishText(_: *ServerWebSocket, _: *jsc.JSGlobalObject, _: *jsc.CallFrame) jsc.JSValue { return .zero; }
    pub fn remoteAddress(_: *ServerWebSocket, _: *jsc.JSGlobalObject, _: *jsc.CallFrame) jsc.JSValue { return .zero; }
    pub fn send(_: *ServerWebSocket, _: *jsc.JSGlobalObject, _: *jsc.CallFrame) jsc.JSValue { return .zero; }
    pub fn sendBinary(_: *ServerWebSocket, _: *jsc.JSGlobalObject, _: *jsc.CallFrame) jsc.JSValue { return .zero; }
    pub fn sendText(_: *ServerWebSocket, _: *jsc.JSGlobalObject, _: *jsc.CallFrame) jsc.JSValue { return .zero; }
    pub fn subscribe(_: *ServerWebSocket, _: *jsc.JSGlobalObject, _: *jsc.CallFrame) jsc.JSValue { return .zero; }
    pub fn terminate(_: *ServerWebSocket, _: *jsc.JSGlobalObject, _: *jsc.CallFrame, _: jsc.JSValue) jsc.JSValue { return .zero; }
    pub fn unsubscribe(_: *ServerWebSocket, _: *jsc.JSGlobalObject, _: *jsc.CallFrame) jsc.JSValue { return .zero; }

    pub fn getBinaryType(_: *ServerWebSocket, _: *jsc.JSGlobalObject) jsc.JSValue { return .zero; }
    pub fn getBufferedAmount(_: *ServerWebSocket, _: *jsc.JSGlobalObject, _: *jsc.CallFrame) jsc.JSValue { return .zero; }
    pub fn getData(_: *ServerWebSocket, _: *jsc.JSGlobalObject) jsc.JSValue { return .zero; }
    pub fn getReadyState(_: *ServerWebSocket, _: *jsc.JSGlobalObject) jsc.JSValue { return .zero; }
    pub fn getRemoteAddress(_: *ServerWebSocket, _: *jsc.JSGlobalObject) jsc.JSValue { return .zero; }
    pub fn getSubscriptions(_: *ServerWebSocket, _: *jsc.JSGlobalObject) jsc.JSValue { return .zero; }
    pub fn setBinaryType(_: *ServerWebSocket, _: *jsc.JSGlobalObject, _: jsc.JSValue) void {}
    pub fn setData(_: *ServerWebSocket, _: *jsc.JSGlobalObject, _: jsc.JSValue) void {}

    pub fn data(_: *ServerWebSocket) jsc.JSValue { return .zero; }
    pub fn socket(_: *ServerWebSocket) jsc.JSValue { return .zero; }
};

pub const ServerConfig = struct {
    allow_hot: bool = false,
    id: []const u8 = "",
    ssl_config: ?SSLConfig = null,

    pub const SSLConfig = struct {
        pub const SharedPtr = SSLConfig;
        pub const zero: SSLConfig = .{};
        server_name: ?[*:0]const u8 = null,
        requires_custom_request_ctx: bool = false,

        pub inline fn get(this: *const SSLConfig) *SSLConfig {
            return @constCast(this);
        }

        pub inline fn rawPtr(maybe_shared: ?SharedPtr) ?*SSLConfig {
            if (maybe_shared) |shared| {
                var copy = shared;
                return copy.get();
            }
            return null;
        }

        pub fn fromJS(_: anytype, _: *jsc.JSGlobalObject, _: jsc.JSValue) !?SSLConfig {
            return .{};
        }

        pub fn fromGenerated(_: *jsc.VirtualMachine, _: *jsc.JSGlobalObject, _: *const jsc.generated.SSLConfig) !?SSLConfig {
            return .{};
        }

        pub fn deinit(_: *SSLConfig) void {}

        pub fn clone(_: *const SSLConfig) SSLConfig {
            return .{};
        }

        pub fn asUSockets(_: *const SSLConfig) bun.uws.SocketContext.BunSocketContextOptions {
            return .{};
        }

        pub fn asUSocketsForClientVerification(_: *const SSLConfig) bun.uws.SocketContext.BunSocketContextOptions {
            return .{};
        }
    };

    pub fn fromJS(_: *jsc.JSGlobalObject, config: *ServerConfig, _: anytype, _: anytype) !void {
        config.* = .{};
    }

    pub fn deinit(_: *ServerConfig) void {}

    pub fn computeID(_: *ServerConfig, _: std.mem.Allocator) []const u8 {
        return "";
    }

    pub fn isDevelopment(_: *const ServerConfig) bool {
        return false;
    }
};

pub const AnyRoute = union(enum) {
    html: *HTMLBundleModule.Route,

    pub fn ref(this: AnyRoute) void {
        switch (this) {
            .html => |route| route.ref(),
        }
    }

    pub fn deref(this: AnyRoute) void {
        switch (this) {
            .html => |route| route.deref(),
        }
    }

    pub fn setServer(this: AnyRoute, server: ?*anyopaque) void {
        switch (this) {
            .html => |route| route.setServer(server),
        }
    }

    pub fn deinit(this: AnyRoute, allocator: std.mem.Allocator) void {
        switch (this) {
            .html => |route| route.deinit(allocator),
        }
    }
};

pub fn applyHTMLRouteToDevServer(dev: *bake.DevServer, path: []const u8, route: *HTMLBundleModule.Route) !void {
    const route_index = try dev.registerRoutePattern(path, .{});
    route.dev_server_id = route_index.toOptional();
    try dev.html_router.put(dev.allocator, path, route);
}

pub const Server = struct {
    pending_requests: usize = 0,
    listener_active: bool = false,
    active_websockets: usize = 0,
    dev_server: ?*bake.DevServer = null,
    routes_cleared: bool = false,
    native_unref_count: usize = 0,

    pub fn init() Server {
        return .{};
    }

    pub fn attachDevServer(this: *Server, dev_server: *bake.DevServer) void {
        this.dev_server = dev_server;
    }

    pub fn hasListener(this: *const Server) bool {
        return this.listener_active;
    }

    pub fn hasActiveWebSockets(this: *const Server) bool {
        return this.active_websockets > 0;
    }

    pub fn beginRequest(this: *Server) void {
        this.pending_requests += 1;
    }

    pub fn endRequest(this: *Server) void {
        if (this.pending_requests > 0) this.pending_requests -= 1;
        this.deinitIfWeCan();
    }

    pub fn openWebSocket(this: *Server) void {
        this.active_websockets += 1;
    }

    pub fn closeWebSocket(this: *Server) void {
        if (this.active_websockets > 0) this.active_websockets -= 1;
        this.deinitIfWeCan();
    }

    pub fn stopListening(this: *Server, abrupt: bool) void {
        this.listener_active = false;
        if (abrupt) this.active_websockets = 0;
        this.deinitIfWeCan();
    }

    pub fn deinitIfWeCan(this: *Server) void {
        if (this.pending_requests != 0 or this.hasListener() or this.hasActiveWebSockets()) {
            return;
        }

        if (this.dev_server) |dev| {
            this.dev_server = null;
            this.clearRoutes();
            dev.deinit();
        }

        this.unref();
    }

    fn clearRoutes(this: *Server) void {
        this.routes_cleared = true;
    }

    fn unref(this: *Server) void {
        this.native_unref_count += 1;
    }
};

test "server lifecycle detaches Bake DevServer only when idle" {
    bake.resetDevServerDeinitCountForTesting();

    var dev = bake.DevServer.init(std.testing.allocator);
    var server = Server.init();
    server.listener_active = true;
    server.attachDevServer(&dev);

    server.deinitIfWeCan();
    try std.testing.expect(server.dev_server != null);
    try std.testing.expectEqual(@as(usize, 0), bake.getDevServerDeinitCountForTesting());

    server.stopListening(false);
    try std.testing.expect(server.dev_server == null);
    try std.testing.expect(server.routes_cleared);
    try std.testing.expectEqual(@as(usize, 1), bake.getDevServerDeinitCountForTesting());
}

test "server lifecycle waits for pending requests and websockets" {
    bake.resetDevServerDeinitCountForTesting();

    var dev = bake.DevServer.init(std.testing.allocator);
    var server = Server.init();
    server.attachDevServer(&dev);
    server.beginRequest();
    server.openWebSocket();

    server.deinitIfWeCan();
    try std.testing.expect(server.dev_server != null);

    server.endRequest();
    try std.testing.expect(server.dev_server != null);

    server.closeWebSocket();
    try std.testing.expect(server.dev_server == null);
    try std.testing.expectEqual(@as(usize, 1), bake.getDevServerDeinitCountForTesting());
}

test "server lifecycle abrupt stop releases websocket gate" {
    bake.resetDevServerDeinitCountForTesting();

    var dev = bake.DevServer.init(std.testing.allocator);
    var server = Server.init();
    server.listener_active = true;
    server.attachDevServer(&dev);
    server.openWebSocket();

    server.stopListening(true);
    try std.testing.expectEqual(@as(usize, 0), server.active_websockets);
    try std.testing.expect(server.dev_server == null);
    try std.testing.expectEqual(@as(usize, 1), bake.getDevServerDeinitCountForTesting());
}

test "server lifecycle deinits attached DevServer once" {
    bake.resetDevServerDeinitCountForTesting();

    var dev = bake.DevServer.init(std.testing.allocator);
    var server = Server.init();
    server.attachDevServer(&dev);

    server.deinitIfWeCan();
    server.deinitIfWeCan();

    try std.testing.expect(server.dev_server == null);
    try std.testing.expectEqual(@as(usize, 1), bake.getDevServerDeinitCountForTesting());
}

test "server AnyRoute.html mirrors into DevServer HTML router" {
    var dev = bake.DevServer.init(std.testing.allocator);
    defer dev.deinit();

    var bundle = try HTMLBundle.init(std.testing.allocator, "index.html");
    defer bundle.deinit();
    var route = bundle.route();
    defer route.deinit(std.testing.allocator);

    try applyHTMLRouteToDevServer(&dev, "/*", &route);

    try std.testing.expect(route.dev_server_id.unwrap() != null);
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&route)), dev.html_router.get("/").?);
}

/// Stub task placeholder so the jsc `Task` tagged-union dispatch compiles; the
/// full server graceful-shutdown lifecycle port is still pending.
pub const ServerAllConnectionsClosedTask = struct {
    dummy: u8 = 0,

    pub fn runFromJSThread(self: *ServerAllConnectionsClosedTask, vm: anytype) void {
        _ = self;
        _ = vm;
    }
};
