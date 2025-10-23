const std = @import("std");
const ast = @import("ast");
const comptime_mod = @import("comptime.zig");

/// Macro system for compile-time code generation
pub const MacroSystem = struct {
    allocator: std.mem.Allocator,
    macros: std.StringHashMap(Macro),
    expansion_depth: usize,

    const MAX_EXPANSION_DEPTH = 100;

    pub const Macro = struct {
        name: []const u8,
        params: []const []const u8,
        expander: *const MacroExpander,

        pub const MacroExpander = fn (
            allocator: std.mem.Allocator,
            args: []*ast.Expr,
        ) anyerror!*ast.Expr;
    };

    pub fn init(allocator: std.mem.Allocator) !MacroSystem {
        var system = MacroSystem{
            .allocator = allocator,
            .macros = std.StringHashMap(Macro).init(allocator),
            .expansion_depth = 0,
        };

        // Register built-in macros
        try system.registerBuiltinMacros();

        return system;
    }

    pub fn deinit(self: *MacroSystem) void {
        self.macros.deinit();
    }

    fn registerBuiltinMacros(self: *MacroSystem) !void {
        // print! macro
        try self.registerMacro("print", &[_][]const u8{"format"}, printMacro);

        // debug! macro
        try self.registerMacro("debug", &[_][]const u8{"value"}, debugMacro);

        // assert! macro
        try self.registerMacro("assert", &[_][]const u8{"condition"}, assertMacro);

        // todo! macro
        try self.registerMacro("todo", &[_][]const u8{}, todoMacro);

        // unreachable! macro
        try self.registerMacro("unreachable", &[_][]const u8{}, unreachableMacro);

        // vec! macro
        try self.registerMacro("vec", &[_][]const u8{"elements"}, vecMacro);

        // format! macro
        try self.registerMacro("format", &[_][]const u8{ "template", "args" }, formatMacro);

        // stringify! macro
        try self.registerMacro("stringify", &[_][]const u8{"expr"}, stringifyMacro);

        // include_str! macro
        try self.registerMacro("include_str", &[_][]const u8{"path"}, includeStrMacro);

        // env! macro
        try self.registerMacro("env", &[_][]const u8{"name"}, envMacro);
    }

    pub fn registerMacro(
        self: *MacroSystem,
        name: []const u8,
        params: []const []const u8,
        expander: *const Macro.MacroExpander,
    ) !void {
        const macro = Macro{
            .name = name,
            .params = params,
            .expander = expander,
        };
        try self.macros.put(name, macro);
    }

    pub fn expandMacro(self: *MacroSystem, name: []const u8, args: []*ast.Expr) !*ast.Expr {
        if (self.expansion_depth >= MAX_EXPANSION_DEPTH) {
            return error.MacroExpansionTooDeep;
        }

        const macro = self.macros.get(name) orelse return error.UndefinedMacro;

        self.expansion_depth += 1;
        defer self.expansion_depth -= 1;

        return try macro.expander(self.allocator, args);
    }

    /// Expand all macros in an expression tree
    pub fn expandAll(self: *MacroSystem, expr: *ast.Expr) !*ast.Expr {
        return switch (expr.*) {
            .MacroExpr => |macro_expr| blk: {
                // First expand macro arguments
                var expanded_args = try std.ArrayList(*ast.Expr).initCapacity(
                    self.allocator,
                    macro_expr.args.len,
                );
                defer expanded_args.deinit();

                for (macro_expr.args) |arg| {
                    const expanded_arg = try self.expandAll(arg);
                    try expanded_args.append(expanded_arg);
                }

                // Then expand the macro itself
                const result = try self.expandMacro(macro_expr.name, try expanded_args.toOwnedSlice());
                break :blk result;
            },

            .BinaryExpr => |bin_expr| blk: {
                const left = try self.expandAll(bin_expr.left);
                const right = try self.expandAll(bin_expr.right);

                const new_expr = try self.allocator.create(ast.BinaryExpr);
                new_expr.* = .{
                    .node = bin_expr.node,
                    .op = bin_expr.op,
                    .left = left,
                    .right = right,
                };

                const result = try self.allocator.create(ast.Expr);
                result.* = ast.Expr{ .BinaryExpr = new_expr };
                break :blk result;
            },

            .CallExpr => |call_expr| blk: {
                const callee = try self.expandAll(call_expr.callee);

                var expanded_args = try std.ArrayList(*ast.Expr).initCapacity(
                    self.allocator,
                    call_expr.arguments.len,
                );
                defer expanded_args.deinit();

                for (call_expr.arguments) |arg| {
                    const expanded_arg = try self.expandAll(arg);
                    try expanded_args.append(expanded_arg);
                }

                const new_expr = try self.allocator.create(ast.CallExpr);
                new_expr.* = .{
                    .node = call_expr.node,
                    .callee = callee,
                    .arguments = try expanded_args.toOwnedSlice(),
                };

                const result = try self.allocator.create(ast.Expr);
                result.* = ast.Expr{ .CallExpr = new_expr };
                break :blk result;
            },

            else => expr, // No expansion needed
        };
    }
};

