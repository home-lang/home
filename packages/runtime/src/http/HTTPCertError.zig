// Copied verbatim from bun/src/http/HTTPCertError.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.

error_no: i32 = 0,
code: [:0]const u8 = "",
reason: [:0]const u8 = "",
