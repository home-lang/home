const std = @import("std");
const Parser = @import("parser.zig").Parser;
const ast = @import("ast");
const Token = @import("lexer").Token;
const TokenType = @import("lexer").TokenType;

/// Parse a closure expression
/// Grammar:
///   closure = 'async'? 'move'? '|' params? '|' ('->' type)? (expr | block)
///   params = param (',' param)*
///   param = IDENTIFIER (':' type)?
///
/// Examples:
///   |x| x + 1
///   |a, b| a + b
///   |x: i32| -> i32 { x * 2 }
///   move |x| println(x)
///   async |x| await someAsyncFn(x)
///   async move |x| await processData(x)
///   || println("hello")
pub fn parseClosureExpr(self: *Parser) !*ast.Expr {
    const start_loc = self.peek().loc;

    // Check for 'async' keyword
    const is_async = if (self.match(&.{.Identifier}) and std.mem.eql(u8, self.previous().lexeme, "async"))
        true
    else blk: {
        // If we consumed an identifier but it wasn't 'async', put it back
        if (self.current > 0) {
            const prev = self.previous();
            if (prev.type == .Identifier and !std.mem.eql(u8, prev.lexeme, "async") and !std.mem.eql(u8, prev.lexeme, "move")) {
                self.current -= 1;
            }
        }
        break :blk false;
    };

    // Check for 'move' keyword
    const is_move = self.match(&.{.Identifier}) and std.mem.eql(u8, self.previous().lexeme, "move");

    // Expect opening pipe
    _ = try self.expect(.Pipe, "Expected '|' to start closure parameters");
    
    // Parse parameters
    var params = std.ArrayList(ast.ClosureParam).init(self.allocator);
    defer params.deinit();
    
    while (!self.check(.Pipe) and !self.isAtEnd()) {
        const is_mut = self.match(&.{.Mut});
        
        const param_token = try self.expect(.Identifier, "Expected parameter name");
        const param_name = try self.allocator.dupe(u8, param_token.lexeme);
        
        // Optional type annotation
        var type_annotation: ?*ast.closure_nodes.TypeExpr = null;
        if (self.match(&.{.Colon})) {
            type_annotation = try self.parseClosureTypeExpr();
        }
        
        try params.append(.{
            .name = param_name,
            .type_annotation = type_annotation,
            .is_mut = is_mut,
        });
        
        if (!self.match(&.{.Comma})) break;
    }
    
    _ = try self.expect(.Pipe, "Expected '|' after closure parameters");
    
    // Optional return type (TypeScript-style with colon)
    var return_type: ?*ast.closure_nodes.TypeExpr = null;
    if (self.match(&.{.Colon})) {
        return_type = try self.parseClosureTypeExpr();
    }
    
    // Parse body - either expression or block
    const body: ast.ClosureBody = if (self.check(.LeftBrace)) blk: {
        const block = try self.block();
        break :blk .{ .Block = block.BlockStmt };
    } else blk: {
        const expr = try self.expression();
        break :blk .{ .Expression = expr };
    };
    
    // Capture analysis will be done during type checking
    const captures = try self.allocator.alloc(ast.Capture, 0);
    
    const closure = try self.allocator.create(ast.ClosureExpr);
    closure.* = ast.ClosureExpr.init(
        try params.toOwnedSlice(self.allocator),
        return_type,
        body,
        captures,
        is_async,
        is_move,
        ast.SourceLocation.fromToken(start_loc),
    );
    
    const expr = try self.allocator.create(ast.Expr);
    expr.* = .{ .ClosureExpr = closure.* };
    
    return expr;
}

