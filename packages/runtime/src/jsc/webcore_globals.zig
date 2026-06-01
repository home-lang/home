// Phase 3 — WebCore data types for the native JSC eval/run realm:
// `Headers`, `Blob`, `Request`, `Response`.
//
// These are the constructible Fetch-spec data types — usable without any
// network (you can build a Request/Response/Headers/Blob and read its body).
// They are the prerequisite for a real `fetch()` (which needs the HTTP client
// wired into the event loop and comes in a later increment).
//
// Bodies are stored as `Uint8Array` and the async accessors
// (`text`/`json`/`arrayBuffer`/`blob`/`bytes`) return Promises resolved on the
// microtask queue (drained by JSC / the realm's event loop), with the
// `bodyUsed` single-consumption guard. Encoding goes through the realm's
// native `TextEncoder`/`TextDecoder`. Behaviorally faithful to WHATWG Fetch
// for these types; Bun implements them natively, so this is a JS realization
// of the same observable behavior. comptime-gated on `enable_jsc`; installed
// after the web globals (TextEncoder/Decoder) it relies on.

const std = @import("std");
const build_options = @import("build_options");
const evaluate = @import("evaluate.zig");
const extern_fns = @import("extern_fns.zig");
const opaques = @import("opaques.zig");

const JSValue = opaques.JSValue;
const JSContextRef = opaques.JSContextRef;
const JSGlobalObject = opaques.JSGlobalObject;