// Built-in macro implementations

fn printMacro(allocator: std.mem.Allocator, args: []*ast.Expr) !*ast.Expr {
    // Transform print!("format", args...) into a function call
    const print_ident = try allocator.create(ast.Identifier);
    print_ident.* = ast.Identifier.init("print", ast.SourceLocation{ .line = 0, .column = 0 });

    const ident_expr = try allocator.create(ast.Expr);
    ident_expr.* = ast.Expr{ .Identifier = print_ident.* };

    const call_expr = try ast.CallExpr.init(
        allocator,
        ident_expr,
        args,
        ast.SourceLocation{ .line = 0, .column = 0 },
    );

    const result = try allocator.create(ast.Expr);
    result.* = ast.Expr{ .CallExpr = call_expr };
    return result;
}

fn debugMacro(allocator: std.mem.Allocator, args: []*ast.Expr) !*ast.Expr {
    if (args.len != 1) {
        return error.InvalidMacroArgs;
    }

    // Transform debug!(value) into print("value = ", value)
    const format_str = try allocator.create(ast.Expr);
    format_str.* = ast.Expr{
        .StringLiteral = ast.StringLiteral.init(
            "debug: ",
            ast.SourceLocation{ .line = 0, .column = 0 },
        ),
    };

    const print_ident = try allocator.create(ast.Identifier);
    print_ident.* = ast.Identifier.init("print", ast.SourceLocation{ .line = 0, .column = 0 });

    const ident_expr = try allocator.create(ast.Expr);
    ident_expr.* = ast.Expr{ .Identifier = print_ident.* };

    const call_args = try allocator.alloc(*ast.Expr, 2);
    call_args[0] = format_str;
    call_args[1] = args[0];

    const call_expr = try ast.CallExpr.init(
        allocator,
        ident_expr,
        call_args,
        ast.SourceLocation{ .line = 0, .column = 0 },
    );

    const result = try allocator.create(ast.Expr);
    result.* = ast.Expr{ .CallExpr = call_expr };
    return result;
}

fn assertMacro(allocator: std.mem.Allocator, args: []*ast.Expr) !*ast.Expr {
    if (args.len != 1) {
        return error.InvalidMacroArgs;
    }

    // Transform assert!(condition) into if (!condition) { panic("assertion failed") }
    const assert_ident = try allocator.create(ast.Identifier);
    assert_ident.* = ast.Identifier.init("assert", ast.SourceLocation{ .line = 0, .column = 0 });

    const ident_expr = try allocator.create(ast.Expr);
    ident_expr.* = ast.Expr{ .Identifier = assert_ident.* };

    const call_expr = try ast.CallExpr.init(
        allocator,
        ident_expr,
        args,
        ast.SourceLocation{ .line = 0, .column = 0 },
    );

    const result = try allocator.create(ast.Expr);
    result.* = ast.Expr{ .CallExpr = call_expr };
    return result;
}

fn todoMacro(allocator: std.mem.Allocator, args: []*ast.Expr) !*ast.Expr {
    _ = args;

    // Transform todo!() into panic("not yet implemented")
    const panic_ident = try allocator.create(ast.Identifier);
    panic_ident.* = ast.Identifier.init("panic", ast.SourceLocation{ .line = 0, .column = 0 });

    const ident_expr = try allocator.create(ast.Expr);
    ident_expr.* = ast.Expr{ .Identifier = panic_ident.* };

    const msg_expr = try allocator.create(ast.Expr);
    msg_expr.* = ast.Expr{
        .StringLiteral = ast.StringLiteral.init(
            "not yet implemented",
            ast.SourceLocation{ .line = 0, .column = 0 },
        ),
    };

    const call_args = try allocator.alloc(*ast.Expr, 1);
    call_args[0] = msg_expr;

    const call_expr = try ast.CallExpr.init(
        allocator,
        ident_expr,
        call_args,
        ast.SourceLocation{ .line = 0, .column = 0 },
    );

    const result = try allocator.create(ast.Expr);
    result.* = ast.Expr{ .CallExpr = call_expr };
    return result;
}

