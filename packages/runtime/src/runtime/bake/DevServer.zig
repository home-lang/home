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

pub const MessageId = enum(u8) {
    version = 'V',
    hot_update = 'u',
    errors = 'e',
    browser_message = 'b',
    browser_message_clear = 'B',
    request_handler_error = 'h',
    visualizer = 'v',
    memory_visualizer = 'M',
    set_url_response = 'n',
    testing_watch_synchronization = 'r',

    pub inline fn char(id: MessageId) u8 {
        return @intFromEnum(id);
    }
};

pub const IncomingMessageId = enum(u8) {
    init = 'i',
    subscribe = 's',
    set_url = 'n',
    testing_batch_events = 'H',
    console_log = 'l',
    unref_source_map = 'u',

    pub fn fromChar(char: u8) ?IncomingMessageId {
        return switch (char) {
            'i' => .init,
            's' => .subscribe,
            'n' => .set_url,
            'H' => .testing_batch_events,
            'l' => .console_log,
            'u' => .unref_source_map,
            else => null,
        };
    }
};

pub const HmrTopic = enum(u8) {
    hot_update = 'h',
    errors = 'e',
    browser_error = 'E',
    incremental_visualizer = 'v',
    memory_visualizer = 'M',
    testing_watch_synchronization = 'r',

    pub const max_count = 6;

    pub const Bits = packed struct {
        hot_update: bool = false,
        errors: bool = false,
        browser_error: bool = false,
        incremental_visualizer: bool = false,
        memory_visualizer: bool = false,
        testing_watch_synchronization: bool = false,
    };

    pub fn fromChar(char: u8) ?HmrTopic {
        return switch (char) {
            'h' => .hot_update,
            'e' => .errors,
            'E' => .browser_error,
            'v' => .incremental_visualizer,
            'M' => .memory_visualizer,
            'r' => .testing_watch_synchronization,
            else => null,
        };
    }
};

pub const HTMLRouter = struct {
    map: std.StringHashMap(*anyopaque),
    fallback: ?*anyopaque = null,

    pub fn init(allocator: std.mem.Allocator) HTMLRouter {
        return .{ .map = std.StringHashMap(*anyopaque).init(allocator) };
    }

    pub fn empty(this: *const HTMLRouter) bool {
        return this.fallback == null and this.map.count() == 0;
    }

    pub fn deinit(this: *HTMLRouter, allocator: std.mem.Allocator) void {
        this.clear(allocator);
        this.map.deinit();
        this.* = undefined;
    }

    pub fn clear(this: *HTMLRouter, allocator: std.mem.Allocator) void {
        var keys = this.map.keyIterator();
        while (keys.next()) |key| allocator.free(key.*);
        this.map.clearRetainingCapacity();
        this.fallback = null;
    }

    pub fn put(this: *HTMLRouter, allocator: std.mem.Allocator, pattern: []const u8, route: *anyopaque) !void {
        if (std.mem.eql(u8, pattern, "/*")) {
            this.fallback = route;
            return;
        }

        if (this.map.getEntry(pattern)) |entry| {
            entry.value_ptr.* = route;
            return;
        }

        const owned = try allocator.dupe(u8, pattern);
        errdefer allocator.free(owned);
        try this.map.put(owned, route);
    }

    pub fn get(this: *const HTMLRouter, pattern: []const u8) ?*anyopaque {
        return this.map.get(pattern) orelse this.fallback;
    }
};

pub var dev_server_deinit_count_for_testing: usize = 0;

pub fn resetDeinitCountForTesting() void {
    dev_server_deinit_count_for_testing = 0;
}

pub fn getDeinitCountForTesting() usize {
    return dev_server_deinit_count_for_testing;
}

