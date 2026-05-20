const std = @import("std");

pub const JSError = error{ JSException, OutOfMemory };

pub const jsc = struct {
    pub const JSGlobalObject = opaque {};

    pub const JSValue = struct {
        tag: Tag,
        bool_value: bool = false,

        pub const Tag = enum {
            boolean,
            null,
            undefined,
            other,
        };

        pub const js_undefined = JSValue{ .tag = .undefined };
        pub const js_null = JSValue{ .tag = .null };
        pub const js_true = JSValue{ .tag = .boolean, .bool_value = true };
        pub const js_false = JSValue{ .tag = .boolean, .bool_value = false };
        pub const js_other = JSValue{ .tag = .other };

        pub fn isBoolean(this: JSValue) bool {
            return this.tag == .boolean;
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

        pub fn toFmt(this: JSValue, _: *ConsoleObject.Formatter) FormatterValue {
            return .{ .value = this };
        }
    };

    pub const FormatterValue = struct {
        value: JSValue,

        pub fn format(this: FormatterValue, writer: *std.Io.Writer) !void {
            try writer.writeAll(switch (this.value.tag) {
                .boolean => if (this.value.bool_value) "true" else "false",
                .null => "null",
                .undefined => "undefined",
                .other => "value",
            });
        }
    };

    pub const CallFrame = struct {
        this_value: JSValue,

        pub fn this(this_frame: *CallFrame) JSValue {
            return this_frame.this_value;
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
