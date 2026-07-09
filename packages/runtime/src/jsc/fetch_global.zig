// Phase 3 — `fetch()` for the native JSC eval/run realm, first cut.
//
// Returns a `Promise<Response>` (the realm's event loop drains it). This cut
// supports the schemes that need no network:
//   - `data:` URLs — parsed in JS (mediatype + base64/percent-encoded payload)
//     into a real `Response`.
//   - `file:` URLs — read natively (libc-free, via the shared single-threaded
//     `std.Io`) into a real `Response` (404-style rejection on a missing file).
// `http(s):`/other schemes reject with an explicit "not yet implemented"
// `TypeError` — honest until Home's HTTP client is wired into the loop.
//
// Builds on the WebCore data types (`Response`/`Headers`) and the web globals
// (`TextEncoder`/`atob`); installed after them. comptime-gated on `enable_jsc`.

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

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn jsStringValue(ctx: *JSContextRef, text: []const u8) ?*JSValue {
    const allocator = std.heap.page_allocator;
    const text_z = bun.dupeZ(allocator, u8, text) catch return null;
    defer allocator.free(text_z);
    const string = extern_fns.JSStringCreateWithUTF8CString(text_z.ptr) orelse return null;
    defer extern_fns.JSStringRelease(string);
    return extern_fns.JSValueMakeString(ctx, string);
}

fn setProp(ctx: *JSContextRef, object: *JSObject, key: []const u8, value: ?*JSValue) void {
    const allocator = std.heap.page_allocator;
    const key_z = bun.dupeZ(allocator, u8, key) catch return;
    defer allocator.free(key_z);
    const name = extern_fns.JSStringCreateWithUTF8CString(key_z.ptr) orelse return;
    defer extern_fns.JSStringRelease(name);
    extern_fns.JSObjectSetProperty(ctx, object, name, value, 0, null);
}

/// Read a JS string argument into an owned UTF-8 slice (caller frees).
fn argToOwnedUtf8(ctx: *JSContextRef, value: *JSValue, allocator: std.mem.Allocator) ?[]u8 {
    const string = extern_fns.JSValueToStringCopy(ctx, value, null) orelse return null;
    defer extern_fns.JSStringRelease(string);
    const capacity = extern_fns.JSStringGetLength(string) * 4 + 1;
    const buf = allocator.alloc(u8, capacity) catch return null;
    const written = extern_fns.JSStringGetUTF8CString(string, buf.ptr, buf.len);
    return buf[0 .. if (written > 0) written - 1 else 0];
}

fn errorResult(ctx: *JSContextRef, message: []const u8) ?*JSValue {
    const object = extern_fns.JSObjectMake(ctx, null, null) orelse return extern_fns.JSValueMakeNull(ctx);
    setProp(ctx, object, "error", jsStringValue(ctx, message));
    return @ptrCast(object);
}

/// `__home_fetch_http(method, url, bodyOrNull, [name, value, ...])` performs a
/// real (blocking) HTTP/HTTPS request via std.http.Client and returns
/// `{ status, body: Uint8Array }`, or `{ error }` on failure. Request headers
/// come from the flat name/value array; response headers are not surfaced yet.
fn httpFetchNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this_object: ?*JSObject,
    argc: usize,
    argv: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    _ = function;
    _ = this_object;
    _ = exception;
    const c = ctx orelse return null;
    if (argc < 2) return errorResult(c, "fetch: missing method/url");

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const method_str = (if (argv[0]) |v| argToOwnedUtf8(c, v, arena) else null) orelse return errorResult(c, "fetch: bad method");
    const url = (if (argv[1]) |v| argToOwnedUtf8(c, v, arena) else null) orelse return errorResult(c, "fetch: bad url");

    var payload: ?[]const u8 = null;
    if (argc >= 3) {
        if (argv[2]) |v| {
            if (!extern_fns.JSValueIsNull(c, v) and !extern_fns.JSValueIsUndefined(c, v)) {
                payload = argToOwnedUtf8(c, v, arena);
            }
        }
    }

    // Build request headers from the flat [name, value, ...] array.
    var headers: std.ArrayListUnmanaged(std.http.Header) = .empty;
    if (argc >= 4) {
        if (argv[3]) |arr_v| {
            if (extern_fns.JSValueToObject(c, arr_v, null)) |arr| {
                const len_name = extern_fns.JSStringCreateWithUTF8CString("length");
                const len_val = if (len_name) |ln| extern_fns.JSObjectGetProperty(c, arr, ln, null) else null;
                if (len_name) |ln| extern_fns.JSStringRelease(ln);
                const count: usize = if (len_val) |lv| @intFromFloat(extern_fns.JSValueToNumber(c, lv, null)) else 0;
                var i: usize = 0;
                while (i + 1 < count) : (i += 2) {
                    const name_v = extern_fns.JSObjectGetPropertyAtIndex(c, arr, @intCast(i), null);
                    const value_v = extern_fns.JSObjectGetPropertyAtIndex(c, arr, @intCast(i + 1), null);
                    const name = (if (name_v) |nv| argToOwnedUtf8(c, nv, arena) else null) orelse continue;
                    const value = (if (value_v) |vv| argToOwnedUtf8(c, vv, arena) else null) orelse continue;
                    headers.append(arena, .{ .name = name, .value = value }) catch {};
                }
            }
        }
    }

    const method = std.meta.stringToEnum(std.http.Method, method_str) orelse .GET;

    var client: std.http.Client = .{ .allocator = arena, .io = io() };
    defer client.deinit();

    var body_writer = std.Io.Writer.Allocating.init(std.heap.page_allocator);
    defer body_writer.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = payload,
        .response_writer = &body_writer.writer,
        .extra_headers = headers.items,
    }) catch |err| return errorResult(c, @errorName(err));

    const object = extern_fns.JSObjectMake(c, null, null) orelse return extern_fns.JSValueMakeNull(c);
    setProp(c, object, "status", extern_fns.JSValueMakeNumber(c, @floatFromInt(@intFromEnum(result.status))));
    setProp(c, object, "body", makeUint8Array(c, body_writer.written()));
    return @ptrCast(object);
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

