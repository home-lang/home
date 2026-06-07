// Phase 3 — a minimal native `Bun` global for the eval/run realm, starting
// with the file I/O surface most scripts use: `Bun.file(path)` and
// `Bun.write(path, data)`, backed by Home's real native file read/write/stat
// (via the shared single-threaded `std.Io`) — not a shim.
//
//   - `Bun.file(path)` -> a `BunFile` with async `text`/`json`/`arrayBuffer`/
//     `bytes`/`exists` and a sync `size`/`name`/`type`.
//   - `Bun.write(path, data)` -> bytes written (data: string | Uint8Array |
//     ArrayBuffer | Blob | Response-ish with `_bytes`).
//   - `Bun.version` — the pinned Bun-compat version.
//
// NOTE: this is the first time the realm exposes a `Bun` global; it is Home's
// OWN native implementation, NOT delegation to a system `bun` binary. Builds
// on the web globals (TextEncoder/Decoder); installed after them.
// comptime-gated on `enable_jsc`.

const std = @import("std");
const build_options = @import("build_options");
const evaluate = @import("evaluate.zig");
const callback = @import("callback.zig");
const extern_fns = @import("extern_fns.zig");
const opaques = @import("opaques.zig");

const JSValue = opaques.JSValue;
const JSContextRef = opaques.JSContextRef;
const JSObject = opaques.JSObject;
const JSGlobalObject = opaques.JSGlobalObject;

const bun_version = "1.3.14";

fn argToOwnedUtf8(ctx: *JSContextRef, value: *JSValue, allocator: std.mem.Allocator) ?[]u8 {
    const string = extern_fns.JSValueToStringCopy(ctx, value, null) orelse return null;
    defer extern_fns.JSStringRelease(string);
    const capacity = extern_fns.JSStringGetLength(string) * 4 + 1;
    const buf = allocator.alloc(u8, capacity) catch return null;
    const written = extern_fns.JSStringGetUTF8CString(string, buf.ptr, buf.len);
    return buf[0 .. if (written > 0) written - 1 else 0];
}

fn makeUint8Array(ctx: *JSContextRef, bytes: []const u8) ?*JSValue {
    const array = extern_fns.JSObjectMakeTypedArray(ctx, .kJSTypedArrayTypeUint8Array, bytes.len, null) orelse
        return extern_fns.JSValueMakeNull(ctx);
    if (bytes.len > 0) {
        if (extern_fns.JSObjectGetTypedArrayBytesPtr(ctx, array, null)) |ptr| {
            const dest: [*]u8 = @ptrCast(ptr);
            @memcpy(dest[0..bytes.len], bytes);
        }
    }
    return @ptrCast(array);
}

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// `__home_bun_read_file(path)` -> Uint8Array or null.
fn readFileNative(ctx: ?*JSContextRef, function: ?*JSObject, this_object: ?*JSObject, argc: usize, argv: [*c]const ?*JSValue, exception: extern_fns.ExceptionRef) callconv(.c) ?*JSValue {
    _ = function;
    _ = this_object;
    _ = exception;
    const c = ctx orelse return null;
    if (argc < 1) return extern_fns.JSValueMakeNull(c);
    const v = argv[0] orelse return extern_fns.JSValueMakeNull(c);
    const allocator = std.heap.page_allocator;
    const path = argToOwnedUtf8(c, v, allocator) orelse return extern_fns.JSValueMakeNull(c);
    defer allocator.free(path);
    if (path.len == 0) return extern_fns.JSValueMakeNull(c);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io(), path, allocator, std.Io.Limit.limited(256 * 1024 * 1024)) catch
        return extern_fns.JSValueMakeNull(c);
    defer allocator.free(bytes);
    return makeUint8Array(c, bytes);
}

/// `__home_bun_stat(path)` -> { exists: bool, size: number }.
fn statNative(ctx: ?*JSContextRef, function: ?*JSObject, this_object: ?*JSObject, argc: usize, argv: [*c]const ?*JSValue, exception: extern_fns.ExceptionRef) callconv(.c) ?*JSValue {
    _ = function;
    _ = this_object;
    _ = exception;
    const c = ctx orelse return null;
    const object = extern_fns.JSObjectMake(c, null, null) orelse return extern_fns.JSValueMakeNull(c);
    var exists = false;
    var size: f64 = 0;
    if (argc >= 1) {
        if (argv[0]) |v| {
            const allocator = std.heap.page_allocator;
            if (argToOwnedUtf8(c, v, allocator)) |path| {
                defer allocator.free(path);
                if (std.Io.Dir.cwd().statFile(io(), path, .{})) |st| {
                    exists = true;
                    size = @floatFromInt(st.size);
                } else |_| {}
            }
        }
    }
    setBool(c, object, "exists", exists);
    setNum(c, object, "size", size);
    return @ptrCast(object);
}

/// `__home_bun_write_file(path, uint8array)` -> bytes written, or -1 on error.
fn writeFileNative(ctx: ?*JSContextRef, function: ?*JSObject, this_object: ?*JSObject, argc: usize, argv: [*c]const ?*JSValue, exception: extern_fns.ExceptionRef) callconv(.c) ?*JSValue {
    _ = function;
    _ = this_object;
    _ = exception;
    const c = ctx orelse return null;
    if (argc < 2) return extern_fns.JSValueMakeNumber(c, -1);
    const path_v = argv[0] orelse return extern_fns.JSValueMakeNumber(c, -1);
    const data_v = argv[1] orelse return extern_fns.JSValueMakeNumber(c, -1);
    const allocator = std.heap.page_allocator;
    const path = argToOwnedUtf8(c, path_v, allocator) orelse return extern_fns.JSValueMakeNumber(c, -1);
    defer allocator.free(path);

    // data must be a Uint8Array (the JS wrapper encodes strings/Blobs first).
    if (extern_fns.JSValueGetTypedArrayType(c, data_v, null) == .kJSTypedArrayTypeNone)
        return extern_fns.JSValueMakeNumber(c, -1);
    const obj = extern_fns.JSValueToObject(c, data_v, null) orelse return extern_fns.JSValueMakeNumber(c, -1);
    const len = extern_fns.JSObjectGetTypedArrayByteLength(c, obj, null);
    const ptr = extern_fns.JSObjectGetTypedArrayBytesPtr(c, obj, null);
    const bytes: []const u8 = if (len > 0 and ptr != null) @as([*]const u8, @ptrCast(ptr.?))[0..len] else "";
    std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = path, .data = bytes }) catch
        return extern_fns.JSValueMakeNumber(c, -1);
    return extern_fns.JSValueMakeNumber(c, @floatFromInt(len));
}

fn makeJsString(ctx: *JSContextRef, s: []const u8) ?*JSValue {
    const allocator = std.heap.page_allocator;
    const z = allocator.dupeZ(u8, s) catch return extern_fns.JSValueMakeNull(ctx);
    defer allocator.free(z);
    const js = extern_fns.JSStringCreateWithUTF8CString(z.ptr) orelse return extern_fns.JSValueMakeNull(ctx);
    defer extern_fns.JSStringRelease(js);
    return extern_fns.JSValueMakeString(ctx, js);
}

