// Copied/adapted from Bun (https://github.com/oven-sh/bun) — MIT-licensed.
// Original subtree: src/runtime/bake/
// See LICENSE.bun.md for full license text.
//
// This is the Home lifetime-only Bake nucleus. It intentionally does not
// expose the bundler, watcher, HTML route, uWS, or JSC-facing DevServer
// surface yet; it carries the deinit/HMR ownership invariants needed before
// wiring Bun.serve({ routes: html }) into Home.

pub const DevServer = @import("DevServer.zig").DevServer;
pub const HmrSocket = @import("DevServer/HmrSocket.zig").HmrSocket;
pub const RouteBundle = @import("DevServer/RouteBundle.zig").RouteBundle;
pub const SourceMapStore = @import("DevServer/SourceMapStore.zig").SourceMapStore;
