//! ts_emit — Phase 4 of TS_PARITY_PLAN.
//!
//! Public surface: JS pretty-printer (Phase 4.1) and the slot for
//! the symbol-driven `.d.ts` emitter (Phase 4.2). Both consume the
//! HIR + (eventually) checker output produced by the upstream phases.
//!
//! The fast-track `.d.ts` path described in §0 (vendoring zig-dtsx)
//! lives at `packages/ts_emit/d_ts/fast/` once the submodule is
//! pulled in; that's a separate landing.

pub const js_emit = @import("js_emit.zig");

pub const Printer = js_emit.Printer;
pub const Options = js_emit.Options;
pub const EmitError = js_emit.EmitError;

const std = @import("std");

test {
    _ = js_emit;
}
