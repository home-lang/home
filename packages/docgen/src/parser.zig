const std = @import("std");
const ast = @import("ast");
const lexer = @import("lexer");

/// Documentation comment parser and extractor
///
/// Parses documentation comments from source code and extracts:
/// - Function signatures and descriptions
/// - Parameter documentation
/// - Return value documentation
/// - Examples
/// - See also references
/// - Since/deprecated tags
pub const DocParser = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    docs: std.ArrayList(DocItem),

    pub const DocItem = struct {
        kind: ItemKind,
        name: []const u8,
        signature: ?[]const u8,
        description: []const u8,
        params: []ParamDoc,
        returns: ?[]const u8,
        examples: []Example,
        tags: std.StringHashMap([]const u8),
        location: SourceLocation,

        pub const ItemKind = enum {
            function,
            struct_type,
            enum_type,
            constant,
            module,
            type_alias,
        };

        pub const ParamDoc = struct {
            name: []const u8,
            type_name: ?[]const u8,
            description: []const u8,
        };

        pub const Example = struct {
            description: ?[]const u8,
            code: []const u8,
        };

        pub const SourceLocation = struct {
            file: []const u8,
            line: usize,
            column: usize,
        };
    };

    pub fn init(allocator: std.mem.Allocator, source: []const u8) DocParser {
        return .{
            .allocator = allocator,
            .source = source,
            .docs = std.ArrayList(DocItem).init(allocator),
        };
    }

    pub fn deinit(self: *DocParser) void {
        for (self.docs.items) |*doc| {
            self.allocator.free(doc.name);
            if (doc.signature) |sig| self.allocator.free(sig);
            self.allocator.free(doc.description);
            for (doc.params) |param| {
                self.allocator.free(param.name);
                if (param.type_name) |t| self.allocator.free(t);
                self.allocator.free(param.description);
            }
            self.allocator.free(doc.params);
            if (doc.returns) |ret| self.allocator.free(ret);
            for (doc.examples) |example| {
                if (example.description) |desc| self.allocator.free(desc);
                self.allocator.free(example.code);
            }
            self.allocator.free(doc.examples);

            var tag_it = doc.tags.iterator();
            while (tag_it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            doc.tags.deinit();
        }
        self.docs.deinit();
    }

    /// Parse documentation from source code
    pub fn parse(self: *DocParser, program: *ast.Program) !void {
        for (program.statements) |*stmt| {
            try self.parseStatement(stmt, "module");
        }
    }

    fn parseStatement(self: *DocParser, stmt: *ast.Stmt, file: []const u8) !void {
        switch (stmt.*) {
            .FunctionDecl => |*func| {
                if (func.doc_comment) |doc_comment| {
                    const doc_item = try self.parseDocComment(
                        doc_comment,
                        .function,
                        func.name,
                        file,
                        0, // line number
                    );

                    // Add signature
                    var sig_buffer = std.ArrayList(u8).init(self.allocator);
                    const writer = sig_buffer.writer();

                    try writer.print("fn {s}(", .{func.name});
                    for (func.params, 0..) |param, i| {
                        if (i > 0) try writer.writeAll(", ");
                        try writer.print("{s}: {s}", .{ param.name, param.type_annotation });
                    }
                    try writer.writeByte(')');

                    if (func.return_type) |ret| {
                        try writer.print(" -> {s}", .{ret});
                    }

                    doc_item.signature = try sig_buffer.toOwnedSlice();

                    try self.docs.append(doc_item);
                }
            },
            .StructDecl => |*struct_decl| {
                if (struct_decl.doc_comment) |doc_comment| {
                    const doc_item = try self.parseDocComment(
                        doc_comment,
                        .struct_type,
                        struct_decl.name,
                        file,
                        0,
                    );
                    try self.docs.append(doc_item);
                }
            },
            .EnumDecl => |*enum_decl| {
                if (enum_decl.doc_comment) |doc_comment| {
                    const doc_item = try self.parseDocComment(
                        doc_comment,
                        .enum_type,
                        enum_decl.name,
                        file,
                        0,
                    );
                    try self.docs.append(doc_item);
                }
            },
            else => {},
        }
    }

    fn parseDocComment(
        self: *DocParser,
        comment: []const u8,
        kind: DocItem.ItemKind,
        name: []const u8,
        file: []const u8,
        line: usize,
    ) !DocItem {
        var description = std.ArrayList(u8).init(self.allocator);
        var params = std.ArrayList(DocItem.ParamDoc).init(self.allocator);
        var examples = std.ArrayList(DocItem.Example).init(self.allocator);
        var tags = std.StringHashMap([]const u8).init(self.allocator);
        var returns: ?[]const u8 = null;

        var lines = std.mem.splitScalar(u8, comment, '\n');
        var in_example = false;
        var example_buffer = std.ArrayList(u8).init(self.allocator);
        defer example_buffer.deinit();

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r///");

            if (trimmed.len == 0) continue;

            // Check for tags
            if (std.mem.startsWith(u8, trimmed, "@param")) {
                const param = try self.parseParamTag(trimmed);
                try params.append(param);
            } else if (std.mem.startsWith(u8, trimmed, "@return")) {
                returns = try self.allocator.dupe(u8, std.mem.trim(u8, trimmed[7..], " "));
            } else if (std.mem.startsWith(u8, trimmed, "@example")) {
                in_example = true;
                example_buffer.clearRetainingCapacity();
            } else if (std.mem.startsWith(u8, trimmed, "@since") or
                std.mem.startsWith(u8, trimmed, "@deprecated") or
                std.mem.startsWith(u8, trimmed, "@see"))
            {
                const space_idx = std.mem.indexOf(u8, trimmed, " ") orelse continue;
                const tag_name = trimmed[1..space_idx];
                const tag_value = std.mem.trim(u8, trimmed[space_idx + 1 ..], " ");
                try tags.put(
                    try self.allocator.dupe(u8, tag_name),
                    try self.allocator.dupe(u8, tag_value),
                );
            } else if (in_example) {
                if (std.mem.startsWith(u8, trimmed, "@")) {
                    // End of example
                    try examples.append(.{
                        .description = null,
                        .code = try example_buffer.toOwnedSlice(),
                    });
                    in_example = false;
                } else {
                    try example_buffer.appendSlice(trimmed);
                    try example_buffer.append('\n');
                }
            } else {
                // Regular description
                try description.appendSlice(trimmed);
                try description.append(' ');
            }
        }

        // Save any pending example
        if (in_example and example_buffer.items.len > 0) {
            try examples.append(.{
                .description = null,
                .code = try example_buffer.toOwnedSlice(),
            });
        }

        return DocItem{
            .kind = kind,
            .name = try self.allocator.dupe(u8, name),
            .signature = null,
            .description = try description.toOwnedSlice(),
            .params = try params.toOwnedSlice(),
            .returns = returns,
            .examples = try examples.toOwnedSlice(),
            .tags = tags,
            .location = .{
                .file = try self.allocator.dupe(u8, file),
                .line = line,
                .column = 0,
            },
        };
    }

    fn parseParamTag(self: *DocParser, tag: []const u8) !DocItem.ParamDoc {
        // Format: @param name description
        // or: @param name: Type description
        const content = std.mem.trim(u8, tag[6..], " ");

        const space_idx = std.mem.indexOf(u8, content, " ") orelse content.len;
        const param_part = content[0..space_idx];
        const desc_part = if (space_idx < content.len)
            std.mem.trim(u8, content[space_idx + 1 ..], " ")
        else
            "";

        // Check for type annotation
        var param_name: []const u8 = undefined;
        var type_name: ?[]const u8 = null;

        if (std.mem.indexOf(u8, param_part, ":")) |colon_idx| {
            param_name = param_part[0..colon_idx];
            type_name = try self.allocator.dupe(u8, std.mem.trim(u8, param_part[colon_idx + 1 ..], " "));
        } else {
            param_name = param_part;
        }

        return DocItem.ParamDoc{
            .name = try self.allocator.dupe(u8, param_name),
            .type_name = type_name,
            .description = try self.allocator.dupe(u8, desc_part),
        };
    }

    /// Get all documentation items
    pub fn getItems(self: *DocParser) []const DocItem {
        return self.docs.items;
    }

    /// Filter items by kind
    pub fn filterByKind(self: *DocParser, kind: DocItem.ItemKind) ![]DocItem {
        var filtered = std.ArrayList(DocItem).init(self.allocator);
        for (self.docs.items) |item| {
            if (item.kind == kind) {
                try filtered.append(item);
            }
        }
        return try filtered.toOwnedSlice();
    }

    /// Search documentation by name
    pub fn search(self: *DocParser, query: []const u8) ![]DocItem {
        var results = std.ArrayList(DocItem).init(self.allocator);
        for (self.docs.items) |item| {
            if (std.mem.indexOf(u8, item.name, query) != null or
                std.mem.indexOf(u8, item.description, query) != null)
            {
                try results.append(item);
            }
        }
        return try results.toOwnedSlice();
    }
};

