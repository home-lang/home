// Native `Bun.listen` / `Bun.connect` — TCP sockets for the eval/run realm.
//
// Like Bun.serve, sockets bind/connect immediately (non-blocking from the
// script) and the process then stays alive via a post-script `poll()` event
// loop (`runLoop`, called by main.zig). The loop multiplexes the listen
// socket(s) and all live connections, dispatching open/data/close to the JS
// `socket` handlers; the JS socket object's `.write()`/`.end()` call back into
// native send/close.
//
// SCOPE (v1): plain TCP (no TLS), IPv4, the open/data/close/error/drain handler
// shape, and `socket.write`/`.end`/`.data`. Unix sockets, TLS, and backpressure
// pause/resume are out of scope. comptime-gated on `enable_jsc`.

const std = @import("std");
const build_options = @import("build_options");
const evaluate = @import("evaluate.zig");
const callback = @import("callback.zig");
const extern_fns = @import("extern_fns.zig");
const opaques = @import("opaques.zig");

const c = std.c;
const timers = @import("timers_global.zig");
const JSValue = opaques.JSValue;
const JSContextRef = opaques.JSContextRef;
const JSObject = opaques.JSObject;
const JSGlobalObject = opaques.JSGlobalObject;

extern "c" fn socket(domain: c_uint, sock_type: c_uint, protocol: c_uint) c_int;
extern "c" fn connect(fd: c_int, addr: *const anyopaque, len: c.socklen_t) c_int;
extern "c" fn sendto(fd: c_int, buf: *const anyopaque, len: usize, flags: u32, dest: ?*const anyopaque, addrlen: c.socklen_t) isize;
extern "c" fn recvfrom(fd: c_int, buf: *anyopaque, len: usize, flags: u32, src: ?*anyopaque, addrlen: ?*c.socklen_t) isize;

const pollfd = extern struct { fd: c_int, events: c_short, revents: c_short };
extern "c" fn poll(fds: [*]pollfd, nfds: c_uint, timeout: c_int) c_int;
const POLLIN: c_short = 0x0001;

const MAX_FDS = 256;

const FdKind = enum { listener, connection, udp, http, ws };

/// Register an HTTP listener fd (from Bun.serve) into the unified poll loop so
/// HTTP + WebSocket + raw TCP/UDP are all multiplexed by one event loop.
pub fn addHttpListener(fd: c_int) void {
    addEntry(fd, .http);
}

/// Read a full HTTP/1.1 request (headers + Content-Length body) from `fd`.
fn readHttpRequest(allocator: std.mem.Allocator, fd: c_int) ?[]u8 {
    const cap: usize = 1 << 20;
    const buf = allocator.alloc(u8, cap) catch return null;
    defer allocator.free(buf);
    var total: usize = 0;
    while (total < cap) {
        const n = c.recv(fd, buf.ptr + total, cap - total, 0);
        if (n <= 0) break;
        total += @intCast(n);
        if (httpRequestComplete(buf[0..total])) break;
    }
    if (total == 0) return null;
    return allocator.dupe(u8, buf[0..total]) catch null;
}

fn httpRequestComplete(data: []const u8) bool {
    const sep = std.mem.indexOf(u8, data, "\r\n\r\n") orelse return false;
    const header_end = sep + 4;
    var content_len: usize = 0;
    var line_it = std.mem.splitSequence(u8, data[0..sep], "\r\n");
    while (line_it.next()) |line| {
        if (line.len > 15 and std.ascii.eqlIgnoreCase(line[0..15], "content-length:")) {
            content_len = std.fmt.parseInt(usize, std.mem.trim(u8, line[15..], " \t"), 10) catch 0;
        }
    }
    return data.len >= header_end + content_len;
}

fn globalIsTrue(ctx: *JSContextRef, name: [:0]const u8) bool {
    const global = extern_fns.JSContextGetGlobalObject(ctx) orelse return false;
    const js = extern_fns.JSStringCreateWithUTF8CString(name.ptr) orelse return false;
    defer extern_fns.JSStringRelease(js);
    const v = extern_fns.JSObjectGetProperty(ctx, global, js, null) orelse return false;
    return extern_fns.JSValueToBoolean(ctx, v);
}

fn writeAll(fd: c_int, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.send(fd, bytes.ptr + off, bytes.len - off, 0);
        if (n <= 0) break;
        off += @intCast(n);
    }
}

fn writeGlobalBytes(ctx: *JSContextRef, global: *JSObject, name: [:0]const u8, fd: c_int) void {
    const js = extern_fns.JSStringCreateWithUTF8CString(name.ptr) orelse return;
    defer extern_fns.JSStringRelease(js);
    const v = extern_fns.JSObjectGetProperty(ctx, global, js, null) orelse return;
    if (extern_fns.JSValueGetTypedArrayType(ctx, v, null) == .kJSTypedArrayTypeNone) return;
    const obj = extern_fns.JSValueToObject(ctx, v, null) orelse return;
    const len = extern_fns.JSObjectGetTypedArrayByteLength(ctx, obj, null);
    const ptr = extern_fns.JSObjectGetTypedArrayBytesPtr(ctx, obj, null);
    if (len > 0 and ptr != null) writeAll(fd, @as([*]const u8, @ptrCast(ptr.?))[0..len]);
}
const Entry = struct { fd: c_int = -1, kind: FdKind = .connection, used: bool = false };

var g_entries: [MAX_FDS]Entry = @splat(.{});
var g_active: bool = false;

fn addEntry(fd: c_int, kind: FdKind) void {
    for (&g_entries) |*e| {
        if (!e.used) {
            e.* = .{ .fd = fd, .kind = kind, .used = true };
            g_active = true;
            return;
        }
    }
}

fn removeEntry(fd: c_int) void {
    for (&g_entries) |*e| {
        if (e.used and e.fd == fd) {
            e.used = false;
            e.fd = -1;
            return;
        }
    }
}

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
    return @bitCast(parts);
}

