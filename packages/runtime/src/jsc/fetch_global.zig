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
const build_options = @import("build_options");
const evaluate = @import("evaluate.zig");
const callback = @import("callback.zig");
const extern_fns = @import("extern_fns.zig");
const opaques = @import("opaques.zig");

const JSValue = opaques.JSValue;
const JSContextRef = opaques.JSContextRef;
const JSObject = opaques.JSObject;
const JSGlobalObject = opaques.JSGlobalObject;

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
    const string = extern_fns.JSValueToStringCopy(c, value, null) orelse return extern_fns.JSValueMakeNull(c);
    defer extern_fns.JSStringRelease(string);
    const capacity = extern_fns.JSStringGetLength(string) * 4 + 1;
    const path_buf = allocator.alloc(u8, capacity) catch return extern_fns.JSValueMakeNull(c);
    defer allocator.free(path_buf);
    const written = extern_fns.JSStringGetUTF8CString(string, path_buf.ptr, path_buf.len);
    const path = path_buf[0 .. if (written > 0) written - 1 else 0];
    if (path.len == 0) return extern_fns.JSValueMakeNull(c);

    const io = std.Io.Threaded.global_single_threaded.io();
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, std.Io.Limit.limited(256 * 1024 * 1024)) catch
        return extern_fns.JSValueMakeNull(c);
    defer allocator.free(bytes);
    return makeUint8Array(c, bytes);
}

const install_glue =
    \\(function() {
    \\  var readFile = globalThis.__home_fetch_read_file;
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
    \\      return Promise.reject(new TypeError(
    \\        "fetch(): network requests are not yet implemented in Home's native runtime " +
    \\        "(only data: and file: URLs are supported so far) — requested: " + url));
    \\    } catch (e) {
    \\      return Promise.reject(e);
    \\    }
    \\  };
    \\  delete globalThis.__home_fetch_read_file;
    \\})();
;

/// Install `fetch`. No-op without JSC. Must run after the WebCore + web
/// globals it relies on (`Response`, `TextEncoder`, `atob`).
pub fn install(allocator: std.mem.Allocator, ctx: *JSContextRef, global: *JSGlobalObject) void {
    if (comptime !build_options.enable_jsc) return;
    callback.registerCallback(ctx, global, "__home_fetch_read_file", readFileNative);
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
    const io = std.Io.Threaded.global_single_threaded.io();
    const path = "/tmp/home_fetch_unit_test.txt";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "file-body-123" });
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

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

test "fetch rejects an http: URL as not-yet-implemented" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealm(std.testing.allocator, ctx, engine.currentGlobalObject());

    _ = try evaluate.evaluateUtf8(std.testing.allocator, ctx,
        "globalThis.__h = null; fetch('https://example.com').then(function() { globalThis.__h = 'resolved'; }, function(e) { globalThis.__h = e.name + ':' + /not yet implemented/.test(e.message); });",
        "home:fetch-http-setup", 1, null);
    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "globalThis.__h === 'TypeError:true'"));
}
