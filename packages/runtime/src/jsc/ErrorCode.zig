// Copied from bun/src/jsc/ErrorCode.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// The original file uses `comptime @export` markers; we keep them so the
// exported symbols line up with Bun's C++ layer once JSC is linked in.

const ErrorCodeInt = u16;

pub const ErrorCode = enum(ErrorCodeInt) {
    _,

    pub inline fn from(code: anyerror) ErrorCode {
        return @as(ErrorCode, @enumFromInt(@intFromError(code)));
    }

    pub inline fn toError(self: ErrorCode) anyerror {
        return @errorFromInt(@intFromEnum(self));
    }

    pub const ParserError = @intFromEnum(ErrorCode.from(error.ParserError));
    pub const JSErrorObject = @intFromEnum(ErrorCode.from(error.JSErrorObject));

    pub const Type = ErrorCodeInt;
};

comptime {
    @export(&ErrorCode.ParserError, .{ .name = "Zig_ErrorCodeParserError" });
    @export(&ErrorCode.JSErrorObject, .{ .name = "Zig_ErrorCodeJSErrorObject" });
}