/// `__home_bun_hash(algo, bytesUint8Array, seed)` -> decimal string of the hash.
/// algo: 0 wyhash / 1 crc32 / 2 adler32 / 3 cityHash32 / 4 cityHash64 /
/// 5 murmur32v3 / 6 murmur64v2. The JS wrapper turns it into a Number/BigInt.
fn bunHashNative(ctx: ?*JSContextRef, function: ?*JSObject, this_object: ?*JSObject, argc: usize, argv: [*c]const ?*JSValue, exception: extern_fns.ExceptionRef) callconv(.c) ?*JSValue {
    _ = function;
    _ = this_object;
    _ = exception;
    const c = ctx orelse return null;
    if (argc < 2) return makeJsString(c, "0");
    const algo: u8 = @intFromFloat(extern_fns.JSValueToNumber(c, argv[0].?, null));
    const data_v = argv[1] orelse return makeJsString(c, "0");
    if (extern_fns.JSValueGetTypedArrayType(c, data_v, null) == .kJSTypedArrayTypeNone) return makeJsString(c, "0");
    const obj = extern_fns.JSValueToObject(c, data_v, null) orelse return makeJsString(c, "0");
    const len = extern_fns.JSObjectGetTypedArrayByteLength(c, obj, null);
    const ptr = extern_fns.JSObjectGetTypedArrayBytesPtr(c, obj, null);
    const input: []const u8 = if (len > 0 and ptr != null) @as([*]const u8, @ptrCast(ptr.?))[0..len] else "";
    var seed: u64 = 0;
    if (argc >= 3) {
        if (argv[2]) |sv| {
            if (!extern_fns.JSValueIsUndefined(c, sv) and !extern_fns.JSValueIsNull(c, sv)) {
                const sf = extern_fns.JSValueToNumber(c, sv, null);
                if (sf >= 0) seed = @intFromFloat(sf);
            }
        }
    }
    const v: u64 = switch (algo) {
        0 => std.hash.Wyhash.hash(seed, input),
        1 => std.hash.Crc32.hash(input),
        2 => std.hash.Adler32.hash(input),
        3 => std.hash.cityhash.CityHash32.hash(input),
        4 => std.hash.cityhash.CityHash64.hashWithSeed(input, seed),
        5 => std.hash.murmur.Murmur3_32.hashWithSeed(input, @truncate(seed)),
        6 => std.hash.murmur.Murmur2_64.hashWithSeed(input, seed),
        else => 0,
    };
    var buf: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch return makeJsString(c, "0");
    return makeJsString(c, s);
}

/// `__home_sleep_sync(ms)` -> undefined. Blocks the current thread for `ms`
/// milliseconds via nanosleep (the JS wrapper has already validated/truncated
/// the argument). Mirrors Bun's `sleepSync` (std.Thread.sleep) — but this Zig
/// 0.17-dev lacks std.Thread.sleep, so use std.c.nanosleep directly.
fn sleepSyncNative(ctx: ?*JSContextRef, function: ?*JSObject, this_object: ?*JSObject, argc: usize, argv: [*c]const ?*JSValue, exception: extern_fns.ExceptionRef) callconv(.c) ?*JSValue {
    _ = function;
    _ = this_object;
    _ = exception;
    const c = ctx orelse return null;
    if (argc >= 1) {
        if (argv[0]) |v| {
            const ms = extern_fns.JSValueToNumber(c, v, null);
            if (ms > 0) {
                const ns: u64 = @intFromFloat(@min(ms, 9_000_000_000.0) * @as(f64, std.time.ns_per_ms));
                var req: std.c.timespec = .{
                    .sec = @intCast(ns / std.time.ns_per_s),
                    .nsec = @intCast(ns % std.time.ns_per_s),
                };
                _ = std.c.nanosleep(&req, null);
            }
        }
    }
    return extern_fns.JSValueMakeUndefined(c);
}

fn setBool(ctx: *JSContextRef, object: *JSObject, key: []const u8, value: bool) void {
    setValue(ctx, object, key, extern_fns.JSValueMakeBoolean(ctx, value));
}
fn setNum(ctx: *JSContextRef, object: *JSObject, key: []const u8, value: f64) void {
    setValue(ctx, object, key, extern_fns.JSValueMakeNumber(ctx, value));
}
fn setValue(ctx: *JSContextRef, object: *JSObject, key: []const u8, value: ?*JSValue) void {
    const allocator = std.heap.page_allocator;
    const key_z = allocator.dupeZ(u8, key) catch return;
    defer allocator.free(key_z);
    const name = extern_fns.JSStringCreateWithUTF8CString(key_z.ptr) orelse return;
    defer extern_fns.JSStringRelease(name);
    extern_fns.JSObjectSetProperty(ctx, object, name, value, 0, null);
}

