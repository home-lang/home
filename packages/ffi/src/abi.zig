// Home Programming Language - ABI (Application Binary Interface) Support
// Platform-specific ABI details and compatibility layers

const std = @import("std");
const builtin = @import("builtin");

// ============================================================================
// Platform Detection
// ============================================================================

pub const Platform = enum {
    linux_x86_64,
    linux_aarch64,
    macos_x86_64,
    macos_aarch64,
    windows_x86_64,
    windows_aarch64,
    other,

    pub fn current() Platform {
        return switch (builtin.os.tag) {
            .linux => switch (builtin.cpu.arch) {
                .x86_64 => .linux_x86_64,
                .aarch64 => .linux_aarch64,
                else => .other,
            },
            .macos => switch (builtin.cpu.arch) {
                .x86_64 => .macos_x86_64,
                .aarch64 => .macos_aarch64,
                else => .other,
            },
            .windows => switch (builtin.cpu.arch) {
                .x86_64 => .windows_x86_64,
                .aarch64 => .windows_aarch64,
                else => .other,
            },
            else => .other,
        };
    }

    pub fn name(self: Platform) []const u8 {
        return switch (self) {
            .linux_x86_64 => "Linux x86_64",
            .linux_aarch64 => "Linux ARM64",
            .macos_x86_64 => "macOS x86_64",
            .macos_aarch64 => "macOS ARM64",
            .windows_x86_64 => "Windows x86_64",
            .windows_aarch64 => "Windows ARM64",
            .other => "Unknown",
        };
    }
};

// ============================================================================
// Calling Conventions by Platform
// ============================================================================

pub const CallingConvention = enum {
    /// Standard C calling convention (platform-specific)
    c,
    /// System V AMD64 ABI (Linux, macOS x86_64)
    sysv,
    /// Microsoft x64 calling convention (Windows x86_64)
    win64,
    /// ARM AAPCS (ARM Architecture Procedure Call Standard)
    aapcs,
    /// ARM64 calling convention
    aapcs64,
    /// x86 stdcall (Windows 32-bit)
    stdcall,
    /// x86 fastcall
    fastcall,
    /// x86 thiscall (C++ methods on Windows)
    thiscall,

    /// Get the default C calling convention for current platform
    pub fn platformDefault() CallingConvention {
        return switch (Platform.current()) {
            .linux_x86_64, .macos_x86_64 => .sysv,
            .windows_x86_64 => .win64,
            .linux_aarch64, .macos_aarch64, .windows_aarch64 => .aapcs64,
            .other => .c,
        };
    }
};

// ============================================================================
// Type Sizes and Alignment
// ============================================================================

pub const TypeInfo = struct {
    size: usize,
    alignment: usize,
};

/// Get platform-specific type information
pub fn getTypeInfo(comptime T: type) TypeInfo {
    return .{
        .size = @sizeOf(T),
        .alignment = @alignOf(T),
    };
}

/// C type sizes (may vary by platform)
pub const CSizes = struct {
    pub const char = @sizeOf(u8);
    pub const short = @sizeOf(c_short);
    pub const int = @sizeOf(c_int);
    pub const long = @sizeOf(c_long);
    pub const long_long = @sizeOf(c_longlong);
    pub const pointer = @sizeOf(*anyopaque);
    pub const float = @sizeOf(f32);
    pub const double = @sizeOf(f64);
};

/// Ensure correct alignment for C types
pub fn alignedAlloc(allocator: std.mem.Allocator, comptime T: type, n: usize) ![]align(@alignOf(T)) T {
    return try allocator.alignedAlloc(T, @alignOf(T), n);
}

// ============================================================================
// Structure Padding and Layout
// ============================================================================

/// Calculate padding needed for alignment
pub fn paddingForAlignment(offset: usize, alignment: usize) usize {
    const misalignment = offset % alignment;
    if (misalignment == 0) return 0;
    return alignment - misalignment;
}

