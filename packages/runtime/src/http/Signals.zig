// Copied verbatim from bun/src/http/Signals.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.

const Signals = @This();

header_progress: ?*std.atomic.Value(bool) = null,
response_body_streaming: ?*std.atomic.Value(bool) = null,
aborted: ?*std.atomic.Value(bool) = null,
cert_errors: ?*std.atomic.Value(bool) = null,
upgraded: ?*std.atomic.Value(bool) = null,
pub fn isEmpty(this: *const Signals) bool {
    return this.aborted == null and this.response_body_streaming == null and this.header_progress == null and this.cert_errors == null and this.upgraded == null;
}

pub const Store = struct {
    header_progress: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    response_body_streaming: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    aborted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    cert_errors: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    upgraded: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    pub fn to(this: *Store) Signals {
        return .{
            .header_progress = &this.header_progress,
            .response_body_streaming = &this.response_body_streaming,
            .aborted = &this.aborted,
            .cert_errors = &this.cert_errors,
            .upgraded = &this.upgraded,
        };
    }
};

pub fn get(this: Signals, comptime field: std.meta.FieldEnum(Signals)) bool {
    var ptr: *std.atomic.Value(bool) = @field(this, @tagName(field)) orelse return false;
    return ptr.load(.monotonic);
}

const std = @import("std");

test "Signals.isEmpty reports true when no flags are wired up" {
    const empty: Signals = .{};
    try std.testing.expect(empty.isEmpty());
}

test "Signals.Store.to wires up every field and Signals.get reads them" {
    var store: Signals.Store = .{};
    const signals = store.to();
    try std.testing.expect(!signals.isEmpty());

    // All atomics start false.
    try std.testing.expect(!signals.get(.aborted));
    try std.testing.expect(!signals.get(.upgraded));

    // Flipping the atomic flows through Signals.get.
    store.aborted.store(true, .monotonic);
    try std.testing.expect(signals.get(.aborted));
    try std.testing.expect(!signals.get(.upgraded));
}
