// Copied/adapted from Bun (https://github.com/oven-sh/bun) — MIT-licensed.
// Original: src/runtime/bake/DevServer/HmrSocket.zig
// See LICENSE.bun.md for full license text.
//
// Lifetime-only subset. Bun's full HmrSocket owns uWS state, topic
// subscriptions, inspector hooks, and source-map refs. This Home carrier keeps
// the parent DevServer relationship and teardown semantics that make Bake
// deinit safe: route viewers and source-map refs are released from onClose,
// and the socket removes itself from the parent active-socket map.

const std = @import("std");

const DevServer = @import("../DevServer.zig").DevServer;
const RouteBundle = @import("RouteBundle.zig").RouteBundle;
const SourceMapStore = @import("SourceMapStore.zig").SourceMapStore;

pub const HmrSocket = struct {
    dev: *DevServer,
    active_route: ?RouteBundle.Index = null,
    referenced_source_maps: std.AutoHashMap(SourceMapStore.Key, void),
    closed: bool = false,

    pub fn init(dev: *DevServer) HmrSocket {
        return .{
            .dev = dev,
            .referenced_source_maps = std.AutoHashMap(SourceMapStore.Key, void).init(dev.allocator),
        };
    }

    pub fn deinit(this: *HmrSocket) void {
        this.referenced_source_maps.deinit();
    }

    pub fn attachRoute(this: *HmrSocket, route_index: RouteBundle.Index) void {
        if (this.active_route) |current| {
            if (current == route_index) return;
            this.releaseRoute();
        }

        this.active_route = route_index;
        this.dev.routeBundlePtr(route_index).active_viewers += 1;
    }

    pub fn addSourceMapRef(this: *HmrSocket, key: SourceMapStore.Key) !void {
        if (this.referenced_source_maps.contains(key)) return;

        try this.dev.source_maps.putOrIncrementRefCount(key);
        errdefer this.dev.source_maps.unref(key);
        try this.referenced_source_maps.put(key, {});
    }

    pub fn unrefSourceMap(this: *HmrSocket, key: SourceMapStore.Key) void {
        if (!this.referenced_source_maps.remove(key)) return;
        this.dev.source_maps.unref(key);
    }

    pub fn close(this: *HmrSocket) void {
        this.onClose();
    }

    pub fn onClose(this: *HmrSocket) void {
        if (this.closed) return;
        this.closed = true;

        this.releaseRoute();

        var keys = this.referenced_source_maps.keyIterator();
        while (keys.next()) |key| {
            this.dev.source_maps.unref(key.*);
        }
        this.referenced_source_maps.clearRetainingCapacity();

        _ = this.dev.active_websocket_connections.remove(this);
    }

    fn releaseRoute(this: *HmrSocket) void {
        const route_index = this.active_route orelse return;
        this.active_route = null;

        const route = this.dev.routeBundlePtr(route_index);
        if (route.active_viewers > 0) route.active_viewers -= 1;
    }
};

test "HmrSocket.onClose releases active route viewers" {
    var dev = DevServer.init(std.testing.allocator);
    defer dev.deinit();

    const route_index = try dev.addRouteBundle(.{});

    var socket = HmrSocket.init(&dev);
    defer socket.deinit();
    try dev.addSocket(&socket);

    socket.attachRoute(route_index);
    try std.testing.expectEqual(@as(usize, 1), dev.routeBundlePtr(route_index).active_viewers);

    socket.onClose();
    try std.testing.expectEqual(@as(usize, 0), dev.routeBundlePtr(route_index).active_viewers);
    try std.testing.expectEqual(@as(usize, 0), dev.active_websocket_connections.count());
}

test "HmrSocket.onClose releases source map refs exactly once" {
    var dev = DevServer.init(std.testing.allocator);
    defer dev.deinit();

    var socket = HmrSocket.init(&dev);
    defer socket.deinit();
    try dev.addSocket(&socket);

    try socket.addSourceMapRef(11);
    try socket.addSourceMapRef(11);
    try std.testing.expectEqual(@as(usize, 1), dev.source_maps.refCount(11));

    socket.onClose();
    socket.onClose();
    try std.testing.expectEqual(@as(usize, 0), dev.source_maps.refCount(11));
}

test "HmrSocket.unrefSourceMap prevents double unref during close" {
    var dev = DevServer.init(std.testing.allocator);
    defer dev.deinit();

    var socket = HmrSocket.init(&dev);
    defer socket.deinit();
    try dev.addSocket(&socket);

    try socket.addSourceMapRef(12);
    socket.unrefSourceMap(12);
    try std.testing.expectEqual(@as(usize, 0), dev.source_maps.refCount(12));

    socket.onClose();
    try std.testing.expectEqual(@as(usize, 0), dev.source_maps.refCount(12));
}

