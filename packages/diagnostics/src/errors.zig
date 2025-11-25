const std = @import("std");

/// Centralized error types for the Home compiler

/// Compiler errors - issues during compilation phases
pub const CompilerError = error{
    // Lexer errors
    InvalidCharacter,
    UnterminatedString,
    UnterminatedComment,
    InvalidNumberFormat,
    InvalidEscapeSequence,

    // Parser errors
    UnexpectedToken,
    ExpectedIdentifier,
    ExpectedExpression,
    ExpectedStatement,
    ExpectedType,
    MissingClosingBrace,
    MissingClosingParen,
    MissingSemicolon,
    InvalidSyntax,

    // Type checker errors
    TypeMismatch,
    UndefinedVariable,
    UndefinedFunction,
    UndefinedType,
    DuplicateDefinition,
    InvalidTypeConversion,
    CircularDependency,
    IncompatibleTypes,

    // Semantic errors
    ImmutableAssignment,
    UseBeforeInitialization,
    UnreachableCode,
    InvalidReturnType,
    MissingReturnStatement,
    TooManyArguments,
    TooFewArguments,

    // Generic errors
    GenericParameterMismatch,
    UninferredTypeParameter,
    InvalidConstraint,

    // Pattern matching errors
    NonExhaustiveMatch,
    UnreachablePattern,
    InvalidPattern,
};

/// Runtime errors - issues during execution
pub const RuntimeError = error{
    // Memory errors
    OutOfMemory,
    NullPointerDereference,
    UseAfterFree,
    DoubleFree,
    InvalidPointer,
    StackOverflow,

    // Arithmetic errors
    DivisionByZero,
    IntegerOverflow,
    IntegerUnderflow,
    InvalidOperation,

    // Access errors
    IndexOutOfBounds,
    InvalidAccess,
    PermissionDenied,

    // Async errors
    TaskFailed,
    Deadlock,
    Timeout,
    ChannelClosed,

    // I/O errors
    IoError,
    FileNotFound,
    PermissionError,
    EndOfFile,
};

/// Package manager errors
pub const PackageError = error{
    // Resolution errors
    PackageNotFound,
    VersionConflict,
    CircularDependency,
    InvalidVersion,
    InvalidPackageName,

    // Download errors
    DownloadFailed,
    NetworkError,
    InvalidChecksum,
    CorruptedPackage,

    // Installation errors
    InstallationFailed,
    ExtractionFailed,
    PermissionDenied,
    DiskFull,

    // Configuration errors
    InvalidConfiguration,
    MissingConfiguration,
    InvalidToml,
    InvalidJson,
};

/// Build system errors
pub const BuildError = error{
    // Compilation errors
    CompilationFailed,
    LinkingFailed,
    CodegenFailed,

    // File system errors
    FileNotFound,
    CannotReadFile,
    CannotWriteFile,
    InvalidPath,

    // Cache errors
    CacheCorrupted,
    CacheInvalidation,
    CacheFull,

    // Configuration errors
    InvalidBuildConfig,
    MissingTarget,
    UnsupportedTarget,
    InvalidOptimizationLevel,
};

/// Error context with source location
pub const ErrorContext = struct {
    file: []const u8,
    line: usize,
    column: usize,
    source_line: ?[]const u8,
    message: []const u8,
    error_code: ?[]const u8,
    suggestion: ?[]const u8,

    pub fn format(
        self: ErrorContext,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        // Format: file:line:column: error: message
        try writer.print("{s}:{d}:{d}: error", .{ self.file, self.line, self.column });

        if (self.error_code) |code| {
            try writer.print("[{s}]", .{code});
        }

        try writer.print(": {s}\n", .{self.message});

        // Show source line with caret
        if (self.source_line) |line| {
            try writer.print("  {s}\n", .{line});
            try writer.writeByteNTimes(' ', self.column + 2);
            try writer.writeByte('^');
            try writer.writeByte('\n');
        }

        // Show suggestion if available
        if (self.suggestion) |suggestion| {
            try writer.print("  help: {s}\n", .{suggestion});
        }
    }
};

