// Copied from bun/src/sql/mysql/protocol/AnyMySQLError.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../../cli/LICENSE.bun.md.
//
// The upstream file's `mysqlErrorToJS` re-export reaches into
// `sql_jsc/mysql/protocol/any_mysql_error_jsc.zig` (JSC bridge). It
// re-lands under `src/sql_jsc/` in Phase 12.2.

pub const Error = error{
    ConnectionClosed,
    ConnectionTimedOut,
    LifetimeTimeout,
    IdleTimeout,
    PasswordRequired,
    MissingAuthData,
    AuthenticationFailed,
    FailedToEncryptPassword,
    InvalidPublicKey,
    PublicKeyRetrievalNotAllowed,
    UnsupportedAuthPlugin,
    UnsupportedProtocolVersion,

    LocalInfileNotSupported,
    JSError,
    JSTerminated,
    OutOfMemory,
    Overflow,

    WrongNumberOfParametersProvided,

    UnsupportedColumnType,

    InvalidLocalInfileRequest,
    InvalidAuthSwitchRequest,
    InvalidQueryBinding,
    InvalidResultRow,
    InvalidBinaryValue,
    InvalidEncodedInteger,
    InvalidEncodedLength,

    InvalidPrepareOKPacket,
    InvalidOKPacket,
    InvalidEOFPacket,
    InvalidErrorPacket,
    UnexpectedPacket,
    ShortRead,
    UnknownError,
    InvalidState,
};

pub fn mysqlErrorToJS(_: *@import("home").jsc.JSGlobalObject, _: []const u8, _: anyerror) @import("home").jsc.JSValue {
    return .zero;
}

test "AnyMySQLError.Error: canonical wire failure tags can be raised" {
    const std = @import("std");
    const err: Error = error.ConnectionClosed;
    try std.testing.expectEqualStrings("ConnectionClosed", @errorName(err));

    const auth_err: Error = error.AuthenticationFailed;
    try std.testing.expectEqualStrings("AuthenticationFailed", @errorName(auth_err));

    const prep_err: Error = error.InvalidPrepareOKPacket;
    try std.testing.expectEqualStrings("InvalidPrepareOKPacket", @errorName(prep_err));
}
