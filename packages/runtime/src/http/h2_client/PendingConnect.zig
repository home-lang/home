// Copied from bun/src/http/h2_client/PendingConnect.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
//
// Naming convention (2026-05-18): `BunXxx` → `Xxx`, `bun` enum tag → `home`.
// Imports rewritten: @import("bun") → @import("home").

//! Placeholder registered while a fresh TLS connect is in flight so that
//! concurrent h2-capable requests to the same origin coalesce onto its
//! eventual session instead of each opening a separate socket.

pub const new = home_rt.TrivialNew(@This());

hostname: []const u8,
port: u16,
ssl_config: ?*SSLConfig,
/// Host-header SNI-override hash: a request carrying an override must not
/// coalesce onto a pending connect verified for a different host.
host_header_hash: u64 = 0,
waiters: std.ArrayListUnmanaged(*HTTPClient) = .empty,

pub fn matches(this: *const @This(), hostname: []const u8, port: u16, ssl_config: ?*SSLConfig, host_header_hash: u64) bool {
    return this.port == port and this.ssl_config == ssl_config and this.host_header_hash == host_header_hash and eqlLong(this.hostname, hostname);
}

pub fn unregisterFrom(this: *@This(), ctx: *NewHTTPContext(true)) void {
    const list = &ctx.pending_h2_connects;
    for (list.items, 0..) |p, i| {
        if (p == this) {
            _ = list.swapRemove(i);
            return;
        }
    }
}

pub fn deinit(this: *@This()) void {
    home_rt.default_allocator.free(this.hostname);
    this.waiters.deinit(home_rt.default_allocator);
    home_rt.destroy(this);
}

inline fn eqlLong(a: []const u8, b: []const u8) bool {
    return strings.eqlLong(a, b, true);
}

const std = @import("std");
const home_rt = @import("home");
const strings = home_rt.strings;
const SSLConfig = home_rt.api.server.ServerConfig.SSLConfig;
const HTTPClient = home_rt.http;
const NewHTTPContext = HTTPClient.NewHTTPContext;

test "PendingConnect.matches: same hostname + port + ssl_config" {
    const hostname = "example.com";
    const ssl_a: *SSLConfig = @ptrFromInt(0xdead_0000);

    const pc: @This() = .{
        .hostname = hostname,
        .port = 443,
        .ssl_config = ssl_a,
    };
    try std.testing.expect(pc.matches("example.com", 443, ssl_a, 0));
    try std.testing.expect(!pc.matches("example.com", 8443, ssl_a, 0));
    try std.testing.expect(!pc.matches("other.com", 443, ssl_a, 0));
}

test "PendingConnect.matches: ssl_config identity is part of the key" {
    const ssl_a: *SSLConfig = @ptrFromInt(0xdead_0000);
    const ssl_b: *SSLConfig = @ptrFromInt(0xbeef_0000);

    const pc: @This() = .{
        .hostname = "example.com",
        .port = 443,
        .ssl_config = ssl_a,
    };
    try std.testing.expect(!pc.matches("example.com", 443, ssl_b, 0));
    try std.testing.expect(!pc.matches("example.com", 443, null, 0));
}

test "PendingConnect.matches: null ssl_config (cleartext) is its own key" {
    const ssl_a: *SSLConfig = @ptrFromInt(0xdead_0000);

    const pc: @This() = .{
        .hostname = "example.com",
        .port = 80,
        .ssl_config = null,
    };
    try std.testing.expect(pc.matches("example.com", 80, null, 0));
    try std.testing.expect(!pc.matches("example.com", 80, ssl_a, 0));
}

test "PendingConnect.unregisterFrom: removes the matching entry" {
    var pc_a: @This() = .{
        .hostname = "a.com",
        .port = 443,
        .ssl_config = null,
    };
    var pc_b: @This() = .{
        .hostname = "b.com",
        .port = 443,
        .ssl_config = null,
    };

    var ctx: NewHTTPContext(true) = .{
        .ref_count = .init(),
        .pending_sockets = NewHTTPContext(true).PooledSocketHiveAllocator.empty,
    };
    ctx.pending_h2_connects = .empty;
    defer ctx.pending_h2_connects.deinit(home_rt.default_allocator);

    try ctx.pending_h2_connects.append(home_rt.default_allocator, &pc_a);
    try ctx.pending_h2_connects.append(home_rt.default_allocator, &pc_b);
    try std.testing.expectEqual(@as(usize, 2), ctx.pending_h2_connects.items.len);

    pc_a.unregisterFrom(&ctx);
    try std.testing.expectEqual(@as(usize, 1), ctx.pending_h2_connects.items.len);
    try std.testing.expectEqual(&pc_b, ctx.pending_h2_connects.items[0]);

    // Removing the same entry a second time is a silent no-op.
    pc_a.unregisterFrom(&ctx);
    try std.testing.expectEqual(@as(usize, 1), ctx.pending_h2_connects.items.len);
}
