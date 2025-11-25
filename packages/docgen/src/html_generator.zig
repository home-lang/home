const std = @import("std");
const DocParser = @import("parser.zig").DocParser;
const DocItem = DocParser.DocItem;

/// HTML documentation generator
///
/// Generates static HTML documentation with:
/// - Navigation sidebar
/// - Search functionality
/// - Syntax highlighting
/// - Responsive design
/// - Dark/light mode support
pub const HTMLGenerator = struct {
    allocator: std.mem.Allocator,
    output_dir: []const u8,
    title: []const u8,
    theme: Theme,

    pub const Theme = enum {
        light,
        dark,
        auto,
    };

    pub fn init(allocator: std.mem.Allocator, output_dir: []const u8, title: []const u8) HTMLGenerator {
        return .{
            .allocator = allocator,
            .output_dir = output_dir,
            .title = title,
            .theme = .auto,
        };
    }

    /// Generate complete documentation site
    pub fn generate(self: *HTMLGenerator, items: []const DocItem) !void {
        // Create output directory
        try std.fs.cwd().makePath(self.output_dir);

        // Generate index page
        try self.generateIndex(items);

        // Generate individual pages
        for (items) |item| {
            try self.generateItemPage(item, items);
        }

        // Generate search index
        try self.generateSearchIndex(items);

        // Copy static assets
        try self.copyAssets();
    }

    fn generateIndex(self: *HTMLGenerator, items: []const DocItem) !void {
        const path = try std.fs.path.join(self.allocator, &.{ self.output_dir, "index.html" });
        defer self.allocator.free(path);

        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        const writer = file.writer();

        try self.writeHeader(writer, "Home", null);

        try writer.writeAll("<main>\n");
        try writer.print("<h1>{s}</h1>\n", .{self.title});

        // Group by kind
        try self.writeSection(writer, "Functions", items, .function);
        try self.writeSection(writer, "Types", items, .struct_type);
        try self.writeSection(writer, "Enums", items, .enum_type);

        try writer.writeAll("</main>\n");
        try self.writeFooter(writer);
    }

    fn writeSection(
        self: *HTMLGenerator,
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

        try writer.print("<section>\n<h2>{s}</h2>\n<ul class=\"item-list\">\n", .{title});

        for (items) |item| {
            if (item.kind == kind) {
                try writer.print(
                    \\<li>
                    \\  <a href="{s}.html">{s}</a>
                    \\  <p>{s}</p>
                    \\</li>
                    \\
                , .{ item.name, item.name, item.description });
            }
        }

        try writer.writeAll("</ul>\n</section>\n");
    }

    fn generateItemPage(self: *HTMLGenerator, item: DocItem, all_items: []const DocItem) !void {
        _ = all_items;

        const filename = try std.fmt.allocPrint(self.allocator, "{s}.html", .{item.name});
        defer self.allocator.free(filename);

        const path = try std.fs.path.join(self.allocator, &.{ self.output_dir, filename });
        defer self.allocator.free(path);

        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        const writer = file.writer();

        try self.writeHeader(writer, item.name, item.signature);

        try writer.writeAll("<main>\n");
        try writer.print("<h1>{s}</h1>\n", .{item.name});

        if (item.signature) |sig| {
            try writer.print("<pre class=\"signature\"><code>{s}</code></pre>\n", .{sig});
        }

        try writer.print("<div class=\"description\">{s}</div>\n", .{item.description});

        // Parameters
        if (item.params.len > 0) {
            try writer.writeAll("<h2>Parameters</h2>\n<dl class=\"params\">\n");
            for (item.params) |param| {
                try writer.print("<dt><code>{s}</code>", .{param.name});
                if (param.type_name) |type_name| {
                    try writer.print(": <span class=\"type\">{s}</span>", .{type_name});
                }
                try writer.writeAll("</dt>\n");
                try writer.print("<dd>{s}</dd>\n", .{param.description});
            }
            try writer.writeAll("</dl>\n");
        }

        // Return value
        if (item.returns) |returns| {
            try writer.writeAll("<h2>Returns</h2>\n");
            try writer.print("<p>{s}</p>\n", .{returns});
        }

        // Examples
        if (item.examples.len > 0) {
            try writer.writeAll("<h2>Examples</h2>\n");
            for (item.examples) |example| {
                if (example.description) |desc| {
                    try writer.print("<p>{s}</p>\n", .{desc});
                }
                try writer.print("<pre><code class=\"language-home\">{s}</code></pre>\n", .{example.code});
            }
        }

        // Tags
        if (item.tags.count() > 0) {
            try writer.writeAll("<h2>Additional Information</h2>\n<dl>\n");
            var tag_it = item.tags.iterator();
            while (tag_it.next()) |entry| {
                try writer.print("<dt>{s}</dt>\n<dd>{s}</dd>\n", .{ entry.key_ptr.*, entry.value_ptr.* });
            }
            try writer.writeAll("</dl>\n");
        }

        try writer.writeAll("</main>\n");
        try self.writeFooter(writer);
    }

    fn writeHeader(self: *HTMLGenerator, writer: anytype, page_title: []const u8, subtitle: ?[]const u8) !void {
        try writer.writeAll(
            \\<!DOCTYPE html>
            \\<html lang="en">
            \\<head>
            \\  <meta charset="UTF-8">
            \\  <meta name="viewport" content="width=device-width, initial-scale=1.0">
            \\
        );
        try writer.print("  <title>{s} - {s}</title>\n", .{ page_title, self.title });
        try writer.writeAll(
            \\  <link rel="stylesheet" href="style.css">
            \\  <script src="search.js" defer></script>
            \\</head>
            \\<body>
            \\<nav class="sidebar">
            \\  <div class="logo">
            \\
        );
        try writer.print("    <h1>{s}</h1>\n", .{self.title});
        try writer.writeAll(
            \\  </div>
            \\  <input type="search" id="search" placeholder="Search...">
            \\  <div id="search-results"></div>
            \\</nav>
            \\<div class="content">
            \\
        );

        if (subtitle) |sub| {
            try writer.print("<div class=\"subtitle\">{s}</div>\n", .{sub});
        }
    }

    fn writeFooter(self: *HTMLGenerator, writer: anytype) !void {
        _ = self;
        try writer.writeAll(
            \\</div>
            \\</body>
            \\</html>
            \\
        );
    }

    fn generateSearchIndex(self: *HTMLGenerator, items: []const DocItem) !void {
        const path = try std.fs.path.join(self.allocator, &.{ self.output_dir, "search-index.json" });
        defer self.allocator.free(path);

        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        const writer = file.writer();

        try writer.writeAll("[\n");
        for (items, 0..) |item, i| {
            if (i > 0) try writer.writeAll(",\n");
            try writer.writeAll("  {\n");
            try writer.print("    \"name\": \"{s}\",\n", .{item.name});
            try writer.print("    \"kind\": \"{s}\",\n", .{@tagName(item.kind)});
            try writer.print("    \"description\": \"{s}\",\n", .{self.escapeJSON(item.description)});
            try writer.print("    \"url\": \"{s}.html\"\n", .{item.name});
            try writer.writeAll("  }");
        }
        try writer.writeAll("\n]\n");
    }

    fn escapeJSON(self: *HTMLGenerator, str: []const u8) []const u8 {
        _ = self;
        // Simple escape - in production would handle all JSON special chars
        return str;
    }

    fn copyAssets(self: *HTMLGenerator) !void {
        // Copy CSS
        try self.writeCSS();
        // Copy JavaScript
        try self.writeJS();
    }

    fn writeCSS(self: *HTMLGenerator) !void {
        const path = try std.fs.path.join(self.allocator, &.{ self.output_dir, "style.css" });
        defer self.allocator.free(path);

        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        try file.writeAll(
            \\:root {
            \\  --bg-color: #ffffff;
            \\  --text-color: #24292e;
            \\  --sidebar-bg: #f6f8fa;
            \\  --border-color: #e1e4e8;
            \\  --link-color: #0366d6;
            \\  --code-bg: #f6f8fa;
            \\}
            \\
            \\@media (prefers-color-scheme: dark) {
            \\  :root {
            \\    --bg-color: #0d1117;
            \\    --text-color: #c9d1d9;
            \\    --sidebar-bg: #161b22;
            \\    --border-color: #30363d;
            \\    --link-color: #58a6ff;
            \\    --code-bg: #161b22;
            \\  }
            \\}
            \\
            \\* {
            \\  margin: 0;
            \\  padding: 0;
            \\  box-sizing: border-box;
            \\}
            \\
            \\body {
            \\  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
            \\  background: var(--bg-color);
            \\  color: var(--text-color);
            \\  display: flex;
            \\  min-height: 100vh;
            \\}
            \\
            \\.sidebar {
            \\  width: 300px;
            \\  background: var(--sidebar-bg);
            \\  border-right: 1px solid var(--border-color);
            \\  padding: 20px;
            \\  position: fixed;
            \\  height: 100vh;
            \\  overflow-y: auto;
            \\}
            \\
            \\.content {
            \\  margin-left: 300px;
            \\  padding: 40px;
            \\  max-width: 900px;
            \\  width: 100%;
            \\}
            \\
            \\h1 { font-size: 2em; margin-bottom: 0.5em; }
            \\h2 { font-size: 1.5em; margin-top: 1.5em; margin-bottom: 0.5em; }
            \\
            \\pre {
            \\  background: var(--code-bg);
            \\  padding: 15px;
            \\  border-radius: 6px;
            \\  overflow-x: auto;
            \\}
            \\
            \\code {
            \\  font-family: "SF Mono", Monaco, monospace;
            \\  font-size: 0.9em;
            \\}
            \\
            \\a {
            \\  color: var(--link-color);
            \\  text-decoration: none;
            \\}
            \\
            \\a:hover {
            \\  text-decoration: underline;
            \\}
            \\
            \\.signature {
            \\  margin: 20px 0;
            \\}
            \\
            \\.params dt {
            \\  font-weight: 600;
            \\  margin-top: 10px;
            \\}
            \\
            \\.params dd {
            \\  margin-left: 20px;
            \\  margin-bottom: 10px;
            \\}
            \\
        );
    }

    fn writeJS(self: *HTMLGenerator) !void {
        const path = try std.fs.path.join(self.allocator, &.{ self.output_dir, "search.js" });
        defer self.allocator.free(path);

        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        try file.writeAll(
            \\let searchIndex = [];
            \\
            \\fetch('search-index.json')
            \\  .then(r => r.json())
            \\  .then(data => {
            \\    searchIndex = data;
            \\    setupSearch();
            \\  });
            \\
            \\function setupSearch() {
            \\  const searchInput = document.getElementById('search');
            \\  const resultsDiv = document.getElementById('search-results');
            \\
            \\  searchInput.addEventListener('input', (e) => {
            \\    const query = e.target.value.toLowerCase();
            \\    if (!query) {
            \\      resultsDiv.innerHTML = '';
            \\      return;
            \\    }
            \\
            \\    const results = searchIndex.filter(item =>
            \\      item.name.toLowerCase().includes(query) ||
            \\      item.description.toLowerCase().includes(query)
            \\    ).slice(0, 10);
            \\
            \\    resultsDiv.innerHTML = results.map(item =>
            \\      `<div class="search-result">
            \\        <a href="${item.url}">
            \\          <strong>${item.name}</strong>
            \\          <span class="kind">${item.kind}</span>
            \\          <p>${item.description.slice(0, 100)}...</p>
            \\        </a>
            \\      </div>`
            \\    ).join('');
            \\  });
            \\}
            \\
        );
    }
};
