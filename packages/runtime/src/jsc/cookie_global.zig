// Native `Bun.Cookie` + `Bun.CookieMap` for the eval/run realm. Pure-JS glue
// mirroring Bun's Cookie/CookieMap (src/jsc/bindings/{Cookie,CookieMap}.cpp):
// RFC 6265 parse/serialize with the same attribute order
//   name=value; Domain; Path; Expires; Max-Age; Secure; HttpOnly; Partitioned; SameSite
// and the same defaults (path "/", sameSite "lax", others off). comptime-gated.

const std = @import("std");
const build_options = @import("build_options");
const evaluate = @import("evaluate.zig");
const extern_fns = @import("extern_fns.zig");
const opaques = @import("opaques.zig");

const JSContextRef = opaques.JSContextRef;
const JSGlobalObject = opaques.JSGlobalObject;

const install_glue =
    \\(function() {
    \\  var B = globalThis.Bun;
    \\  if (!B) return;
    \\
    \\  function normSameSite(v) {
    \\    if (v === undefined || v === null) return "lax";
    \\    if (v === true) return "strict";
    \\    if (v === false) return "none";
    \\    var s = String(v).toLowerCase();
    \\    return (s === "strict" || s === "lax" || s === "none") ? s : "lax";
    \\  }
    \\  function capSameSite(s) { return s === "strict" ? "Strict" : s === "none" ? "None" : "Lax"; }
    \\  function normExpires(e) {
    \\    if (e === undefined || e === null) return undefined;
    \\    if (e instanceof Date) {
    \\      if (isNaN(e.getTime())) throw new TypeError("expires must be a valid Date (or Number)");
    \\      return e;
    \\    }
    \\    if (typeof e === "number") {
    \\      if (!isFinite(e)) throw new TypeError("expires must be a valid Number");
    \\      return new Date(e * 1000);
    \\    }
    \\    var n = Number(e);
    \\    if (!isFinite(n)) throw new TypeError("expires must be a valid Number");
    \\    return new Date(n * 1000);
    \\  }
    \\
    \\  function Cookie(name, value, options) {
    \\    options = options || {};
    \\    this.name = String(name);
    \\    this.value = String(value);
    \\    this.domain = options.domain !== undefined && options.domain !== null ? String(options.domain) : null;
    \\    this.path = options.path !== undefined && options.path !== null ? String(options.path) : "/";
    \\    this.secure = !!options.secure;
    \\    this.httpOnly = !!options.httpOnly;
    \\    this.partitioned = !!options.partitioned;
    \\    this.sameSite = normSameSite(options.sameSite);
    \\    this.maxAge = (options.maxAge !== undefined && options.maxAge !== null) ? (options.maxAge | 0) : undefined;
    \\    this.expires = normExpires(options.expires);
    \\  }
    \\  Cookie.prototype.serialize = function() {
    \\    var s = this.name + "=" + this.value;
    \\    if (this.domain) s += "; Domain=" + this.domain;
    \\    s += "; Path=" + this.path;
    \\    if (this.expires instanceof Date) s += "; Expires=" + this.expires.toUTCString();
    \\    if (this.maxAge !== undefined) s += "; Max-Age=" + this.maxAge;
    \\    if (this.secure) s += "; Secure";
    \\    if (this.httpOnly) s += "; HttpOnly";
    \\    if (this.partitioned) s += "; Partitioned";
    \\    s += "; SameSite=" + capSameSite(this.sameSite);
    \\    return s;
    \\  };
    \\  Cookie.prototype.toString = function() { return this.serialize(); };
    \\  Cookie.prototype.toJSON = function() {
    \\    return { name: this.name, value: this.value, domain: this.domain, path: this.path,
    \\      expires: this.expires, secure: this.secure, httpOnly: this.httpOnly,
    \\      partitioned: this.partitioned, sameSite: this.sameSite, maxAge: this.maxAge };
    \\  };
    \\  Cookie.prototype.isExpired = function() {
    \\    if (this.expires instanceof Date) return this.expires.getTime() <= Date.now();
    \\    if (this.maxAge !== undefined) return this.maxAge <= 0;
    \\    return false;
    \\  };
    \\  Cookie.parse = function(str) {
    \\    str = String(str);
    \\    var parts = str.split(";");
    \\    var first = parts[0] || "";
    \\    var eq = first.indexOf("=");
    \\    var name = eq >= 0 ? first.slice(0, eq).trim() : first.trim();
    \\    var value = eq >= 0 ? first.slice(eq + 1).trim() : "";
    \\    var opts = {};
    \\    for (var i = 1; i < parts.length; i++) {
    \\      var p = parts[i].trim(); if (!p) continue;
    \\      var ai = p.indexOf("=");
    \\      var key = (ai >= 0 ? p.slice(0, ai) : p).trim().toLowerCase();
    \\      var val = ai >= 0 ? p.slice(ai + 1).trim() : "";
    \\      if (key === "domain") opts.domain = val;
    \\      else if (key === "path") opts.path = val;
    \\      else if (key === "max-age") opts.maxAge = parseInt(val, 10);
    \\      else if (key === "expires") { var d = new Date(val); if (!isNaN(d.getTime())) opts.expires = d; }
    \\      else if (key === "secure") opts.secure = true;
    \\      else if (key === "httponly") opts.httpOnly = true;
    \\      else if (key === "partitioned") opts.partitioned = true;
    \\      else if (key === "samesite") opts.sameSite = val;
    \\    }
    \\    return new Cookie(name, value, opts);
    \\  };
    \\  Cookie.from = function(name, value, options) { return new Cookie(name, value, options); };
    \\  B.Cookie = Cookie;
    \\
    \\  function CookieMap(init) {
    \\    this._map = new Map();     // name -> Cookie
    \\    this._changed = new Set();  // names set/deleted since creation (for toSetCookieHeaders)
    \\    if (init === undefined || init === null) return;
    \\    if (typeof init === "string") {
    \\      var pairs = init.split(";");
    \\      for (var i = 0; i < pairs.length; i++) {
    \\        var p = pairs[i].trim(); if (!p) continue;
    \\        var eq = p.indexOf("=");
    \\        if (eq < 0) continue;
    \\        var n = p.slice(0, eq).trim(); var v = p.slice(eq + 1).trim();
    \\        this._map.set(n, new Cookie(n, v));
    \\      }
    \\    } else if (Array.isArray(init)) {
    \\      for (var j = 0; j < init.length; j++) { var e = init[j]; if (e && e.length >= 2) this._map.set(String(e[0]), new Cookie(String(e[0]), String(e[1]))); }
    \\    } else if (typeof init === "object") {
    \\      for (var k in init) if (Object.prototype.hasOwnProperty.call(init, k)) this._map.set(k, new Cookie(k, String(init[k])));
    \\    }
    \\  }
    \\  Object.defineProperty(CookieMap.prototype, "size", { get: function() { return this._map.size; }, configurable: true });
    \\  CookieMap.prototype.get = function(name) { var c = this._map.get(String(name)); return c ? c.value : null; };
    \\  CookieMap.prototype.has = function(name) { return this._map.has(String(name)); };
    \\  CookieMap.prototype.set = function(name, value, options) {
    \\    var cookie;
    \\    if (name instanceof Cookie) { cookie = name; }
    \\    else if (name && typeof name === "object" && name.name !== undefined) { cookie = new Cookie(name.name, name.value, name); }
    \\    else { cookie = new Cookie(name, value, options); }
    \\    this._map.set(cookie.name, cookie);
    \\    this._changed.add(cookie.name);
    \\    return this;
    \\  };
    \\  CookieMap.prototype.delete = function(name) {
    \\    name = (name && typeof name === "object" && name.name !== undefined) ? name.name : String(name);
    \\    var had = this._map.delete(name);
    \\    // mark a deletion Set-Cookie (expired) like Bun
    \\    var del = new Cookie(name, "", { expires: new Date(0), maxAge: 0 });
    \\    this._changed.add(name);
    \\    this._deletions = this._deletions || {};
    \\    this._deletions[name] = del;
    \\    return had;
    \\  };
    \\  CookieMap.prototype.toSetCookieHeaders = function() {
    \\    var out = [];
    \\    var self = this;
    \\    this._changed.forEach(function(n) {
    \\      if (self._map.has(n)) out.push(self._map.get(n).serialize());
    \\      else if (self._deletions && self._deletions[n]) out.push(self._deletions[n].serialize());
    \\    });
    \\    return out;
    \\  };
    \\  CookieMap.prototype.toJSON = function() { var o = {}; this._map.forEach(function(c, n) { o[n] = c.value; }); return o; };
    \\  CookieMap.prototype.forEach = function(cb, thisArg) { this._map.forEach(function(c, n) { cb.call(thisArg, c.value, n, this); }, this); };
    \\  CookieMap.prototype.keys = function() { return this._map.keys(); };
    \\  CookieMap.prototype.values = function() { var vals = []; this._map.forEach(function(c) { vals.push(c.value); }); return vals[Symbol.iterator](); };
    \\  CookieMap.prototype.entries = function() { var es = []; this._map.forEach(function(c, n) { es.push([n, c.value]); }); return es[Symbol.iterator](); };
    \\  CookieMap.prototype[Symbol.iterator] = function() { return this.entries(); };
    \\  B.CookieMap = CookieMap;
    \\})();
