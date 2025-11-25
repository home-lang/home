const std = @import("std");
const DocParser = @import("parser.zig").DocParser;
const DocItem = DocParser.DocItem;

/// Markdown documentation generator
///
/// Generates markdown documentation suitable for:
/// - GitHub/GitLab README files
/// - Static site generators (Hugo, Jekyll, etc.)
/// - Wiki systems
/// - Developer portals
pub const MarkdownGenerator = struct {
    allocator: std.mem.Allocator,
    output_dir: []const u8,
    title: []const u8,
    include_toc: bool,
    generate_index: bool,

    pub const Config = struct {
        include_toc: bool = true,
        generate_index: bool = true,
        code_style: CodeStyle = .github,

        pub const CodeStyle = enum {
            github, // ```language
            indented, // 4-space indent
            backticks, // `code`
        };
    };

    pub fn init(allocator: std.mem.Allocator, output_dir: []const u8, title: []const u8) MarkdownGenerator {
        return .{
            .allocator = allocator,
            .output_dir = output_dir,
            .title = title,
            .include_toc = true,
            .generate_index = true,
        };
    }

    /// Generate complete documentation site in markdown
    pub fn generate(self: *MarkdownGenerator, items: []const DocItem) !void {
        // Create output directory
        try std.fs.cwd().makePath(self.output_dir);

        // Generate index/README
        if (self.generate_index) {
            try self.generateIndex(items);
        }

        // Generate individual pages for each item
        for (items) |item| {
            try self.generateItemPage(item);
        }

        // Generate summary file
        try self.generateSummary(items);
    }

    fn generateIndex(self: *MarkdownGenerator, items: []const DocItem) !void {
        const path = try std.fs.path.join(self.allocator, &.{ self.output_dir, "README.md" });
        defer self.allocator.free(path);

        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        const writer = file.writer();

        // Title
        try writer.print("# {s}\n\n", .{self.title});

        // Table of Contents
        if (self.include_toc) {
            try writer.writeAll("## Table of Contents\n\n");
            try self.writeTOC(writer, items);
            try writer.writeAll("\n");
        }

        // Group by kind
        try self.writeSection(writer, "## Functions", items, .function);
        try self.writeSection(writer, "## Types", items, .struct_type);
        try self.writeSection(writer, "## Enums", items, .enum_type);
        try self.writeSection(writer, "## Constants", items, .constant);
    }

    fn writeTOC(self: *MarkdownGenerator, writer: anytype, items: []const DocItem) !void {
        _ = self;

        var has_functions = false;
        var has_types = false;
        var has_enums = false;
        var has_constants = false;

        for (items) |item| {
            switch (item.kind) {
                .function => has_functions = true,
                .struct_type => has_types = true,
                .enum_type => has_enums = true,
                .constant => has_constants = true,
                else => {},
            }
        }

        if (has_functions) try writer.writeAll("- [Functions](#functions)\n");
        if (has_types) try writer.writeAll("- [Types](#types)\n");
        if (has_enums) try writer.writeAll("- [Enums](#enums)\n");
        if (has_constants) try writer.writeAll("- [Constants](#constants)\n");
    }

    fn writeSection(
        self: *MarkdownGenerator,
        writer: anytype,
        title: []const u8,
        items: []const DocItem,
        kind: DocItem.ItemKind,
    ) !void {
        _ = self;

        var has_items = false;
        for (items) |item| {
            if (item.kind == kind) {
                has_items = true;
                break;
            }
        }

        if (!has_items) return;

        try writer.print("\n{s}\n\n", .{title});

        for (items) |item| {
            if (item.kind == kind) {
                try writer.print("### [{s}]({s}.md)\n\n", .{ item.name, item.name });
                try writer.print("{s}\n\n", .{item.description});

                if (item.signature) |sig| {
                    try writer.writeAll("```zig\n");
                    try writer.print("{s}\n", .{sig});
                    try writer.writeAll("```\n\n");
                }
            }
        }
    }

    fn generateItemPage(self: *MarkdownGenerator, item: DocItem) !void {
        const filename = try std.fmt.allocPrint(self.allocator, "{s}.md", .{item.name});
        defer self.allocator.free(filename);

        const path = try std.fs.path.join(self.allocator, &.{ self.output_dir, filename });
        defer self.allocator.free(path);

        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        const writer = file.writer();

        // Header
        try writer.print("# {s}\n\n", .{item.name});

        // Breadcrumb navigation
        try writer.writeAll("[← Back to Index](README.md)\n\n");

        // Description
        try writer.print("{s}\n\n", .{item.description});

        // Signature
        if (item.signature) |sig| {
            try writer.writeAll("## Signature\n\n");
            try writer.writeAll("```zig\n");
            try writer.print("{s}\n", .{sig});
            try writer.writeAll("```\n\n");
        }

        // Parameters
        if (item.params.len > 0) {
            try writer.writeAll("## Parameters\n\n");
            for (item.params) |param| {
                try writer.print("- **`{s}`**", .{param.name});
                if (param.type_name) |type_name| {
                    try writer.print(" `{s}`", .{type_name});
                }
                try writer.print(": {s}\n", .{param.description});
            }
            try writer.writeAll("\n");
        }

        // Return value
        if (item.returns) |returns| {
            try writer.writeAll("## Returns\n\n");
            try writer.print("{s}\n\n", .{returns});
        }

        // Examples
        if (item.examples.len > 0) {
            try writer.writeAll("## Examples\n\n");
            for (item.examples) |example| {
                if (example.description) |desc| {
                    try writer.print("{s}\n\n", .{desc});
                }
                try writer.writeAll("```zig\n");
                try writer.print("{s}\n", .{example.code});
                try writer.writeAll("```\n\n");
            }
        }

        // Additional information
        if (item.tags.count() > 0) {
            try writer.writeAll("## Additional Information\n\n");
            var tag_it = item.tags.iterator();
            while (tag_it.next()) |entry| {
                const key = self.formatTagName(entry.key_ptr.*);
                try writer.print("**{s}**: {s}\n\n", .{ key, entry.value_ptr.* });
            }
        }

        // Location
        try writer.writeAll("## Source Location\n\n");
        try writer.print("File: `{s}`\n\n", .{item.location.file});
        try writer.print("Line: {d}\n\n", .{item.location.line});
    }

    fn generateSummary(self: *MarkdownGenerator, items: []const DocItem) !void {
        const path = try std.fs.path.join(self.allocator, &.{ self.output_dir, "SUMMARY.md" });
        defer self.allocator.free(path);

        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        const writer = file.writer();

        try writer.print("# {s}\n\n", .{self.title});

        // Introduction
        try writer.writeAll("- [Introduction](README.md)\n\n");

        // Group by kind
        try self.writeSummarySection(writer, "## Functions\n\n", items, .function);
        try self.writeSummarySection(writer, "## Types\n\n", items, .struct_type);
        try self.writeSummarySection(writer, "## Enums\n\n", items, .enum_type);
        try self.writeSummarySection(writer, "## Constants\n\n", items, .constant);
    }

    fn writeSummarySection(
        self: *MarkdownGenerator,
        writer: anytype,
        title: []const u8,
        items: []const DocItem,
        kind: DocItem.ItemKind,
    ) !void {
        _ = self;

        var has_items = false;
        for (items) |item| {
            if (item.kind == kind) {
                has_items = true;
                break;
            }
        }

        if (!has_items) return;

        try writer.writeAll(title);

        for (items) |item| {
            if (item.kind == kind) {
                try writer.print("- [{s}]({s}.md)\n", .{ item.name, item.name });
            }
        }

        try writer.writeAll("\n");
    }

    fn formatTagName(self: *MarkdownGenerator, tag: []const u8) []const u8 {
        _ = self;
        // Convert tag names to readable format
        if (std.mem.eql(u8, tag, "since")) return "Since";
        if (std.mem.eql(u8, tag, "deprecated")) return "Deprecated";
        if (std.mem.eql(u8, tag, "see")) return "See Also";
        if (std.mem.eql(u8, tag, "note")) return "Note";
        if (std.mem.eql(u8, tag, "warning")) return "Warning";
        if (std.mem.eql(u8, tag, "todo")) return "TODO";
        return tag;
    }
};

