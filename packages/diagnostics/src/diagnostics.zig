const std = @import("std");
pub const ast = @import("ast");
pub const errors = @import("errors.zig");

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

/// Rich diagnostic message with context, suggestions, and code examples
pub const RichDiagnostic = struct {
    severity: Severity,
    error_code: []const u8,
    title: []const u8,
    primary_label: Label,
    secondary_labels: []const Label,
    notes: []const []const u8,
    help: ?[]const u8,
    suggestion: ?Suggestion,

    pub const Label = struct {
        location: ast.SourceLocation,
        message: []const u8,
        style: LabelStyle,

        pub const LabelStyle = enum {
            Primary,
            Secondary,
            Note,
        };
    };

    pub const Suggestion = struct {
        location: ast.SourceLocation,
        message: []const u8,
        replacement: []const u8,
    };

    /// Format and display the diagnostic
    pub fn display(
        self: RichDiagnostic,
        file_path: []const u8,
        source: []const u8,
        writer: anytype,
    ) !void {
        // Header: error[E0001]: title
        try writer.print("{s}{s}{s}[{s}]{s}: {s}{s}\n", .{
            Color.Bold.code(),
            self.severity.color().code(),
            self.severity.label(),
            self.error_code,
            Color.Reset.code(),
            Color.Bold.code(),
            self.title,
        });
        try writer.print("{s}\n", .{Color.Reset.code()});

        // Location header: --> file:line:column
        try writer.print("  {s}-->{s} {s}:{d}:{d}\n", .{
            Color.Blue.code(),
            Color.Reset.code(),
            file_path,
            self.primary_label.location.line,
            self.primary_label.location.column,
        });

        // Extract relevant source lines
        const line_nums = try self.getLineRange();
        const min_line = line_nums.min;
        const max_line = line_nums.max;

        // Line number width for alignment
        const line_width = std.fmt.count("{d}", .{max_line});

        // Display source with labels
        try writer.print("   {s}|{s}\n", .{ Color.Blue.code(), Color.Reset.code() });

        var current_line = min_line;
        while (current_line <= max_line) : (current_line += 1) {
            const line_content = self.getSourceLine(source, current_line) orelse continue;

            // Line number and content
            try writer.print(" {s}{d:>[width]}{s} {s}|{s} {s}\n", .{
                Color.Blue.code(),
                current_line,
                Color.Reset.code(),
                Color.Blue.code(),
                Color.Reset.code(),
                line_content,
                .{ .width = line_width },
            });

            // Primary label underline
            if (current_line == self.primary_label.location.line) {
                try self.renderLabel(
                    writer,
                    line_width,
                    line_content,
                    self.primary_label,
                );
            }

            // Secondary labels
            for (self.secondary_labels) |label| {
                if (label.location.line == current_line) {
                    try self.renderLabel(writer, line_width, line_content, label);
                }
            }
        }

        try writer.print("   {s}|{s}\n", .{ Color.Blue.code(), Color.Reset.code() });

        // Notes
        for (self.notes) |note| {
            try writer.print("   {s}={s} {s}note:{s} {s}\n", .{
                Color.Blue.code(),
                Color.Reset.code(),
                Color.Bold.code(),
                Color.Reset.code(),
                note,
            });
        }

        // Help message
        if (self.help) |help_msg| {
            try writer.print("   {s}={s} {s}help:{s} {s}\n", .{
                Color.Cyan.code(),
                Color.Reset.code(),
                Color.Bold.code(),
                Color.Reset.code(),
                help_msg,
            });

            // Show suggestion if available
            if (self.suggestion) |sugg| {
                try writer.print("   {s}|{s} try: {s}{s}{s}\n", .{
                    Color.Blue.code(),
                    Color.Reset.code(),
                    Color.Green.code(),
                    sugg.replacement,
                    Color.Reset.code(),
                });
            }
        }

        try writer.print("\n", .{});
    }

    fn getLineRange(self: RichDiagnostic) !struct { min: usize, max: usize } {
        var min = self.primary_label.location.line;
        var max = self.primary_label.location.line;

        for (self.secondary_labels) |label| {
            if (label.location.line < min) min = label.location.line;
            if (label.location.line > max) max = label.location.line;
        }

        // Add context lines
        if (min > 1) min -= 1;
        max += 1;

        return .{ .min = min, .max = max };
    }

    fn getSourceLine(self: RichDiagnostic, source: []const u8, target_line: usize) ?[]const u8 {
        _ = self;
        var line_num: usize = 1;
        var line_start: usize = 0;

        for (source, 0..) |c, i| {
            if (c == '\n') {
                if (line_num == target_line) {
                    return source[line_start..i];
                }
                line_num += 1;
                line_start = i + 1;
            }
        }

        // Last line
        if (line_num == target_line) {
            return source[line_start..];
        }

        return null;
    }

    fn renderLabel(
        self: RichDiagnostic,
        writer: anytype,
        line_width: usize,
        line_content: []const u8,
        label: Label,
    ) !void {
        _ = self;
        const color = switch (label.style) {
            .Primary => Color.Red,
            .Secondary => Color.Blue,
            .Note => Color.Cyan,
        };

        // Gutter
        try writer.writeByteNTimes(' ', line_width + 1);
        try writer.print(" {s}|{s} ", .{ Color.Blue.code(), Color.Reset.code() });

        // Spaces before caret
        const col = if (label.location.column > 0) label.location.column - 1 else 0;
        try writer.writeByteNTimes(' ', col);

        // Underline
        const underline_len = blk: {
            var len: usize = 1;
            var i = col;
            while (i < line_content.len and line_content[i] != ' ') : (i += 1) {
                len += 1;
                if (len >= 20) break; // Max underline length
            }
            break :blk len;
        };

        try writer.print("{s}", .{color.code()});
        if (label.style == .Primary) {
            try writer.writeByteNTimes('^', underline_len);
        } else {
            try writer.writeByteNTimes('-', underline_len);
        }

        // Label message
        if (label.message.len > 0) {
            try writer.print(" {s}", .{label.message});
        }

        try writer.print("{s}\n", .{Color.Reset.code()});
    }
};

