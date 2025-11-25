const std = @import("std");
const ast = @import("ast");

/// Escape analysis for stack allocation optimization
///
/// Determines if allocations can be moved from heap to stack.
/// An allocation "escapes" if it:
/// - Is returned from a function
/// - Is stored in a global
/// - Outlives the function scope
/// - Is accessed after the function returns
pub const EscapeAnalyzer = struct {
    allocator: std.mem.Allocator,
    /// Map from variable name to escape status
    escape_info: std.StringHashMap(EscapeStatus),
    /// Current function being analyzed
    current_function: ?[]const u8,
    /// Variables that escape
    escaping_vars: std.StringHashSet,
    /// Statistics
    stack_eligible: usize,
    heap_required: usize,

    pub const EscapeStatus = enum {
        /// Does not escape, can be stack-allocated
        NoEscape,
        /// Escapes to return value
        EscapesReturn,
        /// Escapes to heap (stored in global, closure, etc.)
        EscapesHeap,
        /// Escapes to another function's parameters
        EscapesParameter,
        /// Unknown - conservative assumption
        Unknown,
    };

    pub fn init(allocator: std.mem.Allocator) EscapeAnalyzer {
        return .{
            .allocator = allocator,
            .escape_info = std.StringHashMap(EscapeStatus).init(allocator),
            .current_function = null,
            .escaping_vars = std.StringHashSet.init(allocator),
            .stack_eligible = 0,
            .heap_required = 0,
        };
    }

    pub fn deinit(self: *EscapeAnalyzer) void {
        self.escape_info.deinit();
        self.escaping_vars.deinit();
    }

    /// Analyze a program
    pub fn analyze(self: *EscapeAnalyzer, program: *ast.Program) !void {
        for (program.statements) |*stmt| {
            try self.analyzeStmt(stmt);
        }
    }

    fn analyzeStmt(self: *EscapeAnalyzer, stmt: *ast.Stmt) !void {
        switch (stmt.*) {
            .FunctionDecl => |*func| {
                self.current_function = func.name;
                defer self.current_function = null;

                // Analyze parameters - they come from outside, so they escape
                for (func.params) |param| {
                    try self.escape_info.put(param.name, .EscapesParameter);
                }

                // Analyze function body
                for (func.body.statements) |*body_stmt| {
                    try self.analyzeStmt(body_stmt);
                }
            },
            .LetDecl => |let_decl| {
                // Check if this is an allocation
                if (let_decl.initializer) |init_expr| {
                    const is_alloc = self.isAllocation(init_expr);

                    if (is_alloc) {
                        // Start with NoEscape, will be updated if it escapes
                        try self.escape_info.put(let_decl.name, .NoEscape);

                        // Analyze how the variable is used
                        try self.analyzeVariableUses(let_decl.name, stmt);
                    }
                }
            },
            .ReturnStmt => |ret_stmt| {
                // Any variable returned escapes
                if (ret_stmt.expression) |expr| {
                    try self.markEscapesInExpr(expr, .EscapesReturn);
                }
            },
            .ExprStmt => |expr| {
                try self.analyzeExpr(expr);
            },
            else => {},
        }
    }

    fn analyzeExpr(self: *EscapeAnalyzer, expr: *ast.Expr) !void {
        switch (expr.*) {
            .CallExpr => |call| {
                // Arguments passed to functions may escape
                for (call.arguments) |arg| {
                    try self.markEscapesInExpr(arg, .EscapesParameter);
                }
            },
            .BinaryExpr => |bin| {
                try self.analyzeExpr(bin.left);
                try self.analyzeExpr(bin.right);
            },
            else => {},
        }
    }

    fn isAllocation(self: *EscapeAnalyzer, expr: *ast.Expr) bool {
        _ = self;
        return switch (expr.*) {
            .CallExpr => |call| {
                // Check if calling a constructor or allocation function
                if (call.callee.* == .Identifier) {
                    const name = call.callee.Identifier.name;
                    return std.mem.eql(u8, name, "new") or
                        std.mem.eql(u8, name, "alloc") or
                        std.mem.eql(u8, name, "Box") or
                        std.mem.eql(u8, name, "Vec");
                }
                return false;
            },
            .StructLiteral => true,
            .ArrayLiteral => true,
            else => false,
        };
    }

    fn analyzeVariableUses(self: *EscapeAnalyzer, var_name: []const u8, scope: *ast.Stmt) !void {
        _ = self;
        _ = var_name;
        _ = scope;
        // Would perform full data flow analysis
        // Track all uses of the variable
        // Determine if it escapes based on usage patterns
    }

    fn markEscapesInExpr(self: *EscapeAnalyzer, expr: *ast.Expr, status: EscapeStatus) !void {
        switch (expr.*) {
            .Identifier => |id| {
                try self.escape_info.put(id.name, status);
                try self.escaping_vars.put(id.name, {});

                if (status == .EscapesReturn or status == .EscapesHeap or status == .EscapesParameter) {
                    self.heap_required += 1;
                } else {
                    self.stack_eligible += 1;
                }
            },
            .BinaryExpr => |bin| {
                try self.markEscapesInExpr(bin.left, status);
                try self.markEscapesInExpr(bin.right, status);
            },
            .CallExpr => |call| {
                try self.markEscapesInExpr(call.callee, status);
                for (call.arguments) |arg| {
                    try self.markEscapesInExpr(arg, status);
                }
            },
            else => {},
        }
    }

    pub fn getEscapeStatus(self: *EscapeAnalyzer, var_name: []const u8) EscapeStatus {
        return self.escape_info.get(var_name) orelse .Unknown;
    }

    pub fn canStackAllocate(self: *EscapeAnalyzer, var_name: []const u8) bool {
        return self.getEscapeStatus(var_name) == .NoEscape;
    }

    pub fn printStats(self: *EscapeAnalyzer) void {
        std.debug.print("\n=== Escape Analysis Statistics ===\n", .{});
        std.debug.print("Stack-eligible allocations: {d}\n", .{self.stack_eligible});
        std.debug.print("Heap-required allocations:  {d}\n", .{self.heap_required});

        if (self.stack_eligible + self.heap_required > 0) {
            const total = @as(f64, @floatFromInt(self.stack_eligible + self.heap_required));
            const pct = @as(f64, @floatFromInt(self.stack_eligible)) / total * 100.0;
            std.debug.print("Stack allocation rate:      {d:.1}%\n", .{pct});
        }

        std.debug.print("==================================\n\n", .{});
    }
};

