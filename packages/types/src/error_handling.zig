const std = @import("std");
const ast = @import("ast");
const Type = @import("type_system.zig").Type;

/// Error handling system for Result<T, E> types and ? operator
pub const ErrorHandler = struct {
    allocator: std.mem.Allocator,
    errors: std.ArrayList(ErrorInfo),
    /// Track the current function's return type for ? operator validation
    current_function_return: ?Type,

    pub const ErrorInfo = struct {
        message: []const u8,
        loc: ast.SourceLocation,
    };

    pub fn init(allocator: std.mem.Allocator) ErrorHandler {
        return .{
            .allocator = allocator,
            .errors = std.ArrayList(ErrorInfo){},
            .current_function_return = null,
        };
    }

    pub fn deinit(self: *ErrorHandler) void {
        for (self.errors.items) |err| {
            self.allocator.free(err.message);
        }
        self.errors.deinit(self.allocator);
    }

    /// Set the current function's return type
    pub fn enterFunction(self: *ErrorHandler, return_type: Type) void {
        self.current_function_return = return_type;
    }

    /// Clear the current function context
    pub fn exitFunction(self: *ErrorHandler) void {
        self.current_function_return = null;
    }

    /// Check if ? operator can be used with the given Result type
    pub fn checkTryOperator(
        self: *ErrorHandler,
        result_type: Type,
        loc: ast.SourceLocation,
    ) !?Type {
        // Ensure we're in a function context
        const return_type = self.current_function_return orelse {
            try self.addError("Cannot use ? operator outside of function", loc);
            return null;
        };

        // Ensure the operand is a Result type
        if (result_type != .Result) {
            try self.addError("? operator can only be used with Result<T, E> types", loc);
            return null;
        }

        const result_info = result_type.Result;

        // Ensure the function returns a Result type
        if (return_type != .Result) {
            try self.addError("? operator requires function to return Result<T, E>", loc);
            return null;
        }

        const return_result = return_type.Result;

        // Check error type compatibility
        if (!self.errorTypesCompatible(result_info.err_type.*, return_result.err_type.*)) {
            const msg = try std.fmt.allocPrint(
                self.allocator,
                "Error type mismatch: cannot convert from Result<_, E1> to Result<_, E2>",
                .{},
            );
            try self.errors.append(self.allocator, .{ .message = msg, .loc = loc });
            return null;
        }

        // Return the success type (what we get after unwrapping)
        return result_info.ok_type.*;
    }

    /// Check if two error types are compatible for conversion
    fn errorTypesCompatible(self: *ErrorHandler, from: Type, to: Type) bool {
        // Exact match
        if (std.meta.eql(from, to)) return true;

        // String errors are compatible with any string
        if (from == .String and to == .String) return true;

        // Trait-based error conversion (From/Into traits)
        // Check if 'to' implements From<from>
        if (self.implementsFromTrait(to, from)) {
            return true;
        }

        // Check if 'from' implements Into<to>
        if (self.implementsIntoTrait(from, to)) {
            return true;
        }

        return false;
    }

    /// Check if a type implements From<T>
    fn implementsFromTrait(self: *ErrorHandler, target: Type, source: Type) bool {
        _ = target;
        _ = source;
        // Would check trait system for From<Source> implementation on Target
        // For now, return false (not implemented)
        _ = self; // Needed for future trait system access
        return false;
    }

    /// Check if a type implements Into<T>
    fn implementsIntoTrait(self: *ErrorHandler, source: Type, target: Type) bool {
        _ = source;
        _ = target;
        // Would check trait system for Into<Target> implementation on Source
        // For now, return false (not implemented)
        _ = self; // Needed for future trait system access
        return false;
    }

    /// Infer the error type from multiple Result types
    pub fn inferErrorType(
        self: *ErrorHandler,
        result_types: []const Type,
        loc: ast.SourceLocation,
    ) !?Type {
        if (result_types.len == 0) return null;

        // Start with the first error type
        const common_error = result_types[0].Result.err_type.*;

        // Try to find a common error type
        for (result_types[1..]) |result_type| {
            if (result_type != .Result) continue;

            const err_type = result_type.Result.err_type.*;

            if (!self.errorTypesCompatible(err_type, common_error)) {
                try self.addError("Incompatible error types in Result expressions", loc);
                return null;
            }
        }

        return common_error;
    }

    /// Create a Result type
    pub fn makeResultType(
        self: *ErrorHandler,
        ok_type: Type,
        err_type: Type,
    ) !*Type {
        const ok_ptr = try self.allocator.create(Type);
        ok_ptr.* = ok_type;

        const err_ptr = try self.allocator.create(Type);
        err_ptr.* = err_type;

        const result_ptr = try self.allocator.create(Type);
        result_ptr.* = .{
            .Result = .{
                .ok_type = ok_ptr,
                .err_type = err_ptr,
            },
        };

        return result_ptr;
    }

    fn addError(self: *ErrorHandler, message: []const u8, loc: ast.SourceLocation) !void {
        const msg = try self.allocator.dupe(u8, message);
        try self.errors.append(self.allocator, .{ .message = msg, .loc = loc });
    }

    pub fn hasErrors(self: *ErrorHandler) bool {
        return self.errors.items.len > 0;
    }
};

