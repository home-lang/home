// Copied from bun/src/runtime/server/InspectorBunFrontendDevServerAgent.zig at
// upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see
// ../../cli/LICENSE.bun.md.
//
//! Front-end dev-server agent shim. Forwards `notify*` events from the Zig
//! side of `bun.bake.DevServer` to the C++ Inspector backend over the
//! `InspectorBunFrontendDevServerAgent__*` C ABI. The handle is owned by the
//! Inspector and registered on the `VirtualMachine.debugger`; when the
//! Inspector isn't attached `handle` is null and every method is a no-op.
//!
//! Home divergence: upstream re-exports a `Bun__InspectorBunFrontendDevServerAgent__setEnabled`
//! C entrypoint that pokes `jsc.VirtualMachine.get().debugger.frontend_dev_server_agent.handle`.
//! `home_rt.jsc.VirtualMachine` / `jsc.Debugger` are not yet ported (Phase 12.2),
//! so the export is held back until the debugger substrate lands. The handle
//! field is otherwise wired identically to upstream — Phase 12.2 just adds
//! the public setter back. `bun.bake.DevServer.RouteBundle.Index`, the
//! `ConsoleLogKind` enum, and `jsc.Debugger.DebuggerId` are stubbed locally
//! with the same `GenericIndex(i32, …)` / `enum(u8)` shape as upstream so
//! the public method signatures match byte-for-byte.

// `bun.String` C ABI stub. Real layout `{tag: u8, _padding: 7 bytes, impl: *anyopaque}`;
// re-attaches when `home_rt.jsc.BunString` lands in Phase 12.2.
pub const BunString = extern struct {
    tag: u8 = 0,
    _padding: [7]u8 = @splat(0),
    impl: ?*anyopaque = null,
};

// `jsc.Debugger.DebuggerId` stub — upstream is `bun.GenericIndex(i32, Debugger)`.
// We only need `.get()`; the rest of the GenericIndex surface re-attaches in
// Phase 12.2 alongside the debugger.
pub const DebuggerId = enum(i32) {
    _,
    pub inline fn init(int: i32) DebuggerId {
        return @enumFromInt(int);
    }
    pub inline fn get(i: DebuggerId) i32 {
        return @intFromEnum(i);
    }
};

// `bun.bake.DevServer.RouteBundle.Index` stub — upstream is
// `bun.GenericIndex(u30, RouteBundle)`. Same minimal surface as DebuggerId.
pub const RouteBundleIndex = enum(u30) {
    _,
    pub inline fn init(int: u30) RouteBundleIndex {
        return @enumFromInt(int);
    }
    pub inline fn get(i: RouteBundleIndex) u30 {
        return @intFromEnum(i);
    }
};

// `bun.bake.DevServer.ConsoleLogKind` — verbatim from upstream
// (src/runtime/bake/DevServer.zig line 3977).
pub const ConsoleLogKind = enum(u8) {
    log = 'l',
    err = 'e',
};

