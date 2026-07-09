// Native `Bun.password` for the eval/run realm — argon2/bcrypt password
// hashing, mirroring Bun's `src/runtime/crypto/PasswordObject.zig`. Backed by
// Zig std `std.crypto.pwhash.{argon2,bcrypt}`, NOT a JS polyfill or delegation.
//
//   - `Bun.password.hash(password, algorithm?)`     -> Promise<string>
//   - `Bun.password.hashSync(password, algorithm?)` -> string
//   - `Bun.password.verify(password, hash, ?algo)`  -> Promise<boolean>
//   - `Bun.password.verifySync(password, hash)`     -> boolean
//
// `algorithm` is "argon2id" (default) | "argon2i" | "argon2d" | "bcrypt", or an
// options object: `{ algorithm, timeCost, memoryCost }` for argon2 or
// `{ algorithm: "bcrypt", cost }`. Defaults match Bun: argon2id with the
// interactive_2id params, bcrypt cost 10. Faithful to Bun: bcrypt silently
// truncates passwords > 72 bytes, so a SHA-512 pre-hash is applied first (Bun
// does the same to avoid the truncation footgun). Installed AFTER bun_global so
// `globalThis.Bun` exists; comptime-gated on `enable_jsc`.

const std = @import("std");
const bun = @import("bun");
const build_options = @import("build_options");
const evaluate = @import("evaluate.zig");
const callback = @import("callback.zig");
const extern_fns = @import("extern_fns.zig");
const opaques = @import("opaques.zig");

const JSValue = opaques.JSValue;
const JSContextRef = opaques.JSContextRef;
const JSObject = opaques.JSObject;
const JSGlobalObject = opaques.JSGlobalObject;

const pwhash = std.crypto.pwhash;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Read the bytes of a JS TypedArray argument; null if not a typed array.
fn typedArrayBytes(ctx: *JSContextRef, value: *JSValue) ?[]const u8 {
    if (extern_fns.JSValueGetTypedArrayType(ctx, value, null) == .kJSTypedArrayTypeNone) return null;
    const obj = extern_fns.JSValueToObject(ctx, value, null) orelse return null;
    const len = extern_fns.JSObjectGetTypedArrayByteLength(ctx, obj, null);
    if (len == 0) return "";
    const ptr = extern_fns.JSObjectGetTypedArrayBytesPtr(ctx, obj, null) orelse return "";
    return @as([*]const u8, @ptrCast(ptr))[0..len];
}

fn makeJsString(ctx: *JSContextRef, s: []const u8) ?*JSValue {
    const allocator = std.heap.page_allocator;
    const z = bun.dupeZ(allocator, u8, s) catch return extern_fns.JSValueMakeNull(ctx);
    defer allocator.free(z);
    const js = extern_fns.JSStringCreateWithUTF8CString(z.ptr) orelse return extern_fns.JSValueMakeNull(ctx);
    defer extern_fns.JSStringRelease(js);
    return extern_fns.JSValueMakeString(ctx, js);
}

// algo ids shared with the JS glue: 0 argon2i / 1 argon2d / 2 argon2id / 3 bcrypt.
const ALGO_ARGON2I = 0;
const ALGO_ARGON2D = 1;
const ALGO_ARGON2ID = 2;
const ALGO_BCRYPT = 3;

