const std = @import("std");
const ast = @import("ast");
const lexer = @import("lexer");
const parser = @import("parser");
const types = @import("types");

/// Language Server Protocol implementation for Home language
///
/// Provides IDE features:
/// - Auto-completion
/// - Go-to-definition
/// - Find references
/// - Hover information
/// - Diagnostics
/// - Formatting
/// - Refactoring
pub const LanguageServer = struct {
    allocator: std.mem.Allocator,
    /// Open documents indexed by URI
    documents: std.StringHashMap(Document),
    /// Workspace root path
    workspace_root: ?[]const u8,
    /// Server capabilities
    capabilities: ServerCapabilities,
    /// Type checker for semantic analysis
    type_checker: ?*types.TypeChecker,
    /// Running state
    is_running: bool,

    pub const Document = struct {
        uri: []const u8,
        text: []const u8,
        version: i32,
        /// Parsed AST (cached)
        ast: ?*ast.Program,
        /// Diagnostics for this document
        diagnostics: std.ArrayList(Diagnostic),
        /// Symbol table for quick lookups
        symbols: std.ArrayList(Symbol),
    };

    pub const Symbol = struct {
        name: []const u8,
        kind: SymbolKind,
        range: Range,
        /// Containing scope
        container: ?[]const u8,
    };

    pub const SymbolKind = enum {
        Function,
        Struct,
        Enum,
        Trait,
        Variable,
        Constant,
        TypeAlias,
        Module,
        Field,
        EnumVariant,
    };

    pub const Diagnostic = struct {
        range: Range,
        severity: DiagnosticSeverity,
        message: []const u8,
        source: []const u8,
    };

    pub const DiagnosticSeverity = enum(u8) {
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

    pub const ServerCapabilities = struct {
        text_document_sync: bool,
        completion_provider: bool,
        hover_provider: bool,
        definition_provider: bool,
        references_provider: bool,
        document_formatting_provider: bool,
        rename_provider: bool,
        code_action_provider: bool,
        semantic_highlighting: bool,
    };

    pub fn init(allocator: std.mem.Allocator) LanguageServer {
        return .{
            .allocator = allocator,
            .documents = std.StringHashMap(Document).init(allocator),
            .workspace_root = null,
            .capabilities = .{
                .text_document_sync = true,
                .completion_provider = true,
                .hover_provider = true,
                .definition_provider = true,
                .references_provider = true,
                .document_formatting_provider = true,
                .rename_provider = true,
                .code_action_provider = true,
                .semantic_highlighting = true,
            },
            .type_checker = null,
            .is_running = false,
        };
    }

    pub fn deinit(self: *LanguageServer) void {
        var it = self.documents.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.text);
            if (entry.value_ptr.ast) |program| {
                program.deinit();
            }
            entry.value_ptr.diagnostics.deinit(self.allocator);
            entry.value_ptr.symbols.deinit(self.allocator);
        }
        self.documents.deinit();
    }

    /// Initialize the language server
    pub fn initialize(self: *LanguageServer, root_uri: ?[]const u8) !void {
        self.workspace_root = if (root_uri) |uri| try self.allocator.dupe(u8, uri) else null;
        self.is_running = true;
    }

    /// Handle document open notification
    pub fn didOpen(self: *LanguageServer, uri: []const u8, text: []const u8, version: i32) !void {
        const uri_copy = try self.allocator.dupe(u8, uri);
        const text_copy = try self.allocator.dupe(u8, text);

        var doc = Document{
            .uri = uri_copy,
            .text = text_copy,
            .version = version,
            .ast = null,
            .diagnostics = std.ArrayList(Diagnostic){},
            .symbols = std.ArrayList(Symbol){},
        };

        // Parse the document
        try self.parseDocument(&doc);

        // Extract symbols
        try self.extractSymbols(&doc);

        // Run diagnostics
        try self.runDiagnostics(&doc);

        try self.documents.put(uri_copy, doc);
    }

    /// Handle document change notification
    pub fn didChange(self: *LanguageServer, uri: []const u8, text: []const u8, version: i32) !void {
        if (self.documents.getPtr(uri)) |doc| {
            // Update document
            self.allocator.free(doc.text);
            doc.text = try self.allocator.dupe(u8, text);
            doc.version = version;

            // Clear old AST
            if (doc.ast) |program| {
                program.deinit();
                doc.ast = null;
            }

            // Re-parse
            try self.parseDocument(doc);

            // Re-extract symbols
            doc.symbols.clearRetainingCapacity();
            try self.extractSymbols(doc);

            // Re-run diagnostics
            doc.diagnostics.clearRetainingCapacity();
            try self.runDiagnostics(doc);
        }
    }

    /// Handle document close notification
    pub fn didClose(self: *LanguageServer, uri: []const u8) !void {
        if (self.documents.fetchRemove(uri)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value.text);
            if (entry.value.ast) |program| {
                program.deinit();
            }
            entry.value.diagnostics.deinit(self.allocator);
            entry.value.symbols.deinit(self.allocator);
        }
    }

    /// Parse a document and update its AST
    fn parseDocument(self: *LanguageServer, doc: *Document) !void {
        var lex = try lexer.Lexer.init(self.allocator, doc.text);
        defer lex.deinit();

        const tokens = try lex.tokenize();

        var pars = parser.Parser.init(self.allocator, tokens);
        doc.ast = try pars.parse();
    }

    /// Extract symbols from parsed AST
    fn extractSymbols(self: *LanguageServer, doc: *Document) !void {
        if (doc.ast) |program| {
            for (program.statements) |stmt| {
                try self.extractSymbolsFromStmt(doc, stmt, null);
            }
        }
    }

    fn extractSymbolsFromStmt(self: *LanguageServer, doc: *Document, stmt: *const ast.Stmt, container: ?[]const u8) !void {
        switch (stmt.*) {
            .FunctionDecl => |func| {
                try doc.symbols.append(self.allocator, .{
                    .name = func.name,
                    .kind = .Function,
                    .range = self.nodeToRange(func.node),
                    .container = container,
                });
            },
            .StructDecl => |struct_decl| {
                try doc.symbols.append(self.allocator, .{
                    .name = struct_decl.name,
                    .kind = .Struct,
                    .range = self.nodeToRange(struct_decl.node),
                    .container = container,
                });
            },
            .EnumDecl => |enum_decl| {
                try doc.symbols.append(self.allocator, .{
                    .name = enum_decl.name,
                    .kind = .Enum,
                    .range = self.nodeToRange(enum_decl.node),
                    .container = container,
                });
            },
            .TraitDecl => |trait_decl| {
                try doc.symbols.append(self.allocator, .{
                    .name = trait_decl.name,
                    .kind = .Trait,
                    .range = self.nodeToRange(trait_decl.node),
                    .container = container,
                });
            },
            .LetDecl => |let_decl| {
                try doc.symbols.append(self.allocator, .{
                    .name = let_decl.name,
                    .kind = .Variable,
                    .range = self.nodeToRange(let_decl.node),
                    .container = container,
                });
            },
            .ConstDecl => |const_decl| {
                try doc.symbols.append(self.allocator, .{
                    .name = const_decl.name,
                    .kind = .Constant,
                    .range = self.nodeToRange(const_decl.node),
                    .container = container,
                });
            },
            else => {},
        }
    }

    fn nodeToRange(self: *LanguageServer, node: ast.Node) Range {
        _ = self;
        return Range{
            .start = .{ .line = node.loc.line, .character = node.loc.column },
            .end = .{ .line = node.loc.line, .character = node.loc.column },
        };
    }

    /// Run type checking and collect diagnostics
    fn runDiagnostics(self: *LanguageServer, doc: *Document) !void {
        if (doc.ast) |program| {
            var checker = types.TypeChecker.init(self.allocator, program);
            defer checker.deinit();

            _ = checker.check() catch {};

            // Convert type errors to diagnostics
            for (checker.errors.items) |err| {
                try doc.diagnostics.append(self.allocator, .{
                    .range = Range{
                        .start = .{ .line = err.loc.line, .character = err.loc.column },
                        .end = .{ .line = err.loc.line, .character = err.loc.column },
                    },
                    .severity = .Error,
                    .message = err.message,
                    .source = "home-lsp",
                });
            }
        }
    }

    /// Get completions at a position
    pub fn getCompletions(self: *LanguageServer, uri: []const u8, position: Position) ![]CompletionItem {
        const doc = self.documents.get(uri) orelse return &[_]CompletionItem{};

        var completions = std.ArrayList(CompletionItem).init(self.allocator);

        // Add symbols from current document
        for (doc.symbols.items) |symbol| {
            try completions.append(.{
                .label = symbol.name,
                .kind = self.symbolKindToCompletionKind(symbol.kind),
                .detail = null,
                .documentation = null,
            });
        }

        // Add keywords
        const keywords = [_][]const u8{
            "fn",      "struct", "enum",    "trait", "impl",   "let",
            "const",   "mut",    "if",      "else",  "while",  "for",
            "match",   "return", "break",   "continue", "async", "await",
            "pub",     "use",    "mod",     "type",  "where",  "self",
            "Self",    "true",   "false",   "null",
        };

        for (keywords) |kw| {
            try completions.append(.{
                .label = kw,
                .kind = .Keyword,
                .detail = null,
                .documentation = null,
            });
        }

        _ = position;
        return try completions.toOwnedSlice();
    }

    fn symbolKindToCompletionKind(self: *LanguageServer, kind: SymbolKind) CompletionItemKind {
        _ = self;
        return switch (kind) {
            .Function => .Function,
            .Struct => .Struct,
            .Enum => .Enum,
            .Trait => .Interface,
            .Variable => .Variable,
            .Constant => .Constant,
            .TypeAlias => .TypeParameter,
            .Module => .Module,
            .Field => .Field,
            .EnumVariant => .EnumMember,
        };
    }

    pub const CompletionItem = struct {
        label: []const u8,
        kind: CompletionItemKind,
        detail: ?[]const u8,
        documentation: ?[]const u8,
    };

    pub const CompletionItemKind = enum(u8) {
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
        Enum = 13,
        Keyword = 14,
        Constant = 21,
        Struct = 22,
        TypeParameter = 25,
        EnumMember = 20,
    };

    /// Get hover information at a position
    pub fn getHover(self: *LanguageServer, uri: []const u8, position: Position) !?HoverInfo {
        const doc = self.documents.get(uri) orelse return null;

        // Find symbol at position
        if (try self.findSymbolAtPosition(doc, position)) |symbol| {
            // Build hover contents with type information
            var contents = std.ArrayList(u8).init(self.allocator);
            defer contents.deinit();

            try contents.appendSlice("```home\n");
            try contents.appendSlice(@tagName(symbol.kind));
            try contents.append(' ');
            try contents.appendSlice(symbol.name);
            try contents.appendSlice("\n```\n");

            // Add additional information based on symbol kind
            switch (symbol.kind) {
                .Function => try contents.appendSlice("\n**Function**\n"),
                .Struct => try contents.appendSlice("\n**Struct**\n"),
                .Enum => try contents.appendSlice("\n**Enum**\n"),
                .Trait => try contents.appendSlice("\n**Trait**\n"),
                .Variable => try contents.appendSlice("\n**Variable**\n"),
                .Constant => try contents.appendSlice("\n**Constant**\n"),
                else => {},
            }

            if (symbol.container) |container| {
                try contents.appendSlice("Defined in: `");
                try contents.appendSlice(container);
                try contents.appendSlice("`\n");
            }

            return HoverInfo{
                .contents = try self.allocator.dupe(u8, contents.items),
                .range = symbol.range,
            };
        }

        return null;
    }

    pub const HoverInfo = struct {
        contents: []const u8,
        range: ?Range,
    };

    /// Get definition location
    pub fn getDefinition(self: *LanguageServer, uri: []const u8, position: Position) !?Location {
        const doc = self.documents.get(uri) orelse return null;

        // Find the identifier at the cursor position
        const identifier = try self.getIdentifierAtPosition(doc, position) orelse return null;

        // Search for the definition in current document
        for (doc.symbols.items) |symbol| {
            if (std.mem.eql(u8, symbol.name, identifier)) {
                return Location{
                    .uri = uri,
                    .range = symbol.range,
                };
            }
        }

        // Search in other workspace documents
        var doc_iter = self.documents.iterator();
        while (doc_iter.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, uri)) continue; // Skip current doc

            for (entry.value_ptr.symbols.items) |symbol| {
                if (std.mem.eql(u8, symbol.name, identifier)) {
                    return Location{
                        .uri = entry.key_ptr.*,
                        .range = symbol.range,
                    };
                }
            }
        }

        return null;
    }

    pub const Location = struct {
        uri: []const u8,
        range: Range,
    };

    /// Find all references
    pub fn getReferences(self: *LanguageServer, uri: []const u8, position: Position) ![]Location {
        const doc = self.documents.get(uri) orelse return &[_]Location{};

        // Find the identifier at the cursor position
        const identifier = try self.getIdentifierAtPosition(doc, position) orelse return &[_]Location{};

        var locations = std.ArrayList(Location).init(self.allocator);

        // Search for references in the AST
        if (doc.ast) |program| {
            for (program.statements) |stmt| {
                try self.findReferencesInStmt(&locations, &stmt, identifier, uri);
            }
        }

        return try locations.toOwnedSlice();
    }

    /// Find symbol at a specific position
    fn findSymbolAtPosition(self: *LanguageServer, doc: Document, position: Position) !?Symbol {
        _ = self;
        for (doc.symbols.items) |symbol| {
            if (self.positionInRange(position, symbol.range)) {
                return symbol;
            }
        }
        return null;
    }

    /// Check if position is within range
    fn positionInRange(self: *LanguageServer, position: Position, range: Range) bool {
        _ = self;
        if (position.line < range.start.line or position.line > range.end.line) {
            return false;
        }
        if (position.line == range.start.line and position.character < range.start.character) {
            return false;
        }
        if (position.line == range.end.line and position.character > range.end.character) {
            return false;
        }
        return true;
    }

    /// Get identifier at position from document text
    fn getIdentifierAtPosition(self: *LanguageServer, doc: Document, position: Position) !?[]const u8 {
        const lines = std.mem.split(u8, doc.text, "\n");
        var current_line: u32 = 0;
        var line_iter = lines;

        while (line_iter.next()) |line| : (current_line += 1) {
            if (current_line == position.line) {
                // Find identifier boundaries
                if (position.character >= line.len) return null;

                var start = position.character;
                var end = position.character;

                // Expand left
                while (start > 0 and self.isIdentifierChar(line[start - 1])) {
                    start -= 1;
                }

                // Expand right
                while (end < line.len and self.isIdentifierChar(line[end])) {
                    end += 1;
                }

                if (start == end) return null;
                return try self.allocator.dupe(u8, line[start..end]);
            }
        }

        return null;
    }

    /// Check if character is valid in identifier
    fn isIdentifierChar(self: *LanguageServer, c: u8) bool {
        _ = self;
        return std.ascii.isAlphanumeric(c) or c == '_';
    }

    /// Find references to an identifier in a statement
    fn findReferencesInStmt(
        self: *LanguageServer,
        locations: *std.ArrayList(Location),
        stmt: *const ast.Stmt,
        identifier: []const u8,
        uri: []const u8,
    ) !void {
        switch (stmt.*) {
            .LetDecl => |let_decl| {
                if (std.mem.eql(u8, let_decl.name, identifier)) {
                    try locations.append(.{
                        .uri = uri,
                        .range = self.nodeToRange(let_decl.node),
                    });
                }
                if (let_decl.initializer) |init_expr| {
                    try self.findReferencesInExpr(locations, init_expr, identifier, uri);
                }
            },
            .ConstDecl => |const_decl| {
                if (std.mem.eql(u8, const_decl.name, identifier)) {
                    try locations.append(.{
                        .uri = uri,
                        .range = self.nodeToRange(const_decl.node),
                    });
                }
            },
            .ReturnStmt => |ret_stmt| {
                if (ret_stmt.expression) |expr| {
                    try self.findReferencesInExpr(locations, expr, identifier, uri);
                }
            },
            .ExprStmt => |expr| {
                try self.findReferencesInExpr(locations, expr, identifier, uri);
            },
            .IfStmt => |if_stmt| {
                try self.findReferencesInExpr(locations, if_stmt.condition, identifier, uri);
                for (if_stmt.then_block.statements) |block_stmt| {
                    try self.findReferencesInStmt(locations, &block_stmt, identifier, uri);
                }
                if (if_stmt.else_block) |else_block| {
                    for (else_block.statements) |block_stmt| {
                        try self.findReferencesInStmt(locations, &block_stmt, identifier, uri);
                    }
                }
            },
            else => {},
        }
    }

    /// Find references to an identifier in an expression
    fn findReferencesInExpr(
        self: *LanguageServer,
        locations: *std.ArrayList(Location),
        expr: *ast.Expr,
        identifier: []const u8,
        uri: []const u8,
    ) !void {
        switch (expr.*) {
            .Identifier => |id| {
                if (std.mem.eql(u8, id.name, identifier)) {
                    try locations.append(.{
                        .uri = uri,
                        .range = self.nodeToRange(id.node),
                    });
                }
            },
            .BinaryExpr => |bin| {
                try self.findReferencesInExpr(locations, bin.left, identifier, uri);
                try self.findReferencesInExpr(locations, bin.right, identifier, uri);
            },
            .CallExpr => |call| {
                try self.findReferencesInExpr(locations, call.callee, identifier, uri);
                for (call.arguments) |arg| {
                    try self.findReferencesInExpr(locations, arg, identifier, uri);
                }
            },
            else => {},
        }
    }

    /// Format document
    pub fn formatDocument(self: *LanguageServer, uri: []const u8) ![]TextEdit {
        const doc = self.documents.get(uri) orelse return &[_]TextEdit{};

        if (doc.ast == null) return &[_]TextEdit{};

        // Format the entire document by pretty-printing the AST
        const formatted = try self.formatAST(doc.ast.?);
        defer self.allocator.free(formatted);

        // Return a single edit that replaces the entire document
        const edit = try self.allocator.create(TextEdit);
        edit.* = .{
            .range = Range{
                .start = .{ .line = 0, .character = 0 },
                .end = .{
                    .line = @intCast(std.mem.count(u8, doc.text, "\n")),
                    .character = 0,
                },
            },
            .new_text = formatted,
        };

        return &[_]TextEdit{edit.*};
    }

    pub const TextEdit = struct {
        range: Range,
        new_text: []const u8,
    };

    /// Format AST to pretty-printed source code
    fn formatAST(self: *LanguageServer, program: *ast.Program) ![]const u8 {
        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();

        var indent: usize = 0;

        for (program.statements) |stmt| {
            try self.formatStmt(&buf, &stmt, &indent);
            try buf.append('\n');
        }

        return try self.allocator.dupe(u8, buf.items);
    }

    /// Format a statement
    fn formatStmt(
        self: *LanguageServer,
        buf: *std.ArrayList(u8),
        stmt: *const ast.Stmt,
        indent: *usize,
    ) !void {
        try self.writeIndent(buf, indent.*);

        switch (stmt.*) {
            .FunctionDecl => |func| {
                if (func.is_public) try buf.appendSlice("pub ");
                if (func.is_async) try buf.appendSlice("async ");
                try buf.appendSlice("fn ");
                try buf.appendSlice(func.name);
                try buf.append('(');

                for (func.params, 0..) |param, i| {
                    if (i > 0) try buf.appendSlice(", ");
                    if (param.is_mut) try buf.appendSlice("mut ");
                    try buf.appendSlice(param.name);
                    if (param.type_annotation) |typ| {
                        try buf.appendSlice(": ");
                        try self.formatType(buf, typ);
                    }
                }

                try buf.append(')');

                if (func.return_type) |ret_type| {
                    try buf.appendSlice(" -> ");
                    try self.formatType(buf, ret_type);
                }

                try buf.appendSlice(" {\n");
                indent.* += 1;
                for (func.body.statements) |body_stmt| {
                    try self.formatStmt(buf, &body_stmt, indent);
                    try buf.append('\n');
                }
                indent.* -= 1;
                try self.writeIndent(buf, indent.*);
                try buf.append('}');
            },
            .StructDecl => |struct_decl| {
                if (struct_decl.is_public) try buf.appendSlice("pub ");
                try buf.appendSlice("struct ");
                try buf.appendSlice(struct_decl.name);
                try buf.appendSlice(" {\n");
                indent.* += 1;

                for (struct_decl.fields) |field| {
                    try self.writeIndent(buf, indent.*);
                    if (field.is_public) try buf.appendSlice("pub ");
                    try buf.appendSlice(field.name);
                    try buf.appendSlice(": ");
                    try self.formatType(buf, field.field_type);
                    try buf.appendSlice(",\n");
                }

                indent.* -= 1;
                try self.writeIndent(buf, indent.*);
                try buf.append('}');
            },
            .LetDecl => |let_decl| {
                try buf.appendSlice("let ");
                if (let_decl.is_mut) try buf.appendSlice("mut ");
                try buf.appendSlice(let_decl.name);

                if (let_decl.type_annotation) |typ| {
                    try buf.appendSlice(": ");
                    try self.formatType(buf, typ);
                }

                if (let_decl.initializer) |init| {
                    try buf.appendSlice(" = ");
                    try self.formatExpr(buf, init);
                }

                try buf.append(';');
            },
            .ReturnStmt => |ret_stmt| {
                try buf.appendSlice("return");
                if (ret_stmt.expression) |expr| {
                    try buf.append(' ');
                    try self.formatExpr(buf, expr);
                }
                try buf.append(';');
            },
            .ExprStmt => |expr| {
                try self.formatExpr(buf, expr);
                try buf.append(';');
            },
            else => {
                try buf.appendSlice("// Unsupported statement");
            },
        }
    }

    /// Format a type annotation
    fn formatType(self: *LanguageServer, buf: *std.ArrayList(u8), typ: types.Type) !void {
        _ = self;
        switch (typ) {
            .I32 => try buf.appendSlice("i32"),
            .I64 => try buf.appendSlice("i64"),
            .F32 => try buf.appendSlice("f32"),
            .F64 => try buf.appendSlice("f64"),
            .Bool => try buf.appendSlice("bool"),
            .String => try buf.appendSlice("String"),
            .Struct => |s| try buf.appendSlice(s.name),
            .Enum => |e| try buf.appendSlice(e.name),
            .Array => |arr| {
                try buf.append('[');
                try self.formatType(buf, arr.element_type.*);
                try buf.append(']');
            },
            .Optional => |opt| {
                try self.formatType(buf, opt.*);
                try buf.append('?');
            },
            else => try buf.appendSlice("_"),
        }
    }

    /// Format an expression
    fn formatExpr(self: *LanguageServer, buf: *std.ArrayList(u8), expr: *ast.Expr) !void {
        switch (expr.*) {
            .Identifier => |id| try buf.appendSlice(id.name),
            .IntegerLiteral => |lit| {
                const str = try std.fmt.allocPrint(self.allocator, "{d}", .{lit.value});
                defer self.allocator.free(str);
                try buf.appendSlice(str);
            },
            .BinaryExpr => |bin| {
                try self.formatExpr(buf, bin.left);
                try buf.append(' ');
                try buf.appendSlice(@tagName(bin.operator));
                try buf.append(' ');
                try self.formatExpr(buf, bin.right);
            },
            .CallExpr => |call| {
                try self.formatExpr(buf, call.callee);
                try buf.append('(');
                for (call.arguments, 0..) |arg, i| {
                    if (i > 0) try buf.appendSlice(", ");
                    try self.formatExpr(buf, arg);
                }
                try buf.append(')');
            },
            else => try buf.appendSlice("_"),
        }
    }

    /// Write indentation
    fn writeIndent(self: *LanguageServer, buf: *std.ArrayList(u8), indent: usize) !void {
        _ = self;
        var i: usize = 0;
        while (i < indent) : (i += 1) {
            try buf.appendSlice("    ");
        }
    }

    /// Rename symbol
    pub fn rename(self: *LanguageServer, uri: []const u8, position: Position, new_name: []const u8) ![]TextEdit {
        const doc = self.documents.get(uri) orelse return &[_]TextEdit{};

        // Find the identifier at the cursor position
        const identifier = try self.getIdentifierAtPosition(doc, position) orelse return &[_]TextEdit{};

        // Validate new name
        if (!self.isValidIdentifier(new_name)) {
            return &[_]TextEdit{};
        }

        // Find all references to this identifier
        var locations = std.ArrayList(Location).init(self.allocator);

        if (doc.ast) |program| {
            for (program.statements) |stmt| {
                try self.findReferencesInStmt(&locations, &stmt, identifier, uri);
            }
        }

        // Create text edits for each reference
        var edits = try self.allocator.alloc(TextEdit, locations.items.len);

        for (locations.items, 0..) |loc, i| {
            edits[i] = .{
                .range = loc.range,
                .new_text = try self.allocator.dupe(u8, new_name),
            };
        }

        return edits;
    }

    /// Check if a string is a valid identifier
    fn isValidIdentifier(self: *LanguageServer, name: []const u8) bool {
        _ = self;
        if (name.len == 0) return false;

        // First character must be letter or underscore
        if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') {
            return false;
        }

        // Rest must be alphanumeric or underscore
        for (name[1..]) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_') {
                return false;
            }
        }

        return true;
    }

    /// Get semantic tokens for syntax highlighting
    pub fn getSemanticTokens(self: *LanguageServer, uri: []const u8) ![]SemanticToken {
        const doc = self.documents.get(uri) orelse return &[_]SemanticToken{};

        var tokens = std.ArrayList(SemanticToken).init(self.allocator);

        if (doc.ast) |program| {
            for (program.statements) |stmt| {
                try self.extractSemanticTokensFromStmt(&tokens, &stmt);
            }
        }

        return try tokens.toOwnedSlice();
    }

    pub const SemanticToken = struct {
        line: u32,
        start: u32,
        length: u32,
        token_type: TokenType,
        token_modifiers: u32,
    };

    pub const TokenType = enum(u8) {
        Namespace = 0,
        Type = 1,
        Class = 2,
        Enum = 3,
        Interface = 4,
        Struct = 5,
        TypeParameter = 6,
        Parameter = 7,
        Variable = 8,
        Property = 9,
        EnumMember = 10,
        Function = 11,
        Method = 12,
        Macro = 13,
        Keyword = 14,
        Modifier = 15,
        Comment = 16,
        String = 17,
        Number = 18,
        Operator = 19,
    };

    pub const TokenModifiers = struct {
        pub const Declaration: u32 = 1 << 0;
        pub const Definition: u32 = 1 << 1;
        pub const Readonly: u32 = 1 << 2;
        pub const Static: u32 = 1 << 3;
        pub const Deprecated: u32 = 1 << 4;
        pub const Abstract: u32 = 1 << 5;
        pub const Async: u32 = 1 << 6;
        pub const Modification: u32 = 1 << 7;
        pub const Documentation: u32 = 1 << 8;
        pub const DefaultLibrary: u32 = 1 << 9;
    };

    /// Extract semantic tokens from a statement
    fn extractSemanticTokensFromStmt(
        self: *LanguageServer,
        tokens: *std.ArrayList(SemanticToken),
        stmt: *const ast.Stmt,
    ) !void {
        switch (stmt.*) {
            .FunctionDecl => |func| {
                // Function name
                try tokens.append(.{
                    .line = func.node.loc.line,
                    .start = func.node.loc.column,
                    .length = @intCast(func.name.len),
                    .token_type = .Function,
                    .token_modifiers = TokenModifiers.Declaration |
                        if (func.is_async) TokenModifiers.Async else 0,
                });

                // Parameters
                for (func.params) |param| {
                    try tokens.append(.{
                        .line = param.node.loc.line,
                        .start = param.node.loc.column,
                        .length = @intCast(param.name.len),
                        .token_type = .Parameter,
                        .token_modifiers = if (param.is_mut) TokenModifiers.Modification else 0,
                    });
                }

                // Body
                for (func.body.statements) |body_stmt| {
                    try self.extractSemanticTokensFromStmt(tokens, &body_stmt);
                }
            },
            .StructDecl => |struct_decl| {
                // Struct name
                try tokens.append(.{
                    .line = struct_decl.node.loc.line,
                    .start = struct_decl.node.loc.column,
                    .length = @intCast(struct_decl.name.len),
                    .token_type = .Struct,
                    .token_modifiers = TokenModifiers.Declaration,
                });

                // Fields
                for (struct_decl.fields) |field| {
                    try tokens.append(.{
                        .line = field.node.loc.line,
                        .start = field.node.loc.column,
                        .length = @intCast(field.name.len),
                        .token_type = .Property,
                        .token_modifiers = if (field.is_public) 0 else TokenModifiers.Readonly,
                    });
                }
            },
            .EnumDecl => |enum_decl| {
                // Enum name
                try tokens.append(.{
                    .line = enum_decl.node.loc.line,
                    .start = enum_decl.node.loc.column,
                    .length = @intCast(enum_decl.name.len),
                    .token_type = .Enum,
                    .token_modifiers = TokenModifiers.Declaration,
                });

                // Variants
                for (enum_decl.variants) |variant| {
                    try tokens.append(.{
                        .line = variant.node.loc.line,
                        .start = variant.node.loc.column,
                        .length = @intCast(variant.name.len),
                        .token_type = .EnumMember,
                        .token_modifiers = TokenModifiers.Readonly,
                    });
                }
            },
            .TraitDecl => |trait_decl| {
                // Trait name
                try tokens.append(.{
                    .line = trait_decl.node.loc.line,
                    .start = trait_decl.node.loc.column,
                    .length = @intCast(trait_decl.name.len),
                    .token_type = .Interface,
                    .token_modifiers = TokenModifiers.Declaration | TokenModifiers.Abstract,
                });
            },
            .LetDecl => |let_decl| {
                // Variable name
                try tokens.append(.{
                    .line = let_decl.node.loc.line,
                    .start = let_decl.node.loc.column,
                    .length = @intCast(let_decl.name.len),
                    .token_type = .Variable,
                    .token_modifiers = TokenModifiers.Declaration |
                        if (let_decl.is_mut) TokenModifiers.Modification else TokenModifiers.Readonly,
                });

                // Initializer expression
                if (let_decl.initializer) |init| {
                    try self.extractSemanticTokensFromExpr(tokens, init);
                }
            },
            .ConstDecl => |const_decl| {
                // Constant name
                try tokens.append(.{
                    .line = const_decl.node.loc.line,
                    .start = const_decl.node.loc.column,
                    .length = @intCast(const_decl.name.len),
                    .token_type = .Variable,
                    .token_modifiers = TokenModifiers.Declaration |
                        TokenModifiers.Readonly |
                        TokenModifiers.Static,
                });
            },
            .ReturnStmt => |ret_stmt| {
                if (ret_stmt.expression) |expr| {
                    try self.extractSemanticTokensFromExpr(tokens, expr);
                }
            },
            .ExprStmt => |expr| {
                try self.extractSemanticTokensFromExpr(tokens, expr);
            },
            .IfStmt => |if_stmt| {
                try self.extractSemanticTokensFromExpr(tokens, if_stmt.condition);
                for (if_stmt.then_block.statements) |block_stmt| {
                    try self.extractSemanticTokensFromStmt(tokens, &block_stmt);
                }
                if (if_stmt.else_block) |else_block| {
                    for (else_block.statements) |block_stmt| {
                        try self.extractSemanticTokensFromStmt(tokens, &block_stmt);
                    }
                }
            },
            else => {},
        }
    }

    /// Extract semantic tokens from an expression
    fn extractSemanticTokensFromExpr(
        self: *LanguageServer,
        tokens: *std.ArrayList(SemanticToken),
        expr: *ast.Expr,
    ) !void {
        switch (expr.*) {
            .Identifier => |id| {
                try tokens.append(.{
                    .line = id.node.loc.line,
                    .start = id.node.loc.column,
                    .length = @intCast(id.name.len),
                    .token_type = .Variable,
                    .token_modifiers = 0,
                });
            },
            .IntegerLiteral => |lit| {
                const len = std.fmt.count("{d}", .{lit.value});
                try tokens.append(.{
                    .line = lit.node.loc.line,
                    .start = lit.node.loc.column,
                    .length = @intCast(len),
                    .token_type = .Number,
                    .token_modifiers = 0,
                });
            },
            .StringLiteral => |lit| {
                try tokens.append(.{
                    .line = lit.node.loc.line,
                    .start = lit.node.loc.column,
                    .length = @intCast(lit.value.len + 2), // Include quotes
                    .token_type = .String,
                    .token_modifiers = 0,
                });
            },
            .BinaryExpr => |bin| {
                try self.extractSemanticTokensFromExpr(tokens, bin.left);

                // Operator
                const op_str = @tagName(bin.operator);
                try tokens.append(.{
                    .line = bin.node.loc.line,
                    .start = bin.node.loc.column,
                    .length = @intCast(op_str.len),
                    .token_type = .Operator,
                    .token_modifiers = 0,
                });

                try self.extractSemanticTokensFromExpr(tokens, bin.right);
            },
            .CallExpr => |call| {
                try self.extractSemanticTokensFromExpr(tokens, call.callee);
                for (call.arguments) |arg| {
                    try self.extractSemanticTokensFromExpr(tokens, arg);
                }
            },
            else => {},
        }
    }
};