fn readHostArg(ctx: *JSContextRef, v: ?*JSValue, buf: []u8, default: []const u8) []const u8 {
    if (v) |hv| {
        const js = extern_fns.JSValueToStringCopy(ctx, hv, null);
        if (js) |s| {
            defer extern_fns.JSStringRelease(s);
            const n = extern_fns.JSStringGetUTF8CString(s, buf.ptr, buf.len);
            if (n > 1) return buf[0 .. n - 1];
        }
    }
    return default;
}

fn setSocketReuse(fd: c_int) void {
    const one: c_int = 1;
    _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.REUSEADDR, &one, @sizeOf(c_int));
    if (@hasDecl(c.SO, "REUSEPORT")) {
        _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.REUSEPORT, &one, @sizeOf(c_int));
    }
}

/// `__home_tcp_listen(host, port)` -> fd or -1.
fn listenNative(ctx: ?*JSContextRef, function: ?*JSObject, this_object: ?*JSObject, argc: usize, argv: [*c]const ?*JSValue, exception: extern_fns.ExceptionRef) callconv(.c) ?*JSValue {
    _ = function;
    _ = this_object;
    _ = exception;
    const cx = ctx orelse return null;
    if (argc < 2) return extern_fns.JSValueMakeNumber(cx, -1);
    var host_buf: [256]u8 = undefined;
    const host = readHostArg(cx, argv[0], &host_buf, "0.0.0.0");
    const port: u16 = @intFromFloat(@max(0, @min(65535, extern_fns.JSValueToNumber(cx, argv[1].?, null))));

    const fd = socket(c.AF.INET, c.SOCK.STREAM, 0);
    if (fd < 0) return extern_fns.JSValueMakeNumber(cx, -1);
    setSocketReuse(fd);
    var addr = c.sockaddr.in{ .port = std.mem.nativeToBig(u16, port), .addr = parseHostV4(host) };
    if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.in)) != 0 or c.listen(fd, 128) != 0) {
        _ = c.close(fd);
        return extern_fns.JSValueMakeNumber(cx, -1);
    }
    addEntry(fd, .listener);
    return extern_fns.JSValueMakeNumber(cx, @floatFromInt(fd));
}

/// `__home_tcp_connect(host, port)` -> fd or -1 (blocking connect).
fn connectNative(ctx: ?*JSContextRef, function: ?*JSObject, this_object: ?*JSObject, argc: usize, argv: [*c]const ?*JSValue, exception: extern_fns.ExceptionRef) callconv(.c) ?*JSValue {
    _ = function;
    _ = this_object;
    _ = exception;
    const cx = ctx orelse return null;
    if (argc < 2) return extern_fns.JSValueMakeNumber(cx, -1);
    var host_buf: [256]u8 = undefined;
    const host = readHostArg(cx, argv[0], &host_buf, "127.0.0.1");
    const port: u16 = @intFromFloat(@max(0, @min(65535, extern_fns.JSValueToNumber(cx, argv[1].?, null))));

    const fd = socket(c.AF.INET, c.SOCK.STREAM, 0);
    if (fd < 0) return extern_fns.JSValueMakeNumber(cx, -1);
    var addr = c.sockaddr.in{ .port = std.mem.nativeToBig(u16, port), .addr = parseHostV4(host) };
    if (connect(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.in)) != 0) {
        _ = c.close(fd);
        return extern_fns.JSValueMakeNumber(cx, -1);
    }
    addEntry(fd, .connection);
    return extern_fns.JSValueMakeNumber(cx, @floatFromInt(fd));
}

/// `__home_udp_bind(host, port)` -> fd or -1 (SOCK.DGRAM).
fn udpBindNative(ctx: ?*JSContextRef, function: ?*JSObject, this_object: ?*JSObject, argc: usize, argv: [*c]const ?*JSValue, exception: extern_fns.ExceptionRef) callconv(.c) ?*JSValue {
    _ = function;
    _ = this_object;
    _ = exception;
    const cx = ctx orelse return null;
    if (argc < 2) return extern_fns.JSValueMakeNumber(cx, -1);
    var host_buf: [256]u8 = undefined;
    const host = readHostArg(cx, argv[0], &host_buf, "0.0.0.0");
    const port: u16 = @intFromFloat(@max(0, @min(65535, extern_fns.JSValueToNumber(cx, argv[1].?, null))));
    const fd = socket(c.AF.INET, c.SOCK.DGRAM, 0);
    if (fd < 0) return extern_fns.JSValueMakeNumber(cx, -1);
    setSocketReuse(fd);
    var addr = c.sockaddr.in{ .port = std.mem.nativeToBig(u16, port), .addr = parseHostV4(host) };
    if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.in)) != 0) {
        _ = c.close(fd);
        return extern_fns.JSValueMakeNumber(cx, -1);
    }
    addEntry(fd, .udp);
    return extern_fns.JSValueMakeNumber(cx, @floatFromInt(fd));
}

