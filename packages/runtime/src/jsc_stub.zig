// Copied verbatim from bun/src/jsc_stub.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see cli/LICENSE.bun.md.

// For WASM builds
pub const C = struct {};
pub const WebCore = struct {};
pub const Jest = struct {};
pub const API = struct {
    pub const Transpiler = struct {};
};
pub const Node = struct {};

pub const VirtualMachine = struct {};
