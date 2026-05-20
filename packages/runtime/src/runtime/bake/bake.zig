// Copied/adapted from Bun (https://github.com/oven-sh/bun) — MIT-licensed.
// Original subtree: src/runtime/bake/
// See LICENSE.bun.md for full license text.
//
// This is the Home lifetime-only Bake nucleus. It intentionally does not
// expose the bundler, watcher, HTML route, uWS, or JSC-facing DevServer
// surface yet; it carries the deinit/HMR ownership invariants needed before
// wiring Bun.serve({ routes: html }) into Home.

const DevServerModule = @import("DevServer.zig");
const std = @import("std");

pub const DevServer = DevServerModule.DevServer;
pub const resetDevServerDeinitCountForTesting = DevServerModule.resetDeinitCountForTesting;
pub const getDevServerDeinitCountForTesting = DevServerModule.getDeinitCountForTesting;
pub const HmrSocket = @import("DevServer/HmrSocket.zig").HmrSocket;
pub const RouteBundle = @import("DevServer/RouteBundle.zig").RouteBundle;
pub const SourceMapStore = @import("DevServer/SourceMapStore.zig").SourceMapStore;

pub const Mode = enum {
    development,
    production_dynamic,
    production_static,
};

pub const Side = enum {
    client,
    server,
};

pub const DefineMap = struct {
    entries: std.StringArrayHashMapUnmanaged([]const u8) = .empty,

    pub fn deinit(this: *DefineMap, allocator: std.mem.Allocator) void {
        for (this.entries.keys()) |key| allocator.free(key);
        for (this.entries.values()) |value| allocator.free(value);
        this.entries.deinit(allocator);
        this.* = .{};
    }

    pub fn putCopy(this: *DefineMap, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
        if (this.entries.getIndex(key)) |index| {
            const copied_value = try allocator.dupe(u8, value);
            allocator.free(this.entries.values()[index]);
            this.entries.values()[index] = copied_value;
            return;
        }

        const copied_key = try allocator.dupe(u8, key);
        errdefer allocator.free(copied_key);
        const copied_value = try allocator.dupe(u8, value);
        errdefer allocator.free(copied_value);
        try this.entries.put(allocator, copied_key, copied_value);
    }

    pub fn get(this: *const DefineMap, key: []const u8) ?[]const u8 {
        return this.entries.get(key);
    }

    pub fn count(this: *const DefineMap) usize {
        return this.entries.count();
    }
};

pub const BuildConfigSubset = struct {
    define: DefineMap = .{},

    pub fn deinit(this: *BuildConfigSubset, allocator: std.mem.Allocator) void {
        this.define.deinit(allocator);
    }
};

pub const SplitBundlerOptions = struct {
    client: BuildConfigSubset = .{},
    server: BuildConfigSubset = .{},
    ssr: BuildConfigSubset = .{},

    pub fn deinit(this: *SplitBundlerOptions, allocator: std.mem.Allocator) void {
        this.client.deinit(allocator);
        this.server.deinit(allocator);
        this.ssr.deinit(allocator);
    }
};

pub const UserOptions = struct {
    bundler_options: SplitBundlerOptions = .{},

    pub fn deinit(this: *UserOptions, allocator: std.mem.Allocator) void {
        this.bundler_options.deinit(allocator);
    }

    pub fn applyServeStaticOptions(this: *UserOptions, allocator: std.mem.Allocator, serve_static: *const ServeStaticOptions) !void {
        try serve_static.applyToBundlerOptions(allocator, &this.bundler_options);
    }
};

pub const ServeStaticOptions = struct {
    define: DefineMap = .{},

    pub fn deinit(this: *ServeStaticOptions, allocator: std.mem.Allocator) void {
        this.define.deinit(allocator);
    }

    pub fn putDefineCopy(this: *ServeStaticOptions, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
        try this.define.putCopy(allocator, key, value);
    }

    pub fn applyToBundlerOptions(this: *const ServeStaticOptions, allocator: std.mem.Allocator, bundler_options: *SplitBundlerOptions) !void {
        for (this.define.entries.keys(), this.define.entries.values()) |key, value| {
            try bundler_options.client.define.putCopy(allocator, key, value);
            try bundler_options.server.define.putCopy(allocator, key, value);
            try bundler_options.ssr.define.putCopy(allocator, key, value);
        }
    }
};