/// Parse type expression for closures
fn parseClosureTypeExpr(self: *Parser) !*ast.closure_nodes.TypeExpr {
    const type_expr = try self.allocator.create(ast.closure_nodes.TypeExpr);
    
    // Handle reference types
    if (self.match(&.{.Ampersand})) {
        const is_mut = self.match(&.{.Mut});
        const inner = try self.parseClosureTypeExpr();
        
        type_expr.* = .{ .Reference = .{
            .is_mut = is_mut,
            .inner = inner,
        }};
        return type_expr;
    }
    
    // Handle function/closure types
    if (self.match(&.{.Fn})) {
        _ = try self.expect(.LeftParen, "Expected '(' after 'fn'");
        
        var param_types = std.ArrayList(*ast.closure_nodes.TypeExpr).init(self.allocator);
        defer param_types.deinit();
        
        while (!self.check(.RightParen) and !self.isAtEnd()) {
            const param_type = try self.parseClosureTypeExpr();
            try param_types.append(param_type);
            
            if (!self.match(&.{.Comma})) break;
        }
        
        _ = try self.expect(.RightParen, "Expected ')' after function parameters");

        var return_type: ?*ast.closure_nodes.TypeExpr = null;
        if (self.match(&.{.Colon})) {
            return_type = try self.parseClosureTypeExpr();
        }
        
        type_expr.* = .{ .Function = .{
            .params = try param_types.toOwnedSlice(self.allocator),
            .return_type = return_type,
        }};
        return type_expr;
    }
    
    // Named type
    const name_token = try self.expect(.Identifier, "Expected type name");
    const type_name = try self.allocator.dupe(u8, name_token.lexeme);
    
    // Check for generic arguments
    if (self.match(&.{.Less})) {
        var args = std.ArrayList(*ast.closure_nodes.TypeExpr).init(self.allocator);
        defer args.deinit();
        
        while (!self.check(.Greater) and !self.isAtEnd()) {
            const arg = try self.parseClosureTypeExpr();
            try args.append(arg);
            
            if (!self.match(&.{.Comma})) break;
        }
        
        _ = try self.expect(.Greater, "Expected '>' after generic arguments");
        
        type_expr.* = .{ .Generic = .{
            .base = type_name,
            .args = try args.toOwnedSlice(self.allocator),
        }};
    } else {
        type_expr.* = .{ .Named = type_name };
    }
    
    return type_expr;
}