/// Error formatter for consistent error messages
pub const ErrorFormatter = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ErrorFormatter {
        return .{ .allocator = allocator };
    }

    pub fn formatError(
        self: ErrorFormatter,
        file: []const u8,
        line: usize,
        column: usize,
        message: []const u8,
        source_line: ?[]const u8,
        error_code: ?[]const u8,
        suggestion: ?[]const u8,
    ) ![]const u8 {
        // Build error message parts
        var parts = std.ArrayList([]const u8){};
        defer parts.deinit(self.allocator);

        // Format: file:line:column: error: message
        const header = try std.fmt.allocPrint(self.allocator, "{s}:{d}:{d}: error", .{ file, line, column });
        try parts.append(self.allocator, header);

        if (error_code) |code| {
            const code_str = try std.fmt.allocPrint(self.allocator, "[{s}]", .{code});
            try parts.append(self.allocator, code_str);
        }

        const msg = try std.fmt.allocPrint(self.allocator, ": {s}\n", .{message});
        try parts.append(self.allocator, msg);

        // Show source line with caret
        if (source_line) |line_str| {
            const line_part = try std.fmt.allocPrint(self.allocator, "  {s}\n", .{line_str});
            try parts.append(self.allocator, line_part);

            const spaces = try self.allocator.alloc(u8, column + 2);
            @memset(spaces, ' ');
            try parts.append(self.allocator, spaces);

            const caret = try self.allocator.dupe(u8, "^\n");
            try parts.append(self.allocator, caret);
        }

        // Show suggestion if available
        if (suggestion) |sug| {
            const sug_part = try std.fmt.allocPrint(self.allocator, "  help: {s}\n", .{sug});
            try parts.append(self.allocator, sug_part);
        }

        // Join all parts
        var total_len: usize = 0;
        for (parts.items) |part| total_len += part.len;

        const result = try self.allocator.alloc(u8, total_len);
        var pos: usize = 0;
        for (parts.items) |part| {
            @memcpy(result[pos..][0..part.len], part);
            pos += part.len;
            self.allocator.free(part);
        }

        return result;
    }

    pub fn compilerError(
        self: ErrorFormatter,
        file: []const u8,
        line: usize,
        column: usize,
        err: CompilerError,
        source_line: ?[]const u8,
    ) ![]const u8 {
        const message = switch (err) {
            error.InvalidCharacter => "invalid character in source",
            error.UnterminatedString => "unterminated string literal",
            error.UnterminatedComment => "unterminated comment",
            error.InvalidNumberFormat => "invalid number format",
            error.InvalidEscapeSequence => "invalid escape sequence",
            error.UnexpectedToken => "unexpected token",
            error.ExpectedIdentifier => "expected identifier",
            error.ExpectedExpression => "expected expression",
            error.ExpectedStatement => "expected statement",
            error.ExpectedType => "expected type",
            error.MissingClosingBrace => "missing closing brace '}'",
            error.MissingClosingParen => "missing closing parenthesis ')'",
            error.MissingSemicolon => "missing semicolon ';'",
            error.InvalidSyntax => "invalid syntax",
            error.TypeMismatch => "type mismatch",
            error.UndefinedVariable => "undefined variable",
            error.UndefinedFunction => "undefined function",
            error.UndefinedType => "undefined type",
            error.DuplicateDefinition => "duplicate definition",
            error.InvalidTypeConversion => "invalid type conversion",
            error.CircularDependency => "circular dependency detected",
            error.IncompatibleTypes => "incompatible types",
            error.ImmutableAssignment => "cannot assign to immutable variable",
            error.UseBeforeInitialization => "use of uninitialized variable",
            error.UnreachableCode => "unreachable code",
            error.InvalidReturnType => "invalid return type",
            error.MissingReturnStatement => "missing return statement",
            error.TooManyArguments => "too many arguments",
            error.TooFewArguments => "too few arguments",
            error.GenericParameterMismatch => "generic parameter mismatch",
            error.UninferredTypeParameter => "cannot infer type parameter",
            error.InvalidConstraint => "invalid constraint",
            error.NonExhaustiveMatch => "non-exhaustive pattern match",
            error.UnreachablePattern => "unreachable pattern",
            error.InvalidPattern => "invalid pattern",
        };

        const suggestion = switch (err) {
            error.UnterminatedString => "add closing quote",
            error.UnterminatedComment => "add closing */",
            error.MissingClosingBrace => "add } to close the block",
            error.MissingClosingParen => "add ) to close the expression",
            error.MissingSemicolon => "add ; at the end of the statement",
            error.TypeMismatch => "ensure the value matches the expected type",
            error.UndefinedVariable => "check spelling or declare the variable first",
            error.UndefinedFunction => "check spelling or import the required module",
            error.ImmutableAssignment => "declare variable as 'let mut' to allow mutation",
            error.UseBeforeInitialization => "initialize the variable before use",
            error.MissingReturnStatement => "add 'return' statement to all code paths",
            error.TooManyArguments => "remove extra arguments",
            error.TooFewArguments => "add missing arguments",
            error.NonExhaustiveMatch => "add missing match arms or use '_' catch-all",
            error.DuplicateDefinition => "rename one of the definitions or remove duplicate",
            error.CircularDependency => "break the dependency cycle by restructuring code",
            else => null,
        };

        return self.formatError(file, line, column, message, source_line, null, suggestion);
    }

    pub fn runtimeError(
        self: ErrorFormatter,
        file: []const u8,
        line: usize,
        err: RuntimeError,
    ) ![]const u8 {
        const message = switch (err) {
            error.OutOfMemory => "out of memory",
            error.NullPointerDereference => "null pointer dereference",
            error.UseAfterFree => "use after free",
            error.DoubleFree => "double free",
            error.InvalidPointer => "invalid pointer",
            error.StackOverflow => "stack overflow",
            error.DivisionByZero => "division by zero",
            error.IntegerOverflow => "integer overflow",
            error.IntegerUnderflow => "integer underflow",
            error.InvalidOperation => "invalid operation",
            error.IndexOutOfBounds => "index out of bounds",
            error.InvalidAccess => "invalid memory access",
            error.PermissionDenied => "permission denied",
            error.TaskFailed => "async task failed",
            error.Deadlock => "deadlock detected",
            error.Timeout => "operation timed out",
            error.ChannelClosed => "channel closed",
            error.IoError => "I/O error",
            error.FileNotFound => "file not found",
            error.PermissionError => "permission error",
            error.EndOfFile => "unexpected end of file",
        };

        return self.formatError(file, line, 0, message, null, null, null);
    }
};