const install_glue =
    \\(function() {
    \\  var readFn = globalThis.__home_bun_read_file;
    \\  var statFn = globalThis.__home_bun_stat;
    \\  var writeFn = globalThis.__home_bun_write_file;
    \\  var hashFn = globalThis.__home_bun_hash;
    \\  var sleepFn = globalThis.__home_sleep_sync;
    \\
    \\  function toBytes(data) {
    \\    if (typeof data === "string") return new TextEncoder().encode(data);
    \\    if (data && data._bytes instanceof Uint8Array) return data._bytes;
    \\    if (data instanceof ArrayBuffer) return new Uint8Array(data.slice(0));
    \\    if (ArrayBuffer.isView(data)) return new Uint8Array(data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength));
    \\    return new TextEncoder().encode(String(data));
    \\  }
    \\
    \\  class BunFile {
    \\    constructor(path, options) { this._path = String(path); this.type = options && options.type ? String(options.type) : ""; }
    \\    get name() { return this._path; }
    \\    get size() { var s = statFn(this._path); return s.exists ? s.size : 0; }
    \\    exists() { return Promise.resolve(statFn(this._path).exists); }
    \\    bytes() { var b = readFn(this._path); var p = this._path; return b === null ? Promise.reject(new Error("ENOENT: no such file: " + p)) : Promise.resolve(b.slice()); }
    \\    arrayBuffer() { var b = readFn(this._path); var p = this._path; return b === null ? Promise.reject(new Error("ENOENT: no such file: " + p)) : Promise.resolve(b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength)); }
    \\    text() { var b = readFn(this._path); var p = this._path; return b === null ? Promise.reject(new Error("ENOENT: no such file: " + p)) : Promise.resolve(new TextDecoder().decode(b)); }
    \\    json() { return this.text().then(JSON.parse); }
    \\  }
    \\
    \\  function bunDeepEquals(a, b, strict) {
    \\    if (a === b) return true;
    \\    if (a === null || b === null || typeof a !== "object" || typeof b !== "object") {
    \\      return (!strict && a == b) || (a !== a && b !== b);
    \\    }
    \\    if (Array.isArray(a) !== Array.isArray(b)) return false;
    \\    if (ArrayBuffer.isView(a) || ArrayBuffer.isView(b)) {
    \\      if (a.length !== b.length) return false;
    \\      for (var i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
    \\      return true;
    \\    }
    \\    var ka = Object.keys(a), kb = Object.keys(b);
    \\    if (ka.length !== kb.length) return false;
    \\    for (var j = 0; j < ka.length; j++) {
    \\      if (!Object.prototype.hasOwnProperty.call(b, ka[j])) return false;
    \\      if (!bunDeepEquals(a[ka[j]], b[ka[j]], strict)) return false;
    \\    }
    \\    return true;
    \\  }
    \\  var htmlEsc = { "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#x27;" };
    \\  globalThis.Bun = {
    \\    version: __HOME_BUN_VERSION__,
    \\    file: function(path, options) { return new BunFile(path, options); },
    \\    write: function(path, data) {
    \\      var dest = (path && path._path) ? path._path : String(path);
    \\      var n = writeFn(dest, toBytes(data));
    \\      if (n < 0) return Promise.reject(new Error("Bun.write failed: " + dest));
    \\      return Promise.resolve(n);
    \\    },
    \\    get env() { return (typeof globalThis.process !== "undefined" && globalThis.process.env) || {}; },
    \\    sleep: function(ms) { return new Promise(function(res) { setTimeout(res, ms instanceof Date ? Math.max(0, ms.getTime() - Date.now()) : ms); }); },
    \\    sleepSync: function(ms) {
    \\      if (arguments.length < 1) throw new TypeError("sleepSync requires at least 1 argument");
    \\      if (typeof ms !== "number") throw new TypeError("sleepSync() expects milliseconds to be a number");
    \\      var n = ms < 0 ? -1 : (ms | 0);
    \\      if (n < 0) throw new RangeError("argument to sleepSync must not be negative, got " + ms);
    \\      sleepFn(n);
    \\    },
    \\    indexOfLine: function(buffer, offset) {
    \\      var bytes;
    \\      if (buffer instanceof Uint8Array) bytes = buffer;
    \\      else if (ArrayBuffer.isView(buffer)) bytes = new Uint8Array(buffer.buffer, buffer.byteOffset, buffer.byteLength);
    \\      else if (buffer instanceof ArrayBuffer) bytes = new Uint8Array(buffer);
    \\      else return -1;
    \\      var off = Number(offset);
    \\      if (!isFinite(off) || off < 0) off = 0;
    \\      off = Math.floor(off);
    \\      for (var i = off; i < bytes.length; i++) { if (bytes[i] === 10) return i; }
    \\      return -1;
    \\    },
    \\    nanoseconds: function() { return Math.trunc((typeof performance !== "undefined" ? performance.now() : 0) * 1e6); },
    \\    inspect: function(v, opts) { var u = (typeof globalThis.require === "function") ? globalThis.require("node:util") : null; return u ? u.inspect(v, opts) : String(v); },
    \\    deepEquals: function(a, b, strict) { return bunDeepEquals(a, b, !!strict); },
    \\    escapeHTML: function(s) { return String(s).replace(/[&<>"']/g, function(c) { return htmlEsc[c]; }); },
    \\    stringWidth: function(s) { return String(s).replace(/\x1b\[[0-9;]*m/g, "").length; },
    \\  };
    \\  delete globalThis.__home_bun_read_file;
    \\  delete globalThis.__home_bun_stat;
    \\  delete globalThis.__home_sleep_sync;
    \\  (function() {
    \\    function hbytes(d) { return typeof d === "string" ? new TextEncoder().encode(d) : (d instanceof Uint8Array ? d : new Uint8Array(ArrayBuffer.isView(d) ? d.buffer : d)); }
    \\    function h64(algo, d, seed) { return BigInt(hashFn(algo, hbytes(d), seed === undefined ? 0 : Number(seed))); }
    \\    function h32(algo, d, seed) { return Number(hashFn(algo, hbytes(d), seed === undefined ? 0 : Number(seed))); }
    \\    var bunHash = function(d, seed) { return h64(0, d, seed); };
    \\    bunHash.wyhash = function(d, seed) { return h64(0, d, seed); };
    \\    bunHash.crc32 = function(d) { return h32(1, d); };
    \\    bunHash.adler32 = function(d) { return h32(2, d); };
    \\    bunHash.cityHash32 = function(d) { return h32(3, d); };
    \\    bunHash.cityHash64 = function(d, seed) { return h64(4, d, seed); };
    \\    bunHash.murmur32v3 = function(d, seed) { return h32(5, d, seed); };
    \\    bunHash.murmur64v2 = function(d, seed) { return h64(6, d, seed); };
    \\    globalThis.Bun.hash = bunHash;
    \\  })();
    \\  (function() {
    \\    function globToRegExp(pattern) {
    \\      var re = "", i = 0, n = pattern.length, depth = 0;
    \\      while (i < n) {
    \\        var c = pattern[i++];
    \\        if (c === "*") {
    \\          if (pattern[i] === "*") { i++; if (pattern[i] === "/") i++; re += ".*"; } else re += "[^/]*";
    \\        } else if (c === "?") re += "[^/]";
    \\        else if (c === "[") {
    \\          var cls = "["; if (pattern[i] === "!" || pattern[i] === "^") { cls += "^"; i++; }
    \\          while (i < n && pattern[i] !== "]") { var cc = pattern[i++]; cls += (cc === "\\") ? "\\\\" : cc; }
    \\          if (i < n) i++; re += cls + "]";
    \\        } else if (c === "{") { re += "(?:"; depth++; }
    \\        else if (c === "}" && depth > 0) { re += ")"; depth--; }
    \\        else if (c === "," && depth > 0) re += "|";
    \\        else if (".+()|^$\\".indexOf(c) >= 0) re += "\\" + c;
    \\        else re += c;
    \\      }
    \\      return new RegExp("^" + re + "$");
    \\    }
    \\    function Glob(pattern) { this.pattern = String(pattern); this._re = globToRegExp(this.pattern); }
    \\    Glob.prototype.match = function(str) { return this._re.test(String(str)); };
    \\    Glob.prototype.scan = function() { throw Object.assign(new Error("Bun.Glob.scan is not implemented yet (needs directory iteration)"), { code: "ENOSYS" }); };
    \\    globalThis.Bun.Glob = Glob;
    \\  })();
    \\  (function() {
    \\    // Bun.ArrayBufferSink — incremental byte sink. Mirrors
    \\    // src/runtime/webcore/ArrayBufferSink.zig: write() appends bytes
    \\    // (strings as UTF-8), flush() in streaming mode returns + drains the
    \\    // pending bytes (else returns 0), end() returns the whole buffer.
    \\    // asUint8Array -> return Uint8Array; otherwise an ArrayBuffer.
    \\    function sinkBytes(chunk) {
    \\      if (typeof chunk === "string") return new TextEncoder().encode(chunk);
    \\      if (chunk instanceof Uint8Array) return chunk.slice();
    \\      if (ArrayBuffer.isView(chunk)) return new Uint8Array(chunk.buffer.slice(chunk.byteOffset, chunk.byteOffset + chunk.byteLength));
    \\      if (chunk instanceof ArrayBuffer) return new Uint8Array(chunk.slice(0));
    \\      return new TextEncoder().encode("" + chunk);
    \\    }
    \\    function ArrayBufferSink() { this._chunks = []; this._len = 0; this._asUint8Array = false; this._streaming = false; }
    \\    ArrayBufferSink.prototype.start = function(options) {
    \\      this._chunks = []; this._len = 0; this._asUint8Array = false; this._streaming = false;
    \\      if (options && typeof options === "object") {
    \\        if (options.asUint8Array) this._asUint8Array = true;
    \\        if (options.stream) this._streaming = true;
    \\      }
    \\    };
    \\    ArrayBufferSink.prototype.write = function(chunk) {
    \\      var b = sinkBytes(chunk); this._chunks.push(b); this._len += b.length; return b.length;
    \\    };
    \\    ArrayBufferSink.prototype._collect = function() {
    \\      var out = new Uint8Array(this._len), off = 0;
    \\      for (var i = 0; i < this._chunks.length; i++) { out.set(this._chunks[i], off); off += this._chunks[i].length; }
    \\      this._chunks = []; this._len = 0;
    \\      return out;
    \\    };
    \\    ArrayBufferSink.prototype._wrap = function(u8) { return this._asUint8Array ? u8 : u8.buffer; };
    \\    ArrayBufferSink.prototype.flush = function() { return this._streaming ? this._wrap(this._collect()) : 0; };
    \\    ArrayBufferSink.prototype.end = function() { return this._wrap(this._collect()); };
    \\    globalThis.Bun.ArrayBufferSink = ArrayBufferSink;
    \\  })();
    \\  (function() {
    \\    // Bun.randomUUIDv5 (deterministic, SHA-1 of namespace+name) and
    \\    // Bun.randomUUIDv7 (48-bit unix-ms timestamp + monotonic random).
    \\    var HEX = "0123456789abcdef";
    \\    function bytesToUuidHex(b) {
    \\      var h = [];
    \\      for (var i = 0; i < 16; i++) { h.push(HEX[b[i] >> 4]); h.push(HEX[b[i] & 15]); }
    \\      var s = h.join("");
    \\      return s.slice(0, 8) + "-" + s.slice(8, 12) + "-" + s.slice(12, 16) + "-" + s.slice(16, 20) + "-" + s.slice(20, 32);
    \\    }
    \\    function base64FromBytes(b) { var s = ""; for (var i = 0; i < b.length; i++) s += String.fromCharCode(b[i]); return btoa(s); }
    \\    function encodeUuid(b, encoding) {
    \\      encoding = encoding || "hex";
    \\      if (encoding === "hex") return bytesToUuidHex(b);
    \\      if (encoding === "buffer") return (typeof Buffer !== "undefined") ? Buffer.from(b) : b.slice();
    \\      if (encoding === "base64") return base64FromBytes(b);
    \\      if (encoding === "base64url") return base64FromBytes(b).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
    \\      return bytesToUuidHex(b);
    \\    }
    \\    function randomBytesN(n) {
    \\      try { var c = globalThis.require("node:crypto"); var r = c.randomBytes(n); return (r instanceof Uint8Array) ? r : new Uint8Array(r); } catch (e) {}
    \\      if (globalThis.crypto && globalThis.crypto.getRandomValues) return globalThis.crypto.getRandomValues(new Uint8Array(n));
    \\      var b = new Uint8Array(n); for (var i = 0; i < n; i++) b[i] = (Math.random() * 256) | 0; return b;
    \\    }
    \\    var NS = {
    \\      dns: "6ba7b810-9dad-11d1-80b4-00c04fd430c8", url: "6ba7b811-9dad-11d1-80b4-00c04fd430c8",
    \\      oid: "6ba7b812-9dad-11d1-80b4-00c04fd430c8", x500: "6ba7b814-9dad-11d1-80b4-00c04fd430c8",
    \\    };
    \\    function namespaceToBytes(ns) {
    \\      var s = NS[ns] || ns;
    \\      s = String(s).replace(/-/g, "");
    \\      if (s.length !== 32) throw new TypeError("Invalid namespace UUID");
    \\      var b = new Uint8Array(16);
    \\      for (var i = 0; i < 16; i++) b[i] = parseInt(s.substr(i * 2, 2), 16);
    \\      return b;
    \\    }
    \\    globalThis.Bun.randomUUIDv5 = function(name, namespace, encoding) {
    \\      var nsBytes = namespaceToBytes(namespace);
    \\      var nameBytes = (typeof name === "string") ? new TextEncoder().encode(name)
    \\        : (name instanceof Uint8Array ? name : new Uint8Array(name.buffer || name));
    \\      var input = new Uint8Array(16 + nameBytes.length);
    \\      input.set(nsBytes, 0); input.set(nameBytes, 16);
    \\      var hash = globalThis.require("node:crypto").createHash("sha1").update(input).digest();
    \\      var hb = (hash instanceof Uint8Array) ? hash : new Uint8Array(hash);
    \\      var b = new Uint8Array(16);
    \\      for (var i = 0; i < 16; i++) b[i] = hb[i];
    \\      b[6] = (b[6] & 0x0f) | 0x50; // version 5
    \\      b[8] = (b[8] & 0x3f) | 0x80; // variant
    \\      return encodeUuid(b, encoding);
    \\    };
    \\    var v7LastTs = -1n, v7LastRand = 0n;
    \\    var MASK74 = (1n << 74n) - 1n, MASK48 = (1n << 48n) - 1n, MASK62 = (1n << 62n) - 1n;
    \\    globalThis.Bun.randomUUIDv7 = function(encoding, timestamp) {
    \\      var ts;
    \\      if (timestamp === undefined || timestamp === null) ts = Date.now();
    \\      else if (timestamp instanceof Date) ts = timestamp.getTime();
    \\      else ts = Number(timestamp);
    \\      var tsBig = BigInt(Math.floor(ts)) & MASK48;
    \\      if (tsBig === v7LastTs) { v7LastRand = (v7LastRand + 1n) & MASK74; }
    \\      else {
    \\        var rb = randomBytesN(10), r = 0n;
    \\        for (var i = 0; i < 10; i++) r = (r << 8n) | BigInt(rb[i]);
    \\        v7LastRand = r & MASK74; v7LastTs = tsBig;
    \\      }
    \\      var rand = v7LastRand, randA = (rand >> 62n) & 0xFFFn, randB = rand & MASK62;
    \\      var b = new Uint8Array(16);
    \\      for (var i = 0; i < 6; i++) b[i] = Number((tsBig >> BigInt((5 - i) * 8)) & 0xFFn);
    \\      b[6] = 0x70 | Number(randA >> 8n); // version 7
    \\      b[7] = Number(randA & 0xFFn);
    \\      b[8] = 0x80 | Number((randB >> 56n) & 0x3Fn); // variant + top random bits
    \\      for (var i = 0; i < 7; i++) b[9 + i] = Number((randB >> BigInt((6 - i) * 8)) & 0xFFn);
    \\      return encodeUuid(b, encoding);
    \\    };
    \\  })();
    \\  (function() {
    \\    var B = globalThis.Bun;
    \\    // pathToFileURL / fileURLToPath mirror Node's algorithm (Bun's natives
    \\    // do the same via WTF::URL). Home's URL pathname setter does not apply
    \\    // the WHATWG path percent-encode set, so we encode the path ourselves
    \\    // and build the URL from the full string.
    \\    var PCT_HEX = "0123456789ABCDEF";
    \\    function pctEncodePath(p) {
    \\      var bytes = new TextEncoder().encode(p), parts = [];
    \\      for (var i = 0; i < bytes.length; i++) {
    \\        var b = bytes[i];
    \\        // C0 controls + space, all non-ASCII, and " # % < > ? \\ ` { }
    \\        if (b <= 0x20 || b > 0x7E || b === 0x22 || b === 0x23 || b === 0x25 || b === 0x3C || b === 0x3E || b === 0x3F || b === 0x5C || b === 0x60 || b === 0x7B || b === 0x7D) {
    \\          parts.push("%" + PCT_HEX[b >> 4] + PCT_HEX[b & 15]);
    \\        } else parts.push(String.fromCharCode(b));
    \\      }
    \\      // join() builds a flat string; '+=' in a loop would build a deeply
    \\      // nested rope that overflows the stack when later flattened.
    \\      return parts.join("");
    \\    }
    \\    B.pathToFileURL = function(filepath) {
    \\      if (typeof filepath !== "string") throw new TypeError("The \"path\" argument must be of type string. Received " + typeof filepath);
    \\      var resolved = filepath;
    \\      try { var P = globalThis.require("node:path"); resolved = P.resolve(filepath); } catch (e) {}
    \\      return new globalThis.URL("file://" + pctEncodePath(resolved));
    \\    };
    \\    B.fileURLToPath = function(url) {
    \\      var u;
    \\      if (typeof url === "string") u = new globalThis.URL(url);
    \\      else if (url && typeof url === "object" && typeof url.href === "string" && typeof url.protocol === "string") u = url;
    \\      else throw new TypeError("The \"url\" argument must be of type string or an instance of URL.");
    \\      if (u.protocol !== "file:") { var e = new TypeError("The URL must be of scheme file"); e.code = "ERR_INVALID_URL_SCHEME"; throw e; }
    \\      if (u.hostname !== "" && u.hostname !== "localhost") { var eh = new TypeError("File URL host must be \"localhost\" or empty"); eh.code = "ERR_INVALID_FILE_URL_HOST"; throw eh; }
    \\      var pathname = u.pathname;
    \\      for (var n = 0; n < pathname.length; n++) {
    \\        if (pathname[n] === "%") {
    \\          var third = pathname.charCodeAt(n + 2) | 0x20;
    \\          if (pathname[n + 1] === "2" && third === 102) { var ep = new TypeError("File URL path must not include encoded / characters"); ep.code = "ERR_INVALID_FILE_URL_PATH"; throw ep; }
    \\        }
    \\      }
    \\      return decodeURIComponent(pathname);
    \\    };
    \\    B.concatArrayBuffers = function(buffers, maxLength, asUint8Array) {
    \\      // Mirrors functionConcatTypedArrays: maxLength (NaN/<0 -> RangeError,
    \\      // Infinity/undefined -> no cap, else toUInt32) caps the output, and
    \\      // asUint8Array selects Uint8Array vs ArrayBuffer.
    \\      if (arguments.length < 1) throw new TypeError("Expected at least one argument");
    \\      var max = Infinity;
    \\      if (maxLength !== undefined && typeof maxLength === "number") {
    \\        if (isNaN(maxLength) || maxLength < 0) throw new RangeError("Maximum length must be >= 0");
    \\        if (isFinite(maxLength)) max = maxLength >>> 0;
    \\      }
    \\      var au = !!asUint8Array, i;
    \\      function chunkView(c) {
    \\        if (c instanceof Uint8Array) return c;
    \\        if (ArrayBuffer.isView(c)) return new Uint8Array(c.buffer, c.byteOffset, c.byteLength);
    \\        if (c instanceof ArrayBuffer) return new Uint8Array(c);
    \\        return new Uint8Array(0);
    \\      }
    \\      var views = [], total = 0;
    \\      for (i = 0; i < buffers.length; i++) { var v = chunkView(buffers[i]); views.push(v); total += v.length; }
    \\      var outLen = total < max ? total : max;
    \\      var out = new Uint8Array(outLen), off = 0;
    \\      for (i = 0; i < views.length && off < outLen; i++) {
    \\        var vv = views[i], take = (vv.length < outLen - off) ? vv.length : outLen - off;
    \\        out.set(take === vv.length ? vv : vv.subarray(0, take), off); off += take;
    \\      }
    \\      return au ? out : out.buffer;
    \\    };
    \\    B.allocUnsafe = function(n) { return new Uint8Array(n); };
    \\    B.gc = function() { return 0; };
    \\    B.isMainThread = true;
    \\    B.revision = "0000000000000000000000000000000000000000";
    \\    Object.defineProperty(B, "argv", { get: function() { return (typeof globalThis.process !== "undefined" && globalThis.process.argv) || ["bun"]; }, configurable: true });
    \\    Object.defineProperty(B, "main", { get: function() { var a = (typeof globalThis.process !== "undefined" && globalThis.process.argv) || []; return a[1] || ""; }, configurable: true });
    \\  })();
    \\  delete globalThis.__home_bun_hash;
    \\  (function() {
    \\    var B = globalThis.Bun;
    \\    function drainStream(stream) {
    \\      if (!stream || typeof stream.getReader !== "function") return Promise.reject(new TypeError("Expected a ReadableStream"));
    \\      var reader = stream.getReader();
    \\      var chunks = [];
    \\      function step() {
    \\        return reader.read().then(function(r) {
    \\          if (r.done) return chunks;
    \\          if (r.value !== undefined) chunks.push(r.value);
    \\          return step();
    \\        });
    \\      }
    \\      return step();
    \\    }
    \\    function chunkToBytes(chunk) {
    \\      if (typeof chunk === "string") return new TextEncoder().encode(chunk);
    \\      if (chunk instanceof Uint8Array) return chunk;
    \\      if (chunk instanceof ArrayBuffer) return new Uint8Array(chunk.slice(0));
    \\      if (ArrayBuffer.isView(chunk)) return new Uint8Array(chunk.buffer.slice(chunk.byteOffset, chunk.byteOffset + chunk.byteLength));
    \\      return new TextEncoder().encode(String(chunk));
    \\    }
    \\    function concatChunkBytes(chunks) {
    \\      var parts = [], total = 0, i;
    \\      for (i = 0; i < chunks.length; i++) { var b = chunkToBytes(chunks[i]); parts.push(b); total += b.length; }
    \\      var out = new Uint8Array(total), off = 0;
    \\      for (i = 0; i < parts.length; i++) { out.set(parts[i], off); off += parts[i].length; }
    \\      return out;
    \\    }
    \\    function chunksToText(chunks) {
    \\      var allStrings = true;
    \\      for (var i = 0; i < chunks.length; i++) { if (typeof chunks[i] !== "string") { allStrings = false; break; } }
    \\      if (allStrings) return chunks.join("");
    \\      return new TextDecoder().decode(concatChunkBytes(chunks));
    \\    }
    \\    B.readableStreamToArray = function(stream) { return drainStream(stream); };
    \\    B.readableStreamToText = function(stream) { return drainStream(stream).then(chunksToText); };
    \\    B.readableStreamToJSON = function(stream) { return drainStream(stream).then(function(chunks) { return JSON.parse(chunksToText(chunks)); }); };
    \\    B.readableStreamToBytes = function(stream) { return drainStream(stream).then(concatChunkBytes); };
    \\    B.readableStreamToArrayBuffer = function(stream) { return drainStream(stream).then(function(chunks) { var b = concatChunkBytes(chunks); return b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength); }); };
    \\    B.readableStreamToBlob = function(stream) { return drainStream(stream).then(function(chunks) { var Blob = globalThis.Blob; if (typeof Blob !== "function") throw new TypeError("Blob is not defined in this realm"); return new Blob(chunks); }); };
    \\  })();
    \\  delete globalThis.__home_bun_write_file;
    \\})();
;

/// Install the minimal native `Bun` global. No-op without JSC. Must run after
/// the web globals (relies on `TextEncoder`/`TextDecoder`).
pub fn install(allocator: std.mem.Allocator, ctx: *JSContextRef, global: *JSGlobalObject) void {
    if (comptime !build_options.enable_jsc) return;

    callback.registerCallback(ctx, global, "__home_bun_read_file", readFileNative);
    callback.registerCallback(ctx, global, "__home_bun_stat", statNative);
    callback.registerCallback(ctx, global, "__home_bun_write_file", writeFileNative);
    callback.registerCallback(ctx, global, "__home_bun_hash", bunHashNative);
    callback.registerCallback(ctx, global, "__home_sleep_sync", sleepSyncNative);

    // Inject the version literal into the glue (kept out of the raw string).
    const glue = std.mem.replaceOwned(u8, allocator, install_glue, "__HOME_BUN_VERSION__", "\"" ++ bun_version ++ "\"") catch return;
    defer allocator.free(glue);
    const result = evaluate.evaluateUtf8Detailed(allocator, ctx, glue, "home:bun-install", 1) catch return;
    result.deinit(allocator);
}

fn evalBool(allocator: std.mem.Allocator, ctx: *JSContextRef, source: []const u8) !bool {
    const value = (try evaluate.evaluateUtf8(allocator, ctx, source, "home:bun-probe", 1, null)) orelse
        return error.JSEvaluateReturnedNull;
    return extern_fns.JSValueToBoolean(ctx, value);
}

fn installRealm(allocator: std.mem.Allocator, ctx: *JSContextRef, global: *JSGlobalObject) void {
    @import("web_globals.zig").install(allocator, ctx, global);
    install(allocator, ctx, global);
}

// Full realm for the utility batch (env/sleep/nanoseconds/inspect need
// process/timers/misc/node_modules), mirroring installRealmGlobals order.
fn installRealmFull(allocator: std.mem.Allocator, ctx: *JSContextRef, global: *JSGlobalObject) void {
    @import("web_globals.zig").install(allocator, ctx, global);
    @import("process.zig").install(allocator, ctx, global, &[_][]const u8{"home"});
    @import("timers_global.zig").install(allocator, ctx, global);
    @import("misc_globals.zig").install(allocator, ctx, global);
    install(allocator, ctx, global);
    @import("node_modules.zig").install(allocator, ctx, global);
}

test "Bun utility batch: deepEquals/escapeHTML/stringWidth" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealm(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function() {" ++
        "  if (!Bun.deepEquals({ a: 1, b: [2, 3] }, { a: 1, b: [2, 3] })) return false;" ++
        "  if (Bun.deepEquals({ a: 1 }, { a: 2 })) return false;" ++
        "  if (Bun.escapeHTML('<a href=\"x\">&') !== '&lt;a href=&quot;x&quot;&gt;&amp;') return false;" ++
        "  return Bun.stringWidth('ab\\u001b[31mcd\\u001b[0m') === 4; })()"));
}

test "Bun.ArrayBufferSink write/end/flush (corpus parity + stream/asUint8Array)" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealm(std.testing.allocator, ctx, engine.currentGlobalObject());

    // Mirrors js/bun/util/arraybuffersink.test.ts (multi-write rope + mixed
    // string/Uint8Array array) plus the documented stream/asUint8Array modes.
    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function() {" ++
        "  var enc = new TextEncoder();" ++
        "  function sameBytes(u8, exp) { if (u8.byteLength !== exp.length) return false; for (var i = 0; i < exp.length; i++) if (u8[i] !== exp[i]) return false; return true; }" ++
        // rope: many string writes concatenate; end() returns an ArrayBuffer
        "  var s1 = new Bun.ArrayBufferSink();" ++
        "  s1.write('abc'); s1.write('😋'); s1.write(' def');" ++
        "  var out1 = s1.end();" ++
        "  if (!(out1 instanceof ArrayBuffer)) return false;" ++
        "  if (!sameBytes(new Uint8Array(out1), enc.encode('abc😋 def'))) return false;" ++
        // mixed array: Uint8Array + strings
        "  var s2 = new Bun.ArrayBufferSink();" ++
        "  s2.write(enc.encode('abc')); s2.write('😋'); s2.write(' x');" ++
        "  if (!sameBytes(new Uint8Array(s2.end()), enc.encode('abc😋 x'))) return false;" ++
        // write returns the byte count
        "  var s3 = new Bun.ArrayBufferSink();" ++
        "  if (s3.write('😋') !== 4) return false;" ++ // 😋 is 4 UTF-8 bytes
        // asUint8Array -> end returns a Uint8Array
        "  var s4 = new Bun.ArrayBufferSink(); s4.start({ asUint8Array: true });" ++
        "  s4.write('hi'); var o4 = s4.end();" ++
        "  if (!(o4 instanceof Uint8Array) || !sameBytes(o4, enc.encode('hi'))) return false;" ++
        // streaming flush drains and returns pending bytes; non-stream flush -> 0
        "  var s5 = new Bun.ArrayBufferSink(); s5.start({ stream: true, asUint8Array: true });" ++
        "  s5.write('foo'); var f1 = s5.flush();" ++
        "  if (!sameBytes(f1, enc.encode('foo'))) return false;" ++
        "  s5.write('bar'); if (!sameBytes(s5.end(), enc.encode('bar'))) return false;" ++
        "  var s6 = new Bun.ArrayBufferSink(); s6.write('x');" ++
        "  return s6.flush() === 0; })()"));
}

