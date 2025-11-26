const std = @import("std");
const Allocator = std.mem.Allocator;

/// Target architecture
pub const Arch = enum {
    x86_64,
    aarch64,
    arm,
    riscv64,
    wasm32,
    wasm64,

    pub fn toString(self: Arch) []const u8 {
        return switch (self) {
            .x86_64 => "x86_64",
            .aarch64 => "aarch64",
            .arm => "arm",
            .riscv64 => "riscv64",
            .wasm32 => "wasm32",
            .wasm64 => "wasm64",
        };
    }

    pub fn fromString(str: []const u8) !Arch {
        if (std.mem.eql(u8, str, "x86_64")) return .x86_64;
        if (std.mem.eql(u8, str, "aarch64")) return .aarch64;
        if (std.mem.eql(u8, str, "arm")) return .arm;
        if (std.mem.eql(u8, str, "riscv64")) return .riscv64;
        if (std.mem.eql(u8, str, "wasm32")) return .wasm32;
        if (std.mem.eql(u8, str, "wasm64")) return .wasm64;
        return error.UnknownArchitecture;
    }

    pub fn pointerSize(self: Arch) usize {
        return switch (self) {
            .x86_64, .aarch64, .riscv64, .wasm64 => 8,
            .arm, .wasm32 => 4,
        };
    }
};

/// Target operating system
pub const OS = enum {
    linux,
    macos,
    windows,
    freebsd,
    openbsd,
    netbsd,
    wasi,
    freestanding,

    pub fn toString(self: OS) []const u8 {
        return switch (self) {
            .linux => "linux",
            .macos => "macos",
            .windows => "windows",
            .freebsd => "freebsd",
            .openbsd => "openbsd",
            .netbsd => "netbsd",
            .wasi => "wasi",
            .freestanding => "freestanding",
        };
    }

    pub fn fromString(str: []const u8) !OS {
        if (std.mem.eql(u8, str, "linux")) return .linux;
        if (std.mem.eql(u8, str, "macos")) return .macos;
        if (std.mem.eql(u8, str, "windows")) return .windows;
        if (std.mem.eql(u8, str, "freebsd")) return .freebsd;
        if (std.mem.eql(u8, str, "openbsd")) return .openbsd;
        if (std.mem.eql(u8, str, "netbsd")) return .netbsd;
        if (std.mem.eql(u8, str, "wasi")) return .wasi;
        if (std.mem.eql(u8, str, "freestanding")) return .freestanding;
        return error.UnknownOS;
    }

    pub fn executableExtension(self: OS) []const u8 {
        return switch (self) {
            .windows => ".exe",
            .wasi => ".wasm",
            else => "",
        };
    }

    pub fn dynamicLibraryExtension(self: OS) []const u8 {
        return switch (self) {
            .windows => ".dll",
            .macos => ".dylib",
            else => ".so",
        };
    }

    pub fn staticLibraryExtension(self: OS) []const u8 {
        return switch (self) {
            .windows => ".lib",
            else => ".a",
        };
    }
};

/// Target ABI
pub const ABI = enum {
    gnu,
    musl,
    msvc,
    android,
    none,

    pub fn toString(self: ABI) []const u8 {
        return switch (self) {
            .gnu => "gnu",
            .musl => "musl",
            .msvc => "msvc",
            .android => "android",
            .none => "none",
        };
    }
};

