const std = @import("std");

/// Centralized error types for the Ion compiler

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
        var buf = std.ArrayList(u8){};
        errdefer buf.deinit(self.allocator);

        const writer = buf.writer(self.allocator);

        const ctx = ErrorContext{
            .file = file,
            .line = line,
            .column = column,
            .source_line = source_line,
            .message = message,
            .error_code = error_code,
            .suggestion = suggestion,
        };

        try ctx.format("", .{}, writer);

        return buf.toOwnedSlice(self.allocator);
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

        return self.formatError(file, line, column, message, source_line, null, null);
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
