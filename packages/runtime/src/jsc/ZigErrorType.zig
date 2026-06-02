// Copied from bun/src/jsc/ZigErrorType.zig at upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// `bun.jsc.JSValue` is not yet ported. Stubbed as an opaque-equivalent extern
// struct (the C ABI is a 64-bit EncodedJSValue). The JSC bridge re-attaches
// in Phase 12.2.

const std = @import("std");
const ErrorCode = @import("ErrorCode.zig").ErrorCode;
const JSValue = @import("home").jsc.JSValue;

pub const ZigErrorType = extern struct {
    code: ErrorCode,
    value: JSValue,
};

test "ZigErrorType layout: code + value" {
    try std.testing.expect(@offsetOf(ZigErrorType, "code") == 0);
    try std.testing.expect(@hasField(ZigErrorType, "value"));
}
