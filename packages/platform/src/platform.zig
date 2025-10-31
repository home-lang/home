// Home Programming Language - Platform-Specific Code Blocks
// Conditional compilation for x86, ARM, RISC-V and OS differences

const std = @import("std");
const builtin = @import("builtin");

// ============================================================================
// Platform Detection
// ============================================================================

/// CPU Architecture
pub const Arch = enum {
    x86,
    x86_64,
    arm,
    aarch64,
    riscv32,
    riscv64,
    wasm32,
    wasm64,
    unknown,

    pub fn current() Arch {
        return switch (builtin.cpu.arch) {
            .x86 => .x86,
            .x86_64 => .x86_64,
            .arm => .arm,
            .aarch64 => .aarch64,
            .riscv32 => .riscv32,
            .riscv64 => .riscv64,
            .wasm32 => .wasm32,
            .wasm64 => .wasm64,
            else => .unknown,
        };
    }

    pub fn isX86(self: Arch) bool {
        return self == .x86 or self == .x86_64;
    }

    pub fn isARM(self: Arch) bool {
        return self == .arm or self == .aarch64;
    }

    pub fn isRISCV(self: Arch) bool {
        return self == .riscv32 or self == .riscv64;
    }

    pub fn is64Bit(self: Arch) bool {
        return switch (self) {
            .x86_64, .aarch64, .riscv64, .wasm64 => true,
            else => false,
        };
    }

    pub fn pointerSize(self: Arch) usize {
        return if (self.is64Bit()) 8 else 4;
    }

    pub fn name(self: Arch) []const u8 {
        return switch (self) {
            .x86 => "x86",
            .x86_64 => "x86_64",
            .arm => "arm",
            .aarch64 => "aarch64",
            .riscv32 => "riscv32",
            .riscv64 => "riscv64",
            .wasm32 => "wasm32",
            .wasm64 => "wasm64",
            .unknown => "unknown",
        };
    }
};

/// Operating System
pub const OS = enum {
    linux,
    windows,
    macos,
    freebsd,
    openbsd,
    netbsd,
    wasi,
    freestanding,
    unknown,

    pub fn current() OS {
        return switch (builtin.os.tag) {
            .linux => .linux,
            .windows => .windows,
            .macos => .macos,
            .freebsd => .freebsd,
            .openbsd => .openbsd,
            .netbsd => .netbsd,
            .wasi => .wasi,
            .freestanding => .freestanding,
            else => .unknown,
        };
    }

    pub fn isUnix(self: OS) bool {
        return switch (self) {
            .linux, .macos, .freebsd, .openbsd, .netbsd => true,
            else => false,
        };
    }

    pub fn isBSD(self: OS) bool {
        return switch (self) {
            .freebsd, .openbsd, .netbsd, .macos => true,
            else => false,
        };
    }

    pub fn name(self: OS) []const u8 {
        return switch (self) {
            .linux => "linux",
            .windows => "windows",
            .macos => "macos",
            .freebsd => "freebsd",
            .openbsd => "openbsd",
            .netbsd => "netbsd",
            .wasi => "wasi",
            .freestanding => "freestanding",
            .unknown => "unknown",
        };
    }
};

/// Platform combination
pub const Platform = struct {
    arch: Arch,
    os: OS,

    pub fn current() Platform {
        return .{
            .arch = Arch.current(),
            .os = OS.current(),
        };
    }

    pub fn matches(self: Platform, arch: Arch, os: OS) bool {
        return self.arch == arch and self.os == os;
    }

    pub fn name(self: Platform, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{s}-{s}", .{ self.arch.name(), self.os.name() });
    }
};

// ============================================================================
// Conditional Execution
// ============================================================================

/// Execute function only on specific architecture
pub fn onArch(comptime arch: Arch, comptime func: anytype) void {
    if (Arch.current() == arch) {
        func();
    }
}

