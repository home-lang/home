// Native `Bun.serve` for the eval/run realm — a real HTTP/1.1 server.
//
//   const server = Bun.serve({ port: 3000, fetch(req) { return new Response("hi"); } });
//
// Execution model (mirrors Bun): `Bun.serve()` binds + listens immediately and
// returns the server object WITHOUT blocking, so the script keeps running. The
// process then stays alive serving: after the script's synchronous body and
// timer drain, `main.zig` calls `serve.runLoop`, which accepts connections and,
// per request, builds a JS `Request`, invokes the user's `fetch` handler,
// drains microtasks/timers to settle an async handler, reads the resolved
// `Response` synchronously via `Bun.peek`, and writes it back.
//
// SCOPE (v1): one server, HTTP/1.1, Connection: close per request, string /
// bytes / Blob response bodies. WebSocket upgrade, TLS, unix sockets, streaming
// request/response bodies, and `routes`/static responses are not implemented.
// comptime-gated on `enable_jsc`.

const std = @import("std");
const build_options = @import("build_options");
const evaluate = @import("evaluate.zig");
const callback = @import("callback.zig");
const extern_fns = @import("extern_fns.zig");
const opaques = @import("opaques.zig");
const timers = @import("timers_global.zig");

const c = std.c;
const JSValue = opaques.JSValue;
const JSContextRef = opaques.JSContextRef;
const JSObject = opaques.JSObject;
const JSGlobalObject = opaques.JSGlobalObject;

// `socket` is not pub in std.c on this target; declare it (the rest are pub).
extern "c" fn socket(domain: c_uint, sock_type: c_uint, protocol: c_uint) c_int;

// Module state for the single active server (v1). Set by __home_server_listen.
var g_listen_fd: c_int = -1;
var g_has_server: bool = false;

fn parseHostV4(host: []const u8) u32 {
    if (host.len == 0 or std.mem.eql(u8, host, "0.0.0.0")) return 0;
    var h = host;
    if (std.mem.eql(u8, host, "localhost")) h = "127.0.0.1";
    var parts: [4]u8 = .{ 0, 0, 0, 0 };
    var it = std.mem.splitScalar(u8, h, '.');
    var i: usize = 0;
    while (it.next()) |p| : (i += 1) {
        if (i >= 4) return 0;
        parts[i] = std.fmt.parseInt(u8, p, 10) catch return 0;
    }
    if (i != 4) return 0;
    return @bitCast(parts); // already network byte order (memory == wire)
}

/// `__home_server_listen(port, host)` -> fd (or -1). Binds + listens; remembers
/// the fd as the active server for the post-script loop.
fn listenNative(ctx: ?*JSContextRef, function: ?*JSObject, this_object: ?*JSObject, argc: usize, argv: [*c]const ?*JSValue, exception: extern_fns.ExceptionRef) callconv(.c) ?*JSValue {
    _ = function;
    _ = this_object;
    _ = exception;
    const cx = ctx orelse return null;
    if (argc < 1) return extern_fns.JSValueMakeNumber(cx, -1);
    const port: u16 = @intFromFloat(@max(0, @min(65535, extern_fns.JSValueToNumber(cx, argv[0].?, null))));
    var host_buf: [256]u8 = undefined;
    var host: []const u8 = "0.0.0.0";
    if (argc >= 2) {
        if (argv[1]) |hv| {
            const js = extern_fns.JSValueToStringCopy(cx, hv, null);
            if (js) |s| {
                defer extern_fns.JSStringRelease(s);
                const n = extern_fns.JSStringGetUTF8CString(s, &host_buf, host_buf.len);
                if (n > 0) host = host_buf[0 .. n - 1];
            }
        }
    }

    const fd = socket(c.AF.INET, c.SOCK.STREAM, 0);
    if (fd < 0) return extern_fns.JSValueMakeNumber(cx, -1);
    const one: c_int = 1;
    _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.REUSEADDR, &one, @sizeOf(c_int));

    var addr = c.sockaddr.in{
        .port = std.mem.nativeToBig(u16, port),
        .addr = parseHostV4(host),
    };
    if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.in)) != 0) {
        _ = c.close(fd);
        return extern_fns.JSValueMakeNumber(cx, -1);
    }
    if (c.listen(fd, 128) != 0) {
        _ = c.close(fd);
        return extern_fns.JSValueMakeNumber(cx, -1);
    }
    g_listen_fd = fd;
    g_has_server = true;
    return extern_fns.JSValueMakeNumber(cx, @floatFromInt(fd));
}

