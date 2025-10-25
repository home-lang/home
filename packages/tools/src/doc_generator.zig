const std = @import("std");
const ast = @import("../ast/ast.zig");
const parser = @import("../parser/parser.zig");
const lexer = @import("../lexer/lexer.zig");

/// Documentation generator for Home code
pub const DocGenerator = struct {
    allocator: std.mem.Allocator,
    output_dir: []const u8,
    format: OutputFormat,
    items: std.ArrayList(DocItem),

    pub const OutputFormat = enum {
        Markdown,
        HTML,
        JSON,
    };

    pub fn init(allocator: std.mem.Allocator, output_dir: []const u8, format: OutputFormat) DocGenerator {
        return .{
            .allocator = allocator,
            .output_dir = output_dir,
            .format = format,
            .items = std.ArrayList(DocItem).init(allocator),
        };
    }

    pub fn deinit(self: *DocGenerator) void {
        for (self.items.items) |*item| {
            item.deinit(self.allocator);
        }
        self.items.deinit();
    }

    /// Generate documentation for a file
    pub fn generateFile(self: *DocGenerator, file_path: []const u8) !void {
        std.debug.print("Documenting: {s}\n", .{file_path});

        // Read source file
        const source = try std.fs.cwd().readFileAlloc(self.allocator, file_path, 10 * 1024 * 1024);
        errdefer self.allocator.free(source);
        defer self.allocator.free(source);

        // Parse file
        var lex = lexer.Lexer.init(source);
        var tokens = std.ArrayList(lexer.Token).init(self.allocator);
        errdefer tokens.deinit();
        defer tokens.deinit();

        while (true) {
            const token = lex.nextToken();
            try tokens.append(token);
            if (token.type == .Eof) break;
        }

        // Extract documentation
        try self.extractDocs(source, file_path);

        // Generate output
        try self.writeOutput();
    }

    /// Extract documentation from source
    fn extractDocs(self: *DocGenerator, source: []const u8, file_path: []const u8) !void {
        var lines = std.mem.split(u8, source, "\n");
        var line_num: usize = 0;
        var current_doc: ?[]const u8 = null;

        while (lines.next()) |line| : (line_num += 1) {
            const trimmed = std.mem.trim(u8, line, " \t");

            // Collect doc comments
            if (std.mem.startsWith(u8, trimmed, "///")) {
                const comment = std.mem.trimLeft(u8, trimmed[3..], " ");
                if (current_doc) |doc| {
                    const new_doc = try std.fmt.allocPrint(
                        self.allocator,
                        "{s}\n{s}",
                        .{ doc, comment },
                    );
                    errdefer self.allocator.free(new_doc);
                    self.allocator.free(doc);
                    current_doc = new_doc;
                } else {
                    const doc = try self.allocator.dupe(u8, comment);
                    errdefer self.allocator.free(doc);
                    current_doc = doc;
                }
                continue;
            }

            // Parse declarations
            if (current_doc) |doc| {
                defer {
                    self.allocator.free(doc);
                    current_doc = null;
                }

                // Function declaration
                if (std.mem.startsWith(u8, trimmed, "fn ") or
                    std.mem.startsWith(u8, trimmed, "pub fn "))
                {
                    try self.extractFunction(trimmed, doc, file_path, line_num);
                }
                // Struct declaration
                else if (std.mem.startsWith(u8, trimmed, "struct ") or
                    std.mem.startsWith(u8, trimmed, "pub struct "))
                {
                    try self.extractStruct(trimmed, doc, file_path, line_num);
                }
                // Trait declaration
                else if (std.mem.startsWith(u8, trimmed, "trait ") or
                    std.mem.startsWith(u8, trimmed, "pub trait "))
                {
                    try self.extractTrait(trimmed, doc, file_path, line_num);
                }
                // Constant declaration
                else if (std.mem.startsWith(u8, trimmed, "const ") or
                    std.mem.startsWith(u8, trimmed, "pub const "))
                {
                    try self.extractConstant(trimmed, doc, file_path, line_num);
                }
            }
        }
    }

    fn extractFunction(self: *DocGenerator, line: []const u8, doc: []const u8, file_path: []const u8, line_num: usize) !void {
        // Parse function signature
        const is_public = std.mem.startsWith(u8, line, "pub ");
        const start = if (is_public) "pub fn ".len else "fn ".len;

        if (std.mem.indexOfScalar(u8, line[start..], '(')) |paren_idx| {
            const name = std.mem.trim(u8, line[start .. start + paren_idx], " ");

            try self.items.append(.{
                .kind = .Function,
                .name = try self.allocator.dupe(u8, name),
                .signature = try self.allocator.dupe(u8, line),
                .doc = try self.allocator.dupe(u8, doc),
                .file_path = try self.allocator.dupe(u8, file_path),
                .line = line_num,
                .is_public = is_public,
            });
        }
    }

    fn extractStruct(self: *DocGenerator, line: []const u8, doc: []const u8, file_path: []const u8, line_num: usize) !void {
        const is_public = std.mem.startsWith(u8, line, "pub ");
        const start = if (is_public) "pub struct ".len else "struct ".len;

        const remaining = line[start..];
        const end = std.mem.indexOfAny(u8, remaining, " {") orelse remaining.len;
        const name = std.mem.trim(u8, remaining[0..end], " ");

        try self.items.append(.{
            .kind = .Struct,
            .name = try self.allocator.dupe(u8, name),
            .signature = try self.allocator.dupe(u8, line),
            .doc = try self.allocator.dupe(u8, doc),
            .file_path = try self.allocator.dupe(u8, file_path),
            .line = line_num,
            .is_public = is_public,
        });
    }

    fn extractTrait(self: *DocGenerator, line: []const u8, doc: []const u8, file_path: []const u8, line_num: usize) !void {
        const is_public = std.mem.startsWith(u8, line, "pub ");
        const start = if (is_public) "pub trait ".len else "trait ".len;

        const remaining = line[start..];
        const end = std.mem.indexOfAny(u8, remaining, " {") orelse remaining.len;
        const name = std.mem.trim(u8, remaining[0..end], " ");

        try self.items.append(.{
            .kind = .Trait,
            .name = try self.allocator.dupe(u8, name),
            .signature = try self.allocator.dupe(u8, line),
            .doc = try self.allocator.dupe(u8, doc),
            .file_path = try self.allocator.dupe(u8, file_path),
            .line = line_num,
            .is_public = is_public,
        });
    }

    fn extractConstant(self: *DocGenerator, line: []const u8, doc: []const u8, file_path: []const u8, line_num: usize) !void {
        const is_public = std.mem.startsWith(u8, line, "pub ");
        const start = if (is_public) "pub const ".len else "const ".len;

        if (std.mem.indexOfScalar(u8, line[start..], '=')) |eq_idx| {
            const name = std.mem.trim(u8, line[start .. start + eq_idx], " :");

            try self.items.append(.{
                .kind = .Constant,
                .name = try self.allocator.dupe(u8, name),
                .signature = try self.allocator.dupe(u8, line),
                .doc = try self.allocator.dupe(u8, doc),
                .file_path = try self.allocator.dupe(u8, file_path),
                .line = line_num,
                .is_public = is_public,
            });
        }
    }

    /// Write documentation output
    fn writeOutput(self: *DocGenerator) !void {
        // Create output directory
        std.fs.cwd().makePath(self.output_dir) catch {};

        switch (self.format) {
            .Markdown => try self.writeMarkdown(),
            .HTML => try self.writeHTML(),
            .JSON => try self.writeJSON(),
        }
    }

    fn writeMarkdown(self: *DocGenerator) !void {
        const output_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.output_dir, "index.md" });
        defer self.allocator.free(output_path);

        const file = try std.fs.cwd().createFile(output_path, .{});
        defer file.close();

        var writer = file.writer();

        try writer.writeAll("# Home Documentation\n\n");

        // Table of contents
        try writer.writeAll("## Table of Contents\n\n");
        for (self.items.items) |item| {
            if (item.is_public) {
                try writer.print("- [{s}](#{s})\n", .{ item.name, item.name });
            }
        }
        try writer.writeAll("\n---\n\n");

        // Detailed documentation
        for (self.items.items) |item| {
            if (!item.is_public) continue;

            try writer.print("## {s}\n\n", .{item.name});
            try writer.print("**Type:** {s}\n\n", .{@tagName(item.kind)});
            try writer.print("**Signature:**\n```home\n{s}\n```\n\n", .{item.signature});
            try writer.print("{s}\n\n", .{item.doc});
            try writer.print("*Defined in {s}:{d}*\n\n", .{ item.file_path, item.line });
            try writer.writeAll("---\n\n");
        }

        std.debug.print("✓ Generated: {s}\n", .{output_path});
    }

    fn writeHTML(self: *DocGenerator) !void {
        const output_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.output_dir, "index.html" });
        defer self.allocator.free(output_path);

        const file = try std.fs.cwd().createFile(output_path, .{});
        defer file.close();

        var writer = file.writer();

        try writer.writeAll(
            \\<!DOCTYPE html>
            \\<html lang="en">
            \\<head>
            \\  <meta charset="UTF-8">
            \\  <meta name="viewport" content="width=device-width, initial-scale=1.0">
            \\  <title>Ion Documentation</title>
            \\  <style>
            \\    body { font-family: system-ui, -apple-system, sans-serif; max-width: 1200px; margin: 0 auto; padding: 2rem; }
            \\    .item { margin: 2rem 0; padding: 1rem; border-left: 4px solid #0066cc; background: #f5f5f5; }
            \\    .signature { background: #1e1e1e; color: #d4d4d4; padding: 1rem; border-radius: 4px; overflow-x: auto; }
            \\    .kind { color: #0066cc; font-weight: bold; }
            \\    .location { color: #666; font-size: 0.9em; }
            \\  </style>
            \\</head>
            \\<body>
            \\  <h1>Ion Documentation</h1>
            \\
        );

        for (self.items.items) |item| {
            if (!item.is_public) continue;

            try writer.writeAll("  <div class=\"item\">\n");
            try writer.print("    <h2>{s}</h2>\n", .{item.name});
            try writer.print("    <div class=\"kind\">{s}</div>\n", .{@tagName(item.kind)});
            try writer.print("    <pre class=\"signature\">{s}</pre>\n", .{item.signature});
            try writer.print("    <p>{s}</p>\n", .{item.doc});
            try writer.print("    <div class=\"location\">Defined in {s}:{d}</div>\n", .{ item.file_path, item.line });
            try writer.writeAll("  </div>\n");
        }

        try writer.writeAll(
            \\</body>
            \\</html>
            \\
        );

        std.debug.print("✓ Generated: {s}\n", .{output_path});
    }

    fn writeJSON(self: *DocGenerator) !void {
        const output_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.output_dir, "docs.json" });
        defer self.allocator.free(output_path);

        const file = try std.fs.cwd().createFile(output_path, .{});
        defer file.close();

        var writer = file.writer();

        try writer.writeAll("{\n  \"items\": [\n");

        for (self.items.items, 0..) |item, i| {
            if (!item.is_public) continue;

            try writer.writeAll("    {\n");
            try writer.print("      \"name\": \"{s}\",\n", .{item.name});
            try writer.print("      \"kind\": \"{s}\",\n", .{@tagName(item.kind)});
            try writer.print("      \"signature\": \"{s}\",\n", .{item.signature});
            try writer.print("      \"doc\": \"{s}\",\n", .{item.doc});
            try writer.print("      \"file\": \"{s}\",\n", .{item.file_path});
            try writer.print("      \"line\": {d}\n", .{item.line});
            try writer.writeAll("    }");

            if (i < self.items.items.len - 1) {
                try writer.writeAll(",\n");
            } else {
                try writer.writeAll("\n");
            }
        }

        try writer.writeAll("  ]\n}\n");

        std.debug.print("✓ Generated: {s}\n", .{output_path});
    }
};

pub const DocItem = struct {
    kind: DocItemKind,
    name: []const u8,
    signature: []const u8,
    doc: []const u8,
    file_path: []const u8,
    line: usize,
    is_public: bool,

    pub fn deinit(self: *DocItem, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.signature);
        allocator.free(self.doc);
        allocator.free(self.file_path);
    }
};

pub const DocItemKind = enum {
    Function,
    Struct,
    Trait,
    Constant,
    Module,
    Enum,
};
