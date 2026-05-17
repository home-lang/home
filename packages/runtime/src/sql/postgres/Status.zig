// Copied verbatim from bun/src/sql/postgres/Status.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.

pub const Status = enum {
    disconnected,
    connecting,
    // Prevent sending the startup message multiple times.
    // Particularly relevant for TLS connections.
    sent_startup_message,
    connected,
    failed,
};
