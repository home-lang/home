// Copied verbatim from bun/src/sql/postgres/protocol/TransactionStatusIndicator.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../../cli/LICENSE.bun.md.

pub const TransactionStatusIndicator = enum(u8) {
    /// if idle (not in a transaction block)
    I = 'I',

    /// if in a transaction block
    T = 'T',

    /// if in a failed transaction block
    E = 'E',

    _,
};