/// Error code generator
pub fn errorCode(comptime category: []const u8, comptime number: u32) []const u8 {
    return std.fmt.comptimePrint("E{s}{d:0>4}", .{ category, number });
}

// Error code constants
pub const E_LEXER_INVALID_CHAR = errorCode("L", 1);
pub const E_PARSER_UNEXPECTED_TOKEN = errorCode("P", 1);
pub const E_TYPE_MISMATCH = errorCode("T", 1);
pub const E_RUNTIME_NULL_DEREF = errorCode("R", 1);
pub const E_PACKAGE_NOT_FOUND = errorCode("K", 1);
pub const E_BUILD_FAILED = errorCode("B", 1);

// ============================================================================
// Extended Error Context System
// ============================================================================

/// Error severity levels
pub const Severity = enum {
    hint,
    note,
    warning,
    @"error",
    fatal,

    pub fn toString(self: Severity) []const u8 {
        return switch (self) {
            .hint => "hint",
            .note => "note",
            .warning => "warning",
            .@"error" => "error",
            .fatal => "fatal error",
        };
    }

    pub fn toColor(self: Severity) []const u8 {
        return switch (self) {
            .hint => "\x1b[36m", // cyan
            .note => "\x1b[34m", // blue
            .warning => "\x1b[33m", // yellow
            .@"error" => "\x1b[31m", // red
            .fatal => "\x1b[1;31m", // bold red
        };
    }
};

