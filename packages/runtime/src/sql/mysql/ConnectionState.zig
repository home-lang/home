// Copied verbatim from bun/src/sql/mysql/ConnectionState.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.

pub const ConnectionState = enum {
    disconnected,
    connecting,
    handshaking,
    authenticating,
    authentication_awaiting_pk,
    connected,
    failed,
};