/// Generate API reference in markdown format
pub const APIReferenceGenerator = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) APIReferenceGenerator {
        return .{ .allocator = allocator };
    }

    /// Generate a single API reference document
    pub fn generateReference(self: *APIReferenceGenerator, items: []const DocItem, title: []const u8) ![]u8 {
        var buffer = std.ArrayList(u8).init(self.allocator);
        errdefer buffer.deinit();

        const writer = buffer.writer();

        // Title and description
        try writer.print("# {s} API Reference\n\n", .{title});
        try writer.writeAll("This document provides a complete API reference for all public symbols.\n\n");

        // Generate sections by module
        var modules = std.StringHashMap(std.ArrayList(DocItem)).init(self.allocator);
        defer {
            var it = modules.valueIterator();
            while (it.next()) |list| {
                list.deinit();
            }
            modules.deinit();
        }

        // Group by module (extracted from file path)
        for (items) |item| {
            const module_name = try self.extractModuleName(item.location.file);
            var result = try modules.getOrPut(module_name);
            if (!result.found_existing) {
                result.value_ptr.* = std.ArrayList(DocItem).init(self.allocator);
            }
            try result.value_ptr.append(item);
        }

        // Generate documentation for each module
        var module_it = modules.iterator();
        while (module_it.next()) |entry| {
            try writer.print("## Module: {s}\n\n", .{entry.key_ptr.*});

            for (entry.value_ptr.items) |item| {
                try self.writeItemReference(writer, item);
            }
        }

        return buffer.toOwnedSlice();
    }

    fn extractModuleName(self: *APIReferenceGenerator, file_path: []const u8) ![]const u8 {
        _ = self;
        // Extract module name from file path
        // e.g., "/path/to/module/file.zig" -> "module"
        var it = std.mem.splitBackwardsScalar(u8, file_path, '/');
        _ = it.next(); // Skip filename
        if (it.next()) |module| {
            return module;
        }
        return "default";
    }

    fn writeItemReference(self: *APIReferenceGenerator, writer: anytype, item: DocItem) !void {
        _ = self;

        try writer.print("### {s}\n\n", .{item.name});

        if (item.signature) |sig| {
            try writer.writeAll("```zig\n");
            try writer.print("{s}\n", .{sig});
            try writer.writeAll("```\n\n");
        }

        try writer.print("{s}\n\n", .{item.description});

        if (item.params.len > 0) {
            try writer.writeAll("**Parameters:**\n\n");
            for (item.params) |param| {
                try writer.print("- `{s}`", .{param.name});
                if (param.type_name) |type_name| {
                    try writer.print(": `{s}`", .{type_name});
                }
                try writer.print(" - {s}\n", .{param.description});
            }
            try writer.writeAll("\n");
        }

        if (item.returns) |returns| {
            try writer.print("**Returns:** {s}\n\n", .{returns});
        }

        try writer.writeAll("---\n\n");
    }
};

