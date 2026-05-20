const std = @import("std");

pub const JSError = error{ JSException, OutOfMemory };
pub const default_allocator = std.testing.allocator;

pub const strings = struct {
    pub fn contains(haystack: []const u8, needle: []const u8) bool {
        return std.mem.indexOf(u8, haystack, needle) != null;
    }

    pub fn endsWith(haystack: []const u8, needle: []const u8) bool {
        return std.mem.endsWith(u8, haystack, needle);
    }
};

pub fn cast(comptime T: type, ptr: anytype) T {
    return @ptrCast(@alignCast(ptr));
}

pub const jsc = struct {
    pub const VM = opaque {};

    pub const JSGlobalObject = struct {
        pub fn throwInvalidArguments(_: *JSGlobalObject, comptime _: []const u8, _: anytype) JSError!JSValue {
            return error.JSException;
        }

        pub fn throw(_: *JSGlobalObject, comptime _: []const u8, _: anytype) JSError!JSValue {
            return error.JSException;
        }
    };

    pub const JSValue = extern struct {
        tag: Tag,
        bool_value: bool = false,
        number_value: f64 = 0,
        string_ptr: ?[*]const u8 = null,
        string_len: usize = 0,
        array_ptr: ?[*]const JSValue = null,
        array_len: usize = 0,

        pub const Tag = enum(u8) {
            boolean,
            number,
            string,
            function,
            symbol,
            object,
            non_empty_object,
            array,
            date,
            null,
            undefined,
            other,
        };

        pub const js_undefined = JSValue{ .tag = .undefined };
        pub const js_null = JSValue{ .tag = .null };
        pub const js_true = JSValue{ .tag = .boolean, .bool_value = true };
        pub const js_false = JSValue{ .tag = .boolean, .bool_value = false };
        pub const js_number = JSValue{ .tag = .number, .number_value = 42 };
        pub const js_fraction = JSValue{ .tag = .number, .number_value = 1.5 };
        pub const js_negative = JSValue{ .tag = .number, .number_value = -42 };
        pub const js_nan = JSValue{ .tag = .number, .number_value = std.math.nan(f64) };
        pub const js_inf = JSValue{ .tag = .number, .number_value = std.math.inf(f64) };
        pub const js_string = JSValue.string("string");
        pub const js_function = JSValue{ .tag = .function };
        pub const js_symbol = JSValue{ .tag = .symbol };
        pub const js_object = JSValue{ .tag = .object };
        pub const js_non_empty_object = JSValue{ .tag = .non_empty_object };
        pub const js_date = JSValue{ .tag = .date };
        pub const js_invalid_date = JSValue{ .tag = .date, .number_value = std.math.nan(f64) };
        pub const js_array = JSValue{ .tag = .array };
        pub const js_even = JSValue{ .tag = .number, .number_value = 42 };
        pub const js_odd = JSValue{ .tag = .number, .number_value = 41 };
        pub const js_other = JSValue{ .tag = .other };

        pub fn string(value: []const u8) JSValue {
            return .{ .tag = .string, .string_ptr = value.ptr, .string_len = value.len };
        }

        pub fn array(items: []const JSValue) JSValue {
            return .{ .tag = .array, .array_ptr = items.ptr, .array_len = items.len };
        }

        fn stringSlice(this: JSValue) []const u8 {
            const ptr = this.string_ptr orelse return "";
            return ptr[0..this.string_len];
        }

        fn arraySlice(this: JSValue) []const JSValue {
            const ptr = this.array_ptr orelse return &.{};
            return ptr[0..this.array_len];
        }

        pub fn isBoolean(this: JSValue) bool {
            return this.tag == .boolean;
        }

        pub fn isNumber(this: JSValue) bool {
            return this.tag == .number;
        }

        pub fn isString(this: JSValue) bool {
            return this.tag == .string;
        }

        pub fn isCallable(this: JSValue) bool {
            return this.tag == .function;
        }

        pub fn isSymbol(this: JSValue) bool {
            return this.tag == .symbol;
        }

        pub fn isObject(this: JSValue) bool {
            return this.tag == .object or this.tag == .non_empty_object or this.tag == .array;
        }

        pub fn isDate(this: JSValue) bool {
            return this.tag == .date;
        }

        pub fn isBigInt(_: JSValue) bool {
            return false;
        }

        pub fn isBigInt32(_: JSValue) bool {
            return false;
        }

        pub const BigIntCompareResult = enum {
            less_than,
            equal,
            greater_than,
        };

        pub fn asBigIntCompare(_: JSValue, _: *JSGlobalObject, _: JSValue) BigIntCompareResult {
            return .equal;
        }

        pub fn ensureStillAlive(_: JSValue) void {}

        pub fn isInt32(this: JSValue) bool {
            if (!this.isAnyInt()) return false;
            return this.number_value >= std.math.minInt(i32) and this.number_value <= std.math.maxInt(i32);
        }

        pub fn asNumber(this: JSValue) f64 {
            return this.number_value;
        }

        pub fn toInt32(this: JSValue) i32 {
            return @intFromFloat(this.number_value);
        }

        pub fn toInt64(this: JSValue) i64 {
            return @intFromFloat(this.number_value);
        }

        pub fn getUnixTimestamp(this: JSValue) f64 {
            return this.number_value;
        }

        pub fn jsType(this: JSValue) JSType {
            return .{ .tag = this.tag };
        }

        pub fn jsTypeLoose(this: JSValue) JSType {
            return this.jsType();
        }

        pub fn isStringLiteral(this: JSValue) bool {
            return this.isString();
        }

        pub const Slice = struct {
            bytes: []const u8,
            len: usize,

            pub fn slice(this: Slice) []const u8 {
                return this.bytes;
            }

            pub fn deinit(_: Slice) void {}
        };

        pub fn toSlice(this: JSValue, _: *JSGlobalObject, _: std.mem.Allocator) JSError!Slice {
            if (!this.isStringLiteral()) return error.JSException;
            const bytes = this.stringSlice();
            return .{ .bytes = bytes, .len = bytes.len };
        }

        pub fn toSliceOrNull(this: JSValue, _: *JSGlobalObject) JSError!Slice {
            if (!this.isStringLiteral()) return error.JSException;
            const bytes = this.stringSlice();
            return .{ .bytes = bytes, .len = bytes.len };
        }

        pub fn isSameValue(this: JSValue, other: JSValue, _: *JSGlobalObject) JSError!bool {
            if (this.tag != other.tag) return false;
            return switch (this.tag) {
                .boolean => this.bool_value == other.bool_value,
                .number => this.number_value == other.number_value,
                .string => std.mem.eql(u8, this.stringSlice(), other.stringSlice()),
                else => true,
            };
        }

        pub const ArrayIterator = struct {
            items: []const JSValue,
            index: usize = 0,

            pub fn next(this: *ArrayIterator) JSError!?JSValue {
                if (this.index >= this.items.len) return null;
                const item = this.items[this.index];
                this.index += 1;
                return item;
            }
        };

        pub fn arrayIterator(this: JSValue, _: *JSGlobalObject) JSError!ArrayIterator {
            if (this.tag != .array) return error.JSException;
            return .{ .items = this.arraySlice() };
        }

        pub fn isIterable(this: JSValue, _: *JSGlobalObject) JSError!bool {
            return this.tag == .array;
        }

        pub fn forEach(
            this: JSValue,
            globalThis: *JSGlobalObject,
            ctx: ?*anyopaque,
            callback: *const fn (*VM, *JSGlobalObject, ?*anyopaque, JSValue) callconv(.c) void,
        ) JSError!void {
            if (this.tag != .array) return error.JSException;
            const vm: *VM = @ptrFromInt(0x2);
            for (this.arraySlice()) |item| callback(vm, globalThis, ctx, item);
        }

        pub fn isObjectEmpty(this: JSValue, _: *JSGlobalObject) JSError!bool {
            return switch (this.tag) {
                .object => true,
                .non_empty_object => false,
                else => false,
            };
        }

        pub fn getLengthIfPropertyExistsInternal(this: JSValue, _: *JSGlobalObject) JSError!f64 {
            return switch (this.tag) {
                .string => @floatFromInt(this.stringSlice().len),
                .array => @floatFromInt(this.arraySlice().len),
                .object, .non_empty_object => std.math.inf(f64),
                else => std.math.inf(f64),
            };
        }

        pub fn isAnyInt(this: JSValue) bool {
            return this.isNumber() and std.math.isFinite(this.number_value) and @floor(this.number_value) == this.number_value;
        }

        pub fn toBoolean(this: JSValue) bool {
            return this.isBoolean() and this.bool_value;
        }

        pub fn isUndefined(this: JSValue) bool {
            return this.tag == .undefined;
        }

        pub fn isNull(this: JSValue) bool {
            return this.tag == .null;
        }

        pub fn isUndefinedOrNull(this: JSValue) bool {
            return this.isUndefined() or this.isNull();
        }

        pub fn toFmt(this: JSValue, _: *ConsoleObject.Formatter) FormatterValue {
            return .{ .value = this };
        }
    };

    pub const FormatterValue = struct {
        value: JSValue,

        pub fn format(this: FormatterValue, writer: *std.Io.Writer) !void {
            try writer.writeAll(switch (this.value.tag) {
                .boolean => if (this.value.bool_value) "true" else "false",
                .number => "42",
                .string => "\"string\"",
                .function => "[Function]",
                .symbol => "Symbol()",
                .object => "{}",
                .non_empty_object => "{ key: true }",
                .array => "[]",
                .date => "Date",
                .null => "null",
                .undefined => "undefined",
                .other => "value",
            });
        }
    };

    pub const JSType = struct {
        tag: JSValue.Tag,

        pub fn isArray(this: JSType) bool {
            return this.tag == .array;
        }

        pub fn isArrayLike(this: JSType) bool {
            return this.isArray();
        }
    };

    pub const CallFrame = struct {
        this_value: JSValue,
        arguments: []const JSValue = &.{},

        const Arguments = struct {
            ptr: [*]const JSValue,
            len: usize,

            pub fn slice(args: Arguments) []const JSValue {
                return args.ptr[0..args.len];
            }
        };

        pub fn this(this_frame: *CallFrame) JSValue {
            return this_frame.this_value;
        }

        pub fn arguments_old(this_frame: *CallFrame, _: usize) Arguments {
            return .{
                .ptr = this_frame.arguments.ptr,
                .len = this_frame.arguments.len,
            };
        }
    };

    pub const ConsoleObject = struct {
        pub const Formatter = struct {
            globalThis: *JSGlobalObject,
            quote_strings: bool = false,

            pub fn deinit(_: *Formatter) void {}
        };
    };

    pub const Expect = struct {
        pub const Expect = struct {
            const ThisExpect = @This();

            flags: Flags = .{},
            value: JSValue = .js_undefined,
            call_count: usize = 0,
            post_count: usize = 0,
            last_signature: ?[]const u8 = null,

            pub const Flags = struct {
                not: bool = false,
            };

            pub fn postMatch(this: *ThisExpect, _: *JSGlobalObject) void {
                this.post_count += 1;
            }

            pub fn getValue(this: *ThisExpect, _: *JSGlobalObject, _: JSValue, _: []const u8, _: []const u8) JSError!JSValue {
                return this.value;
            }

            pub fn incrementExpectCallCounter(this: *ThisExpect) void {
                this.call_count += 1;
            }

            pub fn throw(this: *ThisExpect, _: *JSGlobalObject, signature: []const u8, comptime _: []const u8, _: anytype) JSError!JSValue {
                this.last_signature = signature;
                return error.JSException;
            }

            pub fn getSignature(comptime matcher_name: []const u8, comptime _: []const u8, comptime not: bool) []const u8 {
                return if (not) "not." ++ matcher_name else matcher_name;
            }
        };
    };
};