/// `__home_udp_port(fd)` -> bound local UDP port or 0.
fn udpPortNative(ctx: ?*JSContextRef, function: ?*JSObject, this_object: ?*JSObject, argc: usize, argv: [*c]const ?*JSValue, exception: extern_fns.ExceptionRef) callconv(.c) ?*JSValue {
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

/// `__home_udp_send(fd, bytes, host, port)` -> bytes sent, or -1.
fn udpSendNative(ctx: ?*JSContextRef, function: ?*JSObject, this_object: ?*JSObject, argc: usize, argv: [*c]const ?*JSValue, exception: extern_fns.ExceptionRef) callconv(.c) ?*JSValue {
    _ = function;
    _ = this_object;
    _ = exception;
    const cx = ctx orelse return null;
    if (argc < 4) return extern_fns.JSValueMakeNumber(cx, -1);
    const fd: c_int = @intFromFloat(extern_fns.JSValueToNumber(cx, argv[0].?, null));
    const data_v = argv[1] orelse return extern_fns.JSValueMakeNumber(cx, -1);
    var host_buf: [256]u8 = undefined;
    const host = readHostArg(cx, argv[2], &host_buf, "127.0.0.1");
    const port: u16 = @intFromFloat(@max(0, @min(65535, extern_fns.JSValueToNumber(cx, argv[3].?, null))));
    if (extern_fns.JSValueGetTypedArrayType(cx, data_v, null) == .kJSTypedArrayTypeNone) return extern_fns.JSValueMakeNumber(cx, -1);
    const obj = extern_fns.JSValueToObject(cx, data_v, null) orelse return extern_fns.JSValueMakeNumber(cx, -1);
    const len = extern_fns.JSObjectGetTypedArrayByteLength(cx, obj, null);
    const ptr = extern_fns.JSObjectGetTypedArrayBytesPtr(cx, obj, null);
    const bytes: []const u8 = if (len > 0 and ptr != null) @as([*]const u8, @ptrCast(ptr.?))[0..len] else "";
    var addr = c.sockaddr.in{ .port = std.mem.nativeToBig(u16, port), .addr = parseHostV4(host) };
    const n = sendto(fd, bytes.ptr, bytes.len, 0, @ptrCast(&addr), @sizeOf(c.sockaddr.in));
    return extern_fns.JSValueMakeNumber(cx, @floatFromInt(n));
}

/// `__home_tcp_write(fd, bytes)` -> bytes written, or -1.
fn writeNative(ctx: ?*JSContextRef, function: ?*JSObject, this_object: ?*JSObject, argc: usize, argv: [*c]const ?*JSValue, exception: extern_fns.ExceptionRef) callconv(.c) ?*JSValue {
    _ = function;
    _ = this_object;
    _ = exception;
    const cx = ctx orelse return null;
    if (argc < 2) return extern_fns.JSValueMakeNumber(cx, -1);
    const fd: c_int = @intFromFloat(extern_fns.JSValueToNumber(cx, argv[0].?, null));
    const data_v = argv[1] orelse return extern_fns.JSValueMakeNumber(cx, -1);
    if (extern_fns.JSValueGetTypedArrayType(cx, data_v, null) == .kJSTypedArrayTypeNone) return extern_fns.JSValueMakeNumber(cx, -1);
    const obj = extern_fns.JSValueToObject(cx, data_v, null) orelse return extern_fns.JSValueMakeNumber(cx, -1);
    const len = extern_fns.JSObjectGetTypedArrayByteLength(cx, obj, null);
    const ptr = extern_fns.JSObjectGetTypedArrayBytesPtr(cx, obj, null);
    if (len == 0 or ptr == null) return extern_fns.JSValueMakeNumber(cx, 0);
    const n = c.send(fd, @as([*]const u8, @ptrCast(ptr.?)), len, 0);
    return extern_fns.JSValueMakeNumber(cx, @floatFromInt(n));
}

/// `__home_tcp_close(fd)`.
fn closeNative(ctx: ?*JSContextRef, function: ?*JSObject, this_object: ?*JSObject, argc: usize, argv: [*c]const ?*JSValue, exception: extern_fns.ExceptionRef) callconv(.c) ?*JSValue {
    _ = function;
    _ = this_object;
    _ = exception;
    const cx = ctx orelse return null;
    if (argc >= 1) {
        const fd: c_int = @intFromFloat(extern_fns.JSValueToNumber(cx, argv[0].?, null));
        removeEntry(fd);
        _ = c.close(fd);
    }
    return extern_fns.JSValueMakeUndefined(cx);
}

pub fn install(allocator: std.mem.Allocator, ctx: *JSContextRef, global: *JSGlobalObject) void {
    if (comptime !build_options.enable_jsc) return;
    callback.registerCallback(ctx, global, "__home_tcp_listen", listenNative);
    callback.registerCallback(ctx, global, "__home_tcp_connect", connectNative);
    callback.registerCallback(ctx, global, "__home_tcp_write", writeNative);
    callback.registerCallback(ctx, global, "__home_tcp_close", closeNative);
    callback.registerCallback(ctx, global, "__home_udp_bind", udpBindNative);
    callback.registerCallback(ctx, global, "__home_udp_port", udpPortNative);
    callback.registerCallback(ctx, global, "__home_udp_send", udpSendNative);
    const result = evaluate.evaluateUtf8Detailed(allocator, ctx, install_glue, "home:bun-socket-install", 1) catch return;
    result.deinit(allocator);
}

pub fn hasSockets() bool {
    return g_active;
}

fn setGlobalBytes(ctx: *JSContextRef, global: *JSObject, name: [:0]const u8, bytes: []const u8) void {
    const array = extern_fns.JSObjectMakeTypedArray(ctx, .kJSTypedArrayTypeUint8Array, bytes.len, null) orelse return;
    if (bytes.len > 0) {
        if (extern_fns.JSObjectGetTypedArrayBytesPtr(ctx, array, null)) |ptr| {
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..bytes.len], bytes);
        }
    }
    const js = extern_fns.JSStringCreateWithUTF8CString(name.ptr) orelse return;
    defer extern_fns.JSStringRelease(js);
    extern_fns.JSObjectSetProperty(ctx, global, js, @ptrCast(array), 0, null);
}

fn setGlobalString(ctx: *JSContextRef, global: *JSObject, name: [:0]const u8, value: [:0]const u8) void {
    const sv = extern_fns.JSStringCreateWithUTF8CString(value.ptr) orelse return;
    defer extern_fns.JSStringRelease(sv);
    const jsval = extern_fns.JSValueMakeString(ctx, sv);
    const js = extern_fns.JSStringCreateWithUTF8CString(name.ptr) orelse return;
    defer extern_fns.JSStringRelease(js);
    extern_fns.JSObjectSetProperty(ctx, global, js, jsval, 0, null);
}

