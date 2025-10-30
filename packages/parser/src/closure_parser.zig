const std = @import("std");
const Parser = @import("parser.zig").Parser;
const ast = @import("ast");
const Token = @import("lexer").Token;
const TokenType = @import("lexer").TokenType;

/// Parse a closure expression
/// Grammar: 
///   closure = 'move'? '|' params? '|' ('->' type)? (expr | block)
///   params = param (',' param)*
///   param = IDENTIFIER (':' type)?
///
/// Examples:
///   |x| x + 1
///   |a, b| a + b
///   |x: i32| -> i32 { x * 2 }
///   move |x| println(x)
///   || println("hello")
pub fn parseClosureExpr(self: *Parser) !*ast.Expr {
    const start_loc = self.peek().loc;
    
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
    
    // Optional return type
    var return_type: ?*ast.closure_nodes.TypeExpr = null;
    if (self.match(&.{.Arrow})) {
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
        false,  // is_async - TODO: support async closures
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
        if (self.match(&.{.Arrow})) {
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
        
        return ast.ClosureAnalysis{
            .trait = trait,
            .environment = environment,
            .is_pure = false,  // TODO: Analyze for purity
            .is_recursive = false,  // TODO: Detect recursion
        };
    }
    
    fn findReferences(
        self: *ClosureAnalyzer,
        refs: *std.StringHashMap(void),
        body: ast.ClosureBody,
    ) !void {
        _ = self;
        switch (body) {
            .Expression => |expr| {
                // TODO: Walk expression tree to find identifiers
                _ = expr;
            },
            .Block => |block| {
                // TODO: Walk block statements to find identifiers
                _ = block;
            },
        }
    }
    
    pub const VarInfo = struct {
        type_name: []const u8,
        is_mut: bool,
    };
};
