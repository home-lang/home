// Copied from bun/src/crash_handler/CPUFeatures.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Wave-16 Tier-1 grinder.
//
// Rewrites:
//   - @import("bun") → @import("home")
//   - bun.strings.eql → home_rt.strings.eql
//   - bun.debugAssert → home_rt.debugAssert
//   - bun.Environment.isX64 → home_rt.Environment.isX64
//   - bun.analytics.Features.no_avx{,2} → home_rt.analytics.Features.no_avx{,2}
//
// External symbol `bun_cpu_features` is provided by upstream's C++ side; in
// Home it's an unresolved extern until the matching C bridge ports. Tests
// instantiate `Flags` directly and don't call `get()`, so the link symbol
// is unused at test time.

const CPUFeatures = @This();

flags: Flags,

extern "c" fn bun_cpu_features() u8;

pub const Flags = switch (@import("builtin").cpu.arch) {
    .x86_64 => packed struct(u8) {
        none: bool,

        sse42: bool,
        popcnt: bool,
        avx: bool,
        avx2: bool,
        avx512: bool,

        padding: u2 = 0,
    },
    .aarch64 => packed struct(u8) {
        none: bool,

        neon: bool,
        fp: bool,
        aes: bool,
        crc32: bool,
        atomics: bool,
        sve: bool,

        padding: u1 = 0,
    },
    else => unreachable,
};

pub fn format(features: @This(), writer: *std.Io.Writer) !void {
    var is_first = true;
    inline for (bun.meta.fieldsOf(Flags)) |field| brk: {
        if (comptime (home_rt.strings.eql(field.name, "padding") or
            home_rt.strings.eql(field.name, "none")))
            break :brk;

        if (@field(features.flags, field.name)) {
            if (!is_first)
                try writer.writeAll(" ");
            is_first = false;
            try writer.writeAll(field.name);
        }
    }
}

pub fn isEmpty(features: CPUFeatures) bool {
    return @as(u8, @bitCast(features.flags)) == 0;
}

pub fn hasAnyAVX(features: CPUFeatures) bool {
    return switch (@import("builtin").cpu.arch) {
        .x86_64 => features.flags.avx or features.flags.avx2 or features.flags.avx512,
        else => false,
    };
}

pub fn get() CPUFeatures {
    const flags: Flags = @bitCast(bun_cpu_features());
    home_rt.debugAssert(flags.none == false and flags.padding == 0); // sanity check

    if (home_rt.Environment.isX64) {
        home_rt.analytics.Features.no_avx += @as(usize, @intFromBool(!flags.avx));
        home_rt.analytics.Features.no_avx2 += @as(usize, @intFromBool(!flags.avx2));
    }

    return .{ .flags = flags };
}

const home_rt = @import("home");
const std = @import("std");
const bun = @import("bun");

test "CPUFeatures: Flags packs into u8 (per-arch layout)" {
    var f: Flags = std.mem.zeroes(Flags);
    try std.testing.expectEqual(@as(u8, 0), @as(u8, @bitCast(f)));
    f.none = true;
    try std.testing.expectEqual(@as(u8, 1), @as(u8, @bitCast(f)));
}

test "CPUFeatures: isEmpty true when no flags set" {
    const cf: CPUFeatures = .{ .flags = std.mem.zeroes(Flags) };
    try std.testing.expect(cf.isEmpty());
}

test "CPUFeatures: hasAnyAVX false for fresh zero state" {
    const cf: CPUFeatures = .{ .flags = std.mem.zeroes(Flags) };
    try std.testing.expect(!cf.hasAnyAVX());
}
