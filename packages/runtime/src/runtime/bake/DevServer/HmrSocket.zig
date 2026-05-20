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

const DevServerModule = @import("../DevServer.zig");
const DevServer = DevServerModule.DevServer;
const HmrTopic = DevServerModule.HmrTopic;
const IncomingMessageId = DevServerModule.IncomingMessageId;
const MessageId = DevServerModule.MessageId;
const RouteBundle = @import("RouteBundle.zig").RouteBundle;
const SourceMapStore = @import("SourceMapStore.zig").SourceMapStore;

pub const HmrSocket = struct {
    dev: *DevServer,
    active_route: ?RouteBundle.Index = null,
    subscriptions: HmrTopic.Bits = .{},
    referenced_source_maps: std.AutoHashMap(SourceMapStore.Key, void),
    next_hot_update_index: usize = 0,
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

    pub fn onOpenPayload(this: *HmrSocket, allocator: std.mem.Allocator) ![]u8 {
        const payload = try allocator.alloc(u8, 1 + this.dev.configuration_hash_key.len);
        payload[0] = MessageId.version.char();
        @memcpy(payload[1..], &this.dev.configuration_hash_key);
        return payload;
    }

    pub fn applyClientMessage(this: *HmrSocket, allocator: std.mem.Allocator, msg: []const u8) !?[]u8 {
        if (msg.len == 0) return error.InvalidHmrMessage;

        switch (IncomingMessageId.fromChar(msg[0]) orelse return error.InvalidHmrMessage) {
            .subscribe => {
                const topics = msg[1..];
                if (topics.len > HmrTopic.max_count) return error.InvalidHmrMessage;
                this.subscriptions = .{};
                for (topics) |topic_char| {
                    switch (HmrTopic.fromChar(topic_char) orelse continue) {
                        .hot_update => this.subscriptions.hot_update = true,
                        .errors => this.subscriptions.errors = true,
                        .browser_error => this.subscriptions.browser_error = true,
                        .incremental_visualizer => this.subscriptions.incremental_visualizer = true,
                        .memory_visualizer => this.subscriptions.memory_visualizer = true,
                        .testing_watch_synchronization => this.subscriptions.testing_watch_synchronization = true,
                    }
                }
                return null;
            },
            .set_url => {
                const route_index = this.dev.routeToBundleIndexSlow(msg[1..]) orelse return null;
                this.attachRoute(route_index);

                const response = try allocator.alloc(u8, 5);
                response[0] = MessageId.set_url_response.char();
                std.mem.writeInt(u32, response[1..5], route_index.asInt(), .little);
                return response;
            },
            .init,
            .testing_batch_events,
            .console_log,
            .unref_source_map,
            => return null,
        }
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

test "HmrSocket.onOpenPayload sends version and configuration hash" {
    var dev = DevServer.init(std.testing.allocator);
    defer dev.deinit();
    dev.setConfigurationHashKey("0123456789abcdef".*);

    var socket = HmrSocket.init(&dev);
    defer socket.deinit();

    const payload = try socket.onOpenPayload(std.testing.allocator);
    defer std.testing.allocator.free(payload);

    try std.testing.expectEqual(@as(usize, 17), payload.len);
    try std.testing.expectEqual(@as(u8, 'V'), payload[0]);
    try std.testing.expectEqualStrings("0123456789abcdef", payload[1..]);
}

test "HmrSocket.applyClientMessage subscribes and answers set_url" {
    var dev = DevServer.init(std.testing.allocator);
    defer dev.deinit();
    const route_index = try dev.registerRoutePattern("/", .{});

    var socket = HmrSocket.init(&dev);
    defer socket.deinit();

    try std.testing.expect(try socket.applyClientMessage(std.testing.allocator, "she") == null);
    try std.testing.expect(socket.subscriptions.hot_update);
    try std.testing.expect(socket.subscriptions.errors);
    try std.testing.expect(!socket.subscriptions.browser_error);

    const response = (try socket.applyClientMessage(std.testing.allocator, "n/")).?;
    defer std.testing.allocator.free(response);

    try std.testing.expectEqual(@as(usize, 5), response.len);
    try std.testing.expectEqual(@as(u8, 'n'), response[0]);
    try std.testing.expectEqual(route_index.asInt(), std.mem.readInt(u32, response[1..5], .little));
    try std.testing.expectEqual(@as(usize, 1), dev.routeBundlePtr(route_index).active_viewers);
}
