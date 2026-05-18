// Copied from bun/src/runtime/webcore/ScriptExecutionContext.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../../cli/LICENSE.bun.md.
//
// Rewrites:
//   - @import("bun") → @import("home_rt") (unused after stubbing — the
//     two JSC types we need are local opaques).
//
// Stubs (re-attach when home_rt.jsc grows the matching surface):
//   - `bun.jsc.JSGlobalObject` modelled as `opaque {}`. The extern
//     `ScriptExecutionContextIdentifier__getGlobalObject` returns an
//     optional pointer to one — opaque is exactly the right shape.
//   - `bun.jsc.VirtualMachine` modelled as `opaque {}` for the same
//     reason. We expose `bunVM()` as a stub that returns null until the
//     JSC VM surface lands, because upstream calls
//     `.bunVMConcurrently()` on a `JSGlobalObject` pointer — a method
//     that doesn't exist in this file's purview to expose.
//
// The `Identifier` enum + its `globalObject()`/`valid()` accessors are
// preserved verbatim. `bunVM()` is stubbed; doc-comment notes why.

const std = @import("std");

// JSC stubs.
const JSGlobalObject = opaque {};
const VirtualMachine = opaque {};

extern fn ScriptExecutionContextIdentifier__getGlobalObject(id: u32) ?*JSGlobalObject;

/// Safe handle to a JavaScript execution environment that may have exited.
/// Obtain with `global_object.scriptExecutionContextIdentifier()`.
///
/// The underlying u32 is a per-VM counter; once a context exits the
/// identifier is invalidated and `globalObject()` returns null. This is
/// the entry point off-thread tasks use to safely re-enter the JS
/// thread (or bail).
pub const Identifier = enum(u32) {
    _,

    /// Returns null if the context referred to by `self` no longer exists.
    pub fn globalObject(self: Identifier) ?*JSGlobalObject {
        return ScriptExecutionContextIdentifier__getGlobalObject(@intFromEnum(self));
    }

    /// Returns null if the context referred to by `self` no longer
    /// exists OR if the home_rt.jsc VM bridge hasn't been re-attached
    /// yet.
    ///
    /// Upstream wires this through
    /// `.globalObject().bunVMConcurrently()`; home_rt.jsc exposes
    /// neither end of that chain, so this stays a stub returning null.
    /// Callers must already handle null (it's how a dead context is
    /// signalled) so behaviour stays safe — the only loss is the
    /// liveness path.
    pub fn bunVM(self: Identifier) ?*VirtualMachine {
        _ = self;
        return null;
    }

    pub fn valid(self: Identifier) bool {
        return self.globalObject() != null;
    }
};

test "ScriptExecutionContext: Identifier is repr(u32) and zero-cost" {
    try std.testing.expectEqual(@as(usize, @sizeOf(u32)), @sizeOf(Identifier));
    try std.testing.expectEqual(@as(usize, @alignOf(u32)), @alignOf(Identifier));
}

test "ScriptExecutionContext: Identifier construction round-trips through u32" {
    // The `_` variant is the public escape hatch for arbitrary u32
    // values produced by C++. Round-tripping must be free of bit drift.
    const raw: u32 = 0xDEAD_BEEF;
    const id: Identifier = @enumFromInt(raw);
    try std.testing.expectEqual(raw, @intFromEnum(id));
}

test "ScriptExecutionContext: bunVM() stub returns null pending home_rt.jsc.VM port" {
    // While the stub is in place, `bunVM()` must always return null.
    // Code paths that rely on a non-null VM should already gate on this.
    const id: Identifier = @enumFromInt(0);
    try std.testing.expectEqual(@as(?*VirtualMachine, null), id.bunVM());
}
