// Home Programming Language - C Type Definitions
// Standard C types with platform-specific sizes

const std = @import("std");

// ============================================================================
// Standard C Integer Types
// ============================================================================

// Exact-width integer types (from stdint.h)
pub const int8_t = i8;
pub const int16_t = i16;
pub const int32_t = i32;
pub const int64_t = i64;

pub const uint8_t = u8;
pub const uint16_t = u16;
pub const uint32_t = u32;
pub const uint64_t = u64;

// Platform-dependent C types (re-export built-ins for convenience)
// Note: Zig provides these as built-in types, we just re-export them

// Special integer types
pub const size_t = usize;
pub const ssize_t = isize;
pub const ptrdiff_t = isize;
pub const intptr_t = isize;
pub const uintptr_t = usize;

// ============================================================================
// Floating Point Types
// ============================================================================

pub const c_float = f32;
pub const c_double = f64;

// ============================================================================
// Boolean Type
// ============================================================================

pub const c_bool = bool;

// ============================================================================
// Pointer Types
// ============================================================================

pub const c_void = anyopaque;
pub const c_void_ptr = ?*anyopaque;
pub const c_const_void_ptr = ?*const anyopaque;

/// NULL pointer constant
pub const NULL = @as(?*anyopaque, null);

// ============================================================================
// String Types
// ============================================================================

/// C null-terminated string
pub const c_string = [*:0]const u8;

/// Mutable C null-terminated string
pub const c_string_mut = [*:0]u8;

// ============================================================================
// Function Pointer Types
// ============================================================================

/// Generic C function pointer
pub const c_fn_ptr = ?*const anyopaque;

// ============================================================================
// Type Size Constants
// ============================================================================

pub const Sizes = struct {
    pub const CHAR_SIZE = @sizeOf(u8);
    pub const SHORT_SIZE = @sizeOf(i16);
    pub const INT_SIZE = @sizeOf(i32);
    pub const LONG_SIZE = @sizeOf(isize);
    pub const LONGLONG_SIZE = @sizeOf(i64);
    pub const POINTER_SIZE = @sizeOf(?*anyopaque);
    pub const FLOAT_SIZE = @sizeOf(c_float);
    pub const DOUBLE_SIZE = @sizeOf(c_double);
};

// ============================================================================
// Type Limits
// ============================================================================

pub const Limits = struct {
    // Character limits
    pub const CHAR_MIN: u8 = 0;
    pub const CHAR_MAX: u8 = 255;
    pub const SCHAR_MIN: i8 = -128;
    pub const SCHAR_MAX: i8 = 127;
    pub const UCHAR_MAX: u8 = 255;

    // Short limits
    pub const SHRT_MIN: i16 = std.math.minInt(i16);
    pub const SHRT_MAX: i16 = std.math.maxInt(i16);
    pub const USHRT_MAX: u16 = std.math.maxInt(u16);

    // Int limits
    pub const INT_MIN: i32 = std.math.minInt(i32);
    pub const INT_MAX: i32 = std.math.maxInt(i32);
    pub const UINT_MAX: u32 = std.math.maxInt(u32);

    // Long limits
    pub const LONG_MIN: isize = std.math.minInt(isize);
    pub const LONG_MAX: isize = std.math.maxInt(isize);
    pub const ULONG_MAX: usize = std.math.maxInt(usize);

    // Long long limits
    pub const LLONG_MIN: i64 = std.math.minInt(i64);
    pub const LLONG_MAX: i64 = std.math.maxInt(i64);
    pub const ULLONG_MAX: u64 = std.math.maxInt(u64);
};

// ============================================================================
// Type Conversion Utilities
// ============================================================================

/// Convert Zig bool to C bool
pub fn toC_bool(value: bool) c_int {
    return if (value) 1 else 0;
}

/// Convert C bool to Zig bool
pub fn fromC_bool(value: c_int) bool {
    return value != 0;
}

/// Check if pointer is NULL
pub fn isNull(ptr: anytype) bool {
    return ptr == null;
}

/// Check if pointer is not NULL
pub fn notNull(ptr: anytype) bool {
    return ptr != null;
}

// ============================================================================
// Common C Type Aliases (from standard headers)
// ============================================================================

// time.h
pub const time_t = isize;
pub const clock_t = isize;

// stdio.h
pub const FILE = anyopaque;

// errno.h
pub const errno_t = i32;

// ============================================================================
// Platform-Specific Types
// ============================================================================

pub const PlatformTypes = struct {
    // File descriptors
    pub const fd_t = i32;

    // Process IDs
    pub const pid_t = i32;

    // Thread IDs (platform-specific, simplified)
    pub const pthread_t = usize;

    // Socket types
    pub const socket_t = i32;
    pub const socklen_t = u32;
};

// ============================================================================
// Type Checking Utilities
// ============================================================================

/// Check if type is a C integer type
pub fn isCInt(comptime T: type) bool {
    return T == i8 or T == i16 or T == i32 or
        T == i64 or T == isize or
        T == u8 or T == u16 or T == u32 or
        T == u64 or T == usize;
}

/// Check if type is a C floating point type
pub fn isCFloat(comptime T: type) bool {
    return T == c_float or T == c_double or T == f64;
}

/// Check if type is a C pointer type
pub fn isCPtr(comptime T: type) bool {
    const info = @typeInfo(T);
    return info == .pointer or info == .optional;
}

// ============================================================================
// Tests
// ============================================================================

test "C integer types" {
    const testing = std.testing;

    try testing.expectEqual(@as(usize, 1), @sizeOf(int8_t));
    try testing.expectEqual(@as(usize, 2), @sizeOf(int16_t));
    try testing.expectEqual(@as(usize, 4), @sizeOf(int32_t));
    try testing.expectEqual(@as(usize, 8), @sizeOf(int64_t));
}

test "C pointer types" {
    const testing = std.testing;

    const ptr: c_void_ptr = null;
    try testing.expect(ptr == NULL);
    try testing.expect(isNull(ptr));
    try testing.expect(!notNull(ptr));
}

test "Bool conversion" {
    const testing = std.testing;

    try testing.expectEqual(@as(i32, 1), toC_bool(true));
    try testing.expectEqual(@as(i32, 0), toC_bool(false));

    try testing.expectEqual(true, fromC_bool(1));
    try testing.expectEqual(false, fromC_bool(0));
    try testing.expectEqual(true, fromC_bool(42));
}

test "Type checking" {
    const testing = std.testing;

    try testing.expect(isCInt(i32));
    try testing.expect(isCInt(usize));
    try testing.expect(!isCInt(f32));

    try testing.expect(isCFloat(c_float));
    try testing.expect(isCFloat(c_double));
    try testing.expect(!isCFloat(i32));

    try testing.expect(isCPtr(*i32));
    try testing.expect(isCPtr(?*const u8));
    try testing.expect(!isCPtr(i32));
}

test "Type limits" {
    const testing = std.testing;

    try testing.expect(Limits.INT_MIN < 0);
    try testing.expect(Limits.INT_MAX > 0);
    try testing.expect(Limits.UINT_MAX > 0);
}
