// Copied from bun/src/runtime/server/ServerConfig.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
//
//! `Bun.serve()` parsed configuration. Upstream is a 1100-line file whose
//! top-level struct fields wrap `uws.AnyResponse`, `jsc.JSValue` handlers,
//! `bun.bake.UserOptions`, `SSLConfig`, `WebSocketServerContext`, and a
//! `StaticRouteEntry` list keyed by `AnyRoute` (a tagged union over
//! `HTMLBundle.Route` / `StaticRoute` / `FileRoute` / `JS` callable). Every
//! one of those types pulls in substrate (uws, the bake DevServer, the JSC
//! VM bridge, the WebCore FetchHeaders) that has not landed yet — porting
//! the full struct now would land as ~700 lines of `anyopaque` stubs that
//! the next batch would just delete.
//!
//! Home divergence: this file ports only the pure-data leaves that callers
//! outside the request hot-path consume — `DevelopmentOption` (enum the CLI
//! reads to decide whether to spawn the DevServer) and `RouteDeclaration`
//! (path + method pair stored on every concrete RouteList row). Both match
//! upstream byte-for-byte. The remaining ServerConfig surface (address,
//! ssl_config, sni, onRequest/onError, websocket, static_routes,
//! negative_routes, user_routes_to_build, bake, fromJS, deinit,
//! cloneForReloadingStaticRoutes, applyStaticRoute{,H3}, computeID,
//! getUsocketsOptions, validateRouteName) re-attaches alongside the uws +
//! AnyRoute substrate in a later phase.

/// Build/serve mode reported by `Bun.serve({ development: ... })`. The CLI
/// reads this off the parsed config to decide whether to spawn the
/// `bake.DevServer` (HMR enabled) or a plain static server. Three states
/// because HMR can be opted out of in development (e.g. an integration test
/// suite that wants development errors but stable module IDs).
pub const DevelopmentOption = enum {
    development,
    production,
    development_without_hmr,

    pub fn isHMREnabled(this: DevelopmentOption) bool {
        return this == .development;
    }

    pub fn isDevelopment(this: DevelopmentOption) bool {
        return this == .development or this == .development_without_hmr;
    }
};

/// A single `Bun.serve({ routes })` entry as stored on the parsed config.
/// `path` is an owned `[:0]const u8` (uWS takes null-terminated route
/// patterns). The `method` union mirrors upstream: `.any` means the same
/// handler runs for every HTTP method (the common case), `.specific` pins
/// it to one method (used by both the route-builder and the `applyStaticRoute`
/// uWS wiring). We don't need `bun.http.Method.Set` for this shape — the
/// per-method-set route lives on `StaticRouteEntry`, which re-lands with
/// `AnyRoute`.
pub const RouteDeclaration = struct {
    path: [:0]const u8 = "",
    method: union(enum) {
        any: void,
        specific: HTTP.Method,
    } = .any,

    pub fn deinit(this: *RouteDeclaration) void {
        if (this.path.len > 0) {
            home_rt.default_allocator.free(this.path);
        }
    }
};

pub const StaticRouteEntry = struct {
    route: server.AnyRoute,
    route_decl: RouteDeclaration = .{},

    pub fn deinit(this: *StaticRouteEntry, allocator: std.mem.Allocator) void {
        if (this.route_decl.path.len > 0) allocator.free(this.route_decl.path);
        this.route_decl.path = "";
    }
};

pub const ServerConfig = struct {
    allocator: std.mem.Allocator,
    static_routes: std.ArrayList(StaticRouteEntry) = .empty,
    had_routes_object: bool = false,
    bake: ?bake.UserOptions = null,

    // Faithful to upstream `ServerConfig.zig:383`:
    // `pub const SSLConfig = @import("../socket/SSLConfig.zig");`
    pub const SSLConfig = @import("../socket/SSLConfig.zig");

    pub fn init(allocator: std.mem.Allocator) ServerConfig {
        return .{ .allocator = allocator };
    }

    pub fn deinit(this: *ServerConfig) void {
        for (this.static_routes.items) |*entry| entry.deinit(this.allocator);
        this.static_routes.deinit(this.allocator);
        if (this.bake) |*options| options.deinit(this.allocator);
        this.* = undefined;
    }

    pub fn appendHTMLRoute(this: *ServerConfig, path: []const u8, route: *HTMLBundleModule.Route) !void {
        const owned_path = try this.allocator.dupeZ(u8, path);
        errdefer this.allocator.free(owned_path);
        try this.static_routes.append(this.allocator, .{
            .route = .{ .html = route },
            .route_decl = .{ .path = owned_path, .method = .any },
        });
        this.had_routes_object = true;
    }

    pub fn ensureBakeForHTMLRoutes(this: *ServerConfig, serve_static: *const bake.ServeStaticOptions) !void {
        if (this.static_routes.items.len == 0) return;
        if (this.bake == null) this.bake = .{};
        try this.bake.?.applyServeStaticOptions(this.allocator, serve_static);
    }
};

