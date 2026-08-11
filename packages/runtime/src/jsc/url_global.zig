// Phase 3 — `URL` / `URLSearchParams` for the native JSC eval/run realm.
//
// The field parse is a faithful native bridge to Home's pure-Zig URL parser
// (`../url/url.zig`, i.e. Bun's `bun.URL`): `__home_url_parse(href)` runs
// `URL.parse` and returns the parsed components as a plain object. The JS
// `URL`/`URLSearchParams` classes are thin wrappers over that.
//
// Scope note: `URLSearchParams` is complete; `URL` covers absolute URLs and
// the common relative-base forms (`new URL("/p", base)`, scheme-relative,
// and simple path-relative). Full WHATWG edge cases (IDNA, exhaustive
// percent-encoding normalization, every relative dot-segment rule) are not
// reproduced — `bun.URL` itself is documented as "close to WHATWG URL, but we
// don't want the validation errors". comptime-gated on `enable_jsc`.

const std = @import("std");
const bun = @import("bun");
const build_options = @import("build_options");
const evaluate = @import("evaluate.zig");
const callback = @import("callback.zig");
const extern_fns = @import("extern_fns.zig");
const opaques = @import("opaques.zig");
const url_mod = @import("../url/url.zig");
const native_url = @import("URL.zig");

const JSValue = opaques.JSValue;
const JSContextRef = opaques.JSContextRef;
const JSObject = opaques.JSObject;
const JSGlobalObject = opaques.JSGlobalObject;

fn jsStringValue(ctx: *JSContextRef, text: []const u8) ?*JSValue {
    const allocator = std.heap.page_allocator;
    const text_z = bun.dupeZ(allocator, u8, text) catch return null;
    defer allocator.free(text_z);
    const string = extern_fns.JSStringCreateWithUTF8CString(text_z.ptr) orelse return null;
    defer extern_fns.JSStringRelease(string);
    return extern_fns.JSValueMakeString(ctx, string);
}

fn setStr(ctx: *JSContextRef, object: *JSObject, key: []const u8, value: []const u8) void {
    const allocator = std.heap.page_allocator;
    const key_z = bun.dupeZ(allocator, u8, key) catch return;
    defer allocator.free(key_z);
    const name = extern_fns.JSStringCreateWithUTF8CString(key_z.ptr) orelse return;
    defer extern_fns.JSStringRelease(name);
    const v = jsStringValue(ctx, value) orelse return;
    extern_fns.JSObjectSetProperty(ctx, object, name, v, 0, null);
}

fn valueToOwnedUtf8(ctx: *JSContextRef, value: *JSValue, allocator: std.mem.Allocator) ?[]u8 {
    const string = extern_fns.JSValueToStringCopy(ctx, value, null) orelse return null;
    defer extern_fns.JSStringRelease(string);
    const capacity = extern_fns.JSStringGetLength(string) * 4 + 1;
    const buffer = allocator.alloc(u8, capacity) catch return null;
    const written = extern_fns.JSStringGetUTF8CString(string, buffer.ptr, buffer.len);
    if (written == 0) {
        allocator.free(buffer);
        return null;
    }
    const result = allocator.dupe(u8, buffer[0 .. written - 1]) catch {
        allocator.free(buffer);
        return null;
    };
    allocator.free(buffer);
    return result;
}

fn setNativeUrlString(ctx: *JSContextRef, object: *JSObject, key: []const u8, value: bun.String) void {
    defer value.deref();
    const allocator = std.heap.page_allocator;
    const bytes = value.toOwnedSlice(allocator) catch return;
    defer allocator.free(bytes);
    setStr(ctx, object, key, bytes);
}

fn nativeStringToOwnedUtf8(value: bun.String, allocator: std.mem.Allocator) ?[]u8 {
    defer value.deref();
    return value.toOwnedSlice(allocator) catch null;
}

