// Copied from bun/src/runtime/api/bun/SecureContext.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../../cli/LICENSE.bun.md.
//
// Rewrites:
//   - @import("bun") → @import("home_rt")
//
// Stubs (re-attach in Phase 12.2 when home_rt grows the matching surface):
//   - `jsc.JSGlobalObject`, `jsc.CallFrame`, `JSValue`, `JSError`,
//     `jsc.Codegen.JSSecureContext` — not yet exposed on home_rt; the
//     `constructor`, `intern`, `borrow`, `finalize`, `memoryCost`,
//     `jsLiveCount` entry points are kept as skeletons that touch the
//     parked symbols through opaque types.
//   - `uws.SocketContext.BunSocketContextOptions`, `uws.create_bun_socket_error_t`,
//     `SSLConfig`, `BoringSSL.SSL_CTX`, `BoringSSL.ERR_*` — opaque +
//     function-pointer-indirected so the file builds standalone.
//   - `bun.new`/`bun.destroy` substitute via `home_rt.default_allocator`.
//   - `Bun__SecureContextCache__get`/`set` — fn-ptr indirection.
//
// Pure-Zig pieces (the `extra_memory`/`memoryCost` accounting and the
// `digest` field layout) are exercised by tests.

//! Native backing for `node:tls` `SecureContext`. Owns one BoringSSL
//! `SSL_CTX*`; every `tls.connect`/`upgradeTLS`/`addContext` that names this
//! object passes that pointer to listen/connect/adopt, where `SSL_new()`
//! up-refs it for each socket.
//!
//! `intern()` memoises by config digest at two levels: a `WeakGCMap` on the
//! global and the per-VM native `SSLContextCache`. The "one config, thousands
//! of connections" pattern allocates one of these and one `SSL_CTX` total.

const SecureContext = @This();

// JS-side codegen surface — parked until home_rt.jsc.Codegen lands.
pub const js = struct {
    pub fn toJS(_: *SecureContext, _: *JSGlobalObject) JSValue {
        return .zero;
    }
    pub fn fromJS(_: JSValue) ?*SecureContext {
        return null;
    }
    pub fn fromJSDirect(_: JSValue) ?*SecureContext {
        return null;
    }
};
pub const toJS = js.toJS;
pub const fromJS = js.fromJS;
pub const fromJSDirect = js.fromJSDirect;

ctx: *BoringSSL.SSL_CTX,
/// `BunSocketContextOptions.digest()` — exactly the fields that reach
/// `us_ssl_ctx_from_options`. Stored so an `intern()` WeakGCMap hit (keyed by
/// the low 64 bits) can do a full content-equality check before reusing.
digest: [32]u8,
/// Approximate cert/key/CA byte length plus the BoringSSL `SSL_CTX` floor
/// (~50 KB), so the GC can account for the off-heap allocation.
extra_memory: usize,

pub fn constructor(global: *JSGlobalObject, callframe: *CallFrame) JSError!*SecureContext {
    _ = callframe;
    // Body parked — depends on SSLConfig.fromJS / config.deinit / create.
    return create(global, &SSLConfig.zero);
}

/// Mode-neutral: Node lets one `SecureContext` back both `tls.connect()` and
/// `tls.createServer({secureContext})`, so we cannot bake client-vs-server
/// into the `SSL_CTX`.
pub fn create(global: *JSGlobalObject, config: *const SSLConfig) JSError!*SecureContext {
    const ctx_opts = config.asUSockets();
    return createWithDigest(global, ctx_opts, ctx_opts.digest());
}

fn createWithDigest(global: *JSGlobalObject, ctx_opts: uws.SocketContext.BunSocketContextOptions, d: [32]u8) JSError!*SecureContext {
    _ = global;
    // Body parked — depends on rareData().sslCtxCache().getOrCreateDigest()
    // + BoringSSL.ERR_get_error / ERR_toJS. The accounting/`new` path stays
    // wired so callers see a real allocation when the wire-up TU plugs in
    // the cache pointer.
    const fake_ctx: *BoringSSL.SSL_CTX = @ptrFromInt(0xCAFE_BABE);
    return newSC(.{
        .ctx = fake_ctx,
        .digest = d,
        .extra_memory = ctx_opts.approxCertBytes() + ssl_ctx_base_cost,
    });
}

/// `tls.createSecureContext(opts)` entry point. Body parked.
pub fn intern(global: *JSGlobalObject, callframe: *CallFrame) JSError!JSValue {
    _ = global;
    _ = callframe;
    return .zero;
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
    destroySC(this);
}

pub fn memoryCost(this: *SecureContext) usize {
    return @sizeOf(SecureContext) + this.extra_memory;
}

/// Exposed via `bun:internal-for-testing` so churn tests can assert
/// `SSL_CTX_new` was called O(1) times, not O(connections).
pub fn jsLiveCount(_: *JSGlobalObject, _: *CallFrame) JSError!JSValue {
    return .zero;
}

