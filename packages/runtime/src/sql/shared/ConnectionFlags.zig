// Copied verbatim from bun/src/sql/shared/ConnectionFlags.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.

pub const ConnectionFlags = packed struct {
    is_ready_for_query: bool = false,
    is_processing_data: bool = false,
    use_unnamed_prepared_statements: bool = false,
    waiting_to_prepare: bool = false,
    has_backpressure: bool = false,
};
