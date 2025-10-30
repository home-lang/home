const std = @import("std");
const Parser = @import("parser.zig").Parser;
const ast = @import("ast");
const Token = @import("lexer").Token;
const TokenType = @import("lexer").TokenType;

/// Parse a trait declaration
/// Grammar: trait IDENTIFIER typeParams? (':' traitList)? whereClause? '{' traitBody '}'
pub fn parseTraitDeclaration(self: *Parser) !ast.Stmt {
    const trait_token = self.previous();
    
    // Parse trait name
    const name_token = try self.expect(.Identifier, "Expected trait name");
    const name = try self.allocator.dupe(u8, name_token.lexeme);
    errdefer self.allocator.free(name);
    
    // Parse optional generic parameters
    var generic_params = std.ArrayList(ast.GenericParam).init(self.allocator);
    defer generic_params.deinit();
    
    if (self.match(&.{.Less})) {
        while (!self.check(.Greater) and !self.isAtEnd()) {
            const param_token = try self.expect(.Identifier, "Expected generic parameter name");
            const param_name = try self.allocator.dupe(u8, param_token.lexeme);
            
            // Parse optional trait bounds (T: Clone + Debug)
            var bounds = std.ArrayList([]const u8).init(self.allocator);
            defer bounds.deinit();
            
            if (self.match(&.{.Colon})) {
                while (true) {
                    const bound_token = try self.expect(.Identifier, "Expected trait bound");
                    const bound = try self.allocator.dupe(u8, bound_token.lexeme);
                    try bounds.append(bound);
                    
                    if (!self.match(&.{.Plus})) break;
                }
            }
            
            try generic_params.append(.{
                .name = param_name,
                .bounds = try bounds.toOwnedSlice(self.allocator),
                .default_type = null,
            });
            
            if (!self.match(&.{.Comma})) break;
        }
        
        _ = try self.expect(.Greater, "Expected '>' after generic parameters");
    }
    
    // Parse optional super traits (: Trait1 + Trait2)
    var super_traits = std.ArrayList([]const u8).init(self.allocator);
    defer super_traits.deinit();
    
    if (self.match(&.{.Colon})) {
        while (true) {
            const trait_token_super = try self.expect(.Identifier, "Expected super trait name");
            const super_trait = try self.allocator.dupe(u8, trait_token_super.lexeme);
            try super_traits.append(super_trait);
            
            if (!self.match(&.{.Plus})) break;
        }
    }
    
    // Parse optional where clause
    var where_clause: ?*ast.WhereClause = null;
    if (self.match(&.{.Where})) {
        where_clause = try self.parseWhereClause();
    }
    
    // Parse trait body
    _ = try self.expect(.LeftBrace, "Expected '{' after trait declaration");
    
    var methods = std.ArrayList(ast.TraitMethod).init(self.allocator);
    defer methods.deinit();
    
    var associated_types = std.ArrayList(ast.AssociatedType).init(self.allocator);
    defer associated_types.deinit();
    
    while (!self.check(.RightBrace) and !self.isAtEnd()) {
        // Associated type: type Name: Bounds = DefaultType;
        if (self.match(&.{.Type})) {
            const type_name_token = try self.expect(.Identifier, "Expected associated type name");
            const type_name = try self.allocator.dupe(u8, type_name_token.lexeme);
            
            var type_bounds = std.ArrayList([]const u8).init(self.allocator);
            defer type_bounds.deinit();
            
            if (self.match(&.{.Colon})) {
                while (true) {
                    const bound_token = try self.expect(.Identifier, "Expected trait bound");
                    const bound = try self.allocator.dupe(u8, bound_token.lexeme);
                    try type_bounds.append(bound);
                    
                    if (!self.match(&.{.Plus})) break;
                }
            }
            
            var default_type: ?*ast.TypeExpr = null;
            if (self.match(&.{.Equal})) {
                default_type = try self.parseTypeExpr();
            }
            
            _ = try self.expect(.Semicolon, "Expected ';' after associated type");
            
            try associated_types.append(.{
                .name = type_name,
                .bounds = try type_bounds.toOwnedSlice(self.allocator),
                .default_type = default_type,
            });
            continue;
        }
        
        // Method signature
        const is_async = self.match(&.{.Async});
        _ = try self.expect(.Fn, "Expected 'fn' for trait method");
        
        const method_name_token = try self.expect(.Identifier, "Expected method name");
        const method_name = try self.allocator.dupe(u8, method_name_token.lexeme);
        
        // Parse parameters
        _ = try self.expect(.LeftParen, "Expected '(' after method name");
        
        var params = std.ArrayList(ast.FnParam).init(self.allocator);
        defer params.deinit();
        
        while (!self.check(.RightParen) and !self.isAtEnd()) {
            // Check for self parameter
            const is_self = self.check(.SelfValue);
            var is_mut = false;
            var param_name: []const u8 = undefined;
            var type_expr: *ast.TypeExpr = undefined;
            
            if (is_self) {
                _ = self.advance();
                param_name = try self.allocator.dupe(u8, "self");
                
                // Create Self type
                type_expr = try self.allocator.create(ast.TypeExpr);
                type_expr.* = .SelfType;
            } else if (self.match(&.{.Ampersand})) {
                // Reference parameter
                is_mut = self.match(&.{.Mut});
                
                if (self.match(&.{.SelfValue})) {
                    param_name = try self.allocator.dupe(u8, "self");
                    
                    const inner = try self.allocator.create(ast.TypeExpr);
                    inner.* = .SelfType;
                    
                    type_expr = try self.allocator.create(ast.TypeExpr);
                    type_expr.* = .{ .Reference = .{ .is_mut = is_mut, .inner = inner } };
                } else {
                    const name_token = try self.expect(.Identifier, "Expected parameter name");
                    param_name = try self.allocator.dupe(u8, name_token.lexeme);
                    _ = try self.expect(.Colon, "Expected ':' after parameter name");
                    type_expr = try self.parseTypeExpr();
                }
            } else {
                const name_token = try self.expect(.Identifier, "Expected parameter name");
                param_name = try self.allocator.dupe(u8, name_token.lexeme);
                _ = try self.expect(.Colon, "Expected ':' after parameter name");
                type_expr = try self.parseTypeExpr();
            }
            
            try params.append(.{
                .name = param_name,
                .type_expr = type_expr,
                .is_mut = is_mut,
                .is_self = is_self,
            });
            
            if (!self.match(&.{.Comma})) break;
        }
        
        _ = try self.expect(.RightParen, "Expected ')' after parameters");
        
        // Parse return type
        var return_type: ?*ast.TypeExpr = null;
        if (self.match(&.{.Arrow})) {
            return_type = try self.parseTypeExpr();
        }
        
        // Check for default implementation
        var has_default = false;
        var default_body: ?*ast.BlockStmt = null;
        
        if (self.check(.LeftBrace)) {
            has_default = true;
            const block = try self.block();
            default_body = block.BlockStmt;
        } else {
            _ = try self.expect(.Semicolon, "Expected ';' after method signature");
        }
        
        try methods.append(.{
            .name = method_name,
            .params = try params.toOwnedSlice(self.allocator),
            .return_type = return_type,
            .is_async = is_async,
            .has_default_impl = has_default,
            .default_body = default_body,
        });
    }
    
    _ = try self.expect(.RightBrace, "Expected '}' after trait body");
    
    const trait_decl = try self.allocator.create(ast.TraitDecl);
    trait_decl.* = ast.TraitDecl.init(
        name,
        try generic_params.toOwnedSlice(self.allocator),
        try super_traits.toOwnedSlice(self.allocator),
        try methods.toOwnedSlice(self.allocator),
        try associated_types.toOwnedSlice(self.allocator),
        where_clause,
        ast.SourceLocation.fromToken(trait_token),
    );
    
    return ast.Stmt{ .TraitDecl = trait_decl };
}

