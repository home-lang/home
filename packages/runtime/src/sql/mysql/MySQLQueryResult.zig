// Copied verbatim from bun/src/sql/mysql/MySQLQueryResult.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.

result_count: u64,
last_insert_id: u64,
affected_rows: u64,
is_last_result: bool,