fn hasAsciiScheme(input: []const u8) bool {
    if (input.len == 0 or !std.ascii.isAlphabetic(input[0])) return false;
    for (input[1..]) |byte| {
        if (byte == ':') return true;
        if (!std.ascii.isAlphanumeric(byte) and byte != '+' and byte != '-' and byte != '.') return false;
    }
    return false;
}

fn containsPinnedDisallowedIdnaCodePoint(input: []const u8) bool {
    const pinned = [_][]const u8{
        "\xE2\x80\xA5", // U+2025
        "\xE1\xA0\x8E", // U+180E
        "\xE2\x81\xAB", // U+206B
        "\xD3\x80", // U+04C0
        "\xE2\x86\x83", // U+2183
    };
    for (pinned) |sequence| {
        if (std.mem.indexOf(u8, input, sequence) != null) return true;
    }
    return false;
}

fn specialAuthorityContainsPinnedDisallowedIdnaCodePoint(input: []const u8) bool {
    const authority_start = if (std.mem.startsWith(u8, input, "//"))
        @as(usize, 2)
    else blk: {
        const colon = std.mem.indexOfScalar(u8, input, ':') orelse return false;
        const scheme = input[0..colon];
        const special = std.ascii.eqlIgnoreCase(scheme, "http") or
            std.ascii.eqlIgnoreCase(scheme, "https") or
            std.ascii.eqlIgnoreCase(scheme, "ws") or
            std.ascii.eqlIgnoreCase(scheme, "wss") or
            std.ascii.eqlIgnoreCase(scheme, "ftp") or
            std.ascii.eqlIgnoreCase(scheme, "file");
        if (!special or !std.mem.startsWith(u8, input[colon + 1 ..], "//")) return false;
        break :blk colon + 3;
    };
    const authority_tail = input[authority_start..];
    const authority_end = std.mem.indexOfAny(u8, authority_tail, "/?#") orelse authority_tail.len;
    const authority = authority_tail[0..authority_end];
    const host_start = if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| at + 1 else 0;
    return containsPinnedDisallowedIdnaCodePoint(authority[host_start..]);
}

fn isOpaqueUrl(href: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, href, ':') orelse return false;
    const scheme = href[0..colon];
    const special = std.ascii.eqlIgnoreCase(scheme, "http") or
        std.ascii.eqlIgnoreCase(scheme, "https") or
        std.ascii.eqlIgnoreCase(scheme, "ws") or
        std.ascii.eqlIgnoreCase(scheme, "wss") or
        std.ascii.eqlIgnoreCase(scheme, "ftp") or
        std.ascii.eqlIgnoreCase(scheme, "file");
    return !special and !std.mem.startsWith(u8, href[colon + 1 ..], "//");
}

fn hasForbiddenDomainByte(ascii: []const u8) bool {
    for (ascii) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return true;
        switch (byte) {
            '#', '%', '/', ':', '<', '>', '?', '@', '[', '\\', ']', '^', '|' => return true,
            else => {},
        }
    }
    return false;
}

fn validateSpecialHost(parsed: *native_url.URL) bool {
    const allocator = std.heap.page_allocator;
    const protocol = nativeStringToOwnedUtf8(native_url.URL.protocol(parsed), allocator) orelse return false;
    defer allocator.free(protocol);
    const special = std.mem.eql(u8, protocol, "http") or
        std.mem.eql(u8, protocol, "https") or
        std.mem.eql(u8, protocol, "ws") or
        std.mem.eql(u8, protocol, "wss") or
        std.mem.eql(u8, protocol, "ftp") or
        std.mem.eql(u8, protocol, "file");
    if (!special) return true;

    const hostname = nativeStringToOwnedUtf8(native_url.URL.host(parsed), allocator) orelse return false;
    defer allocator.free(hostname);
    if (hostname.len == 0 or (hostname[0] == '[' and hostname[hostname.len - 1] == ']')) return true;
    if (hostname.len > std.math.maxInt(i32)) return false;
    var ascii: [idna_buffer_capacity]u8 = undefined;
    const length = home_idna_to_ascii_utf8(hostname.ptr, @intCast(hostname.len), &ascii, ascii.len);
    return length >= 0 and !hasForbiddenDomainByte(ascii[0..@intCast(length)]);
}

