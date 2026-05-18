// Copied verbatim from bun/src/http/h3_client/AltSvc.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
//
// Naming convention (2026-05-18): `BunXxx` → `Xxx`, `bun` enum tag → `home`.
// Imports rewritten: @import("bun") → @import("home_rt"). Local stubs
// stand in for `bun.strings.{eqlLong,trim}` (not yet in home_rt.strings),
// `bun.Output.scoped` (Home's Output namespace lacks scoped/Visibility),
// and `bun.StringHashMapUnmanaged` (re-exports the std HashMap with the
// matching key context). Each stub matches upstream semantics; refer to
// `packages/runtime/upstream/src/bun.zig` and `bun_core/output.zig`.

//! Alt-Svc (RFC 7838) header handling for the HTTP/3 client.
//!
//! When `--experimental-http3-fetch` / `BUN_FEATURE_FLAG_EXPERIMENTAL_HTTP3_CLIENT`
//! is on, `handleResponseMetadata` calls `record()` for every `Alt-Svc` header
//! and `start_()` calls `lookup()` before opening a TCP socket: if the origin
//! previously advertised `h3`, the request is routed onto the QUIC engine
//! instead. The cache is keyed on the *origin* authority (the host:port the
//! request was sent to) and lives only on the HTTP thread, so it needs no
//! locking.
//!
//! Only same-host alternatives (`h3=":port"` with an empty uri-host) are
//! honored; cross-host alternatives need extra certificate-authority checks
//! (RFC 7838 §2.1) that are out of scope here.

/// One advertised `h3` alternative from an `Alt-Svc` field-value. `port` is
/// the alt-authority port (where QUIC should connect); `ma` is the freshness
/// lifetime in seconds (default 24 h per §3.1).
pub const Entry = struct {
    port: u16,
    ma: u32 = 86400,
};

/// Parse the first usable `h3` alternative out of an `Alt-Svc` field-value, or
/// `null` if none / `clear`. Tolerant of extra whitespace and unknown params.
///
///   Alt-Svc       = clear / 1#alt-value
///   alt-value     = protocol-id "=" alt-authority *( OWS ";" OWS parameter )
///   alt-authority = quoted-string containing [uri-host] ":" port
///
/// Returns `error.Clear` for the literal `clear` so the caller can drop the
/// cache entry.
pub fn parse(field_value: []const u8) error{Clear}!?Entry {
    const value = trim(field_value, " \t");
    if (value.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(value, "clear")) return error.Clear;

    var entries = std.mem.splitScalar(u8, value, ',');
    while (entries.next()) |raw_entry| {
        const entry = trim(raw_entry, " \t");
        if (entry.len == 0) continue;

        var params = std.mem.splitScalar(u8, entry, ';');
        const alternative = trim(params.first(), " \t");

        const eq = home_rt.strings.indexOfChar(alternative, '=') orelse continue;
        const proto = alternative[0..eq];
        // Only the final IETF "h3" ALPN token; draft `h3-NN` versions are
        // ignored since lsquic is built for the final spec.
        if (!std.ascii.eqlIgnoreCase(proto, "h3")) continue;

        // alt-authority is a quoted-string: `":443"` or `"host:443"`.
        var auth = trim(alternative[eq + 1 ..], " \t");
        if (auth.len >= 2 and auth[0] == '"' and auth[auth.len - 1] == '"') {
            auth = auth[1 .. auth.len - 1];
        }
        const colon = std.mem.lastIndexOfScalar(u8, auth, ':') orelse continue;
        // Same-host alternatives only (empty uri-host).
        if (colon != 0) continue;
        const port = std.fmt.parseInt(u16, auth[colon + 1 ..], 10) catch continue;
        if (port == 0) continue;

        var result: Entry = .{ .port = port };
        while (params.next()) |raw_param| {
            const param = trim(raw_param, " \t");
            const peq = home_rt.strings.indexOfChar(param, '=') orelse continue;
            if (std.ascii.eqlIgnoreCase(param[0..peq], "ma")) {
                result.ma = std.fmt.parseInt(u32, param[peq + 1 ..], 10) catch result.ma;
            }
            // `persist` and unknown parameters are ignored (§3.1).
        }
        return result;
    }
    return null;
}

