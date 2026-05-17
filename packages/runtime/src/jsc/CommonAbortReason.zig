// Copied from bun/src/jsc/CommonAbortReason.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// The `toJS` method + extern declaration require `JSGlobalObject` / `JSValue`
// from JSC, which haven't been ported. They re-land alongside the rest of the
// JSC binding surface in Phase 12.2 under `src/jsc/`.

pub const CommonAbortReason = enum(u8) {
    Timeout = 1,
    UserAbort = 2,
    ConnectionClosed = 3,
};