/// `__home_url_parse(href)` -> `{ protocol, username, password, host,
/// hostname, port, pathname, search, hash, href, origin }` from `bun.URL`.
fn parseUrlNative(
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
    const buf = allocator.alloc(u8, capacity) catch return extern_fns.JSValueMakeNull(c);
    defer allocator.free(buf);
    const written = extern_fns.JSStringGetUTF8CString(string, buf.ptr, buf.len);
    const href = buf[0..if (written > 0) written - 1 else 0];

    const parsed = url_mod.URL.parse(href);
    const object = extern_fns.JSObjectMake(c, null, null) orelse return extern_fns.JSValueMakeNull(c);
    setStr(c, object, "protocol", parsed.protocol);
    setStr(c, object, "username", parsed.username);
    setStr(c, object, "password", parsed.password);
    setStr(c, object, "host", parsed.host);
    setStr(c, object, "hostname", parsed.hostname);
    setStr(c, object, "port", parsed.port);
    setStr(c, object, "pathname", parsed.pathname);
    setStr(c, object, "search", parsed.search);
    setStr(c, object, "hash", parsed.hash);
    setStr(c, object, "href", parsed.href);
    setStr(c, object, "origin", parsed.origin);
    return @ptrCast(object);
}

/// `__home_url_parse_whatwg_native(input, base?)` parses through WebKit's
/// WHATWG URL implementation and returns null on any invalid input/base.
/// Unlike the lightweight URL global above, this is suitable for Node/Bun
/// compatibility boundaries including IPv6, IDNA, ports, and opaque paths.
fn parseWhatwgUrlNative(
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
    const input_value = arguments[0] orelse return extern_fns.JSValueMakeNull(c);

    const allocator = std.heap.page_allocator;
    const input = valueToOwnedUtf8(c, input_value, allocator) orelse return extern_fns.JSValueMakeNull(c);
    defer allocator.free(input);
    if (specialAuthorityContainsPinnedDisallowedIdnaCodePoint(input)) return extern_fns.JSValueMakeNull(c);

    var resolved: ?[]u8 = null;
    defer if (resolved) |bytes| allocator.free(bytes);
    const href = if (argument_count >= 2 and arguments[1] != null and !extern_fns.JSValueIsUndefined(c, arguments[1])) blk: {
        const base = valueToOwnedUtf8(c, arguments[1].?, allocator) orelse return extern_fns.JSValueMakeNull(c);
        defer allocator.free(base);
        const normalized_base = native_url.URL.hrefFromString(bun.String.borrowUTF8(base));
        defer normalized_base.deref();
        if (normalized_base.tag == .Dead) return extern_fns.JSValueMakeNull(c);
        const base_href = normalized_base.toOwnedSlice(allocator) catch return extern_fns.JSValueMakeNull(c);
        defer allocator.free(base_href);
        const base_url = native_url.URL.fromUTF8(base_href) orelse return extern_fns.JSValueMakeNull(c);
        defer native_url.URL.deinit(base_url);
        if (!validateSpecialHost(base_url)) return extern_fns.JSValueMakeNull(c);
        if (!hasAsciiScheme(input) and isOpaqueUrl(base_href)) return extern_fns.JSValueMakeNull(c);

        const joined = native_url.URL.join(bun.String.borrowUTF8(base_href), bun.String.borrowUTF8(input));
        defer joined.deref();
        if (joined.tag == .Dead) return extern_fns.JSValueMakeNull(c);
        resolved = joined.toOwnedSlice(allocator) catch return extern_fns.JSValueMakeNull(c);
        break :blk resolved.?;
    } else blk: {
        const normalized = native_url.URL.hrefFromString(bun.String.borrowUTF8(input));
        defer normalized.deref();
        if (normalized.tag == .Dead) return extern_fns.JSValueMakeNull(c);
        resolved = normalized.toOwnedSlice(allocator) catch return extern_fns.JSValueMakeNull(c);
        break :blk resolved.?;
    };

    const parsed = native_url.URL.fromUTF8(href) orelse return extern_fns.JSValueMakeNull(c);
    defer native_url.URL.deinit(parsed);
    if (!validateSpecialHost(parsed)) return extern_fns.JSValueMakeNull(c);
    const object = extern_fns.JSObjectMake(c, null, null) orelse return extern_fns.JSValueMakeNull(c);
    setNativeUrlString(c, object, "protocol", native_url.URL.protocol(parsed));
    setNativeUrlString(c, object, "username", native_url.URL.username(parsed));
    setNativeUrlString(c, object, "password", native_url.URL.password(parsed));
    setNativeUrlString(c, object, "hostname", native_url.URL.host(parsed));
    setNativeUrlString(c, object, "host", native_url.URL.hostname(parsed));
    setNativeUrlString(c, object, "pathname", native_url.URL.pathname(parsed));
    setNativeUrlString(c, object, "search", native_url.URL.search(parsed));
    setNativeUrlString(c, object, "hash", native_url.URL.hash(parsed));
    setNativeUrlString(c, object, "href", native_url.URL.href(parsed));
    const port = native_url.URL.port(parsed);
    if (port == std.math.maxInt(u32)) {
        setStr(c, object, "port", "");
    } else {
        var port_buffer: [5]u8 = undefined;
        const port_text = std.fmt.bufPrint(&port_buffer, "{d}", .{port}) catch "";
        setStr(c, object, "port", port_text);
    }
    return @ptrCast(object);
}

