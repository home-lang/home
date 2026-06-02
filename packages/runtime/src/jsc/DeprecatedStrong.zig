// Copied from bun/src/jsc/DeprecatedStrong.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Two divergences from upstream:
//
//  1. The upstream file uses Zig 0.18+ "private field" syntax (`#raw`,
//     `#safety`). The pinned home toolchain (0.17.0-dev.263) does not parse
//     `#`-prefixed identifiers, so we rename those fields to plain `raw`
//     and `safety`. Phase 12.2 restores the private syntax once we move
//     to a 0.18+ toolchain.
//  2. `jsc.JSValue`, `jsc.Strong.Deprecated`, `bun.create`, and
//     `bun.Environment.ci_assert` are not yet ported. Local stubs preserve
//     the public surface; the JSC bridge re-attaches in Phase 12.2.
//
// The upstream file also has free-standing top-level fields (no enclosing
// struct) — that's the upstream `#self` / "anonymous file struct" pattern.
// We preserve that shape: the file *is* the `Strong` struct when imported
// as `@import("./DeprecatedStrong.zig")`.

const std = @import("std");

const JSValue = @import("./JSValue.zig").JSValue;

// Compile-time toggle mirroring `bun.Environment.ci_assert` — defaults to
// off until the Environment toggle is wired.
const enable_safety = false;

raw: JSValue,
safety: Safety,
const Safety = if (enable_safety) ?struct { ptr: *Strong, gpa: std.mem.Allocator, ref_count: u32 } else void;

const Strong = @This();

pub fn initNonCell(non_cell: JSValue) Strong {
    std.debug.assert(!non_cell.isCell());
    const safety: Safety = if (enable_safety) null;
    return .{ .raw = non_cell, .safety = safety };
}
pub fn init(safety_gpa: std.mem.Allocator, value: JSValue) Strong {
    value.protect();
    const safety: Safety = if (enable_safety) blk: {
        const ptr = safety_gpa.create(Strong) catch @panic("OOM");
        ptr.* = .{ .raw = @enumFromInt(0xAEBCFA), .safety = null };
        break :blk .{ .ptr = ptr, .gpa = safety_gpa, .ref_count = 1 };
    };
    return .{ .raw = value, .safety = safety };
}
pub fn deinit(this: *Strong) void {
    this.raw.unprotect();
    if (enable_safety) if (this.safety) |safety| {
        std.debug.assert(@intFromEnum(safety.ptr.*.raw) == 0xAEBCFA);
        safety.ptr.*.raw = @enumFromInt(0xFFFFFF);
        std.debug.assert(safety.ref_count == 1);
        safety.gpa.destroy(safety.ptr);
    };
}
pub fn get(this: Strong) JSValue {
    return this.raw;
}
pub fn swap(this: *Strong, safety_gpa: std.mem.Allocator, next: JSValue) JSValue {
    const prev = this.raw;
    this.deinit();
    this.* = .init(safety_gpa, next);
    return prev;
}
pub fn dupe(this: Strong, gpa: std.mem.Allocator) Strong {
    return .init(gpa, this.get());
}
pub fn ref(this: *Strong) void {
    this.raw.protect();
    if (enable_safety) if (this.safety) |safety| {
        safety.ref_count += 1;
    };
}
pub fn unref(this: *Strong) void {
    this.raw.unprotect();
    if (enable_safety) if (this.safety) |safety| {
        if (safety.ref_count == 1) {
            std.debug.assert(@intFromEnum(safety.ptr.*.raw) == 0xAEBCFA);
            safety.ptr.*.raw = @enumFromInt(0xFFFFFF);
            safety.gpa.destroy(safety.ptr);
            return;
        }
        safety.ref_count -= 1;
    };
}

pub const Optional = struct {
    backing: Strong,
    pub const empty: Optional = .initNonCell(null);
    pub fn initNonCell(non_cell: ?JSValue) Optional {
        return .{ .backing = .initNonCell(non_cell orelse .zero) };
    }
    pub fn init(safety_gpa: std.mem.Allocator, value: ?JSValue) Optional {
        return .{ .backing = .init(safety_gpa, value orelse .zero) };
    }
    pub fn deinit(this: *Optional) void {
        this.backing.deinit();
    }
    pub fn get(this: Optional) ?JSValue {
        const result = this.backing.get();
        if (result == .zero) return null;
        return result;
    }
    pub fn swap(this: *Optional, safety_gpa: std.mem.Allocator, next: ?JSValue) ?JSValue {
        const result = this.backing.swap(safety_gpa, next orelse .zero);
        if (result == .zero) return null;
        return result;
    }
    pub fn dupe(this: Optional, gpa: std.mem.Allocator) Optional {
        return .{ .backing = this.backing.dupe(gpa) };
    }
    pub fn has(this: Optional) bool {
        return this.backing.get() != .zero;
    }
    pub fn ref(this: *Optional) void {
        this.backing.ref();
    }
    pub fn unref(this: *Optional) void {
        this.backing.unref();
    }
};

test "Strong.initNonCell round-trips zero" {
    var s = initNonCell(.zero);
    try std.testing.expectEqual(JSValue.zero, s.get());
    s.deinit();
}

test "Optional.empty has no value" {
    const opt = Optional.empty;
    try std.testing.expect(!opt.has());
    try std.testing.expectEqual(@as(?JSValue, null), opt.get());
}

test "Optional.initNonCell wraps a non-null value" {
    const v: JSValue = @enumFromInt(0); // zero, but treated as 'empty'
    const opt = Optional.initNonCell(v);
    try std.testing.expect(!opt.has()); // zero maps to empty
}
