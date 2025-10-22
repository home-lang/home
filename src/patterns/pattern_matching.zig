const std = @import("std");
const ast = @import("../ast/ast.zig");
const types = @import("../types/type_system.zig");

/// Pattern types for match expressions
pub const Pattern = union(enum) {
    Wildcard: WildcardPattern, // _
    Literal: LiteralPattern, // 42, "hello", true
    Variable: VariablePattern, // x
    Struct: StructPattern, // Point { x, y }
    Tuple: TuplePattern, // (x, y, z)
    Enum: EnumPattern, // Some(x), None
    Range: RangePattern, // 1..10
    Or: OrPattern, // A | B
    Guard: GuardPattern, // x if x > 10

    pub fn getLocation(self: Pattern) ast.SourceLocation {
        return switch (self) {
            .Wildcard => |p| p.loc,
            .Literal => |p| p.loc,
            .Variable => |p| p.loc,
            .Struct => |p| p.loc,
            .Tuple => |p| p.loc,
            .Enum => |p| p.loc,
            .Range => |p| p.loc,
            .Or => |p| p.loc,
            .Guard => |p| p.loc,
        };
    }
};

pub const WildcardPattern = struct {
    loc: ast.SourceLocation,
};

pub const LiteralPattern = struct {
    value: ast.Expr,
    loc: ast.SourceLocation,
};

pub const VariablePattern = struct {
    name: []const u8,
    mutable: bool,
    loc: ast.SourceLocation,
};

pub const StructPattern = struct {
    struct_name: []const u8,
    fields: []FieldPattern,
    rest: bool, // true if using .. to ignore remaining fields
    loc: ast.SourceLocation,
};

pub const FieldPattern = struct {
    name: []const u8,
    pattern: *Pattern,
};

pub const TuplePattern = struct {
    elements: []*Pattern,
    loc: ast.SourceLocation,
};

pub const EnumPattern = struct {
    enum_name: []const u8,
    variant: []const u8,
    inner_pattern: ?*Pattern,
    loc: ast.SourceLocation,
};

pub const RangePattern = struct {
    start: ast.Expr,
    end: ast.Expr,
    inclusive: bool,
    loc: ast.SourceLocation,
};

pub const OrPattern = struct {
    patterns: []*Pattern,
    loc: ast.SourceLocation,
};

pub const GuardPattern = struct {
    pattern: *Pattern,
    guard: ast.Expr,
    loc: ast.SourceLocation,
};

/// Match arm containing pattern and body
pub const MatchArm = struct {
    pattern: Pattern,
    body: ast.Expr,
    loc: ast.SourceLocation,
};

/// Match expression
pub const MatchExpr = struct {
    scrutinee: ast.Expr, // The value being matched
    arms: []MatchArm,
    loc: ast.SourceLocation,
};

/// Pattern matching checker for exhaustiveness and reachability
pub const PatternChecker = struct {
    allocator: std.mem.Allocator,
    errors: std.ArrayList(PatternError),
    warnings: std.ArrayList(PatternWarning),

    pub fn init(allocator: std.mem.Allocator) PatternChecker {
        return .{
            .allocator = allocator,
            .errors = std.ArrayList(PatternError).init(allocator),
            .warnings = std.ArrayList(PatternWarning).init(allocator),
        };
    }

    pub fn deinit(self: *PatternChecker) void {
        self.errors.deinit();
        self.warnings.deinit();
    }

    /// Check if a match expression is exhaustive
    pub fn checkExhaustiveness(self: *PatternChecker, match_expr: *MatchExpr, scrutinee_type: types.Type) !bool {
        // Build a coverage matrix of which patterns are covered
        var covered = PatternCoverage.init(self.allocator);
        defer covered.deinit();

        for (match_expr.arms) |*arm| {
            try covered.addPattern(arm.pattern);
        }

        // Check if all possible values of the type are covered
        const is_exhaustive = try self.isTypeFullyCovered(scrutinee_type, &covered);

        if (!is_exhaustive) {
            try self.addError(.{
                .kind = .NonExhaustiveMatch,
                .message = try std.fmt.allocPrint(
                    self.allocator,
                    "match expression is not exhaustive",
                    .{},
                ),
                .loc = match_expr.loc,
                .missing_patterns = try self.findMissingPatterns(scrutinee_type, &covered),
            });
        }

        return is_exhaustive;
    }

    /// Check for unreachable patterns
    pub fn checkReachability(self: *PatternChecker, match_expr: *MatchExpr) !void {
        var i: usize = 0;
        while (i < match_expr.arms.len) : (i += 1) {
            const arm = &match_expr.arms[i];

            // Check if this pattern is already covered by previous patterns
            var j: usize = 0;
            while (j < i) : (j += 1) {
                const prev_arm = &match_expr.arms[j];

                if (try self.isPatternSubsumed(arm.pattern, prev_arm.pattern)) {
                    try self.addWarning(.{
                        .kind = .UnreachablePattern,
                        .message = try std.fmt.allocPrint(
                            self.allocator,
                            "unreachable pattern (already covered by previous pattern)",
                            .{},
                        ),
                        .loc = arm.loc,
                    });
                    break;
                }
            }
        }
    }

    /// Check if pattern A is subsumed by pattern B (B covers all cases of A)
    fn isPatternSubsumed(self: *PatternChecker, a: Pattern, b: Pattern) !bool {
        _ = self;

        // Wildcard subsumes everything
        if (b == .Wildcard) return true;

        // Same pattern kind checks
        return switch (a) {
            .Wildcard => false,
            .Literal => |lit_a| switch (b) {
                .Literal => |lit_b| self.literalsEqual(lit_a.value, lit_b.value),
                else => false,
            },
            .Variable => true, // Variable patterns are subsumed by wildcard (checked above)
            .Enum => |enum_a| switch (b) {
                .Enum => |enum_b| std.mem.eql(u8, enum_a.variant, enum_b.variant),
                else => false,
            },
            else => false,
        };
    }

    /// Check if a type is fully covered by patterns
    fn isTypeFullyCovered(self: *PatternChecker, typ: types.Type, coverage: *PatternCoverage) !bool {
        // Wildcard pattern covers everything
        if (coverage.has_wildcard) return true;

        return switch (typ) {
            .Bool => coverage.covered_bools.len == 2,
            .Int => coverage.has_wildcard or coverage.has_range_covering_all,
            .Float => coverage.has_wildcard,
            .String => coverage.has_wildcard,
            .Void => true,
            else => coverage.has_wildcard,
        };
    }

    /// Find missing patterns for better error messages
    fn findMissingPatterns(self: *PatternChecker, typ: types.Type, coverage: *PatternCoverage) ![][]const u8 {
        var missing = std.ArrayList([]const u8).init(self.allocator);

        switch (typ) {
            .Bool => {
                if (!coverage.isBoolCovered(true)) {
                    try missing.append("true");
                }
                if (!coverage.isBoolCovered(false)) {
                    try missing.append("false");
                }
            },
            else => {
                if (!coverage.has_wildcard) {
                    try missing.append("_");
                }
            },
        }

        return missing.toOwnedSlice();
    }

    fn literalsEqual(self: *PatternChecker, a: ast.Expr, b: ast.Expr) bool {
        _ = self;
        // Simplified literal comparison
        // In reality, would need to evaluate constant expressions
        return false;
    }

    fn addError(self: *PatternChecker, err: PatternError) !void {
        try self.errors.append(err);
    }

    fn addWarning(self: *PatternChecker, warning: PatternWarning) !void {
        try self.warnings.append(warning);
    }
};