/// `__home_server_actual_port(fd)` -> the OS-assigned port (for port 0).
fn actualPortNative(ctx: ?*JSContextRef, function: ?*JSObject, this_object: ?*JSObject, argc: usize, argv: [*c]const ?*JSValue, exception: extern_fns.ExceptionRef) callconv(.c) ?*JSValue {
    _ = function;
    _ = this_object;
    _ = exception;
    const cx = ctx orelse return null;
    if (argc < 1) return extern_fns.JSValueMakeNumber(cx, 0);
    const fd: c_int = @intFromFloat(extern_fns.JSValueToNumber(cx, argv[0].?, null));
    var addr: c.sockaddr.in = undefined;
    var len: c.socklen_t = @sizeOf(c.sockaddr.in);
    if (c.getsockname(fd, @ptrCast(&addr), &len) != 0) return extern_fns.JSValueMakeNumber(cx, 0);
    return extern_fns.JSValueMakeNumber(cx, @floatFromInt(std.mem.bigToNative(u16, addr.port)));
}

pub fn install(allocator: std.mem.Allocator, ctx: *JSContextRef, global: *JSGlobalObject) void {
    if (comptime !build_options.enable_jsc) return;
    callback.registerCallback(ctx, global, "__home_server_listen", listenNative);
    callback.registerCallback(ctx, global, "__home_server_actual_port", actualPortNative);
    const result = evaluate.evaluateUtf8Detailed(allocator, ctx, install_glue, "home:bun-serve-install", 1) catch return;
    result.deinit(allocator);
}

// ── post-script accept/serve loop ────────────────────────────────────────────

fn makeUint8Array(ctx: *JSContextRef, bytes: []const u8) ?*JSValue {
    const array = extern_fns.JSObjectMakeTypedArray(ctx, .kJSTypedArrayTypeUint8Array, bytes.len, null) orelse return null;
    if (bytes.len > 0) {
        if (extern_fns.JSObjectGetTypedArrayBytesPtr(ctx, array, null)) |ptr| {
            const dest: [*]u8 = @ptrCast(ptr);
            @memcpy(dest[0..bytes.len], bytes);
        }
    }
    return @ptrCast(array);
}

fn setGlobal(ctx: *JSContextRef, global: *JSObject, name: [:0]const u8, value: ?*JSValue) void {
    const js = extern_fns.JSStringCreateWithUTF8CString(name.ptr) orelse return;
    defer extern_fns.JSStringRelease(js);
    extern_fns.JSObjectSetProperty(ctx, global, js, value, 0, null);
}

fn getGlobal(ctx: *JSContextRef, global: *JSObject, name: [:0]const u8) ?*JSValue {
    const js = extern_fns.JSStringCreateWithUTF8CString(name.ptr) orelse return null;
    defer extern_fns.JSStringRelease(js);
    return extern_fns.JSObjectGetProperty(ctx, global, js, null);
}

/// Read a full HTTP/1.1 request (headers + Content-Length body) from `fd`.
fn readRequest(allocator: std.mem.Allocator, fd: c_int) ?[]u8 {
    const cap: usize = 1 << 20;
    const buf = allocator.alloc(u8, cap) catch return null;
    defer allocator.free(buf); // free the scratch buffer; return an exact-size dupe
    var total: usize = 0;
    while (total < cap) {
        const n = c.recv(fd, buf.ptr + total, cap - total, 0);
        if (n <= 0) break;
        total += @intCast(n);
        if (requestComplete(buf[0..total])) break;
    }
    if (total == 0) return null;
    return allocator.dupe(u8, buf[0..total]) catch null;
}

fn requestComplete(data: []const u8) bool {
    const sep = std.mem.indexOf(u8, data, "\r\n\r\n") orelse return false;
    const header_end = sep + 4;
    // Find Content-Length (case-insensitive) in the header block.
    var content_len: usize = 0;
    var line_it = std.mem.splitSequence(u8, data[0..sep], "\r\n");
    while (line_it.next()) |line| {
        if (line.len > 15 and std.ascii.eqlIgnoreCase(line[0..15], "content-length:")) {
            const v = std.mem.trim(u8, line[15..], " \t");
            content_len = std.fmt.parseInt(usize, v, 10) catch 0;
        }
    }
    return data.len >= header_end + content_len;
}

