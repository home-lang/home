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
    \\  // File — WHATWG File, a named Blob with a modification timestamp.
    \\  class File extends Blob {
    \\    constructor(fileBits, fileName, options) {
    \\      super(fileBits, options);
    \\      if (fileName === undefined) throw new TypeError("File constructor requires a fileName argument");
    \\      this.name = String(fileName);
    \\      var lm = options && options.lastModified;
    \\      this.lastModified = (typeof lm === "number") ? lm : Date.now();
    \\      this.webkitRelativePath = "";
    \\    }
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
    \\    static json(data, init) { var r = new this(JSON.stringify(data), init); r.headers.set("content-type", "application/json"); return r; }
    \\    static error() { var r = new this(null, { status: 0 }); r.type = "error"; return r; }
    \\    static redirect(url, status) { return new this(null, { status: status || 302, headers: { location: String(url) } }); }
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
    \\        if (this._bodyStreamCached) return this._bodyStreamCached;
    \\        if (this._bodyBytes === null || this._bodyBytes === undefined) return null;
    \\        this._bodyStreamCached = bytesToStream(this._bodyBytes);
    \\        this.bodyUsed = true;
    \\        return this._bodyStreamCached;
    \\      },
    \\      enumerable: true,
    \\      configurable: true
    \\    });
    \\  }
    \\  defineBodyStream(Request.prototype);
    \\  defineBodyStream(Response.prototype);
    \\
    \\  globalThis.Headers = Headers;
    \\  // Stream-aware bodies: Request/Response may receive a ReadableStream init.body.
    \\  // Detect it by duck-typing (getReader), store it on _bodyStream, and drain it the
    \\  // first time a body accessor runs, sharing the bodyUsed single-consumption guard.
    \\  function __homeIsStream(x) { return x !== null && x !== undefined && typeof x.getReader === "function"; }
    \\  function __homeDrainStream(stream) {
    \\    var reader = stream.getReader();
    \\    var chunks = [];
    \\    function loop() {
    \\      return reader.read().then(function(r) {
    \\        if (r.done) return concatBytes(chunks);
    \\        chunks.push(r.value);
    \\        return loop();
    \\      });
    \\    }
    \\    return loop();
    \\  }
    \\  function __homeConsumeStream(self) {
    \\    if (self.bodyUsed) return Promise.reject(new TypeError("Body already used"));
    \\    self.bodyUsed = true;
    \\    if (self._bodyStream) return __homeDrainStream(self._bodyStream);
    \\    return Promise.resolve(self._bodyBytes || new Uint8Array(0));
    \\  }
    \\  function defineStreamBody(proto) {
    \\    proto.arrayBuffer = function() { return __homeConsumeStream(this).then(function(b) { return b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength); }); };
    \\    proto.bytes = function() { return __homeConsumeStream(this).then(function(b) { return b.slice(); }); };
    \\    proto.text = function() { return __homeConsumeStream(this).then(function(b) { return new TextDecoder().decode(b); }); };
    \\    proto.json = function() { return this.text().then(function(t) { return JSON.parse(t); }); };
    \\    proto.blob = function() { var t = this.headers ? this.headers.get("content-type") : null; return __homeConsumeStream(this).then(function(b) { var nb = new Blob([], { type: t || "" }); nb._bytes = b; return nb; }); };
    \\    Object.defineProperty(proto, "body", {
    \\      get: function() {
    \\        if (this._bodyStreamCached) return this._bodyStreamCached;
    \\        var s;
    \\        if (this._bodyStream) s = this._bodyStream;
    \\        else if (this._bodyBytes === null || this._bodyBytes === undefined) return null;
    \\        else s = bytesToStream(this._bodyBytes);
    \\        this._bodyStreamCached = s;
    \\        this.bodyUsed = true;
    \\        return s;
    \\      },
    \\      enumerable: true,
    \\      configurable: true
    \\    });
    \\  }
    \\  defineStreamBody(Request.prototype);
    \\  defineStreamBody(Response.prototype);
    \\  var __HomeBaseRequest = Request;
    \\  Request = class extends __HomeBaseRequest {
    \\    constructor(input, init) {
    \\      init = init || {};
    \\      var streamBody = __homeIsStream(init.body) ? init.body : null;
    \\      if (streamBody) { var i2 = {}; for (var k in init) if (hasOwn(init, k)) i2[k] = init[k]; i2.body = null; super(input, i2); this._bodyStream = streamBody; }
    \\      else { super(input, init); this._bodyStream = (input instanceof __HomeBaseRequest && input._bodyStream) ? input._bodyStream : null; }
    \\      this.signal = init.signal !== undefined ? init.signal : (input instanceof __HomeBaseRequest ? input.signal : undefined);
    \\    }
    \\  };
    \\  var __HomeBaseResponse = Response;
    \\  Response = class extends __HomeBaseResponse {
    \\    constructor(body, init) {
    \\      var streamBody = __homeIsStream(body) ? body : null;
    \\      super(streamBody ? null : body, init);
    \\      this._bodyStream = streamBody;
    \\    }
    \\  };
    \\  // FormData — WHATWG multipart form data (values are strings or Blob/File).
    \\  class FormData {
    \\    constructor() { this._entries = []; }
    \\    append(name, value, filename) { this._entries.push([String(name), this._coerce(value, filename)]); }
    \\    set(name, value, filename) { name = String(name); var v = this._coerce(value, filename); var replaced = false; var out = []; for (var i = 0; i < this._entries.length; i++) { if (this._entries[i][0] === name) { if (!replaced) { out.push([name, v]); replaced = true; } } else out.push(this._entries[i]); } if (!replaced) out.push([name, v]); this._entries = out; }
    \\    _coerce(value, filename) {
    \\      if (value && typeof Blob === "function" && value instanceof Blob) {
    \\        var isFile = typeof File === "function" && value instanceof File;
    \\        // A Blob given a filename (or a bare Blob) is stored as a File, per
    \\        // the WHATWG FormData "create an entry" steps; a Blob with no name
    \\        // defaults to the filename "blob".
    \\        if (filename !== undefined) { var f = new File([], String(filename), { type: value.type || "" }); f._bytes = value._bytes; if (isFile) f.lastModified = value.lastModified; return f; }
    \\        if (isFile) return value;
    \\        var fb = new File([], "blob", { type: value.type || "" }); fb._bytes = value._bytes; return fb;
    \\      }
    \\      return String(value);
    \\    }
    \\    get(name) { name = String(name); for (var i = 0; i < this._entries.length; i++) if (this._entries[i][0] === name) return this._entries[i][1]; return null; }
    \\    getAll(name) { name = String(name); var out = []; for (var i = 0; i < this._entries.length; i++) if (this._entries[i][0] === name) out.push(this._entries[i][1]); return out; }
    \\    has(name) { name = String(name); for (var i = 0; i < this._entries.length; i++) if (this._entries[i][0] === name) return true; return false; }
    \\    delete(name) { name = String(name); this._entries = this._entries.filter(function(e) { return e[0] !== name; }); }
    \\    forEach(cb, thisArg) { for (var i = 0; i < this._entries.length; i++) cb.call(thisArg, this._entries[i][1], this._entries[i][0], this); }
    \\    keys() { return this._entries.map(function(e) { return e[0]; })[Symbol.iterator](); }
    \\    values() { return this._entries.map(function(e) { return e[1]; })[Symbol.iterator](); }
    \\    entries() { return this._entries.map(function(e) { return [e[0], e[1]]; })[Symbol.iterator](); }
    \\    [Symbol.iterator]() { return this.entries(); }
    \\  }
    \\  globalThis.Blob = Blob;
    \\  globalThis.File = File;
    \\  globalThis.FormData = FormData;
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