/// `__home_fetch_read_file(path)` -> `Uint8Array` of the file's bytes, or
/// `null` if it can't be read (missing/permission/etc.).
fn readFileNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this_object: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    _ = function;
    _ = this_object;
    _ = exception;
    const c = ctx orelse return null;
    if (argument_count < 1) return extern_fns.JSValueMakeNull(c);
    const value = arguments[0] orelse return extern_fns.JSValueMakeNull(c);

    const allocator = std.heap.page_allocator;
    const path = argToOwnedUtf8(c, value, allocator) orelse return extern_fns.JSValueMakeNull(c);
    defer allocator.free(path);
    if (path.len == 0) return extern_fns.JSValueMakeNull(c);

    const bytes = std.Io.Dir.cwd().readFileAlloc(io(), path, allocator, std.Io.Limit.limited(256 * 1024 * 1024)) catch
        return extern_fns.JSValueMakeNull(c);
    defer allocator.free(bytes);
    return makeUint8Array(c, bytes);
}

const install_glue =
    \\(function() {
    \\  var readFile = globalThis.__home_fetch_read_file;
    \\  var httpFetch = globalThis.__home_fetch_http;
    \\
    \\  function parseDataUrl(url) {
    \\    var comma = url.indexOf(",");
    \\    if (comma === -1) throw new TypeError("Invalid data: URL");
    \\    var meta = url.slice(5, comma);
    \\    var data = url.slice(comma + 1);
    \\    var base64 = false;
    \\    if (/;base64$/i.test(meta)) { base64 = true; meta = meta.slice(0, -7); }
    \\    var mediatype = meta || "text/plain;charset=US-ASCII";
    \\    var bytes;
    \\    if (base64) {
    \\      var bin = atob(data);
    \\      bytes = new Uint8Array(bin.length);
    \\      for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    \\    } else {
    \\      bytes = new TextEncoder().encode(decodeURIComponent(data));
    \\    }
    \\    return { bytes: bytes, mediatype: mediatype };
    \\  }
    \\
    \\  function extType(path) {
    \\    var m = /\.([a-z0-9]+)$/i.exec(path);
    \\    var e = m ? m[1].toLowerCase() : "";
    \\    if (e === "json") return "application/json";
    \\    if (e === "js" || e === "mjs") return "text/javascript";
    \\    if (e === "txt") return "text/plain;charset=UTF-8";
    \\    if (e === "html" || e === "htm") return "text/html";
    \\    if (e === "css") return "text/css";
    \\    if (e === "wasm") return "application/wasm";
    \\    return "application/octet-stream";
    \\  }
    \\
    \\  globalThis.fetch = function(input, init) {
    \\    try {
    \\      var url;
    \\      if (input && typeof input === "object" && typeof input.url === "string") url = input.url;
    \\      else if (typeof URL !== "undefined" && input instanceof URL) url = input.href;
    \\      else url = String(input);
    \\
    \\      if (url.slice(0, 5) === "data:") {
    \\        var d = parseDataUrl(url);
    \\        return Promise.resolve(new Response(d.bytes, { status: 200, headers: { "content-type": d.mediatype } }));
    \\      }
    \\      if (url.slice(0, 5) === "file:") {
    \\        var path = url.slice(5);
    \\        if (path.slice(0, 2) === "//") path = path.slice(2);
    \\        path = decodeURIComponent(path);
    \\        var bytes = readFile(path);
    \\        if (bytes === null || bytes === undefined) {
    \\          var err = new TypeError("fetch() failed: file not found: " + path);
    \\          return Promise.reject(err);
    \\        }
    \\        var resp = new Response(bytes, { status: 200, headers: { "content-type": extType(path) } });
    \\        resp.url = url;
    \\        return Promise.resolve(resp);
    \\      }
    \\      var method = "GET";
    \\      if (init && init.method) method = String(init.method).toUpperCase();
    \\      else if (input && typeof input === "object" && input.method) method = String(input.method).toUpperCase();
    \\      var bodyStr = null;
    \\      var rawBody = (init && init.body !== undefined) ? init.body : (input && typeof input === "object" ? input._bodyBytes : undefined);
    \\      if (rawBody !== undefined && rawBody !== null) {
    \\        if (typeof rawBody === "string") bodyStr = rawBody;
    \\        else if (rawBody instanceof Uint8Array) bodyStr = new TextDecoder().decode(rawBody);
    \\        else bodyStr = String(rawBody);
    \\      }
    \\      var headerPairs = [];
    \\      var hsrc = (init && init.headers) ? init.headers : (input && typeof input === "object" ? input.headers : undefined);
    \\      if (hsrc) { new Headers(hsrc).forEach(function(v, k) { headerPairs.push(k); headerPairs.push(v); }); }
    \\      var res = httpFetch(method, url, bodyStr, headerPairs);
    \\      if (!res || res.error) return Promise.reject(new TypeError("fetch failed: " + (res ? res.error : "unknown") + " (" + url + ")"));
    \\      var resp = new Response(res.body, { status: res.status });
    \\      resp.url = url;
    \\      return Promise.resolve(resp);
    \\    } catch (e) {
    \\      return Promise.reject(e);
    \\    }
    \\  };
    \\
    \\  // --- AbortSignal support (retrofit, wraps the fetch defined above) ---
    \\  // The realm has no DOMException; provide a minimal one so AbortError has
    \\  // the right .name and is an Error instance, then keep it on globalThis.
    \\  if (typeof globalThis.DOMException !== "function") {
    \\    var DOMExceptionCtor = function DOMException(message, name) {
    \\      var err = new Error(message === undefined ? "" : String(message));
    \\      err.name = (name === undefined ? "Error" : String(name));
    \\      err.message = (message === undefined ? "" : String(message));
    \\      Object.setPrototypeOf(err, DOMException.prototype);
    \\      return err;
    \\    };
    \\    DOMExceptionCtor.prototype = Object.create(Error.prototype);
    \\    DOMExceptionCtor.prototype.constructor = DOMExceptionCtor;
    \\    DOMExceptionCtor.prototype.name = "Error";
    \\    globalThis.DOMException = DOMExceptionCtor;
    \\  }
    \\  // Normalize an abort reason into a real Error/DOMException. The realm's
    \\  // AbortController.abort()/AbortSignal.abort() leave reason as a PLAIN object
    \\  // ({ name, message }) when no reason is given, so passing it through verbatim
    \\  // would fail `instanceof Error`/`instanceof DOMException`. Pass real Errors
    \\  // through untouched; coerce anything else into a DOMException.
    \\  function makeAbortError(reason) {
    \\    if (reason instanceof Error) return reason;
    \\    var name = "AbortError", msg = "The operation was aborted.";
    \\    if (reason !== undefined && reason !== null && typeof reason === "object") {
    \\      if (reason.name !== undefined) name = String(reason.name);
    \\      if (reason.message !== undefined) msg = String(reason.message);
    \\    }
    \\    return new globalThis.DOMException(msg, name);
    \\  }
    \\
    \\  var __homeInnerFetch = globalThis.fetch;
    \\  globalThis.fetch = function(input, init) {
    \\    var signal;
    \\    if (init && init.signal !== undefined && init.signal !== null) signal = init.signal;
    \\    else if (input && typeof input === "object" && input.signal !== undefined && input.signal !== null) signal = input.signal;
    \\
    \\    // Already-aborted -> reject up front (covers the sync data:/file: paths too).
    \\    if (signal && signal.aborted) return Promise.reject(makeAbortError(signal.reason));
    \\
    \\    var inner;
    \\    try { inner = __homeInnerFetch(input, init); }
    \\    catch (e) { return Promise.reject(e); }
    \\
    \\    // No signal: behave exactly as before.
    \\    if (!signal || typeof signal.addEventListener !== "function") return inner;
    \\
    \\    // Race the in-flight response against a later abort.
    \\    return new Promise(function(resolve, reject) {
    \\      var settled = false;
    \\      var onAbort = function() {
    \\        if (settled) return;
    \\        settled = true;
    \\        reject(makeAbortError(signal.reason));
    \\      };
    \\      signal.addEventListener("abort", onAbort, { once: true });
    \\      Promise.resolve(inner).then(function(resp) {
    \\        if (settled) return;
    \\        settled = true;
    \\        if (typeof signal.removeEventListener === "function") signal.removeEventListener("abort", onAbort);
    \\        resolve(resp);
    \\      }, function(err) {
    \\        if (settled) return;
    \\        settled = true;
    \\        if (typeof signal.removeEventListener === "function") signal.removeEventListener("abort", onAbort);
    \\        reject(err);
    \\      });
    \\    });
    \\  };
    \\  delete globalThis.__home_fetch_read_file;
    \\  delete globalThis.__home_fetch_http;
    \\})();