/// HTTP-thread-only Alt-Svc cache. Key is `"hostname:port"` of the origin the
/// header was received from; value is the advertised h3 port + expiry.
const Record = struct {
    h3_port: u16,
    expires_at: i64,
};

var cache: StringHashMapUnmanaged(Record) = .{};

/// Hard cap on cached origins. When reached, `record()` first sweeps expired
/// entries and then refuses the new insert if still full — bounded memory for
/// long-lived processes that hit many distinct origins.
const max_entries = 256;

fn key(buf: []u8, hostname: []const u8, port: u16) []const u8 {
    // Callers guard `hostname.len > 256` against a `256+8` buffer, and a u16
    // port is at most 5 digits + ':' — bufPrint cannot overflow.
    return std.fmt.bufPrint(buf, "{s}:{d}", .{ hostname, port }) catch unreachable;
}

fn sweepExpired(now: i64) void {
    var it = cache.iterator();
    while (it.next()) |kv| {
        if (now >= kv.value_ptr.expires_at) {
            const owned = kv.key_ptr.*;
            cache.removeByPtr(kv.key_ptr);
            home_rt.default_allocator.free(owned);
            // Unmanaged hash-map iteration is not removal-safe; restart.
            it = cache.iterator();
        }
    }
}

/// Remember (or refresh / clear) the h3 alternative for `origin_host:origin_port`
/// from a received `Alt-Svc` field-value. Runs on the HTTP thread inside
/// `handleResponseMetadata`.
pub fn record(origin_host: []const u8, origin_port: u16, field_value: []const u8) void {
    var buf: [256 + 8]u8 = undefined;
    if (origin_host.len > 256) return;
    const k = key(&buf, origin_host, origin_port);

    const entry = parse(field_value) catch {
        // `clear`
        if (cache.fetchRemove(k)) |kv| home_rt.default_allocator.free(kv.key);
        log("alt-svc clear {s}", .{k});
        return;
    } orelse return;

    const now = nowSeconds();
    if (cache.count() >= max_entries and !cache.contains(k)) {
        sweepExpired(now);
        if (cache.count() >= max_entries) return;
    }
    const gop = home_rt.handleOom(cache.getOrPut(home_rt.default_allocator, k));
    if (!gop.found_existing) {
        gop.key_ptr.* = home_rt.handleOom(home_rt.default_allocator.dupe(u8, k));
    }
    gop.value_ptr.* = .{
        .h3_port = entry.port,
        .expires_at = now + @as(i64, entry.ma),
    };
    log("alt-svc h3 {s} -> :{d} ma={d}", .{ k, entry.port, entry.ma });
}

/// Look up a previously-advertised h3 alternative for `origin_host:origin_port`.
/// Expired entries are dropped on access. Runs on the HTTP thread inside
/// `start_()`.
pub fn lookup(origin_host: []const u8, origin_port: u16) ?u16 {
    var buf: [256 + 8]u8 = undefined;
    if (origin_host.len > 256) return null;
    const k = key(&buf, origin_host, origin_port);
    const rec = cache.get(k) orelse return null;
    if (nowSeconds() >= rec.expires_at) {
        if (cache.fetchRemove(k)) |kv| home_rt.default_allocator.free(kv.key);
        return null;
    }
    return rec.h3_port;
}

// ---------------------------------------------------------------------------
// Local stubs (off-list bun.X symbols)
// ---------------------------------------------------------------------------

/// `std.mem.trim(u8, ...)` shim mirroring `bun.strings.trim`. Upstream
/// callers spell `strings.trim(slice, " \t")`; Home routes through std.
inline fn trim(slice: []const u8, chars: []const u8) []const u8 {
    return std.mem.trim(u8, slice, chars);
}

