// Copied from bun/src/jsc/JSFunction.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// Imports rewritten: @import("bun") → @import("home").

pub const JSFunction = opaque {
    const ImplementationVisibility = enum(u8) {
        public,
        private,
        private_recursive,
    };

    /// In WebKit: Intrinsic.h
    const Intrinsic = enum(u8) {
        none,
        _,
    };

    const CreateJSFunctionOptions = struct {
        implementation_visibility: ImplementationVisibility = .public,
        intrinsic: Intrinsic = .none,
        constructor: ?*const JSHostFn = null,
    };

    extern fn JSFunction__createFromZig(
        global: *JSGlobalObject,
        fn_name: bun.String,
        implementation: *const JSHostFn,
        arg_count: u32,
        implementation_visibility: ImplementationVisibility,
        intrinsic: Intrinsic,
        constructor: ?*const JSHostFn,
    ) JSValue;

    pub fn create(
        global: *JSGlobalObject,
        fn_name: anytype,
        comptime implementation: anytype,
        function_length: u32,
        options: CreateJSFunctionOptions,
    ) JSValue {
        return JSFunction__createFromZig(
            global,
            switch (@TypeOf(fn_name)) {
                bun.String => fn_name,
                else => bun.String.init(fn_name),
            },
            switch (@TypeOf(implementation)) {
                jsc.JSHostFnZig => jsc.toJSHostFn(implementation),
                jsc.JSHostFn => implementation,
                else => coerceHostFn(implementation),
            },
            function_length,
            options.implementation_visibility,
            options.intrinsic,
            options.constructor,
        );
    }

    pub extern fn JSC__JSFunction__optimizeSoon(value: JSValue) void;
    pub fn optimizeSoon(value: JSValue) void {
        JSC__JSFunction__optimizeSoon(value);
    }

    extern fn JSC__JSFunction__getSourceCode(value: JSValue, out: *ZigString) bool;

    pub fn getSourceCode(value: JSValue) ?bun.String {
        var str: ZigString = undefined;
        return if (JSC__JSFunction__getSourceCode(value, &str)) bun.String.init(str) else null;
    }
};

fn coerceHostFn(comptime implementation: anytype) *const JSHostFn {
    const Fn = @TypeOf(implementation);
    const info = switch (@typeInfo(Fn)) {
        .pointer => |ptr| @typeInfo(ptr.child),
        else => @typeInfo(Fn),
    };
    if (info != .@"fn") return unsupportedHostFn;

    const fn_info = info.@"fn";
    if (fn_info.param_types.len != 2) {
        return unsupportedHostFn;
    }

    const Return = fn_info.return_type.?;
    if (Return == JSValue and
        fn_info.params[0].type.? == *JSGlobalObject and
        fn_info.params[1].type.? == *jsc.CallFrame)
    {
        return implementation;
    }

    return struct {
        pub fn wrapper(globalThis: *JSGlobalObject, callframe: *jsc.CallFrame) callconv(jsc.conv) JSValue {
            const P0 = fn_info.params[0].type.?;
            const P1 = fn_info.params[1].type.?;
            const result = @call(.auto, implementation, .{
                castArg(P0, globalThis),
                castArg(P1, callframe),
            });

            return finishHostReturn(Return, result, globalThis);
        }
    }.wrapper;
}

fn castArg(comptime T: type, value: anytype) T {
    if (T == @TypeOf(value)) return value;
    switch (@typeInfo(T)) {
        .pointer => {
            if (@typeInfo(@TypeOf(value)) == .pointer) {
                return @ptrCast(value);
            }
        },
        .optional => |optional| {
            if (@typeInfo(optional.child) == .pointer and @typeInfo(@TypeOf(value)) == .pointer) {
                return @ptrCast(value);
            }
        },
        else => {},
    }
    return undefined;
}

fn isJSValueLike(comptime T: type) bool {
    if (T == JSValue) return true;
    return switch (@typeInfo(T)) {
        .@"enum" => |info| info.tag_type == i64,
        else => false,
    };
}

fn toCanonicalJSValue(value: anytype) JSValue {
    const T = @TypeOf(value);
    if (T == JSValue) return value;
    if (comptime isJSValueLike(T)) {
        return @enumFromInt(@intFromEnum(value));
    }
    return .zero;
}

fn finishHostReturn(comptime Return: type, result: Return, globalThis: *JSGlobalObject) JSValue {
    return switch (@typeInfo(Return)) {
        .error_union => |info| {
            const value = result catch |err| return finishHostError(info.error_set, err, globalThis);
            return finishHostPayload(info.payload, value);
        },
        else => finishHostPayload(Return, result),
    };
}

fn finishHostError(comptime ErrorSet: type, err: ErrorSet, globalThis: *JSGlobalObject) JSValue {
    if (comptime errorSetHas(ErrorSet, "OutOfMemory")) {
        if (err == @as(ErrorSet, @field(anyerror, "OutOfMemory"))) {
            globalThis.throwOutOfMemory() catch {};
        }
    }
    return .zero;
}

fn errorSetHas(comptime ErrorSet: type, comptime name: []const u8) bool {
    const errors = @typeInfo(ErrorSet).error_set orelse return true;
    for (errors) |err| {
        if (std.mem.eql(u8, err.name, name)) return true;
    }
    return false;
}

fn finishHostPayload(comptime Payload: type, value: Payload) JSValue {
    if (Payload == void) return .js_undefined;
    if (comptime isJSValueLike(Payload)) return toCanonicalJSValue(value);
    if (@typeInfo(Payload) == .optional) {
        const Child = @typeInfo(Payload).optional.child;
        if (comptime isJSValueLike(Child)) {
            return if (value) |unwrapped| toCanonicalJSValue(unwrapped) else .zero;
        }
    }
    return .zero;
}

fn unsupportedHostFn(_: *JSGlobalObject, _: *jsc.CallFrame) callconv(jsc.conv) JSValue {
    return .zero;
}

const bun = @import("bun");
const std = @import("std");
const String = bun.String;

const jsc = bun.jsc;
const JSGlobalObject = jsc.JSGlobalObject;
const JSHostFn = jsc.JSHostFn;
const JSValue = jsc.JSValue;
const ZigString = jsc.ZigString;
