// Copied verbatim from bun/src/sql/mysql/TLSStatus.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.

pub const TLSStatus = union(enum) {
    none,
    pending,

    /// Number of bytes sent of the 8-byte SSL request message.
    /// Since we may send a partial message, we need to know how many bytes were sent.
    message_sent,

    ssl_not_available,
    ssl_failed,
    ssl_ok,
};