const ssl_ctx_base_cost: usize = 50 * 1024;

pub const c = uws.SocketContext.c;

// Cache-cell hooks — fn-ptr-indirected so the file builds standalone.
const cpp = struct {
    pub var Bun__SecureContextCache__get: *const fn (*JSGlobalObject, u64) callconv(.c) JSValue = stub_cache_get;
    pub var Bun__SecureContextCache__set: *const fn (*JSGlobalObject, u64, JSValue) callconv(.c) void = stub_cache_set;

    fn stub_cache_get(_: *JSGlobalObject, _: u64) callconv(.c) JSValue {
        return .zero;
    }
    fn stub_cache_set(_: *JSGlobalObject, _: u64, _: JSValue) callconv(.c) void {}
};

// ============================================================================
// Local helpers (substitutes for bun.new / bun.destroy)
// ============================================================================

fn newSC(value: SecureContext) *SecureContext {
    const p = home_rt.default_allocator.create(SecureContext) catch @panic("out of memory");
    p.* = value;
    return p;
}

fn destroySC(p: *SecureContext) void {
    home_rt.default_allocator.destroy(p);
}

const std = @import("std");
const home_rt = @import("home_rt");

// ============================================================================
// Local stubs for the bun.jsc / bun.uws / bun.BoringSSL surface
// ============================================================================

const JSGlobalObject = @import("home_rt").jsc.JSGlobalObject;
const CallFrame = @import("home_rt").jsc.CallFrame;
pub const JSValue = enum(i64) {
    zero = 0,
    js_undefined = 0xa,
    _,
};
pub const JSError = error{JSError};

const BoringSSL = struct {
    pub const SSL_CTX = opaque {};

    pub var SSL_CTX_up_ref: *const fn (ctx: *SSL_CTX) callconv(.c) c_int = stub_up_ref;
    pub var SSL_CTX_free: *const fn (ctx: *SSL_CTX) callconv(.c) void = stub_free;

    fn stub_up_ref(_: *SSL_CTX) callconv(.c) c_int {
        return 1;
    }
    fn stub_free(_: *SSL_CTX) callconv(.c) void {}
};

const uws = struct {
    pub const create_bun_socket_error_t = enum(c_int) {
        none = 0,
        _,
    };
    pub const SocketContext = struct {
        pub const BunSocketContextOptions = extern struct {
            _opaque: ?*anyopaque = null,

            pub fn digest(_: BunSocketContextOptions) [32]u8 {
                return @splat(0);
            }
            pub fn approxCertBytes(_: BunSocketContextOptions) usize {
                return 0;
            }
        };
        pub const c = struct {
            pub var us_ssl_ctx_live_count: *const fn () callconv(.c) usize = stub_live_count;
            fn stub_live_count() callconv(.c) usize {
                return 0;
            }
        };
    };
};

const SSLConfig = struct {
    pub const zero: SSLConfig = .{};

    pub fn asUSockets(_: *const SSLConfig) uws.SocketContext.BunSocketContextOptions {
        return .{};
    }
};

comptime {
    _ = &home_rt.upstream_sha;
}

// ============================================================================
// Tests
// ============================================================================

test "SecureContext: ssl_ctx_base_cost matches BoringSSL floor" {
    try std.testing.expectEqual(@as(usize, 50 * 1024), ssl_ctx_base_cost);
}

test "SecureContext.memoryCost adds struct size and extra_memory" {
    var sc: SecureContext = .{
        .ctx = @ptrFromInt(0xDEADBEEF),
        .digest = @splat(0),
        .extra_memory = 12345,
    };
    try std.testing.expectEqual(@sizeOf(SecureContext) + 12345, sc.memoryCost());
}

test "SecureContext.borrow up-refs via the fn-ptr stub and returns ctx" {
    var sc: SecureContext = .{
        .ctx = @ptrFromInt(0x1234),
        .digest = @splat(0),
        .extra_memory = 0,
    };
    try std.testing.expectEqual(sc.ctx, sc.borrow());
}

test "SecureContext.jsLiveCount returns the stub value" {
    var g: u8 = 0;
    var f: u8 = 0;
    const global: *JSGlobalObject = @ptrCast(&g);
    const cf: *CallFrame = @ptrCast(&f);
    try std.testing.expectEqual(JSValue.zero, try jsLiveCount(global, cf));
}

test "SecureContext.js.toJS round-trips through the stubs" {
    var dummy: u8 = 0;
    const g: *JSGlobalObject = @ptrCast(&dummy);
    var sc: SecureContext = .{
        .ctx = @ptrFromInt(0x5678),
        .digest = @splat(0),
        .extra_memory = 0,
    };
    try std.testing.expectEqual(JSValue.zero, js.toJS(&sc, g));
    try std.testing.expect(js.fromJS(.zero) == null);
}
