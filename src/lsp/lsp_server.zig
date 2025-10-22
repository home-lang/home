const std = @import("std");
const ast = @import("../ast/ast.zig");
const lexer = @import("../lexer/lexer.zig");
const parser = @import("../parser/parser.zig");
const types = @import("../types/type_system.zig");
const diagnostics = @import("../diagnostics/diagnostics.zig");

/// LSP protocol version
pub const LSP_VERSION = "3.17";

/// Language Server Protocol server
pub const LSPServer = struct {
    allocator: std.mem.Allocator,
    workspace: Workspace,
    capabilities: ServerCapabilities,
    running: bool,
    stdin: std.fs.File,
    stdout: std.fs.File,

    pub fn init(allocator: std.mem.Allocator) !LSPServer {
        return .{
            .allocator = allocator,
            .workspace = Workspace.init(allocator),
            .capabilities = ServerCapabilities.full(),
            .running = false,
            .stdin = std.io.getStdIn(),
            .stdout = std.io.getStdOut(),
        };
    }

    pub fn deinit(self: *LSPServer) void {
        self.workspace.deinit();
    }

    /// Start the LSP server
    pub fn run(self: *LSPServer) !void {
        self.running = true;

        var reader = self.stdin.reader();
        var writer = self.stdout.writer();

        while (self.running) {
            // Read LSP message (Content-Length header + JSON body)
            const message = try self.readMessage(reader) orelse break;
            defer self.allocator.free(message);

            // Parse JSON-RPC message
            const request = try self.parseRequest(message);

            // Handle request and send response
            const response = try self.handleRequest(request);
            defer if (response) |r| self.allocator.free(r);

            if (response) |r| {
                try self.sendMessage(writer, r);
            }
        }
    }

    /// Read an LSP message
    fn readMessage(self: *LSPServer, reader: anytype) !?[]const u8 {
        var content_length: usize = 0;

        // Read headers
        var header_buf: [1024]u8 = undefined;
        while (true) {
            const line = try reader.readUntilDelimiter(&header_buf, '\n') catch |err| {
                if (err == error.EndOfStream) return null;
                return err;
            };

            // Remove \r if present
            const trimmed = std.mem.trimRight(u8, line, "\r");

            // Empty line indicates end of headers
            if (trimmed.len == 0) break;

            // Parse Content-Length header
            if (std.mem.startsWith(u8, trimmed, "Content-Length: ")) {
                const length_str = trimmed["Content-Length: ".len..];
                content_length = try std.fmt.parseInt(usize, length_str, 10);
            }
        }

        if (content_length == 0) return error.InvalidMessage;

        // Read content
        const content = try self.allocator.alloc(u8, content_length);
        errdefer self.allocator.free(content);

        try reader.readNoEof(content);

        return content;
    }

    /// Send an LSP message
    fn sendMessage(self: *LSPServer, writer: anytype, content: []const u8) !void {
        _ = self;
        try writer.print("Content-Length: {d}\r\n\r\n{s}", .{ content.len, content });
    }

    /// Parse JSON-RPC request
    fn parseRequest(self: *LSPServer, message: []const u8) !LSPRequest {
        _ = self;
        _ = message;
        // Would use JSON parser here
        return LSPRequest{
            .id = 1,
            .method = "textDocument/completion",
            .params = null,
        };
    }

    /// Handle incoming LSP request
    fn handleRequest(self: *LSPServer, request: LSPRequest) !?[]const u8 {
        if (std.mem.eql(u8, request.method, "initialize")) {
            return try self.handleInitialize(request);
        } else if (std.mem.eql(u8, request.method, "textDocument/didOpen")) {
            try self.handleDidOpen(request);
            return null;
        } else if (std.mem.eql(u8, request.method, "textDocument/didChange")) {
            try self.handleDidChange(request);
            return null;
        } else if (std.mem.eql(u8, request.method, "textDocument/completion")) {
            return try self.handleCompletion(request);
        } else if (std.mem.eql(u8, request.method, "textDocument/hover")) {
            return try self.handleHover(request);
        } else if (std.mem.eql(u8, request.method, "textDocument/definition")) {
            return try self.handleDefinition(request);
        } else if (std.mem.eql(u8, request.method, "textDocument/references")) {
            return try self.handleReferences(request);
        } else if (std.mem.eql(u8, request.method, "textDocument/formatting")) {
            return try self.handleFormatting(request);
        } else if (std.mem.eql(u8, request.method, "shutdown")) {
            return try self.handleShutdown(request);
        } else if (std.mem.eql(u8, request.method, "exit")) {
            self.running = false;
            return null;
        }

        return null;
    }

    fn handleInitialize(self: *LSPServer, request: LSPRequest) ![]const u8 {
        return try std.fmt.allocPrint(
            self.allocator,
            \\{{"jsonrpc":"2.0","id":{d},"result":{{"capabilities":{{
            \\  "textDocumentSync":1,
            \\  "completionProvider":{{"triggerCharacters":["."]}},
            \\  "hoverProvider":true,
            \\  "definitionProvider":true,
            \\  "referencesProvider":true,
            \\  "documentFormattingProvider":true,
            \\  "documentSymbolProvider":true
            \\}}}}}}
        ,
            .{request.id},
        );
    }

    fn handleDidOpen(self: *LSPServer, request: LSPRequest) !void {
        _ = self;
        _ = request;
        // Open document and parse
    }

    fn handleDidChange(self: *LSPServer, request: LSPRequest) !void {
        _ = self;
        _ = request;
        // Update document and reparse
    }

    fn handleCompletion(self: *LSPServer, request: LSPRequest) ![]const u8 {
        _ = self;
        _ = request;
        // Provide completion items
        return try std.fmt.allocPrint(
            self.allocator,
            \\{{"jsonrpc":"2.0","id":{d},"result":[
            \\  {{"label":"let","kind":14}},
            \\  {{"label":"fn","kind":14}},
            \\  {{"label":"struct","kind":14}}
            \\]}}
        ,
            .{request.id},
        );
    }

    fn handleHover(self: *LSPServer, request: LSPRequest) ![]const u8 {
        _ = self;
        _ = request;
        // Provide hover information
        return try std.fmt.allocPrint(
            self.allocator,
            \\{{"jsonrpc":"2.0","id":{d},"result":{{"contents":"Type: int"}}}}
        ,
            .{request.id},
        );
    }

    fn handleDefinition(self: *LSPServer, request: LSPRequest) ![]const u8 {
        _ = self;
        _ = request;
        // Go to definition
        return try std.fmt.allocPrint(
            self.allocator,
            \\{{"jsonrpc":"2.0","id":{d},"result":null}}
        ,
            .{request.id},
        );
    }

    fn handleReferences(self: *LSPServer, request: LSPRequest) ![]const u8 {
        _ = self;
        _ = request;
        // Find references
        return try std.fmt.allocPrint(
            self.allocator,
            \\{{"jsonrpc":"2.0","id":{d},"result":[]}}
        ,
            .{request.id},
        );
    }

    fn handleFormatting(self: *LSPServer, request: LSPRequest) ![]const u8 {
        _ = self;
        _ = request;
        // Format document
        return try std.fmt.allocPrint(
            self.allocator,
            \\{{"jsonrpc":"2.0","id":{d},"result":[]}}
        ,
            .{request.id},
        );
    }

    fn handleShutdown(self: *LSPServer, request: LSPRequest) ![]const u8 {
        return try std.fmt.allocPrint(
            self.allocator,
            \\{{"jsonrpc":"2.0","id":{d},"result":null}}
        ,
            .{request.id},
        );
    }
};

