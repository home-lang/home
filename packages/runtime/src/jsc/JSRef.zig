// Copied from bun/src/jsc/JSRef.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// `JSGlobalObject` and `jsc.JSValue` are not yet wired into the canonical
// `home_rt.jsc.*` namespace. We re-use the `JSValue` stub from `Strong.zig`
// (and its `Optional` Strong wrapper) so `JSRef` shares one stub surface.
// The JSC bridge re-attaches in Phase 12.2.

const std = @import("std");
const home_rt = @import("home");
const Strong = home_rt.jsc.Strong;

const JSGlobalObject = home_rt.jsc.JSGlobalObject;
const JSValue = home_rt.jsc.JSValue;

// JSValue capability shims used by upstream code. The real JSValue exposes
// these on the C++ side via `isEmptyOrUndefinedOrNull`. While JSValue is a
// stub enum, we approximate using only the `.zero` / `.js_undefined`
// sentinels — anything else is treated as live.
inline fn isEmptyOrUndefinedOrNull(v: JSValue) bool {
    return v == .zero or v == .js_undefined;
}

/// Holds a reference to a JSValue with lifecycle management.
///
/// JSRef is used to safely maintain a reference to a JavaScript object from native code,
/// with explicit control over whether the reference keeps the object alive during garbage collection.
///
/// # States
///
/// - **weak**: Holds a JSValue directly. Does NOT prevent garbage collection.
///   The JSValue may become invalid if the object is collected.
///   Use `tryGet()` to safely check if the value is still alive.
///
/// - **strong**: Holds a Strong reference that prevents garbage collection.
///   The JavaScript object will stay alive as long as this reference exists.
///   Must call `deinit()` or `finalize()` to release.
///
/// - **finalized**: The reference has been finalized (object was GC'd or explicitly cleaned up).
///   Indicates the JSValue is no longer valid. `tryGet()` returns null.
pub const JSRef = union(enum) {
    weak: JSValue,
    strong: Strong.Optional,
    finalized: void,

    pub fn initWeak(value: JSValue) @This() {
        home_rt.assert(!isEmptyOrUndefinedOrNull(value));
        return .{ .weak = value };
    }

    pub fn initStrong(value: JSValue, globalThis: *JSGlobalObject) @This() {
        home_rt.assert(!isEmptyOrUndefinedOrNull(value));
        return .{ .strong = .create(value, @ptrCast(globalThis)) };
    }

    pub fn empty() @This() {
        return .{ .weak = .js_undefined };
    }

    pub fn tryGet(this: *const @This()) ?JSValue {
        return switch (this.*) {
            .weak => if (isEmptyOrUndefinedOrNull(this.weak)) null else this.weak,
            .strong => this.strong.get(),
            .finalized => null,
        };
    }

    pub fn setWeak(this: *@This(), value: JSValue) void {
        home_rt.assert(!isEmptyOrUndefinedOrNull(value));
        switch (this.*) {
            .weak => {},
            .strong => {
                this.strong.deinit();
            },
            .finalized => {
                return;
            },
        }
        this.* = .{ .weak = value };
    }

    pub fn setStrong(this: *@This(), value: JSValue, globalThis: *JSGlobalObject) void {
        home_rt.assert(!isEmptyOrUndefinedOrNull(value));
        if (this.* == .strong) {
            this.strong.set(@ptrCast(globalThis), value);
            return;
        }
        this.* = .{ .strong = .create(value, @ptrCast(globalThis)) };
    }

    pub fn upgrade(this: *@This(), globalThis: *JSGlobalObject) void {
        switch (this.*) {
            .weak => {
                home_rt.assert(!isEmptyOrUndefinedOrNull(this.weak));
                const weak = this.weak;
                this.* = .{ .strong = .create(weak, @ptrCast(globalThis)) };
            },
            .strong => {},
            .finalized => {
                if (home_rt.Environment.isDebug) home_rt.assert(false);
            },
        }
    }

    pub fn downgrade(this: *@This()) void {
        switch (this.*) {
            .weak => {},
            .strong => |*strong| {
                const value = strong.trySwap() orelse .js_undefined;
                value.ensureStillAlive();
                strong.deinit();
                this.* = .{ .weak = value };
            },
            .finalized => {},
        }
    }

    pub fn isEmpty(this: *const @This()) bool {
        return switch (this.*) {
            .weak => isEmptyOrUndefinedOrNull(this.weak),
            .strong => !this.strong.has(),
            .finalized => true,
        };
    }

    pub fn isNotEmpty(this: *const @This()) bool {
        return switch (this.*) {
            .weak => !isEmptyOrUndefinedOrNull(this.weak),
            .strong => this.strong.has(),
            .finalized => false,
        };
    }

    /// Test whether this reference is a strong reference.
    pub fn isStrong(this: *const @This()) bool {
        return this.* == .strong;
    }

    pub fn deinit(this: *@This()) void {
        switch (this.*) {
            .weak => {
                this.weak = .js_undefined;
            },
            .strong => {
                this.strong.deinit();
            },
            .finalized => {},
        }
    }

    pub fn finalize(this: *@This()) void {
        this.deinit();
        this.* = .{ .finalized = {} };
    }

    pub fn update(this: *@This(), globalThis: *JSGlobalObject, value: JSValue) void {
        switch (this.*) {
            .weak => {
                if (home_rt.Environment.isDebug) home_rt.assert(!isEmptyOrUndefinedOrNull(value));
                this.weak = value;
            },
            .strong => {
                if (this.strong.get() != value) {
                    this.strong.set(@ptrCast(globalThis), value);
                }
            },
            .finalized => {
                if (home_rt.Environment.isDebug) home_rt.assert(false);
            },
        }
    }
};

test "JSRef.empty produces a weak js_undefined" {
    const ref = JSRef.empty();
    try std.testing.expect(ref == .weak);
    try std.testing.expect(ref.isEmpty());
    try std.testing.expect(!ref.isNotEmpty());
    try std.testing.expect(!ref.isStrong());
}

test "JSRef.finalize sets the finalized variant" {
    var ref = JSRef.empty();
    ref.finalize();
    try std.testing.expect(ref == .finalized);
    try std.testing.expect(ref.isEmpty());
    try std.testing.expect(ref.tryGet() == null);
}
