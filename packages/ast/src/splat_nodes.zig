const std = @import("std");
const ast = @import("ast.zig");
const Node = ast.Node;
const NodeType = ast.NodeType;
const SourceLocation = ast.SourceLocation;
const Expr = ast.Expr;

/// Splat/Spread expression
/// Used to unpack arrays, objects, and iterables
/// Syntax: ...expr
pub const SplatExpr = struct {
    node: Node,
    expr: *Expr,
    context: SplatContext,

    pub const SplatContext = enum {
        ArrayLiteral,      // [...arr1, ...arr2]
        FunctionCall,      // func(...args)
        StructLiteral,     // Struct { ...base, field: value }
        Destructuring,     // let [a, ...rest] = array
        PatternMatch,      // match value { [first, ...rest] => ... }
    };

    pub fn init(expr: *Expr, context: SplatContext, loc: SourceLocation) SplatExpr {
        return .{
            .node = .{ .type = .SplatExpr, .loc = loc },
            .expr = expr,
            .context = context,
        };
    }

    pub fn deinit(self: *SplatExpr, allocator: std.mem.Allocator) void {
        allocator.destroy(self.expr);
    }
};

/// Rest pattern in destructuring
/// Captures remaining elements
/// Syntax: ...rest
pub const RestPattern = struct {
    name: []const u8,
    loc: SourceLocation,

    pub fn init(name: []const u8, loc: SourceLocation) RestPattern {
        return .{
            .name = name,
            .loc = loc,
        };
    }

    pub fn deinit(self: *RestPattern, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

/// Array destructuring with rest
/// let [a, b, ...rest] = array
pub const ArrayDestructuring = struct {
    node: Node,
    elements: []const DestructureElement,
    rest: ?RestPattern,

    pub const DestructureElement = union(enum) {
        Identifier: []const u8,
        Nested: *ArrayDestructuring,
        Ignored,  // _ placeholder
    };

    pub fn init(
        elements: []const DestructureElement,
        rest: ?RestPattern,
        loc: SourceLocation,
    ) ArrayDestructuring {
        return .{
            .node = .{ .type = .ArrayDestructuring, .loc = loc },
            .elements = elements,
            .rest = rest,
        };
    }

    pub fn deinit(self: *ArrayDestructuring, allocator: std.mem.Allocator) void {
        for (self.elements) |elem| {
            switch (elem) {
                .Identifier => |name| allocator.free(name),
                .Nested => |nested| {
                    nested.deinit(allocator);
                    allocator.destroy(nested);
                },
                .Ignored => {},
            }
        }
        allocator.free(self.elements);
        if (self.rest) |*rest| {
            rest.deinit(allocator);
        }
    }
};

/// Object destructuring with rest
/// let { a, b, ...rest } = object
pub const ObjectDestructuring = struct {
    node: Node,
    fields: []const DestructureField,
    rest: ?RestPattern,

    pub const DestructureField = struct {
        key: []const u8,
        binding: ?[]const u8,  // Optional rename: { key: binding }
        default_value: ?*Expr,
    };

    pub fn init(
        fields: []const DestructureField,
        rest: ?RestPattern,
        loc: SourceLocation,
    ) ObjectDestructuring {
        return .{
            .node = .{ .type = .ObjectDestructuring, .loc = loc },
            .fields = fields,
            .rest = rest,
        };
    }

    pub fn deinit(self: *ObjectDestructuring, allocator: std.mem.Allocator) void {
        for (self.fields) |field| {
            allocator.free(field.key);
            if (field.binding) |binding| {
                allocator.free(binding);
            }
            if (field.default_value) |val| {
                allocator.destroy(val);
            }
        }
        allocator.free(self.fields);
        if (self.rest) |*rest| {
            rest.deinit(allocator);
        }
    }
};

/// Splat in function parameters
/// fn func(a, b, ...rest) { }
pub const SplatParameter = struct {
    name: []const u8,
    type_annotation: ?[]const u8,
    loc: SourceLocation,

    pub fn init(
        name: []const u8,
        type_annotation: ?[]const u8,
        loc: SourceLocation,
    ) SplatParameter {
        return .{
            .name = name,
            .type_annotation = type_annotation,
            .loc = loc,
        };
    }

    pub fn deinit(self: *SplatParameter, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.type_annotation) |type_name| {
            allocator.free(type_name);
        }
    }
};

/// Splat in array literal
/// [1, 2, ...arr, 3, 4]
pub const ArraySplat = struct {
    elements: []const ArrayElement,

    pub const ArrayElement = union(enum) {
        Value: *Expr,
        Splat: *SplatExpr,
    };

    pub fn init(elements: []const ArrayElement) ArraySplat {
        return .{ .elements = elements };
    }

    pub fn deinit(self: *ArraySplat, allocator: std.mem.Allocator) void {
        for (self.elements) |elem| {
            switch (elem) {
                .Value => |val| allocator.destroy(val),
                .Splat => |splat| allocator.destroy(splat),
            }
        }
        allocator.free(self.elements);
    }
};

/// Splat in function call
/// func(a, b, ...args, c)
pub const CallWithSplat = struct {
    callee: *Expr,
    arguments: []const CallArgument,

    pub const CallArgument = union(enum) {
        Positional: *Expr,
        Named: struct {
            name: []const u8,
            value: *Expr,
        },
        Splat: *SplatExpr,
    };

    pub fn init(callee: *Expr, arguments: []const CallArgument) CallWithSplat {
        return .{
            .callee = callee,
            .arguments = arguments,
        };
    }

    pub fn deinit(self: *CallWithSplat, allocator: std.mem.Allocator) void {
        allocator.destroy(self.callee);
        for (self.arguments) |arg| {
            switch (arg) {
                .Positional => |val| allocator.destroy(val),
                .Named => |named| {
                    allocator.free(named.name);
                    allocator.destroy(named.value);
                },
                .Splat => |splat| allocator.destroy(splat),
            }
        }
        allocator.free(self.arguments);
    }
};

/// Splat validator
pub const SplatValidator = struct {
    /// Validate splat in array literal
    pub fn validateArraySplat(elements: []const ArraySplat.ArrayElement) !void {
        // All splats must be iterable
        for (elements) |elem| {
            if (elem == .Splat) {
                // TODO: Check if expression is iterable
            }
        }
    }

    /// Validate splat in function call
    pub fn validateCallSplat(arguments: []const CallWithSplat.CallArgument) !void {
        var seen_splat = false;
        var seen_named = false;

        for (arguments) |arg| {
            switch (arg) {
                .Splat => {
                    if (seen_named) {
                        return error.SplatAfterNamed;
                    }
                    seen_splat = true;
                },
                .Named => {
                    seen_named = true;
                },
                .Positional => {
                    if (seen_named) {
                        return error.PositionalAfterNamed;
                    }
                },
            }
        }
    }

    /// Validate rest pattern in destructuring
    pub fn validateRestPattern(rest: ?RestPattern, position: usize, total: usize) !void {
        if (rest != null and position != total - 1) {
            return error.RestMustBeLast;
        }
    }
};

/// Splat desugaring
pub const SplatDesugarer = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SplatDesugarer {
        return .{ .allocator = allocator };
    }

    /// Desugar array splat
    /// [1, ...arr, 2] => [1].concat(arr).concat([2])
    pub fn desugarArraySplat(self: *SplatDesugarer, splat: *ArraySplat) !*Expr {
        _ = self;
        _ = splat;
        // TODO: Implement desugaring
        return error.NotImplemented;
    }

    /// Desugar function call splat
    /// func(...args) => func.apply(null, args)
    pub fn desugarCallSplat(self: *SplatDesugarer, call: *CallWithSplat) !*Expr {
        _ = self;
        _ = call;
        // TODO: Implement desugaring
        return error.NotImplemented;
    }

    /// Desugar array destructuring with rest
    /// let [a, ...rest] = arr => let a = arr[0]; let rest = arr[1..]
    pub fn desugarArrayDestructuring(
        self: *SplatDesugarer,
        destructure: *ArrayDestructuring,
    ) ![]const ast.Stmt {
        _ = self;
        _ = destructure;
        // TODO: Implement desugaring
        return error.NotImplemented;
    }
};

/// Splat patterns
pub const SplatPattern = enum {
    /// [...arr]
    ArraySpread,
    
    /// func(...args)
    CallSpread,
    
    /// { ...obj }
    ObjectSpread,
    
    /// let [a, ...rest] = arr
    ArrayRest,
    
    /// let { a, ...rest } = obj
    ObjectRest,
    
    /// fn func(...args)
    ParameterRest,

    pub fn toString(self: SplatPattern) []const u8 {
        return switch (self) {
            .ArraySpread => "array_spread",
            .CallSpread => "call_spread",
            .ObjectSpread => "object_spread",
            .ArrayRest => "array_rest",
            .ObjectRest => "object_rest",
            .ParameterRest => "parameter_rest",
        };
    }
};
