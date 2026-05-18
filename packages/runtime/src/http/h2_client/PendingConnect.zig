// Copied from bun/src/http/h2_client/PendingConnect.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
//
// Naming convention (2026-05-18): `BunXxx` → `Xxx`, `bun` enum tag → `home`.
// Imports rewritten: @import("bun") → @import("home_rt"). Local opaque
// stubs stand in for `HTTPClient` (upstream's fetch() state machine),
// `NewHTTPContext` (the per-thread connection pool), and `SSLConfig`
// (which lives under `bun.api.server.ServerConfig` and pulls in JSC).
// `bun.strings.eqlLong` is shimmed via std.mem.eql because home_rt's
// strings module doesn't expose the SIMD-backed variant yet. The
// matcher / unregister logic is exercised by the inline tests against
// the opaque pointer values they take.

//! Placeholder registered while a fresh TLS connect is in flight so that
//! concurrent h2-capable requests to the same origin coalesce onto its
//! eventual session instead of each opening a separate socket.

pub const new = trivialNew(@This());

hostname: []const u8,
port: u16,
ssl_config: ?*SSLConfig,
waiters: std.ArrayListUnmanaged(*HTTPClient) = .empty,

pub fn matches(this: *const @This(), hostname: []const u8, port: u16, ssl_config: ?*SSLConfig) bool {
    return this.port == port and this.ssl_config == ssl_config and eqlLong(this.hostname, hostname);
}

pub fn unregisterFrom(this: *@This(), ctx: *NewHTTPContext) void {
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
    destroy(this);
}

// ---------------------------------------------------------------------------
// Local stubs (off-list bun.X symbols)
// ---------------------------------------------------------------------------

/// Upstream `bun.http` (the HTTPClient struct) — opaque until the fetch()
/// state machine ports.
pub const HTTPClient = opaque {};

/// Upstream uses `HTTPClient.NewHTTPContext(true)` — the per-thread
/// connection pool parameterised on TLS-on-or-off. The only piece used
/// here is the `pending_h2_connects: std.ArrayListUnmanaged(*PendingConnect)`
/// field, so shape the stub to match exactly.
pub const NewHTTPContext = struct {
    pending_h2_connects: std.ArrayListUnmanaged(*@This().Outer) = .empty,

    pub const Outer = @import("PendingConnect.zig");
};

/// `bun.api.server.ServerConfig.SSLConfig` — the BoringSSL configuration
/// blob. We only need its identity (pointer equality) for the `matches`
/// guard, so an opaque is enough.
pub const SSLConfig = opaque {};

/// `bun.strings.eqlLong(a, b, true)` — SIMD-backed byte comparison.
/// `std.mem.eql` is correct, just not vectorised; identical for
/// short hostnames the matcher always sees.
inline fn eqlLong(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// `bun.TrivialNew` shim — allocates via `home_rt.default_allocator`.
fn trivialNew(comptime T: type) fn (T) *T {
    return struct {
        fn create(value: T) *T {
            const ptr = home_rt.default_allocator.create(T) catch
                @panic("OOM in PendingConnect.new");
            ptr.* = value;
            return ptr;
        }
    }.create;
}

/// `bun.destroy` shim.
fn destroy(ptr: anytype) void {
    home_rt.default_allocator.destroy(ptr);
}

const std = @import("std");
const home_rt = @import("home_rt");

test "PendingConnect.matches: same hostname + port + ssl_config" {
    const hostname = "example.com";
    const ssl_a: *SSLConfig = @ptrFromInt(0xdead_0000);

    const pc: @This() = .{
        .hostname = hostname,
        .port = 443,
        .ssl_config = ssl_a,
    };
    try std.testing.expect(pc.matches("example.com", 443, ssl_a));
    try std.testing.expect(!pc.matches("example.com", 8443, ssl_a));
    try std.testing.expect(!pc.matches("other.com", 443, ssl_a));
}

test "PendingConnect.matches: ssl_config identity is part of the key" {
    const ssl_a: *SSLConfig = @ptrFromInt(0xdead_0000);
    const ssl_b: *SSLConfig = @ptrFromInt(0xbeef_0000);

    const pc: @This() = .{
        .hostname = "example.com",
        .port = 443,
        .ssl_config = ssl_a,
    };
    try std.testing.expect(!pc.matches("example.com", 443, ssl_b));
    try std.testing.expect(!pc.matches("example.com", 443, null));
}

test "PendingConnect.matches: null ssl_config (cleartext) is its own key" {
    const ssl_a: *SSLConfig = @ptrFromInt(0xdead_0000);

    const pc: @This() = .{
        .hostname = "example.com",
        .port = 80,
        .ssl_config = null,
    };
    try std.testing.expect(pc.matches("example.com", 80, null));
    try std.testing.expect(!pc.matches("example.com", 80, ssl_a));
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

    var ctx: NewHTTPContext = .{};
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