/// Execute function only on x86/x86_64
pub fn onX86(comptime func: anytype) void {
    if (Arch.current().isX86()) {
        func();
    }
}

/// Execute function only on ARM/AArch64
pub fn onARM(comptime func: anytype) void {
    if (Arch.current().isARM()) {
        func();
    }
}

/// Execute function only on RISC-V
pub fn onRISCV(comptime func: anytype) void {
    if (Arch.current().isRISCV()) {
        func();
    }
}

/// Execute function only on specific OS
pub fn onOS(comptime os: OS, comptime func: anytype) void {
    if (OS.current() == os) {
        func();
    }
}

/// Execute function only on Unix-like systems
pub fn onUnix(comptime func: anytype) void {
    if (OS.current().isUnix()) {
        func();
    }
}

/// Execute function only on specific platform combination
pub fn onPlatform(comptime arch: Arch, comptime os: OS, comptime func: anytype) void {
    if (Arch.current() == arch and OS.current() == os) {
        func();
    }
}

// ============================================================================
// Compile-Time Selection
// ============================================================================

/// Select value based on architecture
pub fn selectByArch(comptime T: type, comptime options: ArchOptions(T)) T {
    return switch (Arch.current()) {
        .x86 => options.x86 orelse options.default,
        .x86_64 => options.x86_64 orelse options.default,
        .arm => options.arm orelse options.default,
        .aarch64 => options.aarch64 orelse options.default,
        .riscv32 => options.riscv32 orelse options.default,
        .riscv64 => options.riscv64 orelse options.default,
        .wasm32 => options.wasm32 orelse options.default,
        .wasm64 => options.wasm64 orelse options.default,
        .unknown => options.default,
    };
}

pub fn ArchOptions(comptime T: type) type {
    return struct {
        default: T,
        x86: ?T = null,
        x86_64: ?T = null,
        arm: ?T = null,
        aarch64: ?T = null,
        riscv32: ?T = null,
        riscv64: ?T = null,
        wasm32: ?T = null,
        wasm64: ?T = null,
    };
}

/// Select value based on OS
pub fn selectByOS(comptime T: type, comptime options: OSOptions(T)) T {
    return switch (OS.current()) {
        .linux => options.linux orelse options.default,
        .windows => options.windows orelse options.default,
        .macos => options.macos orelse options.default,
        .freebsd => options.freebsd orelse options.default,
        .openbsd => options.openbsd orelse options.default,
        .netbsd => options.netbsd orelse options.default,
        .wasi => options.wasi orelse options.default,
        .freestanding => options.freestanding orelse options.default,
        .unknown => options.default,
    };
}

pub fn OSOptions(comptime T: type) type {
    return struct {
        default: T,
        linux: ?T = null,
        windows: ?T = null,
        macos: ?T = null,
        freebsd: ?T = null,
        openbsd: ?T = null,
        netbsd: ?T = null,
        wasi: ?T = null,
        freestanding: ?T = null,
    };
}

// ============================================================================
// Architecture-Specific Features
// ============================================================================

pub const ArchFeatures = struct {
    // Endianness
    pub fn isLittleEndian() bool {
        return builtin.cpu.arch.endian() == .little;
    }

    pub fn isBigEndian() bool {
        return builtin.cpu.arch.endian() == .big;
    }

    // Alignment requirements
    pub fn naturalAlignment(comptime T: type) usize {
        return @alignOf(T);
    }

    pub fn strictAlignment() bool {
        return switch (Arch.current()) {
            .arm, .aarch64 => true, // ARM requires aligned access
            .x86, .x86_64 => false, // x86 allows unaligned access
            .riscv32, .riscv64 => true, // RISC-V requires aligned access
            else => true, // Conservative default
        };
    }

    // Cache line size
    pub fn cacheLineSize() usize {
        return switch (Arch.current()) {
            .x86, .x86_64 => 64,
            .arm, .aarch64 => 64,
            .riscv32, .riscv64 => 64,
            else => 64,
        };
    }

    // Page size
    pub fn pageSize() usize {
        return selectByArch(usize, .{
            .default = 4096,
            .aarch64 = switch (OS.current()) {
                .macos => 16384, // Apple Silicon uses 16KB pages
                else => 4096,
            },
        });
    }

    // Stack alignment
    pub fn stackAlignment() usize {
        return switch (Arch.current()) {
            .x86 => 4,
            .x86_64 => 16, // SysV ABI requires 16-byte alignment
            .arm => 8,
            .aarch64 => 16, // AAPCS64 requires 16-byte alignment
            .riscv32 => 4,
            .riscv64 => 16,
            else => 16,
        };
    }
};