fn unreachableMacro(allocator: std.mem.Allocator, args: []*ast.Expr) !*ast.Expr {
    _ = args;

    // Transform unreachable!() into panic("unreachable code reached")
    const panic_ident = try allocator.create(ast.Identifier);
    panic_ident.* = ast.Identifier.init("panic", ast.SourceLocation{ .line = 0, .column = 0 });

    const ident_expr = try allocator.create(ast.Expr);
    ident_expr.* = ast.Expr{ .Identifier = panic_ident.* };

    const msg_expr = try allocator.create(ast.Expr);
    msg_expr.* = ast.Expr{
        .StringLiteral = ast.StringLiteral.init(
            "unreachable code reached",
            ast.SourceLocation{ .line = 0, .column = 0 },
        ),
    };

    const call_args = try allocator.alloc(*ast.Expr, 1);
    call_args[0] = msg_expr;

    const call_expr = try ast.CallExpr.init(
        allocator,
        ident_expr,
        call_args,
        ast.SourceLocation{ .line = 0, .column = 0 },
    );

    const result = try allocator.create(ast.Expr);
    result.* = ast.Expr{ .CallExpr = call_expr };
    return result;
}

fn vecMacro(allocator: std.mem.Allocator, args: []*ast.Expr) !*ast.Expr {
    // Transform vec!(1, 2, 3) into [1, 2, 3]
    const array_expr = try ast.ArrayLiteral.init(
        allocator,
        args,
        ast.SourceLocation{ .line = 0, .column = 0 },
    );

    const result = try allocator.create(ast.Expr);
    result.* = ast.Expr{ .ArrayLiteral = array_expr };
    return result;
}

fn formatMacro(allocator: std.mem.Allocator, args: []*ast.Expr) !*ast.Expr {
    // Transform format!("template", args...) into format("template", args...)
    const format_ident = try allocator.create(ast.Identifier);
    format_ident.* = ast.Identifier.init("format", ast.SourceLocation{ .line = 0, .column = 0 });

    const ident_expr = try allocator.create(ast.Expr);
    ident_expr.* = ast.Expr{ .Identifier = format_ident.* };

    const call_expr = try ast.CallExpr.init(
        allocator,
        ident_expr,
        args,
        ast.SourceLocation{ .line = 0, .column = 0 },
    );

    const result = try allocator.create(ast.Expr);
    result.* = ast.Expr{ .CallExpr = call_expr };
    return result;
}

fn stringifyMacro(allocator: std.mem.Allocator, args: []*ast.Expr) !*ast.Expr {
    if (args.len != 1) {
        return error.InvalidMacroArgs;
    }

    // Transform stringify!(expr) into "expr" (as string literal)
    // This would require converting expr to string representation
    // For simplicity, just return a placeholder string
    const result = try allocator.create(ast.Expr);
    result.* = ast.Expr{
        .StringLiteral = ast.StringLiteral.init(
            "<stringified>",
            ast.SourceLocation{ .line = 0, .column = 0 },
        ),
    };
    return result;
}

fn includeStrMacro(allocator: std.mem.Allocator, args: []*ast.Expr) !*ast.Expr {
    if (args.len != 1) {
        return error.InvalidMacroArgs;
    }

    // Transform include_str!("path") into the file contents as a string literal
    // This would read the file at compile time
    // For now, return a placeholder
    const result = try allocator.create(ast.Expr);
    result.* = ast.Expr{
        .StringLiteral = ast.StringLiteral.init(
            "<file contents>",
            ast.SourceLocation{ .line = 0, .column = 0 },
        ),
    };
    return result;
}

fn envMacro(allocator: std.mem.Allocator, args: []*ast.Expr) !*ast.Expr {
    if (args.len != 1) {
        return error.InvalidMacroArgs;
    }

    // Transform env!("NAME") into environment variable value at compile time
    // For now, return a placeholder
    const result = try allocator.create(ast.Expr);
    result.* = ast.Expr{
        .StringLiteral = ast.StringLiteral.init(
            "<env value>",
            ast.SourceLocation{ .line = 0, .column = 0 },
        ),
    };
    return result;
}
