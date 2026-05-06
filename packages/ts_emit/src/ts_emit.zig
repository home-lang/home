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
pub const source_map = @import("source_map.zig");
pub const d_ts_emit = @import("d_ts_emit.zig");
pub const d_ts_fast = @import("d_ts_fast.zig");
pub const tsbuildinfo = @import("tsbuildinfo.zig");

pub const Printer = js_emit.Printer;
pub const Options = js_emit.Options;
pub const EmitError = js_emit.EmitError;
pub const SourceMap = source_map.SourceMap;
pub const Mapping = source_map.Mapping;
pub const encodeVlq = source_map.encodeVlq;
pub const decodeVlq = source_map.decodeVlq;
pub const DtsEmitter = d_ts_emit.Emitter;
pub const DtsOptions = d_ts_emit.Options;

const std = @import("std");

test {
    _ = js_emit;
    _ = source_map;
    _ = d_ts_emit;
    _ = d_ts_fast;
    _ = tsbuildinfo;
}