/// Generate changelog-style documentation
pub const ChangelogGenerator = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ChangelogGenerator {
        return .{ .allocator = allocator };
    }

    /// Generate changelog from versioned documentation
    pub fn generateChangelog(self: *ChangelogGenerator, items: []const DocItem) ![]u8 {
        var buffer = std.ArrayList(u8).init(self.allocator);
        errdefer buffer.deinit();

        const writer = buffer.writer();

        try writer.writeAll("# Changelog\n\n");
        try writer.writeAll("All notable changes to this API are documented here.\n\n");

        // Group by version (from @since tags)
        var versions = std.StringHashMap(std.ArrayList(DocItem)).init(self.allocator);
        defer {
            var it = versions.valueIterator();
            while (it.next()) |list| {
                list.deinit();
            }
            versions.deinit();
        }

        for (items) |item| {
            if (item.tags.get("since")) |version| {
                var result = try versions.getOrPut(version);
                if (!result.found_existing) {
                    result.value_ptr.* = std.ArrayList(DocItem).init(self.allocator);
                }
                try result.value_ptr.append(item);
            }
        }

        // Sort versions and generate entries
        var version_list = std.ArrayList([]const u8).init(self.allocator);
        defer version_list.deinit();

        var version_it = versions.keyIterator();
        while (version_it.next()) |version| {
            try version_list.append(version.*);
        }

        // Sort versions in reverse order
        std.mem.sort([]const u8, version_list.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, b, a) == .lt;
            }
        }.lessThan);

        for (version_list.items) |version| {
            try writer.print("## Version {s}\n\n", .{version});

            const version_items = versions.get(version).?;

            // Categorize items
            var added = std.ArrayList(DocItem).init(self.allocator);
            defer added.deinit();
            var deprecated = std.ArrayList(DocItem).init(self.allocator);
            defer deprecated.deinit();

            for (version_items.items) |item| {
                if (item.tags.contains("deprecated")) {
                    try deprecated.append(item);
                } else {
                    try added.append(item);
                }
            }

            if (added.items.len > 0) {
                try writer.writeAll("### Added\n\n");
                for (added.items) |item| {
                    try writer.print("- **{s}**: {s}\n", .{ item.name, item.description });
                }
                try writer.writeAll("\n");
            }

            if (deprecated.items.len > 0) {
                try writer.writeAll("### Deprecated\n\n");
                for (deprecated.items) |item| {
                    try writer.print("- **{s}**: {s}\n", .{ item.name, item.description });
                    if (item.tags.get("deprecated")) |reason| {
                        try writer.print("  - Reason: {s}\n", .{reason});
                    }
                }
                try writer.writeAll("\n");
            }
        }

        return buffer.toOwnedSlice();
    }
};
