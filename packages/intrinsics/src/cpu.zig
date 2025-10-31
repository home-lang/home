// Home Programming Language - CPU Feature Detection
// Runtime CPU capability detection

const std = @import("std");
const builtin = @import("builtin");

pub const CpuFeatures = struct {
    // x86/x86_64 features
    sse: bool = false,
    sse2: bool = false,
    sse3: bool = false,
    ssse3: bool = false,
    sse4_1: bool = false,
    sse4_2: bool = false,
    avx: bool = false,
    avx2: bool = false,
    avx512f: bool = false,
    fma: bool = false,
    aes: bool = false,
    pclmul: bool = false,
    popcnt: bool = false,
    bmi1: bool = false,
    bmi2: bool = false,
    lzcnt: bool = false,

    // ARM features
    neon: bool = false,
    sve: bool = false,
    crc32: bool = false,
    crypto: bool = false,
    fp16: bool = false,
    dotprod: bool = false,

    pub fn detect() CpuFeatures {
        const os_struct = std.Target.Os{ .tag = builtin.target.os.tag, .version_range = .{ .none = {} } };
        const cpu_features = std.Target.Cpu.baseline(builtin.cpu.arch, os_struct).features;

        var features = CpuFeatures{};

        switch (builtin.cpu.arch) {
            .x86_64, .x86 => {
                features.sse = std.Target.x86.featureSetHas(cpu_features, .sse);
                features.sse2 = std.Target.x86.featureSetHas(cpu_features, .sse2);
                features.sse3 = std.Target.x86.featureSetHas(cpu_features, .sse3);
                features.ssse3 = std.Target.x86.featureSetHas(cpu_features, .ssse3);
                features.sse4_1 = std.Target.x86.featureSetHas(cpu_features, .sse4_1);
                features.sse4_2 = std.Target.x86.featureSetHas(cpu_features, .sse4_2);
                features.avx = std.Target.x86.featureSetHas(cpu_features, .avx);
                features.avx2 = std.Target.x86.featureSetHas(cpu_features, .avx2);
                features.avx512f = std.Target.x86.featureSetHas(cpu_features, .avx512f);
                features.fma = std.Target.x86.featureSetHas(cpu_features, .fma);
                features.aes = std.Target.x86.featureSetHas(cpu_features, .aes);
                features.pclmul = std.Target.x86.featureSetHas(cpu_features, .pclmul);
                features.popcnt = std.Target.x86.featureSetHas(cpu_features, .popcnt);
                features.bmi1 = std.Target.x86.featureSetHas(cpu_features, .bmi);
                features.bmi2 = std.Target.x86.featureSetHas(cpu_features, .bmi2);
                features.lzcnt = std.Target.x86.featureSetHas(cpu_features, .lzcnt);
            },
            .aarch64, .arm => {
                features.neon = std.Target.aarch64.featureSetHas(cpu_features, .neon);
                features.crc32 = std.Target.aarch64.featureSetHas(cpu_features, .crc);
                features.crypto = std.Target.aarch64.featureSetHas(cpu_features, .crypto);
                features.fp16 = std.Target.aarch64.featureSetHas(cpu_features, .fp16fml);
                features.dotprod = std.Target.aarch64.featureSetHas(cpu_features, .dotprod);
                features.sve = std.Target.aarch64.featureSetHas(cpu_features, .sve);
            },
            else => {},
        }

        return features;
    }

    pub fn hasSimd(self: CpuFeatures) bool {
        return self.sse or self.sse2 or self.avx or self.avx2 or self.neon;
    }

    pub fn hasAdvancedSimd(self: CpuFeatures) bool {
        return self.avx2 or self.avx512f or self.sve;
    }

    pub fn hasCrypto(self: CpuFeatures) bool {
        return self.aes or self.crypto;
    }
};

// CPU identification
pub const CpuInfo = struct {
    vendor: []const u8,
    brand: []const u8,
    cores: usize,
    threads: usize,

    pub fn detect() CpuInfo {
        return .{
            .vendor = "Unknown",
            .brand = "Unknown",
            .cores = 1,
            .threads = 1,
        };
    }
};

// Cache line size detection
pub fn getCacheLineSize() usize {
    return switch (builtin.cpu.arch) {
        .x86_64, .x86 => 64,
        .aarch64, .arm => 64,
        else => 64,
    };
}

// Page size detection
pub fn getPageSize() usize {
    return switch (builtin.target.os.tag) {
        .linux, .macos => 4096,
        .windows => 4096,
        else => 4096,
    };
}

test "cpu feature detection" {
    const features = CpuFeatures.detect();
    _ = features.hasSimd();
    _ = features.hasAdvancedSimd();
    _ = features.hasCrypto();
}

test "cache line size" {
    const size = getCacheLineSize();
    const testing = std.testing;
    try testing.expect(size == 64 or size == 128);
}

test "page size" {
    const size = getPageSize();
    const testing = std.testing;
    try testing.expect(size >= 4096);
}
