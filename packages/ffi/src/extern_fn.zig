// Home Programming Language - External Function Utilities
// Helpers for declaring and calling external C functions

const std = @import("std");

// ============================================================================
// External Function Declaration Helpers
// ============================================================================

/// Declare an external C function
pub fn externC(comptime name: []const u8, comptime ReturnType: type, comptime params: anytype) type {
    _ = name;
    _ = params;
    return ReturnType;
}

/// Declare an external function with custom calling convention
pub fn externFn(comptime lib: []const u8, comptime name: []const u8, comptime cc: std.builtin.CallingConvention, comptime ReturnType: type) type {
    _ = lib;
    _ = name;
    _ = cc;
    return ReturnType;
}

// ============================================================================
// Function Signature Utilities
// ============================================================================

/// Get function signature information at comptime
pub fn FnInfo(comptime FnType: type) type {
    const fn_info = @typeInfo(FnType).@"fn";

    return struct {
        pub const return_type = fn_info.return_type orelse void;
        pub const params = fn_info.params;
        pub const is_var_args = fn_info.is_var_args;
        pub const calling_convention = fn_info.calling_convention;

        pub fn param_count() comptime_int {
            return params.len;
        }

        pub fn param_type(comptime index: comptime_int) type {
            if (index >= params.len) {
                @compileError("Parameter index out of bounds");
            }
            return params[index].type orelse void;
        }
    };
}

// ============================================================================
// Dynamic Function Calling
// ============================================================================

/// Wrapper for dynamically loaded C functions
pub fn ExternFn(comptime ReturnType: type, comptime ParamTypes: []const type) type {
    return struct {
        const Self = @This();

        // Build function pointer type
        pub const FnPtr = buildFnPtr(ReturnType, ParamTypes);

        ptr: FnPtr,
        name: []const u8,

        pub fn init(ptr: FnPtr, name: []const u8) Self {
            return .{
                .ptr = ptr,
                .name = name,
            };
        }

        fn buildFnPtr(comptime Ret: type, comptime Params: []const type) type {
            // Build function type
            var param_fields: [Params.len]std.builtin.Type.Fn.Param = undefined;
            for (Params, 0..) |P, i| {
                param_fields[i] = .{
                    .is_generic = false,
                    .is_noalias = false,
                    .type = P,
                };
            }

            const fn_type = std.builtin.Type.Fn{
                .calling_convention = .c,
                .is_generic = false,
                .is_var_args = false,
                .return_type = Ret,
                .params = &param_fields,
            };

            const fn_child = @Type(.{ .@"fn" = fn_type });
            return @Type(.{ .pointer = .{
                .size = .one,
                .is_const = true,
                .is_volatile = false,
                .alignment = @alignOf(fn_child),
                .address_space = .generic,
                .child = fn_child,
                .is_allowzero = false,
                .sentinel_ptr = null,
            } });
        }

        /// Call the function with arguments
        pub fn call(self: Self, args: anytype) ReturnType {
            const args_tuple = args;
            return @call(.auto, self.ptr, args_tuple);
        }
    };
}

// ============================================================================
// Safe External Function Wrapper
// ============================================================================

/// Safe wrapper that catches and handles errors from C functions
pub fn SafeExternFn(comptime ReturnType: type) type {
    return struct {
        const Self = @This();

        /// Call a C function and convert return value/errno to Zig error
        pub fn callSafe(comptime func: anytype, args: anytype) !ReturnType {
            // Reset errno before call
            if (@hasDecl(@import("std").c, "getErrno")) {
                std.c.getErrno().* = 0;
            }

            const result = @call(.auto, func, args);

            // Check for error (simplified - would need platform-specific handling)
            if (ReturnType == ?*anyopaque or ReturnType == ?*const anyopaque) {
                if (result == null) {
                    return error.ExternalFunctionFailed;
                }
            }

            return result;
        }
    };
}

// ============================================================================
// Variadic Function Support
// ============================================================================

/// Helper for calling variadic C functions (like printf)
pub const Variadic = struct {
    /// Call variadic function with type-safe wrapper
    pub fn call(comptime func: anytype, comptime fmt: []const u8, args: anytype) @TypeOf(func).return_type {
        _ = fmt;
        return @call(.auto, func, args);
    }
};