const std = @import("std");
const home_rt = @import("home_rt");
const bake = @import("../bake/bake.zig");
const server = @import("server.zig");
const HTMLBundleModule = @import("HTMLBundle.zig");
const HTMLBundle = HTMLBundleModule.HTMLBundle;
const HTTP = struct {
    pub const Method = home_rt.http_types.Method;
};

test "DevelopmentOption: isHMREnabled only true for .development" {
    try std.testing.expect(DevelopmentOption.development.isHMREnabled());
    try std.testing.expect(!DevelopmentOption.production.isHMREnabled());
    try std.testing.expect(!DevelopmentOption.development_without_hmr.isHMREnabled());
}

test "DevelopmentOption: isDevelopment treats both dev variants as dev" {
    try std.testing.expect(DevelopmentOption.development.isDevelopment());
    try std.testing.expect(DevelopmentOption.development_without_hmr.isDevelopment());
    try std.testing.expect(!DevelopmentOption.production.isDevelopment());
}

test "RouteDeclaration: default is empty .any" {
    const r: RouteDeclaration = .{};
    try std.testing.expectEqualStrings("", r.path);
    try std.testing.expect(r.method == .any);
}

test "RouteDeclaration: specific method roundtrips" {
    const r: RouteDeclaration = .{ .path = "", .method = .{ .specific = .GET } };
    try std.testing.expect(r.method == .specific);
    try std.testing.expectEqual(HTTP.Method.GET, r.method.specific);
}

test "RouteDeclaration: deinit on empty path is a no-op" {
    var r: RouteDeclaration = .{};
    r.deinit(); // must not call free("")
}

test "RouteDeclaration: deinit frees owned path" {
    const dup = try home_rt.default_allocator.dupeZ(u8, "/api/users");
    var r: RouteDeclaration = .{ .path = dup, .method = .{ .specific = .POST } };
    r.deinit();
}

test "ServerConfig appends HTML static routes" {
    var config = ServerConfig.init(std.testing.allocator);
    defer config.deinit();

    var bundle = try HTMLBundle.init(std.testing.allocator, "index.html");
    defer bundle.deinit();
    var route = bundle.route();
    defer route.deinit(std.testing.allocator);

    try config.appendHTMLRoute("/*", &route);

    try std.testing.expect(config.had_routes_object);
    try std.testing.expectEqual(@as(usize, 1), config.static_routes.items.len);
    try std.testing.expectEqualStrings("/*", config.static_routes.items[0].route_decl.path);
    try std.testing.expect(config.static_routes.items[0].route == .html);
}

test "ServerConfig HTML route initializes Bake options with serve.static defines" {
    var config = ServerConfig.init(std.testing.allocator);
    defer config.deinit();

    var bundle = try HTMLBundle.init(std.testing.allocator, "index.html");
    defer bundle.deinit();
    var route = bundle.route();
    defer route.deinit(std.testing.allocator);
    try config.appendHTMLRoute("/*", &route);

    var serve_static: bake.ServeStaticOptions = .{};
    defer serve_static.deinit(std.testing.allocator);
    try serve_static.putDefineCopy(std.testing.allocator, "DEFINE", "\"HELLO\"");

    try config.ensureBakeForHTMLRoutes(&serve_static);

    try std.testing.expect(config.bake != null);
    try std.testing.expectEqualStrings("\"HELLO\"", config.bake.?.bundler_options.client.define.get("DEFINE").?);
    try std.testing.expectEqualStrings("\"HELLO\"", config.bake.?.bundler_options.server.define.get("DEFINE").?);
    try std.testing.expectEqualStrings("\"HELLO\"", config.bake.?.bundler_options.ssr.define.get("DEFINE").?);
}