/// `bun.Output.scoped(.h3_client, .hidden)` returns a comptime-known
/// no-op logger in hidden visibility unless the matching env var is set;
/// Home's Output namespace doesn't yet have scoped/Visibility so emit a
/// release-build-stripped stub instead. Stays signature-compatible with
/// the upstream `LogFunction` (comptime fmt + anytype args).
fn log(comptime fmt: []const u8, args: anytype) void {
    _ = fmt;
    _ = args;
}

/// `std.time.timestamp()` was removed in Zig 0.17 (replaced by the
/// `std.Io.Clock` interface). Use `posix.clock_gettime` directly so
/// we don't need an `Io` instance for what is a leaf data module.
fn nowSeconds() i64 {
    var ts: std.posix.timespec = undefined;
    switch (std.posix.errno(std.posix.system.clock_gettime(.REALTIME, &ts))) {
        .SUCCESS => return @intCast(ts.sec),
        else => return 0,
    }
}

/// `bun.StringHashMapUnmanaged(V)` is `std.HashMapUnmanaged([]const u8, V,
/// StringHashMapContext, default_max_load_percentage)` — re-export the
/// std HashMap with the same byte-slice key context so cache state
/// behaves identically.
fn StringHashMapUnmanaged(comptime V: type) type {
    return std.HashMapUnmanaged(
        []const u8,
        V,
        std.hash_map.StringContext,
        std.hash_map.default_max_load_percentage,
    );
}

const std = @import("std");
const home_rt = @import("home_rt");

test "AltSvc.parse handles same-host h3 alternative" {
    const entry = (try parse("h3=\":443\"; ma=3600")).?;
    try std.testing.expectEqual(@as(u16, 443), entry.port);
    try std.testing.expectEqual(@as(u32, 3600), entry.ma);
}

test "AltSvc.parse skips draft h3 / cross-host / zero port" {
    // draft tokens (`h3-29`) and other protocols are skipped.
    try std.testing.expect((try parse("h3-29=\":443\"")) == null);
    try std.testing.expect((try parse("h2=\":443\"")) == null);
    // cross-host (uri-host non-empty) is rejected.
    try std.testing.expect((try parse("h3=\"alt.example:443\"")) == null);
    // port==0 is invalid per §3.
    try std.testing.expect((try parse("h3=\":0\"")) == null);
}

test "AltSvc.parse returns error.Clear for the literal 'clear'" {
    try std.testing.expectError(error.Clear, parse("clear"));
    try std.testing.expectError(error.Clear, parse("  CLEAR  "));
}

test "AltSvc.parse defaults ma to 24h when omitted" {
    const entry = (try parse("h3=\":443\"")).?;
    try std.testing.expectEqual(@as(u16, 443), entry.port);
    try std.testing.expectEqual(@as(u32, 86400), entry.ma);
}

test "AltSvc.parse picks the first usable h3 entry from a list" {
    const entry = (try parse("h2=\":443\", h3=\":8443\"; ma=60")).?;
    try std.testing.expectEqual(@as(u16, 8443), entry.port);
    try std.testing.expectEqual(@as(u32, 60), entry.ma);
}

test "AltSvc.record + lookup round-trip" {
    // Each test runs against the module-level cache; clean up afterwards
    // so subsequent runs (and the rest of the test binary) start fresh.
    defer {
        var it = cache.iterator();
        while (it.next()) |kv| home_rt.default_allocator.free(kv.key_ptr.*);
        cache.deinit(home_rt.default_allocator);
        cache = .{};
    }

    record("example.com", 443, "h3=\":8443\"; ma=120");
    try std.testing.expectEqual(@as(?u16, 8443), lookup("example.com", 443));
    try std.testing.expect(lookup("other.com", 443) == null);

    // `clear` drops the entry.
    record("example.com", 443, "clear");
    try std.testing.expect(lookup("example.com", 443) == null);
}