const InspectorBunFrontendDevServerAgentHandle = opaque {
    const c = struct {
        extern "c" fn InspectorBunFrontendDevServerAgent__notifyClientConnected(agent: *InspectorBunFrontendDevServerAgentHandle, devServerId: i32, connectionId: i32) void;
        extern "c" fn InspectorBunFrontendDevServerAgent__notifyClientDisconnected(agent: *InspectorBunFrontendDevServerAgentHandle, devServerId: i32, connectionId: i32) void;
        extern "c" fn InspectorBunFrontendDevServerAgent__notifyBundleStart(agent: *InspectorBunFrontendDevServerAgentHandle, devServerId: i32, triggerFiles: [*]BunString, triggerFilesLen: usize) void;
        extern "c" fn InspectorBunFrontendDevServerAgent__notifyBundleComplete(agent: *InspectorBunFrontendDevServerAgentHandle, devServerId: i32, durationMs: f64) void;
        extern "c" fn InspectorBunFrontendDevServerAgent__notifyBundleFailed(agent: *InspectorBunFrontendDevServerAgentHandle, devServerId: i32, buildErrorsPayloadBase64: *BunString) void;
        extern "c" fn InspectorBunFrontendDevServerAgent__notifyClientNavigated(agent: *InspectorBunFrontendDevServerAgentHandle, devServerId: i32, connectionId: i32, url: *BunString, routeBundleId: i32) void;
        extern "c" fn InspectorBunFrontendDevServerAgent__notifyClientErrorReported(agent: *InspectorBunFrontendDevServerAgentHandle, devServerId: i32, clientErrorPayloadBase64: *BunString) void;
        extern "c" fn InspectorBunFrontendDevServerAgent__notifyGraphUpdate(agent: *InspectorBunFrontendDevServerAgentHandle, devServerId: i32, visualizerPayloadBase64: *BunString) void;
        extern "c" fn InspectorBunFrontendDevServerAgent__notifyConsoleLog(agent: *InspectorBunFrontendDevServerAgentHandle, devServerId: i32, kind: u8, data: *BunString) void;
    };
    const notifyClientConnected = c.InspectorBunFrontendDevServerAgent__notifyClientConnected;
    const notifyClientDisconnected = c.InspectorBunFrontendDevServerAgent__notifyClientDisconnected;
    const notifyBundleStart = c.InspectorBunFrontendDevServerAgent__notifyBundleStart;
    const notifyBundleComplete = c.InspectorBunFrontendDevServerAgent__notifyBundleComplete;
    const notifyBundleFailed = c.InspectorBunFrontendDevServerAgent__notifyBundleFailed;
    const notifyClientNavigated = c.InspectorBunFrontendDevServerAgent__notifyClientNavigated;
    const notifyClientErrorReported = c.InspectorBunFrontendDevServerAgent__notifyClientErrorReported;
    const notifyGraphUpdate = c.InspectorBunFrontendDevServerAgent__notifyGraphUpdate;
    const notifyConsoleLog = c.InspectorBunFrontendDevServerAgent__notifyConsoleLog;
};

pub const FrontendDevServerAgent = struct {
    next_inspector_connection_id: i32 = 0,
    handle: ?*InspectorBunFrontendDevServerAgentHandle = null,

    pub fn nextConnectionID(this: *FrontendDevServerAgent) i32 {
        const id = this.next_inspector_connection_id;
        this.next_inspector_connection_id +%= 1;
        return id;
    }

    pub fn isEnabled(this: *const FrontendDevServerAgent) bool {
        return this.handle != null;
    }

    pub fn notifyClientConnected(this: *const FrontendDevServerAgent, devServerId: DebuggerId, connectionId: i32) void {
        if (this.handle) |handle| {
            handle.notifyClientConnected(devServerId.get(), connectionId);
        }
    }

    pub fn notifyClientDisconnected(this: *const FrontendDevServerAgent, devServerId: DebuggerId, connectionId: i32) void {
        if (this.handle) |handle| {
            handle.notifyClientDisconnected(devServerId.get(), connectionId);
        }
    }

    pub fn notifyBundleStart(this: *const FrontendDevServerAgent, devServerId: DebuggerId, triggerFiles: []BunString) void {
        if (this.handle) |handle| {
            handle.notifyBundleStart(devServerId.get(), triggerFiles.ptr, triggerFiles.len);
        }
    }

    pub fn notifyBundleComplete(this: *const FrontendDevServerAgent, devServerId: DebuggerId, durationMs: f64) void {
        if (this.handle) |handle| {
            handle.notifyBundleComplete(devServerId.get(), durationMs);
        }
    }

    pub fn notifyBundleFailed(this: *const FrontendDevServerAgent, devServerId: DebuggerId, buildErrorsPayloadBase64: *BunString) void {
        if (this.handle) |handle| {
            handle.notifyBundleFailed(devServerId.get(), buildErrorsPayloadBase64);
        }
    }

    pub fn notifyClientNavigated(
        this: *const FrontendDevServerAgent,
        devServerId: DebuggerId,
        connectionId: i32,
        url: *BunString,
        routeBundleId: ?RouteBundleIndex,
    ) void {
        if (this.handle) |handle| {
            handle.notifyClientNavigated(
                devServerId.get(),
                connectionId,
                url,
                if (routeBundleId) |id| @intCast(id.get()) else -1,
            );
        }
    }

    pub fn notifyClientErrorReported(
        this: *const FrontendDevServerAgent,
        devServerId: DebuggerId,
        clientErrorPayloadBase64: *BunString,
    ) void {
        if (this.handle) |handle| {
            handle.notifyClientErrorReported(devServerId.get(), clientErrorPayloadBase64);
        }
    }

    pub fn notifyGraphUpdate(this: *const FrontendDevServerAgent, devServerId: DebuggerId, visualizerPayloadBase64: *BunString) void {
        if (this.handle) |handle| {
            handle.notifyGraphUpdate(devServerId.get(), visualizerPayloadBase64);
        }
    }

    pub fn notifyConsoleLog(this: FrontendDevServerAgent, devServerId: DebuggerId, kind: ConsoleLogKind, data: *BunString) void {
        if (this.handle) |handle| {
            handle.notifyConsoleLog(devServerId.get(), @intFromEnum(kind), data);
        }
    }

    // NOTE: Upstream re-exports `Bun__InspectorBunFrontendDevServerAgent__setEnabled`
    // which pokes `jsc.VirtualMachine.get().debugger.frontend_dev_server_agent.handle`.
    // `VirtualMachine` / `Debugger` are not yet ported (Phase 12.2); the
    // export re-attaches when they land.
};