fn writeAll(fd: c_int, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.send(fd, bytes.ptr + off, bytes.len - off, 0);
        if (n <= 0) break;
        off += @intCast(n);
    }
}

/// Run the accept loop until the listen socket is closed. Called by main.zig
/// after the script + timer drain when a server was registered. Blocks the
/// process (the server runs until killed), matching Bun's `bun run server.ts`.
pub fn runLoop(allocator: std.mem.Allocator, ctx: *JSContextRef) void {
    if (comptime !build_options.enable_jsc) return;
    if (!g_has_server) return;
    const fd = g_listen_fd;
    const global = extern_fns.JSContextGetGlobalObject(ctx) orelse return;

    while (true) {
        const client = c.accept(fd, null, null);
        if (client < 0) {
            if (std.posix.errno(@as(isize, client)) == .INTR) continue;
            break;
        }
        defer _ = c.close(client);

        const req = readRequest(allocator, client) orelse continue;
        defer allocator.free(req);

        setGlobal(ctx, global, "__home_req", makeUint8Array(ctx, req));
        const d = evaluate.evaluateUtf8Detailed(allocator, ctx, "globalThis.__home_serve_dispatch();", "home:serve-dispatch", 1) catch continue;
        d.deinit(allocator);

        timers.drain(ctx); // settle an async fetch handler's promise

        const f = evaluate.evaluateUtf8Detailed(allocator, ctx, "globalThis.__home_serve_finish();", "home:serve-finish", 1) catch continue;
        f.deinit(allocator);

        // Write the serialized response straight from the JS Uint8Array.
        const resp_v = getGlobal(ctx, global, "__home_resp") orelse continue;
        if (extern_fns.JSValueGetTypedArrayType(ctx, resp_v, null) == .kJSTypedArrayTypeNone) continue;
        const obj = extern_fns.JSValueToObject(ctx, resp_v, null) orelse continue;
        const len = extern_fns.JSObjectGetTypedArrayByteLength(ctx, obj, null);
        const ptr = extern_fns.JSObjectGetTypedArrayBytesPtr(ctx, obj, null);
        if (len > 0 and ptr != null) {
            writeAll(client, @as([*]const u8, @ptrCast(ptr.?))[0..len]);
        }
    }
}