;

/// Install `fetch`. No-op without JSC. Must run after the WebCore + web
/// globals it relies on (`Response`, `TextEncoder`, `atob`).
pub fn install(allocator: std.mem.Allocator, ctx: *JSContextRef, global: *JSGlobalObject) void {
    if (comptime !build_options.enable_jsc) return;
    callback.registerCallback(ctx, global, "__home_fetch_read_file", readFileNative);
    callback.registerCallback(ctx, global, "__home_fetch_http", httpFetchNative);
    const result = evaluate.evaluateUtf8Detailed(allocator, ctx, install_glue, "home:fetch-install", 1) catch return;
    result.deinit(allocator);
}

fn evalBool(allocator: std.mem.Allocator, ctx: *JSContextRef, source: []const u8) !bool {
    const value = (try evaluate.evaluateUtf8(allocator, ctx, source, "home:fetch-probe", 1, null)) orelse
        return error.JSEvaluateReturnedNull;
    return extern_fns.JSValueToBoolean(ctx, value);
}

fn installRealm(allocator: std.mem.Allocator, ctx: *JSContextRef, global: *JSGlobalObject) void {
    @import("web_globals.zig").install(allocator, ctx, global);
    @import("url_global.zig").install(allocator, ctx, global);
    @import("webcore_globals.zig").install(allocator, ctx, global);
    install(allocator, ctx, global);
}