test "Bun.sleepSync sleeps and validates args (corpus parity)" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealm(std.testing.allocator, ctx, engine.currentGlobalObject());

    // Mirrors js/bun/util/sleepSync.test.ts: a real sleep elapses, and missing
    // / non-number / negative arguments throw; extra args are ignored so that
    // `[1,2,3].map(Bun.sleepSync)` works.
    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function() {" ++
        "  function threw(fn) { try { fn(); return false; } catch (e) { return true; } }" ++
        "  var t0 = (typeof performance !== 'undefined') ? performance.now() : 0;" ++
        "  Bun.sleepSync(8);" ++
        "  var dt = ((typeof performance !== 'undefined') ? performance.now() : 1000) - t0;" ++
        "  if (dt < 1) return false;" ++
        "  if (!threw(function() { Bun.sleepSync(); })) return false;" ++
        "  var invalid = [true, false, 'hi', {}, [], undefined, null];" ++
        "  for (var i = 0; i < invalid.length; i++) if (!threw((function(v) { return function() { Bun.sleepSync(v); }; })(invalid[i]))) return false;" ++
        "  if (!threw(function() { Bun.sleepSync(-10); })) return false;" ++
        "  [1, 2, 3].map(Bun.sleepSync);" ++ // must not throw
        "  return true; })()"));
}

