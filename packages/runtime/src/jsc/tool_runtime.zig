//! Public-C runtime surface for Home-executed repository tools.
//!
//! This module intentionally stays inside the small engine-independent leaf:
//! TypeScript parsing/emission belongs to Home, while JavaScript execution is
//! supplied at link time by zig-js or system JavaScriptCore.

pub const Engine = @import("engine.zig").Engine;
pub const console = @import("console.zig");
pub const process = @import("process.zig");
pub const host = @import("tool_host.zig");
pub const evaluate = @import("evaluate.zig");
pub const extern_fns = @import("extern_fns.zig");
pub const opaques = @import("opaques.zig");