/// Parse an impl declaration
/// Grammar: impl typeParams? TRAIT? for TYPE whereClause? '{' implBody '}'
pub fn parseImplDeclaration(self: *Parser) !ast.Stmt {
    const impl_token = self.previous();
    
    // Parse optional generic parameters
    var generic_params = std.ArrayList(ast.GenericParam).init(self.allocator);
    defer generic_params.deinit();
    
    if (self.match(&.{.Less})) {
        while (!self.check(.Greater) and !self.isAtEnd()) {
            const param_token = try self.expect(.Identifier, "Expected generic parameter name");
            const param_name = try self.allocator.dupe(u8, param_token.lexeme);
            
            var bounds = std.ArrayList([]const u8).init(self.allocator);
            defer bounds.deinit();
            
            if (self.match(&.{.Colon})) {
                while (true) {
                    const bound_token = try self.expect(.Identifier, "Expected trait bound");
                    const bound = try self.allocator.dupe(u8, bound_token.lexeme);
                    try bounds.append(bound);
                    
                    if (!self.match(&.{.Plus})) break;
                }
            }
            
            try generic_params.append(.{
                .name = param_name,
                .bounds = try bounds.toOwnedSlice(self.allocator),
                .default_type = null,
            });
            
            if (!self.match(&.{.Comma})) break;
        }
        
        _ = try self.expect(.Greater, "Expected '>' after generic parameters");
    }
    
    // Parse trait name (optional for inherent impl)
    var trait_name: ?[]const u8 = null;
    var for_type: *ast.TypeExpr = undefined;
    
    // Look ahead to determine if this is "impl Trait for Type" or "impl Type"
    if (self.check(.Identifier)) {
        const checkpoint = self.current;
        const first_ident = self.advance();
        
        if (self.check(.For)) {
            // This is "impl Trait for Type"
            trait_name = try self.allocator.dupe(u8, first_ident.lexeme);
            _ = self.advance(); // consume 'for'
            for_type = try self.parseTypeExpr();
        } else {
            // This is "impl Type" - restore and parse type
            self.current = checkpoint;
            for_type = try self.parseTypeExpr();
        }
    } else {
        for_type = try self.parseTypeExpr();
    }
    
    // Parse optional where clause
    var where_clause: ?*ast.WhereClause = null;
    if (self.match(&.{.Where})) {
        where_clause = try self.parseWhereClause();
    }
    
    // Parse impl body
    _ = try self.expect(.LeftBrace, "Expected '{' after impl declaration");
    
    var methods = std.ArrayList(*ast.FnDecl).init(self.allocator);
    defer methods.deinit();
    
    while (!self.check(.RightBrace) and !self.isAtEnd()) {
        // Parse method (must be a function)
        const is_async = self.match(&.{.Async});
        _ = try self.expect(.Fn, "Expected 'fn' in impl block");
        
        // Reuse function parsing logic
        self.current -= 1; // Back up to re-parse fn
        if (is_async) self.current -= 1;
        
        const method_stmt = try self.functionDeclaration(false);
        if (method_stmt == .FnDecl) {
            try methods.append(method_stmt.FnDecl);
        }
    }
    
    _ = try self.expect(.RightBrace, "Expected '}' after impl body");
    
    const impl_decl = try self.allocator.create(ast.ImplDecl);
    impl_decl.* = ast.ImplDecl.init(
        trait_name,
        for_type,
        try generic_params.toOwnedSlice(self.allocator),
        try methods.toOwnedSlice(self.allocator),
        where_clause,
        ast.SourceLocation.fromToken(impl_token),
        self.allocator,
    );
    
    return ast.Stmt{ .ImplDecl = impl_decl };
}