/// `__home_password_hash(passwordBytes, algoId, p1, p2)` -> PHC/crypt string, or null.
/// argon2: p1 = timeCost (0 = default), p2 = memoryCost-KiB (0 = default).
/// bcrypt: p1 = cost / rounds_log.
fn passwordHashNative(ctx: ?*JSContextRef, function: ?*JSObject, this_object: ?*JSObject, argc: usize, argv: [*c]const ?*JSValue, exception: extern_fns.ExceptionRef) callconv(.c) ?*JSValue {
    _ = function;
    _ = this_object;
    _ = exception;
    const c = ctx orelse return null;
    if (argc < 4) return extern_fns.JSValueMakeNull(c);
    const pw_v = argv[0] orelse return extern_fns.JSValueMakeNull(c);
    const password = typedArrayBytes(c, pw_v) orelse return extern_fns.JSValueMakeNull(c);
    const algo_id: u8 = @intFromFloat(extern_fns.JSValueToNumber(c, argv[1].?, null));
    const p1: u32 = @intFromFloat(@max(0, extern_fns.JSValueToNumber(c, argv[2].?, null)));
    const p2: u32 = @intFromFloat(@max(0, extern_fns.JSValueToNumber(c, argv[3].?, null)));

    const allocator = std.heap.page_allocator;
    var outbuf: [4096]u8 = undefined;

    switch (algo_id) {
        ALGO_ARGON2I, ALGO_ARGON2D, ALGO_ARGON2ID => {
            const defaults = pwhash.argon2.Params.interactive_2id;
            const params = pwhash.argon2.Params{
                .t = if (p1 == 0) defaults.t else p1,
                .m = if (p2 == 0) defaults.m else p2,
                .p = 1,
            };
            const mode: pwhash.argon2.Mode = switch (algo_id) {
                ALGO_ARGON2I => .argon2i,
                ALGO_ARGON2D => .argon2d,
                else => .argon2id,
            };
            const out = pwhash.argon2.strHash(password, .{
                .allocator = allocator,
                .params = params,
                .mode = mode,
                .encoding = .phc,
            }, &outbuf, io()) catch return extern_fns.JSValueMakeNull(c);
            return makeJsString(c, out);
        },
        ALGO_BCRYPT => {
            // bcrypt silently truncates to 72 bytes; SHA-512 pre-hash longer
            // passwords so the full input contributes (matches Bun).
            var sha_buf: [std.crypto.hash.sha2.Sha512.digest_length]u8 = undefined;
            var password_to_use = password;
            if (password.len > 72) {
                std.crypto.hash.sha2.Sha512.hash(password, &sha_buf, .{});
                password_to_use = sha_buf[0..];
            }
            const cost: u6 = @intCast(@min(@as(u32, 31), @max(@as(u32, 4), p1)));
            const out = pwhash.bcrypt.strHash(password_to_use, .{
                .params = .{ .rounds_log = cost, .silently_truncate_password = true },
                .encoding = .crypt,
            }, &outbuf, io()) catch return extern_fns.JSValueMakeNull(c);
            return makeJsString(c, out);
        },
        else => return extern_fns.JSValueMakeNull(c),
    }
}

/// `__home_password_verify(passwordBytes, hashBytes)` -> 1 (ok) / 0 (mismatch) /
/// -1 (unsupported algorithm). The algorithm is auto-detected from the encoded
/// hash prefix (the PHC/crypt string already pins which KDF produced it).
fn passwordVerifyNative(ctx: ?*JSContextRef, function: ?*JSObject, this_object: ?*JSObject, argc: usize, argv: [*c]const ?*JSValue, exception: extern_fns.ExceptionRef) callconv(.c) ?*JSValue {
    _ = function;
    _ = this_object;
    _ = exception;
    const c = ctx orelse return null;
    if (argc < 2) return extern_fns.JSValueMakeNumber(c, 0);
    const pw_v = argv[0] orelse return extern_fns.JSValueMakeNumber(c, 0);
    const hash_v = argv[1] orelse return extern_fns.JSValueMakeNumber(c, 0);
    const password = typedArrayBytes(c, pw_v) orelse return extern_fns.JSValueMakeNumber(c, 0);
    const hash = typedArrayBytes(c, hash_v) orelse return extern_fns.JSValueMakeNumber(c, 0);
    if (hash.len == 0 or password.len == 0) return extern_fns.JSValueMakeNumber(c, 0);

    const allocator = std.heap.page_allocator;

    if (std.mem.startsWith(u8, hash, "$argon2")) {
        pwhash.argon2.strVerify(hash, password, .{ .allocator = allocator }, io()) catch |err| {
            if (err == error.PasswordVerificationFailed) return extern_fns.JSValueMakeNumber(c, 0);
            return extern_fns.JSValueMakeNumber(c, -1);
        };
        return extern_fns.JSValueMakeNumber(c, 1);
    }

    if (std.mem.startsWith(u8, hash, "$2")) {
        var sha_buf: [std.crypto.hash.sha2.Sha512.digest_length]u8 = undefined;
        var password_to_use = password;
        if (password.len > 72) {
            std.crypto.hash.sha2.Sha512.hash(password, &sha_buf, .{});
            password_to_use = sha_buf[0..];
        }
        pwhash.bcrypt.strVerify(hash, password_to_use, .{ .silently_truncate_password = true }) catch |err| {
            if (err == error.PasswordVerificationFailed) return extern_fns.JSValueMakeNumber(c, 0);
            return extern_fns.JSValueMakeNumber(c, -1);
        };
        return extern_fns.JSValueMakeNumber(c, 1);
    }

    return extern_fns.JSValueMakeNumber(c, -1);
}