/// Calculate structure size with proper alignment
pub fn structSize(field_sizes: []const usize, field_alignments: []const usize) usize {
    std.debug.assert(field_sizes.len == field_alignments.len);

    var offset: usize = 0;
    var max_align: usize = 1;

    for (field_sizes, field_alignments) |size, alignment| {
        max_align = @max(max_align, alignment);
        offset += paddingForAlignment(offset, alignment);
        offset += size;
    }

    // Add final padding for struct alignment
    offset += paddingForAlignment(offset, max_align);

    return offset;
}

/// Get field offset in a structure
pub fn fieldOffset(field_sizes: []const usize, field_alignments: []const usize, field_index: usize) usize {
    std.debug.assert(field_sizes.len == field_alignments.len);
    std.debug.assert(field_index < field_sizes.len);

    var offset: usize = 0;

    for (0..field_index) |i| {
        offset += paddingForAlignment(offset, field_alignments[i]);
        offset += field_sizes[i];
    }

    offset += paddingForAlignment(offset, field_alignments[field_index]);

    return offset;
}

// ============================================================================
// Endianness
// ============================================================================

pub const Endian = enum {
    little,
    big,

    pub fn native() Endian {
        return switch (builtin.cpu.arch.endian()) {
            .little => .little,
            .big => .big,
        };
    }

    pub fn isBigEndian() bool {
        return native() == .big;
    }

    pub fn isLittleEndian() bool {
        return native() == .little;
    }
};

/// Swap bytes for different endianness
pub fn byteSwap(comptime T: type, value: T) T {
    return @byteSwap(value);
}

// ============================================================================
// Register Information (for calling conventions)
// ============================================================================

pub const RegisterClass = enum {
    integer,
    sse, // x86 SSE/AVX
    x87, // x86 floating point
    memory,
};

/// Argument passing information (simplified)
pub const ArgInfo = struct {
    class: RegisterClass,
    /// True if passed in register, false if on stack
    in_register: bool,
    /// Register number or stack offset
    location: usize,
};

/// Get argument passing info for System V AMD64 ABI (simplified)
pub fn getSysVArgInfo(arg_index: usize, comptime T: type) ArgInfo {
    const type_info = @typeInfo(T);

    // Integer/pointer arguments (first 6 in registers: RDI, RSI, RDX, RCX, R8, R9)
    switch (type_info) {
        .int, .pointer => {
            if (arg_index < 6) {
                return .{
                    .class = .integer,
                    .in_register = true,
                    .location = arg_index,
                };
            } else {
                return .{
                    .class = .integer,
                    .in_register = false,
                    .location = (arg_index - 6) * 8,
                };
            }
        },
        // Float arguments (first 8 in XMM0-XMM7)
        .float => {
            if (arg_index < 8) {
                return .{
                    .class = .sse,
                    .in_register = true,
                    .location = arg_index,
                };
            } else {
                return .{
                    .class = .sse,
                    .in_register = false,
                    .location = (arg_index - 8) * 8,
                };
            }
        },
        else => {},
    }

    // Default to memory
    return .{
        .class = .memory,
        .in_register = false,
        .location = arg_index * 8,
    };
}

/// Get argument passing info for Win64 ABI (simplified)
pub fn getWin64ArgInfo(arg_index: usize, comptime T: type) ArgInfo {
    const type_info = @typeInfo(T);

    // First 4 arguments in RCX, RDX, R8, R9 (or XMM0-XMM3 for floats)
    if (arg_index < 4) {
        switch (type_info) {
            .float => {
                return .{
                    .class = .sse,
                    .in_register = true,
                    .location = arg_index,
                };
            },
            else => {
                return .{
                    .class = .integer,
                    .in_register = true,
                    .location = arg_index,
                };
            },
        }
    }

    // Rest on stack
    return .{
        .class = .memory,
        .in_register = false,
        .location = arg_index * 8,
    };
}

// ============================================================================
// Stack Alignment
// ============================================================================

pub const StackAlignment = struct {
    pub const x86_64 = 16;
    pub const aarch64 = 16;
    pub const x86 = 4;

    pub fn required() usize {
        return switch (builtin.cpu.arch) {
            .x86_64 => x86_64,
            .aarch64 => aarch64,
            .x86 => x86,
            else => @sizeOf(usize),
        };
    }

    pub fn align_(size: usize) usize {
        const alignment = required();
        const remainder = size % alignment;
        if (remainder == 0) return size;
        return size + (alignment - remainder);
    }
};