const IdnaOperation = enum { ascii, unicode };
const idna_buffer_capacity = 8192;

extern fn home_idna_to_ascii_utf8([*]const u8, i32, [*]u8, i32) callconv(.c) i32;
extern fn home_idna_to_unicode_utf8([*]const u8, i32, [*]u8, i32) callconv(.c) i32;

/// ICU UTS #46 hostname conversion used by Node's domainToASCII() and
/// domainToUnicode(). This matches Bun's NodeURL.cpp validation rules rather
/// than treating successful URL parsing as sufficient IDNA validation.
fn domainConvertNative(
    comptime operation: IdnaOperation,
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this_object: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) ?*JSValue {
    _ = function;
    _ = this_object;
    _ = exception;
    const c = ctx orelse return null;
    if (argument_count < 1) return jsStringValue(c, "");
    const value = arguments[0] orelse return jsStringValue(c, "");

    const allocator = std.heap.page_allocator;
    const string = extern_fns.JSValueToStringCopy(c, value, null) orelse return jsStringValue(c, "");
    defer extern_fns.JSStringRelease(string);
    const capacity = extern_fns.JSStringGetLength(string) * 4 + 1;
    const input_buffer = allocator.alloc(u8, capacity) catch return jsStringValue(c, "");
    defer allocator.free(input_buffer);
    const written = extern_fns.JSStringGetUTF8CString(string, input_buffer.ptr, input_buffer.len);
    const input = input_buffer[0..if (written > 0) written - 1 else 0];

    if (input.len > std.math.maxInt(i32)) return jsStringValue(c, "");
    var output: [idna_buffer_capacity]u8 = undefined;
    const output_length = switch (operation) {
        .ascii => home_idna_to_ascii_utf8(input.ptr, @intCast(input.len), &output, output.len),
        .unicode => home_idna_to_unicode_utf8(input.ptr, @intCast(input.len), &output, output.len),
    };
    if (output_length < 0) return jsStringValue(c, "");
    return jsStringValue(c, output[0..@intCast(output_length)]);
}