const install_glue =
    \\(function() {
    \\  var B = globalThis.Bun;
    \\  if (!B) return;
    \\  var listenFn = globalThis.__home_server_listen;
    \\  var portFn = globalThis.__home_server_actual_port;
    \\  var STATUS = { 200:"OK",201:"Created",202:"Accepted",204:"No Content",206:"Partial Content",301:"Moved Permanently",302:"Found",303:"See Other",304:"Not Modified",307:"Temporary Redirect",308:"Permanent Redirect",400:"Bad Request",401:"Unauthorized",403:"Forbidden",404:"Not Found",405:"Method Not Allowed",406:"Not Acceptable",409:"Conflict",410:"Gone",413:"Payload Too Large",415:"Unsupported Media Type",418:"I'm a Teapot",422:"Unprocessable Entity",429:"Too Many Requests",500:"Internal Server Error",501:"Not Implemented",502:"Bad Gateway",503:"Service Unavailable",504:"Gateway Timeout" };
    \\  function statusText(s) { return STATUS[s] !== undefined ? STATUS[s] : ""; }
    \\
    \\  function parseRequest(bytes, srv) {
    \\    var head = "", sep = -1;
    \\    for (var i = 0; i + 3 < bytes.length; i++) {
    \\      if (bytes[i] === 13 && bytes[i+1] === 10 && bytes[i+2] === 13 && bytes[i+3] === 10) { sep = i; break; }
    \\    }
    \\    var headLen = sep >= 0 ? sep : bytes.length;
    \\    var headStr = "";
    \\    for (var k = 0; k < headLen; k++) headStr += String.fromCharCode(bytes[k]);
    \\    var lines = headStr.split("\r\n");
    \\    var rl = (lines[0] || "GET / HTTP/1.1").split(" ");
    \\    var method = rl[0] || "GET";
    \\    var path = rl[1] || "/";
    \\    var headers = {};
    \\    var host = srv.hostname + ":" + srv.port;
    \\    for (var j = 1; j < lines.length; j++) {
    \\      var ci = lines[j].indexOf(":");
    \\      if (ci > 0) {
    \\        var hk = lines[j].slice(0, ci).trim();
    \\        var hv = lines[j].slice(ci + 1).trim();
    \\        headers[hk] = hv;
    \\        if (hk.toLowerCase() === "host") host = hv;
    \\      }
    \\    }
    \\    var bodyBytes = null;
    \\    if (sep >= 0 && bytes.length > sep + 4) bodyBytes = bytes.slice(sep + 4);
    \\    var url = "http://" + host + path;
    \\    var init = { method: method, headers: headers };
    \\    if (bodyBytes && method !== "GET" && method !== "HEAD") init.body = bodyBytes;
    \\    return new Request(url, init);
    \\  }
    \\
    \\  function isResponseLike(v) {
    \\    return v && typeof v === "object" && typeof v.status === "number" && v.headers && typeof v.headers.forEach === "function";
    \\  }
    \\  function toResponse(v) {
    \\    if (isResponseLike(v)) return v; // duck-typed (avoids cross-Response-subclass instanceof pitfalls)
    \\    if (v === null || v === undefined) return new Response("", { status: 200 });
    \\    if (typeof v === "string") return new Response(v);
    \\    return new Response(String(v));
    \\  }
    \\
    \\  function serializeResponse(resp) {
    \\    var status = resp.status || 200;
    \\    var st = resp.statusText || statusText(status);
    \\    var body = resp._bodyBytes || new Uint8Array(0);
    \\    var head = "HTTP/1.1 " + status + " " + st + "\r\n";
    \\    var hasCL = false;
    \\    if (resp.headers && typeof resp.headers.forEach === "function") {
    \\      resp.headers.forEach(function(v, kk) { head += kk + ": " + v + "\r\n"; if (kk.toLowerCase() === "content-length") hasCL = true; });
    \\    }
    \\    if (!hasCL) head += "Content-Length: " + body.length + "\r\n";
    \\    head += "Connection: close\r\n\r\n";
    \\    var headBytes = new TextEncoder().encode(head);
    \\    var out = new Uint8Array(headBytes.length + body.length);
    \\    out.set(headBytes, 0);
    \\    out.set(body, headBytes.length);
    \\    return out;
    \\  }
    \\
    \\  globalThis.__home_serve_dispatch = function() {
    \\    var srv = globalThis.__home_active_server;
    \\    try {
    \\      var req = parseRequest(globalThis.__home_req, srv);
    \\      var res = srv.fetch.call(undefined, req, srv);
    \\      globalThis.__home_resp_promise = (res && typeof res.then === "function") ? res : Promise.resolve(res);
    \\    } catch (e) {
    \\      globalThis.__home_resp_promise = Promise.resolve(new Response("Internal Server Error: " + ((e && e.message) || e), { status: 500 }));
    \\    }
    \\  };
    \\  globalThis.__home_serve_finish = function() {
    \\    var resp;
    \\    try {
    \\      var peeked = Bun.peek(globalThis.__home_resp_promise);
    \\      if (peeked && typeof peeked.then === "function") resp = new Response("", { status: 500, statusText: "Internal Server Error" });
    \\      else resp = toResponse(peeked);
    \\    } catch (e) {
    \\      resp = new Response("Internal Server Error", { status: 500 });
    \\    }
    \\    globalThis.__home_resp = serializeResponse(resp);
    \\    globalThis.__home_resp_promise = null;
    \\  };
    \\
    \\  B.serve = function(options) {
    \\    options = options || {};
    \\    var fetch = options.fetch;
    \\    if (typeof fetch !== "function") throw new TypeError("Bun.serve() expects a fetch handler function");
    \\    var port;
    \\    if (options.port !== undefined) port = options.port | 0;
    \\    else if (typeof process !== "undefined" && process.env && process.env.PORT) port = process.env.PORT | 0;
    \\    else port = 3000;
    \\    var hostname = options.hostname || "0.0.0.0";
    \\    var fd = listenFn(port, hostname);
    \\    if (fd < 0) { var err = new Error("Failed to start server: address " + hostname + ":" + port + " in use or unavailable"); err.code = "EADDRINUSE"; throw err; }
    \\    var actualPort = portFn(fd) || port;
    \\    var displayHost = (hostname === "0.0.0.0" || hostname === "::") ? "localhost" : hostname;
    \\    var server = {
    \\      port: actualPort, hostname: hostname, development: !!options.development,
    \\      fetch: fetch, _fd: fd, pendingRequests: 0, pendingWebSockets: 0,
    \\      url: new URL("http://" + displayHost + ":" + actualPort + "/"),
    \\      stop: function() {},
    \\      reload: function(opts) { if (opts && typeof opts.fetch === "function") this.fetch = opts.fetch; },
    \\      ref: function() {}, unref: function() {},
    \\      requestIP: function() { return null; },
    \\      [Symbol.dispose]: function() {},
    \\    };
    \\    globalThis.__home_active_server = server;
    \\    return server;
    \\  };
    \\})();
