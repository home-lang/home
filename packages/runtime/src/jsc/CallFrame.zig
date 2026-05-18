// Copied from bun/src/jsc/CallFrame.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Structural port. The opaque `CallFrame` type round-trips between Zig and
// the JSC interpreter; we keep its public surface (`arguments`, `this`,
// `callee`, `iterate`, ...) so callers compile against the same API.
//
// The `Bun__CallFrame__*` externs go through C++ and are kept verbatim per
// the porting rules. The `VM` / `JSGlobalObject` parameters are stubbed
// locally as opaque pointers; they re-attach when the JSC bridge lands in
// Phase 12.2.
//
// `bun.String`, `bun.ArenaAllocator`, `bun.bit_set.IntegerBitSet`, and
// `jsc.VirtualMachine` are not yet on the `home_rt` allow-list. The
// `ArgumentsSlice` sub-struct that depends on all four is omitted; callers
// reaching for it should switch to `argumentsAsArray` per the upstream
// migration note ("Do not use this function").

const std = @import("std");

// JSC bridge stubs — re-attach in Phase 12.2.
const JSGlobalObject = opaque {};
const VM = opaque {};

// `bun.String` C ABI stub — re-attaches in Phase 12.2. Real layout is
// `{tag: u8, _padding: 7 bytes, impl: *anyopaque}`.
const String = extern struct {
    tag: u8 = 0,
    _padding: [7]u8 = @splat(0),
    impl: ?*anyopaque = null,

    pub const empty: String = .{};
};

/// Stand-in for `bun.jsc.JSValue`. Real type is an `enum(i64)` with sentinel
/// tags (`.zero`, `.js_undefined`, ...); only `zero` and `js_undefined` are
/// used at the boundaries this file touches.
pub const JSValue = enum(i64) {
    zero = 0,
    js_undefined = 0xa,
    _,
};

