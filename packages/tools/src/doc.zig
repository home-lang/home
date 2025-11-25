const std = @import("std");
const ast = @import("ast");
const parser = @import("parser");
const lexer = @import("lexer");

/// Home documentation generator
pub const DocGenerator = struct {
    allocator: std.mem.Allocator,
    output_dir: []const u8,
    docs: std.ArrayList(DocItem),

    pub fn init(allocator: std.mem.Allocator, output_dir: []const u8) DocGenerator {
        return .{
            .allocator = allocator,
            .output_dir = output_dir,
            .docs = std.ArrayList(DocItem).init(allocator),
        };
    }

    pub fn deinit(self: *DocGenerator) void {
        for (self.docs.items) |*doc| {
            doc.deinit(self.allocator);
        }
        self.docs.deinit();
    }

    /// Generate documentation for a file
    pub fn generateFile(self: *DocGenerator, file_path: []const u8) !void {
        const file_content = try std.fs.cwd().readFileAlloc(self.allocator, file_path, 10 * 1024 * 1024);
        defer self.allocator.free(file_content);

        var lex = lexer.Lexer.init(self.allocator, file_content);
        defer lex.deinit();

        const tokens = try lex.scanAllTokens();

        var parse = try parser.Parser.init(self.allocator, tokens);
        defer parse.deinit();

        const program = try parse.parse();

        try self.extractDocs(program, file_path);
    }

    /// Extract documentation from AST
    fn extractDocs(self: *DocGenerator, program: *ast.Program, file_path: []const u8) !void {
        for (program.statements) |stmt| {
            try self.extractStatementDocs(stmt, file_path);
        }
    }

    /// Extract documentation from statement
    fn extractStatementDocs(self: *DocGenerator, stmt: ast.Stmt, file_path: []const u8) !void {
        switch (stmt) {
            .FnDecl => |fn_decl| {
                const doc = DocItem{
                    .kind = .Function,
                    .name = try self.allocator.dupe(u8, fn_decl.name),
                    .signature = try self.generateFunctionSignature(fn_decl),
                    .description = try self.extractDocComment(fn_decl.node.loc),
                    .file_path = try self.allocator.dupe(u8, file_path),
                    .loc = fn_decl.node.loc,
                    .params = try self.extractParams(fn_decl),
                    .return_type = if (fn_decl.return_type) |ret| try self.allocator.dupe(u8, ret) else null,
                    .examples = &[_][]const u8{},
                    .is_public = fn_decl.is_public,
                    .is_async = fn_decl.is_async,
                    .generics = if (fn_decl.type_params.len > 0) try self.allocator.dupe([]const u8, fn_decl.type_params) else &[_][]const u8{},
                };
                try self.docs.append(doc);
            },
            .StructDecl => |struct_decl| {
                const doc = DocItem{
                    .kind = .Struct,
                    .name = try self.allocator.dupe(u8, struct_decl.name),
                    .signature = try self.generateStructSignature(struct_decl),
                    .description = try self.allocator.dupe(u8, ""),
                    .file_path = try self.allocator.dupe(u8, file_path),
                    .loc = struct_decl.node.loc,
                    .params = &[_]ParamDoc{},
                    .return_type = null,
                    .examples = &[_][]const u8{},
                    .is_public = true,
                    .is_async = false,
                    .generics = if (struct_decl.type_params.len > 0) try self.allocator.dupe([]const u8, struct_decl.type_params) else &[_][]const u8{},
                };
                try self.docs.append(doc);
            },
            else => {},
        }
    }

    /// Generate function signature
    fn generateFunctionSignature(self: *DocGenerator, fn_decl: *const ast.FnDecl) ![]const u8 {
        var sig = std.ArrayList(u8).init(self.allocator);
        defer sig.deinit();

        const writer = sig.writer();

        if (fn_decl.is_async) {
            try writer.writeAll("async ");
        }

        try writer.writeAll("fn ");
        try writer.writeAll(fn_decl.name);

        // Generic parameters
        if (fn_decl.type_params.len > 0) {
            try writer.writeAll("<");
            for (fn_decl.type_params, 0..) |param, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.writeAll(param);
            }
            try writer.writeAll(">");
        }

        try writer.writeAll("(");
        for (fn_decl.params, 0..) |param, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.writeAll(param.name);
            try writer.writeAll(": ");
            try writer.writeAll(param.type_name);
        }
        try writer.writeAll(")");

        if (fn_decl.return_type) |ret_type| {
            try writer.writeAll(" -> ");
            try writer.writeAll(ret_type);
        }

        return sig.toOwnedSlice();
    }

    /// Generate struct signature
    fn generateStructSignature(self: *DocGenerator, struct_decl: *const ast.StructDecl) ![]const u8 {
        var sig = std.ArrayList(u8).init(self.allocator);
        defer sig.deinit();

        const writer = sig.writer();

        try writer.writeAll("struct ");
        try writer.writeAll(struct_decl.name);

        // Generic parameters
        if (struct_decl.type_params.len > 0) {
            try writer.writeAll("<");
            for (struct_decl.type_params, 0..) |param, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.writeAll(param);
            }
            try writer.writeAll(">");
        }

        return sig.toOwnedSlice();
    }

    /// Extract parameter documentation
    fn extractParams(self: *DocGenerator, fn_decl: *const ast.FnDecl) ![]ParamDoc {
        const params = try self.allocator.alloc(ParamDoc, fn_decl.params.len);

        for (fn_decl.params, 0..) |param, i| {
            params[i] = ParamDoc{
                .name = try self.allocator.dupe(u8, param.name),
                .type_name = try self.allocator.dupe(u8, param.type_name),
                .description = try self.allocator.dupe(u8, ""),
            };
        }

        return params;
    }

    /// Extract documentation comment from source location
    /// Looks for /// comments immediately preceding the declaration
    fn extractDocComment(self: *DocGenerator, loc: ast.SourceLocation) ![]const u8 {
        _ = loc;
        // For now, return empty string
        // Full implementation would scan backwards from loc to find doc comments
        // and extract /// comment text
        return try self.allocator.dupe(u8, "");
    }

    /// Generate HTML documentation
    pub fn generateHTML(self: *DocGenerator) !void {
        // Create output directory
        try std.fs.cwd().makePath(self.output_dir);

        // Generate index
        try self.generateIndexHTML();

        // Generate individual pages
        for (self.docs.items) |doc| {
            try self.generateDocHTML(doc);
        }
    }

    /// Generate index HTML
    fn generateIndexHTML(self: *DocGenerator) !void {
        const index_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.output_dir, "index.html" });
        defer self.allocator.free(index_path);

        const file = try std.fs.cwd().createFile(index_path, .{});
        defer file.close();

        const writer = file.writer();

        try writer.writeAll(
            \\<!DOCTYPE html>
            \\<html>
            \\<head>
            \\  <title>Home Documentation</title>
            \\  <style>
            \\    body { font-family: system-ui; max-width: 1200px; margin: 0 auto; padding: 20px; }
            \\    h1 { color: #7c3aed; }
            \\    .item { border: 1px solid #e5e7eb; padding: 15px; margin: 10px 0; border-radius: 8px; }
            \\    .signature { background: #f3f4f6; padding: 10px; border-radius: 4px; font-family: monospace; }
            \\    .generics { color: #10b981; }
            \\    .async { color: #f59e0b; }
            \\  </style>
            \\</head>
            \\<body>
            \\  <h1>🧬 Home Documentation</h1>
            \\
        );

        // List functions
        try writer.writeAll("  <h2>Functions</h2>\n");
        for (self.docs.items) |doc| {
            if (doc.kind == .Function) {
                try writer.print("  <div class='item'>\n", .{});
                try writer.print("    <h3>{s}</h3>\n", .{doc.name});
                try writer.print("    <div class='signature'>{s}</div>\n", .{doc.signature});
                if (doc.generics.len > 0) {
                    try writer.writeAll("    <p class='generics'>Generic</p>\n");
                }
                if (doc.is_async) {
                    try writer.writeAll("    <p class='async'>Async</p>\n");
                }
                try writer.writeAll("  </div>\n");
            }
        }

        // List structs
        try writer.writeAll("  <h2>Structs</h2>\n");
        for (self.docs.items) |doc| {
            if (doc.kind == .Struct) {
                try writer.print("  <div class='item'>\n", .{});
                try writer.print("    <h3>{s}</h3>\n", .{doc.name});
                try writer.print("    <div class='signature'>{s}</div>\n", .{doc.signature});
                if (doc.generics.len > 0) {
                    try writer.writeAll("    <p class='generics'>Generic</p>\n");
                }
                try writer.writeAll("  </div>\n");
            }
        }

        try writer.writeAll(
            \\</body>
            \\</html>
        );
    }

    /// Generate documentation HTML for a single item
    fn generateDocHTML(self: *DocGenerator, doc: DocItem) !void {
        // Create filename from item name (sanitized)
        var filename = std.ArrayList(u8).init(self.allocator);
        defer filename.deinit();

        try filename.appendSlice(doc.name);
        try filename.appendSlice(".html");

        // Create full path
        var path_buf = std.ArrayList(u8).init(self.allocator);
        defer path_buf.deinit();

        try path_buf.appendSlice(self.output_dir);
        try path_buf.append('/');
        try path_buf.appendSlice(filename.items);

        // Create and write HTML file
        const file = try std.fs.cwd().createFile(path_buf.items, .{});
        defer file.close();

        const writer = file.writer();

        // Write HTML header
        try writer.print(
            \\<!DOCTYPE html>
            \\<html>
            \\<head>
            \\  <meta charset="UTF-8">
            \\  <title>{s} - Home Documentation</title>
            \\  <style>
            \\    body {{ font-family: sans-serif; max-width: 900px; margin: 0 auto; padding: 20px; }}
            \\    .signature {{ background: #f0f0f0; padding: 10px; border-radius: 5px; }}
            \\    .params {{ margin-top: 20px; }}
            \\    .param {{ margin: 10px 0; }}
            \\  </style>
            \\</head>
            \\<body>
            \\  <h1>{s}</h1>
            \\  <div class="signature"><code>{s}</code></div>
            \\
        , .{ doc.name, doc.name, doc.signature });

        // Write description
        if (doc.description.len > 0) {
            try writer.print("  <p>{s}</p>\n", .{doc.description});
        }

        // Write parameters
        if (doc.params.len > 0) {
            try writer.writeAll("  <div class=\"params\"><h3>Parameters:</h3>\n");
            for (doc.params) |param| {
                try writer.print("    <div class=\"param\"><b>{s}</b>: {s}", .{ param.name, param.type_name });
                if (param.description.len > 0) {
                    try writer.print(" - {s}", .{param.description});
                }
                try writer.writeAll("</div>\n");
            }
            try writer.writeAll("  </div>\n");
        }

        // Write return type
        if (doc.return_type) |ret_type| {
            try writer.print("  <p><b>Returns:</b> {s}</p>\n", .{ret_type});
        }

        // Write footer
        try writer.writeAll(
            \\</body>
            \\</html>
            \\
        );
    }
};

pub const DocItem = struct {
    kind: DocKind,
    name: []const u8,
    signature: []const u8,
    description: []const u8,
    file_path: []const u8,
    loc: ast.SourceLocation,
    params: []ParamDoc,
    return_type: ?[]const u8,
    examples: [][]const u8,
    is_public: bool,
    is_async: bool,
    generics: [][]const u8,

    pub fn deinit(self: *DocItem, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.signature);
        allocator.free(self.description);
        allocator.free(self.file_path);

        for (self.params) |*param| {
            allocator.free(param.name);
            allocator.free(param.type_name);
            allocator.free(param.description);
        }
        if (self.params.len > 0) allocator.free(self.params);

        if (self.return_type) |ret| allocator.free(ret);

        for (self.examples) |example| {
            allocator.free(example);
        }
        if (self.examples.len > 0) allocator.free(self.examples);

        if (self.generics.len > 0) allocator.free(self.generics);
    }
};

pub const ParamDoc = struct {
    name: []const u8,
    type_name: []const u8,
    description: []const u8,
};

pub const DocKind = enum {
    Function,
    Struct,
    Enum,
    Trait,
    Module,
    Constant,
};