pub const DevServer = struct {
    pub const HotUpdate = struct {
        source_map_id: SourceMapStore.Key,
        source: []const u8,

        pub fn deinit(this: *HotUpdate, allocator: std.mem.Allocator) void {
            allocator.free(this.source);
            this.* = undefined;
        }
    };

    allocator: std.mem.Allocator,
    route_bundles: std.ArrayList(RouteBundle) = .empty,
    route_patterns: std.StringHashMap(RouteBundle.Index),
    html_router: HTMLRouter,
    source_maps: SourceMapStore,
    active_websocket_connections: std.AutoHashMap(*HmrSocket, void),
    hot_updates: std.ArrayList(HotUpdate) = .empty,
    configuration_hash_key: [16]u8 = .{
        '0', '0', '0', '0',
        '0', '0', '0', '0',
        '0', '0', '0', '0',
        '0', '0', '0', '0',
    },

    pub fn init(allocator: std.mem.Allocator) DevServer {
        return .{
            .allocator = allocator,
            .route_patterns = std.StringHashMap(RouteBundle.Index).init(allocator),
            .html_router = HTMLRouter.init(allocator),
            .source_maps = SourceMapStore.init(allocator),
            .active_websocket_connections = std.AutoHashMap(*HmrSocket, void).init(allocator),
        };
    }

    pub fn deinit(this: *DevServer) void {
        dev_server_deinit_count_for_testing +|= 1;

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
        for (this.hot_updates.items) |*update| update.deinit(this.allocator);
        this.hot_updates.deinit(this.allocator);
        this.source_maps.deinit();
        var pattern_keys = this.route_patterns.keyIterator();
        while (pattern_keys.next()) |key| this.allocator.free(key.*);
        this.route_patterns.deinit();
        this.html_router.deinit(this.allocator);
        this.route_bundles.deinit(this.allocator);
    }

    pub fn setConfigurationHashKey(this: *DevServer, key: [16]u8) void {
        this.configuration_hash_key = key;
    }

    pub fn addRouteBundle(this: *DevServer, route_bundle: RouteBundle) !RouteBundle.Index {
        const index = RouteBundle.Index.fromInt(@intCast(this.route_bundles.items.len));
        try this.route_bundles.append(this.allocator, route_bundle);
        return index;
    }

    pub fn registerRoutePattern(this: *DevServer, pattern: []const u8, route_bundle: RouteBundle) !RouteBundle.Index {
        if (this.route_patterns.get(pattern)) |existing| return existing;

        const index = try this.addRouteBundle(route_bundle);
        errdefer _ = this.route_bundles.pop();

        const owned_pattern = try this.allocator.dupe(u8, pattern);
        errdefer this.allocator.free(owned_pattern);
        try this.route_patterns.put(owned_pattern, index);
        return index;
    }

    pub fn routeToBundleIndexSlow(this: *DevServer, pattern: []const u8) ?RouteBundle.Index {
        return this.route_patterns.get(pattern) orelse this.route_patterns.get("/*");
    }

    pub fn routeBundlePtr(this: *DevServer, index: RouteBundle.Index) *RouteBundle {
        return &this.route_bundles.items[index.asInt()];
    }

    pub fn addSocket(this: *DevServer, socket: *HmrSocket) !void {
        try this.active_websocket_connections.put(socket, {});
    }

    pub fn emitHotUpdate(this: *DevServer, source: []const u8) !void {
        const copied = try this.allocator.dupe(u8, source);
        errdefer this.allocator.free(copied);
        try this.hot_updates.append(this.allocator, .{
            .source_map_id = hotUpdateSourceMapId(source),
            .source = copied,
        });
    }

    pub fn drainHotUpdateTextForSocket(
        this: *DevServer,
        allocator: std.mem.Allocator,
        socket: *HmrSocket,
        separator: []const u8,
    ) ![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(allocator);

        if (!socket.subscriptions.hot_update) return out.toOwnedSlice(allocator);

        var index = socket.next_hot_update_index;
        while (index < this.hot_updates.items.len) : (index += 1) {
            if (out.items.len > 0) try out.appendSlice(allocator, separator);
            try socket.addSourceMapRef(this.hot_updates.items[index].source_map_id);
            try out.appendSlice(allocator, this.hot_updates.items[index].source);
        }
        socket.next_hot_update_index = this.hot_updates.items.len;

        return out.toOwnedSlice(allocator);
    }

    pub fn hotUpdateSourceMapId(source: []const u8) SourceMapStore.Key {
        return @truncate(std.hash.Wyhash.hash(0, source) | 1);
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

test "DevServer route pattern lookup returns registered bundle index" {
    var dev = DevServer.init(std.testing.allocator);
    defer dev.deinit();

    const index = try dev.registerRoutePattern("/", .{});
    try std.testing.expectEqual(index, dev.routeToBundleIndexSlow("/").?);
    try std.testing.expectEqual(index, try dev.registerRoutePattern("/", .{}));
    try std.testing.expectEqual(@as(usize, 1), dev.route_bundles.items.len);
    try std.testing.expect(dev.routeToBundleIndexSlow("/missing") == null);
}

test "DevServer route pattern lookup falls back to catch-all bundle" {
    var dev = DevServer.init(std.testing.allocator);
    defer dev.deinit();

    const index = try dev.registerRoutePattern("/*", .{});
    try std.testing.expectEqual(index, dev.routeToBundleIndexSlow("/").?);
}

test "DevServer HMR protocol ids match Bun wire bytes" {
    try std.testing.expectEqual(@as(u8, 'V'), MessageId.version.char());
    try std.testing.expectEqual(@as(u8, 'n'), MessageId.set_url_response.char());
    try std.testing.expectEqual(IncomingMessageId.subscribe, IncomingMessageId.fromChar('s').?);
    try std.testing.expectEqual(IncomingMessageId.set_url, IncomingMessageId.fromChar('n').?);
    try std.testing.expectEqual(HmrTopic.hot_update, HmrTopic.fromChar('h').?);
    try std.testing.expectEqual(HmrTopic.errors, HmrTopic.fromChar('e').?);
}

test "DevServer queues duplicate hot updates FIFO for sockets" {
    var dev = DevServer.init(std.testing.allocator);
    defer dev.deinit();

    var socket = HmrSocket.init(&dev);
    defer socket.deinit();
    try dev.addSocket(&socket);

    _ = try socket.applyClientMessage(std.testing.allocator, "sh");
    try dev.emitHotUpdate("console.log(\"rapid\");");
    try dev.emitHotUpdate("console.log(\"rapid\");");
    try dev.emitHotUpdate("console.log(\"sentinel\");");

    const rapid_id = DevServer.hotUpdateSourceMapId("console.log(\"rapid\");");
    try std.testing.expectEqual(rapid_id, dev.hot_updates.items[0].source_map_id);
    try std.testing.expectEqual(rapid_id, dev.hot_updates.items[1].source_map_id);

    const drained = try dev.drainHotUpdateTextForSocket(std.testing.allocator, &socket, "\n--hmr--\n");
    defer std.testing.allocator.free(drained);

    try std.testing.expectEqualStrings(
        "console.log(\"rapid\");\n--hmr--\nconsole.log(\"rapid\");\n--hmr--\nconsole.log(\"sentinel\");",
        drained,
    );
    try std.testing.expectEqual(@as(usize, 1), dev.source_maps.refCount(rapid_id));
    try std.testing.expectEqual(@as(usize, 3), socket.next_hot_update_index);

    const empty = try dev.drainHotUpdateTextForSocket(std.testing.allocator, &socket, "\n--hmr--\n");
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqualStrings("", empty);

    socket.close();
}

pub fn emitMemoryVisualizerMessageTimer(_: *anyopaque, _: *const anyopaque) void {
    // Stub: only used when bake_debugging_features is enabled
}

test "DevServer HTMLRouter stores catch-all route as fallback" {
    var router = HTMLRouter.init(std.testing.allocator);
    defer router.deinit(std.testing.allocator);

    var fallback: u8 = 1;
    var exact: u8 = 2;

    try std.testing.expect(router.empty());
    try router.put(std.testing.allocator, "/*", &fallback);
    try std.testing.expect(!router.empty());
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&fallback)), router.get("/anything").?);

    try router.put(std.testing.allocator, "/admin", &exact);
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&exact)), router.get("/admin").?);
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&fallback)), router.get("/other").?);
}
