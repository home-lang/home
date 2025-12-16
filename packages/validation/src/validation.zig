// Input Validation Framework for Home Programming Language
//
// This module provides comprehensive input validation with:
// - Recursion depth limits to prevent stack overflow
// - Input size limits to prevent memory exhaustion
// - Resource limits for parsing/compilation
// - Structured error reporting

const std = @import("std");

/// Validation configuration for resource limits
pub const ValidationConfig = struct {
    /// Maximum recursion depth for nested structures
    max_recursion_depth: usize = 256,
    /// Maximum input size in bytes
    max_input_size: usize = 10 * 1024 * 1024, // 10MB
    /// Maximum number of tokens
    max_tokens: usize = 1_000_000,
    /// Maximum AST node count
    max_ast_nodes: usize = 500_000,
    /// Maximum string literal length
    max_string_length: usize = 1 * 1024 * 1024, // 1MB
    /// Maximum array literal size
    max_array_size: usize = 100_000,
    /// Maximum function parameter count
    max_parameters: usize = 255,
    /// Maximum local variable count per function
    max_locals: usize = 65535,
    /// Maximum nesting depth for types
    max_type_depth: usize = 64,
    /// Maximum generic type parameter count
    max_type_params: usize = 32,
    /// Maximum import depth (circular import detection)
    max_import_depth: usize = 100,
    /// Maximum match/switch arms
    max_match_arms: usize = 1000,
    /// Maximum struct field count
    max_struct_fields: usize = 1000,
    /// Maximum enum variant count
    max_enum_variants: usize = 65535,
    /// Timeout for parsing in milliseconds (0 = no timeout)
    parse_timeout_ms: u64 = 30000,
    /// Timeout for type checking in milliseconds
    typecheck_timeout_ms: u64 = 60000,
    /// Timeout for code generation in milliseconds
    codegen_timeout_ms: u64 = 120000,

    /// Create a strict configuration for untrusted input
    pub fn strict() ValidationConfig {
        return .{
            .max_recursion_depth = 64,
            .max_input_size = 1 * 1024 * 1024,
            .max_tokens = 100_000,
            .max_ast_nodes = 50_000,
            .max_string_length = 64 * 1024,
            .max_array_size = 10_000,
            .max_parameters = 32,
            .max_locals = 1024,
            .max_type_depth = 16,
            .max_type_params = 8,
            .max_import_depth = 20,
            .max_match_arms = 256,
            .max_struct_fields = 256,
            .max_enum_variants = 4096,
            .parse_timeout_ms = 5000,
            .typecheck_timeout_ms = 10000,
            .codegen_timeout_ms = 30000,
        };
    }

    /// Create a permissive configuration for trusted input
    pub fn permissive() ValidationConfig {
        return .{
            .max_recursion_depth = 1024,
            .max_input_size = 100 * 1024 * 1024,
            .max_tokens = 10_000_000,
            .max_ast_nodes = 5_000_000,
            .max_string_length = 10 * 1024 * 1024,
            .max_array_size = 1_000_000,
            .max_parameters = 255,
            .max_locals = 65535,
            .max_type_depth = 128,
            .max_type_params = 64,
            .max_import_depth = 500,
            .max_match_arms = 10000,
            .max_struct_fields = 10000,
            .max_enum_variants = 100000,
            .parse_timeout_ms = 0,
            .typecheck_timeout_ms = 0,
            .codegen_timeout_ms = 0,
        };
    }
};

/// Validation error types
pub const ValidationError = error{
    InputTooLarge,
    RecursionDepthExceeded,
    TooManyTokens,
    TooManyAstNodes,
    StringTooLong,
    ArrayTooLarge,
    TooManyParameters,
    TooManyLocals,
    TypeNestingTooDeep,
    TooManyTypeParams,
    ImportDepthExceeded,
    TooManyMatchArms,
    TooManyStructFields,
    TooManyEnumVariants,
    Timeout,
    MemoryLimitExceeded,
    InvalidUtf8,
    NullByteInInput,
};

/// Validation context for tracking state during validation
pub const ValidationContext = struct {
    config: ValidationConfig,
    current_recursion_depth: usize = 0,
    token_count: usize = 0,
    ast_node_count: usize = 0,
    import_depth: usize = 0,
    start_time: i64,
    phase: Phase = .parsing,

    pub const Phase = enum { parsing, type_checking, code_generation };

    pub fn init(config: ValidationConfig) ValidationContext {
        return .{ .config = config, .start_time = std.time.milliTimestamp() };
    }

    pub fn enterRecursion(self: *ValidationContext) ValidationError!void {
        self.current_recursion_depth += 1;
        if (self.current_recursion_depth > self.config.max_recursion_depth) {
            return ValidationError.RecursionDepthExceeded;
        }
    }

    pub fn exitRecursion(self: *ValidationContext) void {
        if (self.current_recursion_depth > 0) self.current_recursion_depth -= 1;
    }

    pub fn recordToken(self: *ValidationContext) ValidationError!void {
        self.token_count += 1;
        if (self.token_count > self.config.max_tokens) return ValidationError.TooManyTokens;
    }

    pub fn recordAstNode(self: *ValidationContext) ValidationError!void {
        self.ast_node_count += 1;
        if (self.ast_node_count > self.config.max_ast_nodes) return ValidationError.TooManyAstNodes;
    }

    pub fn enterImport(self: *ValidationContext) ValidationError!void {
        self.import_depth += 1;
        if (self.import_depth > self.config.max_import_depth) return ValidationError.ImportDepthExceeded;
    }

    pub fn exitImport(self: *ValidationContext) void {
        if (self.import_depth > 0) self.import_depth -= 1;
    }

    pub fn checkTimeout(self: *ValidationContext) ValidationError!void {
        const timeout_ms = switch (self.phase) {
            .parsing => self.config.parse_timeout_ms,
            .type_checking => self.config.typecheck_timeout_ms,
            .code_generation => self.config.codegen_timeout_ms,
        };
        if (timeout_ms == 0) return;
        const elapsed = std.time.milliTimestamp() - self.start_time;
        if (elapsed > @as(i64, @intCast(timeout_ms))) return ValidationError.Timeout;
    }

    pub fn setPhase(self: *ValidationContext, phase: Phase) void {
        self.phase = phase;
        self.start_time = std.time.milliTimestamp();
    }
};

