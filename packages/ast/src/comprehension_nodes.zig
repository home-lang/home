const std = @import("std");
const ast = @import("ast.zig");
const Node = ast.Node;
const NodeType = ast.NodeType;
const SourceLocation = ast.SourceLocation;
const Expr = ast.Expr;

/// Array comprehension expression
/// Syntax: [expr for item in iterable if condition]
pub const ArrayComprehension = struct {
    node: Node,
    element_expr: *Expr,  // Expression to evaluate for each element
    variable: []const u8,  // Loop variable name
    iterable: *Expr,      // Expression to iterate over
    condition: ?*Expr,    // Optional filter condition
    is_async: bool,       // true for async comprehensions

    pub fn init(
        element_expr: *Expr,
        variable: []const u8,
        iterable: *Expr,
        condition: ?*Expr,
        is_async: bool,
        loc: SourceLocation,
    ) ArrayComprehension {
        return .{
            .node = .{ .type = .ArrayComprehension, .loc = loc },
            .element_expr = element_expr,
            .variable = variable,
            .iterable = iterable,
            .condition = condition,
            .is_async = is_async,
        };
    }

    pub fn deinit(self: *ArrayComprehension, allocator: std.mem.Allocator) void {
        allocator.destroy(self.element_expr);
        allocator.free(self.variable);
        allocator.destroy(self.iterable);
        if (self.condition) |cond| {
            allocator.destroy(cond);
        }
    }
};

/// Dictionary/Map comprehension expression
/// Syntax: {key_expr: value_expr for item in iterable if condition}
pub const DictComprehension = struct {
    node: Node,
    key_expr: *Expr,
    value_expr: *Expr,
    variable: []const u8,
    iterable: *Expr,
    condition: ?*Expr,

    pub fn init(
        key_expr: *Expr,
        value_expr: *Expr,
        variable: []const u8,
        iterable: *Expr,
        condition: ?*Expr,
        loc: SourceLocation,
    ) DictComprehension {
        return .{
            .node = .{ .type = .DictComprehension, .loc = loc },
            .key_expr = key_expr,
            .value_expr = value_expr,
            .variable = variable,
            .iterable = iterable,
            .condition = condition,
        };
    }

    pub fn deinit(self: *DictComprehension, allocator: std.mem.Allocator) void {
        allocator.destroy(self.key_expr);
        allocator.destroy(self.value_expr);
        allocator.free(self.variable);
        allocator.destroy(self.iterable);
        if (self.condition) |cond| {
            allocator.destroy(cond);
        }
    }
};

/// Set comprehension expression
/// Syntax: {expr for item in iterable if condition}
pub const SetComprehension = struct {
    node: Node,
    element_expr: *Expr,
    variable: []const u8,
    iterable: *Expr,
    condition: ?*Expr,

    pub fn init(
        element_expr: *Expr,
        variable: []const u8,
        iterable: *Expr,
        condition: ?*Expr,
        loc: SourceLocation,
    ) SetComprehension {
        return .{
            .node = .{ .type = .SetComprehension, .loc = loc },
            .element_expr = element_expr,
            .variable = variable,
            .iterable = iterable,
            .condition = condition,
        };
    }

    pub fn deinit(self: *SetComprehension, allocator: std.mem.Allocator) void {
        allocator.destroy(self.element_expr);
        allocator.free(self.variable);
        allocator.destroy(self.iterable);
        if (self.condition) |cond| {
            allocator.destroy(cond);
        }
    }
};

/// Nested comprehension (multiple for clauses)
/// Syntax: [expr for x in iter1 for y in iter2 if condition]
pub const NestedComprehension = struct {
    node: Node,
    element_expr: *Expr,
    clauses: []const ComprehensionClause,
    condition: ?*Expr,

    pub fn init(
        element_expr: *Expr,
        clauses: []const ComprehensionClause,
        condition: ?*Expr,
        loc: SourceLocation,
    ) NestedComprehension {
        return .{
            .node = .{ .type = .NestedComprehension, .loc = loc },
            .element_expr = element_expr,
            .clauses = clauses,
            .condition = condition,
        };
    }

    pub fn deinit(self: *NestedComprehension, allocator: std.mem.Allocator) void {
        allocator.destroy(self.element_expr);
        for (self.clauses) |*clause| {
            clause.deinit(allocator);
        }
        allocator.free(self.clauses);
        if (self.condition) |cond| {
            allocator.destroy(cond);
        }
    }
};