/// Track which patterns have been covered
const PatternCoverage = struct {
    allocator: std.mem.Allocator,
    has_wildcard: bool,
    covered_bools: std.ArrayList(bool),
    covered_ints: std.ArrayList(i64),
    covered_strings: std.ArrayList([]const u8),
    has_range_covering_all: bool,

    pub fn init(allocator: std.mem.Allocator) PatternCoverage {
        return .{
            .allocator = allocator,
            .has_wildcard = false,
            .covered_bools = std.ArrayList(bool).init(allocator),
            .covered_ints = std.ArrayList(i64).init(allocator),
            .covered_strings = std.ArrayList([]const u8).init(allocator),
            .has_range_covering_all = false,
        };
    }

    pub fn deinit(self: *PatternCoverage) void {
        self.covered_bools.deinit();
        self.covered_ints.deinit();
        self.covered_strings.deinit();
    }

    pub fn addPattern(self: *PatternCoverage, pattern: Pattern) !void {
        switch (pattern) {
            .Wildcard => self.has_wildcard = true,
            .Variable => self.has_wildcard = true, // Variable bindings match everything
            .Literal => |lit| {
                // Would need to evaluate literal and add to appropriate list
                _ = lit;
            },
            .Range => {
                // Check if range covers all possible values
                // This is simplified; real implementation would be more complex
            },
            else => {},
        }
    }

    pub fn isBoolCovered(self: *PatternCoverage, value: bool) bool {
        for (self.covered_bools.items) |covered| {
            if (covered == value) return true;
        }
        return false;
    }
};

/// Pattern matching errors
pub const PatternError = struct {
    kind: PatternErrorKind,
    message: []const u8,
    loc: ast.SourceLocation,
    missing_patterns: [][]const u8,
};

pub const PatternErrorKind = enum {
    NonExhaustiveMatch,
    InvalidPattern,
    TypeMismatch,
    DuplicateBinding,
};

/// Pattern matching warnings
pub const PatternWarning = struct {
    kind: PatternWarningKind,
    message: []const u8,
    loc: ast.SourceLocation,
};

pub const PatternWarningKind = enum {
    UnreachablePattern,
    UselessGuard,
};

/// Pattern compiler for lowering patterns to conditional checks
pub const PatternCompiler = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PatternCompiler {
        return .{ .allocator = allocator };
    }

    /// Compile a pattern into a decision tree
    pub fn compile(self: *PatternCompiler, match_expr: *MatchExpr) !DecisionTree {
        _ = self;
        _ = match_expr;
        // This would generate an efficient decision tree for pattern matching
        // For now, return a placeholder
        return DecisionTree{ .arms = &[_]CompiledArm{} };
    }
};

/// Compiled decision tree for efficient pattern matching
pub const DecisionTree = struct {
    arms: []CompiledArm,
};

pub const CompiledArm = struct {
    conditions: []Condition,
    bindings: []Binding,
    body_index: usize,
};

pub const Condition = struct {
    kind: ConditionKind,
};

pub const ConditionKind = enum {
    TypeCheck,
    ValueCheck,
    RangeCheck,
    VariantCheck,
};

pub const Binding = struct {
    name: []const u8,
    source: []const u8,
};
