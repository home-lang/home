const std = @import("std");
const ast = @import("ast");
const parser_mod = @import("parser");
const lexer_mod = @import("lexer");

/// Language Server Protocol implementation for Ion
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
        // TODO: Type checking, undefined variables, etc.
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

        // TODO: Add symbols from AST (functions, variables, structs, etc.)

        return try items.toOwnedSlice();
    }

    /// Go to definition
    pub fn gotoDefinition(self: *LanguageServer, uri: []const u8, position: Position) !?Location {
        _ = position;

        const doc = self.documents.get(uri) orelse return null;
        _ = doc;

        // TODO: Implement symbol resolution and jump to definition

        return null;
    }

    /// Find references
    pub fn findReferences(self: *LanguageServer, uri: []const u8, position: Position) ![]Location {
        _ = position;

        const doc = self.documents.get(uri) orelse return &[_]Location{};
        _ = doc;

        // TODO: Implement reference finding

        return &[_]Location{};
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
