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
const HTMLBundle = @import("HTMLBundle.zig");

pub const AnyRoute = union(enum) {
    html: *HTMLBundle.Route,

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

pub fn applyHTMLRouteToDevServer(dev: *bake.DevServer, path: []const u8, route: *HTMLBundle.Route) !void {
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

    var bundle = try HTMLBundle.HTMLBundle.init(std.testing.allocator, "index.html");
    defer bundle.deinit();
    var route = bundle.route();
    defer route.deinit(std.testing.allocator);

    try applyHTMLRouteToDevServer(&dev, "/*", &route);

    try std.testing.expect(route.dev_server_id.unwrap() != null);
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&route)), dev.html_router.get("/").?);
}
