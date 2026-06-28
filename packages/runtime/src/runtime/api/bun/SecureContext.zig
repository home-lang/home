// Copied from bun/src/runtime/api/bun/SecureContext.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../../cli/LICENSE.bun.md.
//
// Re-attached 2026-06-27 (was a fully-parked stub): every dependency has landed
// — `jsc.Codegen.JSSecureContext` (ZigGeneratedClasses), the `SecureContext__*`
// + `Bun__SecureContextCache__*` C++ externs (linked), `SSLConfig.fromJS/
// asUSockets`, and `rareData().sslCtxCache().getOrCreateDigest` (the same cache
// Listener/WebSocket already use). Without this, `node:tls`'s
// `NativeSecureContext = $zig("SecureContext.zig","js.getConstructor")` was a
// noop → `.intern` undefined → ~80 node-tls tests failed.

//! Native backing for `node:tls` `SecureContext`. Owns one BoringSSL
//! `SSL_CTX*`; every `tls.connect`/`upgradeTLS`/`addContext` that names this
//! object passes that pointer to listen/connect/adopt, where `SSL_new()`
//! up-refs it for each socket.
//!
//! `intern()` memoises by config digest at two levels: a `WeakGCMap` on the
//! global and the per-VM native `SSLContextCache` (same digest → same
//! `SSL_CTX*`). The "one config, thousands of connections" pattern allocates
//! one of these and one `SSL_CTX` total.
const SecureContext = @This();

pub const js = jsc.Codegen.JSSecureContext;
pub const toJS = js.toJS;
pub const fromJS = js.fromJS;
pub const fromJSDirect = js.fromJSDirect;

ctx: *BoringSSL.SSL_CTX,
/// `BunSocketContextOptions.digest()` — the fields that reach
/// `us_ssl_ctx_from_options`. Stored so an `intern()` WeakGCMap hit (keyed by
/// the low 64 bits) can do a full content-equality check before reusing.
digest: [32]u8,
/// Approximate cert/key/CA byte length plus the BoringSSL `SSL_CTX` floor
/// (~50 KB), so the GC can account for the off-heap allocation.
extra_memory: usize,

pub fn constructor(global: *jsc.JSGlobalObject, callframe: *jsc.CallFrame) bun.JSError!*SecureContext {
    const args = callframe.arguments();
    const opts = if (args.len > 0) args[0] else .js_undefined;

    var config = (try SSLConfig.fromJS(global.bunVM(), global, opts)) orelse SSLConfig.zero;
    defer config.deinit();

    return try create(global, &config);
}

/// Mode-neutral: Node lets one `SecureContext` back both `tls.connect()` and
/// `tls.createServer({secureContext})`, so we cannot bake client-vs-server into
/// the `SSL_CTX`. The per-socket attach overrides client SSLs to
/// `SSL_VERIFY_PEER` so chain validation always runs.
pub fn create(global: *jsc.JSGlobalObject, config: *const SSLConfig) bun.JSError!*SecureContext {
    const ctx_opts = config.asUSockets();
    return createWithDigest(global, ctx_opts, ctx_opts.digest());
}

fn createWithDigest(global: *jsc.JSGlobalObject, ctx_opts: uws.SocketContext.BunSocketContextOptions, d: [32]u8) bun.JSError!*SecureContext {
    var err: uws.create_bun_socket_error_t = .none;
    const ctx = global.bunVM().rareData().sslCtxCache().getOrCreateDigest(ctx_opts, d, &err) orelse {
        // `err` is only set for the input-validation paths (bad PEM, missing
        // file, …). When BoringSSL itself fails the enum is still `.none`;
        // surface the library error stack instead of an empty placeholder.
        if (err == .none) {
            const code = BoringSSL.ERR_get_error();
            if (code != 0) return global.throwValue(bun.BoringSSL.ERR_toJS(global, code));
            return global.throw("Failed to create SSL context", .{});
        }
        return global.throwValue(err.toJS(global));
    };
    return bun.new(SecureContext, .{
        .ctx = ctx,
        .digest = d,
        .extra_memory = ctx_opts.approxCertBytes() + ssl_ctx_base_cost,
    });
}

/// `tls.createSecureContext(opts)` entry point. WeakGCMap-memoised by config
/// digest so identical configs return the same `JSSecureContext` cell while
/// alive; falls through to `create()` (which itself hits the native
/// `SSLContextCache`) on miss.
pub fn intern(global: *jsc.JSGlobalObject, callframe: *jsc.CallFrame) bun.JSError!jsc.JSValue {
    const args = callframe.arguments();
    const opts = if (args.len > 0) args[0] else .js_undefined;

    var config = (try SSLConfig.fromJS(global.bunVM(), global, opts)) orelse SSLConfig.zero;
    defer config.deinit();

    const ctx_opts = config.asUSockets();
    const d = ctx_opts.digest();
    const key = std.mem.readInt(u64, d[0..8], .little);

    const cached = cpp.Bun__SecureContextCache__get(global, key);
    if (cached != .zero) {
        if (fromJS(cached)) |existing| {
            // 64-bit key collision is ~2⁻⁶⁴ but a false hit hands the wrong
            // cert to a connection. Full-digest compare is 32 bytes; cheap.
            if (bun.strings.eqlLong(&existing.digest, &d, false)) {
                return cached;
            }
        }
    }

    const sc = try createWithDigest(global, ctx_opts, d);
    const value = sc.toJS(global);
    cpp.Bun__SecureContextCache__set(global, key, value);
    return value;
}

/// `SSL_CTX_up_ref` and return — for callers that want to outlive this
/// wrapper's GC. Most paths just pass `this.ctx` directly and let `SSL_new`
/// take its own ref.
pub fn borrow(this: *SecureContext) *BoringSSL.SSL_CTX {
    _ = BoringSSL.SSL_CTX_up_ref(this.ctx);
    return this.ctx;
}

pub fn finalize(this: *SecureContext) callconv(.c) void {
    BoringSSL.SSL_CTX_free(this.ctx);
    bun.destroy(this);
}

pub fn memoryCost(this: *SecureContext) usize {
    return @sizeOf(SecureContext) + this.extra_memory;
}

/// Exposed via `bun:internal-for-testing` so churn tests can assert
/// `SSL_CTX_new` was called O(1) times, not O(connections).
pub fn jsLiveCount(_: *jsc.JSGlobalObject, _: *jsc.CallFrame) bun.JSError!jsc.JSValue {
    return jsc.JSValue.jsNumber(c.us_ssl_ctx_live_count());
}

const ssl_ctx_base_cost: usize = 50 * 1024;

pub const c = uws.SocketContext.c;

const cpp = struct {
    pub extern fn Bun__SecureContextCache__get(*jsc.JSGlobalObject, u64) jsc.JSValue;
    pub extern fn Bun__SecureContextCache__set(*jsc.JSGlobalObject, u64, jsc.JSValue) void;
};

const std = @import("std");

const bun = @import("home");
const jsc = bun.jsc;
const uws = bun.uws;
const BoringSSL = bun.BoringSSL.c;
const SSLConfig = jsc.API.ServerConfig.SSLConfig;