const install_glue =
    \\(function() {
    \\  var hashFn = globalThis.__home_password_hash;
    \\  var verifyFn = globalThis.__home_password_verify;
    \\  var enc = new TextEncoder();
    \\  function toBytes(p) {
    \\    if (typeof p === "string") return enc.encode(p);
    \\    if (p instanceof Uint8Array) return p;
    \\    if (ArrayBuffer.isView(p)) return new Uint8Array(p.buffer, p.byteOffset, p.byteLength);
    \\    if (p instanceof ArrayBuffer) return new Uint8Array(p);
    \\    // `"" + p` (not String(p)) so a Symbol or a throwing toString() raises a
    \\    // TypeError, matching Bun's StringOrBuffer coercion semantics.
    \\    return enc.encode("" + p);
    \\  }
    \\  function algoId(name) {
    \\    switch (name) {
    \\      case "argon2i": return 0;
    \\      case "argon2d": return 1;
    \\      case "argon2id": return 2;
    \\      case "bcrypt": return 3;
    \\      default: throw new TypeError("Algorithm '" + name + "' is not supported. Supported: argon2id, argon2d, argon2i, bcrypt");
    \\    }
    \\  }
    \\  function parseAlgorithm(algorithm) {
    \\    if (algorithm === undefined || algorithm === null) return [2, 0, 0];
    \\    if (typeof algorithm === "string") {
    \\      var id = algoId(algorithm);
    \\      return [id, id === 3 ? 10 : 0, 0];
    \\    }
    \\    if (typeof algorithm === "object") {
    \\      var name = algorithm.algorithm;
    \\      if (typeof name !== "string") throw new TypeError("algorithm must be a string");
    \\      var id = algoId(name);
    \\      if (id === 3) {
    \\        var cost = algorithm.cost;
    \\        if (cost === undefined || cost === null) return [3, 10, 0];
    \\        if (typeof cost !== "number") throw new TypeError("cost must be a number");
    \\        if (cost < 4 || cost > 31) throw new RangeError("Rounds must be between 4 and 31");
    \\        return [3, cost | 0, 0];
    \\      }
    \\      var t = 0, m = 0;
    \\      var tc = algorithm.timeCost;
    \\      if (tc !== undefined && tc !== null) {
    \\        if (typeof tc !== "number") throw new TypeError("timeCost must be a number");
    \\        if (tc < 1) throw new RangeError("Time cost must be greater than 0");
    \\        t = tc | 0;
    \\      }
    \\      var mc = algorithm.memoryCost;
    \\      if (mc !== undefined && mc !== null) {
    \\        if (typeof mc !== "number") throw new TypeError("memoryCost must be a number");
    \\        if (mc < 1) throw new RangeError("Memory cost must be greater than 0");
    \\        m = mc | 0;
    \\      }
    \\      return [id, t, m];
    \\    }
    \\    throw new TypeError("algorithm must be a string or object");
    \\  }
    \\  function validateExplicitAlgorithm(algorithm) {
    \\    if (algorithm === undefined || algorithm === null) return;
    \\    if (typeof algorithm === "string") { algoId(algorithm); return; }
    \\    if (typeof algorithm === "object" && typeof algorithm.algorithm === "string") { algoId(algorithm.algorithm); return; }
    \\    throw new TypeError("algorithm must be a string");
    \\  }
    \\  // All argument validation runs synchronously (it throws on the calling
    \\  // stack, even for the async hash/verify) — only the KDF result is wrapped
    \\  // in a Promise. This matches Bun, whose arg-parsing tests assert the call
    \\  // itself throws rather than returning a rejected Promise.
    \\  function doHash(password, algorithm) {
    \\    var bytes = toBytes(password);
    \\    if (bytes.length === 0) throw new Error("password must not be empty");
    \\    var a = parseAlgorithm(algorithm);
    \\    var out = hashFn(bytes, a[0], a[1], a[2]);
    \\    if (out === null || out === undefined) throw new Error("password hashing failed");
    \\    return out;
    \\  }
    \\  function doVerify(password, hash, algorithm) {
    \\    validateExplicitAlgorithm(algorithm);
    \\    var hb = toBytes(hash);
    \\    if (hb.length === 0) return false;
    \\    var pb = toBytes(password);
    \\    if (pb.length === 0) return false;
    \\    var r = verifyFn(pb, hb);
    \\    if (r < 0) throw new Error("Unsupported algorithm or malformed hash");
    \\    return r === 1;
    \\  }
    \\  var password = {
    \\    hash: function(p, algorithm) { if (arguments.length < 1) throw new TypeError("password is required"); return Promise.resolve(doHash(p, algorithm)); },
    \\    hashSync: function(p, algorithm) { if (arguments.length < 1) throw new TypeError("password is required"); return doHash(p, algorithm); },
    \\    verify: function(p, h, algorithm) { if (arguments.length < 2) throw new TypeError("verify requires at least 2 arguments"); return Promise.resolve(doVerify(p, h, algorithm)); },
    \\    verifySync: function(p, h, algorithm) { if (arguments.length < 2) throw new TypeError("verify requires at least 2 arguments"); return doVerify(p, h, algorithm); },
    \\  };
    \\  if (typeof globalThis.Bun === "object" && globalThis.Bun) globalThis.Bun.password = password;
    \\  delete globalThis.__home_password_hash;
    \\  delete globalThis.__home_password_verify;
    \\})();
