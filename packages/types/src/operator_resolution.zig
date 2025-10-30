const std = @import("std");
const ast = @import("ast");
const traits_mod = @import("traits");
const TraitSystem = traits_mod.TraitSystem;
const OperatorTraitMap = traits_mod.OperatorTraits.OperatorTraitMap;

/// Operator resolution for type checking
/// Resolves operator expressions to trait method calls
pub const OperatorResolver = struct {
    allocator: std.mem.Allocator,
    trait_system: *TraitSystem,

    pub fn init(allocator: std.mem.Allocator, trait_system: *TraitSystem) OperatorResolver {
        return .{
            .allocator = allocator,
            .trait_system = trait_system,
        };
    }

    /// Resolve a binary operator expression
    /// Returns the trait method to call and the output type
    pub fn resolveBinaryOp(
        self: *OperatorResolver,
        op: ast.BinaryOp,
        lhs_type: []const u8,
        rhs_type: []const u8,
    ) !?OperatorResolution {
        const op_str = self.binaryOpToString(op);
        const trait_name = OperatorTraitMap.getTraitForBinaryOp(op_str) orelse return null;
        const method_name = OperatorTraitMap.getMethodForBinaryOp(op_str) orelse return null;

        // Check if lhs_type implements the operator trait for rhs_type
        const impl_key = try std.fmt.allocPrint(
            self.allocator,
            "{s}<{s}>",
            .{ trait_name, rhs_type },
        );
        defer self.allocator.free(impl_key);

        if (self.trait_system.implementsTrait(lhs_type, impl_key)) {
            // Get the implementation to find the Output type
            if (self.trait_system.getImplementation(lhs_type, impl_key)) |impl| {
                const output_type = impl.associated_types.get("Output") orelse lhs_type;

                return OperatorResolution{
                    .trait_name = try self.allocator.dupe(u8, trait_name),
                    .method_name = try self.allocator.dupe(u8, method_name),
                    .output_type = try self.allocator.dupe(u8, output_type),
                    .is_assignment = self.isAssignmentOp(op),
                };
            }
        }

        return null;
    }

    /// Resolve a unary operator expression
    pub fn resolveUnaryOp(
        self: *OperatorResolver,
        op: ast.UnaryOp,
        operand_type: []const u8,
    ) !?OperatorResolution {
        const op_str = self.unaryOpToString(op);
        const trait_name = OperatorTraitMap.getTraitForUnaryOp(op_str) orelse return null;
        const method_name = OperatorTraitMap.getMethodForUnaryOp(op_str) orelse return null;

        if (self.trait_system.implementsTrait(operand_type, trait_name)) {
            if (self.trait_system.getImplementation(operand_type, trait_name)) |impl| {
                const output_type = impl.associated_types.get("Output") orelse operand_type;

                return OperatorResolution{
                    .trait_name = try self.allocator.dupe(u8, trait_name),
                    .method_name = try self.allocator.dupe(u8, method_name),
                    .output_type = try self.allocator.dupe(u8, output_type),
                    .is_assignment = false,
                };
            }
        }

        return null;
    }

    /// Resolve an index expression (array[index])
    pub fn resolveIndexOp(
        self: *OperatorResolver,
        array_type: []const u8,
        index_type: []const u8,
        is_mutable: bool,
    ) !?OperatorResolution {
        const trait_name = if (is_mutable) "IndexMut" else "Index";
        const method_name = if (is_mutable) "index_mut" else "index";

        const impl_key = try std.fmt.allocPrint(
            self.allocator,
            "{s}<{s}>",
            .{ trait_name, index_type },
        );
        defer self.allocator.free(impl_key);

        if (self.trait_system.implementsTrait(array_type, impl_key)) {
            if (self.trait_system.getImplementation(array_type, impl_key)) |impl| {
                const output_type = impl.associated_types.get("Output") orelse array_type;

                return OperatorResolution{
                    .trait_name = try self.allocator.dupe(u8, trait_name),
                    .method_name = try self.allocator.dupe(u8, method_name),
                    .output_type = try self.allocator.dupe(u8, output_type),
                    .is_assignment = false,
                };
            }
        }

        return null;
    }

    fn binaryOpToString(self: *OperatorResolver, op: ast.BinaryOp) []const u8 {
        _ = self;
        return switch (op) {
            .Add => "+",
            .Sub => "-",
            .Mul => "*",
            .Div => "/",
            .Mod => "%",
            .BitAnd => "&",
            .BitOr => "|",
            .BitXor => "^",
            .LeftShift => "<<",
            .RightShift => ">>",
            else => "",
        };
    }

    fn unaryOpToString(self: *OperatorResolver, op: ast.UnaryOp) []const u8 {
        _ = self;
        return switch (op) {
            .Neg => "-",
            .Not => "!",
            else => "",
        };
    }

    fn isAssignmentOp(self: *OperatorResolver, op: ast.BinaryOp) bool {
        _ = self;
        _ = op;
        // Check if this is a compound assignment operator
        // This would need to be extended based on AST definition
        return false;
    }
};

