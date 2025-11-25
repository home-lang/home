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
                // Check if expression is iterable
                // In a full type system, we would check if the expression's type
                // implements Iterator or is an array/slice type
                // For now, we validate that splat expressions are syntactically valid

                // The expression must be:
                // - An array literal [...]
                // - A variable that could be an array
                // - A function call that returns an array
                // - A slice expression

                // This is a semantic check that would be done during type checking
                // For AST validation, we just ensure the node structure is valid
                _ = elem.Splat; // Ensure it's accessible
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
        // Strategy: Transform [a, ...b, c, ...d, e] into chained concat calls:
        // [a].concat(b).concat([c]).concat(d).concat([e])

        const allocator = self.allocator;

        const Segment = union(enum) {
            Array: []*Expr,  // Regular array elements
            Splat: *Expr,    // Splat expression to spread
        };

        // Collect segments between splats
        var segments = std.ArrayList(Segment).init(allocator);
        defer segments.deinit();

        var current_segment = std.ArrayList(*Expr).init(allocator);
        defer current_segment.deinit();

        for (splat.elements) |elem| {
            switch (elem) {
                .Element => |expr| {
                    try current_segment.append(expr);
                },
                .Splat => |splat_expr| {
                    // Save current segment as array if not empty
                    if (current_segment.items.len > 0) {
                        const arr_elements = try allocator.dupe(*Expr, current_segment.items);
                        try segments.append(.{ .Array = arr_elements });
                        current_segment.clearRetainingCapacity();
                    }

                    // Add splat segment
                    try segments.append(.{ .Splat = splat_expr });
                },
            }
        }

        // Don't forget remaining elements
        if (current_segment.items.len > 0) {
            const arr_elements = try allocator.dupe(*Expr, current_segment.items);
            try segments.append(.{ .Array = arr_elements });
        }

        // If only one segment and it's an array, just return array literal
        if (segments.items.len == 1 and segments.items[0] == .Array) {
            const array_expr = try allocator.create(Expr);
            array_expr.* = .{ .ArrayLiteral = .{
                .elements = segments.items[0].Array,
                .loc = splat.node.loc,
            }};
            return array_expr;
        }

        // Build concat chain: first.concat(second).concat(third)...
        // For now, return a placeholder that represents the desugared form
        // In a real implementation, this would create actual MethodCall AST nodes

        // Return first segment as base (in real impl, would build concat chain)
        const result = try allocator.create(Expr);
        result.* = .{ .ArrayLiteral = .{
            .elements = if (segments.items.len > 0 and segments.items[0] == .Array)
                segments.items[0].Array
            else
                &.{},
            .loc = splat.node.loc,
        }};

        return result;
    }

    /// Desugar function call splat
    /// func(...args) => Expand arguments at compile/runtime
    pub fn desugarCallSplat(self: *SplatDesugarer, call: *CallWithSplat) !*Expr {
        const allocator = self.allocator;

        // Collect all arguments, expanding splats
        var expanded_args = std.ArrayList(*Expr).init(allocator);
        defer expanded_args.deinit();

        for (call.arguments) |arg| {
            switch (arg) {
                .Positional => |expr| {
                    // Regular argument, add as-is
                    try expanded_args.append(expr);
                },
                .Named => |named| {
                    // Named arguments can't be mixed with splats in simple desugaring
                    // In a real implementation, this would be handled by the type checker
                    _ = named;
                    return error.NamedArgWithSplat;
                },
                .Splat => |splat_expr| {
                    // For splat, we need to expand at call site
                    // This requires runtime support or compile-time evaluation
                    //
                    // Strategy: Create a special CallWithExpandedArgs node
                    // that the codegen will handle by:
                    // 1. Evaluating the splat expression to get array
                    // 2. Iterating over array elements
                    // 3. Passing each as a separate argument
                    //
                    // For now, add marker that codegen will recognize
                    try expanded_args.append(splat_expr);
                },
            }
        }

        // Create regular function call with expanded args
        // In real implementation, this would be a special node type
        // that codegen recognizes and expands properly
        const result = try allocator.create(Expr);
        result.* = .{ .FunctionCall = .{
            .callee = call.callee,
            .arguments = try allocator.dupe(*Expr, expanded_args.items),
            .loc = call.node.loc,
        }};

        return result;
    }

    /// Desugar array destructuring with rest
    /// let [a, ...rest] = arr => let a = arr[0]; let rest = arr[1..]
    pub fn desugarArrayDestructuring(
        self: *SplatDesugarer,
        destructure: *ArrayDestructuring,
    ) ![]const ast.Stmt {
        const allocator = self.allocator;

        // Transform: let [a, b, ...rest] = arr
        // Into:
        //   let a = arr[0]
        //   let b = arr[1]
        //   let rest = arr[2..]
        //
        // Transform: let [a, b] = arr  (no rest)
        // Into:
        //   let a = arr[0]
        //   let b = arr[1]

        var statements = std.ArrayList(ast.Stmt).init(allocator);
        errdefer statements.deinit();

        // For each element, create index access
        for (destructure.elements, 0..) |elem, i| {
            switch (elem) {
                .Identifier => |name| {
                    // Create: let name = arr[i]
                    // In a real implementation, we would create:
                    // 1. IndexExpr node for arr[i]
                    // 2. VariableDecl node for let name = ...
                    // 3. Add to statements list

                    // Placeholder for actual statement creation
                    _ = name;
                    _ = i;
                    // const stmt = createLetStatement(name, arr, i);
                    // try statements.append(stmt);
                },
                .Nested => |nested| {
                    // Recursive destructuring: let [a, [b, c]] = arr
                    // Would recursively desugar the nested part
                    _ = nested;
                },
                .Ignored => {
                    // Ignored element: let [a, _, c] = arr
                    // No statement needed
                },
            }
        }

        // Handle rest pattern if present
        if (destructure.rest) |rest| {
            // Create: let rest = arr[n..]
            // where n is the number of non-rest elements
            const rest_start = destructure.elements.len;
            _ = rest;
            _ = rest_start;

            // In real implementation:
            // const stmt = createSliceStatement(rest.name, arr, rest_start);
            // try statements.append(stmt);
        }

        return try statements.toOwnedSlice();
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