/// Error conversion utilities
pub const ErrorConversion = struct {
    /// Check if an error type implements From<E> for conversion
    pub fn canConvertError(from: Type, to: Type) bool {
        // Exact match
        if (std.meta.eql(from, to)) return true;

        // String to string
        if (from == .String and to == .String) return true;

        // Check if 'to' implements From<from>
        // This would require access to trait system
        // For now, just check for basic conversions
        return checkBasicErrorConversion(from, to);
    }

    /// Check basic error conversions without traits
    fn checkBasicErrorConversion(from: Type, to: Type) bool {
        // Allow any error to convert to String
        if (to == .String) return true;

        // Would check trait implementations here
        _ = from;
        return false;
    }

    /// Generate error conversion code
    pub fn convertError(from: Type, to: Type) ?[]const u8 {
        // Generate conversion code based on From trait
        // For String conversion
        if (to == .String) {
            _ = from;
            return ".to_string()"; // Would generate proper conversion
        }

        // For other conversions, would generate From trait call
        // e.g., "Error::from(err)"
        _ = from;
        return null;
    }
};

/// Result type utilities
pub const ResultUtils = struct {
    /// Check if a type is a Result<T, E>
    pub fn isResult(typ: Type) bool {
        return typ == .Result;
    }

    /// Extract the Ok type from Result<T, E>
    pub fn getOkType(result_type: Type) ?*const Type {
        if (result_type != .Result) return null;
        return result_type.Result.ok_type;
    }

    /// Extract the Err type from Result<T, E>
    pub fn getErrType(result_type: Type) ?*const Type {
        if (result_type != .Result) return null;
        return result_type.Result.err_type;
    }

    /// Check if all paths in a function return Result types
    pub fn allPathsReturnResult(function_body: *const ast.BlockStmt) bool {
        // Analyze control flow to ensure all paths return Result
        return analyzeBlockReturns(function_body);
    }

    /// Analyze if a block returns on all paths
    fn analyzeBlockReturns(block: *const ast.BlockStmt) bool {
        for (block.statements) |stmt| {
            switch (stmt) {
                .ReturnStmt => return true,
                .IfStmt => |if_stmt| {
                    // If statement returns on all paths only if both branches return
                    const then_returns = analyzeBlockReturns(&if_stmt.then_block);
                    const else_returns = if (if_stmt.else_block) |else_block|
                        analyzeBlockReturns(&else_block)
                    else
                        false;

                    if (then_returns and else_returns) return true;
                },
                .WhileStmt, .ForStmt => {
                    // Loops don't guarantee return (can be empty or break)
                    continue;
                },
                .MatchStmt => |match_stmt| {
                    // Match returns on all paths if all arms return
                    var all_arms_return = true;
                    for (match_stmt.arms) |arm| {
                        if (!analyzeBlockReturns(&arm.body)) {
                            all_arms_return = false;
                            break;
                        }
                    }
                    if (all_arms_return and match_stmt.arms.len > 0) return true;
                },
                else => continue,
            }
        }
        return false;
    }
};
