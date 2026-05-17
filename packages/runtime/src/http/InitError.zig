// Copied verbatim from bun/src/http/InitError.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.

pub const InitError = error{
    FailedToOpenSocket,
    LoadCAFile,
    InvalidCAFile,
    InvalidCA,
};