/// Complete target triple
pub const Target = struct {
    arch: Arch,
    os: OS,
    abi: ABI,

    pub fn init(arch: Arch, os: OS, abi: ABI) Target {
        return .{ .arch = arch, .os = os, .abi = abi };
    }

    /// Parse target triple string (e.g., "x86_64-linux-gnu")
    pub fn parse(str: []const u8) !Target {
        var parts = std.mem.splitScalar(u8, str, '-');

        const arch_str = parts.next() orelse return error.InvalidTargetTriple;
        const os_str = parts.next() orelse return error.InvalidTargetTriple;
        const abi_str = parts.next() orelse "none";

        return Target{
            .arch = try Arch.fromString(arch_str),
            .os = try OS.fromString(os_str),
            .abi = if (std.mem.eql(u8, abi_str, "gnu")) ABI.gnu else if (std.mem.eql(u8, abi_str, "musl")) ABI.musl else if (std.mem.eql(u8, abi_str, "msvc")) ABI.msvc else if (std.mem.eql(u8, abi_str, "android")) ABI.android else ABI.none,
        };
    }

    /// Format as target triple string
    pub fn toString(self: Target, allocator: Allocator) ![]const u8 {
        return std.fmt.allocPrint(
            allocator,
            "{s}-{s}-{s}",
            .{ self.arch.toString(), self.os.toString(), self.abi.toString() },
        );
    }

    /// Get the current host target
    pub fn host() Target {
        const builtin = @import("builtin");
        return Target{
            .arch = switch (builtin.cpu.arch) {
                .x86_64 => .x86_64,
                .aarch64 => .aarch64,
                .arm => .arm,
                .riscv64 => .riscv64,
                .wasm32 => .wasm32,
                .wasm64 => .wasm64,
                else => .x86_64,
            },
            .os = switch (builtin.os.tag) {
                .linux => .linux,
                .macos => .macos,
                .windows => .windows,
                .freebsd => .freebsd,
                .openbsd => .openbsd,
                .netbsd => .netbsd,
                .wasi => .wasi,
                .freestanding => .freestanding,
                else => .linux,
            },
            .abi = switch (builtin.abi) {
                .gnu => .gnu,
                .musl => .musl,
                .msvc => .msvc,
                .android => .android,
                else => .none,
            },
        };
    }

    /// Check if this target can be built on the current host
    pub fn canCrossCompile(self: Target, from_host: Target) bool {
        // Same target is always buildable
        if (std.meta.eql(self, from_host)) return true;

        // x86_64 can cross-compile to most targets
        if (from_host.arch == .x86_64) {
            return switch (self.arch) {
                .x86_64, .aarch64, .arm, .wasm32, .wasm64 => true,
                .riscv64 => true,
            };
        }

        // aarch64 can cross-compile to arm
        if (from_host.arch == .aarch64 and self.arch == .arm) return true;

        return false;
    }
};