/// Source location with optional span
pub const SourceLocation = struct {
    file: []const u8,
    line: usize,
    column: usize,
    end_line: ?usize = null,
    end_column: ?usize = null,

    pub fn span(file: []const u8, start_line: usize, start_col: usize, end_line: usize, end_col: usize) SourceLocation {
        return .{
            .file = file,
            .line = start_line,
            .column = start_col,
            .end_line = end_line,
            .end_column = end_col,
        };
    }

    pub fn point(file: []const u8, line: usize, column: usize) SourceLocation {
        return .{
            .file = file,
            .line = line,
            .column = column,
        };
    }
};

/// Related diagnostic information
pub const RelatedInfo = struct {
    location: SourceLocation,
    message: []const u8,
};

/// Code fix suggestion
pub const CodeFix = struct {
    description: []const u8,
    replacement: []const u8,
    location: SourceLocation,
};

/// Stack frame for error traces
pub const StackFrame = struct {
    function_name: []const u8,
    file: []const u8,
    line: usize,
    column: usize,
};

/// Rich diagnostic with full context
pub const RichDiagnostic = struct {
    allocator: std.mem.Allocator,
    severity: Severity,
    code: ?[]const u8,
    message: []const u8,
    location: SourceLocation,
    source_lines: std.ArrayList(SourceLine),
    related: std.ArrayList(RelatedInfo),
    fixes: std.ArrayList(CodeFix),
    notes: std.ArrayList([]const u8),
    explanation_url: ?[]const u8,
    cause: ?*RichDiagnostic,
    stack_trace: std.ArrayList(StackFrame),

    const SourceLine = struct {
        line_number: usize,
        content: []const u8,
        highlight_start: ?usize,
        highlight_end: ?usize,
    };

    pub fn init(allocator: std.mem.Allocator, severity: Severity, message: []const u8, location: SourceLocation) RichDiagnostic {
        return .{
            .allocator = allocator,
            .severity = severity,
            .code = null,
            .message = message,
            .location = location,
            .source_lines = std.ArrayList(SourceLine).init(allocator),
            .related = std.ArrayList(RelatedInfo).init(allocator),
            .fixes = std.ArrayList(CodeFix).init(allocator),
            .notes = std.ArrayList([]const u8).init(allocator),
            .explanation_url = null,
            .cause = null,
            .stack_trace = std.ArrayList(StackFrame).init(allocator),
        };
    }

    pub fn deinit(self: *RichDiagnostic) void {
        self.source_lines.deinit();
        self.related.deinit();
        self.fixes.deinit();
        self.notes.deinit();
        self.stack_trace.deinit();
        if (self.cause) |cause| {
            cause.deinit();
            self.allocator.destroy(cause);
        }
    }

    /// Set error code
    pub fn withCode(self: *RichDiagnostic, code: []const u8) *RichDiagnostic {
        self.code = code;
        return self;
    }

    /// Add source line context
    pub fn addSourceLine(self: *RichDiagnostic, line_num: usize, content: []const u8, highlight_start: ?usize, highlight_end: ?usize) !void {
        try self.source_lines.append(.{
            .line_number = line_num,
            .content = content,
            .highlight_start = highlight_start,
            .highlight_end = highlight_end,
        });
    }

    /// Add related information
    pub fn addRelated(self: *RichDiagnostic, location: SourceLocation, message: []const u8) !void {
        try self.related.append(.{
            .location = location,
            .message = message,
        });
    }

    /// Add code fix suggestion
    pub fn addFix(self: *RichDiagnostic, description: []const u8, replacement: []const u8, location: SourceLocation) !void {
        try self.fixes.append(.{
            .description = description,
            .replacement = replacement,
            .location = location,
        });
    }

    /// Add a note
    pub fn addNote(self: *RichDiagnostic, note: []const u8) !void {
        try self.notes.append(note);
    }

    /// Set explanation URL
    pub fn withExplanation(self: *RichDiagnostic, url: []const u8) *RichDiagnostic {
        self.explanation_url = url;
        return self;
    }

    /// Set cause (for error chains)
    pub fn withCause(self: *RichDiagnostic, cause: *RichDiagnostic) *RichDiagnostic {
        self.cause = cause;
        return self;
    }

    /// Add stack frame
    pub fn addStackFrame(self: *RichDiagnostic, func: []const u8, file: []const u8, line: usize, col: usize) !void {
        try self.stack_trace.append(.{
            .function_name = func,
            .file = file,
            .line = line,
            .column = col,
        });
    }

    /// Format diagnostic for terminal output (with colors)
    pub fn formatColored(self: *const RichDiagnostic, writer: anytype) !void {
        const reset = "\x1b[0m";
        const bold = "\x1b[1m";
        const dim = "\x1b[2m";
        const cyan = "\x1b[36m";
        const blue = "\x1b[34m";
        const green = "\x1b[32m";

        // Header: file:line:column: severity[code]: message
        try writer.print("{s}{s}:{d}:{d}:{s} ", .{
            bold,
            self.location.file,
            self.location.line,
            self.location.column,
            reset,
        });

        try writer.print("{s}{s}{s}", .{
            self.severity.toColor(),
            self.severity.toString(),
            reset,
        });

        if (self.code) |code| {
            try writer.print("{s}[{s}]{s}", .{ dim, code, reset });
        }

        try writer.print(": {s}{s}{s}\n", .{ bold, self.message, reset });

        // Source lines with highlighting
        for (self.source_lines.items) |line| {
            try writer.print("{s}{d: >5} |{s} ", .{ blue, line.line_number, reset });

            if (line.highlight_start) |start| {
                const end = line.highlight_end orelse line.content.len;
                try writer.writeAll(line.content[0..start]);
                try writer.print("{s}{s}{s}", .{
                    self.severity.toColor(),
                    line.content[start..@min(end, line.content.len)],
                    reset,
                });
                if (end < line.content.len) {
                    try writer.writeAll(line.content[end..]);
                }
            } else {
                try writer.writeAll(line.content);
            }
            try writer.writeByte('\n');

            // Underline
            if (line.highlight_start) |start| {
                const end = line.highlight_end orelse start + 1;
                try writer.print("{s}      |{s} ", .{ blue, reset });
                try writer.writeByteNTimes(' ', start);
                try writer.print("{s}", .{self.severity.toColor()});
                try writer.writeByteNTimes('^', @min(end - start, line.content.len - start));
                try writer.print("{s}\n", .{reset});
            }
        }

        // Notes
        for (self.notes.items) |note| {
            try writer.print("{s}note:{s} {s}\n", .{ cyan, reset, note });
        }

        // Related information
        for (self.related.items) |rel| {
            try writer.print("{s}  --> {s}:{d}:{d}{s}\n", .{
                dim,
                rel.location.file,
                rel.location.line,
                rel.location.column,
                reset,
            });
            try writer.print("       {s}{s}{s}\n", .{ dim, rel.message, reset });
        }

        // Code fixes
        if (self.fixes.items.len > 0) {
            try writer.print("{s}help:{s} ", .{ green, reset });
            for (self.fixes.items, 0..) |fix, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.print("{s}", .{fix.description});
            }
            try writer.writeByte('\n');

            for (self.fixes.items) |fix| {
                if (fix.replacement.len > 0) {
                    try writer.print("{s}      |{s} {s}{s}{s}\n", .{
                        blue,
                        reset,
                        green,
                        fix.replacement,
                        reset,
                    });
                }
            }
        }

        // Explanation URL
        if (self.explanation_url) |url| {
            try writer.print("{s}for more information, see: {s}{s}\n", .{ dim, url, reset });
        }

        // Stack trace
        if (self.stack_trace.items.len > 0) {
            try writer.print("\n{s}stack trace:{s}\n", .{ dim, reset });
            for (self.stack_trace.items, 0..) |frame, i| {
                try writer.print("  {d}: {s}{s}{s} at {s}:{d}:{d}\n", .{
                    i,
                    bold,
                    frame.function_name,
                    reset,
                    frame.file,
                    frame.line,
                    frame.column,
                });
            }
        }

        // Cause chain
        if (self.cause) |cause| {
            try writer.print("\n{s}caused by:{s}\n", .{ dim, reset });
            try cause.formatColored(writer);
        }
    }

    /// Format diagnostic for plain text output
    pub fn formatPlain(self: *const RichDiagnostic, writer: anytype) !void {
        // Header
        try writer.print("{s}:{d}:{d}: {s}", .{
            self.location.file,
            self.location.line,
            self.location.column,
            self.severity.toString(),
        });

        if (self.code) |code| {
            try writer.print("[{s}]", .{code});
        }

        try writer.print(": {s}\n", .{self.message});

        // Source lines
        for (self.source_lines.items) |line| {
            try writer.print("{d: >5} | {s}\n", .{ line.line_number, line.content });

            if (line.highlight_start) |start| {
                const end = line.highlight_end orelse start + 1;
                try writer.writeAll("      | ");
                try writer.writeByteNTimes(' ', start);
                try writer.writeByteNTimes('^', end - start);
                try writer.writeByte('\n');
            }
        }

        // Notes
        for (self.notes.items) |note| {
            try writer.print("note: {s}\n", .{note});
        }

        // Related
        for (self.related.items) |rel| {
            try writer.print("  --> {s}:{d}:{d}: {s}\n", .{
                rel.location.file,
                rel.location.line,
                rel.location.column,
                rel.message,
            });
        }

        // Fixes
        for (self.fixes.items) |fix| {
            try writer.print("help: {s}\n", .{fix.description});
            if (fix.replacement.len > 0) {
                try writer.print("      | {s}\n", .{fix.replacement});
            }
        }

        // URL
        if (self.explanation_url) |url| {
            try writer.print("for more information, see: {s}\n", .{url});
        }

        // Stack trace
        if (self.stack_trace.items.len > 0) {
            try writer.writeAll("\nstack trace:\n");
            for (self.stack_trace.items, 0..) |frame, i| {
                try writer.print("  {d}: {s} at {s}:{d}:{d}\n", .{
                    i,
                    frame.function_name,
                    frame.file,
                    frame.line,
                    frame.column,
                });
            }
        }

        // Cause
        if (self.cause) |cause| {
            try writer.writeAll("\ncaused by:\n");
            try cause.formatPlain(writer);
        }
    }
};

