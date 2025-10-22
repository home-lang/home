const std = @import("std");
pub const ast = @import("ast");

/// Color codes for terminal output
pub const Color = enum {
    Reset,
    Red,
    Green,
    Yellow,
    Blue,
    Magenta,
    Cyan,
    Bold,
    Dim,

    pub fn code(self: Color) []const u8 {
        return switch (self) {
            .Reset => "\x1b[0m",
            .Red => "\x1b[31m",
            .Green => "\x1b[32m",
            .Yellow => "\x1b[33m",
            .Blue => "\x1b[34m",
            .Magenta => "\x1b[35m",
            .Cyan => "\x1b[36m",
            .Bold => "\x1b[1m",
            .Dim => "\x1b[2m",
        };
    }
};

/// Severity level of diagnostic messages
pub const Severity = enum {
    Error,
    Warning,
    Info,
    Hint,

    pub fn color(self: Severity) Color {
        return switch (self) {
            .Error => .Red,
            .Warning => .Yellow,
            .Info => .Blue,
            .Hint => .Cyan,
        };
    }

    pub fn label(self: Severity) []const u8 {
        return switch (self) {
            .Error => "error",
            .Warning => "warning",
            .Info => "info",
            .Hint => "hint",
        };
    }
};

/// A diagnostic message with location and context
pub const Diagnostic = struct {
    severity: Severity,
    message: []const u8,
    location: ast.SourceLocation,
    source_line: ?[]const u8,
    suggestion: ?[]const u8,

    pub fn format(
        self: Diagnostic,
        file_path: []const u8,
    ) void {
        // Error header: error: message
        std.debug.print("{s}{s}{s}{s}:{s} {s}\n", .{
            Color.Bold.code(),
            self.severity.color().code(),
            self.severity.label(),
            Color.Reset.code(),
            Color.Bold.code(),
            self.message,
        });
        std.debug.print("{s}\n", .{Color.Reset.code()});

        // Location: --> file:line:column
        std.debug.print("  {s}-->{s} {s}:{d}:{d}\n", .{
            Color.Blue.code(),
            Color.Reset.code(),
            file_path,
            self.location.line,
            self.location.column,
        });

        // Source code snippet with line numbers
        if (self.source_line) |source| {
            const line_num = self.location.line;
            const col_num = self.location.column;

            // Line number gutter
            std.debug.print("   {s}|{s}\n", .{ Color.Blue.code(), Color.Reset.code() });

            // Actual source line with line number
            std.debug.print(" {s}{d:3}{s} {s}|{s} {s}\n", .{
                Color.Blue.code(),
                line_num,
                Color.Reset.code(),
                Color.Blue.code(),
                Color.Reset.code(),
                source,
            });

            // Underline/caret pointing to error location
            std.debug.print("   {s}|{s} ", .{ Color.Blue.code(), Color.Reset.code() });

            // Add spaces up to the column
            var i: usize = 0;
            while (i < col_num) : (i += 1) {
                std.debug.print(" ", .{});
            }

            // Add caret
            std.debug.print("{s}^{s}\n", .{
                self.severity.color().code(),
                Color.Reset.code(),
            });
        }

        // Suggestion if available
        if (self.suggestion) |suggestion| {
            std.debug.print("   {s}|{s}\n", .{ Color.Blue.code(), Color.Reset.code() });
            std.debug.print("   {s}={s} {s}help:{s} {s}\n", .{
                Color.Cyan.code(),
                Color.Reset.code(),
                Color.Bold.code(),
                Color.Reset.code(),
                suggestion,
            });
        }

        std.debug.print("\n", .{});
    }
};

/// Diagnostic reporter for collecting and displaying diagnostics
pub const DiagnosticReporter = struct {
    allocator: std.mem.Allocator,
    diagnostics: std.ArrayList(Diagnostic),
    source_lines: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) DiagnosticReporter {
        return .{
            .allocator = allocator,
            .diagnostics = .{ .items = &.{}, .capacity = 0 },
            .source_lines = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *DiagnosticReporter) void {
        for (self.diagnostics.items) |diag| {
            self.allocator.free(diag.message);
            if (diag.suggestion) |sugg| {
                self.allocator.free(sugg);
            }
        }
        self.diagnostics.deinit(self.allocator);

        var it = self.source_lines.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.source_lines.deinit();
    }

    /// Load source code for displaying in diagnostics
    pub fn loadSource(self: *DiagnosticReporter, source: []const u8) !void {
        var line_num: usize = 1;
        var line_start: usize = 0;

        for (source, 0..) |c, i| {
            if (c == '\n') {
                const line = source[line_start..i];
                const line_copy = try self.allocator.dupe(u8, line);
                const key = try std.fmt.allocPrint(self.allocator, "{d}", .{line_num});
                try self.source_lines.put(key, line_copy);

                line_num += 1;
                line_start = i + 1;
            }
        }

        // Last line if no trailing newline
        if (line_start < source.len) {
            const line = source[line_start..];
            const line_copy = try self.allocator.dupe(u8, line);
            const key = try std.fmt.allocPrint(self.allocator, "{d}", .{line_num});
            try self.source_lines.put(key, line_copy);
        }
    }

    pub fn addError(
        self: *DiagnosticReporter,
        message: []const u8,
        location: ast.SourceLocation,
        suggestion: ?[]const u8,
    ) !void {
        const msg_copy = try self.allocator.dupe(u8, message);
        const sugg_copy = if (suggestion) |s| try self.allocator.dupe(u8, s) else null;

        const source_line = blk: {
            const key = try std.fmt.allocPrint(self.allocator, "{d}", .{location.line});
            defer self.allocator.free(key);
            break :blk self.source_lines.get(key);
        };

        try self.diagnostics.append(self.allocator, .{
            .severity = .Error,
            .message = msg_copy,
            .location = location,
            .source_line = source_line,
            .suggestion = sugg_copy,
        });
    }

    pub fn addWarning(
        self: *DiagnosticReporter,
        message: []const u8,
        location: ast.SourceLocation,
        suggestion: ?[]const u8,
    ) !void {
        const msg_copy = try self.allocator.dupe(u8, message);
        const sugg_copy = if (suggestion) |s| try self.allocator.dupe(u8, s) else null;

        const source_line = blk: {
            const key = try std.fmt.allocPrint(self.allocator, "{d}", .{location.line});
            defer self.allocator.free(key);
            break :blk self.source_lines.get(key);
        };

        try self.diagnostics.append(self.allocator, .{
            .severity = .Warning,
            .message = msg_copy,
            .location = location,
            .source_line = source_line,
            .suggestion = sugg_copy,
        });
    }

    pub fn report(self: *DiagnosticReporter, file_path: []const u8) void {
        for (self.diagnostics.items) |diag| {
            diag.format(file_path);
        }
    }

    pub fn hasErrors(self: *DiagnosticReporter) bool {
        for (self.diagnostics.items) |diag| {
            if (diag.severity == .Error) return true;
        }
        return false;
    }

    pub fn hasWarnings(self: *DiagnosticReporter) bool {
        for (self.diagnostics.items) |diag| {
            if (diag.severity == .Warning) return true;
        }
        return false;
    }
};
