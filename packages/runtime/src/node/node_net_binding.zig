// Copied from bun/src/runtime/node/node_net_binding.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// **Partial port (process-wide net defaults; JSC accessors deferred).**
//
// Upstream `node_net_binding.zig` is a thin glue file for `node:net`
// that exposes:
//
//   1. Two process-wide tunables — `autoSelectFamilyDefault` and the
//      thread-local `autoSelectFamilyAttemptTimeoutDefault` — that
//      `node:net.connect` reads to decide whether to race AAAA/A
//      addresses and how long to wait between attempts (Happy Eyeballs).
//      Pure storage with no JSC dependency.
//   2. JSC accessor functions (`getDefaultAutoSelectFamily` /
//      `setDefaultAutoSelectFamily` / `…AttemptTimeout` variants) that
//      box the values into `JSFunction`s; the setter uses
//      `validators.validateInt32`. Requires the JSC surface (which is
//      mostly stubbed in Home today).
//   3. Five `node:net` class re-exports (SocketAddress, BlockList,
//      newDetachedSocket, doConnect) — each needs the `jsc.Codegen`
//      layer plus `bun.api.TCPSocket` / `bun.api.TLSSocket` /
//      `bun.api.Listener` (none ported yet).
//
// Only (1) is ported here. The (2) accessors re-attach once
// `validators` and JSFunction.create re-land; (3) waits on the Bun
// TCP/TLS socket surface. Test exercises the storage round-trip +
// confirms the clamped lower bound (>= 10ms) that upstream's setter
// applies.
//
// Imports rewritten: only `std` is needed for the storage.

const std = @import("std");

// ---- Happy Eyeballs defaults ---------------------------------------------

/// `net.getDefaultAutoSelectFamily()` returns this. Defaults to `true`
/// per Node 20+, matching Bun's upstream initialiser.
pub var autoSelectFamilyDefault: bool = true;

/// `net.getDefaultAutoSelectFamilyAttemptTimeout()` returns this. Per
/// Node, the minimum allowed value is 10 ms; the setter clamps below
/// that. Stored per-thread because each Bun Worker gets its own copy —
/// matching upstream's `threadlocal` qualifier.
///
/// > If this becomes used in more places, and especially if it can be
/// > read by other threads, we may need to store it as a field in the
/// > VirtualMachine instead of in a `threadlocal`.
pub threadlocal var autoSelectFamilyAttemptTimeoutDefault: u32 = 250;

/// The lower bound the JSC setter enforces (`if (value < 10) value =
/// 10;`). Exported as a constant so callers (and the deferred
/// accessor) can reference it without rederiving the magic number.
pub const auto_select_family_attempt_timeout_min_ms: u32 = 10;

/// Pure-Zig setter that mirrors the JSC `setter`'s clamp: any value
/// below 10ms is bumped up. Returns the value actually stored.
pub fn setAutoSelectFamilyAttemptTimeoutClamped(value: u32) u32 {
    const clamped = if (value < auto_select_family_attempt_timeout_min_ms) auto_select_family_attempt_timeout_min_ms else value;
    autoSelectFamilyAttemptTimeoutDefault = clamped;
    return clamped;
}

// ---- Tests ----------------------------------------------------------------

test "node_net_binding: autoSelectFamilyDefault is `true` per Node 20+" {
    try std.testing.expectEqual(true, autoSelectFamilyDefault);
}

test "node_net_binding: attempt-timeout default is 250ms" {
    try std.testing.expectEqual(@as(u32, 250), autoSelectFamilyAttemptTimeoutDefault);
}

test "node_net_binding: setter clamps values below 10ms to the minimum" {
    const prev = autoSelectFamilyAttemptTimeoutDefault;
    defer autoSelectFamilyAttemptTimeoutDefault = prev;

    // Below the floor — bumped to 10.
    try std.testing.expectEqual(@as(u32, 10), setAutoSelectFamilyAttemptTimeoutClamped(0));
    try std.testing.expectEqual(@as(u32, 10), autoSelectFamilyAttemptTimeoutDefault);

    // At the floor — unchanged.
    try std.testing.expectEqual(@as(u32, 10), setAutoSelectFamilyAttemptTimeoutClamped(10));

    // Above the floor — stored verbatim.
    try std.testing.expectEqual(@as(u32, 1234), setAutoSelectFamilyAttemptTimeoutClamped(1234));
    try std.testing.expectEqual(@as(u32, 1234), autoSelectFamilyAttemptTimeoutDefault);
}
