const std = @import("std");
const ast = @import("ast.zig");
const Node = ast.Node;
const SourceLocation = ast.SourceLocation;
const Expr = ast.Expr;

/// Enhanced parameter with default value and named argument support
pub const EnhancedParameter = struct {
    name: []const u8,
    type_name: []const u8,
    default_value: ?*Expr,
    is_named_only: bool,  // true if parameter can only be passed by name
    loc: SourceLocation,

    pub fn init(
        name: []const u8,
        type_name: []const u8,
        default_value: ?*Expr,
        is_named_only: bool,
        loc: SourceLocation,
    ) EnhancedParameter {
        return .{
            .name = name,
            .type_name = type_name,
            .default_value = default_value,
            .is_named_only = is_named_only,
            .loc = loc,
        };
    }

    pub fn deinit(self: *EnhancedParameter, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.type_name);
        if (self.default_value) |val| {
            allocator.destroy(val);
        }
    }

    pub fn hasDefault(self: *const EnhancedParameter) bool {
        return self.default_value != null;
    }
};

/// Named argument in function call
pub const NamedArgument = struct {
    name: []const u8,
    value: *Expr,
    loc: SourceLocation,

    pub fn init(name: []const u8, value: *Expr, loc: SourceLocation) NamedArgument {
        return .{
            .name = name,
            .value = value,
            .loc = loc,
        };
    }

    pub fn deinit(self: *NamedArgument, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.destroy(self.value);
    }
};

/// Function call with named arguments
pub const EnhancedCallExpr = struct {
    node: Node,
    callee: *Expr,
    positional_args: []const *Expr,
    named_args: []const NamedArgument,

    pub fn init(
        callee: *Expr,
        positional_args: []const *Expr,
        named_args: []const NamedArgument,
        loc: SourceLocation,
    ) EnhancedCallExpr {
        return .{
            .node = .{ .type = .CallExpr, .loc = loc },
            .callee = callee,
            .positional_args = positional_args,
            .named_args = named_args,
        };
    }

    pub fn deinit(self: *EnhancedCallExpr, allocator: std.mem.Allocator) void {
        allocator.destroy(self.callee);
        
        for (self.positional_args) |arg| {
            allocator.destroy(arg);
        }
        allocator.free(self.positional_args);
        
        for (self.named_args) |*arg| {
            arg.deinit(allocator);
        }
        allocator.free(self.named_args);
    }
};

/// Parameter configuration for function signature
pub const ParameterConfig = struct {
    required_params: []const []const u8,
    optional_params: []const []const u8,
    named_only_params: []const []const u8,
    has_variadic: bool,

    pub fn init(_: std.mem.Allocator) ParameterConfig {
        return .{
            .required_params = &[_][]const u8{},
            .optional_params = &[_][]const u8{},
            .named_only_params = &[_][]const u8{},
            .has_variadic = false,
        };
    }

    pub fn deinit(self: *ParameterConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.required_params);
        allocator.free(self.optional_params);
        allocator.free(self.named_only_params);
    }
};

/// Argument matching result
pub const ArgumentMatch = struct {
    param_name: []const u8,
    arg_value: *Expr,
    is_default: bool,  // true if using default value
    position: usize,

    pub fn init(
        param_name: []const u8,
        arg_value: *Expr,
        is_default: bool,
        position: usize,
    ) ArgumentMatch {
        return .{
            .param_name = param_name,
            .arg_value = arg_value,
            .is_default = is_default,
            .position = position,
        };
    }
};

/// Argument resolver - matches arguments to parameters
pub const ArgumentResolver = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ArgumentResolver {
        return .{ .allocator = allocator };
    }

    /// Resolve arguments to parameters, handling defaults and named args
    pub fn resolve(
        self: *ArgumentResolver,
        params: []const EnhancedParameter,
        positional_args: []const *Expr,
        named_args: []const NamedArgument,
    ) ![]ArgumentMatch {
        var matches = std.ArrayList(ArgumentMatch).init(self.allocator);
        defer matches.deinit();

        var used_params = std.StringHashMap(bool).init(self.allocator);
        defer used_params.deinit();

        // Match positional arguments first
        var pos_index: usize = 0;
        for (params) |param| {
            if (param.is_named_only) break;
            
            if (pos_index < positional_args.len) {
                try matches.append(ArgumentMatch.init(
                    param.name,
                    positional_args[pos_index],
                    false,
                    pos_index,
                ));
                try used_params.put(param.name, true);
                pos_index += 1;
            }
        }

        // Match named arguments
        for (named_args) |named_arg| {
            if (used_params.contains(named_arg.name)) {
                return error.DuplicateArgument;
            }

            // Find parameter with this name
            var found = false;
            for (params, 0..) |param, i| {
                if (std.mem.eql(u8, param.name, named_arg.name)) {
                    try matches.append(ArgumentMatch.init(
                        param.name,
                        named_arg.value,
                        false,
                        i,
                    ));
                    try used_params.put(param.name, true);
                    found = true;
                    break;
                }
            }

            if (!found) {
                return error.UnknownParameter;
            }
        }

        // Fill in defaults for missing parameters
        for (params, 0..) |param, i| {
            if (!used_params.contains(param.name)) {
                if (param.default_value) |default| {
                    try matches.append(ArgumentMatch.init(
                        param.name,
                        default,
                        true,
                        i,
                    ));
                } else {
                    return error.MissingRequiredParameter;
                }
            }
        }

        return matches.toOwnedSlice(self.allocator);
    }
};

/// Parameter validation
pub const ParameterValidator = struct {
    pub fn validate(params: []const EnhancedParameter) !void {
        var seen_default = false;
        var seen_named_only = false;

        for (params) |param| {
            // Once we see a named-only param, all following must be named-only
            if (seen_named_only and !param.is_named_only) {
                return error.PositionalAfterNamedOnly;
            }

            // Once we see a default param, all following positional params must have defaults
            if (!param.is_named_only) {
                if (seen_default and param.default_value == null) {
                    return error.RequiredAfterOptional;
                }
                if (param.default_value != null) {
                    seen_default = true;
                }
            }

            if (param.is_named_only) {
                seen_named_only = true;
            }
        }
    }
};

/// Built-in functions with default parameters
pub const BuiltinDefaults = struct {
    /// range function with default start and step
    pub const range = struct {
        pub const name = "range";
        pub const params = [_]EnhancedParameter{
            .{ .name = "start", .type_name = "i32", .default_value = null, .is_named_only = false },
            .{ .name = "end", .type_name = "i32", .default_value = null, .is_named_only = false },
            .{ .name = "step", .type_name = "i32", .default_value = null, .is_named_only = false }, // default: 1
        };
    };

    /// split with default separator
    pub const split = struct {
        pub const name = "split";
        // default separator: " "
    };

    /// round with default decimal places
    pub const round = struct {
        pub const name = "round";
        // default places: 0
    };
};
