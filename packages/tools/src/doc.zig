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
                    .description = if (fn_decl.doc_comment) |doc| try self.parseDocComment(doc) else try self.allocator.dupe(u8, ""),
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
                    .description = if (struct_decl.doc_comment) |doc| try self.parseDocComment(doc) else try self.allocator.dupe(u8, ""),
                    .file_path = try self.allocator.dupe(u8, file_path),
                    .loc = struct_decl.node.loc,
                    .params = &[_]ParamDoc{},
                    .return_type = null,
                    .examples = &[_][]const u8{},
                    .is_public = struct_decl.is_public,
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

    /// Parse a documentation comment, removing /// prefix and cleaning up formatting
    /// Handles multiple consecutive /// lines and combines them into a single description
    fn parseDocComment(self: *DocGenerator, doc_comment: []const u8) ![]const u8 {
        var result = std.ArrayList(u8).init(self.allocator);
        defer result.deinit();

        // Split by newlines and process each line
        var lines = std.mem.splitSequence(u8, doc_comment, "\n");
        var first_line = true;

        while (lines.next()) |line| {
            var trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);

            // Remove /// prefix
            if (std.mem.startsWith(u8, trimmed, "///")) {
                trimmed = trimmed[3..];
                // Remove one space after /// if present
                if (trimmed.len > 0 and trimmed[0] == ' ') {
                    trimmed = trimmed[1..];
                }
            }

            // Skip empty lines at the start
            if (first_line and trimmed.len == 0) {
                continue;
            }

            if (!first_line) {
                try result.append('\n');
            }

            try result.appendSlice(trimmed);
            first_line = false;
        }

        return result.toOwnedSlice();
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
                try writer.print("    <h3><a href='{s}.html'>{s}</a>", .{ doc.name, doc.name });
                if (!doc.is_public) {
                    try writer.writeAll(" <span style='color: #6b7280; font-size: 0.9em;'>(private)</span>");
                }
                try writer.writeAll("</h3>\n");
                try writer.print("    <div class='signature'>{s}</div>\n", .{doc.signature});
                if (doc.description.len > 0) {
                    // Show first line of description
                    var first_line_end = std.mem.indexOfScalar(u8, doc.description, '\n') orelse doc.description.len;
                    if (first_line_end > 100) first_line_end = 100;
                    try writer.print("    <p>{s}", .{doc.description[0..first_line_end]});
                    if (first_line_end < doc.description.len) {
                        try writer.writeAll("...");
                    }
                    try writer.writeAll("</p>\n");
                }
                var badges = std.ArrayList(u8).init(self.allocator);
                defer badges.deinit();
                if (doc.generics.len > 0) {
                    try badges.appendSlice(" <span class='generics'>Generic</span>");
                }
                if (doc.is_async) {
                    try badges.appendSlice(" <span class='async'>Async</span>");
                }
                if (badges.items.len > 0) {
                    try writer.print("    <div>{s}</div>\n", .{badges.items});
                }
                try writer.writeAll("  </div>\n");
            }
        }

        // List structs
        try writer.writeAll("  <h2>Structs</h2>\n");
        for (self.docs.items) |doc| {
            if (doc.kind == .Struct) {
                try writer.print("  <div class='item'>\n", .{});
                try writer.print("    <h3><a href='{s}.html'>{s}</a>", .{ doc.name, doc.name });
                if (!doc.is_public) {
                    try writer.writeAll(" <span style='color: #6b7280; font-size: 0.9em;'>(private)</span>");
                }
                try writer.writeAll("</h3>\n");
                try writer.print("    <div class='signature'>{s}</div>\n", .{doc.signature});
                if (doc.description.len > 0) {
                    // Show first line of description
                    var first_line_end = std.mem.indexOfScalar(u8, doc.description, '\n') orelse doc.description.len;
                    if (first_line_end > 100) first_line_end = 100;
                    try writer.print("    <p>{s}", .{doc.description[0..first_line_end]});
                    if (first_line_end < doc.description.len) {
                        try writer.writeAll("...");
                    }
                    try writer.writeAll("</p>\n");
                }
                if (doc.generics.len > 0) {
                    try writer.writeAll("    <div><span class='generics'>Generic</span></div>\n");
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
            \\    body {{ font-family: system-ui, -apple-system, sans-serif; max-width: 900px; margin: 0 auto; padding: 20px; background: #fafafa; }}
            \\    .header {{ display: flex; justify-content: space-between; align-items: center; margin-bottom: 30px; }}
            \\    .back-link {{ color: #7c3aed; text-decoration: none; }}
            \\    .back-link:hover {{ text-decoration: underline; }}
            \\    h1 {{ color: #1f2937; margin: 0; }}
            \\    .visibility {{ color: #6b7280; font-size: 0.9em; font-weight: normal; }}
            \\    .signature {{ background: #f3f4f6; padding: 15px; border-radius: 8px; font-family: 'Monaco', 'Courier New', monospace; border: 1px solid #e5e7eb; overflow-x: auto; }}
            \\    .description {{ margin: 20px 0; line-height: 1.6; color: #374151; }}
            \\    .section {{ margin: 30px 0; }}
            \\    .section h3 {{ color: #4b5563; border-bottom: 2px solid #e5e7eb; padding-bottom: 8px; }}
            \\    .params {{ margin-top: 20px; }}
            \\    .param {{ margin: 15px 0; padding: 12px; background: white; border-radius: 6px; border-left: 3px solid #7c3aed; }}
            \\    .param-name {{ font-weight: 600; color: #7c3aed; }}
            \\    .param-type {{ color: #059669; font-family: monospace; }}
            \\    .badges {{ margin: 15px 0; }}
            \\    .badge {{ display: inline-block; padding: 4px 12px; border-radius: 12px; font-size: 0.85em; margin-right: 8px; }}
            \\    .badge-generic {{ background: #d1fae5; color: #065f46; }}
            \\    .badge-async {{ background: #fef3c7; color: #92400e; }}
            \\    .badge-public {{ background: #dbeafe; color: #1e40af; }}
            \\    .badge-private {{ background: #e5e7eb; color: #374151; }}
            \\  </style>
            \\</head>
            \\<body>
            \\  <div class="header">
            \\    <h1>{s} <span class="visibility">({s})</span></h1>
            \\    <a href="index.html" class="back-link">← Back to Index</a>
            \\  </div>
            \\  <div class="signature"><code>{s}</code></div>
            \\
        , .{ doc.name, if (doc.is_public) "public" else "private", doc.signature });

        // Write badges
        if (doc.generics.len > 0 or doc.is_async or doc.is_public) {
            try writer.writeAll("  <div class=\"badges\">\n");
            if (doc.is_public) {
                try writer.writeAll("    <span class=\"badge badge-public\">Public</span>\n");
            } else {
                try writer.writeAll("    <span class=\"badge badge-private\">Private</span>\n");
            }
            if (doc.generics.len > 0) {
                try writer.writeAll("    <span class=\"badge badge-generic\">Generic</span>\n");
            }
            if (doc.is_async) {
                try writer.writeAll("    <span class=\"badge badge-async\">Async</span>\n");
            }
            try writer.writeAll("  </div>\n");
        }

        // Write description
        if (doc.description.len > 0) {
            try writer.print("  <div class=\"description\">{s}</div>\n", .{doc.description});
        }

        // Write parameters
        if (doc.params.len > 0) {
            try writer.writeAll("  <div class=\"section\">\n");
            try writer.writeAll("    <h3>Parameters</h3>\n");
            try writer.writeAll("    <div class=\"params\">\n");
            for (doc.params) |param| {
                try writer.writeAll("      <div class=\"param\">\n");
                try writer.print("        <span class=\"param-name\">{s}</span>: <span class=\"param-type\">{s}</span>", .{ param.name, param.type_name });
                if (param.description.len > 0) {
                    try writer.print("<br>{s}", .{param.description});
                }
                try writer.writeAll("\n      </div>\n");
            }
            try writer.writeAll("    </div>\n");
            try writer.writeAll("  </div>\n");
        }

        // Write return type
        if (doc.return_type) |ret_type| {
            try writer.writeAll("  <div class=\"section\">\n");
            try writer.writeAll("    <h3>Returns</h3>\n");
            try writer.print("    <div class=\"param-type\">{s}</div>\n", .{ret_type});
            try writer.writeAll("  </div>\n");
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
