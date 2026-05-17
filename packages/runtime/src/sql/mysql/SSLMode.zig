// Copied verbatim from bun/src/sql/mysql/SSLMode.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.

pub const SSLMode = enum(u8) {
    disable = 0,
    prefer = 1,
    require = 2,
    verify_ca = 3,
    verify_full = 4,
};