test "File is a named Blob; FormData coerces blobs to files" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installPrereqs(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function() {" ++
        "  var f = new File(['hé', 'llo'], 'greeting.txt', { type: 'text/plain', lastModified: 123 });" ++
        "  if (!(f instanceof Blob) || !(f instanceof File)) return false;" ++
        "  if (f.name !== 'greeting.txt' || f.size !== 6 || f.type !== 'text/plain') return false;" ++
        "  if (f.lastModified !== 123 || f.webkitRelativePath !== '') return false;" ++
        "  if (typeof new File([], 'x').lastModified !== 'number') return false;" ++ // defaults to now
        "  var threw = false; try { new File(['a']); } catch (e) { threw = true; } if (!threw) return false;" ++
        // FormData: a Blob with a filename becomes a File; a bare Blob defaults to "blob".
        "  var fd = new FormData();" ++
        "  fd.append('doc', new Blob(['x'], { type: 'text/plain' }), 'a.txt');" ++
        "  fd.append('raw', new Blob(['y']));" ++
        "  fd.append('keep', f);" ++
        "  var d = fd.get('doc'); if (!(d instanceof File) || d.name !== 'a.txt') return false;" ++
        "  var r = fd.get('raw'); if (!(r instanceof File) || r.name !== 'blob') return false;" ++
        "  return fd.get('keep').name === 'greeting.txt';" ++
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

    // Reading .body flips bodyUsed synchronously; .body is idempotent (WHATWG:
    // repeated access returns the SAME ReadableStream, it does not throw).
    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function() {" ++
        "  var r = new Response('hello');" ++
        "  if (r.bodyUsed !== false) return false;" ++
        "  var b = r.body;" ++
        "  if (!(b instanceof ReadableStream) || r.bodyUsed !== true) return false;" ++
        "  return r.body === b;" ++
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

test "Response constructed from a ReadableStream drains to the original string" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installPrereqs(std.testing.allocator, ctx, engine.currentGlobalObject());

    // A ReadableStream init.body is stored; .text() drains it on the microtask queue.
    _ = try evaluate.evaluateUtf8(std.testing.allocator, ctx,
        "globalThis.__streamResp = null;" ++
        "var rs = new ReadableStream({ start: function(c) { c.enqueue(new TextEncoder().encode('héllo')); c.close(); } });" ++
        "new Response(rs).text().then(function(t) { globalThis.__streamResp = t; });",
        "home:webcore-streamresp-setup", 1, null);
    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "globalThis.__streamResp === 'héllo'"));
}