fn setGlobalNumber(ctx: *JSContextRef, global: *JSObject, name: [:0]const u8, value: f64) void {
    const js = extern_fns.JSStringCreateWithUTF8CString(name.ptr) orelse return;
    defer extern_fns.JSStringRelease(js);
    extern_fns.JSObjectSetProperty(ctx, global, js, extern_fns.JSValueMakeNumber(ctx, value), 0, null);
}

fn dispatch(allocator: std.mem.Allocator, ctx: *JSContextRef, src: []const u8) void {
    const r = evaluate.evaluateUtf8Detailed(allocator, ctx, src, "home:socket-dispatch", 1) catch return;
    r.deinit(allocator);
}

/// The post-script poll loop. Runs while any listener/connection is live.
pub fn runLoop(allocator: std.mem.Allocator, ctx: *JSContextRef) void {
    if (comptime !build_options.enable_jsc) return;
    if (!g_active) return;
    const global = extern_fns.JSContextGetGlobalObject(ctx) orelse return;
    var fds: [MAX_FDS]pollfd = undefined;
    var recv_buf: [64 * 1024]u8 = undefined;
    var dispatch_buf: [128]u8 = undefined;

    while (true) {
        var n: usize = 0;
        for (&g_entries) |*e| {
            if (e.used) {
                fds[n] = .{ .fd = e.fd, .events = POLLIN, .revents = 0 };
                n += 1;
            }
        }
        if (n == 0) break;
        const pr = poll(&fds, @intCast(n), -1);
        if (pr < 0) {
            if (std.posix.errno(@as(isize, pr)) == .INTR) continue;
            break;
        }
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (fds[i].revents & POLLIN == 0) continue;
            const fd = fds[i].fd;
            const kind = entryKind(fd) orelse continue;
            if (kind == .http) {
                const client = c.accept(fd, null, null);
                if (client < 0) continue;
                const req = readHttpRequest(allocator, client) orelse {
                    _ = c.close(client);
                    continue;
                };
                defer allocator.free(req);
                setGlobalBytes(ctx, global, "__home_req", req);
                setGlobalNumber(ctx, global, "__home_serve_fd", @floatFromInt(client));
                dispatch(allocator, ctx, "globalThis.__home_serve_dispatch();");
                timers.drain(ctx);
                dispatch(allocator, ctx, "globalThis.__home_serve_finish();");
                writeGlobalBytes(ctx, global, "__home_resp", client);
                if (globalIsTrue(ctx, "__home_upgraded")) {
                    addEntry(client, .ws);
                    const src = std.fmt.bufPrint(&dispatch_buf, "globalThis.__home_ws_event('open',{d});", .{client}) catch continue;
                    dispatch(allocator, ctx, src);
                } else {
                    _ = c.close(client);
                }
            } else if (kind == .ws) {
                const rn = c.recv(fd, &recv_buf, recv_buf.len, 0);
                if (rn <= 0) {
                    removeEntry(fd);
                    _ = c.close(fd);
                    const src = std.fmt.bufPrint(&dispatch_buf, "globalThis.__home_ws_event('close',{d});", .{fd}) catch continue;
                    dispatch(allocator, ctx, src);
                } else {
                    setGlobalBytes(ctx, global, "__home_sock_data", recv_buf[0..@intCast(rn)]);
                    const src = std.fmt.bufPrint(&dispatch_buf, "globalThis.__home_ws_data({d});", .{fd}) catch continue;
                    dispatch(allocator, ctx, src);
                }
            } else if (kind == .udp) {
                var from: c.sockaddr.in = undefined;
                var fromlen: c.socklen_t = @sizeOf(c.sockaddr.in);
                const rn = recvfrom(fd, &recv_buf, recv_buf.len, 0, @ptrCast(&from), &fromlen);
                if (rn <= 0) continue;
                const b: [4]u8 = @bitCast(from.addr);
                var ip_buf: [24]u8 = undefined;
                const ip = std.fmt.bufPrintSentinel(&ip_buf, "{d}.{d}.{d}.{d}", .{ b[0], b[1], b[2], b[3] }, 0) catch "0.0.0.0";
                setGlobalBytes(ctx, global, "__home_sock_data", recv_buf[0..@intCast(rn)]);
                setGlobalString(ctx, global, "__home_sock_addr", ip);
                setGlobalNumber(ctx, global, "__home_sock_port", @floatFromInt(std.mem.bigToNative(u16, from.port)));
                const src = std.fmt.bufPrint(&dispatch_buf, "globalThis.__home_socket_event('message',{d},0);", .{fd}) catch continue;
                dispatch(allocator, ctx, src);
            } else if (kind == .listener) {
                const client = c.accept(fd, null, null);
                if (client < 0) continue;
                addEntry(client, .connection);
                const src = std.fmt.bufPrint(&dispatch_buf, "globalThis.__home_socket_event('open',{d},{d});", .{ client, fd }) catch continue;
                dispatch(allocator, ctx, src);
            } else {
                const rn = c.recv(fd, &recv_buf, recv_buf.len, 0);
                if (rn <= 0) {
                    removeEntry(fd);
                    _ = c.close(fd);
                    const src = std.fmt.bufPrint(&dispatch_buf, "globalThis.__home_socket_event('close',{d},0);", .{fd}) catch continue;
                    dispatch(allocator, ctx, src);
                } else {
                    setGlobalBytes(ctx, global, "__home_sock_data", recv_buf[0..@intCast(rn)]);
                    const src = std.fmt.bufPrint(&dispatch_buf, "globalThis.__home_socket_event('data',{d},0);", .{fd}) catch continue;
                    dispatch(allocator, ctx, src);
                }
            }
        }
    }
}

fn entryKind(fd: c_int) ?FdKind {
    for (&g_entries) |*e| {
        if (e.used and e.fd == fd) return e.kind;
    }
    return null;
}