/// Input validator for checking raw input before processing
pub const InputValidator = struct {
    config: ValidationConfig,

    pub fn init(config: ValidationConfig) InputValidator {
        return .{ .config = config };
    }

    pub fn validateInput(self: *const InputValidator, input: []const u8) ValidationError!void {
        if (input.len > self.config.max_input_size) return ValidationError.InputTooLarge;
        if (!std.unicode.utf8ValidateSlice(input)) return ValidationError.InvalidUtf8;
        if (std.mem.indexOfScalar(u8, input, 0) != null) return ValidationError.NullByteInInput;
    }

    pub fn validateString(self: *const InputValidator, str: []const u8) ValidationError!void {
        if (str.len > self.config.max_string_length) return ValidationError.StringTooLong;
    }

    pub fn validateArraySize(self: *const InputValidator, size: usize) ValidationError!void {
        if (size > self.config.max_array_size) return ValidationError.ArrayTooLarge;
    }

    pub fn validateParameterCount(self: *const InputValidator, count: usize) ValidationError!void {
        if (count > self.config.max_parameters) return ValidationError.TooManyParameters;
    }

    pub fn validateLocalCount(self: *const InputValidator, count: usize) ValidationError!void {
        if (count > self.config.max_locals) return ValidationError.TooManyLocals;
    }

    pub fn validateTypeDepth(self: *const InputValidator, depth: usize) ValidationError!void {
        if (depth > self.config.max_type_depth) return ValidationError.TypeNestingTooDeep;
    }

    pub fn validateTypeParamCount(self: *const InputValidator, count: usize) ValidationError!void {
        if (count > self.config.max_type_params) return ValidationError.TooManyTypeParams;
    }

    pub fn validateMatchArmCount(self: *const InputValidator, count: usize) ValidationError!void {
        if (count > self.config.max_match_arms) return ValidationError.TooManyMatchArms;
    }

    pub fn validateStructFieldCount(self: *const InputValidator, count: usize) ValidationError!void {
        if (count > self.config.max_struct_fields) return ValidationError.TooManyStructFields;
    }

    pub fn validateEnumVariantCount(self: *const InputValidator, count: usize) ValidationError!void {
        if (count > self.config.max_enum_variants) return ValidationError.TooManyEnumVariants;
    }
};

/// RAII guard for recursion depth tracking
pub const RecursionGuard = struct {
    context: *ValidationContext,

    pub fn init(context: *ValidationContext) ValidationError!RecursionGuard {
        try context.enterRecursion();
        return .{ .context = context };
    }

    pub fn deinit(self: RecursionGuard) void {
        self.context.exitRecursion();
    }
};

/// RAII guard for import depth tracking
pub const ImportGuard = struct {
    context: *ValidationContext,

    pub fn init(context: *ValidationContext) ValidationError!ImportGuard {
        try context.enterImport();
        return .{ .context = context };
    }

    pub fn deinit(self: ImportGuard) void {
        self.context.exitImport();
    }
};

/// Format validation error for display
pub fn formatValidationError(err: ValidationError) []const u8 {
    return switch (err) {
        ValidationError.InputTooLarge => "Input exceeds maximum allowed size",
        ValidationError.RecursionDepthExceeded => "Maximum recursion depth exceeded",
        ValidationError.TooManyTokens => "Input contains too many tokens",
        ValidationError.TooManyAstNodes => "Input generates too many AST nodes",
        ValidationError.StringTooLong => "String literal exceeds maximum length",
        ValidationError.ArrayTooLarge => "Array literal exceeds maximum size",
        ValidationError.TooManyParameters => "Function has too many parameters",
        ValidationError.TooManyLocals => "Function has too many local variables",
        ValidationError.TypeNestingTooDeep => "Type nesting exceeds maximum depth",
        ValidationError.TooManyTypeParams => "Too many generic type parameters",
        ValidationError.ImportDepthExceeded => "Import depth exceeded",
        ValidationError.TooManyMatchArms => "Match expression has too many arms",
        ValidationError.TooManyStructFields => "Struct has too many fields",
        ValidationError.TooManyEnumVariants => "Enum has too many variants",
        ValidationError.Timeout => "Operation timed out",
        ValidationError.MemoryLimitExceeded => "Memory limit exceeded",
        ValidationError.InvalidUtf8 => "Input contains invalid UTF-8 encoding",
        ValidationError.NullByteInInput => "Input contains null bytes",
    };
}