const install_glue =
    \\(function() {
    \\  function hasOwn(o, k) { return Object.prototype.hasOwnProperty.call(o, k); }
    \\
    \\  class Headers {
    \\    constructor(init) {
    \\      this._map = new Map(); // lowercased name -> combined value
    \\      if (init === undefined || init === null) return;
    \\      if (init instanceof Headers) { var self = this; init.forEach(function(v, k) { self.append(k, v); }); }
    \\      else if (Array.isArray(init)) { for (var i = 0; i < init.length; i++) this.append(init[i][0], init[i][1]); }
    \\      else if (typeof init === "object") { for (var k in init) if (hasOwn(init, k)) this.append(k, init[k]); }
    \\    }
    \\    append(name, value) { name = String(name).toLowerCase(); value = String(value); var ex = this._map.get(name); this._map.set(name, ex === undefined ? value : ex + ", " + value); }
    \\    set(name, value) { this._map.set(String(name).toLowerCase(), String(value)); }
    \\    get(name) { var v = this._map.get(String(name).toLowerCase()); return v === undefined ? null : v; }
    \\    has(name) { return this._map.has(String(name).toLowerCase()); }
    \\    delete(name) { this._map.delete(String(name).toLowerCase()); }
    \\    _sortedKeys() { return Array.from(this._map.keys()).sort(); }
    \\    forEach(cb, thisArg) { var ks = this._sortedKeys(); for (var i = 0; i < ks.length; i++) cb.call(thisArg, this._map.get(ks[i]), ks[i], this); }
    \\    keys() { return this._sortedKeys()[Symbol.iterator](); }
    \\    values() { var self = this; return this._sortedKeys().map(function(k) { return self._map.get(k); })[Symbol.iterator](); }
    \\    entries() { var self = this; return this._sortedKeys().map(function(k) { return [k, self._map.get(k)]; })[Symbol.iterator](); }
    \\    [Symbol.iterator]() { return this.entries(); }
    \\  }
    \\
    \\  function toBytes(part) {
    \\    if (typeof part === "string") return new TextEncoder().encode(part);
    \\    if (part instanceof Blob) return part._bytes;
    \\    if (part instanceof ArrayBuffer) return new Uint8Array(part.slice(0));
    \\    if (ArrayBuffer.isView(part)) return new Uint8Array(part.buffer.slice(part.byteOffset, part.byteOffset + part.byteLength));
    \\    return new TextEncoder().encode(String(part));
    \\  }
    \\
    \\  function concatBytes(chunks) {
    \\    var total = 0; for (var i = 0; i < chunks.length; i++) total += chunks[i].length;
    \\    var out = new Uint8Array(total); var off = 0;
    \\    for (var j = 0; j < chunks.length; j++) { out.set(chunks[j], off); off += chunks[j].length; }
    \\    return out;
    \\  }
    \\
    \\  class Blob {
    \\    constructor(parts, options) {
    \\      var chunks = [];
    \\      if (parts) for (var i = 0; i < parts.length; i++) chunks.push(toBytes(parts[i]));
    \\      this._bytes = concatBytes(chunks);
    \\      this.type = options && options.type ? String(options.type).toLowerCase() : "";
    \\    }
    \\    get size() { return this._bytes.length; }
    \\    text() { var b = this._bytes; return Promise.resolve(new TextDecoder().decode(b)); }
    \\    arrayBuffer() { var b = this._bytes; return Promise.resolve(b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength)); }
    \\    bytes() { var b = this._bytes; return Promise.resolve(b.slice()); }
    \\    slice(start, end, contentType) { var nb = new Blob([], { type: contentType || "" }); nb._bytes = this._bytes.slice(start, end); return nb; }
    \\  }
    \\
    \\  // Encode a body init into { bytes, type } (type is the default content-type, or null).
    \\  function encodeBody(body) {
    \\    if (body === null || body === undefined) return { bytes: null, type: null };
    \\    if (typeof body === "string") return { bytes: new TextEncoder().encode(body), type: "text/plain;charset=UTF-8" };
    \\    if (body instanceof Blob) return { bytes: body._bytes, type: body.type || null };
    \\    if (body instanceof URLSearchParams) return { bytes: new TextEncoder().encode(body.toString()), type: "application/x-www-form-urlencoded;charset=UTF-8" };
    \\    if (body instanceof ArrayBuffer) return { bytes: new Uint8Array(body.slice(0)), type: null };
    \\    if (ArrayBuffer.isView(body)) return { bytes: new Uint8Array(body.buffer.slice(body.byteOffset, body.byteOffset + body.byteLength)), type: null };
    \\    return { bytes: new TextEncoder().encode(String(body)), type: "text/plain;charset=UTF-8" };
    \\  }
    \\
    \\  function defineBody(proto) {
    \\    function consume(self) {
    \\      if (self.bodyUsed) return Promise.reject(new TypeError("Body already used"));
    \\      self.bodyUsed = true;
    \\      return Promise.resolve(self._bodyBytes || new Uint8Array(0));
    \\    }
    \\    proto.arrayBuffer = function() { return consume(this).then(function(b) { return b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength); }); };
    \\    proto.bytes = function() { return consume(this).then(function(b) { return b.slice(); }); };
    \\    proto.text = function() { return consume(this).then(function(b) { return new TextDecoder().decode(b); }); };
    \\    proto.json = function() { return this.text().then(function(t) { return JSON.parse(t); }); };
    \\    proto.blob = function() { var t = this.headers ? this.headers.get("content-type") : null; return consume(this).then(function(b) { var nb = new Blob([], { type: t || "" }); nb._bytes = b; return nb; }); };
    \\  }
    \\
    \\  class Request {
    \\    constructor(input, init) {
    \\      init = init || {};
    \\      var baseHeaders, baseBody = null, baseMethod = "GET";
    \\      if (input instanceof Request) { this.url = input.url; baseMethod = input.method; baseHeaders = input.headers; baseBody = input._bodyBytes; }
    \\      else { this.url = String(input); }
    \\      this.method = String(init.method || baseMethod).toUpperCase();
    \\      this.headers = new Headers(init.headers || baseHeaders);
    \\      this.credentials = init.credentials || "same-origin";
    \\      this.mode = init.mode || "cors";
    \\      this.redirect = init.redirect || "follow";
    \\      if (init.body !== undefined && init.body !== null) {
    \\        var enc = encodeBody(init.body);
    \\        this._bodyBytes = enc.bytes;
    \\        if (enc.type && !this.headers.has("content-type")) this.headers.set("content-type", enc.type);
    \\      } else this._bodyBytes = baseBody;
    \\      this.bodyUsed = false;
    \\    }
    \\    clone() { var r = new Request(this.url, { method: this.method, headers: this.headers }); r._bodyBytes = this._bodyBytes; return r; }
    \\  }
    \\  defineBody(Request.prototype);
    \\
    \\  class Response {
    \\    constructor(body, init) {
    \\      init = init || {};
    \\      this.status = init.status !== undefined ? (init.status | 0) : 200;
    \\      this.statusText = init.statusText !== undefined ? String(init.statusText) : "";
    \\      this.headers = new Headers(init.headers);
    \\      this.ok = this.status >= 200 && this.status < 300;
    \\      this.type = "default";
    \\      this.url = "";
    \\      this.redirected = false;
    \\      if (body !== null && body !== undefined) {
    \\        var enc = encodeBody(body);
    \\        this._bodyBytes = enc.bytes;
    \\        if (enc.type && !this.headers.has("content-type")) this.headers.set("content-type", enc.type);
    \\      } else this._bodyBytes = null;
    \\      this.bodyUsed = false;
    \\    }
    \\    clone() { var r = new Response(null, { status: this.status, statusText: this.statusText, headers: this.headers }); r._bodyBytes = this._bodyBytes; r.url = this.url; return r; }
    \\    static json(data, init) { var r = new Response(JSON.stringify(data), init); r.headers.set("content-type", "application/json"); return r; }
    \\    static error() { var r = new Response(null, { status: 0 }); r.type = "error"; return r; }
    \\    static redirect(url, status) { return new Response(null, { status: status || 302, headers: { location: String(url) } }); }
    \\  }
    \\  defineBody(Response.prototype);
    \\
    \\  // Streaming bodies: leverage the realm's ReadableStream to surface stored
    \\  // body bytes as a one-chunk-then-close stream. Reading a body stream
    \\  // consumes the body, sharing the bodyUsed single-consumption guard.
    \\  function bytesToStream(bytes) {
    \\    return new ReadableStream({
    \\      start: function(controller) {
    \\        if (bytes && bytes.length > 0) controller.enqueue(bytes.slice());
    \\        controller.close();
    \\      }
    \\    });
    \\  }
    \\  Blob.prototype.stream = function() { return bytesToStream(this._bytes || new Uint8Array(0)); };
    \\  function defineBodyStream(proto) {
    \\    Object.defineProperty(proto, "body", {
    \\      get: function() {
    \\        if (this._bodyBytes === null || this._bodyBytes === undefined) return null;
    \\        if (this.bodyUsed) throw new TypeError("Body already used");
    \\        this.bodyUsed = true;
    \\        return bytesToStream(this._bodyBytes);
    \\      },
    \\      enumerable: true,
    \\      configurable: true
    \\    });
    \\  }
    \\  defineBodyStream(Request.prototype);
    \\  defineBodyStream(Response.prototype);
    \\
    \\  globalThis.Headers = Headers;
    \\  globalThis.Blob = Blob;
    \\  globalThis.Request = Request;
    \\  globalThis.Response = Response;
    \\})();