/// Lifetime analysis for borrow checking optimization
pub const LifetimeAnalyzer = struct {
    allocator: std.mem.Allocator,
    /// Map from variable to its lifetime bounds
    lifetimes: std.StringHashMap(Lifetime),

    pub const Lifetime = struct {
        start: usize, // Statement index where lifetime begins
        end: usize, // Statement index where lifetime ends
        scope_depth: usize,
    };

    pub fn init(allocator: std.mem.Allocator) LifetimeAnalyzer {
        return .{
            .allocator = allocator,
            .lifetimes = std.StringHashMap(Lifetime).init(allocator),
        };
    }

    pub fn deinit(self: *LifetimeAnalyzer) void {
        self.lifetimes.deinit();
    }

    pub fn analyze(self: *LifetimeAnalyzer, program: *ast.Program) !void {
        for (program.statements, 0..) |*stmt, i| {
            try self.analyzeStmt(stmt, i, 0);
        }
    }

    fn analyzeStmt(self: *LifetimeAnalyzer, stmt: *ast.Stmt, index: usize, scope_depth: usize) !void {
        switch (stmt.*) {
            .LetDecl => |let_decl| {
                try self.lifetimes.put(let_decl.name, .{
                    .start = index,
                    .end = index, // Will be updated
                    .scope_depth = scope_depth,
                });
            },
            .FunctionDecl => |*func| {
                for (func.body.statements, 0..) |*body_stmt, i| {
                    try self.analyzeStmt(body_stmt, i, scope_depth + 1);
                }
            },
            else => {},
        }
    }

    pub fn getLifetime(self: *LifetimeAnalyzer, var_name: []const u8) ?Lifetime {
        return self.lifetimes.get(var_name);
    }

    pub fn lifetimesOverlap(self: *LifetimeAnalyzer, var1: []const u8, var2: []const u8) bool {
        const lt1 = self.getLifetime(var1) orelse return false;
        const lt2 = self.getLifetime(var2) orelse return false;

        return !(lt1.end < lt2.start or lt2.end < lt1.start);
    }
};

/// Register allocation using graph coloring
pub const RegisterAllocator = struct {
    allocator: std.mem.Allocator,
    /// Interference graph
    interference: std.AutoHashMap([]const u8, std.StringHashSet),
    /// Register assignment
    assignment: std.StringHashMap(usize),
    /// Number of available registers
    num_registers: usize,

    pub fn init(allocator: std.mem.Allocator, num_registers: usize) RegisterAllocator {
        return .{
            .allocator = allocator,
            .interference = std.AutoHashMap([]const u8, std.StringHashSet).init(allocator),
            .assignment = std.StringHashMap(usize).init(allocator),
            .num_registers = num_registers,
        };
    }

    pub fn deinit(self: *RegisterAllocator) void {
        var it = self.interference.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.interference.deinit();
        self.assignment.deinit();
    }

    pub fn addInterference(self: *RegisterAllocator, var1: []const u8, var2: []const u8) !void {
        const entry1 = try self.interference.getOrPut(var1);
        if (!entry1.found_existing) {
            entry1.value_ptr.* = std.StringHashSet.init(self.allocator);
        }
        try entry1.value_ptr.put(var2, {});

        const entry2 = try self.interference.getOrPut(var2);
        if (!entry2.found_existing) {
            entry2.value_ptr.* = std.StringHashSet.init(self.allocator);
        }
        try entry2.value_ptr.put(var1, {});
    }

    pub fn allocateRegisters(self: *RegisterAllocator) !void {
        // Simplified graph coloring
        // Real implementation would use Chaitin's algorithm

        var it = self.interference.iterator();
        while (it.next()) |entry| {
            const var_name = entry.key_ptr.*;
            const neighbors = entry.value_ptr.*;

            // Find available register (color)
            var color: usize = 0;
            while (color < self.num_registers) : (color += 1) {
                var available = true;

                var neighbor_it = neighbors.iterator();
                while (neighbor_it.next()) |neighbor| {
                    if (self.assignment.get(neighbor.key_ptr.*)) |neighbor_color| {
                        if (neighbor_color == color) {
                            available = false;
                            break;
                        }
                    }
                }

                if (available) {
                    try self.assignment.put(var_name, color);
                    break;
                }
            }

            // If no register available, spill to memory
            if (color == self.num_registers) {
                try self.assignment.put(var_name, std.math.maxInt(usize));
            }
        }
    }

    pub fn getRegister(self: *RegisterAllocator, var_name: []const u8) ?usize {
        return self.assignment.get(var_name);
    }

    pub fn isSpilled(self: *RegisterAllocator, var_name: []const u8) bool {
        if (self.assignment.get(var_name)) |reg| {
            return reg == std.math.maxInt(usize);
        }
        return false;
    }
};