/// Cross-compilation toolchain configuration
pub const Toolchain = struct {
    allocator: Allocator,
    target: Target,
    sysroot: ?[]const u8,
    cc: []const u8,
    cxx: []const u8,
    ar: []const u8,
    ld: []const u8,
    strip: []const u8,
    cflags: std.ArrayList([]const u8),
    ldflags: std.ArrayList([]const u8),

    pub fn init(allocator: Allocator, target: Target) Toolchain {
        return .{
            .allocator = allocator,
            .target = target,
            .sysroot = null,
            .cc = "clang",
            .cxx = "clang++",
            .ar = "ar",
            .ld = "ld",
            .strip = "strip",
            .cflags = std.ArrayList([]const u8).init(allocator),
            .ldflags = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Toolchain) void {
        for (self.cflags.items) |flag| {
            self.allocator.free(flag);
        }
        self.cflags.deinit();

        for (self.ldflags.items) |flag| {
            self.allocator.free(flag);
        }
        self.ldflags.deinit();

        if (self.sysroot) |sysroot| {
            self.allocator.free(sysroot);
        }
    }

    /// Detect and configure toolchain for target
    pub fn detect(allocator: Allocator, target: Target) !Toolchain {
        var toolchain = Toolchain.init(allocator, target);

        // Configure target-specific compiler
        const target_triple = try target.toString(allocator);
        defer allocator.free(target_triple);

        try toolchain.cflags.append(try std.fmt.allocPrint(allocator, "--target={s}", .{target_triple}));
        try toolchain.ldflags.append(try std.fmt.allocPrint(allocator, "--target={s}", .{target_triple}));

        // Add architecture-specific flags
        switch (target.arch) {
            .x86_64 => {
                try toolchain.cflags.append(try allocator.dupe(u8, "-march=x86-64"));
            },
            .aarch64 => {
                try toolchain.cflags.append(try allocator.dupe(u8, "-march=armv8-a"));
            },
            .arm => {
                try toolchain.cflags.append(try allocator.dupe(u8, "-march=armv7-a"));
                try toolchain.cflags.append(try allocator.dupe(u8, "-mfloat-abi=hard"));
            },
            .riscv64 => {
                try toolchain.cflags.append(try allocator.dupe(u8, "-march=rv64gc"));
            },
            .wasm32, .wasm64 => {
                // WebAssembly uses different toolchain
                toolchain.cc = "emcc";
                toolchain.cxx = "em++";
                toolchain.ar = "emar";
                toolchain.ld = "emcc";
            },
        }

        // Add OS-specific flags
        switch (target.os) {
            .linux => {
                try toolchain.ldflags.append(try allocator.dupe(u8, "-lc"));
            },
            .macos => {
                try toolchain.ldflags.append(try allocator.dupe(u8, "-lSystem"));
            },
            .windows => {
                try toolchain.ldflags.append(try allocator.dupe(u8, "-lmsvcrt"));
            },
            .freestanding => {
                try toolchain.cflags.append(try allocator.dupe(u8, "-ffreestanding"));
                try toolchain.cflags.append(try allocator.dupe(u8, "-nostdlib"));
            },
            else => {},
        }

        return toolchain;
    }

    /// Get complete compiler command
    pub fn getCompilerCommand(self: *const Toolchain, allocator: Allocator) ![][]const u8 {
        var cmd = std.ArrayList([]const u8).init(allocator);

        try cmd.append(try allocator.dupe(u8, self.cc));

        for (self.cflags.items) |flag| {
            try cmd.append(try allocator.dupe(u8, flag));
        }

        if (self.sysroot) |sysroot| {
            try cmd.append(try std.fmt.allocPrint(allocator, "--sysroot={s}", .{sysroot}));
        }

        return cmd.toOwnedSlice();
    }

    /// Get complete linker command
    pub fn getLinkerCommand(self: *const Toolchain, allocator: Allocator) ![][]const u8 {
        var cmd = std.ArrayList([]const u8).init(allocator);

        try cmd.append(try allocator.dupe(u8, self.ld));

        for (self.ldflags.items) |flag| {
            try cmd.append(try allocator.dupe(u8, flag));
        }

        if (self.sysroot) |sysroot| {
            try cmd.append(try std.fmt.allocPrint(allocator, "--sysroot={s}", .{sysroot}));
        }

        return cmd.toOwnedSlice();
    }
};

/// Common cross-compilation targets
pub const CommonTargets = struct {
    pub const linux_x86_64 = Target.init(.x86_64, .linux, .gnu);
    pub const linux_aarch64 = Target.init(.aarch64, .linux, .gnu);
    pub const linux_arm = Target.init(.arm, .linux, .gnu);
    pub const macos_x86_64 = Target.init(.x86_64, .macos, .none);
    pub const macos_aarch64 = Target.init(.aarch64, .macos, .none);
    pub const windows_x86_64 = Target.init(.x86_64, .windows, .msvc);
    pub const wasm32 = Target.init(.wasm32, .wasi, .none);
    pub const freestanding_x86_64 = Target.init(.x86_64, .freestanding, .none);
    pub const freestanding_aarch64 = Target.init(.aarch64, .freestanding, .none);
};

test "Target - parse and format" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const target = try Target.parse("x86_64-linux-gnu");
    try testing.expectEqual(Arch.x86_64, target.arch);
    try testing.expectEqual(OS.linux, target.os);
    try testing.expectEqual(ABI.gnu, target.abi);

    const str = try target.toString(allocator);
    defer allocator.free(str);
    try testing.expectEqualStrings("x86_64-linux-gnu", str);
}

test "Target - host" {
    const testing = std.testing;

    const host = Target.host();
    try testing.expect(host.arch != @as(Arch, undefined));
    try testing.expect(host.os != @as(OS, undefined));
}

test "Toolchain - detect" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var toolchain = try Toolchain.detect(allocator, CommonTargets.linux_x86_64);
    defer toolchain.deinit();

    try testing.expect(toolchain.cflags.items.len > 0);
}