fn domainToAsciiNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this_object: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    return domainConvertNative(.ascii, ctx, function, this_object, argument_count, arguments, exception);
}

fn domainToUnicodeNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this_object: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    return domainConvertNative(.unicode, ctx, function, this_object, argument_count, arguments, exception);
}

/// Install only the native IDNA primitive. Corpus and other compatibility
/// realms can use this without replacing their existing URL constructors.
pub fn installIdnaBridge(ctx: *JSContextRef, global: *JSGlobalObject) void {
    if (comptime !build_options.enable_jsc) return;
    callback.registerCallback(ctx, global, "__home_url_parse_whatwg_native", parseWhatwgUrlNative);
    callback.registerCallback(ctx, global, "__home_url_domain_to_ascii_native", domainToAsciiNative);
    callback.registerCallback(ctx, global, "__home_url_domain_to_unicode_native", domainToUnicodeNative);
}

const install_glue =
    \\(function() {
    \\  var parseFn = globalThis.__home_url_parse;
    \\  var domainToAsciiFn = globalThis.__home_url_domain_to_ascii_native;
    \\
    \\  function hasForbiddenDomainCodePoint(text) {
    \\    for (var i = 0; i < text.length; i++) {
    \\      var code = text.charCodeAt(i);
    \\      if (code <= 0x20 || code === 0x7f || code === 0x23 || code === 0x25 || code === 0x2f || code === 0x3a || code === 0x3c || code === 0x3e || code === 0x3f || code === 0x40 || code === 0x5b || code === 0x5c || code === 0x5d || code === 0x5e || code === 0x7c) return true;
    \\    }
    \\    return false;
    \\  }
    \\
    \\  function normalizeSpecialHost(value) {
    \\    var match = String(value).match(/^([A-Za-z][A-Za-z0-9+.-]*:\/\/)([^\/?#]*)(.*)$/);
    \\    if (!match || !["http://", "https://", "ws://", "wss://", "ftp://", "file://"].includes(match[1].toLowerCase())) return String(value);
    \\    var authority = match[2];
    \\    var at = authority.lastIndexOf("@");
    \\    var credentials = at === -1 ? "" : authority.slice(0, at + 1);
    \\    var hostPort = at === -1 ? authority : authority.slice(at + 1);
    \\    if (hostPort.charAt(0) === "[") return String(value);
    \\    var colon = hostPort.lastIndexOf(":");
    \\    var hostname = colon === -1 ? hostPort : hostPort.slice(0, colon);
    \\    var port = colon === -1 ? "" : hostPort.slice(colon);
    \\    var ascii = typeof domainToAsciiFn === "function" ? domainToAsciiFn(hostname) : hostname;
    \\    if ((ascii === "" && hostname !== "") || hasForbiddenDomainCodePoint(ascii)) throw new TypeError("Invalid URL: " + String(value));
    \\    return match[1] + credentials + ascii + port + match[3];
    \\  }
    \\
    \\  function encode(s) { return encodeURIComponent(s).replace(/%20/g, "+"); }
    \\  function decode(s) { return decodeURIComponent(String(s).replace(/\+/g, " ")); }
    \\
    \\  class URLSearchParams {
    \\    constructor(init) {
    \\      this._list = [];
    \\      if (init === undefined || init === null) return;
    \\      if (typeof init === "string") {
    \\        var q = init.charAt(0) === "?" ? init.slice(1) : init;
    \\        if (q.length) {
    \\          var pairs = q.split("&");
    \\          for (var i = 0; i < pairs.length; i++) {
    \\            if (!pairs[i]) continue;
    \\            var eq = pairs[i].indexOf("=");
    \\            if (eq === -1) this._list.push([decode(pairs[i]), ""]);
    \\            else this._list.push([decode(pairs[i].slice(0, eq)), decode(pairs[i].slice(eq + 1))]);
    \\          }
    \\        }
    \\      } else if (Array.isArray(init)) {
    \\        for (var j = 0; j < init.length; j++) this._list.push([String(init[j][0]), String(init[j][1])]);
    \\      } else if (init instanceof URLSearchParams) {
    \\        for (var k = 0; k < init._list.length; k++) this._list.push([init._list[k][0], init._list[k][1]]);
    \\      } else if (typeof init === "object") {
    \\        for (var key in init) if (Object.prototype.hasOwnProperty.call(init, key)) this._list.push([key, String(init[key])]);
    \\      }
    \\    }
    \\    get size() { return this._list.length; }
    \\    append(n, v) { this._list.push([String(n), String(v)]); }
    \\    delete(n) { n = String(n); this._list = this._list.filter(function(p) { return p[0] !== n; }); }
    \\    get(n) { n = String(n); for (var i = 0; i < this._list.length; i++) if (this._list[i][0] === n) return this._list[i][1]; return null; }
    \\    getAll(n) { n = String(n); return this._list.filter(function(p) { return p[0] === n; }).map(function(p) { return p[1]; }); }
    \\    has(n) { n = String(n); return this._list.some(function(p) { return p[0] === n; }); }
    \\    set(n, v) { n = String(n); v = String(v); var done = false; var out = [];
    \\      for (var i = 0; i < this._list.length; i++) { if (this._list[i][0] === n) { if (!done) { out.push([n, v]); done = true; } } else out.push(this._list[i]); }
    \\      if (!done) out.push([n, v]); this._list = out; }
    \\    sort() { this._list.sort(function(a, b) { return a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0; }); }
    \\    forEach(cb, thisArg) { for (var i = 0; i < this._list.length; i++) cb.call(thisArg, this._list[i][1], this._list[i][0], this); }
    \\    keys() { return this._list.map(function(p) { return p[0]; })[Symbol.iterator](); }
    \\    values() { return this._list.map(function(p) { return p[1]; })[Symbol.iterator](); }
    \\    entries() { return this._list.map(function(p) { return [p[0], p[1]]; })[Symbol.iterator](); }
    \\    [Symbol.iterator]() { return this.entries(); }
    \\    toString() { return this._list.map(function(p) { return encode(p[0]) + "=" + encode(p[1]); }).join("&"); }
    \\  }
    \\
    \\  function hasScheme(s) { return /^[a-zA-Z][a-zA-Z0-9+.\-]*:/.test(s); }
    \\
    \\  function resolve(input, base) {
    \\    if (hasScheme(input)) return input;
    \\    var b = parseFn(base);
    \\    if (!b || !b.protocol) throw new TypeError("Invalid base URL: " + base);
    \\    var proto = b.protocol.charAt(b.protocol.length - 1) === ":" ? b.protocol : b.protocol + ":";
    \\    var origin = proto + "//" + (b.host || b.hostname);
    \\    if (input.slice(0, 2) === "//") return proto + input;
    \\    if (input.charAt(0) === "/") return origin + input;
    \\    if (input.charAt(0) === "?") return origin + (b.pathname || "/") + input;
    \\    if (input.charAt(0) === "#") return origin + (b.pathname || "/") + (b.search || "") + input;
    \\    var dir = (b.pathname || "/").replace(/[^/]*$/, "");
    \\    return origin + dir + input;
    \\  }
    \\
    \\  class URL {
    \\    constructor(input, base) {
    \\      var str = String(input);
    \\      if (base !== undefined && base !== null) str = resolve(str, String(base));
    \\      str = normalizeSpecialHost(str);
    \\      var f = parseFn(str);
    \\      if (!f || !f.protocol) throw new TypeError("Invalid URL: " + String(input));
    \\      this._protocol = f.protocol.charAt(f.protocol.length - 1) === ":" ? f.protocol : f.protocol + ":";
    \\      this._username = f.username || "";
    \\      this._password = f.password || "";
    \\      this._hostname = f.hostname || "";
    \\      this._port = f.port || "";
    \\      var rawPath = f.pathname || "/";
    \\      var cut = rawPath.search(/[?#]/);
    \\      this._pathname = cut === -1 ? rawPath : rawPath.slice(0, cut);
    \\      if (this._pathname === "") this._pathname = "/";
    \\      this._hash = f.hash || "";
    \\      this._searchParams = new URLSearchParams(f.search || "");
    \\    }
    \\    get protocol() { return this._protocol; }
    \\    set protocol(v) { v = String(v); this._protocol = v.charAt(v.length - 1) === ":" ? v : v + ":"; }
    \\    get username() { return this._username; }
    \\    set username(v) { this._username = String(v); }
    \\    get password() { return this._password; }
    \\    set password(v) { this._password = String(v); }
    \\    get hostname() { return this._hostname; }
    \\    set hostname(v) { this._hostname = String(v); }
    \\    get port() { return this._port; }
    \\    set port(v) { this._port = String(v); }
    \\    get host() { return this._hostname + (this._port ? ":" + this._port : ""); }
    \\    set host(v) { v = String(v); var c = v.indexOf(":"); if (c === -1) { this._hostname = v; this._port = ""; } else { this._hostname = v.slice(0, c); this._port = v.slice(c + 1); } }
    \\    get pathname() { return this._pathname; }
    \\    set pathname(v) { v = String(v); this._pathname = v.charAt(0) === "/" ? v : "/" + v; }
    \\    get hash() { var h = this._hash; return h && h.charAt(0) !== "#" ? "#" + h : h; }
    \\    set hash(v) { v = String(v); this._hash = v === "" ? "" : (v.charAt(0) === "#" ? v : "#" + v); }
    \\    get search() { var s = this._searchParams.toString(); return s ? "?" + s : ""; }
    \\    set search(v) { this._searchParams = new URLSearchParams(String(v)); }
    \\    get searchParams() { return this._searchParams; }
    \\    get origin() {
    \\      var special = /^(https?|wss?|ftp|file):$/.test(this._protocol);
    \\      if (!special) return "null";
    \\      if (this._protocol === "file:") return "null";
    \\      return this._protocol + "//" + this.host;
    \\    }
    \\    get href() {
    \\      var auth = this._username ? (this._username + (this._password ? ":" + this._password : "") + "@") : "";
    \\      return this._protocol + "//" + auth + this.host + this._pathname + this.search + this.hash;
    \\    }
    \\    set href(v) { var u = new URL(String(v)); Object.assign(this, { _protocol: u._protocol, _username: u._username, _password: u._password, _hostname: u._hostname, _port: u._port, _pathname: u._pathname, _hash: u._hash, _searchParams: u._searchParams }); }
    \\    toString() { return this.href; }
    \\    toJSON() { return this.href; }
    \\  }
    \\  // URL.canParse(url, base) -> would `new URL(url, base)` succeed?
    \\  URL.canParse = function(url, base) { try { new URL(String(url), base); return true; } catch (e) { return false; } };
    \\
    \\  globalThis.URLSearchParams = URLSearchParams;
    \\  globalThis.URL = URL;
    \\  delete globalThis.__home_url_parse;
    \\})();
;

/// Install `URL` and `URLSearchParams` into `ctx`'s realm. No-op without JSC.
pub fn install(allocator: std.mem.Allocator, ctx: *JSContextRef, global: *JSGlobalObject) void {
    if (comptime !build_options.enable_jsc) return;

    installIdnaBridge(ctx, global);
    callback.registerCallback(ctx, global, "__home_url_parse", parseUrlNative);
    const result = evaluate.evaluateUtf8Detailed(allocator, ctx, install_glue, "home:url-install", 1) catch return;
    result.deinit(allocator);
}

fn evalBool(allocator: std.mem.Allocator, ctx: *JSContextRef, source: []const u8) !bool {
    const value = (try evaluate.evaluateUtf8(allocator, ctx, source, "home:url-probe", 1, null)) orelse
        return error.JSEvaluateReturnedNull;
    return extern_fns.JSValueToBoolean(ctx, value);
}

test "URL parses an absolute https url into components" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    install(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "(function() {" ++
        "  var u = new URL('https://user:pass@example.com:8080/a/b?x=1&y=2#frag');" ++
        "  var ignored = new URL('https://look\u{feff}out.net/x');" ++
        "  return u.protocol === 'https:' && u.hostname === 'example.com' && u.port === '8080' &&" ++
        "    u.host === 'example.com:8080' && u.pathname === '/a/b' && u.search === '?x=1&y=2' &&" ++
        "    u.hash === '#frag' && u.username === 'user' && u.password === 'pass' &&" ++
        "    u.origin === 'https://example.com:8080' && u.searchParams.get('y') === '2' &&" ++
        "    ignored.hostname === 'lookout.net' && ignored.href === 'https://lookout.net/x';" ++
        "})()"));
}

test "URL throws TypeError on an invalid (schemeless) url" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    install(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "(function() { try { new URL('not a url'); return false; } catch (e) { return e instanceof TypeError; } })()"));
}

test "URL.canParse reports parseability without throwing" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    install(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "(function() {" ++
        "  if (typeof URL.canParse !== 'function') return false;" ++
        "  if (URL.canParse('https://example.com/p') !== true) return false;" ++
        "  if (URL.canParse('not a url') !== false) return false;" ++
        "  if (URL.canParse('/rel') !== false) return false;" ++ // relative w/o base
        "  return URL.canParse('/rel', 'https://example.com') === true;" ++ // relative w/ base
        "})()"));
}

