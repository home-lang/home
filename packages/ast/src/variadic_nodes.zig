const std = @import("std");
const ast = @import("ast.zig");
const Node = ast.Node;
const SourceLocation = ast.SourceLocation;

/// Variadic parameter in function declaration
/// Represents parameters like `args: ...T` or `...args: T[]`
pub const VariadicParam = struct {
    name: []const u8,
    element_type: []const u8,
    is_c_style: bool,  // true for C-style varargs (...)
    loc: SourceLocation,

    pub fn deinit(self: *VariadicParam, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.element_type);
    }
};

/// Spread expression for variadic arguments
/// Example: func(...args) or func(1, 2, ...rest)
pub const SpreadArg = struct {
    expr: *ast.Expr,
    loc: SourceLocation,

    pub fn deinit(self: *SpreadArg, allocator: std.mem.Allocator) void {
        allocator.destroy(self.expr);
    }
};

/// Variadic function call information
pub const VariadicCall = struct {
    regular_args: []const *ast.Expr,
    spread_args: []const SpreadArg,
    
    pub fn deinit(self: *VariadicCall, allocator: std.mem.Allocator) void {
        for (self.regular_args) |arg| {
            allocator.destroy(arg);
        }
        allocator.free(self.regular_args);
        
        for (self.spread_args) |*arg| {
            arg.deinit(allocator);
        }
        allocator.free(self.spread_args);
    }
};

/// Variadic function metadata
pub const VariadicInfo = struct {
    min_args: usize,  // Minimum number of arguments
    has_variadic: bool,
    variadic_param_name: ?[]const u8,
    variadic_type: ?[]const u8,
    
    pub fn init(min_args: usize) VariadicInfo {
        return .{
            .min_args = min_args,
            .has_variadic = false,
            .variadic_param_name = null,
            .variadic_type = null,
        };
    }
    
    pub fn withVariadic(
        min_args: usize,
        param_name: []const u8,
        param_type: []const u8,
    ) VariadicInfo {
        return .{
            .min_args = min_args,
            .has_variadic = true,
            .variadic_param_name = param_name,
            .variadic_type = param_type,
        };
    }
};

/// Built-in variadic functions support
pub const BuiltinVariadic = struct {
    /// printf-style formatting
    pub const printf = struct {
        pub const name = "printf";
        pub const min_args = 1;  // At least format string
        pub const variadic_type = "any";
    };
    
    /// println with multiple arguments
    pub const println = struct {
        pub const name = "println";
        pub const min_args = 0;
        pub const variadic_type = "any";
    };
    
    /// Array/slice creation
    pub const vec = struct {
        pub const name = "vec";
        pub const min_args = 0;
        pub const variadic_type = "T";
    };
    
    /// Max of multiple values
    pub const max = struct {
        pub const name = "max";
        pub const min_args = 1;
        pub const variadic_type = "T";
    };
    
    /// Min of multiple values
    pub const min = struct {
        pub const name = "min";
        pub const min_args = 1;
        pub const variadic_type = "T";
    };
};