;

/// Install `Headers`/`Blob`/`Request`/`Response`. No-op without JSC. Must run
/// after the web globals (relies on `TextEncoder`/`TextDecoder`).
pub fn install(allocator: std.mem.Allocator, ctx: *JSContextRef, global: *JSGlobalObject) void {
    if (comptime !build_options.enable_jsc) return;
    _ = global;
    const result = evaluate.evaluateUtf8Detailed(allocator, ctx, install_glue, "home:webcore-install", 1) catch return;
    result.deinit(allocator);
}

fn evalBool(allocator: std.mem.Allocator, ctx: *JSContextRef, source: []const u8) !bool {
    const value = (try evaluate.evaluateUtf8(allocator, ctx, source, "home:webcore-probe", 1, null)) orelse
        return error.JSEvaluateReturnedNull;
    return extern_fns.JSValueToBoolean(ctx, value);
}

// The realm needs TextEncoder/TextDecoder for body encoding, so the tests
// install the web globals first.
fn installPrereqs(allocator: std.mem.Allocator, ctx: *JSContextRef, global: *JSGlobalObject) void {
    @import("web_globals.zig").install(allocator, ctx, global);
    @import("url_global.zig").install(allocator, ctx, global);
    install(allocator, ctx, global);
}

test "Headers is case-insensitive, combines appends, sorts iteration" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installPrereqs(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function() {" ++
        "  var h = new Headers({ 'Content-Type': 'text/plain' });" ++
        "  h.append('X-A', '1'); h.append('x-a', '2');" ++
        "  if (h.get('CONTENT-TYPE') !== 'text/plain' || h.get('x-a') !== '1, 2' || !h.has('X-A')) return false;" ++
        "  h.delete('content-type'); if (h.has('content-type')) return false;" ++
        "  var seen = []; h.forEach(function(v, k) { seen.push(k); });" ++
        "  return seen.join(',') === 'x-a';" ++
        "})()"));
}

test "Blob holds bytes; size/type and async text round-trip" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installPrereqs(std.testing.allocator, ctx, engine.currentGlobalObject());

    // size/type are sync; text() is a Promise resolved on the microtask queue.
    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function() { var b = new Blob(['hé', 'llo'], { type: 'text/plain' }); " ++
        "return b.size === 6 && b.type === 'text/plain'; })()"));
    _ = try evaluate.evaluateUtf8(std.testing.allocator, ctx,
        "globalThis.__blobText = null; new Blob(['hé', 'llo']).text().then(function(t) { globalThis.__blobText = t; });",
        "home:webcore-blob-setup", 1, null);
    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "globalThis.__blobText === 'héllo'"));
}

test "Request carries url/method/headers and sets a default content-type" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installPrereqs(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function() {" ++
        "  var r = new Request('https://h.com/x', { method: 'post', body: 'hi', headers: { 'X-Y': 'z' } });" ++
        "  return r.url === 'https://h.com/x' && r.method === 'POST' && r.headers.get('x-y') === 'z' &&" ++
        "    r.headers.get('content-type') === 'text/plain;charset=UTF-8' && r.bodyUsed === false;" ++
        "})()"));
}

