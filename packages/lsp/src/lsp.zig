const std = @import("std");
const ast = @import("ast");
const parser_mod = @import("parser");
const lexer_mod = @import("lexer");

/// Language Server Protocol implementation for Home
/// Provides IDE features like autocomplete, goto definition, diagnostics
pub const LanguageServer = struct {
    allocator: std.mem.Allocator,
    documents: std.StringHashMap(Document),
    capabilities: ServerCapabilities,

    pub const Document = struct {
        uri: []const u8,
        text: []const u8,
        version: i32,
        ast: ?*ast.Program,
        diagnostics: std.ArrayList(Diagnostic),

        pub fn deinit(self: *Document, allocator: std.mem.Allocator) void {
            allocator.free(self.uri);
            allocator.free(self.text);
            self.diagnostics.deinit();
        }
    };

    pub const ServerCapabilities = struct {
        text_document_sync: TextDocumentSyncKind,
        completion_provider: bool,
        hover_provider: bool,
        definition_provider: bool,
        references_provider: bool,
        document_highlight_provider: bool,
        document_symbol_provider: bool,
        workspace_symbol_provider: bool,
        code_action_provider: bool,
        document_formatting_provider: bool,
        rename_provider: bool,
        semantic_tokens_provider: bool,

        pub fn default() ServerCapabilities {
            return .{
                .text_document_sync = .Full,
                .completion_provider = true,
                .hover_provider = true,
                .definition_provider = true,
                .references_provider = true,
                .document_highlight_provider = true,
                .document_symbol_provider = true,
                .workspace_symbol_provider = true,
                .code_action_provider = true,
                .document_formatting_provider = true,
                .rename_provider = true,
                .semantic_tokens_provider = true,
            };
        }
    };

    pub const TextDocumentSyncKind = enum(i32) {
        None = 0,
        Full = 1,
        Incremental = 2,
    };

    pub const Diagnostic = struct {
        range: Range,
        severity: DiagnosticSeverity,
        message: []const u8,
        source: []const u8,
    };

    pub const DiagnosticSeverity = enum(i32) {
        Error = 1,
        Warning = 2,
        Information = 3,
        Hint = 4,
    };

    pub const Range = struct {
        start: Position,
        end: Position,
    };

    pub const Position = struct {
        line: u32,
        character: u32,
    };

    pub const CompletionItem = struct {
        label: []const u8,
        kind: CompletionItemKind,
        detail: ?[]const u8,
        documentation: ?[]const u8,
        insert_text: ?[]const u8,
    };

    pub const CompletionItemKind = enum(i32) {
        Text = 1,
        Method = 2,
        Function = 3,
        Constructor = 4,
        Field = 5,
        Variable = 6,
        Class = 7,
        Interface = 8,
        Module = 9,
        Property = 10,
        Unit = 11,
        Value = 12,
        Enum = 13,
        Keyword = 14,
        Snippet = 15,
        Color = 16,
        File = 17,
        Reference = 18,
        Folder = 19,
        EnumMember = 20,
        Constant = 21,
        Struct = 22,
        Event = 23,
        Operator = 24,
        TypeParameter = 25,
    };

    pub const Location = struct {
        uri: []const u8,
        range: Range,
    };

    pub const SymbolInformation = struct {
        name: []const u8,
        kind: SymbolKind,
        location: Location,
        container_name: ?[]const u8,
    };

    pub const SymbolKind = enum(i32) {
        File = 1,
        Module = 2,
        Namespace = 3,
        Package = 4,
        Class = 5,
        Method = 6,
        Property = 7,
        Field = 8,
        Constructor = 9,
        Enum = 10,
        Interface = 11,
        Function = 12,
        Variable = 13,
        Constant = 14,
        String = 15,
        Number = 16,
        Boolean = 17,
        Array = 18,
        Object = 19,
        Key = 20,
        Null = 21,
        EnumMember = 22,
        Struct = 23,
        Event = 24,
        Operator = 25,
        TypeParameter = 26,
    };

    pub fn init(allocator: std.mem.Allocator) LanguageServer {
        return .{
            .allocator = allocator,
            .documents = std.StringHashMap(Document).init(allocator),
            .capabilities = ServerCapabilities.default(),
        };
    }

    pub fn deinit(self: *LanguageServer) void {
        var it = self.documents.valueIterator();
        while (it.next()) |doc| {
            doc.deinit(self.allocator);
        }
        self.documents.deinit();
    }

    /// Handle document open
    pub fn didOpenTextDocument(self: *LanguageServer, uri: []const u8, text: []const u8, version: i32) !void {
        const uri_copy = try self.allocator.dupe(u8, uri);
        errdefer self.allocator.free(uri_copy);

        const text_copy = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(text_copy);

        var doc = Document{
            .uri = uri_copy,
            .text = text_copy,
            .version = version,
            .ast = null,
            .diagnostics = std.ArrayList(Diagnostic).init(self.allocator),
        };
        errdefer doc.diagnostics.deinit();

        // Parse and analyze
        try self.analyzeDocument(&doc);

        try self.documents.put(uri_copy, doc);
    }

    /// Handle document change
    pub fn didChangeTextDocument(self: *LanguageServer, uri: []const u8, text: []const u8, version: i32) !void {
        if (self.documents.getPtr(uri)) |doc| {
            const old_text = doc.text;
            doc.text = try self.allocator.dupe(u8, text);
            errdefer {
                self.allocator.free(doc.text);
                doc.text = old_text;
            };
            self.allocator.free(old_text);
            doc.version = version;
            doc.diagnostics.clearRetainingCapacity();

            try self.analyzeDocument(doc);
        }
    }

    /// Handle document close
    pub fn didCloseTextDocument(self: *LanguageServer, uri: []const u8) void {
        if (self.documents.fetchRemove(uri)) |kv| {
            var doc = kv.value;
            doc.deinit(self.allocator);
        }
    }

    /// Analyze document and produce diagnostics
    fn analyzeDocument(self: *LanguageServer, doc: *Document) !void {
        // Lex
        var lexer = lexer_mod.Lexer.init(self.allocator, doc.text);
        var tokens = std.ArrayList(lexer_mod.Token).init(self.allocator);
        defer tokens.deinit();

        while (true) {
            const token = try lexer.nextToken();
            try tokens.append(token);
            if (token.type == .Eof) break;
        }

        // Parse
        const tokens_slice = try tokens.toOwnedSlice();
        errdefer self.allocator.free(tokens_slice);

        var parser = parser_mod.Parser.init(self.allocator, tokens_slice);
        defer parser.deinit();

        const program = parser.parse() catch |err| {
            // Add parse error as diagnostic
            const err_msg = try std.fmt.allocPrint(self.allocator, "Parse error: {}", .{err});
            errdefer self.allocator.free(err_msg);
            try doc.diagnostics.append(.{
                .range = .{
                    .start = .{ .line = 0, .character = 0 },
                    .end = .{ .line = 0, .character = 0 },
                },
                .severity = .Error,
                .message = err_msg,
                .source = "ion-lsp",
            });
            return;
        };

        doc.ast = program;

        // Semantic analysis
        try self.performSemanticAnalysis(doc, program);
    }

    /// Perform semantic analysis on the AST
    fn performSemanticAnalysis(self: *LanguageServer, doc: *Document, program: *ast.Program) !void {
        // Track defined symbols for undefined variable checking
        var defined_symbols = std.StringHashMap(void).init(self.allocator);
        defer defined_symbols.deinit();

        // First pass: collect all function, struct, and enum declarations
        for (program.statements) |stmt| {
            switch (stmt) {
                .FunctionDecl => |func_decl| {
                    try defined_symbols.put(func_decl.name, {});
                },
                .StructDecl => |struct_decl| {
                    try defined_symbols.put(struct_decl.name, {});
                },
                .EnumDecl => |enum_decl| {
                    try defined_symbols.put(enum_decl.name, {});
                },
                .ConstDecl => |const_decl| {
                    try defined_symbols.put(const_decl.name, {});
                },
                else => {},
            }
        }

        // Second pass: check for undefined variables in function bodies
        for (program.statements) |stmt| {
            switch (stmt) {
                .FunctionDecl => |func_decl| {
                    try self.checkFunctionBody(doc, &func_decl.body, &defined_symbols, func_decl.params);
                },
                else => {},
            }
        }
    }

    /// Check a function body for undefined variables
    fn checkFunctionBody(
        self: *LanguageServer,
        doc: *Document,
        block: *const ast.BlockStmt,
        defined_symbols: *std.StringHashMap(void),
        params: []const ast.FunctionParam,
    ) !void {
        // Track local variables within this scope
        var local_vars = std.StringHashMap(void).init(self.allocator);
        defer local_vars.deinit();

        // Add function parameters to local scope
        for (params) |param| {
            try local_vars.put(param.name, {});
        }

        // Check each statement
        for (block.statements) |stmt| {
            try self.checkStatement(doc, &stmt, defined_symbols, &local_vars);
        }
    }

    /// Check a statement for undefined variables
    fn checkStatement(
        self: *LanguageServer,
        doc: *Document,
        stmt: *const ast.Stmt,
        defined_symbols: *std.StringHashMap(void),
        local_vars: *std.StringHashMap(void),
    ) !void {
        switch (stmt.*) {
            .LetDecl => |let_decl| {
                // Add to local scope
                try local_vars.put(let_decl.name, {});

                // Check initializer expression
                if (let_decl.initializer) |init_expr| {
                    try self.checkExpression(doc, init_expr, defined_symbols, local_vars);
                }
            },
            .ConstDecl => |const_decl| {
                // Add to local scope
                try local_vars.put(const_decl.name, {});

                // Check initializer expression
                if (const_decl.initializer) |init_expr| {
                    try self.checkExpression(doc, init_expr, defined_symbols, local_vars);
                }
            },
            .ExprStmt => |expr| {
                try self.checkExpression(doc, expr, defined_symbols, local_vars);
            },
            .ReturnStmt => |ret_stmt| {
                if (ret_stmt.expression) |expr| {
                    try self.checkExpression(doc, expr, defined_symbols, local_vars);
                }
            },
            .IfStmt => |if_stmt| {
                try self.checkExpression(doc, if_stmt.condition, defined_symbols, local_vars);
                try self.checkFunctionBodyHelper(doc, &if_stmt.then_block, defined_symbols, local_vars);
                if (if_stmt.else_block) |else_block| {
                    try self.checkFunctionBodyHelper(doc, &else_block, defined_symbols, local_vars);
                }
            },
            .WhileStmt => |while_stmt| {
                try self.checkExpression(doc, while_stmt.condition, defined_symbols, local_vars);
                try self.checkFunctionBodyHelper(doc, &while_stmt.body, defined_symbols, local_vars);
            },
            .ForStmt => |for_stmt| {
                try self.checkExpression(doc, for_stmt.iterable, defined_symbols, local_vars);
                // Add loop variable to local scope
                try local_vars.put(for_stmt.variable, {});
                try self.checkFunctionBodyHelper(doc, &for_stmt.body, defined_symbols, local_vars);
            },
            .AssignmentStmt => |assign_stmt| {
                try self.checkExpression(doc, assign_stmt.target, defined_symbols, local_vars);
                try self.checkExpression(doc, assign_stmt.value, defined_symbols, local_vars);
            },
            else => {},
        }
    }

    /// Helper to check a block with existing local scope
    fn checkFunctionBodyHelper(
        self: *LanguageServer,
        doc: *Document,
        block: *const ast.BlockStmt,
        defined_symbols: *std.StringHashMap(void),
        local_vars: *std.StringHashMap(void),
    ) !void {
        for (block.statements) |stmt| {
            try self.checkStatement(doc, &stmt, defined_symbols, local_vars);
        }
    }

    /// Check an expression for undefined variables
    fn checkExpression(
        self: *LanguageServer,
        doc: *Document,
        expr: *const ast.Expr,
        defined_symbols: *std.StringHashMap(void),
        local_vars: *std.StringHashMap(void),
    ) !void {
        switch (expr.*) {
            .Identifier => |id| {
                // Check if identifier is defined
                if (!local_vars.contains(id.name) and !defined_symbols.contains(id.name)) {
                    // Undefined variable
                    try doc.diagnostics.append(.{
                        .range = .{
                            .start = .{ .line = @intCast(id.node.loc.line), .character = @intCast(id.node.loc.column) },
                            .end = .{ .line = @intCast(id.node.loc.line), .character = @intCast(id.node.loc.column + id.name.len) },
                        },
                        .severity = .Error,
                        .message = try std.fmt.allocPrint(self.allocator, "Undefined variable: {s}", .{id.name}),
                        .source = "semantic-analysis",
                    });
                }
            },
            .BinaryExpr => |bin| {
                try self.checkExpression(doc, bin.left, defined_symbols, local_vars);
                try self.checkExpression(doc, bin.right, defined_symbols, local_vars);
            },
            .UnaryExpr => |un| {
                try self.checkExpression(doc, un.operand, defined_symbols, local_vars);
            },
            .CallExpr => |call| {
                try self.checkExpression(doc, call.callee, defined_symbols, local_vars);
                for (call.arguments) |arg| {
                    try self.checkExpression(doc, arg, defined_symbols, local_vars);
                }
            },
            .MemberExpr => |member| {
                try self.checkExpression(doc, member.object, defined_symbols, local_vars);
            },
            .IndexExpr => |index| {
                try self.checkExpression(doc, index.array, defined_symbols, local_vars);
                try self.checkExpression(doc, index.index, defined_symbols, local_vars);
            },
            .ArrayLiteral => |arr| {
                for (arr.elements) |elem| {
                    try self.checkExpression(doc, elem, defined_symbols, local_vars);
                }
            },
            .StructLiteral => |struct_lit| {
                for (struct_lit.fields) |field| {
                    try self.checkExpression(doc, field.value, defined_symbols, local_vars);
                }
            },
            else => {},
        }
    }

    /// Provide completions at position
    pub fn completion(self: *LanguageServer, uri: []const u8, position: Position) ![]CompletionItem {
        _ = position;

        const doc = self.documents.get(uri) orelse return &[_]CompletionItem{};
        _ = doc;

        var items = std.ArrayList(CompletionItem).init(self.allocator);
        errdefer items.deinit();

        // Keywords
        const keywords = [_][]const u8{
            "fn",      "let",    "const",  "if",      "else",     "while",  "for",
            "return",  "struct", "enum",   "type",    "async",    "await",  "comptime",
            "import",  "export", "pub",    "mut",     "defer",    "try",    "catch",
            "switch",  "case",   "break",  "continue", "true",     "false",  "null",
        };

        for (keywords) |kw| {
            try items.append(.{
                .label = kw,
                .kind = .Keyword,
                .detail = null,
                .documentation = null,
                .insert_text = null,
            });
        }

        // Built-in types
        const types = [_][]const u8{ "int", "float", "bool", "string", "void" };
        for (types) |ty| {
            try items.append(.{
                .label = ty,
                .kind = .Keyword,
                .detail = "Built-in type",
                .documentation = null,
                .insert_text = null,
            });
        }

        // Add symbols from AST
        if (doc.ast) |program| {
            // Add functions
            for (program.statements) |stmt| {
                switch (stmt) {
                    .FunctionDecl => |func_decl| {
                        const detail = try self.formatFunctionSignature(func_decl);
                        try items.append(.{
                            .label = func_decl.name,
                            .kind = .Function,
                            .detail = detail,
                            .documentation = null,
                            .insert_text = null,
                        });
                    },
                    .StructDecl => |struct_decl| {
                        try items.append(.{
                            .label = struct_decl.name,
                            .kind = .Struct,
                            .detail = "struct",
                            .documentation = null,
                            .insert_text = null,
                        });
                    },
                    .EnumDecl => |enum_decl| {
                        try items.append(.{
                            .label = enum_decl.name,
                            .kind = .Enum,
                            .detail = "enum",
                            .documentation = null,
                            .insert_text = null,
                        });
                    },
                    .ConstDecl => |const_decl| {
                        try items.append(.{
                            .label = const_decl.name,
                            .kind = .Constant,
                            .detail = "const",
                            .documentation = null,
                            .insert_text = null,
                        });
                    },
                    else => {},
                }
            }
        }

        return try items.toOwnedSlice();
    }

    /// Format a function signature for display
    fn formatFunctionSignature(self: *LanguageServer, func_decl: ast.FunctionDecl) ![]const u8 {
        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();

        try buf.appendSlice("fn ");
        try buf.appendSlice(func_decl.name);
        try buf.append('(');

        for (func_decl.params, 0..) |param, i| {
            if (i > 0) try buf.appendSlice(", ");
            try buf.appendSlice(param.name);
            if (param.type_annotation) |type_ann| {
                try buf.appendSlice(": ");
                try buf.appendSlice(try self.formatType(type_ann));
            }
        }

        try buf.append(')');

        if (func_decl.return_type) |ret_type| {
            try buf.appendSlice(" -> ");
            try buf.appendSlice(try self.formatType(ret_type));
        }

        return try self.allocator.dupe(u8, buf.items);
    }

    /// Format a type for display
    fn formatType(self: *LanguageServer, typ: ast.Type) ![]const u8 {
        _ = self;
        return switch (typ) {
            .Int => "int",
            .Float => "float",
            .Bool => "bool",
            .String => "string",
            .Void => "void",
            .I32 => "i32",
            .I64 => "i64",
            .F32 => "f32",
            .F64 => "f64",
            else => "unknown",
        };
    }

    /// Go to definition
    pub fn gotoDefinition(self: *LanguageServer, uri: []const u8, position: Position) !?Location {
        const doc = self.documents.get(uri) orelse return null;

        if (doc.ast) |program| {
            // Get the symbol at the cursor position
            const symbol_name = try self.getSymbolAtPosition(doc, position);
            if (symbol_name) |name| {
                // Search for the definition in the AST
                return try self.findDefinitionLocation(program, name, uri);
            }
        }

        return null;
    }

    /// Get the symbol name at a given position
    fn getSymbolAtPosition(self: *LanguageServer, doc: *Document, position: Position) !?[]const u8 {
        _ = self;

        // Split document into lines
        var line_iter = std.mem.splitScalar(u8, doc.text, '\n');
        var current_line: u32 = 0;

        while (line_iter.next()) |line| : (current_line += 1) {
            if (current_line == position.line) {
                // Found the line, now extract the identifier at the position
                if (position.character >= line.len) return null;

                // Find identifier boundaries
                var start = position.character;
                var end = position.character;

                // Move start back to start of identifier
                while (start > 0 and isIdentifierChar(line[start - 1])) {
                    start -= 1;
                }

                // Move end forward to end of identifier
                while (end < line.len and isIdentifierChar(line[end])) {
                    end += 1;
                }

                if (start < end) {
                    return line[start..end];
                }
            }
        }

        return null;
    }

    /// Check if a character is part of an identifier
    fn isIdentifierChar(c: u8) bool {
        return (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '_';
    }

    /// Find the definition location of a symbol
    fn findDefinitionLocation(self: *LanguageServer, program: *ast.Program, symbol_name: []const u8, uri: []const u8) !?Location {
        _ = self;

        for (program.statements) |stmt| {
            switch (stmt) {
                .FunctionDecl => |func_decl| {
                    if (std.mem.eql(u8, func_decl.name, symbol_name)) {
                        return Location{
                            .uri = uri,
                            .range = .{
                                .start = .{ .line = @intCast(func_decl.node.loc.line), .character = @intCast(func_decl.node.loc.column) },
                                .end = .{ .line = @intCast(func_decl.node.loc.line), .character = @intCast(func_decl.node.loc.column + func_decl.name.len) },
                            },
                        };
                    }
                },
                .StructDecl => |struct_decl| {
                    if (std.mem.eql(u8, struct_decl.name, symbol_name)) {
                        return Location{
                            .uri = uri,
                            .range = .{
                                .start = .{ .line = @intCast(struct_decl.node.loc.line), .character = @intCast(struct_decl.node.loc.column) },
                                .end = .{ .line = @intCast(struct_decl.node.loc.line), .character = @intCast(struct_decl.node.loc.column + struct_decl.name.len) },
                            },
                        };
                    }
                },
                .EnumDecl => |enum_decl| {
                    if (std.mem.eql(u8, enum_decl.name, symbol_name)) {
                        return Location{
                            .uri = uri,
                            .range = .{
                                .start = .{ .line = @intCast(enum_decl.node.loc.line), .character = @intCast(enum_decl.node.loc.column) },
                                .end = .{ .line = @intCast(enum_decl.node.loc.line), .character = @intCast(enum_decl.node.loc.column + enum_decl.name.len) },
                            },
                        };
                    }
                },
                .ConstDecl => |const_decl| {
                    if (std.mem.eql(u8, const_decl.name, symbol_name)) {
                        return Location{
                            .uri = uri,
                            .range = .{
                                .start = .{ .line = @intCast(const_decl.node.loc.line), .character = @intCast(const_decl.node.loc.column) },
                                .end = .{ .line = @intCast(const_decl.node.loc.line), .character = @intCast(const_decl.node.loc.column + const_decl.name.len) },
                            },
                        };
                    }
                },
                else => {},
            }
        }

        return null;
    }

    /// Find references
    pub fn findReferences(self: *LanguageServer, uri: []const u8, position: Position) ![]Location {
        const doc = self.documents.get(uri) orelse return &[_]Location{};

        if (doc.ast) |program| {
            // Get the symbol at the cursor position
            const symbol_name = try self.getSymbolAtPosition(doc, position);
            if (symbol_name) |name| {
                // Find all references to this symbol
                var locations = std.ArrayList(Location).init(self.allocator);
                errdefer locations.deinit();

                try self.findReferencesInProgram(program, name, uri, &locations);

                return try locations.toOwnedSlice();
            }
        }

        return &[_]Location{};
    }

    /// Find all references to a symbol in the program
    fn findReferencesInProgram(
        self: *LanguageServer,
        program: *ast.Program,
        symbol_name: []const u8,
        uri: []const u8,
        locations: *std.ArrayList(Location),
    ) !void {
        for (program.statements) |stmt| {
            try self.findReferencesInStmt(&stmt, symbol_name, uri, locations);
        }
    }

    /// Find references in a statement
    fn findReferencesInStmt(
        self: *LanguageServer,
        stmt: *const ast.Stmt,
        symbol_name: []const u8,
        uri: []const u8,
        locations: *std.ArrayList(Location),
    ) !void {
        switch (stmt.*) {
            .FunctionDecl => |func_decl| {
                try self.findReferencesInBlock(&func_decl.body, symbol_name, uri, locations);
            },
            .ExprStmt => |expr| {
                try self.findReferencesInExpr(expr, symbol_name, uri, locations);
            },
            .LetDecl => |let_decl| {
                if (let_decl.initializer) |init_expr| {
                    try self.findReferencesInExpr(init_expr, symbol_name, uri, locations);
                }
            },
            .ReturnStmt => |ret_stmt| {
                if (ret_stmt.expression) |expr| {
                    try self.findReferencesInExpr(expr, symbol_name, uri, locations);
                }
            },
            else => {},
        }
    }

    /// Find references in a block
    fn findReferencesInBlock(
        self: *LanguageServer,
        block: *const ast.BlockStmt,
        symbol_name: []const u8,
        uri: []const u8,
        locations: *std.ArrayList(Location),
    ) !void {
        for (block.statements) |stmt| {
            try self.findReferencesInStmt(&stmt, symbol_name, uri, locations);
        }
    }

    /// Find references in an expression
    fn findReferencesInExpr(
        self: *LanguageServer,
        expr: *const ast.Expr,
        symbol_name: []const u8,
        uri: []const u8,
        locations: *std.ArrayList(Location),
    ) !void {
        switch (expr.*) {
            .Identifier => |id| {
                if (std.mem.eql(u8, id.name, symbol_name)) {
                    try locations.append(.{
                        .uri = uri,
                        .range = .{
                            .start = .{ .line = @intCast(id.node.loc.line), .character = @intCast(id.node.loc.column) },
                            .end = .{ .line = @intCast(id.node.loc.line), .character = @intCast(id.node.loc.column + id.name.len) },
                        },
                    });
                }
            },
            .BinaryExpr => |bin| {
                try self.findReferencesInExpr(bin.left, symbol_name, uri, locations);
                try self.findReferencesInExpr(bin.right, symbol_name, uri, locations);
            },
            .UnaryExpr => |un| {
                try self.findReferencesInExpr(un.operand, symbol_name, uri, locations);
            },
            .CallExpr => |call| {
                try self.findReferencesInExpr(call.callee, symbol_name, uri, locations);
                for (call.arguments) |arg| {
                    try self.findReferencesInExpr(arg, symbol_name, uri, locations);
                }
            },
            .MemberExpr => |member| {
                try self.findReferencesInExpr(member.object, symbol_name, uri, locations);
            },
            .IndexExpr => |index| {
                try self.findReferencesInExpr(index.array, symbol_name, uri, locations);
                try self.findReferencesInExpr(index.index, symbol_name, uri, locations);
            },
            else => {},
        }
    }

    /// Document symbols
    pub fn documentSymbols(self: *LanguageServer, uri: []const u8) ![]SymbolInformation {
        const doc = self.documents.get(uri) orelse return &[_]SymbolInformation{};

        var symbols = std.ArrayList(SymbolInformation).init(self.allocator);
        errdefer symbols.deinit();

        if (doc.ast) |program| {
            for (program.statements) |stmt| {
                switch (stmt.*) {
                    .FnDecl => |fn_decl| {
                        try symbols.append(.{
                            .name = fn_decl.name,
                            .kind = .Function,
                            .location = .{
                                .uri = uri,
                                .range = .{
                                    .start = .{ .line = @intCast(fn_decl.node.loc.line), .character = 0 },
                                    .end = .{ .line = @intCast(fn_decl.node.loc.line), .character = 0 },
                                },
                            },
                            .container_name = null,
                        });
                    },
                    .StructDecl => |struct_decl| {
                        try symbols.append(.{
                            .name = struct_decl.name,
                            .kind = .Struct,
                            .location = .{
                                .uri = uri,
                                .range = .{
                                    .start = .{ .line = @intCast(struct_decl.node.loc.line), .character = 0 },
                                    .end = .{ .line = @intCast(struct_decl.node.loc.line), .character = 0 },
                                },
                            },
                            .container_name = null,
                        });
                    },
                    .EnumDecl => |enum_decl| {
                        try symbols.append(.{
                            .name = enum_decl.name,
                            .kind = .Enum,
                            .location = .{
                                .uri = uri,
                                .range = .{
                                    .start = .{ .line = @intCast(enum_decl.node.loc.line), .character = 0 },
                                    .end = .{ .line = @intCast(enum_decl.node.loc.line), .character = 0 },
                                },
                            },
                            .container_name = null,
                        });
                    },
                    else => {},
                }
            }
        }

        return try symbols.toOwnedSlice();
    }

    /// Hover information
    pub fn hover(self: *LanguageServer, uri: []const u8, position: Position) !?[]const u8 {
        _ = position;

        const doc = self.documents.get(uri) orelse return null;
        _ = doc;

        // TODO: Provide type information and documentation

        return null;
    }

    /// Format document
    pub fn formatDocument(self: *LanguageServer, uri: []const u8) ![]const u8 {
        const doc = self.documents.get(uri) orelse return "";

        // TODO: Use formatter package
        return doc.text;
    }
};
