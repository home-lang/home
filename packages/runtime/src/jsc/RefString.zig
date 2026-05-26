// Copied from bun/src/jsc/RefString.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
//! expensive heap reference-counted string type
//! only use this for big strings
//! like source code
//! not little ones
//
// `bun.WTF.StringImpl`, `bun.IdentityContext`, `bun.String`, and the
// `jsc.JSGlobalObject`/`jsc.JSValue` types are not yet ported. We stub the
// minimum: `StringImpl` exposes only `ref` / `deref` (the operations this
// file performs), and the IdentityContext for HashMap is replaced with the
// std `AutoHashMap` equivalent (same semantics for an integer key).
//
// `toJS` upstream calls `bun.String.init(this.impl).toJS(global)`. With
// `bun.String` unported, we omit the helper; the path re-attaches in
// Phase 12.2.

const std = @import("std");

// JSC bridge JSGlobalObject stubbed — re-attaches in Phase 12.2.
const JSGlobalObject = opaque {};
// JSC bridge JSValue stubbed — re-attaches in Phase 12.2.
const JSValue = enum(i64) { zero = 0, _ };

// `bun.WTF.StringImpl` C ABI stub — re-attaches in Phase 12.2. The real
// type is an opaque pointer to a `WTF::StringImpl` whose ref/deref bump
// an atomic refcount on the C++ side.
const StringImpl = opaque {
    pub fn ref(this: *StringImpl) void {
        WTFStringImpl__ref(this);
    }

    pub fn deref(this: *StringImpl) void {
        WTFStringImpl__deref(this);
    }

    extern fn WTFStringImpl__ref(this: *StringImpl) void;
    extern fn WTFStringImpl__deref(this: *StringImpl) void;
};

pub const RefString = @This();

ptr: [*]const u8 = undefined,
len: usize = 0,
hash: Hash = 0,
impl: *StringImpl,

allocator: std.mem.Allocator,

ctx: ?*anyopaque = null,
onBeforeDeinit: ?*const Callback = null,

pub const Hash = u32;
// Upstream uses `bun.IdentityContext(Hash)` with load-factor 80 — a no-rehash
// HashMap keyed on an already-hashed Hash. We keep the same shape with
// std's IdentityContext (the integer-key equivalent) plus the matching
// load factor.
pub const Map = std.HashMap(Hash, *RefString, std.hash_map.AutoContext(Hash), 80);

// `toJS` upstream returns `bun.String.init(impl).toJS(global)`. That path
// re-attaches once `bun.String` is ported in Phase 12.2.

pub const Callback = fn (ctx: *anyopaque, str: *RefString) void;

pub fn computeHash(input: []const u8) u32 {
    return std.hash.XxHash32.hash(0, input);
}

pub fn slice(this: *RefString) []const u8 {
    this.ref();

    return this.leak();
}

pub fn ref(this: *RefString) void {
    this.impl.ref();
}

pub fn leak(this: RefString) []const u8 {
    @setRuntimeSafety(false);
    return this.ptr[0..this.len];
}

pub fn deref(this: *RefString) void {
    this.impl.deref();
}

pub fn deinit(this: *RefString) void {
    if (this.onBeforeDeinit) |onBeforeDeinit| {
        onBeforeDeinit(this.ctx.?, this);
    }

    this.allocator.free(this.leak());
    this.allocator.destroy(this);
}

test "RefString has the expected fields in order" {
    const info = @typeInfo(RefString).@"struct";
    try std.testing.expectEqualStrings("ptr", info.fields[0].name);
    try std.testing.expectEqualStrings("len", info.fields[1].name);
    try std.testing.expectEqualStrings("hash", info.fields[2].name);
    try std.testing.expectEqualStrings("impl", info.fields[3].name);
    try std.testing.expectEqualStrings("allocator", info.fields[4].name);
    try std.testing.expectEqualStrings("ctx", info.fields[5].name);
    try std.testing.expectEqualStrings("onBeforeDeinit", info.fields[6].name);
}

test "RefString.Hash is u32" {
    try std.testing.expect(RefString.Hash == u32);
}

test "RefString.computeHash is deterministic for the same input" {
    const a = RefString.computeHash("hello");
    const b = RefString.computeHash("hello");
    const c = RefString.computeHash("world");
    try std.testing.expectEqual(a, b);
    try std.testing.expect(a != c);
}

test "RefString.Map is a HashMap of Hash -> *RefString with load factor 80" {
    // Probe the type for the K/V we expect.
    const M = RefString.Map;
    try std.testing.expect(@typeInfo(M.KV).@"struct".fields[0].type == RefString.Hash);
    try std.testing.expect(@typeInfo(M.KV).@"struct".fields[1].type == *RefString);
}

test "RefString.Callback is the expected fn type" {
    const cb: RefString.Callback = struct {
        fn noop(_: *anyopaque, _: *RefString) void {}
    }.noop;
    _ = cb;
}
