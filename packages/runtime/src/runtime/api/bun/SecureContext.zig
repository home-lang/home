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

/// User-created contexts must own a distinct SSL_CTX: addCACert must never
/// mutate another user's context or the internal per-digest cache.
pub fn createPrivate(global: *jsc.JSGlobalObject, callframe: *jsc.CallFrame) bun.JSError!jsc.JSValue {
    const args = callframe.arguments();
    var config = (try SSLConfig.fromJS(global.bunVM(), global, if (args.len > 0) args[0] else .js_undefined)) orelse SSLConfig.zero;
    defer config.deinit();
    const opts = config.asUSockets();
    var err: uws.create_bun_socket_error_t = .none;
    const ctx = opts.createSSLContext(&err) orelse {
        if (err == .none or err == .invalid_ciphers) {
            const code = BoringSSL.ERR_get_error();
            if (code != 0) return global.throwValue(bun.BoringSSL.ERR_toJS(global, code));
            if (err == .none) return global.throw("Failed to create SSL context", .{});
        }
        return global.throwValue(err.toJS(global));
    };
    return bun.new(SecureContext, .{
        .ctx = ctx,
        .digest = opts.digest(),
        .extra_memory = opts.approxCertBytes() + ssl_ctx_base_cost,
    }).toJS(global);
}

pub fn addCACert(this: *SecureContext, global: *jsc.JSGlobalObject, frame: *jsc.CallFrame) bun.JSError!jsc.JSValue {
    const args = frame.arguments();
    if (args.len == 0) return global.throwInvalidArguments("addCACert requires a certificate", .{});
    const pem = try args[0].toSlice(global, bun.default_allocator);
    defer pem.deinit();
    if (pem.len == 0) return global.throwInvalidArguments("addCACert requires a certificate", .{});
    const owned = try bun.dupeZ(bun.default_allocator, u8, pem.slice());
    defer bun.default_allocator.free(owned);
    if (native.us_ssl_ctx_add_ca_cert(this.ctx, owned) == 0) return global.throw("Invalid CA certificate", .{});
    return .js_undefined;
}

/// Preserve binary DER and coerce the passphrase before borrowing the input:
/// its toString() may detach an ArrayBuffer passed as the first argument.
pub fn parsePkcs12(global: *jsc.JSGlobalObject, frame: *jsc.CallFrame) bun.JSError!jsc.JSValue {
    const args = frame.arguments();
    if (args.len == 0) return global.throw("PFX certificate argument is mandatory", .{});
    var pass: ?[:0]u8 = null;
    defer if (pass) |value| bun.freeSensitive(bun.default_allocator, value);
    if (args.len > 1 and !args[1].isUndefinedOrNull()) {
        const value = try args[1].toSlice(global, bun.default_allocator);
        defer value.deinit();
        pass = try bun.dupeZ(bun.default_allocator, u8, value.slice());
    }
    var text: ?jsc.ZigString.Slice = null;
    defer if (text) |value| value.deinit();
    const bytes = if (args[0].asArrayBuffer(global)) |ab| ab.byteSlice() else blk: {
        text = try args[0].toSlice(global, bun.default_allocator);
        break :blk text.?.slice();
    };
    if (bytes.len == 0) return global.throw("PFX certificate argument is mandatory", .{});
    var key: ?[*]u8 = null;
    var cert: ?[*]u8 = null;
    var ca: ?[*]u8 = null;
    var key_len: usize = 0;
    var cert_len: usize = 0;
    var ca_len: usize = 0;
    var reason: ?[*:0]const u8 = null;
    if (native.us_ssl_parse_pkcs12(bytes.ptr, bytes.len, if (pass) |value| value.ptr else null, &key, &key_len, &cert, &cert_len, &ca, &ca_len, &reason) == 0) {
        const tag = if (reason) |value| std.mem.span(value) else "";
        if (std.mem.eql(u8, tag, "key")) return global.throw("Unable to load private key from PFX data", .{});
        if (std.mem.eql(u8, tag, "cert")) return global.throw("Unable to load certificate from PFX data", .{});
        if (std.mem.eql(u8, tag, "mac")) return global.throw("PFX MAC verification failed - is the passphrase correct?", .{});
        return global.throw("Unable to load PFX certificate", .{});
    }
    // The helper allocates with malloc; these are not bun allocator buffers.
    defer native.free(@ptrCast(key));
    defer native.free(@ptrCast(cert));
    defer native.free(@ptrCast(ca));
    const result = jsc.JSValue.createEmptyObject(global, 0);
    result.put(global, "key", jsc.ZigString.init(key.?[0..key_len]).toJS(global));
    result.put(global, "cert", jsc.ZigString.init(cert.?[0..cert_len]).toJS(global));
    if (ca != null and ca_len > 0) result.put(global, "ca", jsc.ZigString.init(ca.?[0..ca_len]).toJS(global));
    return result;
}

// The retained class generator predates these pinned native entry points.
// Use the same checked host-function ABI without keeping no-op exports.
comptime {
    @export(&jsc.toJSHostFn(createPrivate), .{ .name = "SecureContextClass__create_private" });
    @export(&jsc.toJSHostFn(parsePkcs12), .{ .name = "SecureContextClass__parse_pkcs12" });
    @export(&jsc.host_fn.toJSHostFnWithContext(SecureContext, addCACert), .{ .name = "SecureContextPrototype__add_ca_cert" });
}

const native = struct {
    extern fn us_ssl_ctx_add_ca_cert(*BoringSSL.SSL_CTX, [*:0]const u8) c_int;
    extern fn us_ssl_parse_pkcs12([*]const u8, usize, ?[*:0]const u8, *?[*]u8, *usize, *?[*]u8, *usize, *?[*]u8, *usize, *?[*:0]const u8) c_int;
    extern fn free(?*anyopaque) void;
};

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

/// Internal contexts are WeakGCMap-memoised by config digest so identical
/// configs share a live cell; misses use the native SSLContextCache.
/// User-created `tls.createSecureContext(opts)` contexts use createPrivate.
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