;

/// Install `Bun.password`. No-op without JSC. Must run after `bun_global.install`.
pub fn install(allocator: std.mem.Allocator, ctx: *JSContextRef, global: *JSGlobalObject) void {
    if (comptime !build_options.enable_jsc) return;

    callback.registerCallback(ctx, global, "__home_password_hash", passwordHashNative);
    callback.registerCallback(ctx, global, "__home_password_verify", passwordVerifyNative);

    const result = evaluate.evaluateUtf8Detailed(allocator, ctx, install_glue, "home:bun-password-install", 1) catch return;
    result.deinit(allocator);
}

fn evalBool(allocator: std.mem.Allocator, ctx: *JSContextRef, source: []const u8) !bool {
    const value = (try evaluate.evaluateUtf8(allocator, ctx, source, "home:password-probe", 1, null)) orelse
        return error.JSEvaluateReturnedNull;
    return extern_fns.JSValueToBoolean(ctx, value);
}

fn installRealm(allocator: std.mem.Allocator, ctx: *JSContextRef, global: *JSGlobalObject) void {
    @import("web_globals.zig").install(allocator, ctx, global);
    @import("bun_global.zig").install(allocator, ctx, global);
    install(allocator, ctx, global);
}

test "Bun.password.hashSync/verifySync round-trips for bcrypt" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealm(std.testing.allocator, ctx, engine.currentGlobalObject());

    // bcrypt cost 4 keeps the unit test fast while exercising the full path.
    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function() {" ++
        "  var h = Bun.password.hashSync('hunter2', { algorithm: 'bcrypt', cost: 4 });" ++
        "  if (typeof h !== 'string' || h.indexOf('$2') !== 0) return false;" ++
        "  if (!Bun.password.verifySync('hunter2', h)) return false;" ++
        "  return Bun.password.verifySync('wrong', h) === false; })()"));
}

test "Bun.password argon2id default round-trips and pins the algorithm in the hash" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealm(std.testing.allocator, ctx, engine.currentGlobalObject());

    // Low memory/time cost so argon2 stays quick under the unit harness.
    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function() {" ++
        "  var h = Bun.password.hashSync('s3cret', { algorithm: 'argon2id', timeCost: 1, memoryCost: 256 });" ++
        "  if (h.indexOf('$argon2id$') !== 0) return false;" ++
        "  if (!Bun.password.verifySync('s3cret', h)) return false;" ++
        "  return Bun.password.verifySync('nope', h) === false; })()"));
}

