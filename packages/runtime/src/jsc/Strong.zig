// Copied from bun/src/jsc/Strong.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// JSC bridge types (`JSGlobalObject`, `JSValue`, `markBinding`, `DecodedJSValue`)
// are not yet wired into the canonical `home_rt.jsc.*` namespace. Local
// opaque/enum stubs preserve the public surface and the C ABI for the
// `Bun__StrongRef__*` externs — the real JSC bridge re-attaches in Phase 12.2
// once `JSValue` (with `.zero`, `.js_undefined`) and `JSGlobalObject` exist.
//
//! Holds a strong reference to a JS value, protecting it from garbage
//! collection. This type implies there is always a valid value held.
//! For a strong that may be empty (to reuse allocation), use `Strong.Optional`.

const std = @import("std");
const home_rt = @import("home");

const Strong = @This();

// ── local stubs ─────────────────────────────────────────────────────────────
// JSC bridge JSGlobalObject stubbed — re-attaches in Phase 12.2.
const JSGlobalObject = @import("./JSGlobalObject.zig").JSGlobalObject;

// JSC bridge now wired: use the canonical JSValue so Strong handles hold the
// same type the rest of the runtime passes around (and so the GC-protecting
// Bun__StrongRef__* path actually receives the real EncodedJSValue).
pub const JSValue = home_rt.jsc.JSValue;

inline fn markBinding(src: std.builtin.SourceLocation) void {
    _ = src;
}

inline fn allow_assert() bool {
    return home_rt.Environment.allow_assert;
}

// ── Strong ──────────────────────────────────────────────────────────────────

impl: *Impl,

/// Hold a strong reference to a JavaScript value. Release with `deinit` or `clear`
pub fn create(value: JSValue, global: *JSGlobalObject) Strong {
    if (allow_assert()) home_rt.assert(value != .zero);
    return .{ .impl = .init(global, value) };
}

/// Release the strong reference.
pub fn deinit(strong: *Strong) void {
    strong.impl.deinit();
    if (home_rt.Environment.isDebug)
        strong.* = undefined;
}

pub fn get(strong: *const Strong) JSValue {
    const result = strong.impl.get();
    if (allow_assert()) home_rt.assert(result != .zero);
    return result;
}

/// Set a new value for the strong reference.
pub fn set(strong: *Strong, global: *JSGlobalObject, new_value: JSValue) void {
    if (allow_assert()) home_rt.assert(new_value != .zero);
    strong.impl.set(global, new_value);
}

/// Swap a new value for the strong reference.
pub fn swap(strong: *Strong, global: *JSGlobalObject, new_value: JSValue) JSValue {
    const result = strong.impl.get();
    strong.set(global, new_value);
    return result;
}

/// Holds a strong reference to a JS value, protecting it from garbage
/// collection. When not holding a value, the strong may still be allocated.
pub const Optional = struct {
    impl: ?*Impl,

    pub const empty: Optional = .{ .impl = null };

    /// Hold a strong reference to a JavaScript value. Release with `deinit` or `clear`
    pub fn create(value: JSValue, global: *JSGlobalObject) Optional {
        return if (value != .zero)
            .{ .impl = .init(global, value) }
        else
            .empty;
    }

    /// Frees memory for the underlying Strong reference.
    pub fn deinit(strong: *Optional) void {
        const ref: *Impl = strong.impl orelse return;
        strong.* = .empty;
        ref.deinit();
    }

    /// Clears the value, but does not de-allocate the Strong reference.
    pub fn clearWithoutDeallocation(strong: *Optional) void {
        const ref: *Impl = strong.impl orelse return;
        ref.clear();
    }

    pub fn call(this: *Optional, global: *JSGlobalObject, args: []const JSValue) JSValue {
        const function = this.trySwap() orelse return .zero;
        return function.call(global, args);
    }

    pub fn get(this: *const Optional) ?JSValue {
        const impl = this.impl orelse return null;
        const result = impl.get();
        if (result == .zero) {
            return null;
        }
        return result;
    }

    pub fn swap(strong: *Optional) JSValue {
        const impl = strong.impl orelse return .zero;
        const result = impl.get();
        if (result == .zero) {
            return .zero;
        }
        impl.clear();
        return result;
    }

    pub fn has(this: *const Optional) bool {
        var ref = this.impl orelse return false;
        return ref.get() != .zero;
    }

    pub fn trySwap(this: *Optional) ?JSValue {
        const result = this.swap();
        if (result == .zero) {
            return null;
        }

        return result;
    }

    pub fn set(strong: *Optional, global: *JSGlobalObject, value: JSValue) void {
        const ref: *Impl = strong.impl orelse {
            if (value == .zero) return;
            strong.impl = Impl.init(global, value);
            return;
        };
        ref.set(global, value);
    }

    /// Alias of `get()` — some call sites use `.tryGet()` on the optional.
    pub fn tryGet(this: *const Optional) ?JSValue {
        return this.get();
    }

    /// Set a strong reference (creating one if absent). Mirrors the inline
    /// stub's surface that this type replaced.
    pub fn setStrong(this: *Optional, value: JSValue, global: *JSGlobalObject) void {
        this.set(global, value);
    }
};