// ============================================================================
// Symbol Mangling
// ============================================================================

pub const Mangling = struct {
    /// Check if name needs mangling for platform
    pub fn needsMangling(platform: Platform) bool {
        return switch (platform) {
            .windows_x86_64, .windows_aarch64 => true,
            else => false,
        };
    }

    /// Get mangled symbol name (simplified - just for demonstration)
    pub fn mangle(allocator: std.mem.Allocator, name: []const u8, platform: Platform) ![]const u8 {
        if (!needsMangling(platform)) {
            return try allocator.dupe(u8, name);
        }

        // Windows may add underscore prefix
        return try std.fmt.allocPrint(allocator, "_{s}", .{name});
    }

    /// Demangle symbol name
    pub fn demangle(allocator: std.mem.Allocator, mangled: []const u8) ![]const u8 {
        if (mangled.len > 0 and mangled[0] == '_') {
            return try allocator.dupe(u8, mangled[1..]);
        }
        return try allocator.dupe(u8, mangled);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Platform detection" {
    const testing = std.testing;
    const platform = Platform.current();
    const platform_name = platform.name();

    try testing.expect(platform_name.len > 0);
}

test "Calling convention" {
    const conv = CallingConvention.platformDefault();
    _ = conv;
}

test "Type info" {
    const testing = std.testing;

    const info = getTypeInfo(i32);
    try testing.expectEqual(@as(usize, 4), info.size);
    try testing.expectEqual(@as(usize, 4), info.alignment);
}

test "Padding calculation" {
    const testing = std.testing;

    try testing.expectEqual(@as(usize, 0), paddingForAlignment(0, 4));
    try testing.expectEqual(@as(usize, 3), paddingForAlignment(1, 4));
    try testing.expectEqual(@as(usize, 2), paddingForAlignment(2, 4));
    try testing.expectEqual(@as(usize, 1), paddingForAlignment(3, 4));
    try testing.expectEqual(@as(usize, 0), paddingForAlignment(4, 4));
}

test "Struct size calculation" {
    const testing = std.testing;

    // struct { i8, i32 } should be 8 bytes (1 byte + 3 padding + 4 bytes)
    const sizes = [_]usize{ 1, 4 };
    const alignments = [_]usize{ 1, 4 };

    const size = structSize(&sizes, &alignments);
    try testing.expectEqual(@as(usize, 8), size);
}

test "Field offset calculation" {
    const testing = std.testing;

    // struct { i8, i32, i8 }
    const sizes = [_]usize{ 1, 4, 1 };
    const alignments = [_]usize{ 1, 4, 1 };

    try testing.expectEqual(@as(usize, 0), fieldOffset(&sizes, &alignments, 0));
    try testing.expectEqual(@as(usize, 4), fieldOffset(&sizes, &alignments, 1)); // 1 + 3 padding
    try testing.expectEqual(@as(usize, 8), fieldOffset(&sizes, &alignments, 2));
}

test "Endianness" {
    const endian = Endian.native();
    _ = endian;
}

test "Stack alignment" {
    const testing = std.testing;
    const alignment = StackAlignment.required();

    try testing.expect(alignment >= 4);
    try testing.expect(alignment <= 16);

    try testing.expectEqual(@as(usize, 16), StackAlignment.align_(15));
    try testing.expectEqual(@as(usize, 16), StackAlignment.align_(16));
}

test "Symbol mangling" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const name = "myfunction";
    const mangled = try Mangling.mangle(allocator, name, .linux_x86_64);
    defer allocator.free(mangled);

    try testing.expectEqualStrings(name, mangled);
}

test "Argument info - SysV" {
    const info1 = getSysVArgInfo(0, i32);
    _ = info1;

    const info2 = getSysVArgInfo(7, i32); // Should be on stack
    _ = info2;
}

test "Argument info - Win64" {
    const info1 = getWin64ArgInfo(0, i32);
    _ = info1;

    const info2 = getWin64ArgInfo(5, i32); // Should be on stack
    _ = info2;
}
