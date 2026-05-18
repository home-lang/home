// Copied from bun/src/jsc/Errorable.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// `ZigErrorType` and `bun.jsc.JSValue` are not yet ported. We inline the
// `ZigErrorType` definition here as the source file is tiny (it's literally
// `extern struct { code, value }`) and stub `JSValue` as an `i64`-shaped
// enum to preserve ABI. Full JSValue wiring lands in Phase 12.2.

const std = @import("std");
const ErrorCode = @import("./ErrorCode.zig").ErrorCode;

// JSC bridge JSValue stubbed — re-attaches in Phase 12.2.
pub const JSValue = enum(i64) { zero = 0, _ };

/// Inlined from upstream `ZigErrorType.zig` (5-line file) so Errorable can be
/// a leaf port. Phase 12.2 promotes this to its own file alongside JSValue.
pub const ZigErrorType = extern struct {
    code: ErrorCode,
    value: JSValue,
};

pub fn Errorable(comptime Type: type) type {
    return extern struct {
        result: Result,
        success: bool,

        pub const Result = extern union {
            value: Type,
            err: ZigErrorType,
        };

        pub fn unwrap(errorable: @This()) !Type {
            if (errorable.success) {
                return errorable.result.value;
            } else {
                return errorable.result.err.code.toError();
            }
        }

        pub fn value(val: Type) @This() {
            return @This(){ .result = .{ .value = val }, .success = true };
        }

        pub fn ok(val: Type) @This() {
            return @This(){ .result = .{ .value = val }, .success = true };
        }

        pub fn err(code: anyerror, err_value: JSValue) @This() {
            return @This(){
                .result = .{
                    .err = .{
                        .code = ErrorCode.from(code),
                        .value = err_value,
                    },
                },
                .success = false,
            };
        }
    };
}

test "Errorable.ok wraps value, success=true" {
    const E = Errorable(u32);
    const e = E.ok(42);
    try std.testing.expect(e.success);
    try std.testing.expectEqual(@as(u32, 42), e.result.value);
}

test "Errorable.err marks success=false and propagates code" {
    const E = Errorable(u32);
    const e = E.err(error.ParserError, JSValue.zero);
    try std.testing.expect(!e.success);
    try std.testing.expectError(error.ParserError, e.unwrap());
}

test "Errorable.unwrap returns value on success" {
    const E = Errorable(u64);
    const e = E.value(7);
    try std.testing.expectEqual(@as(u64, 7), try e.unwrap());
}
