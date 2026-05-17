// Copied verbatim from bun/src/sql/shared/SQLQueryResultMode.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.

pub const SQLQueryResultMode = enum(u2) {
    objects = 0,
    values = 1,
    raw = 2,
};