/// Builder for creating rich diagnostics
pub const DiagnosticBuilder = struct {
    allocator: std.mem.Allocator,
    severity: Severity,
    error_code: []const u8,
    title: []const u8,
    primary_label: ?RichDiagnostic.Label,
    secondary_labels: std.ArrayList(RichDiagnostic.Label),
    notes: std.ArrayList([]const u8),
    help: ?[]const u8,
    suggestion: ?RichDiagnostic.Suggestion,

    pub fn init(allocator: std.mem.Allocator, severity: Severity, error_code: []const u8, title: []const u8) DiagnosticBuilder {
        return .{
            .allocator = allocator,
            .severity = severity,
            .error_code = error_code,
            .title = title,
            .primary_label = null,
            .secondary_labels = std.ArrayList(RichDiagnostic.Label){ .items = &.{}, .capacity = 0 },
            .notes = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 },
            .help = null,
            .suggestion = null,
        };
    }

    pub fn withPrimaryLabel(self: *DiagnosticBuilder, location: ast.SourceLocation, message: []const u8) *DiagnosticBuilder {
        self.primary_label = .{
            .location = location,
            .message = message,
            .style = .Primary,
        };
        return self;
    }

    pub fn withSecondaryLabel(self: *DiagnosticBuilder, location: ast.SourceLocation, message: []const u8) !*DiagnosticBuilder {
        try self.secondary_labels.append(self.allocator, .{
            .location = location,
            .message = message,
            .style = .Secondary,
        });
        return self;
    }

    pub fn withNote(self: *DiagnosticBuilder, note: []const u8) !*DiagnosticBuilder {
        try self.notes.append(self.allocator, note);
        return self;
    }

    pub fn withHelp(self: *DiagnosticBuilder, help: []const u8) *DiagnosticBuilder {
        self.help = help;
        return self;
    }

    pub fn withSuggestion(
        self: *DiagnosticBuilder,
        location: ast.SourceLocation,
        message: []const u8,
        replacement: []const u8,
    ) *DiagnosticBuilder {
        self.suggestion = .{
            .location = location,
            .message = message,
            .replacement = replacement,
        };
        return self;
    }

    pub fn build(self: *DiagnosticBuilder) !RichDiagnostic {
        if (self.primary_label == null) {
            return error.MissingPrimaryLabel;
        }

        return RichDiagnostic{
            .severity = self.severity,
            .error_code = self.error_code,
            .title = self.title,
            .primary_label = self.primary_label.?,
            .secondary_labels = try self.secondary_labels.toOwnedSlice(self.allocator),
            .notes = try self.notes.toOwnedSlice(self.allocator),
            .help = self.help,
            .suggestion = self.suggestion,
        };
    }
};

