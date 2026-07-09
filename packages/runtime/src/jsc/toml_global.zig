// Native `Bun.TOML.parse` for the eval/run realm, backed by Home's own TOML
// parser (`packages/toml`). The parser builds a Value tree; we serialize it to
// JSON in Zig and `JSON.parse` it on the JS side, so no internal JSValue bridge
// is needed. comptime-gated on `enable_jsc`.

const std = @import("std");
const bun = @import("bun");
const build_options = @import("build_options");
const evaluate = @import("evaluate.zig");
const callback = @import("callback.zig");
const extern_fns = @import("extern_fns.zig");
const opaques = @import("opaques.zig");
const toml = @import("toml_parser.zig");

const JSValue = opaques.JSValue;
const JSContextRef = opaques.JSContextRef;
const JSObject = opaques.JSObject;
const JSGlobalObject = opaques.JSGlobalObject;

const Buf = std.array_list.Managed(u8);
// Explicit error set so the mutually-recursive jsonValue/jsonTable don't form
// an inferred-error-set dependency loop.
const JsonError = error{ OutOfMemory, NoSpaceLeft, WriteFailed };

fn jsonString(out: *Buf, s: []const u8) JsonError!void {
    try out.append('"');
    for (s) |ch| {
        switch (ch) {
            '"' => try out.appendSlice("\\\""),
            '\\' => try out.appendSlice("\\\\"),
            '\n' => try out.appendSlice("\\n"),
            '\r' => try out.appendSlice("\\r"),
            '\t' => try out.appendSlice("\\t"),
            0x08 => try out.appendSlice("\\b"),
            0x0c => try out.appendSlice("\\f"),
            else => {
                if (ch < 0x20) {
                    var buf: [8]u8 = undefined;
                    const hex = try std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{ch});
                    try out.appendSlice(hex);
                } else {
                    try out.append(ch);
                }
            },
        }
    }
    try out.append('"');
}

fn jsonNum(out: *Buf, comptime fmt: []const u8, value: anytype) JsonError!void {
    var buf: [64]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, fmt, .{value});
    try out.appendSlice(s);
}

fn jsonDateTime(out: *Buf, dt: toml.DateTime) JsonError!void {
    // Serialize as an ISO-ish string token (JSON has no date type).
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    dt.format(&w) catch {};
    try jsonString(out, w.buffered());
}

fn jsonValue(out: *Buf, v: toml.Value) JsonError!void {
    switch (v) {
        .string => |s| try jsonString(out, s),
        .integer => |i| try jsonNum(out, "{d}", i),
        .float => |f| try jsonNum(out, "{d}", f),
        .boolean => |b| try out.appendSlice(if (b) "true" else "false"),
        .datetime => |dt| try jsonDateTime(out, dt),
        .array => |arr| {
            try out.append('[');
            for (arr, 0..) |item, idx| {
                if (idx > 0) try out.append(',');
                try jsonValue(out, item);
            }
            try out.append(']');
        },
        .table => |t| try jsonTable(out, t),
    }
}

fn jsonTable(out: *Buf, t: toml.Table) JsonError!void {
    try out.append('{');
    var it = t.entries.iterator();
    var first = true;
    while (it.next()) |entry| {
        if (!first) try out.append(',');
        first = false;
        try jsonString(out, entry.key_ptr.*);
        try out.append(':');
        try jsonValue(out, entry.value_ptr.*);
    }
    try out.append('}');
}

/// `__home_toml_parse(text)` -> JSON string, or null on parse error.
fn tomlParseNative(ctx: ?*JSContextRef, function: ?*JSObject, this_object: ?*JSObject, argc: usize, argv: [*c]const ?*JSValue, exception: extern_fns.ExceptionRef) callconv(.c) ?*JSValue {
    _ = function;
    _ = this_object;
    _ = exception;
    const c = ctx orelse return null;
    if (argc < 1) return extern_fns.JSValueMakeNull(c);
    const v = argv[0] orelse return extern_fns.JSValueMakeNull(c);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const str = extern_fns.JSValueToStringCopy(c, v, null) orelse return extern_fns.JSValueMakeNull(c);
    defer extern_fns.JSStringRelease(str);
    const cap = extern_fns.JSStringGetLength(str) * 4 + 1;
    const inbuf = alloc.alloc(u8, cap) catch return extern_fns.JSValueMakeNull(c);
    const written = extern_fns.JSStringGetUTF8CString(str, inbuf.ptr, inbuf.len);
    const input = inbuf[0 .. if (written > 0) written - 1 else 0];

    var parsed = toml.Toml.parse(alloc, input) catch return extern_fns.JSValueMakeNull(c);
    defer parsed.deinit();

    var out = Buf.init(alloc);
    jsonTable(&out, parsed.root) catch return extern_fns.JSValueMakeNull(c);

    const z = bun.dupeZ(alloc, u8, out.items) catch return extern_fns.JSValueMakeNull(c);
    const js = extern_fns.JSStringCreateWithUTF8CString(z.ptr) orelse return extern_fns.JSValueMakeNull(c);
    defer extern_fns.JSStringRelease(js);
    return extern_fns.JSValueMakeString(c, js);
}

const install_glue =
    \\(function() {
    \\  var parseFn = globalThis.__home_toml_parse;
    \\  var TOML = {
    \\    parse: function(text) {
    \\      var json = parseFn(String(text));
    \\      if (json === null || json === undefined) throw new SyntaxError("Invalid TOML");
    \\      return JSON.parse(json);
    \\    },
    \\  };
    \\  if (typeof globalThis.Bun === "object" && globalThis.Bun) globalThis.Bun.TOML = TOML;
    \\  delete globalThis.__home_toml_parse;
    \\})();
;

pub fn install(allocator: std.mem.Allocator, ctx: *JSContextRef, global: *JSGlobalObject) void {
    if (comptime !build_options.enable_jsc) return;
    callback.registerCallback(ctx, global, "__home_toml_parse", tomlParseNative);
    const result = evaluate.evaluateUtf8Detailed(allocator, ctx, install_glue, "home:bun-toml-install", 1) catch return;
    result.deinit(allocator);
}

fn evalBool(allocator: std.mem.Allocator, ctx: *JSContextRef, source: []const u8) !bool {
    const value = (try evaluate.evaluateUtf8(allocator, ctx, source, "home:toml-probe", 1, null)) orelse
        return error.JSEvaluateReturnedNull;
    return extern_fns.JSValueToBoolean(ctx, value);
}

fn installRealm(allocator: std.mem.Allocator, ctx: *JSContextRef, global: *JSGlobalObject) void {
    @import("web_globals.zig").install(allocator, ctx, global);
    @import("bun_global.zig").install(allocator, ctx, global);
    install(allocator, ctx, global);
}

test "Bun.TOML.parse parses tables, arrays, scalars" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealm(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function() {" ++
        "  var t = Bun.TOML.parse('title = \"Home\"\\nport = 8080\\nenabled = true\\npi = 3.14\\n\\n[server]\\nhost = \"localhost\"\\nports = [80, 443]\\n');" ++
        "  if (t.title !== 'Home' || t.port !== 8080 || t.enabled !== true) return false;" ++
        "  if (Math.abs(t.pi - 3.14) > 1e-9) return false;" ++
        "  if (!t.server || t.server.host !== 'localhost') return false;" ++
        "  if (!Array.isArray(t.server.ports) || t.server.ports[0] !== 80 || t.server.ports[1] !== 443) return false;" ++
        "  return true; })()"));
}