/// Diagnostic collection for multiple errors
pub const DiagnosticBag = struct {
    allocator: std.mem.Allocator,
    diagnostics: std.ArrayList(RichDiagnostic),
    error_count: usize,
    warning_count: usize,

    pub fn init(allocator: std.mem.Allocator) DiagnosticBag {
        return .{
            .allocator = allocator,
            .diagnostics = std.ArrayList(RichDiagnostic).init(allocator),
            .error_count = 0,
            .warning_count = 0,
        };
    }

    pub fn deinit(self: *DiagnosticBag) void {
        for (self.diagnostics.items) |*d| {
            d.deinit();
        }
        self.diagnostics.deinit();
    }

    /// Add a diagnostic
    pub fn add(self: *DiagnosticBag, diagnostic: RichDiagnostic) !void {
        switch (diagnostic.severity) {
            .@"error", .fatal => self.error_count += 1,
            .warning => self.warning_count += 1,
            else => {},
        }
        try self.diagnostics.append(diagnostic);
    }

    /// Create and add an error
    pub fn addError(self: *DiagnosticBag, message: []const u8, location: SourceLocation) !*RichDiagnostic {
        var diag = RichDiagnostic.init(self.allocator, .@"error", message, location);
        try self.add(diag);
        return &self.diagnostics.items[self.diagnostics.items.len - 1];
    }

    /// Create and add a warning
    pub fn addWarning(self: *DiagnosticBag, message: []const u8, location: SourceLocation) !*RichDiagnostic {
        var diag = RichDiagnostic.init(self.allocator, .warning, message, location);
        try self.add(diag);
        return &self.diagnostics.items[self.diagnostics.items.len - 1];
    }

    /// Check if there are any errors
    pub fn hasErrors(self: *const DiagnosticBag) bool {
        return self.error_count > 0;
    }

    /// Print summary
    pub fn printSummary(self: *const DiagnosticBag, writer: anytype, colored: bool) !void {
        if (colored) {
            const reset = "\x1b[0m";
            const bold = "\x1b[1m";
            const red = "\x1b[31m";
            const yellow = "\x1b[33m";

            if (self.error_count > 0) {
                try writer.print("{s}{s}error{s}: aborting due to ", .{ bold, red, reset });
                if (self.error_count == 1) {
                    try writer.writeAll("previous error");
                } else {
                    try writer.print("{d} previous errors", .{self.error_count});
                }
            }

            if (self.warning_count > 0) {
                if (self.error_count > 0) try writer.writeAll("; ");
                try writer.print("{s}{s}{d} warning{s}{s}", .{
                    bold,
                    yellow,
                    self.warning_count,
                    if (self.warning_count > 1) "s" else "",
                    reset,
                });
            }

            if (self.error_count > 0 or self.warning_count > 0) {
                try writer.writeAll(" emitted\n");
            }
        } else {
            if (self.error_count > 0) {
                try writer.print("error: aborting due to {d} previous error{s}", .{
                    self.error_count,
                    if (self.error_count > 1) "s" else "",
                });
            }

            if (self.warning_count > 0) {
                if (self.error_count > 0) try writer.writeAll("; ");
                try writer.print("{d} warning{s}", .{
                    self.warning_count,
                    if (self.warning_count > 1) "s" else "",
                });
            }

            if (self.error_count > 0 or self.warning_count > 0) {
                try writer.writeAll(" emitted\n");
            }
        }
    }

    /// Print all diagnostics
    pub fn printAll(self: *const DiagnosticBag, writer: anytype, colored: bool) !void {
        for (self.diagnostics.items) |*diag| {
            if (colored) {
                try diag.formatColored(writer);
            } else {
                try diag.formatPlain(writer);
            }
            try writer.writeByte('\n');
        }
        try self.printSummary(writer, colored);
    }
};