const install_glue =
    \\(function() {
    \\  var B = globalThis.Bun;
    \\  if (!B) return;
    \\  var listenFn = globalThis.__home_tcp_listen;
    \\  var connectFn = globalThis.__home_tcp_connect;
    \\  var writeFn = globalThis.__home_tcp_write;
    \\  var closeFn = globalThis.__home_tcp_close;
    \\  var udpBindFn = globalThis.__home_udp_bind;
    \\  var udpPortFn = globalThis.__home_udp_port;
    \\  var udpSendFn = globalThis.__home_udp_send;
    \\  // fd -> { handlers, isServer, serverFd, socketObj }
    \\  var registry = {};
    \\  // serverFd -> handlers
    \\  var servers = {};
    \\  // udp fd -> { kind: 'dgram'|'bun', target }
    \\  var udpReg = {};
    \\
    \\  function toBytes(d) {
    \\    if (typeof d === "string") return new TextEncoder().encode(d);
    \\    if (d instanceof Uint8Array) return d;
    \\    if (ArrayBuffer.isView(d)) return new Uint8Array(d.buffer, d.byteOffset, d.byteLength);
    \\    if (d instanceof ArrayBuffer) return new Uint8Array(d);
    \\    return new TextEncoder().encode(String(d));
    \\  }
    \\  function makeSocket(fd) {
    \\    return {
    \\      _fd: fd, data: undefined, readyState: "open",
    \\      write: function(d) { var b = toBytes(d); var n = writeFn(fd, b); return n < 0 ? 0 : n; },
    \\      end: function(d) { if (d !== undefined) this.write(d); this.readyState = "closed"; closeFn(fd); },
    \\      flush: function() {}, ref: function() {}, unref: function() {}, shutdown: function() {},
    \\      timeout: function() {},
    \\      get remoteAddress() { return "127.0.0.1"; },
    \\    };
    \\  }
    \\
    \\  globalThis.__home_socket_event = function(type, fd, serverFd) {
    \\    if (type === "open") {
    \\      var handlers = servers[serverFd];
    \\      if (!handlers) return;
    \\      var sock = makeSocket(fd);
    \\      registry[fd] = { handlers: handlers, socketObj: sock };
    \\      if (typeof handlers.open === "function") { try { handlers.open(sock); } catch (e) { if (handlers.error) handlers.error(sock, e); } }
    \\    } else if (type === "data") {
    \\      var entry = registry[fd];
    \\      if (!entry) return;
    \\      var bytes = globalThis.__home_sock_data;
    \\      if (typeof entry.handlers.data === "function") { try { entry.handlers.data(entry.socketObj, Buffer.from(bytes)); } catch (e) { if (entry.handlers.error) entry.handlers.error(entry.socketObj, e); } }
    \\    } else if (type === "close") {
    \\      var entry2 = registry[fd];
    \\      if (!entry2) return;
    \\      entry2.socketObj.readyState = "closed";
    \\      if (typeof entry2.handlers.close === "function") { try { entry2.handlers.close(entry2.socketObj); } catch (e) {} }
    \\      delete registry[fd];
    \\    } else if (type === "message") {
    \\      var u = udpReg[fd];
    \\      if (!u) return;
    \\      var bytes = globalThis.__home_sock_data;
    \\      var rinfo = { address: globalThis.__home_sock_addr, port: globalThis.__home_sock_port, family: "IPv4", size: bytes.length };
    \\      if (u.kind === "dgram") { try { u.target.emit("message", Buffer.from(bytes), rinfo); } catch (e) { try { u.target.emit("error", e); } catch (e2) {} } }
    \\      else { var h = u.target.handlers; if (typeof h.data === "function") { try { h.data(u.target.sock, Buffer.from(bytes), rinfo.port, rinfo.address); } catch (e) {} } }
    \\    }
    \\  };
    \\  function udpToBytes(d) { if (typeof d === "string") return new TextEncoder().encode(d); if (d instanceof Uint8Array) return d; if (ArrayBuffer.isView(d)) return new Uint8Array(d.buffer, d.byteOffset, d.byteLength); if (d instanceof ArrayBuffer) return new Uint8Array(d); return new TextEncoder().encode(String(d)); }
    \\  // node:dgram (udp4) backed by the native UDP socket + poll loop.
    \\  function createDgram(typeArg, cbArg) {
    \\    var type = (typeof typeArg === "object" && typeArg) ? (typeArg.type || "udp4") : (typeArg || "udp4");
    \\    var cb = (typeof typeArg === "function") ? typeArg : cbArg;
    \\    var EventEmitter = globalThis.require("node:events").EventEmitter || globalThis.require("node:events");
    \\    var sock = new EventEmitter();
    \\    sock.type = type; var fd = -1; var boundPort = 0; var boundAddress = "0.0.0.0";
    \\    function finishBind(nextFd, addressForSocket) {
    \\      if (nextFd < 0) return false;
    \\      fd = nextFd; sock._fd = fd; udpReg[fd] = { kind: "dgram", target: sock };
    \\      boundPort = udpPortFn(fd) | 0;
    \\      boundAddress = addressForSocket || "0.0.0.0";
    \\      return true;
    \\    }
    \\    function ensureBound() {
    \\      if (fd >= 0) return true;
    \\      return finishBind(udpBindFn("0.0.0.0", 0), "0.0.0.0");
    \\    }
    \\    sock.bind = function(port, address, bindCb) {
    \\      if (typeof port === "function") { bindCb = port; port = 0; }
    \\      if (typeof address === "function") { bindCb = address; address = undefined; }
    \\      if (port && typeof port === "object") { address = port.address; port = port.port; }
    \\      if (!finishBind(udpBindFn(address || "0.0.0.0", port | 0), address || "0.0.0.0")) { var self0 = sock; Promise.resolve().then(function() { self0.emit("error", Object.assign(new Error("bind failed"), { code: "EADDRINUSE" })); }); return sock; }
    \\      Promise.resolve().then(function() { sock.emit("listening"); if (bindCb) bindCb(); });
    \\      return sock;
    \\    };
    \\    sock.send = function(msg, offset, length, port, address, sendCb) {
    \\      // send(msg, port, address, cb) | send(msg, offset, length, port, address, cb)
    \\      if (typeof offset !== "number") { sendCb = port; address = length; port = offset; offset = 0; length = undefined; }
    \\      if (typeof port === "function") { sendCb = port; port = undefined; }
    \\      if (typeof address === "function") { sendCb = address; address = undefined; }
    \\      if (!ensureBound()) { if (typeof sendCb === "function") Promise.resolve().then(function() { sendCb(new Error("bind failed"), 0); }); return; }
    \\      var bytes = udpToBytes(msg);
    \\      var n = udpSendFn(fd, bytes, address || "127.0.0.1", port | 0);
    \\      if (typeof sendCb === "function") Promise.resolve().then(function() { sendCb(n < 0 ? new Error("send failed") : null, n < 0 ? 0 : n); });
    \\    };
    \\    sock.address = function() { return { address: boundAddress, port: boundPort, family: "IPv4" }; };
    \\    sock.close = function(closeCb) { if (fd >= 0) { closeFn(fd); delete udpReg[fd]; fd = -1; boundPort = 0; } var self1 = sock; Promise.resolve().then(function() { self1.emit("close"); if (closeCb) closeCb(); }); return sock; };
    \\    sock.ref = function() { return sock; }; sock.unref = function() { return sock; };
    \\    sock.setBroadcast = function() {}; sock.setTTL = function() {}; sock.setMulticastTTL = function() {};
    \\    sock.addMembership = function() {}; sock.dropMembership = function() {};
    \\    if (typeof cb === "function") sock.on("message", cb);
    \\    return sock;
    \\  }
    \\  var dgramModule = { createSocket: createDgram, Socket: createDgram };
    \\  // node:net — Server/Socket (EventEmitter) backed by Bun.listen/connect.
    \\  function netEmitter() { var EE = globalThis.require("node:events").EventEmitter || globalThis.require("node:events"); return new EE(); }
    \\  function wrapNetSocket(bunSock) {
    \\    var s = netEmitter();
    \\    s._bun = bunSock; s._encoding = null;
    \\    s.write = function(data, enc, cb) { if (typeof enc === "function") cb = enc; var n = bunSock.write(data); if (typeof cb === "function") Promise.resolve().then(cb); return n >= 0; };
    \\    s.end = function(data, enc, cb) { if (typeof data === "function") cb = data; else if (data !== undefined && data !== null) bunSock.write(data); bunSock.end(); s.emit("end"); if (typeof cb === "function") cb(); };
    \\    s.destroy = function() { bunSock.end(); s.emit("close"); };
    \\    s.setEncoding = function(e) { s._encoding = e; return s; };
    \\    s.setKeepAlive = function() { return s; }; s.setNoDelay = function() { return s; }; s.setTimeout = function() { return s; };
    \\    s.pause = function() { return s; }; s.resume = function() { return s; }; s.ref = function() { return s; }; s.unref = function() { return s; };
    \\    s.address = function() { return { address: bunSock.remoteAddress, port: 0, family: "IPv4" }; };
    \\    Object.defineProperty(s, "remoteAddress", { get: function() { return bunSock.remoteAddress; }, configurable: true });
    \\    return s;
    \\  }
    \\  function netDeliver(s, data) { s.emit("data", s._encoding ? data.toString(s._encoding) : data); }
    \\  function netCreateServer(opts, connListener) {
    \\    if (typeof opts === "function") { connListener = opts; opts = {}; }
    \\    var server = netEmitter();
    \\    if (typeof connListener === "function") server.on("connection", connListener);
    \\    server._bun = null; server._port = 0;
    \\    server.listen = function(port, host, cb) {
    \\      if (port && typeof port === "object") { cb = host; host = port.host || port.hostname; port = port.port; }
    \\      if (typeof host === "function") { cb = host; host = undefined; }
    \\      server._bun = B.listen({ hostname: host || "0.0.0.0", port: port | 0, socket: {
    \\        open: function(bs) { var ns = wrapNetSocket(bs); bs._netSock = ns; server.emit("connection", ns); ns.emit("connect"); },
    \\        data: function(bs, data) { if (bs._netSock) netDeliver(bs._netSock, data); },
    \\        close: function(bs) { if (bs._netSock) bs._netSock.emit("close"); },
    \\      } });
    \\      server._port = server._bun.port;
    \\      Promise.resolve().then(function() { server.emit("listening"); if (typeof cb === "function") cb(); });
    \\      return server;
    \\    };
    \\    server.address = function() { return { port: server._port, address: "0.0.0.0", family: "IPv4" }; };
    \\    server.close = function(cb) { if (server._bun) server._bun.stop(); Promise.resolve().then(function() { server.emit("close"); if (typeof cb === "function") cb(); }); return server; };
    \\    server.ref = function() { return server; }; server.unref = function() { return server; };
    \\    return server;
    \\  }
    \\  function netConnect(port, host, cb) {
    \\    if (port && typeof port === "object") { cb = host; host = port.host || port.hostname; port = port.port; }
    \\    if (typeof host === "function") { cb = host; host = undefined; }
    \\    var s = netEmitter(); var pending = []; s._encoding = null; s._ready = false; s._bun = null;
    \\    s.write = function(data, enc, c2) { if (typeof enc === "function") c2 = enc; if (s._ready) s._bun.write(data); else pending.push(data); if (typeof c2 === "function") Promise.resolve().then(c2); return true; };
    \\    s.end = function(data) { if (data !== undefined && data !== null) s.write(data); if (s._ready) s._bun.end(); s.emit("end"); };
    \\    s.destroy = function() { if (s._ready) s._bun.end(); };
    \\    s.setEncoding = function(e) { s._encoding = e; return s; };
    \\    s.setKeepAlive = function() { return s; }; s.setNoDelay = function() { return s; }; s.setTimeout = function() { return s; };
    \\    s.pause = function() { return s; }; s.resume = function() { return s; }; s.ref = function() { return s; }; s.unref = function() { return s; };
    \\    B.connect({ hostname: host || "127.0.0.1", port: port | 0, socket: {
    \\      open: function(bs) { s._bun = bs; s._ready = true; for (var i = 0; i < pending.length; i++) bs.write(pending[i]); pending = []; },
    \\      data: function(bs, data) { netDeliver(s, data); },
    \\      close: function(bs) { s.emit("close"); },
    \\    } }).then(function() { s.emit("connect"); if (typeof cb === "function") cb(); }, function(err) { s.emit("error", err); });
    \\    return s;
    \\  }
    \\  var netModule = { createServer: netCreateServer, connect: netConnect, createConnection: netConnect, Socket: wrapNetSocket, Server: netCreateServer, isIP: function(s) { return /^\d+\.\d+\.\d+\.\d+$/.test(String(s)) ? 4 : 0; }, isIPv4: function(s) { return /^\d+\.\d+\.\d+\.\d+$/.test(String(s)); }, isIPv6: function() { return false; } };
    \\  // Extend the realm's require() to serve node:dgram + the real node:net
    \\  // (socket_global loads after node_modules, so wrap the existing require).
    \\  if (typeof globalThis.require === "function") {
    \\    var prevRequire = globalThis.require;
    \\    var wrapped = function(spec) { var n = String(spec); n = n.indexOf("node:") === 0 ? n.slice(5) : n; if (n === "dgram") return dgramModule; if (n === "net") return netModule; return prevRequire(spec); };
    \\    wrapped.resolve = prevRequire.resolve || function(s) { return String(s); };
    \\    globalThis.require = wrapped;
    \\  }
    \\  // WebSocket client global — ws:// over Bun.connect with masked frames.
    \\  function wsClientFrame(opcode, payload) {
    \\    var mask = [(Math.random() * 256) | 0, (Math.random() * 256) | 0, (Math.random() * 256) | 0, (Math.random() * 256) | 0];
    \\    var len = payload.length, header;
    \\    if (len < 126) header = [0x80 | opcode, 0x80 | len];
    \\    else if (len < 65536) header = [0x80 | opcode, 0x80 | 126, (len >> 8) & 0xff, len & 0xff];
    \\    else header = [0x80 | opcode, 0x80 | 127, 0, 0, 0, 0, (len >>> 24) & 0xff, (len >> 16) & 0xff, (len >> 8) & 0xff, len & 0xff];
    \\    var frame = new Uint8Array(header.length + 4 + len);
    \\    frame.set(header, 0); frame.set(mask, header.length);
    \\    for (var i = 0; i < len; i++) frame[header.length + 4 + i] = payload[i] ^ mask[i % 4];
    \\    return frame;
    \\  }
    \\  function WebSocket(url, protocols) {
    \\    var self = this;
    \\    this.url = String(url); this.readyState = 0; this.binaryType = "blob"; this.protocol = "";
    \\    this.bufferedAmount = 0; this.extensions = "";
    \\    var listeners = { open: [], message: [], close: [], error: [] };
    \\    this.addEventListener = function(t, fn) { if (listeners[t]) listeners[t].push(fn); };
    \\    this.removeEventListener = function(t, fn) { if (listeners[t]) listeners[t] = listeners[t].filter(function(f) { return f !== fn; }); };
    \\    function fire(t, ev) {
    \\      ev = ev || {}; ev.type = t; ev.target = self;
    \\      var on = self["on" + t]; if (typeof on === "function") { try { on.call(self, ev); } catch (e) {} }
    \\      listeners[t].forEach(function(fn) { try { fn.call(self, ev); } catch (e) {} });
    \\    }
    \\    var u = new globalThis.URL(this.url);
    \\    var port = u.port ? (u.port | 0) : (u.protocol === "wss:" ? 443 : 80);
    \\    var host = u.hostname, path = (u.pathname || "/") + (u.search || "");
    \\    var keyBytes = new Uint8Array(16); for (var ki = 0; ki < 16; ki++) keyBytes[ki] = (Math.random() * 256) | 0;
    \\    var key = btoa(String.fromCharCode.apply(null, keyBytes));
    \\    var handshakeDone = false, sock = null;
    \\    function onbytes(data) {
    \\      self._buf = self._buf || new Uint8Array(0);
    \\      var buf = new Uint8Array(self._buf.length + data.length); buf.set(self._buf, 0); buf.set(data, self._buf.length);
    \\      var off = 0;
    \\      while (buf.length - off >= 2) {
    \\        var opcode = buf[off] & 0x0f, len = buf[off + 1] & 0x7f, p = off + 2;
    \\        if (len === 126) { if (buf.length - off < 4) break; len = (buf[p] << 8) | buf[p + 1]; p += 2; }
    \\        else if (len === 127) { if (buf.length - off < 10) break; len = 0; for (var i = 0; i < 8; i++) len = len * 256 + buf[p + i]; p += 8; }
    \\        if (buf.length - p < len) break;
    \\        var payload = buf.slice(p, p + len); off = p + len;
    \\        if (opcode === 0x1) fire("message", { data: new TextDecoder().decode(payload) });
    \\        else if (opcode === 0x2) { var d = self.binaryType === "arraybuffer" ? payload.buffer.slice(payload.byteOffset, payload.byteOffset + payload.byteLength) : (typeof globalThis.Blob === "function" ? new globalThis.Blob([payload]) : Buffer.from(payload)); fire("message", { data: d }); }
    \\        else if (opcode === 0x8) { self.readyState = 3; if (sock) sock.end(); fire("close", { code: 1000, wasClean: true }); }
    \\        else if (opcode === 0x9) { if (sock) sock.write(wsClientFrame(0xA, payload)); }
    \\      }
    \\      self._buf = buf.slice(off);
    \\    }
    \\    B.connect({ hostname: host, port: port, socket: {
    \\      open: function(s) { sock = s; self._sock = s; s.write("GET " + path + " HTTP/1.1\r\nHost: " + host + ":" + port + "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: " + key + "\r\nSec-WebSocket-Version: 13\r\n\r\n"); },
    \\      data: function(s, data) {
    \\        if (!handshakeDone) {
    \\          var str = data.toString("latin1"); var idx = str.indexOf("\r\n\r\n"); if (idx < 0) return;
    \\          if (str.indexOf(" 101 ") < 0) { self.readyState = 3; fire("error", {}); fire("close", { code: 1006 }); s.end(); return; }
    \\          handshakeDone = true; self.readyState = 1; fire("open", {});
    \\          if (data.length > idx + 4) onbytes(data.slice(idx + 4));
    \\        } else onbytes(data);
    \\      },
    \\      close: function() { if (self.readyState !== 3) { self.readyState = 3; fire("close", { code: 1006 }); } },
    \\    } }).catch(function(e) { self.readyState = 3; fire("error", e); fire("close", { code: 1006 }); });
    \\    this.send = function(data) {
    \\      if (self.readyState !== 1 || !sock) return;
    \\      var pp = (typeof data === "string") ? [0x1, new TextEncoder().encode(data)] : [0x2, (data instanceof Uint8Array ? data : (ArrayBuffer.isView(data) ? new Uint8Array(data.buffer, data.byteOffset, data.byteLength) : new Uint8Array(data)))];
    \\      sock.write(wsClientFrame(pp[0], pp[1]));
    \\    };
    \\    this.close = function(code, reason) {
    \\      if (self.readyState === 3) return;
    \\      self.readyState = 2;
    \\      var rb = reason ? new TextEncoder().encode(String(reason)) : new Uint8Array(0);
    \\      var cc = code || 1000; var pl = new Uint8Array(2 + rb.length); pl[0] = (cc >> 8) & 0xff; pl[1] = cc & 0xff; pl.set(rb, 2);
    \\      if (sock) { sock.write(wsClientFrame(0x8, pl)); sock.end(); }
    \\      self.readyState = 3;
    \\    };
    \\  }
    \\  WebSocket.CONNECTING = 0; WebSocket.OPEN = 1; WebSocket.CLOSING = 2; WebSocket.CLOSED = 3;
    \\  globalThis.WebSocket = WebSocket;
    \\  B.udpSocket = function(options) {
    \\    options = options || {};
    \\    var host = options.hostname || "0.0.0.0";
    \\    var port = options.port | 0;
    \\    var fd = udpBindFn(host, port);
    \\    if (fd < 0) return Promise.reject(Object.assign(new Error("Failed to bind UDP " + host + ":" + port), { code: "EADDRINUSE" }));
    \\    var handlers = options.socket || {};
    \\    var sock = {
    \\      _fd: fd, port: port, hostname: host, binaryType: options.binaryType || "buffer",
    \\      send: function(data, p, a) { var n = udpSendFn(fd, udpToBytes(data), a || "127.0.0.1", p | 0); return n >= 0; },
    \\      close: function() { closeFn(fd); delete udpReg[fd]; },
    \\      ref: function() {}, unref: function() {},
    \\      address: function() { return { address: host, port: port, family: "IPv4" }; },
    \\    };
    \\    udpReg[fd] = { kind: "bun", target: { handlers: handlers, sock: sock } };
    \\    return Promise.resolve(sock);
    \\  };
    \\
    \\  B.listen = function(options) {
    \\    options = options || {};
    \\    var hostname = options.hostname || "0.0.0.0";
    \\    var port = options.port | 0;
    \\    var handlers = options.socket || {};
    \\    var fd = listenFn(hostname, port);
    \\    if (fd < 0) { var e = new Error("Failed to listen on " + hostname + ":" + port); e.code = "EADDRINUSE"; throw e; }
    \\    servers[fd] = handlers;
    \\    return {
    \\      port: port, hostname: hostname, unix: undefined, _fd: fd,
    \\      stop: function() { closeFn(fd); delete servers[fd]; },
    \\      ref: function() {}, unref: function() {}, reload: function(o) { if (o && o.socket) servers[fd] = o.socket; },
    \\      data: options.data,
    \\    };
    \\  };
    \\
    \\  B.connect = function(options) {
    \\    options = options || {};
    \\    var hostname = options.hostname || "127.0.0.1";
    \\    var port = options.port | 0;
    \\    var handlers = options.socket || {};
    \\    var fd = connectFn(hostname, port);
    \\    if (fd < 0) return Promise.reject(Object.assign(new Error("Failed to connect to " + hostname + ":" + port), { code: "ECONNREFUSED" }));
    \\    var sock = makeSocket(fd);
    \\    sock.data = options.data;
    \\    registry[fd] = { handlers: handlers, socketObj: sock };
    \\    if (typeof handlers.open === "function") { try { handlers.open(sock); } catch (e) {} }
    \\    return Promise.resolve(sock);
    \\  };
    \\})();
;

fn evalBool(allocator: std.mem.Allocator, ctx: *JSContextRef, source: []const u8) !bool {
    const value = (try evaluate.evaluateUtf8(allocator, ctx, source, "home:socket-probe", 1, null)) orelse
        return error.JSEvaluateReturnedNull;
    return extern_fns.JSValueToBoolean(ctx, value);
}

test "Bun.listen / Bun.connect expose the socket API surface (non-blocking)" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    @import("bun_global.zig").install(std.testing.allocator, ctx, engine.currentGlobalObject());
    install(std.testing.allocator, ctx, engine.currentGlobalObject());

    // The handles bind/connect and expose the documented surface without
    // entering the (blocking) poll loop, which main.zig drives post-script.
    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "(function() {" ++
        "  var server = Bun.listen({ hostname: '127.0.0.1', port: 0, socket: { data: function() {} } });" ++
        "  if (typeof server.stop !== 'function' || typeof server.port !== 'number') return false;" ++
        "  server.stop();" ++
        "  return typeof Bun.connect === 'function'; })()"));
}