/// Analyze closure captures
/// This is called during semantic analysis to determine what variables are captured
pub const ClosureAnalyzer = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) ClosureAnalyzer {
        return .{ .allocator = allocator };
    }
    
    /// Analyze a closure to determine its captures and trait
    pub fn analyze(
        self: *ClosureAnalyzer,
        closure: *ast.ClosureExpr,
        scope_vars: std.StringHashMap(VarInfo),
    ) !ast.ClosureAnalysis {
        var environment = ast.ClosureEnvironment.init(self.allocator);
        errdefer environment.deinit();
        
        // Find all variable references in the closure body
        var referenced_vars = std.StringHashMap(void).init(self.allocator);
        defer referenced_vars.deinit();
        
        try self.findReferences(&referenced_vars, closure.body);
        
        // Determine capture mode for each referenced variable
        var trait = ast.ClosureTrait.Fn;
        var it = referenced_vars.iterator();
        
        while (it.next()) |entry| {
            const var_name = entry.key_ptr.*;
            
            // Skip parameters
            var is_param = false;
            for (closure.params) |param| {
                if (std.mem.eql(u8, param.name, var_name)) {
                    is_param = true;
                    break;
                }
            }
            if (is_param) continue;
            
            // Check if variable is from outer scope
            if (scope_vars.get(var_name)) |var_info| {
                const mode = if (closure.is_move)
                    ast.Capture.CaptureMode.ByMove
                else if (var_info.is_mut)
                    ast.Capture.CaptureMode.ByMutRef
                else
                    ast.Capture.CaptureMode.ByRef;
                
                try environment.addCapture(var_name, mode, var_info.type_name);
                
                // Determine closure trait based on captures
                if (mode == .ByMove) {
                    trait = .FnOnce;
                } else if (mode == .ByMutRef and trait != .FnOnce) {
                    trait = .FnMut;
                }
            }
        }
        
        // Analyze purity: closure is pure if:
        // 1. No mutable captures
        // 2. No mutations in the body (simplified: check for ByMutRef captures)
        // 3. Body doesn't contain impure operations (I/O, etc.)
        const is_pure = blk: {
            // If closure has mutable captures, it's not pure
            if (trait == .FnMut or trait == .FnOnce) break :blk false;

            // Check if body contains impure operations
            const has_impure_ops = try self.bodyHasImpureOperations(closure.body);
            break :blk !has_impure_ops;
        };

        // Detect recursion: check if closure calls itself
        // This requires the closure to have a name binding, which we don't have here
        // For now, closures are not directly recursive (would need Y-combinator style)
        const is_recursive = false;

        return ast.ClosureAnalysis{
            .trait = trait,
            .environment = environment,
            .is_pure = is_pure,
            .is_recursive = is_recursive,
        };
    }
    
    /// Check if closure body contains impure operations
    fn bodyHasImpureOperations(self: *ClosureAnalyzer, body: ast.ClosureBody) !bool {
        _ = self;

        // Simplified purity analysis:
        // - I/O operations: print, println, read, write
        // - Mutations: assignments (handled by checking FnMut trait)
        // - Random number generation
        // - Time/date operations
        //
        // For now, conservatively return false (assume pure unless we detect impurity)
        // A full implementation would walk the AST and check for:
        // - Calls to known impure functions (print, println, etc.)
        // - Assignment statements
        // - Method calls on mutable references

        switch (body) {
            .Expression => |_| {
                // Simple expressions are typically pure
                // (arithmetic, comparisons, pure function calls)
                return false;
            },
            .Block => |_| {
                // Blocks with statements might have side effects
                // For now, conservatively assume blocks might be impure
                // A full implementation would check each statement
                return false;
            },
        }
    }

    fn findReferences(
        self: *ClosureAnalyzer,
        refs: *std.StringHashMap(void),
        body: ast.ClosureBody,
    ) !void {
        switch (body) {
            .Expression => |expr| {
                try self.walkExpression(refs, expr);
            },
            .Block => |block| {
                try self.walkBlock(refs, block);
            },
        }
    }

    /// Walk expression tree to find variable references
    fn walkExpression(self: *ClosureAnalyzer, refs: *std.StringHashMap(void), expr: *ast.Expr) !void {
        switch (expr.*) {
            .Identifier => |id| {
                try refs.put(id.name, {});
            },
            .BinaryExpr => |bin| {
                try self.walkExpression(refs, bin.left);
                try self.walkExpression(refs, bin.right);
            },
            .UnaryExpr => |un| {
                try self.walkExpression(refs, un.operand);
            },
            .CallExpr => |call| {
                try self.walkExpression(refs, call.callee);
                for (call.arguments) |arg| {
                    try self.walkExpression(refs, arg);
                }
            },
            .MemberExpr => |member| {
                try self.walkExpression(refs, member.object);
            },
            .IndexExpr => |index| {
                try self.walkExpression(refs, index.array);
                try self.walkExpression(refs, index.index);
            },
            .IfExpr => |if_expr| {
                try self.walkExpression(refs, if_expr.condition);
                try self.walkExpression(refs, if_expr.then_expr);
                if (if_expr.else_expr) |else_expr| {
                    try self.walkExpression(refs, else_expr);
                }
            },
            .TernaryExpr => |tern| {
                try self.walkExpression(refs, tern.condition);
                try self.walkExpression(refs, tern.then_expr);
                try self.walkExpression(refs, tern.else_expr);
            },
            .MatchExpr => |match_expr| {
                try self.walkExpression(refs, match_expr.expr);
                // Note: match arms would need special handling for bindings
            },
            .ArrayLiteral => |arr| {
                for (arr.elements) |elem| {
                    try self.walkExpression(refs, elem);
                }
            },
            .TupleLiteral => |tup| {
                for (tup.elements) |elem| {
                    try self.walkExpression(refs, elem);
                }
            },
            // Literals don't reference variables
            .IntLiteral, .FloatLiteral, .BoolLiteral, .StringLiteral, .NullLiteral => {},
            // Other expressions
            else => {},
        }
    }

    /// Walk block statements to find variable references
    fn walkBlock(self: *ClosureAnalyzer, refs: *std.StringHashMap(void), block: ast.BlockStmt) !void {
        for (block.statements) |stmt| {
            try self.walkStatement(refs, &stmt);
        }
    }

    /// Walk a single statement
    fn walkStatement(self: *ClosureAnalyzer, refs: *std.StringHashMap(void), stmt: *const ast.Stmt) !void {
        switch (stmt.*) {
            .ExprStmt => |expr_stmt| {
                try self.walkExpression(refs, expr_stmt);
            },
            .ReturnStmt => |ret_stmt| {
                if (ret_stmt.expression) |expr| {
                    try self.walkExpression(refs, expr);
                }
            },
            .IfStmt => |if_stmt| {
                try self.walkExpression(refs, if_stmt.condition);
                try self.walkBlock(refs, if_stmt.then_block);
                if (if_stmt.else_block) |else_block| {
                    try self.walkBlock(refs, else_block);
                }
            },
            .WhileStmt => |while_stmt| {
                try self.walkExpression(refs, while_stmt.condition);
                try self.walkBlock(refs, while_stmt.body);
            },
            .ForStmt => |for_stmt| {
                try self.walkExpression(refs, for_stmt.iterable);
                try self.walkBlock(refs, for_stmt.body);
            },
            .LetDecl => |let_decl| {
                if (let_decl.initializer) |initializer| {
                    try self.walkExpression(refs, initializer);
                }
            },
            .AssignmentStmt => |assign| {
                try self.walkExpression(refs, assign.target);
                try self.walkExpression(refs, assign.value);
            },
            .MatchStmt => |match_stmt| {
                try self.walkExpression(refs, match_stmt.expr);
                for (match_stmt.arms) |arm| {
                    try self.walkBlock(refs, arm.body);
                }
            },
            else => {},
        }
    }
    
    pub const VarInfo = struct {
        type_name: []const u8,
        is_mut: bool,
    };
};
