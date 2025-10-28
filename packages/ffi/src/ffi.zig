// Home Programming Language - FFI/C Compatibility Layer
// Provides seamless interoperability with C libraries and drivers
//
// Features:
// - C ABI compatibility
// - External function declarations
// - Structure layout compatibility
// - Multiple calling conventions
// - Variadic function support
// - Type conversions
// - Header generation

const std = @import("std");
const Basics = @import("basics");

// ============================================================================
// Core FFI Types
// ============================================================================

// Note: C types (c_char, c_int, c_long, etc.) are primitives in Zig
// We provide additional type aliases for convenience
pub const ssize_t = isize;
pub const ptrdiff_t = isize;
pub const wchar_t = u32;

// ============================================================================
// Calling Conventions
// ============================================================================

pub const CallingConvention = enum {
    C,           // Standard C calling convention
    Stdcall,     // Windows stdcall (callee cleans stack)
    Fastcall,    // Fastcall (arguments in registers)
    Vectorcall,  // Vectorcall (SIMD optimization)
    Thiscall,    // C++ member function call
    AAPCS,       // ARM AAPCS
    SysV,        // System V AMD64 ABI
    Win64,       // Windows x64 calling convention
    Inline,      // Inline assembly
    Naked,       // No prologue/epilogue
    Interrupt,   // Interrupt handler
    Signal,      // Signal handler

    pub fn toZig(self: CallingConvention) std.builtin.CallingConvention {
        return switch (self) {
            .C => .c,
            .Stdcall => .stdcall,
            .Fastcall => .fastcall,
            .Vectorcall => .vectorcall,
            .Thiscall => .thiscall,
            .AAPCS => .aapcs,
            .SysV => .sysv,
            .Win64 => .win64,
            .Inline => .@"inline",
            .Naked => .naked,
            .Interrupt => .interrupt,
            .Signal => .signal,
        };
    }
};

// ============================================================================
// External Function Wrapper
// ============================================================================

pub fn ExternFn(comptime return_type: type, comptime params: []const type) type {
    return struct {
        ptr: *const anyopaque,
        convention: CallingConvention,

        pub const ReturnType = return_type;
        pub const ParamTypes = params;

        pub fn init(func_ptr: anytype, convention: CallingConvention) @This() {
            return .{
                .ptr = @ptrCast(func_ptr),
                .convention = convention,
            };
        }
    };
}

// ============================================================================
// C String Utilities
// ============================================================================

pub const CString = struct {
    /// Convert Home string to null-terminated C string
    pub fn fromHome(allocator: Basics.Allocator, home_str: []const u8) ![:0]const u8 {
        const c_str = try allocator.allocSentinel(u8, home_str.len, 0);
        @memcpy(c_str, home_str);
        return c_str;
    }

    /// Convert C string to Home string
    pub fn toHome(c_str: [*:0]const u8) []const u8 {
        return std.mem.span(c_str);
    }

    /// Get length of C string
    pub fn len(c_str: [*:0]const u8) usize {
        return std.mem.len(c_str);
    }

    /// Compare C strings
    pub fn cmp(a: [*:0]const u8, b: [*:0]const u8) c_int {
        var i: usize = 0;
        while (a[i] == b[i] and a[i] != 0) : (i += 1) {}
        return @as(c_int, a[i]) - @as(c_int, b[i]);
    }

    /// Copy C string
    pub fn copy(dest: [*]u8, src: [*:0]const u8) [*:0]u8 {
        var i: usize = 0;
        while (src[i] != 0) : (i += 1) {
            dest[i] = src[i];
        }
        dest[i] = 0;
        return @ptrCast(dest);
    }

    /// Concatenate C strings
    pub fn concat(allocator: Basics.Allocator, a: [*:0]const u8, b: [*:0]const u8) ![:0]u8 {
        const len_a = len(a);
        const len_b = len(b);
        const result = try allocator.allocSentinel(u8, len_a + len_b, 0);
        @memcpy(result[0..len_a], a[0..len_a]);
        @memcpy(result[len_a..][0..len_b], b[0..len_b]);
        return result;
    }
};