;

fn evalBool(allocator: std.mem.Allocator, ctx: *JSContextRef, source: []const u8) !bool {
    const value = (try evaluate.evaluateUtf8(allocator, ctx, source, "home:serve-probe", 1, null)) orelse
        return error.JSEvaluateReturnedNull;
    return extern_fns.JSValueToBoolean(ctx, value);
}

fn installRealm(allocator: std.mem.Allocator, ctx: *JSContextRef, global: *JSGlobalObject) void {
    @import("web_globals.zig").install(allocator, ctx, global);
    @import("process.zig").install(allocator, ctx, global, &[_][]const u8{"home"});
    @import("timers_global.zig").install(allocator, ctx, global);
    @import("misc_globals.zig").install(allocator, ctx, global);
    @import("url_global.zig").install(allocator, ctx, global);
    @import("webcore_globals.zig").install(allocator, ctx, global);
    @import("bun_global.zig").install(allocator, ctx, global);
    @import("peek_global.zig").install(allocator, ctx, global);
    install(allocator, ctx, global);
}

test "Bun.serve binds + returns a non-blocking server object; request round-trips in-process" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealm(std.testing.allocator, ctx, engine.currentGlobalObject());

    // Bun.serve returns immediately (no blocking); the server object exposes
    // port/url/stop. Then exercise the request pipeline (parse -> fetch ->
    // serialize) in-process without going through a real socket.
    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function() {" ++
        "  var server = Bun.serve({ port: 0, fetch: function(req) {" ++
        "    if (req.method !== 'GET' || new URL(req.url).pathname !== '/hi') return new Response('bad', { status: 400 });" ++
        "    return new Response('hello world', { headers: { 'content-type': 'text/plain' } });" ++
        "  } });" ++
        "  if (typeof server.port !== 'number' || server.port <= 0) return false;" ++
        "  if (typeof server.stop !== 'function' || !server.url) return false;" ++
        "  globalThis.__home_active_server = server;" ++
        "  globalThis.__home_req = new TextEncoder().encode('GET /hi HTTP/1.1\\r\\nHost: localhost\\r\\n\\r\\n');" ++
        "  globalThis.__home_serve_dispatch();" ++
        "  globalThis.__home_serve_finish();" ++
        "  var text = new TextDecoder().decode(globalThis.__home_resp);" ++
        "  if (text.indexOf('HTTP/1.1 200 OK') !== 0) return false;" ++
        "  if (text.indexOf('content-type: text/plain') < 0) return false;" ++
        "  if (text.indexOf('Content-Length: 11') < 0) return false;" ++
        "  return text.indexOf('\\r\\n\\r\\nhello world') > 0; })()"));
}

test "Bun.serve fetch handler may be async (resolved via the same peek path)" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealm(std.testing.allocator, ctx, engine.currentGlobalObject());

    _ = try evaluate.evaluateUtf8(std.testing.allocator, ctx,
        "var server = Bun.serve({ port: 0, fetch: function(req) { return Promise.resolve(new Response('async-body')); } });" ++
        "globalThis.__home_active_server = server;" ++
        "globalThis.__home_req = new TextEncoder().encode('GET / HTTP/1.1\\r\\nHost: x\\r\\n\\r\\n');" ++
        "globalThis.__home_serve_dispatch();",
        "home:serve-async-setup", 1, null);
    timers.drain(ctx);
    _ = try evaluate.evaluateUtf8(std.testing.allocator, ctx, "globalThis.__home_serve_finish();", "home:serve-async-finish", 1, null);
    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "new TextDecoder().decode(globalThis.__home_resp).indexOf('async-body') > 0"));
}