/// Common diagnostic builders for frequently used errors
pub const CommonDiagnostics = struct {
    /// Type mismatch error with expected and found types
    pub fn typeMismatch(
        allocator: std.mem.Allocator,
        location: ast.SourceLocation,
        expected: []const u8,
        found: []const u8,
    ) !RichDiagnostic {
        const title = try std.fmt.allocPrint(allocator, "type mismatch: expected {s}, found {s}", .{ expected, found });
        var builder = DiagnosticBuilder.init(allocator, .Error, "T0001", title);

        const msg = try std.fmt.allocPrint(allocator, "expected {s}, found {s}", .{ expected, found });
        _ = builder.withPrimaryLabel(location, msg);
        _ = builder.withHelp("ensure the value matches the expected type");

        return try builder.build();
    }

    /// Undefined variable error with similar names suggestion
    pub fn undefinedVariable(
        allocator: std.mem.Allocator,
        location: ast.SourceLocation,
        name: []const u8,
        similar: ?[]const u8,
    ) !RichDiagnostic {
        const title = try std.fmt.allocPrint(allocator, "cannot find value '{s}' in this scope", .{name});
        var builder = DiagnosticBuilder.init(allocator, .Error, "V0001", title);

        _ = builder.withPrimaryLabel(location, "not found in this scope");

        if (similar) |sim| {
            const help = try std.fmt.allocPrint(allocator, "did you mean '{s}'?", .{sim});
            _ = builder.withHelp(help);
        } else {
            _ = builder.withHelp("check spelling or declare the variable first");
        }

        return try builder.build();
    }

    /// Mutability error
    pub fn cannotMutate(
        allocator: std.mem.Allocator,
        location: ast.SourceLocation,
        var_name: []const u8,
        def_location: ?ast.SourceLocation,
    ) !RichDiagnostic {
        const title = try std.fmt.allocPrint(allocator, "cannot assign to immutable variable '{s}'", .{var_name});
        var builder = DiagnosticBuilder.init(allocator, .Error, "M0001", title);

        _ = builder.withPrimaryLabel(location, "cannot assign to immutable variable");

        if (def_location) |def_loc| {
            _ = try builder.withSecondaryLabel(def_loc, "variable defined here as immutable");
        }

        const help = try std.fmt.allocPrint(allocator, "declare '{s}' as mutable: 'let mut {s} = ...'", .{ var_name, var_name });
        _ = builder.withHelp(help);

        return try builder.build();
    }

    /// Function argument count mismatch
    pub fn argumentCountMismatch(
        allocator: std.mem.Allocator,
        location: ast.SourceLocation,
        expected: usize,
        found: usize,
        fn_name: []const u8,
    ) !RichDiagnostic {
        const title = try std.fmt.allocPrint(
            allocator,
            "function '{s}' takes {d} argument(s) but {d} were supplied",
            .{ fn_name, expected, found },
        );
        var builder = DiagnosticBuilder.init(allocator, .Error, "F0001", title);

        const msg = if (found > expected)
            try std.fmt.allocPrint(allocator, "expected {d} argument(s), found {d}", .{ expected, found })
        else
            try std.fmt.allocPrint(allocator, "expected {d} argument(s), found {d}", .{ expected, found });

        _ = builder.withPrimaryLabel(location, msg);

        if (found > expected) {
            _ = builder.withHelp("remove extra arguments");
        } else {
            _ = builder.withHelp("add missing arguments");
        }

        return try builder.build();
    }

    /// Missing return statement
    pub fn missingReturn(
        allocator: std.mem.Allocator,
        location: ast.SourceLocation,
        fn_name: []const u8,
        return_type: []const u8,
    ) !RichDiagnostic {
        const title = try std.fmt.allocPrint(
            allocator,
            "function '{s}' must return a value of type {s}",
            .{ fn_name, return_type },
        );
        var builder = DiagnosticBuilder.init(allocator, .Error, "R0001", title);

        _ = builder.withPrimaryLabel(location, "missing return statement");
        _ = try builder.withNote("all code paths must return a value");
        _ = builder.withHelp("add 'return' statement to all code paths");

        return try builder.build();
    }

    /// Non-exhaustive match
    pub fn nonExhaustiveMatch(
        allocator: std.mem.Allocator,
        location: ast.SourceLocation,
        missing_patterns: []const []const u8,
    ) !RichDiagnostic {
        const title = "non-exhaustive pattern match";
        var builder = DiagnosticBuilder.init(allocator, .Error, "P0001", title);

        _ = builder.withPrimaryLabel(location, "pattern match is not exhaustive");

        // List missing patterns
        for (missing_patterns) |pattern| {
            const note = try std.fmt.allocPrint(allocator, "missing case: {s}", .{pattern});
            _ = try builder.withNote(note);
        }

        _ = builder.withHelp("add missing patterns or use '_' for a catch-all case");

        return try builder.build();
    }

    /// Division by zero
    pub fn divisionByZero(
        allocator: std.mem.Allocator,
        location: ast.SourceLocation,
    ) !RichDiagnostic {
        const title = "attempt to divide by zero";
        var builder = DiagnosticBuilder.init(allocator, .Error, "A0001", title);

        _ = builder.withPrimaryLabel(location, "division by zero");
        _ = try builder.withNote("this operation will panic at runtime");
        _ = builder.withHelp("ensure the divisor is not zero before dividing");

        return try builder.build();
    }

    /// Index out of bounds
    pub fn indexOutOfBounds(
        allocator: std.mem.Allocator,
        location: ast.SourceLocation,
        index: usize,
        len: usize,
    ) !RichDiagnostic {
        const title = try std.fmt.allocPrint(
            allocator,
            "index out of bounds: index {d} >= length {d}",
            .{ index, len },
        );
        var builder = DiagnosticBuilder.init(allocator, .Error, "A0002", title);

        const msg = try std.fmt.allocPrint(allocator, "index {d} is out of bounds", .{index});
        _ = builder.withPrimaryLabel(location, msg);

        const note = try std.fmt.allocPrint(allocator, "array has length {d}", .{len});
        _ = try builder.withNote(note);

        _ = builder.withHelp("ensure index is less than array length");

        return try builder.build();
    }

    /// Unreachable code
    pub fn unreachableCode(
        allocator: std.mem.Allocator,
        location: ast.SourceLocation,
        reason: []const u8,
    ) !RichDiagnostic {
        const title = "unreachable code detected";
        var builder = DiagnosticBuilder.init(allocator, .Warning, "W0001", title);

        _ = builder.withPrimaryLabel(location, "this code will never execute");
        _ = try builder.withNote(reason);
        _ = builder.withHelp("consider removing unreachable code");

        return try builder.build();
    }

    /// Unused variable
    pub fn unusedVariable(
        allocator: std.mem.Allocator,
        location: ast.SourceLocation,
        var_name: []const u8,
    ) !RichDiagnostic {
        const title = try std.fmt.allocPrint(allocator, "unused variable: '{s}'", .{var_name});
        var builder = DiagnosticBuilder.init(allocator, .Warning, "W0002", title);

        _ = builder.withPrimaryLabel(location, "this variable is never used");

        const help = try std.fmt.allocPrint(allocator, "prefix with '_' to suppress warning: '_{s}'", .{var_name});
        _ = builder.withHelp(help);

        return try builder.build();
    }

    /// Type inference failure
    pub fn cannotInferType(
        allocator: std.mem.Allocator,
        location: ast.SourceLocation,
        context: []const u8,
    ) !RichDiagnostic {
        const title = "cannot infer type";
        var builder = DiagnosticBuilder.init(allocator, .Error, "T0002", title);

        _ = builder.withPrimaryLabel(location, "type cannot be inferred");
        _ = try builder.withNote(context);
        _ = builder.withHelp("add explicit type annotation");

        return try builder.build();
    }
};