pub fn addImportMetaDefineStrings(allocator: std.mem.Allocator, define: *DefineMap, mode: Mode, side: Side) !void {
    try define.putCopy(allocator, "import.meta.env.DEV", if (mode == .development) "true" else "false");
    try define.putCopy(allocator, "import.meta.env.PROD", if (mode == .development) "false" else "true");
    try define.putCopy(allocator, "import.meta.env.MODE", switch (mode) {
        .development => "\"development\"",
        .production_dynamic, .production_static => "\"production\"",
    });
    try define.putCopy(allocator, "import.meta.env.SSR", if (side == .server) "true" else "false");
    try define.putCopy(allocator, "import.meta.env.STATIC", if (mode == .production_static) "true" else "false");
}

test "Bake serve static define copies to all bundler graphs" {
    var serve: ServeStaticOptions = .{};
    defer serve.deinit(std.testing.allocator);

    try serve.putDefineCopy(std.testing.allocator, "DEFINE", "\"HELLO\"");
    try serve.putDefineCopy(std.testing.allocator, "process.env.FEATURE", "\"enabled\"");

    var bundler_options: SplitBundlerOptions = .{};
    defer bundler_options.deinit(std.testing.allocator);

    try serve.applyToBundlerOptions(std.testing.allocator, &bundler_options);

    try std.testing.expectEqualStrings("\"HELLO\"", bundler_options.client.define.get("DEFINE").?);
    try std.testing.expectEqualStrings("\"HELLO\"", bundler_options.server.define.get("DEFINE").?);
    try std.testing.expectEqualStrings("\"HELLO\"", bundler_options.ssr.define.get("DEFINE").?);
    try std.testing.expectEqualStrings("\"enabled\"", bundler_options.client.define.get("process.env.FEATURE").?);
}

test "Bake UserOptions applies serve static define maps" {
    var serve: ServeStaticOptions = .{};
    defer serve.deinit(std.testing.allocator);
    try serve.putDefineCopy(std.testing.allocator, "DEFINE", "\"HELLO\"");

    var user_options: UserOptions = .{};
    defer user_options.deinit(std.testing.allocator);
    try user_options.applyServeStaticOptions(std.testing.allocator, &serve);

    try std.testing.expectEqualStrings("\"HELLO\"", user_options.bundler_options.client.define.get("DEFINE").?);
    try std.testing.expectEqualStrings("\"HELLO\"", user_options.bundler_options.server.define.get("DEFINE").?);
    try std.testing.expectEqualStrings("\"HELLO\"", user_options.bundler_options.ssr.define.get("DEFINE").?);
}

test "Bake serve static define replacement preserves latest value" {
    var serve: ServeStaticOptions = .{};
    defer serve.deinit(std.testing.allocator);

    try serve.putDefineCopy(std.testing.allocator, "DEFINE", "\"OLD\"");
    try serve.putDefineCopy(std.testing.allocator, "DEFINE", "\"HELLO\"");

    try std.testing.expectEqual(@as(usize, 1), serve.define.count());
    try std.testing.expectEqualStrings("\"HELLO\"", serve.define.get("DEFINE").?);
}

test "Bake import.meta define strings match Bun mode and side flags" {
    var define: DefineMap = .{};
    defer define.deinit(std.testing.allocator);

    try addImportMetaDefineStrings(std.testing.allocator, &define, .production_static, .server);

    try std.testing.expectEqualStrings("false", define.get("import.meta.env.DEV").?);
    try std.testing.expectEqualStrings("true", define.get("import.meta.env.PROD").?);
    try std.testing.expectEqualStrings("\"production\"", define.get("import.meta.env.MODE").?);
    try std.testing.expectEqualStrings("true", define.get("import.meta.env.SSR").?);
    try std.testing.expectEqualStrings("true", define.get("import.meta.env.STATIC").?);
}