test "Response status/ok, json body, and Response.json static" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installPrereqs(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function() {" ++
        "  var r = new Response('body', { status: 201 });" ++
        "  if (r.status !== 201 || r.ok !== true) return false;" ++
        "  var bad = new Response(null, { status: 404 });" ++
        "  if (bad.ok !== false) return false;" ++
        "  var j = Response.json({ a: 1 });" ++
        "  return j.headers.get('content-type') === 'application/json';" ++
        "})()"));

    // Async json() body parse resolves on the microtask queue.
    _ = try evaluate.evaluateUtf8(std.testing.allocator, ctx,
        "globalThis.__respJson = null; new Response(JSON.stringify({ n: 42 })).json().then(function(o) { globalThis.__respJson = o.n; });",
        "home:webcore-resp-setup", 1, null);
    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "globalThis.__respJson === 42"));
}

test "body single-use guard rejects a second read" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installPrereqs(std.testing.allocator, ctx, engine.currentGlobalObject());

    _ = try evaluate.evaluateUtf8(std.testing.allocator, ctx,
        "globalThis.__used = null;" ++
        "var r = new Response('once');" ++
        "r.text().then(function() {" ++
        "  r.text().then(function() { globalThis.__used = 'no-throw'; }, function(e) { globalThis.__used = e.name; });" ++
        "});",
        "home:webcore-bodyused-setup", 1, null);
    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "globalThis.__used === 'TypeError'"));
}

test "Blob.stream() yields a ReadableStream draining to the original bytes" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installPrereqs(std.testing.allocator, ctx, engine.currentGlobalObject());

    // stream() is sync; the drain runs on the microtask queue inside one eval.
    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(new Blob(['x']).stream()) instanceof ReadableStream"));
    _ = try evaluate.evaluateUtf8(std.testing.allocator, ctx,
        "globalThis.__bs = null;" ++
        "(function(){" ++
        "  var rs = new Blob(['hé', 'llo']).stream();" ++
        "  (async function(){" ++
        "    var chunks = [];" ++
        "    for await (var ch of rs) chunks.push(ch);" ++
        "    var total = 0; for (var i = 0; i < chunks.length; i++) total += chunks[i].length;" ++
        "    var out = new Uint8Array(total), off = 0;" ++
        "    for (var j = 0; j < chunks.length; j++) { out.set(chunks[j], off); off += chunks[j].length; }" ++
        "    globalThis.__bs = new TextDecoder().decode(out);" ++
        "  })();" ++
        "})();",
        "home:webcore-blobstream-setup", 1, null);
    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "globalThis.__bs === 'héllo'"));
}

test "Response.body is a ReadableStream draining to the body bytes" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installPrereqs(std.testing.allocator, ctx, engine.currentGlobalObject());

    // A body present -> ReadableStream; no body -> null.
    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function() {" ++
        "  var r = new Response('hello');" ++
        "  if (!(r.body instanceof ReadableStream)) return false;" ++
        "  return new Response(null).body === null;" ++
        "})()"));
    _ = try evaluate.evaluateUtf8(std.testing.allocator, ctx,
        "globalThis.__rbody = null;" ++
        "(function(){" ++
        "  var rs = new Response('hello').body;" ++
        "  (async function(){" ++
        "    var chunks = [];" ++
        "    for await (var ch of rs) chunks.push(ch);" ++
        "    var total = 0; for (var i = 0; i < chunks.length; i++) total += chunks[i].length;" ++
        "    var out = new Uint8Array(total), off = 0;" ++
        "    for (var j = 0; j < chunks.length; j++) { out.set(chunks[j], off); off += chunks[j].length; }" ++
        "    globalThis.__rbody = new TextDecoder().decode(out);" ++
        "  })();" ++
        "})();",
        "home:webcore-respbody-setup", 1, null);
    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "globalThis.__rbody === 'hello'"));
}

test "reading .body sets bodyUsed and a second consume is rejected" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installPrereqs(std.testing.allocator, ctx, engine.currentGlobalObject());

    // Reading .body flips bodyUsed synchronously, and a second .body access throws.
    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function() {" ++
        "  var r = new Response('hello');" ++
        "  if (r.bodyUsed !== false) return false;" ++
        "  var b = r.body;" ++
        "  if (!(b instanceof ReadableStream) || r.bodyUsed !== true) return false;" ++
        "  try { var b2 = r.body; return false; } catch (e) { return e.name === 'TypeError'; }" ++
        "})()"));

    // After .body, text() rejects via the shared single-consumption guard.
    _ = try evaluate.evaluateUtf8(std.testing.allocator, ctx,
        "globalThis.__bodyGuard = null;" ++
        "var r = new Response('once');" ++
        "var s = r.body;" ++
        "r.text().then(function() { globalThis.__bodyGuard = 'no-throw'; }, function(e) { globalThis.__bodyGuard = e.name; });",
        "home:webcore-bodyguard-setup", 1, null);
    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "globalThis.__bodyGuard === 'TypeError'"));
}
