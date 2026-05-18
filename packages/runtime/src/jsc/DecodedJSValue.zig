// Copied from bun/src/jsc/DecodedJSValue.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// `jsc.JSCell`, `jsc.JSValue`, `ffi.NotCellMask`, `bun.assertf`, and the
// `bun.bun_js.jsc` namespace are not yet ported. `JSCell` becomes a local
// opaque stub; `JSValue` is the ABI-matching `enum(i64)` stub; the
// `NotCellMask` constant is inlined from `FFI.zig` (the full FFI port lands
// in Phase 12.2).

const std = @import("std");
const builtin = @import("builtin");

// JSC bridge JSCell stubbed — re-attaches in Phase 12.2.
pub const JSCell = opaque {};

// JSC bridge JSValue stubbed — re-attaches in Phase 12.2.
pub const JSValue = enum(i64) { zero = 0, _ };

/// Inlined from upstream `FFI.zig`:
///   const NumberTag: c_longlong = 0xfffe_0000_0000_0000;
///   const OtherTag: c_int = 0x2;
///   pub const NotCellMask = NumberTag | OtherTag;
const NotCellMask: u64 = @as(u64, 0xfffe_0000_0000_0000) | @as(u64, 0x2);

/// ABI-compatible with `JSC::JSValue`.
pub const DecodedJSValue = extern struct {
    const Self = @This();

    u: EncodedValueDescriptor,

    /// ABI-compatible with `JSC::EncodedValueDescriptor`.
    pub const EncodedValueDescriptor = extern union {
        asInt64: i64,
        ptr: ?*JSCell,
        asBits: extern struct {
            payload: i32,
            tag: i32,
        },
    };

    /// Equivalent to `JSC::JSValue::encode`.
    pub fn encode(self: Self) JSValue {
        return @enumFromInt(self.u.asInt64);
    }

    fn asU64(self: Self) u64 {
        return @bitCast(self.u.asInt64);
    }

    /// Equivalent to `JSC::JSValue::isCell`. Note that like JSC, this method treats 0 as a cell.
    pub fn isCell(self: Self) bool {
        return self.asU64() & NotCellMask == 0;
    }

    /// Equivalent to `JSC::JSValue::asCell`.
    pub fn asCell(self: Self) ?*JSCell {
        std.debug.assert(self.isCell());
        return self.u.ptr;
    }
};

comptime {
    std.debug.assert(@sizeOf(usize) == 8); // EncodedValueDescriptor assumes a 64-bit system
    std.debug.assert(builtin.target.cpu.arch.endian() == .little); // EncodedValueDescriptor.asBits assumes a little-endian system
}

test "DecodedJSValue size matches i64" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(DecodedJSValue));
}

test "DecodedJSValue.isCell treats zero as a cell" {
    const v: DecodedJSValue = .{ .u = .{ .asInt64 = 0 } };
    try std.testing.expect(v.isCell());
}

test "DecodedJSValue.isCell flags NumberTag bits as non-cell" {
    const v: DecodedJSValue = .{ .u = .{ .asInt64 = @bitCast(@as(u64, 0xfffe_0000_0000_0001)) } };
    try std.testing.expect(!v.isCell());
}

test "DecodedJSValue.encode round-trips" {
    const v: DecodedJSValue = .{ .u = .{ .asInt64 = 42 } };
    try std.testing.expectEqual(@as(i64, 42), @intFromEnum(v.encode()));
}