test "fetch resolves a data: URL into a Response" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealm(std.testing.allocator, ctx, engine.currentGlobalObject());

    // text data URL
    _ = try evaluate.evaluateUtf8(std.testing.allocator, ctx,
        "globalThis.__d = null; fetch('data:text/plain,hello%20world').then(function(r) { return r.text().then(function(t) { globalThis.__d = r.status + ':' + r.headers.get('content-type') + ':' + t; }); });",
        "home:fetch-data-setup", 1, null);
    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "globalThis.__d === '200:text/plain:hello world'"));

    // base64 data URL
    _ = try evaluate.evaluateUtf8(std.testing.allocator, ctx,
        "globalThis.__b = null; fetch('data:text/plain;base64,aGVsbG8=').then(function(r) { return r.text().then(function(t) { globalThis.__b = t; }); });",
        "home:fetch-b64-setup", 1, null);
    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "globalThis.__b === 'hello'"));
}

test "fetch reads a file: URL natively into a Response" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    // Write a known temp file through the same shared Io the native read uses.
    const path = "/tmp/home_fetch_unit_test.txt";
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = path, .data = "file-body-123" });
    defer std.Io.Dir.cwd().deleteFile(io(), path) catch {};

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealm(std.testing.allocator, ctx, engine.currentGlobalObject());

    _ = try evaluate.evaluateUtf8(std.testing.allocator, ctx,
        "globalThis.__f = null; fetch('file:///tmp/home_fetch_unit_test.txt').then(function(r) { return r.text().then(function(t) { globalThis.__f = r.status + ':' + t; }); });",
        "home:fetch-file-setup", 1, null);
    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "globalThis.__f === '200:file-body-123'"));
}