/// Error builder for fluent API
pub const ErrorBuilder = struct {
    allocator: std.mem.Allocator,
    diagnostic: RichDiagnostic,

    pub fn init(allocator: std.mem.Allocator, severity: Severity, message: []const u8, file: []const u8, line: usize, column: usize) ErrorBuilder {
        return .{
            .allocator = allocator,
            .diagnostic = RichDiagnostic.init(allocator, severity, message, SourceLocation.point(file, line, column)),
        };
    }

    pub fn code(self: *ErrorBuilder, err_code: []const u8) *ErrorBuilder {
        self.diagnostic.code = err_code;
        return self;
    }

    pub fn span(self: *ErrorBuilder, end_line: usize, end_column: usize) *ErrorBuilder {
        self.diagnostic.location.end_line = end_line;
        self.diagnostic.location.end_column = end_column;
        return self;
    }

    pub fn source(self: *ErrorBuilder, line_num: usize, content: []const u8) *ErrorBuilder {
        self.diagnostic.addSourceLine(line_num, content, null, null) catch {};
        return self;
    }

    pub fn sourceHighlight(self: *ErrorBuilder, line_num: usize, content: []const u8, start: usize, end: usize) *ErrorBuilder {
        self.diagnostic.addSourceLine(line_num, content, start, end) catch {};
        return self;
    }

    pub fn note(self: *ErrorBuilder, msg: []const u8) *ErrorBuilder {
        self.diagnostic.addNote(msg) catch {};
        return self;
    }

    pub fn help(self: *ErrorBuilder, description: []const u8, replacement: []const u8) *ErrorBuilder {
        self.diagnostic.addFix(description, replacement, self.diagnostic.location) catch {};
        return self;
    }

    pub fn related(self: *ErrorBuilder, file: []const u8, line: usize, col: usize, msg: []const u8) *ErrorBuilder {
        self.diagnostic.addRelated(SourceLocation.point(file, line, col), msg) catch {};
        return self;
    }

    pub fn explanation(self: *ErrorBuilder, url: []const u8) *ErrorBuilder {
        self.diagnostic.explanation_url = url;
        return self;
    }

    pub fn build(self: *ErrorBuilder) RichDiagnostic {
        return self.diagnostic;
    }
};