test "Bun.indexOfLine finds newline byte offsets (corpus parity)" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealm(std.testing.allocator, ctx, engine.currentGlobalObject());

    // Mirrors js/bun/util/index-of-line.test.ts: non-number offsets coerce, an
    // empty buffer is -1, and a newline is located at its byte index.
    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function() {" ++
        "  if (Bun.indexOfLine(new Uint8ClampedArray(), {}) !== -1) return false;" ++
        "  if (Bun.indexOfLine(new Uint8Array(), null) !== -1) return false;" ++
        "  if (Bun.indexOfLine(new Uint8Array(), NaN) !== -1) return false;" ++
        "  var buf = new Uint8Array([104,101,108,108,111,10,119,111,114,108,100]);" ++ // "hello\nworld"
        "  if (Bun.indexOfLine(buf, {}) !== 5) return false;" ++ // {} -> NaN -> 0
        "  if (Bun.indexOfLine(buf, '2') !== 5) return false;" ++ // "2" -> 2
        "  if (Bun.indexOfLine(buf, 6) !== -1) return false;" ++ // past the newline
        "  return Bun.indexOfLine('not a buffer', 0) === -1; })()"));
}

test "Bun.hash family (native std.hash): crc32 vector + types/determinism" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealm(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function() { var h = Bun.hash;" ++
        "  if (typeof h('abc') !== 'bigint' || h('abc') !== h('abc') || h('abc') === h('abd')) return false;" ++
        "  if (h.crc32('hello') !== 907060870) return false;" ++ // known CRC-32 (IsoHdlc) of 'hello'
        "  if (typeof h.crc32('x') !== 'number' || typeof h.adler32('x') !== 'number') return false;" ++
        "  if (typeof h.cityHash64('x') !== 'bigint' || typeof h.murmur32v3('x') !== 'number') return false;" ++
        "  if (h.wyhash('a', 0) !== h.wyhash('a', 0)) return false;" ++
        "  return h.wyhash('a', 1) !== h.wyhash('a', 2); })()"));
}