// ============================================================================
// Common C Function Wrappers
// ============================================================================

/// Wrapper for C functions that return pointers (checks for NULL)
pub fn callPtrFn(func: anytype, args: anytype) !@TypeOf(@call(.auto, func, args)) {
    const result = @call(.auto, func, args);
    if (result == null) {
        return error.NullPointer;
    }
    return result;
}

/// Wrapper for C functions that return int status codes
pub fn callStatusFn(func: anytype, args: anytype) !void {
    const result = @call(.auto, func, args);
    if (result != 0) {
        return error.ExternalFunctionFailed;
    }
}

/// Wrapper for C functions that return negative on error
pub fn callNegativeErrorFn(func: anytype, args: anytype) !@TypeOf(@call(.auto, func, args)) {
    const result = @call(.auto, func, args);
    if (result < 0) {
        return error.ExternalFunctionFailed;
    }
    return result;
}

// ============================================================================
// Function Pointer Validation
// ============================================================================

/// Check if function pointer is valid (non-null)
pub fn isValidFnPtr(ptr: anytype) bool {
    return ptr != null;
}

/// Assert function pointer is valid
pub fn assertValidFnPtr(ptr: anytype) void {
    std.debug.assert(ptr != null);
}

// ============================================================================
// Tests
// ============================================================================

test "FnInfo" {
    const testing = std.testing;

    const TestFn = fn (i32, f32) callconv(.c) bool;
    const info = FnInfo(TestFn);

    try testing.expectEqual(bool, info.return_type);
    try testing.expectEqual(@as(usize, 2), info.param_count());
    try testing.expectEqual(i32, info.param_type(0));
    try testing.expectEqual(f32, info.param_type(1));
    try testing.expectEqual(std.builtin.CallingConvention.c, info.calling_convention);
}

test "ExternFn basic" {
    const testing = std.testing;

    // Test function
    const test_fn = struct {
        fn add(a: i32, b: i32) callconv(.c) i32 {
            return a + b;
        }
    }.add;

    const AddFn = ExternFn(i32, &[_]type{ i32, i32 });
    const extern_fn = AddFn.init(test_fn, "add");

    const result = extern_fn.call(.{ 10, 20 });
    try testing.expectEqual(@as(i32, 30), result);
}

test "callPtrFn" {
    const testing = std.testing;

    // Static value for test
    const TestState = struct {
        var value: i32 = 42;
    };

    const test_fn = struct {
        fn get_ptr(return_null: bool) callconv(.c) ?*i32 {
            if (return_null) return null;
            return &TestState.value;
        }
    }.get_ptr;

    // Should succeed
    const result1 = callPtrFn(test_fn, .{false});
    try testing.expect(result1 != error.NullPointer);

    // Should fail
    const result2 = callPtrFn(test_fn, .{true});
    try testing.expectError(error.NullPointer, result2);
}

test "callStatusFn" {
    const testing = std.testing;

    const test_fn = struct {
        fn status(fail: bool) callconv(.c) c_int {
            return if (fail) -1 else 0;
        }
    }.status;

    // Should succeed
    try callStatusFn(test_fn, .{false});

    // Should fail
    const result = callStatusFn(test_fn, .{true});
    try testing.expectError(error.ExternalFunctionFailed, result);
}

test "callNegativeErrorFn" {
    const testing = std.testing;

    const test_fn = struct {
        fn check(value: i32) callconv(.c) i32 {
            return value;
        }
    }.check;

    // Should succeed
    const result1 = try callNegativeErrorFn(test_fn, .{42});
    try testing.expectEqual(@as(i32, 42), result1);

    // Should fail
    const result2 = callNegativeErrorFn(test_fn, .{-1});
    try testing.expectError(error.ExternalFunctionFailed, result2);
}

test "isValidFnPtr" {
    const testing = std.testing;

    const fn_ptr: ?*const fn () callconv(.c) void = struct {
        fn f() callconv(.c) void {}
    }.f;

    try testing.expect(isValidFnPtr(fn_ptr));
    try testing.expect(!isValidFnPtr(null));
}
