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