/// LSP request
pub const LSPRequest = struct {
    id: i64,
    method: []const u8,
    params: ?[]const u8,
};

/// Server capabilities
pub const ServerCapabilities = struct {
    text_document_sync: TextDocumentSyncKind,
    completion_provider: bool,
    hover_provider: bool,
    definition_provider: bool,
    references_provider: bool,
    formatting_provider: bool,
    symbol_provider: bool,

    pub fn full() ServerCapabilities {
        return .{
            .text_document_sync = .Full,
            .completion_provider = true,
            .hover_provider = true,
            .definition_provider = true,
            .references_provider = true,
            .formatting_provider = true,
            .symbol_provider = true,
        };
    }
};

pub const TextDocumentSyncKind = enum {
    None,
    Full,
    Incremental,
};

/// Workspace managing open documents
pub const Workspace = struct {
    allocator: std.mem.Allocator,
    documents: std.StringHashMap(*Document),

    pub fn init(allocator: std.mem.Allocator) Workspace {
        return .{
            .allocator = allocator,
            .documents = std.StringHashMap(*Document).init(allocator),
        };
    }

    pub fn deinit(self: *Workspace) void {
        var doc_iter = self.documents.iterator();
        while (doc_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        self.documents.deinit();
    }

    pub fn openDocument(self: *Workspace, uri: []const u8, text: []const u8) !void {
        const doc = try Document.init(self.allocator, uri, text);
        try self.documents.put(uri, doc);
    }

    pub fn closeDocument(self: *Workspace, uri: []const u8) !void {
        if (self.documents.get(uri)) |doc| {
            doc.deinit();
            _ = self.documents.remove(uri);
        }
    }

    pub fn updateDocument(self: *Workspace, uri: []const u8, text: []const u8) !void {
        if (self.documents.getPtr(uri)) |doc_ptr| {
            try doc_ptr.*.update(text);
        }
    }

    pub fn getDocument(self: *Workspace, uri: []const u8) ?*Document {
        return self.documents.get(uri);
    }
};

/// Document in the workspace
pub const Document = struct {
    allocator: std.mem.Allocator,
    uri: []const u8,
    text: []const u8,
    version: i64,
    ast_root: ?*ast.Program,
    diagnostics_list: std.ArrayList(diagnostics.Diagnostic),

    pub fn init(allocator: std.mem.Allocator, uri: []const u8, text: []const u8) !*Document {
        const doc = try allocator.create(Document);
        doc.* = .{
            .allocator = allocator,
            .uri = try allocator.dupe(u8, uri),
            .text = try allocator.dupe(u8, text),
            .version = 0,
            .ast_root = null,
            .diagnostics_list = std.ArrayList(diagnostics.Diagnostic).init(allocator),
        };

        // Parse document
        try doc.parse();

        return doc;
    }

    pub fn deinit(self: *Document) void {
        self.allocator.free(self.uri);
        self.allocator.free(self.text);
        self.diagnostics_list.deinit();
        if (self.ast_root) |root| {
            _ = root;
            // Would free AST
        }
        self.allocator.destroy(self);
    }

    pub fn update(self: *Document, new_text: []const u8) !void {
        self.allocator.free(self.text);
        self.text = try self.allocator.dupe(u8, new_text);
        self.version += 1;

        // Reparse
        try self.parse();
    }

    fn parse(self: *Document) !void {
        // Create lexer and parser
        var lex = lexer.Lexer.init(self.text);
        var tokens = std.ArrayList(lexer.Token).init(self.allocator);
        defer tokens.deinit();

        // Tokenize
        while (true) {
            const token = lex.nextToken();
            try tokens.append(token);
            if (token.type == .Eof) break;
        }

        // Parse (would need to implement)
        // var p = parser.Parser.init(self.allocator, tokens.items);
        // self.ast_root = try p.parse();
    }

    pub fn getDiagnostics(self: *Document) []diagnostics.Diagnostic {
        return self.diagnostics_list.items;
    }
};

/// Symbol information for document symbols
pub const SymbolInformation = struct {
    name: []const u8,
    kind: SymbolKind,
    location: Location,
    container_name: ?[]const u8,
};

pub const SymbolKind = enum(u8) {
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
};

/// Location in a document
pub const Location = struct {
    uri: []const u8,
    range: Range,
};

pub const Range = struct {
    start: Position,
    end: Position,
};

pub const Position = struct {
    line: u32,
    character: u32,
};

/// Completion item
pub const CompletionItem = struct {
    label: []const u8,
    kind: CompletionItemKind,
    detail: ?[]const u8,
    documentation: ?[]const u8,
    insert_text: ?[]const u8,
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
    Unit = 11,
    Value = 12,
    Enum = 13,
    Keyword = 14,
    Snippet = 15,
    Color = 16,
    File = 17,
    Reference = 18,
};
