const std = @import("std");

/// Documentation generation package
///
/// Provides comprehensive documentation generation with:
/// - HTML and Markdown output
/// - Advanced search indexing with fuzzy matching
/// - Syntax highlighting for code examples
/// - Multiple color schemes
/// - Autocomplete and suggestions
pub const DocParser = @import("parser.zig").DocParser;
pub const HTMLGenerator = @import("html_generator.zig").HTMLGenerator;
pub const MarkdownGenerator = @import("markdown_generator.zig").MarkdownGenerator;
pub const APIReferenceGenerator = @import("markdown_generator.zig").APIReferenceGenerator;
pub const ChangelogGenerator = @import("markdown_generator.zig").ChangelogGenerator;
pub const SearchIndexer = @import("search_indexer.zig").SearchIndexer;
pub const SearchUIGenerator = @import("search_indexer.zig").SearchUIGenerator;
pub const SyntaxHighlighter = @import("syntax_highlighter.zig").SyntaxHighlighter;
pub const CodeBlockHighlighter = @import("syntax_highlighter.zig").CodeBlockHighlighter;

/// Complete documentation generator with all features
pub const DocumentationGenerator = struct {
    allocator: std.mem.Allocator,
    parser: DocParser,
    html_gen: ?HTMLGenerator,
    markdown_gen: ?MarkdownGenerator,
    search_indexer: ?SearchIndexer,
    syntax_highlighter: ?SyntaxHighlighter,

    pub const Config = struct {
        title: []const u8,
        output_dir: []const u8,
        generate_html: bool = true,
        generate_markdown: bool = true,
        enable_search: bool = true,
        enable_syntax_highlighting: bool = true,
        color_scheme: SyntaxHighlighter.ColorScheme = .github_light,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !DocumentationGenerator {
        var html_gen: ?HTMLGenerator = null;
        var markdown_gen: ?MarkdownGenerator = null;
        var search_indexer: ?SearchIndexer = null;
        var syntax_highlighter: ?SyntaxHighlighter = null;

        if (config.generate_html) {
            html_gen = HTMLGenerator.init(allocator, config.output_dir, config.title);
        }

        if (config.generate_markdown) {
            const md_dir = try std.fs.path.join(allocator, &.{ config.output_dir, "markdown" });
            defer allocator.free(md_dir);
            markdown_gen = MarkdownGenerator.init(allocator, md_dir, config.title);
        }

        if (config.enable_search) {
            search_indexer = SearchIndexer.init(allocator);
        }

        if (config.enable_syntax_highlighting) {
            syntax_highlighter = SyntaxHighlighter.init(allocator, .home);
            syntax_highlighter.?.color_scheme = config.color_scheme;
        }

        return .{
            .allocator = allocator,
            .parser = DocParser.init(allocator),
            .html_gen = html_gen,
            .markdown_gen = markdown_gen,
            .search_indexer = search_indexer,
            .syntax_highlighter = syntax_highlighter,
        };
    }

    pub fn deinit(self: *DocumentationGenerator) void {
        self.parser.deinit();
        if (self.search_indexer) |*indexer| {
            indexer.deinit();
        }
    }

    /// Generate complete documentation from source files
    pub fn generateFromFiles(self: *DocumentationGenerator, files: []const []const u8) !void {
        // Parse all files
        var all_items = std.ArrayList(DocParser.DocItem).init(self.allocator);
        defer {
            for (all_items.items) |*item| {
                item.deinit(self.allocator);
            }
            all_items.deinit();
        }

        for (files) |file_path| {
            const items = try self.parser.parseFile(file_path);
            try all_items.appendSlice(items);
        }

        // Generate documentation
        try self.generate(all_items.items);
    }

    /// Generate documentation from parsed items
    pub fn generate(self: *DocumentationGenerator, items: []const DocParser.DocItem) !void {
        // Generate HTML documentation
        if (self.html_gen) |*html_gen| {
            try html_gen.generate(items);
        }

        // Generate Markdown documentation
        if (self.markdown_gen) |*markdown_gen| {
            try markdown_gen.generate(items);
        }

        // Build search index
        if (self.search_indexer) |*indexer| {
            try indexer.buildIndex(items);

            // Export search index to JSON
            const search_json = try indexer.exportToJSON();
            defer self.allocator.free(search_json);

            const output_dir = if (self.html_gen) |gen| gen.output_dir else "";
            const json_path = try std.fs.path.join(self.allocator, &.{ output_dir, "search-index.json" });
            defer self.allocator.free(json_path);

            const json_file = try std.fs.cwd().createFile(json_path, .{});
            defer json_file.close();
            try json_file.writeAll(search_json);

            // Generate enhanced search JavaScript
            var ui_gen = SearchUIGenerator.init(self.allocator);
            const search_js = try ui_gen.generateSearchJS();
            defer self.allocator.free(search_js);

            const js_path = try std.fs.path.join(self.allocator, &.{ output_dir, "search.js" });
            defer self.allocator.free(js_path);

            const js_file = try std.fs.cwd().createFile(js_path, .{});
            defer js_file.close();
            try js_file.writeAll(search_js);
        }

        // Generate syntax highlighting CSS
        if (self.syntax_highlighter) |*highlighter| {
            const css = try highlighter.generateCSS();
            defer self.allocator.free(css);

            const output_dir = if (self.html_gen) |gen| gen.output_dir else "";
            const css_path = try std.fs.path.join(self.allocator, &.{ output_dir, "syntax.css" });
            defer self.allocator.free(css_path);

            const css_file = try std.fs.cwd().createFile(css_path, .{});
            defer css_file.close();
            try css_file.writeAll(css);
        }
    }

    /// Generate API reference document
    pub fn generateAPIReference(self: *DocumentationGenerator, items: []const DocParser.DocItem, title: []const u8) ![]u8 {
        var api_gen = APIReferenceGenerator.init(self.allocator);
        return try api_gen.generateReference(items, title);
    }

    /// Generate changelog document
    pub fn generateChangelog(self: *DocumentationGenerator, items: []const DocParser.DocItem) ![]u8 {
        var changelog_gen = ChangelogGenerator.init(self.allocator);
        return try changelog_gen.generateChangelog(items);
    }
};

test {
    @import("std").testing.refAllDecls(@This());
}
