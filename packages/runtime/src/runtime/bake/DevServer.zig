// Copied/adapted from Bun (https://github.com/oven-sh/bun) — MIT-licensed.
// Original: src/runtime/bake/DevServer.zig
// See LICENSE.bun.md for full license text.
//
// Lifetime-only subset. The full Bun DevServer coordinates bundling,
// framework routing, uWS, file watching, and JSC-visible Bake APIs. Home keeps
// the deinit/HMR ownership nucleus first so corpus failures can move from
// missing substrate toward real API behavior without faking deinit counters.

const std = @import("std");

pub const HmrSocket = @import("DevServer/HmrSocket.zig").HmrSocket;
pub const RouteBundle = @import("DevServer/RouteBundle.zig").RouteBundle;
pub const SourceMapStore = @import("DevServer/SourceMapStore.zig").SourceMapStore;

pub var dev_server_deinit_count_for_testing: usize = 0;

pub fn resetDeinitCountForTesting() void {
    dev_server_deinit_count_for_testing = 0;
}

pub fn getDeinitCountForTesting() usize {
    return dev_server_deinit_count_for_testing;
}

pub const DevServer = struct {
    allocator: std.mem.Allocator,
    route_bundles: std.ArrayList(RouteBundle) = .empty,
    source_maps: SourceMapStore,
    active_websocket_connections: std.AutoHashMap(*HmrSocket, void),

    pub fn init(allocator: std.mem.Allocator) DevServer {
        return .{
            .allocator = allocator,
            .source_maps = SourceMapStore.init(allocator),
            .active_websocket_connections = std.AutoHashMap(*HmrSocket, void).init(allocator),
        };
    }

    pub fn deinit(this: *DevServer) void {
        dev_server_deinit_count_for_testing += 1;

        var sockets: std.ArrayList(*HmrSocket) = .empty;
        defer sockets.deinit(this.allocator);

        var active = this.active_websocket_connections.keyIterator();
        while (active.next()) |socket| {
            sockets.append(this.allocator, socket.*) catch @panic("failed to snapshot Bake HMR sockets");
        }

        for (sockets.items) |socket| {
            socket.close();
        }

        std.debug.assert(this.active_websocket_connections.count() == 0);
        this.active_websocket_connections.deinit();
        this.source_maps.deinit();
        this.route_bundles.deinit(this.allocator);
    }

    pub fn addRouteBundle(this: *DevServer, route_bundle: RouteBundle) !RouteBundle.Index {
        const index = RouteBundle.Index.fromInt(@intCast(this.route_bundles.items.len));
        try this.route_bundles.append(this.allocator, route_bundle);
        return index;
    }

    pub fn routeBundlePtr(this: *DevServer, index: RouteBundle.Index) *RouteBundle {
        return &this.route_bundles.items[index.asInt()];
    }

    pub fn addSocket(this: *DevServer, socket: *HmrSocket) !void {
        try this.active_websocket_connections.put(socket, {});
    }
};

test "DevServer.deinit increments the Bake testing counter" {
    resetDeinitCountForTesting();

    var dev = DevServer.init(std.testing.allocator);
    dev.deinit();

    try std.testing.expectEqual(@as(usize, 1), getDeinitCountForTesting());
}

test "DevServer.deinit snapshots HMR sockets before close mutates the map" {
    resetDeinitCountForTesting();

    var dev = DevServer.init(std.testing.allocator);
    const route_index = try dev.addRouteBundle(.{});

    var first = HmrSocket.init(&dev);
    defer first.deinit();
    var second = HmrSocket.init(&dev);
    defer second.deinit();

    try dev.addSocket(&first);
    try dev.addSocket(&second);

    first.attachRoute(route_index);
    second.attachRoute(route_index);

    try first.addSourceMapRef(31);
    try second.addSourceMapRef(31);
    try std.testing.expectEqual(@as(usize, 2), dev.routeBundlePtr(route_index).active_viewers);
    try std.testing.expectEqual(@as(usize, 2), dev.source_maps.refCount(31));

    dev.deinit();

    try std.testing.expect(first.closed);
    try std.testing.expect(second.closed);
    try std.testing.expectEqual(@as(usize, 1), getDeinitCountForTesting());
}