/// Call Frame for JavaScript -> Native function calls. In Bun, it is
/// preferred to use the bindings generator instead of directly decoding
/// arguments. See `docs/project/bindgen.md`
pub const CallFrame = opaque {
    /// A slice of all passed arguments to this function call.
    pub fn arguments(self: *const CallFrame) []const JSValue {
        return self.asUnsafeJSValueArray()[offset_first_argument..][0..self.argumentsCount()];
    }

    /// Usage: `const arg1, const arg2 = call_frame.argumentsAsArray(2);`
    pub fn argumentsAsArray(call_frame: *const CallFrame, comptime count: usize) [count]JSValue {
        const slice = call_frame.arguments();
        var value: [count]JSValue = @splat(.js_undefined);
        const n = @min(call_frame.argumentsCount(), count);
        @memcpy(value[0..n], slice[0..n]);
        return value;
    }

    /// This function protects out-of-bounds access by returning undefined
    pub fn argument(self: *const CallFrame, i: usize) JSValue {
        return if (self.argumentsCount() > i) self.arguments()[i] else .js_undefined;
    }

    pub fn argumentsCount(self: *const CallFrame) u32 {
        return self.argumentCountIncludingThis() - 1;
    }

    /// When this CallFrame belongs to a constructor, this value is not the `this`
    /// value, but instead the value of `new.target`.
    pub fn this(self: *const CallFrame) JSValue {
        return self.asUnsafeJSValueArray()[offset_this_argument];
    }

    /// `JSValue` for the current function being called.
    pub fn callee(self: *const CallFrame) JSValue {
        return self.asUnsafeJSValueArray()[offset_callee];
    }

    /// Return a basic iterator.
    pub fn iterate(call_frame: *const CallFrame) Iterator {
        return .{ .rest = call_frame.arguments() };
    }

    /// From JavaScriptCore/interpreter/CallFrame.h
    ///
    ///   |          ......            |   |
    ///   +----------------------------+   |
    ///   |           argN             |   v  lower address
    ///   +----------------------------+
    ///   |           arg1             |
    ///   +----------------------------+
    ///   |           arg0             |
    ///   +----------------------------+
    ///   |           this             |
    ///   +----------------------------+
    ///   | argumentCountIncludingThis |
    ///   +----------------------------+
    ///   |          callee            |
    ///   +----------------------------+
    ///   |        codeBlock           |
    ///   +----------------------------+
    ///   |      return-address        |
    ///   +----------------------------+
    ///   |       callerFrame          |
    ///   +----------------------------+  <- callee's cfr is pointing this address
    ///   |          local0            |
    ///   +----------------------------+
    ///   |          local1            |
    ///   +----------------------------+
    ///   |          localN            |
    ///   +----------------------------+
    ///   |          ......            |
    ///
    /// The proper return type of this should be []Register, but
    inline fn asUnsafeJSValueArray(self: *const CallFrame) [*]const JSValue {
        return @ptrCast(@alignCast(self));
    }

    // These constants are from JSC::CallFrameSlot in JavaScriptCore/interpreter/CallFrame.h
    const offset_code_block = 2;
    const offset_callee = offset_code_block + 1;
    const offset_argument_count_including_this = offset_callee + 1;
    const offset_this_argument = offset_argument_count_including_this + 1;
    const offset_first_argument = offset_this_argument + 1;

    /// This function is manually ported from JSC's equivalent function in C++
    /// See JavaScriptCore/interpreter/CallFrame.h
    fn argumentCountIncludingThis(self: *const CallFrame) u32 {
        // Register defined in JavaScriptCore/interpreter/Register.h
        const Register = extern union {
            value: JSValue, // EncodedJSValue
            call_frame: *CallFrame,
            code_block: *anyopaque, // CodeBlock*
            /// EncodedValueDescriptor defined in JavaScriptCore/runtime/JSCJSValue.h
            encoded_value: extern union {
                ptr: JSValue, // JSCell*
                as_bits: extern struct {
                    payload: i32,
                    tag: i32,
                },
            },
            number: f64, // double
            integer: i64, // integer
        };
        const registers: [*]const Register = @ptrCast(@alignCast(self));
        // argumentCountIncludingThis takes the register at the defined offset, then
        // calls 'ALWAYS_INLINE int32_t Register::unboxedInt32() const',
        // which in turn calls 'ALWAYS_INLINE int32_t Register::payload() const'
        // which accesses `.encodedValue.asBits.payload`
        // JSC stores and works with value as signed, but it is always 1 or more.
        return @intCast(registers[offset_argument_count_including_this].encoded_value.as_bits.payload);
    }

    extern fn Bun__CallFrame__isFromBunMain(*const CallFrame, *const VM) bool;
    pub const isFromBunMain = Bun__CallFrame__isFromBunMain;

    extern fn Bun__CallFrame__getCallerSrcLoc(*const CallFrame, *JSGlobalObject, *String, *c_uint, *c_uint) void;
    pub const CallerSrcLoc = struct {
        str: String,
        line: c_uint,
        column: c_uint,
    };
    pub fn getCallerSrcLoc(call_frame: *const CallFrame, globalThis: *JSGlobalObject) CallerSrcLoc {
        var str: String = undefined;
        var line: c_uint = undefined;
        var column: c_uint = undefined;
        Bun__CallFrame__getCallerSrcLoc(call_frame, globalThis, &str, &line, &column);
        return .{
            .str = str,
            .line = line,
            .column = column,
        };
    }

    extern fn Bun__CallFrame__describeFrame(*const CallFrame) [*:0]const u8;
    pub fn describeFrame(self: *const CallFrame) [:0]const u8 {
        return std.mem.span(Bun__CallFrame__describeFrame(self));
    }

    pub const Iterator = struct {
        rest: []const JSValue,
        pub fn next(it: *Iterator) ?JSValue {
            if (it.rest.len == 0) return null;
            const current = it.rest[0];
            it.rest = it.rest[1..];
            return current;
        }
    };

    // `ArgumentsSlice` was upstream's pre-bindgen argument iterator. It pulls
    // in `bun.ArenaAllocator`, `bun.bit_set.IntegerBitSet`, and
    // `jsc.VirtualMachine` — none of which are on the `home_rt` allow-list
    // yet. Callers should reach for `argumentsAsArray` per the migration
    // note in upstream. The sub-struct re-lands with `jsc.VirtualMachine`.
};

test "CallFrame.Iterator drains the slice in order" {
    var slice = [_]JSValue{ @enumFromInt(7), @enumFromInt(8), @enumFromInt(9) };
    var it: CallFrame.Iterator = .{ .rest = slice[0..] };
    try std.testing.expectEqual(@as(?JSValue, @enumFromInt(7)), it.next());
    try std.testing.expectEqual(@as(?JSValue, @enumFromInt(8)), it.next());
    try std.testing.expectEqual(@as(?JSValue, @enumFromInt(9)), it.next());
    try std.testing.expectEqual(@as(?JSValue, null), it.next());
}

test "CallFrame.CallerSrcLoc carries str/line/column" {
    const loc: CallFrame.CallerSrcLoc = .{ .str = .empty, .line = 1, .column = 2 };
    try std.testing.expectEqual(@as(c_uint, 1), loc.line);
    try std.testing.expectEqual(@as(c_uint, 2), loc.column);
}

test "CallFrame is an opaque pointer-only type" {
    try std.testing.expect(@sizeOf(*CallFrame) == @sizeOf(usize));
}