// ============================================================================
// Structure Layout Compatibility
// ============================================================================

/// Ensure C-compatible struct layout
pub fn CStruct(comptime T: type) type {
    return extern struct {
        pub const WrappedType = T;
        value: T,

        pub fn init(val: T) @This() {
            return .{ .value = val };
        }

        pub fn get(self: *const @This()) T {
            return self.value;
        }

        pub fn set(self: *@This(), val: T) void {
            self.value = val;
        }
    };
}

/// C-compatible union (placeholder - create manually)
/// Note: In real usage, define extern union directly with your fields
pub fn CUnion(comptime T: type) type {
    return extern union {
        value: T,
    };
}

/// Packed C struct (no padding)
pub fn CPackedStruct(comptime T: type) type {
    return packed struct {
        pub const WrappedType = T;
        value: T,
    };
}

// ============================================================================
// Type Conversions
// ============================================================================

pub const Convert = struct {
    /// Convert Home integer to C integer
    pub fn toC(comptime CType: type, value: anytype) CType {
        return @intCast(value);
    }

    /// Convert C integer to Home integer
    pub fn fromC(comptime HomeType: type, value: anytype) HomeType {
        return @intCast(value);
    }

    /// Convert Home pointer to C pointer
    pub fn ptrToC(comptime T: type, ptr: *T) *anyopaque {
        return @ptrCast(ptr);
    }

    /// Convert C pointer to Home pointer
    pub fn ptrFromC(comptime T: type, c_ptr: *anyopaque) *T {
        return @ptrCast(@alignCast(c_ptr));
    }

    /// Convert Home array to C array pointer
    pub fn arrayToC(comptime T: type, array: []T) [*]T {
        return @ptrCast(array.ptr);
    }

    /// Convert C array pointer to Home slice (requires length)
    pub fn arrayFromC(comptime T: type, c_array: [*]T, length: usize) []T {
        return c_array[0..length];
    }
};

// ============================================================================
// Variadic Function Support
// ============================================================================

pub const VaList = extern struct {
    // Platform-specific va_list implementation
    gp_offset: c_uint,
    fp_offset: c_uint,
    overflow_arg_area: ?*anyopaque,
    reg_save_area: ?*anyopaque,

    pub fn start(args: anytype) VaList {
        _ = args;
        // This is a simplified implementation
        // Real implementation would depend on platform ABI
        return VaList{
            .gp_offset = 0,
            .fp_offset = 0,
            .overflow_arg_area = null,
            .reg_save_area = null,
        };
    }

    pub fn arg(self: *VaList, comptime T: type) T {
        // Platform-specific argument extraction
        _ = self;
        @compileError("Variadic arguments require platform-specific implementation");
    }

    pub fn end(self: *VaList) void {
        _ = self;
        // Cleanup if needed
    }
};

// Variadic function wrapper
pub fn VariadicFn(comptime fixed_params: []const type, comptime return_type: type) type {
    return struct {
        pub const FixedParams = fixed_params;
        pub const ReturnType = return_type;

        ptr: *const anyopaque,

        pub fn init(func_ptr: anytype) @This() {
            return .{ .ptr = @ptrCast(func_ptr) };
        }
    };
}

// ============================================================================
// C Library Functions (Standard Library)
// ============================================================================

