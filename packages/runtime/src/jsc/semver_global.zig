// Native `Bun.semver` for the eval/run realm — `satisfies` and `order`, backed
// by Home's own semver engine (`semver.Version` / `semver.Query`), the same one
// behind the native SemverObject. Mirrors src/semver_jsc/SemverObject.zig.
//
//   Bun.semver.satisfies(version, range) -> boolean
//   Bun.semver.order(a, b)               -> -1 | 0 | 1   (throws on invalid)
//
// comptime-gated on `enable_jsc`.

const std = @import("std");
const build_options = @import("build_options");
const evaluate = @import("evaluate.zig");
const callback = @import("callback.zig");
const extern_fns = @import("extern_fns.zig");
const opaques = @import("opaques.zig");
const semver = @import("../semver/semver.zig");

const Version = semver.Version;
const Query = semver.Query;
const SlicedString = semver.SlicedString;

const JSValue = opaques.JSValue;
const JSContextRef = opaques.JSContextRef;
const JSObject = opaques.JSObject;
const JSGlobalObject = opaques.JSGlobalObject;

fn argToOwnedUtf8(ctx: *JSContextRef, value: *JSValue, allocator: std.mem.Allocator) ?[]u8 {
    const string = extern_fns.JSValueToStringCopy(ctx, value, null) orelse return null;
    defer extern_fns.JSStringRelease(string);
    const capacity = extern_fns.JSStringGetLength(string) * 4 + 1;
    const buf = allocator.alloc(u8, capacity) catch return null;
    const written = extern_fns.JSStringGetUTF8CString(string, buf.ptr, buf.len);
    return buf[0 .. if (written > 0) written - 1 else 0];
}

fn isAscii(s: []const u8) bool {
    for (s) |c| if (c > 127) return false;
    return true;
}

/// `__home_semver(op, a, b)` — op 0 = order (-1/0/1, or -2 sentinel for invalid),
/// op 1 = satisfies (boolean).
fn semverNative(ctx: ?*JSContextRef, function: ?*JSObject, this_object: ?*JSObject, argc: usize, argv: [*c]const ?*JSValue, exception: extern_fns.ExceptionRef) callconv(.c) ?*JSValue {
    _ = function;
    _ = this_object;
    _ = exception;
    const c = ctx orelse return null;
    if (argc < 3) return extern_fns.JSValueMakeNull(c);
    const op: u8 = @intFromFloat(extern_fns.JSValueToNumber(c, argv[0].?, null));

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const a = argToOwnedUtf8(c, argv[1].?, alloc) orelse return extern_fns.JSValueMakeNull(c);
    const b = argToOwnedUtf8(c, argv[2].?, alloc) orelse return extern_fns.JSValueMakeNull(c);

    if (op == 0) {
        if (!isAscii(a) or !isAscii(b)) return extern_fns.JSValueMakeNumber(c, 0);
        const lr = Version.parse(SlicedString.init(a, a));
        const rr = Version.parse(SlicedString.init(b, b));
        if (!lr.valid or !rr.valid) return extern_fns.JSValueMakeNumber(c, -2);
        const lv = lr.version.max();
        const rv = rr.version.max();
        return extern_fns.JSValueMakeNumber(c, switch (lv.orderWithoutBuild(rv, a, b)) {
            .eq => 0,
            .gt => 1,
            .lt => -1,
        });
    }

    // satisfies
    if (!isAscii(a) or !isAscii(b)) return extern_fns.JSValueMakeBoolean(c, false);
    const lr = Version.parse(SlicedString.init(a, a));
    if (lr.wildcard != .none) return extern_fns.JSValueMakeBoolean(c, false);
    const lv = lr.version.min();
    const group = Query.parse(alloc, b, SlicedString.init(b, b)) catch return extern_fns.JSValueMakeBoolean(c, false);
    defer group.deinit();
    if (group.getExactVersion()) |ev| return extern_fns.JSValueMakeBoolean(c, lv.eql(ev));
    return extern_fns.JSValueMakeBoolean(c, group.satisfies(lv, b, a));
}

const install_glue =
    \\(function() {
    \\  var semverFn = globalThis.__home_semver;
    \\  function toStr(v) {
    \\    if (typeof v === "string") return v;
    \\    if (v instanceof Uint8Array) return new TextDecoder().decode(v);
    \\    if (ArrayBuffer.isView(v)) return new TextDecoder().decode(new Uint8Array(v.buffer, v.byteOffset, v.byteLength));
    \\    if (v instanceof ArrayBuffer) return new TextDecoder().decode(new Uint8Array(v));
    \\    return String(v);
    \\  }
    \\  var semver = {
    \\    satisfies: function(version, range) { return semverFn(1, toStr(version), toStr(range)); },
    \\    order: function(a, b) { var r = semverFn(0, toStr(a), toStr(b)); if (r === -2) throw new Error("Invalid SemVer"); return r; },
    \\  };
    \\  if (typeof globalThis.Bun === "object" && globalThis.Bun) globalThis.Bun.semver = semver;
    \\  delete globalThis.__home_semver;
    \\})();
;

pub fn install(allocator: std.mem.Allocator, ctx: *JSContextRef, global: *JSGlobalObject) void {
    if (comptime !build_options.enable_jsc) return;
    callback.registerCallback(ctx, global, "__home_semver", semverNative);
    const result = evaluate.evaluateUtf8Detailed(allocator, ctx, install_glue, "home:bun-semver-install", 1) catch return;
    result.deinit(allocator);
}

fn evalBool(allocator: std.mem.Allocator, ctx: *JSContextRef, source: []const u8) !bool {
    const value = (try evaluate.evaluateUtf8(allocator, ctx, source, "home:semver-probe", 1, null)) orelse
        return error.JSEvaluateReturnedNull;
    return extern_fns.JSValueToBoolean(ctx, value);
}

fn installRealm(allocator: std.mem.Allocator, ctx: *JSContextRef, global: *JSGlobalObject) void {
    @import("web_globals.zig").install(allocator, ctx, global);
    @import("bun_global.zig").install(allocator, ctx, global);
    // node_modules supplies `globalThis.Buffer`; Bun.semver accepts Buffer args.
    @import("node_modules.zig").install(allocator, ctx, global);
    install(allocator, ctx, global);
}

test "Bun.semver.satisfies + order (native engine)" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealm(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function() {" ++
        "  var s = Bun.semver;" ++
        "  if (!s.satisfies('1.2.3', '^1.0.0')) return false;" ++
        "  if (s.satisfies('2.0.0', '^1.0.0')) return false;" ++
        "  if (!s.satisfies('1.2.3', '~1.2.0')) return false;" ++
        "  if (!s.satisfies('1.2.3', '>=1.0.0 <2.0.0')) return false;" ++
        "  if (!s.satisfies('1.2.3', '1.2.3')) return false;" ++
        "  if (!s.satisfies('1.2.3', '*')) return false;" ++
        "  if (s.order('1.2.3', '1.2.4') !== -1) return false;" ++
        "  if (s.order('2.0.0', '1.9.9') !== 1) return false;" ++
        "  if (s.order('1.2.3', '1.2.3') !== 0) return false;" ++
        "  if (s.order('1.2.3', '\\n1.2.3') !== 0) return false;" ++ // whitespace tolerance
        // Buffer inputs accepted
        "  if (!s.satisfies(Buffer.from('1.2.3'), Buffer.from('^1.0.0'))) return false;" ++
        "  var threw = false; try { s.order('not-a-version', '1.2.3'); } catch (e) { threw = true; }" ++
        "  return threw; })()"));
}