test "fetch rejects a missing file: URL" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealm(std.testing.allocator, ctx, engine.currentGlobalObject());

    _ = try evaluate.evaluateUtf8(std.testing.allocator, ctx,
        "globalThis.__m = null; fetch('file:///tmp/home_does_not_exist_xyz.txt').then(function() { globalThis.__m = 'resolved'; }, function(e) { globalThis.__m = e.name; });",
        "home:fetch-missing-setup", 1, null);
    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "globalThis.__m === 'TypeError'"));
}

test "fetch attempts http: and rejects on a refused connection" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealm(std.testing.allocator, ctx, engine.currentGlobalObject());

    // Port 1 on loopback is reliably closed: the request is attempted (no
    // "not implemented" stub) and rejects with a connection error. No external
    // network is touched.
    _ = try evaluate.evaluateUtf8(std.testing.allocator, ctx,
        "globalThis.__h = null; fetch('http://127.0.0.1:1/').then(function() { globalThis.__h = 'resolved'; }, function(e) { globalThis.__h = e.name; });",
        "home:fetch-http-setup", 1, null);
    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "globalThis.__h === 'TypeError'"));
}

test "fetch with an already-aborted signal rejects with an AbortError DOMException" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealm(std.testing.allocator, ctx, engine.currentGlobalObject());

    // A pre-aborted signal rejects even though the data: path would resolve sync.
    _ = try evaluate.evaluateUtf8(std.testing.allocator, ctx,
        "globalThis.__ab = null;" ++
        "var ctrl = new AbortController();" ++
        "ctrl.abort();" ++
        "fetch('data:,hello', { signal: ctrl.signal }).then(" ++
        "  function() { globalThis.__ab = 'resolved'; }," ++
        "  function(e) { globalThis.__ab = e.name + ':' + (e instanceof Error) + ':' + (e instanceof DOMException); });",
        "home:fetch-aborted-setup", 1, null);
    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "globalThis.__ab === 'AbortError:true:true'"));
}

test "fetch rejects with AbortError when the signal aborts mid-flight" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealm(std.testing.allocator, ctx, engine.currentGlobalObject());

    // Abort the http: request before it can settle: the abort listener wins the race.
    _ = try evaluate.evaluateUtf8(std.testing.allocator, ctx,
        "globalThis.__mid = null;" ++
        "var ctrl = new AbortController();" ++
        "var p = fetch('http://127.0.0.1:1/', { signal: ctrl.signal });" ++
        "p.then(function() { globalThis.__mid = 'resolved'; }, function(e) { globalThis.__mid = e.name; });" ++
        "ctrl.abort();",
        "home:fetch-midflight-setup", 1, null);
    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "globalThis.__mid === 'AbortError'"));
}

test "fetch data: response .body drains to the original bytes via getReader" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealm(std.testing.allocator, ctx, engine.currentGlobalObject());

    // The resolved Response exposes a ReadableStream body backed by the bytes.
    _ = try evaluate.evaluateUtf8(std.testing.allocator, ctx,
        "globalThis.__bd = null;" ++
        "fetch('data:,hi').then(function(r) {" ++
        "  if (!(r.body instanceof ReadableStream)) { globalThis.__bd = 'not-stream'; return; }" ++
        "  var reader = r.body.getReader();" ++
        "  var chunks = [];" ++
        "  function loop() {" ++
        "    return reader.read().then(function(res) {" ++
        "      if (res.done) {" ++
        "        var total = 0; for (var i = 0; i < chunks.length; i++) total += chunks[i].length;" ++
        "        var out = new Uint8Array(total), off = 0;" ++
        "        for (var j = 0; j < chunks.length; j++) { out.set(chunks[j], off); off += chunks[j].length; }" ++
        "        globalThis.__bd = new TextDecoder().decode(out);" ++
        "        return;" ++
        "      }" ++
        "      chunks.push(res.value);" ++
        "      return loop();" ++
        "    });" ++
        "  }" ++
        "  return loop();" ++
        "});",
        "home:fetch-body-setup", 1, null);
    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "globalThis.__bd === 'hi'"));
}

test "fetch accepts a Request object as input" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealm(std.testing.allocator, ctx, engine.currentGlobalObject());

    // A Request carrying a data: URL resolves through fetch via its .url.
    _ = try evaluate.evaluateUtf8(std.testing.allocator, ctx,
        "globalThis.__rq = null;" ++
        "var req = new Request('data:text/plain,from-request');" ++
        "fetch(req).then(function(r) { return r.text().then(function(t) { globalThis.__rq = r.status + ':' + t; }); });",
        "home:fetch-request-setup", 1, null);
    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "globalThis.__rq === '200:from-request'"));
}