test "Bun.Glob.match (wildcards, globstar, braces, char classes)" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealm(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function() { var G = Bun.Glob;" ++
        "  if (!new G('*.ts').match('foo.ts') || new G('*.ts').match('foo.js')) return false;" ++
        "  if (!new G('src/**/*.ts').match('src/a/b/c.ts')) return false;" ++
        "  if (!new G('**/*.ts').match('a/b.ts')) return false;" ++
        "  if (!new G('file-{a,b}.txt').match('file-b.txt') || new G('file-{a,b}.txt').match('file-c.txt')) return false;" ++
        "  if (!new G('?at').match('cat')) return false;" ++
        "  return new G('[hc]at').match('hat') && !new G('[hc]at').match('bat'); })()"));
}

test "Bun global fill-out: fileURLToPath/concatArrayBuffers/allocUnsafe/argv/main/gc" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealmFull(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function() { var B = Bun;" ++
        "  if (B.fileURLToPath('file:///tmp/a%20b.txt') !== '/tmp/a b.txt') return false;" ++
        "  if (B.isMainThread !== true || B.gc() !== 0 || B.allocUnsafe(4).length !== 4) return false;" ++
        "  var ab = B.concatArrayBuffers([new Uint8Array([1, 2]).buffer, new Uint8Array([3, 4]).buffer]);" ++
        "  var u = new Uint8Array(ab); if (u.length !== 4 || u[0] !== 1 || u[3] !== 4) return false;" ++
        "  if (!Array.isArray(B.argv) || typeof B.main !== 'string') return false;" ++
        "  return B.revision.length === 40; })()"));
}

