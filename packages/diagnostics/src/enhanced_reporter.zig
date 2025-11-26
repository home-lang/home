const std = @import("std");
const ast = @import("ast");
const diagnostics = @import("diagnostics.zig");
const Color = diagnostics.Color;
const Severity = diagnostics.Severity;
const suggestions = @import("suggestions.zig");
const colorizer = @import("colorizer.zig");

/// Enhanced diagnostic reporter with rich error messages
pub const EnhancedReporter = struct {
    allocator: std.mem.Allocator,
    source_files: std.StringHashMap([]const u8),
    use_color: bool = true,
    show_suggestions: bool = true,
    show_context: bool = true,
    context_lines: usize = 2,

    pub const Config = struct {
        use_color: bool = true,
        show_suggestions: bool = true,
        show_context: bool = true,
        context_lines: usize = 2,
    };

    pub const EnhancedDiagnostic = struct {
        severity: Severity,
        code: ?[]const u8 = null, // Error code like "E0308"
        message: []const u8,
        location: ast.SourceLocation,
        labels: []Label,
        notes: [][]const u8 = &.{},
        help: ?[]const u8 = null,
        suggestion: ?Suggestion = null,

        pub const Label = struct {
            location: ast.SourceLocation,
            message: []const u8,
            style: Style = .primary,

            pub const Style = enum {
                primary,
                secondary,
                note,
            };
        };

        pub const Suggestion = struct {
            message: []const u8,
            replacement: ?Replacement = null,

            pub const Replacement = struct {
                location: ast.SourceLocation,
                text: []const u8,
            };
        };

        pub fn deinit(self: *EnhancedDiagnostic, allocator: std.mem.Allocator) void {
            if (self.code) |code| allocator.free(code);
            allocator.free(self.message);
            for (self.labels) |label| {
                allocator.free(label.message);
            }
            allocator.free(self.labels);
            for (self.notes) |note| {
                allocator.free(note);
            }
            allocator.free(self.notes);
            if (self.help) |help| allocator.free(help);
            if (self.suggestion) |*sug| {
                allocator.free(sug.message);
                if (sug.replacement) |repl| {
                    allocator.free(repl.text);
                }
            }
        }
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) EnhancedReporter {
        return .{
            .allocator = allocator,
            .source_files = std.StringHashMap([]const u8).init(allocator),
            .use_color = config.use_color,
            .show_suggestions = config.show_suggestions,
            .show_context = config.show_context,
            .context_lines = config.context_lines,
        };
    }

    pub fn deinit(self: *EnhancedReporter) void {
        var it = self.source_files.valueIterator();
        while (it.next()) |source| {
            self.allocator.free(source.*);
        }
        self.source_files.deinit();
    }

    /// Register source file for better error reporting
    pub fn registerSource(self: *EnhancedReporter, file_path: []const u8, source: []const u8) !void {
        const path_copy = try self.allocator.dupe(u8, file_path);
        errdefer self.allocator.free(path_copy);
        const source_copy = try self.allocator.dupe(u8, source);
        errdefer self.allocator.free(source_copy);

        try self.source_files.put(path_copy, source_copy);
    }

    /// Report an enhanced diagnostic
    pub fn report(self: *EnhancedReporter, diagnostic: EnhancedDiagnostic, file_path: []const u8) !void {
        const writer = std.io.getStdErr().writer();

        // Error header: error[E0308]: message
        if (self.use_color) {
            try writer.writeAll(Color.Bold.code());
            try writer.writeAll(diagnostic.severity.color().code());
        }

        try writer.writeAll(diagnostic.severity.label());

        if (diagnostic.code) |code| {
            try writer.print("[{s}]", .{code});
        }

        try writer.writeAll(": ");

        if (self.use_color) {
            try writer.writeAll(Color.Reset.code());
            try writer.writeAll(Color.Bold.code());
        }

        try writer.print("{s}\n", .{diagnostic.message});

        if (self.use_color) {
            try writer.writeAll(Color.Reset.code());
        }

        // Location: --> file:line:column
        try self.printLocation(writer, file_path, diagnostic.location);

        // Source code snippet with labels
        if (self.show_context) {
            try self.printSourceContext(writer, file_path, diagnostic);
        }

        // Additional notes
        for (diagnostic.notes) |note| {
            try self.printNote(writer, note);
        }

        // Help text
        if (diagnostic.help) |help| {
            try self.printHelp(writer, help);
        }

        // Suggestion with code fix
        if (self.show_suggestions and diagnostic.suggestion != null) {
            try self.printSuggestion(writer, diagnostic.suggestion.?, file_path);
        }

        try writer.writeAll("\n");
    }

    fn printLocation(self: *EnhancedReporter, writer: anytype, file_path: []const u8, location: ast.SourceLocation) !void {
        if (self.use_color) {
            try writer.print("  {s}-->{s} ", .{ Color.Blue.code(), Color.Reset.code() });
        } else {
            try writer.writeAll("  --> ");
        }

        try writer.print("{s}:{d}:{d}\n", .{ file_path, location.line, location.column });
    }

    fn printSourceContext(self: *EnhancedReporter, writer: anytype, file_path: []const u8, diagnostic: EnhancedDiagnostic) !void {
        const source = self.source_files.get(file_path) orelse return;

        // Get the lines we need to display
        var lines = std.mem.splitScalar(u8, source, '\n');
        var current_line: usize = 1;
        var line_contents = std.ArrayList([]const u8).init(self.allocator);
        defer line_contents.deinit();

        while (lines.next()) |line| : (current_line += 1) {
            try line_contents.append(line);
        }

        const primary_line = diagnostic.location.line;
        const start_line = if (primary_line > self.context_lines) primary_line - self.context_lines else 1;
        const end_line = @min(primary_line + self.context_lines, line_contents.items.len);

        // Calculate max line number width for alignment
        const max_line_width = std.fmt.count("{d}", .{end_line});

        // Print gutter
        try self.printGutter(writer, max_line_width);

        // Print context lines
        var line_num = start_line;
        while (line_num <= end_line) : (line_num += 1) {
            const is_primary = line_num == primary_line;
            const line_content = if (line_num <= line_contents.items.len) line_contents.items[line_num - 1] else "";

            // Line number and content
            if (self.use_color) {
                try writer.print(" {s}{d:>[1]}{s} {s}|{s} ", .{
                    Color.Blue.code(),
                    line_num,
                    max_line_width,
                    Color.Reset.code(),
                    if (is_primary) Color.Reset.code() else Color.Dim.code(),
                });
            } else {
                try writer.print(" {d:>[1]} | ", .{ line_num, max_line_width });
            }

            try writer.print("{s}\n", .{line_content});

            // Print caret/underline for primary line
            if (is_primary) {
                try self.printCarets(writer, diagnostic, line_content, max_line_width);
            }

            if (self.use_color) {
                try writer.writeAll(Color.Reset.code());
            }
        }

        // Final gutter
        try self.printGutter(writer, max_line_width);
    }

    fn printGutter(self: *EnhancedReporter, writer: anytype, width: usize) !void {
        if (self.use_color) {
            try writer.print("   {s}", .{Color.Blue.code()});
        } else {
            try writer.writeAll("   ");
        }

        var i: usize = 0;
        while (i < width) : (i += 1) {
            try writer.writeAll(" ");
        }

        if (self.use_color) {
            try writer.print("|{s}\n", .{Color.Reset.code()});
        } else {
            try writer.writeAll("|\n");
        }
    }

    fn printCarets(self: *EnhancedReporter, writer: anytype, diagnostic: EnhancedDiagnostic, line: []const u8, gutter_width: usize) !void {
        const col = diagnostic.location.column;

        // Print spaces before gutter
        try writer.writeAll("   ");
        var i: usize = 0;
        while (i < gutter_width) : (i += 1) {
            try writer.writeAll(" ");
        }
        try writer.writeAll("| ");

        // Print spaces up to error column
        i = 1;
        while (i < col) : (i += 1) {
            if (i < line.len and line[i - 1] == '\t') {
                try writer.writeAll("\t");
            } else {
                try writer.writeAll(" ");
            }
        }

        // Print carets
        if (self.use_color) {
            try writer.print("{s}{s}", .{ Color.Bold.code(), Color.Red.code() });
        }

        // For now, just print a single caret and underline
        // TODO: Support multi-character spans
        try writer.writeAll("^");

        // Determine underline length (default to rest of identifier)
        var underline_len: usize = 1;
        if (col < line.len) {
            var pos = col;
            while (pos < line.len and isIdentifierChar(line[pos])) {
                underline_len += 1;
                pos += 1;
            }
        }

        i = 1;
        while (i < underline_len) : (i += 1) {
            try writer.writeAll("~");
        }

        // Print primary label message
        if (diagnostic.labels.len > 0) {
            const primary_label = diagnostic.labels[0];
            if (primary_label.style == .primary) {
                try writer.print(" {s}", .{primary_label.message});
            }
        }

        if (self.use_color) {
            try writer.writeAll(Color.Reset.code());
        }

        try writer.writeAll("\n");
    }

    fn isIdentifierChar(c: u8) bool {
        return (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '_';
    }

    fn printNote(self: *EnhancedReporter, writer: anytype, note: []const u8) !void {
        if (self.use_color) {
            try writer.print("  {s}note:{s} {s}\n", .{ Color.Cyan.code(), Color.Reset.code(), note });
        } else {
            try writer.print("  note: {s}\n", .{note});
        }
    }

    fn printHelp(self: *EnhancedReporter, writer: anytype, help: []const u8) !void {
        if (self.use_color) {
            try writer.print("  {s}help:{s} {s}\n", .{ Color.Green.code(), Color.Reset.code(), help });
        } else {
            try writer.print("  help: {s}\n", .{help});
        }
    }

    fn printSuggestion(self: *EnhancedReporter, writer: anytype, suggestion: EnhancedDiagnostic.Suggestion, file_path: []const u8) !void {
        if (self.use_color) {
            try writer.print("\n  {s}help:{s} {s}\n", .{ Color.Green.code(), Color.Reset.code(), suggestion.message });
        } else {
            try writer.print("\n  help: {s}\n", .{suggestion.message});
        }

        if (suggestion.replacement) |replacement| {
            // Show the suggested fix
            try self.printLocation(writer, file_path, replacement.location);

            if (self.use_color) {
                try writer.print("   {s}|{s}\n", .{ Color.Blue.code(), Color.Reset.code() });
                try writer.print("   {s}|{s} {s}{s}{s}\n", .{
                    Color.Blue.code(),
                    Color.Reset.code(),
                    Color.Green.code(),
                    replacement.text,
                    Color.Reset.code(),
                });
                try writer.print("   {s}|{s}\n", .{ Color.Blue.code(), Color.Reset.code() });
            } else {
                try writer.writeAll("   |\n");
                try writer.print("   | {s}\n", .{replacement.text});
                try writer.writeAll("   |\n");
            }
        }
    }
};