pub const BunFrontendDevServerAgent = FrontendDevServerAgent;

const std = @import("std");

test "FrontendDevServerAgent: starts disabled when handle is null" {
    var agent: FrontendDevServerAgent = .{};
    try std.testing.expect(!agent.isEnabled());
    try std.testing.expectEqual(@as(?*InspectorBunFrontendDevServerAgentHandle, null), agent.handle);
}

test "FrontendDevServerAgent: nextConnectionID returns monotonically increasing IDs" {
    var agent: FrontendDevServerAgent = .{};
    try std.testing.expectEqual(@as(i32, 0), agent.nextConnectionID());
    try std.testing.expectEqual(@as(i32, 1), agent.nextConnectionID());
    try std.testing.expectEqual(@as(i32, 2), agent.nextConnectionID());
}

test "FrontendDevServerAgent: nextConnectionID wraps on i32 overflow" {
    var agent: FrontendDevServerAgent = .{ .next_inspector_connection_id = std.math.maxInt(i32) };
    try std.testing.expectEqual(std.math.maxInt(i32), agent.nextConnectionID());
    try std.testing.expectEqual(std.math.minInt(i32), agent.nextConnectionID());
}

test "FrontendDevServerAgent: exposes the expected notify* surface" {
    // Mirrors DOMURL.zig's shape-only test pattern — exercising the methods
    // at runtime would force the C externs to resolve at link time, but the
    // Inspector backend lives in the C++ shared lib that the Home test build
    // doesn't link against. We only verify the public surface compiles and
    // every decl is reachable; the handle-null no-op path is structural
    // (every method body is `if (this.handle) |h| { … }`).
    try std.testing.expect(@hasDecl(FrontendDevServerAgent, "nextConnectionID"));
    try std.testing.expect(@hasDecl(FrontendDevServerAgent, "isEnabled"));
    try std.testing.expect(@hasDecl(FrontendDevServerAgent, "notifyClientConnected"));
    try std.testing.expect(@hasDecl(FrontendDevServerAgent, "notifyClientDisconnected"));
    try std.testing.expect(@hasDecl(FrontendDevServerAgent, "notifyBundleStart"));
    try std.testing.expect(@hasDecl(FrontendDevServerAgent, "notifyBundleComplete"));
    try std.testing.expect(@hasDecl(FrontendDevServerAgent, "notifyBundleFailed"));
    try std.testing.expect(@hasDecl(FrontendDevServerAgent, "notifyClientNavigated"));
    try std.testing.expect(@hasDecl(FrontendDevServerAgent, "notifyClientErrorReported"));
    try std.testing.expect(@hasDecl(FrontendDevServerAgent, "notifyGraphUpdate"));
    try std.testing.expect(@hasDecl(FrontendDevServerAgent, "notifyConsoleLog"));
}

test "DebuggerId / RouteBundleIndex: init round-trips through get" {
    try std.testing.expectEqual(@as(i32, 42), DebuggerId.init(42).get());
    try std.testing.expectEqual(@as(i32, -1), DebuggerId.init(-1).get());
    try std.testing.expectEqual(@as(u30, 0), RouteBundleIndex.init(0).get());
    try std.testing.expectEqual(@as(u30, 1024), RouteBundleIndex.init(1024).get());
}

test "ConsoleLogKind: enum values match wire-protocol bytes" {
    // The C++ Inspector backend reads these as raw u8s — log='l', err='e'.
    try std.testing.expectEqual(@as(u8, 'l'), @intFromEnum(ConsoleLogKind.log));
    try std.testing.expectEqual(@as(u8, 'e'), @intFromEnum(ConsoleLogKind.err));
}