/// Result of operator resolution
pub const OperatorResolution = struct {
    trait_name: []const u8,
    method_name: []const u8,
    output_type: []const u8,
    is_assignment: bool,

    pub fn deinit(self: *OperatorResolution, allocator: std.mem.Allocator) void {
        allocator.free(self.trait_name);
        allocator.free(self.method_name);
        allocator.free(self.output_type);
    }
};

/// Desugar operator expressions into trait method calls
/// This transforms `a + b` into `a.add(b)` at the AST level
pub const OperatorDesugarer = struct {
    allocator: std.mem.Allocator,
    resolver: *OperatorResolver,

    pub fn init(allocator: std.mem.Allocator, resolver: *OperatorResolver) OperatorDesugarer {
        return .{
            .allocator = allocator,
            .resolver = resolver,
        };
    }

    /// Desugar a binary expression into a method call
    /// a + b => a.add(b)
    pub fn desugarBinaryExpr(
        self: *OperatorDesugarer,
        binary_expr: *ast.BinaryExpr,
        lhs_type: []const u8,
        rhs_type: []const u8,
    ) !?*ast.CallExpr {
        const resolution = try self.resolver.resolveBinaryOp(
            binary_expr.op,
            lhs_type,
            rhs_type,
        ) orelse return null;
        defer {
            var res = resolution;
            res.deinit(self.allocator);
        }

        // Create method call: lhs.method_name(rhs)
        const member_expr = try self.allocator.create(ast.MemberExpr);
        member_expr.* = .{
            .node = .{ .type = .MemberExpr, .loc = binary_expr.node.loc },
            .object = binary_expr.left,
            .member = resolution.method_name,
        };

        const member_as_expr = try self.allocator.create(ast.Expr);
        member_as_expr.* = .{ .MemberExpr = member_expr.* };

        var args = try self.allocator.alloc(*ast.Expr, 1);
        args[0] = binary_expr.right;

        const call_expr = try self.allocator.create(ast.CallExpr);
        call_expr.* = .{
            .node = .{ .type = .CallExpr, .loc = binary_expr.node.loc },
            .callee = member_as_expr,
            .args = args,
        };

        return call_expr;
    }

    /// Desugar a unary expression into a method call
    /// -a => a.neg()
    pub fn desugarUnaryExpr(
        self: *OperatorDesugarer,
        unary_expr: *ast.UnaryExpr,
        operand_type: []const u8,
    ) !?*ast.CallExpr {
        const resolution = try self.resolver.resolveUnaryOp(
            unary_expr.op,
            operand_type,
        ) orelse return null;
        defer {
            var res = resolution;
            res.deinit(self.allocator);
        }

        // Create method call: operand.method_name()
        const member_expr = try self.allocator.create(ast.MemberExpr);
        member_expr.* = .{
            .node = .{ .type = .MemberExpr, .loc = unary_expr.node.loc },
            .object = unary_expr.operand,
            .member = resolution.method_name,
        };

        const member_as_expr = try self.allocator.create(ast.Expr);
        member_as_expr.* = .{ .MemberExpr = member_expr.* };

        const args = try self.allocator.alloc(*ast.Expr, 0);

        const call_expr = try self.allocator.create(ast.CallExpr);
        call_expr.* = .{
            .node = .{ .type = .CallExpr, .loc = unary_expr.node.loc },
            .callee = member_as_expr,
            .args = args,
        };

        return call_expr;
    }

    /// Desugar an index expression into a method call
    /// arr[i] => arr.index(i) or arr.index_mut(i)
    pub fn desugarIndexExpr(
        self: *OperatorDesugarer,
        index_expr: *ast.IndexExpr,
        array_type: []const u8,
        index_type: []const u8,
        is_mutable: bool,
    ) !?*ast.CallExpr {
        const resolution = try self.resolver.resolveIndexOp(
            array_type,
            index_type,
            is_mutable,
        ) orelse return null;
        defer {
            var res = resolution;
            res.deinit(self.allocator);
        }

        // Create method call: array.index(index) or array.index_mut(index)
        const member_expr = try self.allocator.create(ast.MemberExpr);
        member_expr.* = .{
            .node = .{ .type = .MemberExpr, .loc = index_expr.node.loc },
            .object = index_expr.array,
            .member = resolution.method_name,
        };

        const member_as_expr = try self.allocator.create(ast.Expr);
        member_as_expr.* = .{ .MemberExpr = member_expr.* };

        var args = try self.allocator.alloc(*ast.Expr, 1);
        args[0] = index_expr.index;

        const call_expr = try self.allocator.create(ast.CallExpr);
        call_expr.* = .{
            .node = .{ .type = .CallExpr, .loc = index_expr.node.loc },
            .callee = member_as_expr,
            .args = args,
        };

        return call_expr;
    }
};
