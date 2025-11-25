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
        const allocator = self.allocator;

        // Desugaring strategy:
        // [expr for item in iterable if condition]
        // =>
        // {
        //     let result = []
        //     for item in iterable {
        //         if condition {
        //             result.push(expr)
        //         }
        //     }
        //     result
        // }

        var block_stmts = std.ArrayList(ast.Stmt).init(allocator);
        errdefer block_stmts.deinit();

        // Step 1: Create result array variable
        // let result = []
        const result_var_name = try allocator.dupe(u8, "__comprehension_result");

        // Create empty array literal expression
        const empty_array = try allocator.create(ast.Expr);
        empty_array.* = .{ .ArrayLiteral = .{
            .elements = &.{},
            .loc = comp.node.loc,
        }};

        // Create variable declaration: let result = []
        const var_decl = ast.Stmt{ .VariableDecl = .{
            .name = result_var_name,
            .mutable = true,
            .type_annotation = null,
            .value = empty_array,
            .loc = comp.node.loc,
        }};
        try block_stmts.append(var_decl);

        // Step 2: Build the for loop body
        // The body will be: result.push(expr) wrapped in condition if present
        var for_body_stmts = std.ArrayList(ast.Stmt).init(allocator);
        defer for_body_stmts.deinit();

        // Create push call: result.push(expr)
        // This would be a method call node in real implementation
        // For now, create a placeholder statement

        // Step 3: Wrap in condition if filter exists
        if (comp.filter) |_| {
            // Wrap push in if statement
            // if condition { result.push(expr) }
            // In real implementation, would create IfStmt node
        }

        // Step 4: Create for loop
        // for item in iterable { ... body ... }
        // In real implementation, would create ForStmt node

        // Step 5: Return result variable
        const result_expr = try allocator.create(ast.Expr);
        result_expr.* = .{ .Identifier = .{
            .name = result_var_name,
            .loc = comp.node.loc,
        }};

        const return_stmt = ast.Stmt{ .ExprStmt = .{
            .expr = result_expr,
            .loc = comp.node.loc,
        }};
        try block_stmts.append(return_stmt);

        // Create block statement
        const block = try allocator.create(ast.BlockStmt);
        block.* = .{
            .statements = try block_stmts.toOwnedSlice(),
            .loc = comp.node.loc,
        };

        return block;
    }

    /// Desugar dict comprehension to for loop
    /// {key: value for item in iterable if condition}
    /// becomes:
    /// {
    ///     let result = {}
    ///     for item in iterable {
    ///         if condition {
    ///             result[key] = value
    ///         }
    ///     }
    ///     result
    /// }
    pub fn desugarDictComprehension(
        self: *ComprehensionDesugarer,
        comp: *DictComprehension,
    ) !*ast.BlockStmt {
        const allocator = self.allocator;

        var block_stmts = std.ArrayList(ast.Stmt).init(allocator);
        errdefer block_stmts.deinit();

        // Step 1: Create result dict variable
        // let result = {}
        const result_var_name = try allocator.dupe(u8, "__dict_comprehension_result");

        // Create empty dict literal expression
        const empty_dict = try allocator.create(ast.Expr);
        empty_dict.* = .{ .DictLiteral = .{
            .entries = &.{},
            .loc = comp.node.loc,
        }};

        // Create variable declaration: let result = {}
        const var_decl = ast.Stmt{ .VariableDecl = .{
            .name = result_var_name,
            .mutable = true,
            .type_annotation = null,
            .value = empty_dict,
            .loc = comp.node.loc,
        }};
        try block_stmts.append(var_decl);

        // Step 2: Build for loop body
        // result[key_expr] = value_expr
        // In real implementation, would create:
        // 1. IndexAssignment or method call node
        // 2. Wrap in if statement if filter exists
        // 3. Create ForStmt with this body

        // For now, create structure that represents the desugared form
        // The actual loop and assignment nodes would be created here

        // Step 3: Return result variable
        const result_expr = try allocator.create(ast.Expr);
        result_expr.* = .{ .Identifier = .{
            .name = result_var_name,
            .loc = comp.node.loc,
        }};

        const return_stmt = ast.Stmt{ .ExprStmt = .{
            .expr = result_expr,
            .loc = comp.node.loc,
        }};
        try block_stmts.append(return_stmt);

        // Create block statement
        const block = try allocator.create(ast.BlockStmt);
        block.* = .{
            .statements = try block_stmts.toOwnedSlice(),
            .loc = comp.node.loc,
        };

        return block;
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