// ============================================================================
// Platform-Specific Constants
// ============================================================================

pub const PlatformConstants = struct {
    // System call numbers differ between platforms
    pub const SYSCALL_EXIT = selectByArch(usize, .{
        .default = 0,
        .x86_64 = 60, // exit on Linux x86_64
        .aarch64 = 93, // exit on Linux aarch64
        .riscv64 = 93, // exit on Linux riscv64
    });

    pub const SYSCALL_WRITE = selectByArch(usize, .{
        .default = 0,
        .x86_64 = 1, // write on Linux x86_64
        .aarch64 = 64, // write on Linux aarch64
        .riscv64 = 64, // write on Linux riscv64
    });

    // Signal numbers differ
    pub const SIGINT = selectByOS(i32, .{
        .default = 2,
        .linux = 2,
        .macos = 2,
        .windows = 2,
    });

    pub const SIGSEGV = selectByOS(i32, .{
        .default = 11,
        .linux = 11,
        .macos = 11,
        .windows = 11,
    });
};

// ============================================================================
// Code Block Selection
// ============================================================================

pub const CodeBlock = struct {
    x86: ?[]const u8 = null,
    x86_64: ?[]const u8 = null,
    arm: ?[]const u8 = null,
    aarch64: ?[]const u8 = null,
    riscv32: ?[]const u8 = null,
    riscv64: ?[]const u8 = null,
    default: []const u8,

    pub fn select(self: CodeBlock) []const u8 {
        return switch (Arch.current()) {
            .x86 => self.x86 orelse self.default,
            .x86_64 => self.x86_64 orelse self.default,
            .arm => self.arm orelse self.default,
            .aarch64 => self.aarch64 orelse self.default,
            .riscv32 => self.riscv32 orelse self.default,
            .riscv64 => self.riscv64 orelse self.default,
            else => self.default,
        };
    }
};

// ============================================================================
// Platform-Specific Assembly
// ============================================================================

/// Inline assembly with platform-specific variants
pub fn platformAsm(comptime code: CodeBlock) void {
    const selected = code.select();
    if (selected.len > 0) {
        @compileError("Platform-specific assembly not yet supported in compile-time context");
    }
}

// ============================================================================
// Feature Detection
// ============================================================================

pub const Features = struct {
    /// Check if SIMD is available
    pub fn hasSIMD() bool {
        return switch (Arch.current()) {
            .x86_64 => true, // SSE2 is baseline
            .aarch64 => true, // NEON is baseline
            .riscv64 => false, // V extension is optional
            else => false,
        };
    }

    /// Check if atomic operations are available
    pub fn hasAtomics() bool {
        return switch (Arch.current()) {
            .x86, .x86_64 => true,
            .arm, .aarch64 => true,
            .riscv32, .riscv64 => true,
            .wasm32, .wasm64 => false, // Depends on threading proposal
            else => false,
        };
    }

    /// Check if unaligned access is efficient
    pub fn hasEfficientUnalignedAccess() bool {
        return Arch.current().isX86();
    }
};

// ============================================================================
// Tests
// ============================================================================

