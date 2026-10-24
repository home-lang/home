//! Standalone entry keeps the module root at src/ for shared imports.
pub const main = @import("io/process_output_host.zig").main;