/// Parse a where clause
/// Grammar: where TYPE: TRAIT (+ TRAIT)* (, TYPE: TRAIT (+ TRAIT)*)*
fn parseWhereClause(self: *Parser) !*ast.WhereClause {
    var bounds = std.ArrayList(ast.WhereBound).init(self.allocator);
    defer bounds.deinit();
    
    while (true) {
        const type_param_token = try self.expect(.Identifier, "Expected type parameter in where clause");
        const type_param = try self.allocator.dupe(u8, type_param_token.lexeme);
        
        _ = try self.expect(.Colon, "Expected ':' after type parameter");
        
        var trait_bounds = std.ArrayList([]const u8).init(self.allocator);
        defer trait_bounds.deinit();
        
        while (true) {
            const trait_token = try self.expect(.Identifier, "Expected trait bound");
            const trait_bound = try self.allocator.dupe(u8, trait_token.lexeme);
            try trait_bounds.append(trait_bound);
            
            if (!self.match(&.{.Plus})) break;
        }
        
        try bounds.append(.{
            .type_param = type_param,
            .trait_bounds = try trait_bounds.toOwnedSlice(self.allocator),
        });
        
        if (!self.match(&.{.Comma})) break;
        if (self.check(.LeftBrace)) break; // End of where clause
    }
    
    const where_clause = try self.allocator.create(ast.WhereClause);
    where_clause.* = .{
        .bounds = try bounds.toOwnedSlice(self.allocator),
    };
    
    return where_clause;
}

/// Parse a type expression
fn parseTypeExpr(self: *Parser) !*ast.TypeExpr {
    const type_expr = try self.allocator.create(ast.TypeExpr);
    
    // Handle dyn Trait (trait object)
    if (self.match(&.{.Dyn})) {
        const trait_token = try self.expect(.Identifier, "Expected trait name after 'dyn'");
        const trait_name = try self.allocator.dupe(u8, trait_token.lexeme);
        
        var bounds = std.ArrayList([]const u8).init(self.allocator);
        defer bounds.deinit();
        
        if (self.match(&.{.Plus})) {
            while (true) {
                const bound_token = try self.expect(.Identifier, "Expected trait bound");
                const bound = try self.allocator.dupe(u8, bound_token.lexeme);
                try bounds.append(bound);
                
                if (!self.match(&.{.Plus})) break;
            }
        }
        
        type_expr.* = .{ .TraitObject = .{
            .trait_name = trait_name,
            .bounds = try bounds.toOwnedSlice(self.allocator),
        }};
        return type_expr;
    }
    
    // Handle Self type
    if (self.match(&.{.SelfType})) {
        type_expr.* = .SelfType;
        return type_expr;
    }
    
    // Handle reference types (&T, &mut T)
    if (self.match(&.{.Ampersand})) {
        const is_mut = self.match(&.{.Mut});
        const inner = try self.parseTypeExpr();
        
        type_expr.* = .{ .Reference = .{
            .is_mut = is_mut,
            .inner = inner,
        }};
        return type_expr;
    }
    
    // Handle named types and generics
    const name_token = try self.expect(.Identifier, "Expected type name");
    const type_name = try self.allocator.dupe(u8, name_token.lexeme);
    
    // Check for generic arguments
    if (self.match(&.{.Less})) {
        var args = std.ArrayList(*ast.TypeExpr).init(self.allocator);
        defer args.deinit();
        
        while (!self.check(.Greater) and !self.isAtEnd()) {
            const arg = try self.parseTypeExpr();
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