pub const CStdLib = struct {
    // Memory functions
    pub extern "c" fn malloc(size: size_t) ?*anyopaque;
    pub extern "c" fn calloc(count: size_t, size: size_t) ?*anyopaque;
    pub extern "c" fn realloc(ptr: ?*anyopaque, size: size_t) ?*anyopaque;
    pub extern "c" fn free(ptr: ?*anyopaque) void;
    pub extern "c" fn memcpy(dest: ?*anyopaque, src: ?*const anyopaque, n: size_t) ?*anyopaque;
    pub extern "c" fn memmove(dest: ?*anyopaque, src: ?*const anyopaque, n: size_t) ?*anyopaque;
    pub extern "c" fn memset(s: ?*anyopaque, c: c_int, n: size_t) ?*anyopaque;
    pub extern "c" fn memcmp(s1: ?*const anyopaque, s2: ?*const anyopaque, n: size_t) c_int;

    // String functions
    pub extern "c" fn strlen(s: [*:0]const u8) size_t;
    pub extern "c" fn strcmp(s1: [*:0]const u8, s2: [*:0]const u8) c_int;
    pub extern "c" fn strncmp(s1: [*:0]const u8, s2: [*:0]const u8, n: size_t) c_int;
    pub extern "c" fn strcpy(dest: [*:0]u8, src: [*:0]const u8) [*:0]u8;
    pub extern "c" fn strncpy(dest: [*:0]u8, src: [*:0]const u8, n: size_t) [*:0]u8;
    pub extern "c" fn strcat(dest: [*:0]u8, src: [*:0]const u8) [*:0]u8;
    pub extern "c" fn strchr(s: [*:0]const u8, c: c_int) ?[*:0]const u8;

    // I/O functions
    pub extern "c" fn printf(format: [*:0]const u8, ...) c_int;
    pub extern "c" fn sprintf(str: [*:0]u8, format: [*:0]const u8, ...) c_int;
    pub extern "c" fn snprintf(str: [*:0]u8, size: size_t, format: [*:0]const u8, ...) c_int;

    // File I/O
    pub extern "c" fn fopen(filename: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
    pub extern "c" fn fclose(stream: ?*anyopaque) c_int;
    pub extern "c" fn fread(ptr: ?*anyopaque, size: size_t, nmemb: size_t, stream: ?*anyopaque) size_t;
    pub extern "c" fn fwrite(ptr: ?*const anyopaque, size: size_t, nmemb: size_t, stream: ?*anyopaque) size_t;

    // Conversion functions
    pub extern "c" fn atoi(s: [*:0]const u8) c_int;
    pub extern "c" fn atol(s: [*:0]const u8) c_long;
    pub extern "c" fn atof(s: [*:0]const u8) c_double;
    pub extern "c" fn strtol(s: [*:0]const u8, endptr: ?*[*:0]u8, base: c_int) c_long;
    pub extern "c" fn strtod(s: [*:0]const u8, endptr: ?*[*:0]u8) c_double;

    // Process control
    pub extern "c" fn exit(status: c_int) noreturn;
    pub extern "c" fn abort() noreturn;
    pub extern "c" fn atexit(func: *const fn () callconv(.C) void) c_int;

    // Math functions
    pub extern "c" fn sqrt(x: c_double) c_double;
    pub extern "c" fn pow(x: c_double, y: c_double) c_double;
    pub extern "c" fn sin(x: c_double) c_double;
    pub extern "c" fn cos(x: c_double) c_double;
    pub extern "c" fn tan(x: c_double) c_double;
};

// ============================================================================
// Function Binding Helpers
// ============================================================================

pub const Bind = struct {
    /// Metadata for a C function binding
    pub fn cFunc(
        comptime name: []const u8,
        comptime return_type: type,
        comptime params: []const type,
        comptime convention: CallingConvention,
    ) type {
        return struct {
            pub const FuncName = name;
            pub const ReturnType = return_type;
            pub const ParamTypes = params;
            pub const Convention = convention;

            // Note: Actual extern declarations must be written manually
            // Example: pub extern "c" fn funcname(...) callconv(.C) return_type;
        };
    }

    /// Create wrapper function with type safety
    pub fn wrap(comptime CFunc: type, comptime wrapper_fn: anytype) type {
        return struct {
            pub fn call(args: anytype) CFunc.ReturnType {
                return wrapper_fn(args);
            }
        };
    }
};

// ============================================================================
// Callback Support
// ============================================================================

pub fn Callback(comptime return_type: type, comptime params: []const type) type {
    return struct {
        pub const ReturnType = return_type;
        pub const ParamTypes = params;

        ptr: *const anyopaque,
        context: ?*anyopaque,

        pub fn init(func: anytype, ctx: ?*anyopaque) @This() {
            return .{
                .ptr = @ptrCast(func),
                .context = ctx,
            };
        }

        pub fn toCFunction(self: @This()) *const anyopaque {
            _ = self;
            return self.ptr;
        }
    };
}

// ============================================================================
// Error Handling Integration
// ============================================================================

pub const CError = error{
    NullPointer,
    InvalidParameter,
    BufferTooSmall,
    ConversionFailed,
    AllocationFailed,
    InvalidCString,
    CallbackFailed,
};

pub fn checkNull(ptr: anytype) !@TypeOf(ptr) {
    if (ptr == null) return CError.NullPointer;
    return ptr;
}

pub fn checkResult(result: c_int) !void {
    if (result < 0) return CError.InvalidParameter;
}

// ============================================================================
// C Allocator Wrapper
// ============================================================================

pub const CAllocator = struct {
    pub fn allocator() Basics.Allocator {
        return .{
            .ptr = undefined,
            .vtable = &vtable,
        };
    }

    const vtable = Basics.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .free = free,
    };

    fn alloc(_: *anyopaque, len: usize, _: u8, _: usize) ?[*]u8 {
        const ptr = CStdLib.malloc(len) orelse return null;
        return @ptrCast(ptr);
    }

    fn resize(_: *anyopaque, buf: []u8, _: u8, new_len: usize, _: usize) bool {
        const new_ptr = CStdLib.realloc(buf.ptr, new_len) orelse return false;
        _ = new_ptr;
        return true;
    }

    fn free(_: *anyopaque, buf: []u8, _: u8, _: usize) void {
        CStdLib.free(buf.ptr);
    }
};