test "Bun.password empty password throws; empty hash verifies false" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealm(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function() {" ++
        "  var threw = false;" ++
        "  try { Bun.password.hashSync(''); } catch (e) { threw = e.message.indexOf('empty') >= 0; }" ++
        "  if (!threw) return false;" ++
        "  if (Bun.password.verifySync('x', '') !== false) return false;" ++
        "  var badAlgo = false;" ++
        "  try { Bun.password.hashSync('x', 'sha256'); } catch (e) { badAlgo = true; }" ++
        "  return badAlgo; })()"));
}

test "Bun.password matches Bun corpus arg-parsing: sync throws, coercion, arity" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealm(std.testing.allocator, ctx, engine.currentGlobalObject());

    // These mirror js/bun/util/password.test.ts: the *async* hash/verify must
    // throw synchronously on bad arguments (not return a rejected Promise), a
    // Symbol/throwing-toString password must throw, and arity is enforced.
    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function() {" ++
        "  function threw(fn) { try { fn(); return false; } catch (e) { return true; } }" ++
        // async hash throws synchronously for empty / bad algo / bad-arg
        "  if (!threw(function() { Bun.password.hash(''); })) return false;" ++
        "  if (!threw(function() { Bun.password.hash(); })) return false;" ++
        "  if (!threw(function() { Bun.password.hash('x', 123); })) return false;" ++
        "  if (!threw(function() { Bun.password.hash('x', { algorithm: 'poop' }); })) return false;" ++
        "  if (!threw(function() { Bun.password.hash('x', { algorithm: 'bcrypt', cost: Infinity }); })) return false;" ++
        "  if (!threw(function() { Bun.password.hash('x', { algorithm: 'argon2id', memoryCost: -1 }); })) return false;" ++
        // Symbol and throwing-toString coercion must raise, not stringify
        "  if (!threw(function() { Bun.password.hashSync(Symbol()); })) return false;" ++
        "  if (!threw(function() { Bun.password.hashSync({ toString() { throw new Error('x'); } }); })) return false;" ++
        // empty typed arrays -> 'must not be empty'
        "  if (!threw(function() { Bun.password.hashSync(new Uint8Array(0)); })) return false;" ++
        "  if (!threw(function() { Bun.password.hashSync(new ArrayBuffer(0)); })) return false;" ++
        // verify arity + explicit-algorithm validation + empty -> false
        "  if (!threw(function() { Bun.password.verify(); })) return false;" ++
        "  if (!threw(function() { Bun.password.verify(''); })) return false;" ++
        "  if (!threw(function() { Bun.password.verifySync('x', '$', 'scrpyt'); })) return false;" ++
        "  if (Bun.password.verifySync('', '$') !== false) return false;" ++
        "  return Bun.password.verifySync('$', '') === false; })()"));
}

test "Bun.password verifies a hash produced by upstream Bun (cross-version bcrypt SHA-512 prehash)" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealm(std.testing.allocator, ctx, engine.currentGlobalObject());

    // Exact hash + secret from Bun's own corpus (generated by Bun 1.2.4); a
    // 500-byte password exercises the >72-byte SHA-512 pre-hash path. If our
    // pre-hash diverged from Bun's, this would not verify.
    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "Bun.password.verifySync('hello'.repeat(100), " ++
        "'$2b$10$PsJ3/W82mzNJoP0rSblfvet2ab9jZg2aH7tIxr1B8uFLJwuWk/jTi')"));
}

test "Bun.password.hash/verify async resolve through Promises" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealm(std.testing.allocator, ctx, engine.currentGlobalObject());

    _ = try evaluate.evaluateUtf8(std.testing.allocator, ctx,
        "globalThis.__pw = null;" ++
        "Bun.password.hash('async-pw', { algorithm: 'bcrypt', cost: 4 }).then(function(h) {" ++
        "  return Bun.password.verify('async-pw', h).then(function(ok) { globalThis.__pw = ok ? 'ok' : 'bad'; });" ++
        "});",
        "home:password-async-setup", 1, null);
    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "globalThis.__pw === 'ok'"));
}