;

pub fn install(allocator: std.mem.Allocator, ctx: *JSContextRef, global: *JSGlobalObject) void {
    if (comptime !build_options.enable_jsc) return;
    _ = global; // installs purely via JS glue over the existing Bun object
    const result = evaluate.evaluateUtf8Detailed(allocator, ctx, install_glue, "home:bun-cookie-install", 1) catch return;
    result.deinit(allocator);
}

fn evalBool(allocator: std.mem.Allocator, ctx: *JSContextRef, source: []const u8) !bool {
    const value = (try evaluate.evaluateUtf8(allocator, ctx, source, "home:cookie-probe", 1, null)) orelse
        return error.JSEvaluateReturnedNull;
    return extern_fns.JSValueToBoolean(ctx, value);
}

fn installRealm(allocator: std.mem.Allocator, ctx: *JSContextRef, global: *JSGlobalObject) void {
    @import("web_globals.zig").install(allocator, ctx, global);
    @import("bun_global.zig").install(allocator, ctx, global);
    install(allocator, ctx, global);
}

test "Bun.Cookie defaults, options, serialize, parse, isExpired" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealm(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function() {" ++
        "  var c = new Bun.Cookie('name', 'value');" ++
        "  if (c.name !== 'name' || c.value !== 'value' || c.path !== '/' || c.domain !== null) return false;" ++
        "  if (c.secure || c.httpOnly || c.partitioned || c.sameSite !== 'lax') return false;" ++
        "  var c2 = new Bun.Cookie('name', 'value', { domain: 'example.com', path: '/foo', secure: true, httpOnly: true, partitioned: true, sameSite: 'strict', maxAge: 3600 });" ++
        "  if (c2.toString() !== 'name=value; Domain=example.com; Path=/foo; Max-Age=3600; Secure; HttpOnly; Partitioned; SameSite=Strict') return false;" ++
        "  if (new Bun.Cookie('foo', 'bar').serialize() !== 'foo=bar; Path=/; SameSite=Lax') return false;" ++
        "  var p = Bun.Cookie.parse('name=value; Domain=example.com; Path=/foo; Max-Age=3600; Secure; HttpOnly; Partitioned; SameSite=Strict');" ++
        "  if (p.name !== 'name' || p.value !== 'value' || p.domain !== 'example.com' || p.maxAge !== 3600 || !p.secure || p.sameSite !== 'strict') return false;" ++
        "  if (!new Bun.Cookie('n', 'v', { expires: new Date(Date.now() - 1000) }).isExpired()) return false;" ++
        "  if (new Bun.Cookie('n', 'v', { maxAge: 3600 }).isExpired()) return false;" ++
        "  var fromNum = Bun.Cookie.from('n', 'v', { expires: 1625097600 });" ++
        "  if (fromNum.expires.getTime() !== 1625097600 * 1000) return false;" ++
        "  var threw = false; try { new Bun.Cookie('n', 'v', { expires: NaN }); } catch (e) { threw = true; }" ++
        "  return threw; })()"));
}

test "Bun.CookieMap from string/object/array + get/set/has/size/toSetCookieHeaders" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealm(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function() {" ++
        "  var m = new Bun.CookieMap('name=value; foo=bar');" ++
        "  if (m.size !== 2 || m.get('name') !== 'value' || m.get('foo') !== 'bar') return false;" ++
        "  if (m.toSetCookieHeaders().length !== 0) return false;" ++ // parsed-only -> no Set-Cookie
        "  var mo = new Bun.CookieMap({ a: '1', b: '2' });" ++
        "  if (mo.size !== 2 || mo.get('a') !== '1') return false;" ++
        "  var ma = new Bun.CookieMap([['x', 'y']]);" ++
        "  if (ma.get('x') !== 'y') return false;" ++
        "  var e = new Bun.CookieMap();" ++
        "  e.set('k', 'v');" ++
        "  if (e.size !== 1 || !e.has('k') || e.get('k') !== 'v') return false;" ++
        "  var hdrs = e.toSetCookieHeaders();" ++
        "  if (hdrs.length !== 1 || hdrs[0] !== 'k=v; Path=/; SameSite=Lax') return false;" ++
        "  return e.delete('k') === true && e.has('k') === false; })()"));
}
