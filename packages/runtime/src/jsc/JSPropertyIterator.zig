// Copied from bun/src/jsc/JSPropertyIterator.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Generic property-iterator over a `JSC::JSObject`. The implementation hops
// through `Bun__JSPropertyIterator__*` extern fns to materialise property
// names (optionally with values) one at a time, skipping holes and (when
// asked) empty-string keys.
//
// The shape is `JSPropertyIterator(comptime options: JSPropertyIteratorOptions)`,
// matching upstream — call sites parameterise the iterator with the four
// option bools and get a struct back.
//
// `JSGlobalObject`, `JSObject`, `JSValue`, and `bun.String` are not yet
// ported (Phase 12.2). Local stubs preserve the C ABI. The Top-exception
// scope guards re-use the ported `home_rt.jsc.TopExceptionScope`.

const std = @import("std");
const home_rt = @import("home_rt");
const TopExceptionScope = home_rt.jsc.TopExceptionScope;

// JSC bridge stubs — re-attach in Phase 12.2.
const JSGlobalObject = opaque {};
const JSObject = opaque {
    /// Real upstream: `*JSObject -> JSValue` cell-pointer cast. Until the
    /// real JSValue is ported we hand back the opaque pointer cast to the
    /// stub `JSValue` enum so the call site compiles.
    pub fn toJS(this: *JSObject) JSValue {
        return @enumFromInt(@as(i64, @bitCast(@as(u64, @intCast(@intFromPtr(this))))));
    }
    /// Real upstream: pins the JSC cell via the conservative roots scan. The
    /// debug-only sanity check re-attaches in Phase 12.2; here it's a no-op
    /// so call sites compile.
    pub fn ensureStillAlive(_: *JSObject) void {}
};
const JSValue = enum(i64) { zero = 0, _ };

/// `bun.String` C ABI stub. Real layout `{tag: u8, _padding: 7 bytes, impl: *anyopaque}`.
/// Only the tag is meaningful here (callers compare against `.Dead`).
const String = extern struct {
    tag: u8 = 0,
    _padding: [7]u8 = @splat(0),
    impl: ?*anyopaque = null,

    pub const Tag = enum(u8) { Dead = 0, _ };

    /// Sentinel for "no value bound". Upstream spells this as
    /// `bun.String.dead`; we keep the name so the loop body reads naturally.
    pub const dead: String = .{};

    /// Stub for `name.isEmpty()`. Real impl peers into the WTFStringImpl;
    /// re-attaches in Phase 12.2 once the bun.String runtime lands.
    pub fn isEmpty(_: String) bool {
        return false;
    }
};

pub const JSPropertyIteratorOptions = struct {
    skip_empty_name: bool,
    include_value: bool,
    own_properties_only: bool = true,
    observable: bool = true,
    only_non_index_properties: bool = false,
};

pub fn JSPropertyIterator(comptime options: JSPropertyIteratorOptions) type {
    return struct {
        len: usize = 0,
        i: u32 = 0,
        iter_i: u32 = 0,
        /// null if and only if `object` has no properties (i.e. `len == 0`).
        impl: ?*JSPropertyIteratorImpl = null,

        globalObject: *JSGlobalObject,
        object: *JSObject,
        /// Current property being yielded.
        value: JSValue = .zero,

        pub fn getLongestPropertyName(this: *@This()) usize {
            return if (this.impl) |iter|
                iter.getLongestPropertyName(this.globalObject, this.object)
            else
                0;
        }

        pub fn deinit(this: *@This()) void {
            if (this.impl) |impl| impl.deinit();
            this.* = undefined;
        }

        /// `object` should be a `JSC::JSObject`. Non-objects will be runtime-converted.
        pub fn init(globalObject: *JSGlobalObject, object: *JSObject) error{JSError}!@This() {
            var len: usize = 0;
            object.ensureStillAlive();
            const impl = try JSPropertyIteratorImpl.init(
                globalObject,
                object,
                &len,
                options.own_properties_only,
                options.only_non_index_properties,
            );
            if (home_rt.Environment.allow_assert) {
                if (len > 0) {
                    std.debug.assert(impl != null);
                } else {
                    std.debug.assert(impl == null);
                }
            }

            return .{
                .object = object,
                .globalObject = globalObject,
                .impl = impl,
                .len = len,
            };
        }

        pub fn reset(this: *@This()) void {
            this.iter_i = 0;
            this.i = 0;
        }

        /// The `String` returned has not incremented its reference count.
        pub fn next(this: *@This()) !?String {
            while (true) {
                const i: usize = this.iter_i;
                if (i >= this.len) {
                    this.i = this.iter_i;
                    return null;
                }

                this.i = this.iter_i;
                this.iter_i += 1;
                var name = String.dead;
                if (comptime options.include_value) {
                    const FnToUse = if (options.observable)
                        JSPropertyIteratorImpl.getNameAndValue
                    else
                        JSPropertyIteratorImpl.getNameAndValueNonObservable;
                    const current: JSValue = try FnToUse(this.impl.?, this.globalObject, this.object, &name, i);
                    if (current == .zero) continue;
                    // Real `current.ensureStillAlive()` re-attaches in Phase 12.2.
                    this.value = current;
                } else {
                    // Exception check is unnecessary here because it won't throw.
                    this.impl.?.getName(&name, i);
                }

                if (name.tag == @intFromEnum(String.Tag.Dead)) {
                    continue;
                }

                if (comptime options.skip_empty_name) {
                    if (name.isEmpty()) {
                        continue;
                    }
                }

                return name;
            }

            unreachable;
        }
    };
}