/// Module-level documentation extractor
pub const ModuleDoc = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    description: []const u8,
    items: std.ArrayList(DocParser.DocItem),
    submodules: std.ArrayList(*ModuleDoc),

    pub fn init(allocator: std.mem.Allocator, name: []const u8) ModuleDoc {
        return .{
            .allocator = allocator,
            .name = name,
            .description = "",
            .items = std.ArrayList(DocParser.DocItem).init(allocator),
            .submodules = std.ArrayList(*ModuleDoc).init(allocator),
        };
    }

    pub fn deinit(self: *ModuleDoc) void {
        self.allocator.free(self.name);
        self.allocator.free(self.description);
        self.items.deinit();
        for (self.submodules.items) |submod| {
            submod.deinit();
            self.allocator.destroy(submod);
        }
        self.submodules.deinit();
    }

    pub fn addItem(self: *ModuleDoc, item: DocParser.DocItem) !void {
        try self.items.append(item);
    }

    pub fn addSubmodule(self: *ModuleDoc, submod: *ModuleDoc) !void {
        try self.submodules.append(submod);
    }
};

/// Cross-reference resolver for documentation
pub const CrossRefResolver = struct {
    allocator: std.mem.Allocator,
    items: std.StringHashMap(DocParser.DocItem),

    pub fn init(allocator: std.mem.Allocator) CrossRefResolver {
        return .{
            .allocator = allocator,
            .items = std.StringHashMap(DocParser.DocItem).init(allocator),
        };
    }

    pub fn deinit(self: *CrossRefResolver) void {
        self.items.deinit();
    }

    pub fn addItem(self: *CrossRefResolver, item: DocParser.DocItem) !void {
        try self.items.put(item.name, item);
    }

    pub fn resolve(self: *CrossRefResolver, reference: []const u8) ?DocParser.DocItem {
        return self.items.get(reference);
    }

    pub fn resolveAll(self: *CrossRefResolver, doc: []const u8) ![]const u8 {
        // Find and resolve cross-references in markdown format: [name]
        var result = std.ArrayList(u8).init(self.allocator);
        const writer = result.writer();

        var i: usize = 0;
        while (i < doc.len) {
            if (doc[i] == '[') {
                const close = std.mem.indexOfScalarPos(u8, doc, i, ']') orelse {
                    try writer.writeByte(doc[i]);
                    i += 1;
                    continue;
                };

                const ref_name = doc[i + 1 .. close];
                if (self.resolve(ref_name)) |_| {
                    // Create link
                    try writer.print("[{s}](#{s})", .{ ref_name, ref_name });
                    i = close + 1;
                    continue;
                }
            }

            try writer.writeByte(doc[i]);
            i += 1;
        }

        return try result.toOwnedSlice();
    }
};