test "URL resolves common relative forms against a base" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    install(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "(function() {" ++
        "  var root = new URL('/api/x', 'https://h.com/a/b');" ++
        "  var rel = new URL('c', 'https://h.com/a/b');" ++
        "  return root.href === 'https://h.com/api/x' && rel.href === 'https://h.com/a/c';" ++
        "})()"));
}

test "URLSearchParams supports the core mutating + iteration API" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    install(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "(function() {" ++
        "  var p = new URLSearchParams('a=1&b=2&a=3');" ++
        "  if (p.get('a') !== '1' || p.getAll('a').join(',') !== '1,3' || p.has('b') !== true) return false;" ++
        "  p.append('c', '4'); p.set('a', '9'); p.delete('b');" ++
        "  if (p.get('a') !== '9' || p.has('b') !== false || p.get('c') !== '4') return false;" ++
        "  var seen = []; for (var e of p) seen.push(e[0] + '=' + e[1]);" ++
        "  return seen.join('&') === 'a=9&c=4' && p.toString() === 'a=9&c=4' && p.size === 2;" ++
        "})()"));
}

test "native IDNA bridge follows Node UTS 46 validation" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    installIdnaBridge(ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "(function() {" ++
        "  return __home_url_domain_to_ascii_native('mañana.com') === 'xn--maana-pta.com' &&" ++
        "    __home_url_domain_to_ascii_native('look\u{feff}out.net') === 'lookout.net' &&" ++
        "    __home_url_domain_to_unicode_native('xn--maana-pta.com') === 'mañana.com' &&" ++
        "    __home_url_domain_to_ascii_native('xn--a') === '';" ++
        "})()"));
}

test "native WHATWG URL bridge canonicalizes and rejects invalid bases" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    installIdnaBridge(ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "(function() {" ++
        "  var parsed = __home_url_parse_whatwg_native('https://mañana.com/a b');" ++
        "  return parsed !== null && parsed.href === 'https://xn--maana-pta.com/a%20b' &&" ++
        "    __home_url_parse_whatwg_native('https://example.com:99999/') === null &&" ++
        "    __home_url_parse_whatwg_native('relative', 'mailto:test@example.com') === null &&" ++
        "    __home_url_parse_whatwg_native('relative', 'custom:/opaque') === null;" ++
        "})()"));
}
