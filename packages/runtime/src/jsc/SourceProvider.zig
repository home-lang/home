// Copied from bun/src/jsc/SourceProvider.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Upstream uses `bun.cpp.JSC__SourceProvider__deref`; we declare the symbol
// inline since the `bun.cpp` namespace isn't yet ported. Re-lands in
// Phase 12.2.

/// Opaque representation of a JavaScript source provider
pub const SourceProvider = opaque {
    pub fn deref(provider: *SourceProvider) void {
        JSC__SourceProvider__deref(provider);
    }

    extern fn JSC__SourceProvider__deref(provider: *SourceProvider) void;
};

test "SourceProvider is an opaque pointer-only type" {
    const std = @import("std");
    try std.testing.expect(@sizeOf(*SourceProvider) == @sizeOf(usize));
}