/// Single comprehension clause (for x in iterable)
pub const ComprehensionClause = struct {
    variable: []const u8,
    iterable: *Expr,
    is_async: bool,

    pub fn init(variable: []const u8, iterable: *Expr, is_async: bool) ComprehensionClause {
        return .{
            .variable = variable,
            .iterable = iterable,
            .is_async = is_async,
        };
    }

    pub fn deinit(self: *ComprehensionClause, allocator: std.mem.Allocator) void {
        allocator.free(self.variable);
        allocator.destroy(self.iterable);
    }
};

/// Generator expression (lazy comprehension)
/// Syntax: (expr for item in iterable if condition)
pub const GeneratorExpr = struct {
    node: Node,
    element_expr: *Expr,
    variable: []const u8,
    iterable: *Expr,
    condition: ?*Expr,

    pub fn init(
        element_expr: *Expr,
        variable: []const u8,
        iterable: *Expr,
        condition: ?*Expr,
        loc: SourceLocation,
    ) GeneratorExpr {
        return .{
            .node = .{ .type = .GeneratorExpr, .loc = loc },
            .element_expr = element_expr,
            .variable = variable,
            .iterable = iterable,
            .condition = condition,
        };
    }

    pub fn deinit(self: *GeneratorExpr, allocator: std.mem.Allocator) void {
        allocator.destroy(self.element_expr);
        allocator.free(self.variable);
        allocator.destroy(self.iterable);
        if (self.condition) |cond| {
            allocator.destroy(cond);
        }
    }
};

/// Comprehension desugaring
/// Transforms comprehensions into equivalent for loops
pub const ComprehensionDesugarer = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ComprehensionDesugarer {
        return .{ .allocator = allocator };
    }

    /// Desugar array comprehension to for loop
    /// [x * 2 for x in numbers if x > 0]
    /// becomes:
    /// {
    ///     let result = []
    ///     for x in numbers {
    ///         if x > 0 {
    ///             result.push(x * 2)
    ///         }
    ///     }
    ///     result
    /// }
    pub fn desugarArrayComprehension(
        self: *ComprehensionDesugarer,
        comp: *ArrayComprehension,
    ) !*ast.BlockStmt {
        _ = self;
        _ = comp;
        // TODO: Implement desugaring logic
        return error.NotImplemented;
    }

    /// Desugar dict comprehension to for loop
    pub fn desugarDictComprehension(
        self: *ComprehensionDesugarer,
        comp: *DictComprehension,
    ) !*ast.BlockStmt {
        _ = self;
        _ = comp;
        // TODO: Implement desugaring logic
        return error.NotImplemented;
    }
};

/// Comprehension type inference
pub const ComprehensionTypeInference = struct {
    /// Infer the result type of an array comprehension
    pub fn inferArrayType(
        element_type: []const u8,
    ) []const u8 {
        // Returns Vec<element_type>
        return element_type;
    }

    /// Infer the result type of a dict comprehension
    pub fn inferDictType(
        key_type: []const u8,
        value_type: []const u8,
    ) struct { key: []const u8, value: []const u8 } {
        return .{ .key = key_type, .value = value_type };
    }
};

/// Comprehension patterns
pub const ComprehensionPattern = enum {
    /// [x for x in items]
    Simple,
    
    /// [x * 2 for x in items]
    Map,
    
    /// [x for x in items if x > 0]
    Filter,
    
    /// [x * 2 for x in items if x > 0]
    MapFilter,
    
    /// [x for row in matrix for x in row]
    Nested,
    
    /// {x: x * 2 for x in items}
    Dict,
    
    /// {x for x in items}
    Set,
    
    /// (x for x in items)
    Generator,

    pub fn toString(self: ComprehensionPattern) []const u8 {
        return switch (self) {
            .Simple => "simple",
            .Map => "map",
            .Filter => "filter",
            .MapFilter => "map_filter",
            .Nested => "nested",
            .Dict => "dict",
            .Set => "set",
            .Generator => "generator",
        };
    }
};