/// Convenience function to create an error
pub fn err(allocator: std.mem.Allocator, message: []const u8, file: []const u8, line: usize, column: usize) ErrorBuilder {
    return ErrorBuilder.init(allocator, .@"error", message, file, line, column);
}

/// Convenience function to create a warning
pub fn warn(allocator: std.mem.Allocator, message: []const u8, file: []const u8, line: usize, column: usize) ErrorBuilder {
    return ErrorBuilder.init(allocator, .warning, message, file, line, column);
}

/// Convenience function to create a note
pub fn info(allocator: std.mem.Allocator, message: []const u8, file: []const u8, line: usize, column: usize) ErrorBuilder {
    return ErrorBuilder.init(allocator, .note, message, file, line, column);
}

// ============================================================================
// Tests
// ============================================================================

test "RichDiagnostic basic" {
    var diag = RichDiagnostic.init(
        std.testing.allocator,
        .@"error",
        "type mismatch",
        SourceLocation.point("test.home", 10, 5),
    );
    defer diag.deinit();

    _ = diag.withCode("E0001");
    try diag.addNote("expected i32, found string");

    try std.testing.expectEqualStrings("E0001", diag.code.?);
}

test "ErrorBuilder fluent API" {
    var builder = err(std.testing.allocator, "undefined variable 'x'", "main.home", 15, 10);
    var diag = builder
        .code("E0002")
        .sourceHighlight(15, "    let y = x + 1", 12, 13)
        .note("'x' is not defined in this scope")
        .help("did you mean 'y'?", "let y = y + 1")
        .build();
    defer diag.deinit();

    try std.testing.expect(diag.source_lines.items.len == 1);
    try std.testing.expect(diag.notes.items.len == 1);
    try std.testing.expect(diag.fixes.items.len == 1);
}

test "DiagnosticBag error counting" {
    var bag = DiagnosticBag.init(std.testing.allocator);
    defer bag.deinit();

    _ = try bag.addError("error 1", SourceLocation.point("a.home", 1, 1));
    _ = try bag.addWarning("warning 1", SourceLocation.point("b.home", 2, 2));
    _ = try bag.addError("error 2", SourceLocation.point("c.home", 3, 3));

    try std.testing.expectEqual(@as(usize, 2), bag.error_count);
    try std.testing.expectEqual(@as(usize, 1), bag.warning_count);
    try std.testing.expect(bag.hasErrors());
}