test "Request constructed from a ReadableStream body drains via text() and .body returns the stream" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installPrereqs(std.testing.allocator, ctx, engine.currentGlobalObject());

    // .body of a stream-bodied Request is the original stream object.
    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function() {" ++
        "  var rs = new ReadableStream({ start: function(c) { c.enqueue(new Uint8Array([1])); c.close(); } });" ++
        "  var r = new Request('https://h.com/x', { method: 'POST', body: rs });" ++
        "  return r.body === rs;" ++
        "})()"));

    // text() drains the stream body the first time.
    _ = try evaluate.evaluateUtf8(std.testing.allocator, ctx,
        "globalThis.__streamReq = null;" ++
        "var rs2 = new ReadableStream({ start: function(c) { c.enqueue(new TextEncoder().encode('wörld')); c.close(); } });" ++
        "new Request('https://h.com/x', { method: 'POST', body: rs2 }).text().then(function(t) { globalThis.__streamReq = t; });",
        "home:webcore-streamreq-setup", 1, null);
    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "globalThis.__streamReq === 'wörld'"));
}

test "Request carries init.signal (or undefined when absent)" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installPrereqs(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function() {" ++
        "  var sig = {};" ++
        "  var r = new Request('https://h.com/x', { signal: sig });" ++
        "  if (r.signal !== sig) return false;" ++
        "  return new Request('https://h.com/x').signal === undefined;" ++
        "})()"));
}

test "Response.redirect sets status and Location; error/json statics intact" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installPrereqs(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function() {" ++
        "  var r = Response.redirect('/x', 301);" ++
        "  if (r.status !== 301 || r.headers.get('location') !== '/x') return false;" ++
        "  if (Response.error().type !== 'error') return false;" ++
        "  return Response.json({ a: 1 }).headers.get('content-type') === 'application/json';" ++
        "})()"));
}