/// `jsc.Strong.Deprecated` — the legacy strong wrapper a few subsystems still
/// reference (test runner, etc.).
pub const Deprecated = @import("./DeprecatedStrong.zig");

// Test-only weak stubs so that the four `Bun__StrongRef__*` externs link
// when this file is run as a test root. The real symbols live in C++;
// these only resolve in `zig test` builds.
const builtin = @import("builtin");
comptime {
    if (builtin.is_test) {
        @export(&struct {
            fn delete(_: *Impl) callconv(.c) void {}
        }.delete, .{ .name = "Bun__StrongRef__delete", .linkage = .weak });
        @export(&struct {
            fn new(_: *JSGlobalObject, _: JSValue) callconv(.c) *Impl {
                return @ptrFromInt(@alignOf(usize));
            }
        }.new, .{ .name = "Bun__StrongRef__new", .linkage = .weak });
        @export(&struct {
            fn set(_: *Impl, _: *JSGlobalObject, _: JSValue) callconv(.c) void {}
        }.set, .{ .name = "Bun__StrongRef__set", .linkage = .weak });
        @export(&struct {
            fn clear(_: *Impl) callconv(.c) void {}
        }.clear, .{ .name = "Bun__StrongRef__clear", .linkage = .weak });
    }
}

pub const Impl = opaque {
    pub fn init(global: *JSGlobalObject, value: JSValue) *Impl {
        markBinding(@src());
        return Bun__StrongRef__new(global, value);
    }

    pub fn get(this: *Impl) JSValue {
        // `this` is actually a pointer to a `JSC::JSValue`; see Strong.cpp.
        // The upstream port decodes via `DecodedJSValue`; we round-trip via
        // the raw `i64` tag while the DecodedJSValue.encode shim stays parked.
        const js_value: *align(@alignOf(JSValue)) i64 = @ptrCast(@alignCast(this));
        return @enumFromInt(js_value.*);
    }

    pub fn set(this: *Impl, global: *JSGlobalObject, value: JSValue) void {
        markBinding(@src());
        Bun__StrongRef__set(this, global, value);
    }

    pub fn clear(this: *Impl) void {
        markBinding(@src());
        Bun__StrongRef__clear(this);
    }

    pub fn deinit(this: *Impl) void {
        markBinding(@src());
        Bun__StrongRef__delete(this);
    }

    extern fn Bun__StrongRef__delete(this: *Impl) void;
    extern fn Bun__StrongRef__new(*JSGlobalObject, JSValue) *Impl;
    extern fn Bun__StrongRef__set(this: *Impl, *JSGlobalObject, JSValue) void;
    extern fn Bun__StrongRef__clear(this: *Impl) void;
};

// `pub const Deprecated = @import("./DeprecatedStrong.zig");` is intentionally
// omitted — the Deprecated namespace re-exports through
// `home_rt.jsc.Strong.Deprecated` directly. Reintroducing the import here
// trips `file exists in modules 'root' and 'home_rt'` when this file is
// run as a test root.

test "Strong.Optional.empty starts null" {
    const opt: Optional = .empty;
    try std.testing.expect(opt.impl == null);
    try std.testing.expect(!opt.has());
}

test "JSValue sentinels" {
    try std.testing.expect(JSValue.zero != JSValue.js_undefined);
    try std.testing.expectEqual(@as(i64, 0), @intFromEnum(JSValue.zero));
}
