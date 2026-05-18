// Copied verbatim from bun/src/jsc/JSInternalPromise.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// JSInternalPromise was removed from JavaScriptCore upstream. The new module
// loader uses regular JSPromise everywhere. Keep this as a transparent alias so
// existing Zig callers continue to compile.
pub const JSInternalPromise = @import("./JSPromise.zig").JSPromise;

test "JSInternalPromise is aliased to JSPromise" {
    const std = @import("std");
    try std.testing.expectEqual(JSInternalPromise, @import("./JSPromise.zig").JSPromise);
}