// ============================================================================
// Alignment Utilities
// ============================================================================

pub const Alignment = struct {
    /// Get C alignment for type
    pub fn ofType(comptime T: type) comptime_int {
        return @alignOf(T);
    }

    /// Align pointer to specified alignment
    pub fn alignPtr(ptr: usize, alignment: usize) usize {
        return (ptr + alignment - 1) & ~(alignment - 1);
    }

    /// Check if pointer is aligned
    pub fn isAligned(ptr: usize, alignment: usize) bool {
        return ptr % alignment == 0;
    }

    /// Align size up to specified alignment
    pub fn alignSize(size: usize, alignment: usize) usize {
        return (size + alignment - 1) & ~(alignment - 1);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "C types compatibility" {
    const testing = std.testing;

    // Verify C type sizes match expectations
    try testing.expectEqual(@as(usize, 1), @sizeOf(c_char));
    try testing.expectEqual(@as(usize, 4), @sizeOf(c_int));
    try testing.expectEqual(@as(usize, 4), @sizeOf(f32));
    try testing.expectEqual(@as(usize, 8), @sizeOf(f64));
}

test "C string conversion" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const home_str = "Hello, World!";
    const c_str = try CString.fromHome(allocator, home_str);
    defer allocator.free(c_str);

    try testing.expectEqual(@as(usize, 13), CString.len(c_str));

    const back_to_home = CString.toHome(c_str);
    try testing.expectEqualStrings(home_str, back_to_home);
}

test "type conversions" {
    const testing = std.testing;

    const home_int: i64 = 42;
    const c_val = Convert.toC(c_int, home_int);
    try testing.expectEqual(@as(c_int, 42), c_val);

    const back = Convert.fromC(i64, c_val);
    try testing.expectEqual(home_int, back);
}

test "alignment utilities" {
    const testing = std.testing;

    try testing.expect(Alignment.isAligned(16, 8));
    try testing.expect(!Alignment.isAligned(15, 8));
    try testing.expectEqual(@as(usize, 16), Alignment.alignPtr(15, 8));
    try testing.expectEqual(@as(usize, 24), Alignment.alignSize(17, 8));
}

test "calling convention enum" {
    const testing = std.testing;

    const cc = CallingConvention.C;
    const zig_cc = cc.toZig();
    try testing.expectEqual(std.builtin.CallingConvention.c, zig_cc);
}