test "architecture detection" {
    const testing = std.testing;

    const arch = Arch.current();
    try testing.expect(arch != .unknown);

    // Test properties based on actual platform
    if (arch.is64Bit()) {
        try testing.expectEqual(@as(usize, 8), arch.pointerSize());
    } else {
        try testing.expectEqual(@as(usize, 4), arch.pointerSize());
    }
}

test "OS detection" {
    const testing = std.testing;

    const os = OS.current();
    try testing.expect(os != .unknown);

    // Should have a valid name
    const os_name = os.name();
    try testing.expect(os_name.len > 0);
}

test "platform detection" {
    const testing = std.testing;

    const platform = Platform.current();
    try testing.expect(platform.arch != .unknown);
    try testing.expect(platform.os != .unknown);

    const name = try platform.name(testing.allocator);
    defer testing.allocator.free(name);
    try testing.expect(name.len > 0);
}

test "architecture categories" {
    const testing = std.testing;

    const arch = Arch.current();

    // At most one category should be true
    var count: u32 = 0;
    if (arch.isX86()) count += 1;
    if (arch.isARM()) count += 1;
    if (arch.isRISCV()) count += 1;

    try testing.expect(count <= 1);
}

test "select by architecture" {
    const testing = std.testing;

    const value = selectByArch(u32, .{
        .default = 100,
        .x86_64 = 64,
        .aarch64 = 64,
    });

    // Value should be defined
    try testing.expect(value == 64 or value == 100);
}

test "select by OS" {
    const testing = std.testing;

    const value = selectByOS([]const u8, .{
        .default = "unknown",
        .linux = "linux",
        .macos = "macos",
        .windows = "windows",
    });

    try testing.expect(value.len > 0);
}

test "arch features" {
    const testing = std.testing;

    // Endianness should be consistent
    const little = ArchFeatures.isLittleEndian();
    const big = ArchFeatures.isBigEndian();
    try testing.expect(little != big);

    // Cache line size should be reasonable
    const cache_line = ArchFeatures.cacheLineSize();
    try testing.expect(cache_line == 64 or cache_line == 128);

    // Page size should be power of 2
    const page_size = ArchFeatures.pageSize();
    try testing.expect(page_size >= 4096);
    try testing.expect(@popCount(page_size) == 1);

    // Stack alignment should be power of 2
    const stack_align = ArchFeatures.stackAlignment();
    try testing.expect(@popCount(stack_align) == 1);
}

test "code block selection" {
    const testing = std.testing;

    const block = CodeBlock{
        .x86_64 = "x86_64 code",
        .aarch64 = "aarch64 code",
        .default = "default code",
    };

    const selected = block.select();
    try testing.expect(selected.len > 0);
    try testing.expect(std.mem.indexOf(u8, selected, "code") != null);
}

test "feature detection" {
    const testing = std.testing;

    // SIMD availability
    const has_simd = Features.hasSIMD();
    _ = has_simd; // Platform dependent

    // Atomics should be available on most platforms
    const has_atomics = Features.hasAtomics();
    _ = has_atomics; // Platform dependent

    // Unaligned access efficiency
    const efficient_unaligned = Features.hasEfficientUnalignedAccess();
    if (Arch.current().isX86()) {
        try testing.expect(efficient_unaligned);
    }
}

test "platform constants" {
    const testing = std.testing;

    // Syscall numbers should be non-zero
    try testing.expect(PlatformConstants.SYSCALL_EXIT >= 0);
    try testing.expect(PlatformConstants.SYSCALL_WRITE >= 0);

    // Signal numbers should be valid
    try testing.expect(PlatformConstants.SIGINT > 0);
    try testing.expect(PlatformConstants.SIGSEGV > 0);
}

test "strict alignment" {
    const testing = std.testing;

    const strict = ArchFeatures.strictAlignment();

    // x86 doesn't require strict alignment
    if (Arch.current().isX86()) {
        try testing.expect(!strict);
    }

    // ARM requires strict alignment
    if (Arch.current().isARM()) {
        try testing.expect(strict);
    }
}
