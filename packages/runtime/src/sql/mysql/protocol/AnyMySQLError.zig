// Copied from bun/src/sql/mysql/protocol/AnyMySQLError.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../../cli/LICENSE.bun.md.
//
// The JSC bridge lives under sql_jsc so the wire protocol remains usable
// without JavaScriptCore. Runtime builds re-export it here, matching Bun.

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

pub const mysqlErrorToJS = @import("../../../sql_jsc/mysql/protocol/any_mysql_error_jsc.zig").mysqlErrorToJS;

test "AnyMySQLError.Error: canonical wire failure tags can be raised" {
    const std = @import("std");
    const err: Error = error.ConnectionClosed;
    try std.testing.expectEqualStrings("ConnectionClosed", @errorName(err));

    const auth_err: Error = error.AuthenticationFailed;
    try std.testing.expectEqualStrings("AuthenticationFailed", @errorName(auth_err));

    const prep_err: Error = error.InvalidPrepareOKPacket;
    try std.testing.expectEqualStrings("InvalidPrepareOKPacket", @errorName(prep_err));
}