const JSPropertyIteratorImpl = opaque {
    pub fn init(
        globalObject: *JSGlobalObject,
        object: *JSObject,
        count: *usize,
        own_properties_only: bool,
        only_non_index_properties: bool,
    ) error{JSError}!?*JSPropertyIteratorImpl {
        // Upstream uses `home_rt.jsc.fromJSHostCallGeneric` to drive the
        // exception-validation handshake around the call. That helper is part
        // of the still-unported JSC binding-recorder surface; for now we call
        // through directly and re-attach the wrapper in Phase 12.2.
        return Bun__JSPropertyIterator__create(
            globalObject,
            object.toJS(),
            count,
            own_properties_only,
            only_non_index_properties,
        );
    }

    pub const deinit = Bun__JSPropertyIterator__deinit;

    pub fn getNameAndValue(
        iter: *JSPropertyIteratorImpl,
        globalObject: *JSGlobalObject,
        object: *JSObject,
        propertyName: *String,
        i: usize,
    ) error{JSError}!JSValue {
        var scope: TopExceptionScope = undefined;
        scope.init(globalObject, @src());
        defer scope.deinit();
        const value = Bun__JSPropertyIterator__getNameAndValue(iter, globalObject, object, propertyName, i);
        try scope.returnIfException();
        return value;
    }

    pub fn getNameAndValueNonObservable(
        iter: *JSPropertyIteratorImpl,
        globalObject: *JSGlobalObject,
        object: *JSObject,
        propertyName: *String,
        i: usize,
    ) error{JSError}!JSValue {
        var scope: TopExceptionScope = undefined;
        scope.init(globalObject, @src());
        defer scope.deinit();
        const value = Bun__JSPropertyIterator__getNameAndValueNonObservable(iter, globalObject, object, propertyName, i);
        try scope.returnIfException();
        return value;
    }

    pub const getName = Bun__JSPropertyIterator__getName;

    pub const getLongestPropertyName = Bun__JSPropertyIterator__getLongestPropertyName;

    /// May return null without an exception.
    extern "c" fn Bun__JSPropertyIterator__create(globalObject: *JSGlobalObject, encodedValue: JSValue, count: *usize, own_properties_only: bool, only_non_index_properties: bool) ?*JSPropertyIteratorImpl;
    extern "c" fn Bun__JSPropertyIterator__getNameAndValue(iter: *JSPropertyIteratorImpl, globalObject: *JSGlobalObject, object: *JSObject, propertyName: *String, i: usize) JSValue;
    extern "c" fn Bun__JSPropertyIterator__getNameAndValueNonObservable(iter: *JSPropertyIteratorImpl, globalObject: *JSGlobalObject, object: *JSObject, propertyName: *String, i: usize) JSValue;
    extern "c" fn Bun__JSPropertyIterator__getName(iter: *JSPropertyIteratorImpl, propertyName: *String, i: usize) void;
    extern "c" fn Bun__JSPropertyIterator__deinit(iter: *JSPropertyIteratorImpl) void;
    extern "c" fn Bun__JSPropertyIterator__getLongestPropertyName(iter: *JSPropertyIteratorImpl, globalObject: *JSGlobalObject, object: *JSObject) usize;
};

test "JSPropertyIteratorOptions has the expected defaults" {
    const opt: JSPropertyIteratorOptions = .{
        .skip_empty_name = false,
        .include_value = false,
    };
    try std.testing.expect(opt.own_properties_only);
    try std.testing.expect(opt.observable);
    try std.testing.expect(!opt.only_non_index_properties);
}

test "JSPropertyIterator yields a struct type" {
    const Iter = JSPropertyIterator(.{ .skip_empty_name = true, .include_value = true });
    try std.testing.expect(@hasDecl(Iter, "init"));
    try std.testing.expect(@hasDecl(Iter, "next"));
    try std.testing.expect(@hasDecl(Iter, "deinit"));
    try std.testing.expect(@hasDecl(Iter, "reset"));
    try std.testing.expect(@hasDecl(Iter, "getLongestPropertyName"));
}

test "JSPropertyIteratorImpl is opaque" {
    try std.testing.expect(@sizeOf(*JSPropertyIteratorImpl) == @sizeOf(usize));
}