test "Bun.randomUUIDv5 is deterministic + matches the canonical uuid vector" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealmFull(std.testing.allocator, ctx, engine.currentGlobalObject());

    // Mirrors js/bun/util/randomUUIDv5.test.ts: version-5 layout, determinism,
    // 'dns' alias == its literal UUID, and the canonical uuid.v5 vector for
    // "www.example.com" under the DNS namespace.
    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function() {" ++
        "  var dns = '6ba7b810-9dad-11d1-80b4-00c04fd430c8';" ++
        "  var u = Bun.randomUUIDv5('www.example.com', dns);" ++
        "  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(u)) return false;" ++
        "  if (u[14] !== '5') return false;" ++ // version
        "  if (u !== Bun.randomUUIDv5('www.example.com', dns)) return false;" ++ // deterministic
        "  if (Bun.randomUUIDv5('www.example.com', 'dns') !== u) return false;" ++ // alias
        "  return u === '2ed6657d-e927-568b-95e1-2665a8aea6a2'; })()")); // canonical vector
}

test "Bun.randomUUIDv7 layout, timestamp, encodings, monotonic (corpus parity)" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealmFull(std.testing.allocator, ctx, engine.currentGlobalObject());

    // Mirrors js/bun/util/randomUUIDv7.test.ts: hex layout + version 7, a known
    // custom-timestamp prefix, base64/buffer encodings, and monotonicity within
    // the same timestamp.
    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function() {" ++
        "  var u = Bun.randomUUIDv7();" ++
        "  if (typeof u !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(u)) return false;" ++
        "  if (u[14] !== '7') return false;" ++ // version nibble
        "  var ct = 1625097600000;" ++
        "  if (!Bun.randomUUIDv7('hex', ct).startsWith('017a5f5d-')) return false;" ++
        "  if (!Bun.randomUUIDv7('hex', new Date(ct)).startsWith('017a5f5d-')) return false;" ++
        "  if (!/^[0-9a-zA-Z+/=]+$/.test(Bun.randomUUIDv7('base64'))) return false;" ++
        "  var buf = Bun.randomUUIDv7('buffer');" ++
        "  if (!(buf instanceof Uint8Array) || buf.byteLength !== 16) return false;" ++
        // monotonic within the same timestamp
        "  var arr = []; for (var i = 0; i < 100; i++) arr.push(Bun.randomUUIDv7('hex', ct));" ++
        "  var sorted = arr.slice().sort();" ++
        "  for (var j = 0; j < 100; j++) if (arr[j] !== sorted[j]) return false;" ++
        "  return true; })()"));
}

test "Bun.concatArrayBuffers maxLength + asUint8Array (corpus parity)" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealm(std.testing.allocator, ctx, engine.currentGlobalObject());

    // Mirrors js/bun/util/concat.test.js: ArrayBuffer/TypedArray mix, trimming
    // to a max length, and the asUint8Array flag.
    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function() {" ++
        "  function threw(fn) { try { fn(); return false; } catch (e) { return true; } }" ++
        "  function bytesEq(u8, exp) { if (u8.length !== exp.length) return false; for (var i = 0; i < exp.length; i++) if (u8[i] !== exp[i]) return false; return true; }" ++
        "  var a = Uint8Array.from([1, 2, 3]), b = Uint8Array.from([4, 5, 6]);" ++
        // default -> full ArrayBuffer
        "  var full = Bun.concatArrayBuffers([a, b]);" ++
        "  if (!(full instanceof ArrayBuffer) || !bytesEq(new Uint8Array(full), [1, 2, 3, 4, 5, 6])) return false;" ++
        // mix ArrayBuffer + TypedArray
        "  if (!bytesEq(new Uint8Array(Bun.concatArrayBuffers([a.buffer, b])), [1, 2, 3, 4, 5, 6])) return false;" ++
        // trim to maxLength, asUint8Array=true -> Uint8Array([1,2,3,4])
        "  var t = Bun.concatArrayBuffers([a, b], 4, true);" ++
        "  if (!(t instanceof Uint8Array) || !bytesEq(t, [1, 2, 3, 4])) return false;" ++
        // trim to maxLength as ArrayBuffer
        "  var t2 = Bun.concatArrayBuffers([a, b], 4);" ++
        "  if (!(t2 instanceof ArrayBuffer) || !bytesEq(new Uint8Array(t2), [1, 2, 3, 4])) return false;" ++
        // Infinity -> no cap
        "  if (!bytesEq(Bun.concatArrayBuffers([a, b], Infinity, true), [1, 2, 3, 4, 5, 6])) return false;" ++
        // NaN / negative -> RangeError; no args -> TypeError
        "  if (!threw(function() { Bun.concatArrayBuffers([a], -1); })) return false;" ++
        "  if (!threw(function() { Bun.concatArrayBuffers([a], NaN); })) return false;" ++
        "  return threw(function() { Bun.concatArrayBuffers(); }); })()"));
}

test "Bun.pathToFileURL/fileURLToPath mirror Node (corpus parity)" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealmFull(std.testing.allocator, ctx, engine.currentGlobalObject());

    // Mirrors js/bun/util/fileUrl.test.js: absolute round-trip, relative paths
    // resolve against cwd, type validation, and non-file: schemes throw.
    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function() {" ++
        "  function threw(fn) { try { fn(); return false; } catch (e) { return true; } }" ++
        "  if (Bun.pathToFileURL('/path/to/file.js').href !== 'file:///path/to/file.js') return false;" ++
        "  if (Bun.fileURLToPath('file:///path/to/file.js') !== '/path/to/file.js') return false;" ++
        "  if (Bun.fileURLToPath(new URL('file:///path/to/file.js')) !== '/path/to/file.js') return false;" ++
        // spaces and # percent-encode in the URL, decode back on the way out
        "  var sp = Bun.pathToFileURL('/a b/c#d');" ++
        "  if (sp.href !== 'file:///a%20b/c%23d') return false;" ++
        "  if (Bun.fileURLToPath(sp) !== '/a b/c#d') return false;" ++
        // relative paths resolve against process.cwd()
        "  var rel = Bun.pathToFileURL('foo.txt');" ++
        "  if (rel.href !== Bun.pathToFileURL(process.cwd()).href + '/foo.txt') return false;" ++
        // non-file: scheme + non-URL values throw
        "  if (!threw(function() { Bun.fileURLToPath(new URL('http://example.com/x')); })) return false;" ++
        "  var fuzz = [1, true, {}, [], null, undefined, NaN, Infinity];" ++
        "  for (var i = 0; i < fuzz.length; i++) if (!threw((function(v) { return function() { Bun.fileURLToPath(v); }; })(fuzz[i]))) return false;" ++
        "  return !threw(function() { Bun.pathToFileURL('/x'); }); })()"));
}

test "Bun utility batch: env/sleep/nanoseconds/inspect (full realm)" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealmFull(std.testing.allocator, ctx, engine.currentGlobalObject());

    _ = try evaluate.evaluateUtf8(std.testing.allocator, ctx,
        "globalThis.__bu = '';" ++
        "var ok = (Bun.env === process.env) && (typeof Bun.nanoseconds() === 'number') &&" ++
        "  (Bun.inspect({ a: 1 }).indexOf('a') >= 0);" ++
        "Bun.sleep(1).then(function() { globalThis.__bu = ok ? 'slept' : 'no'; });",
        "home:bun-util-setup", 1, null);
    @import("timers_global.zig").drain(ctx);
    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "globalThis.__bu === 'slept'"));
}

test "Bun global exposes version + file/write surface" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealm(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "typeof Bun === 'object' && Bun.version === '1.3.14' && " ++
        "typeof Bun.file === 'function' && typeof Bun.write === 'function' && " ++
        "typeof globalThis.__home_bun_read_file === 'undefined'"));
}

test "Bun.write then Bun.file round-trips through native fs" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const path = "/tmp/home_bun_unit_test.txt";
    defer std.Io.Dir.cwd().deleteFile(io(), path) catch {};

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealm(std.testing.allocator, ctx, engine.currentGlobalObject());

    // Write natively, then read the bytes back and check size/exists/text.
    _ = try evaluate.evaluateUtf8(std.testing.allocator, ctx,
        "globalThis.__w = null;" ++
        "Bun.write('/tmp/home_bun_unit_test.txt', 'bun-fs-roundtrip').then(function(n) {" ++
        "  var f = Bun.file('/tmp/home_bun_unit_test.txt');" ++
        "  return f.text().then(function(t) { globalThis.__w = n + ':' + f.size + ':' + t; });" ++
        "});",
        "home:bun-write-setup", 1, null);
    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "globalThis.__w === '16:16:bun-fs-roundtrip'"));
}

test "Bun.file.exists reflects presence; missing file text() rejects" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealm(std.testing.allocator, ctx, engine.currentGlobalObject());

    _ = try evaluate.evaluateUtf8(std.testing.allocator, ctx,
        "globalThis.__e = null;" ++
        "Bun.file('/tmp/home_definitely_missing_zzz.txt').exists().then(function(ex) {" ++
        "  Bun.file('/tmp/home_definitely_missing_zzz.txt').text().then(function() { globalThis.__e = 'resolved'; }, function() { globalThis.__e = ex + ':rejected'; });" ++
        "});",
        "home:bun-exists-setup", 1, null);
    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "globalThis.__e === 'false:rejected'"));
}

test "Bun.readableStreamToText/Array drain a web ReadableStream" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealm(std.testing.allocator, ctx, engine.currentGlobalObject());

    // A minimal pull-based ReadableStream over ["foo", "bar"]; the consumers
    // only touch getReader()/read(), and reads resolve via already-settled
    // promises so the whole chain drains within this single evaluateUtf8.
    _ = try evaluate.evaluateUtf8(std.testing.allocator, ctx,
        "globalThis.__rsText = null; globalThis.__rsArr = null;" ++
        "function makeStream(items) {" ++
        "  var i = 0;" ++
        "  return { getReader: function() { return {" ++
        "    read: function() { return Promise.resolve(i < items.length ? { value: items[i++], done: false } : { value: undefined, done: true }); }" ++
        "  }; } };" ++
        "}" ++
        "Bun.readableStreamToText(makeStream(['foo', 'bar'])).then(function(t) { globalThis.__rsText = t; });" ++
        "Bun.readableStreamToArray(makeStream(['foo', 'bar'])).then(function(a) { globalThis.__rsArr = JSON.stringify(a); });",
        "home:bun-rs-consumers-setup", 1, null);
    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "globalThis.__rsText === 'foobar' && globalThis.__rsArr === '[\"foo\",\"bar\"]'"));
}
