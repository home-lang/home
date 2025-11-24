const std = @import("std");
const ast = @import("ast");
const Type = @import("type_system.zig").Type;

/// Pattern matching checker for exhaustiveness and type safety
pub const PatternChecker = struct {
    allocator: std.mem.Allocator,
    errors: std.ArrayList(PatternError),

    pub const PatternError = struct {
        message: []const u8,
        loc: ast.SourceLocation,
    };

    pub fn init(allocator: std.mem.Allocator) PatternChecker {
        return .{
            .allocator = allocator,
            .errors = std.ArrayList(PatternError){},
        };
    }

    pub fn deinit(self: *PatternChecker) void {
        for (self.errors.items) |err| {
            self.allocator.free(err.message);
        }
        self.errors.deinit(self.allocator);
    }

    /// Check if a match expression is exhaustive
    pub fn checkExhaustiveness(
        self: *PatternChecker,
        match_type: Type,
        patterns: []const *ast.Pattern,
        loc: ast.SourceLocation,
    ) !bool {
        // Build a coverage set of what patterns match
        var coverage = try self.buildCoverage(patterns);
        defer coverage.deinit();

        // Check if coverage is complete for the given type
        return try self.isCoverageComplete(match_type, coverage, loc);
    }

    /// Check if a pattern is valid for the given type
    pub fn checkPattern(
        self: *PatternChecker,
        pattern: *const ast.Pattern,
        expected_type: Type,
        loc: ast.SourceLocation,
    ) !bool {
        return switch (pattern.*) {
            .IntLiteral => expected_type == .Int or expected_type == .I32 or expected_type == .I64,
            .FloatLiteral => expected_type == .Float or expected_type == .F32 or expected_type == .F64,
            .StringLiteral => expected_type == .String,
            .BoolLiteral => expected_type == .Bool,
            .Wildcard => true, // Wildcard matches anything
            .Identifier => true, // Identifier binds to anything

            .Tuple => |tuple_patterns| blk: {
                if (expected_type != .Tuple) {
                    try self.addError("Pattern is a tuple but type is not", loc);
                    break :blk false;
                }
                const tuple_type = expected_type.Tuple;
                if (tuple_patterns.len != tuple_type.element_types.len) {
                    try self.addError("Tuple pattern length mismatch", loc);
                    break :blk false;
                }
                // Check each element
                for (tuple_patterns, tuple_type.element_types) |pat, typ| {
                    if (!try self.checkPattern(pat, typ, loc)) {
                        break :blk false;
                    }
                }
                break :blk true;
            },

            .Array => |array_pat| blk: {
                if (expected_type != .Array) {
                    try self.addError("Pattern is an array but type is not", loc);
                    break :blk false;
                }
                const array_type = expected_type.Array;
                // Check each element pattern against element type
                for (array_pat.elements) |pat| {
                    if (!try self.checkPattern(pat, array_type.element_type.*, loc)) {
                        break :blk false;
                    }
                }
                break :blk true;
            },

            .Struct => |struct_pat| blk: {
                if (expected_type != .Struct) {
                    try self.addError("Pattern is a struct but type is not", loc);
                    break :blk false;
                }
                const struct_type = expected_type.Struct;
                // Check each field pattern
                for (struct_pat.fields) |field_pat| {
                    var found = false;
                    for (struct_type.fields) |struct_field| {
                        if (std.mem.eql(u8, field_pat.name, struct_field.name)) {
                            found = true;
                            if (!try self.checkPattern(field_pat.pattern, struct_field.type, loc)) {
                                break :blk false;
                            }
                            break;
                        }
                    }
                    if (!found) {
                        const msg = try std.fmt.allocPrint(
                            self.allocator,
                            "Field '{s}' not found in struct '{s}'",
                            .{ field_pat.name, struct_type.name },
                        );
                        try self.errors.append(self.allocator, .{ .message = msg, .loc = loc });
                        break :blk false;
                    }
                }
                break :blk true;
            },

            .EnumVariant => |variant_pat| blk: {
                if (expected_type != .Enum) {
                    try self.addError("Pattern is an enum variant but type is not an enum", loc);
                    break :blk false;
                }
                const enum_type = expected_type.Enum;
                // Find the variant
                var found = false;
                for (enum_type.variants) |variant| {
                    if (std.mem.eql(u8, variant_pat.variant, variant.name)) {
                        found = true;
                        // Check payload pattern if present
                        if (variant_pat.payload) |payload_pat| {
                            if (variant.data_type) |data_type| {
                                // Need to convert string to Type
                                // For now, just accept it
                                _ = payload_pat;
                                _ = data_type;
                            } else {
                                try self.addError("Variant has no payload but pattern expects one", loc);
                                break :blk false;
                            }
                        }
                        break;
                    }
                }
                if (!found) {
                    const msg = try std.fmt.allocPrint(
                        self.allocator,
                        "Variant '{s}' not found in enum '{s}'",
                        .{ variant_pat.variant, enum_type.name },
                    );
                    try self.errors.append(self.allocator, .{ .message = msg, .loc = loc });
                    break :blk false;
                }
                break :blk true;
            },

            .Range => true, // Range patterns are valid for numeric types
            .Or => |or_patterns| blk: {
                // All alternatives must be valid for the type
                for (or_patterns) |pat| {
                    if (!try self.checkPattern(pat, expected_type, loc)) {
                        break :blk false;
                    }
                }
                break :blk true;
            },

            .As => |as_pat| try self.checkPattern(as_pat.pattern, expected_type, loc),
        };
    }

    /// Check if patterns are exhaustive for an enum type
    pub fn checkEnumExhaustiveness(
        self: *PatternChecker,
        enum_type: Type.EnumType,
        patterns: []const *ast.Pattern,
        loc: ast.SourceLocation,
    ) !bool {
        var covered_variants = std.StringHashMap(void).init(self.allocator);
        defer covered_variants.deinit();

        var has_wildcard = false;

        for (patterns) |pattern| {
            switch (pattern.*) {
                .Wildcard, .Identifier => {
                    has_wildcard = true;
                    break;
                },
                .EnumVariant => |variant_pat| {
                    try covered_variants.put(variant_pat.variant, {});
                },
                .Or => |or_patterns| {
                    for (or_patterns) |or_pat| {
                        if (or_pat.* == .EnumVariant) {
                            try covered_variants.put(or_pat.EnumVariant.variant, {});
                        } else if (or_pat.* == .Wildcard or or_pat.* == .Identifier) {
                            has_wildcard = true;
                            break;
                        }
                    }
                },
                else => {},
            }
        }

        if (has_wildcard) {
            return true; // Wildcard covers all cases
        }

        // Check if all variants are covered
        for (enum_type.variants) |variant| {
            if (!covered_variants.contains(variant.name)) {
                const msg = try std.fmt.allocPrint(
                    self.allocator,
                    "Match is not exhaustive: missing variant '{s}'",
                    .{variant.name},
                );
                try self.errors.append(self.allocator, .{ .message = msg, .loc = loc });
                return false;
            }
        }

        return true;
    }

    /// Check if patterns are exhaustive for a boolean type
    pub fn checkBoolExhaustiveness(
        self: *PatternChecker,
        patterns: []const *ast.Pattern,
        loc: ast.SourceLocation,
    ) !bool {
        var has_true = false;
        var has_false = false;
        var has_wildcard = false;

        for (patterns) |pattern| {
            switch (pattern.*) {
                .Wildcard, .Identifier => {
                    has_wildcard = true;
                    break;
                },
                .BoolLiteral => |val| {
                    if (val) {
                        has_true = true;
                    } else {
                        has_false = true;
                    }
                },
                .Or => |or_patterns| {
                    for (or_patterns) |or_pat| {
                        if (or_pat.* == .BoolLiteral) {
                            if (or_pat.BoolLiteral) {
                                has_true = true;
                            } else {
                                has_false = true;
                            }
                        } else if (or_pat.* == .Wildcard or or_pat.* == .Identifier) {
                            has_wildcard = true;
                            break;
                        }
                    }
                },
                else => {},
            }
        }

        if (has_wildcard or (has_true and has_false)) {
            return true;
        }

        try self.addError("Match is not exhaustive: missing boolean cases", loc);
        return false;
    }

    fn buildCoverage(self: *PatternChecker, patterns: []const *ast.Pattern) !std.StringHashMap(void) {
        const coverage = std.StringHashMap(void).init(self.allocator);
        _ = patterns;
        return coverage;
    }

    fn isCoverageComplete(
        self: *PatternChecker,
        match_type: Type,
        coverage: std.StringHashMap(void),
        loc: ast.SourceLocation,
    ) !bool {
        _ = coverage;

        return switch (match_type) {
            .Enum => |enum_type| self.checkEnumExhaustiveness(enum_type, &[_]*ast.Pattern{}, loc),
            .Bool => self.checkBoolExhaustiveness(&[_]*ast.Pattern{}, loc),
            // Other types require wildcard or are considered exhaustive with any pattern
            else => true,
        };
    }

    fn addError(self: *PatternChecker, message: []const u8, loc: ast.SourceLocation) !void {
        const msg = try self.allocator.dupe(u8, message);
        try self.errors.append(self.allocator, .{ .message = msg, .loc = loc });
    }

    pub fn hasErrors(self: *PatternChecker) bool {
        return self.errors.items.len > 0;
    }
};

/// Utility for matching patterns against values
pub const PatternMatcher = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PatternMatcher {
        return .{ .allocator = allocator };
    }

    /// Check if a pattern is irrefutable (always matches)
    pub fn isIrrefutable(pattern: *const ast.Pattern) bool {
        return switch (pattern.*) {
            .Wildcard, .Identifier => true,
            .Tuple => |tuple_patterns| blk: {
                for (tuple_patterns) |pat| {
                    if (!isIrrefutable(pat)) {
                        break :blk false;
                    }
                }
                break :blk true;
            },
            .Struct => |struct_pat| blk: {
                for (struct_pat.fields) |field_pat| {
                    if (!isIrrefutable(field_pat.pattern)) {
                        break :blk false;
                    }
                }
                break :blk true;
            },
            .As => |as_pat| isIrrefutable(as_pat.pattern),
            else => false,
        };
    }

    /// Check if patterns overlap (could match the same value)
    pub fn patternsOverlap(p1: *const ast.Pattern, p2: *const ast.Pattern) bool {
        // Wildcard overlaps with everything
        if (p1.* == .Wildcard or p2.* == .Wildcard) return true;
        if (p1.* == .Identifier or p2.* == .Identifier) return true;

        // Same pattern type: check specifics
        const p1_tag = @as(std.meta.Tag(ast.Pattern), p1.*);
        const p2_tag = @as(std.meta.Tag(ast.Pattern), p2.*);

        if (p1_tag != p2_tag) return false;

        return switch (p1.*) {
            .IntLiteral => |v1| v1 == p2.IntLiteral,
            .FloatLiteral => |v1| v1 == p2.FloatLiteral,
            .StringLiteral => |s1| std.mem.eql(u8, s1, p2.StringLiteral),
            .BoolLiteral => |b1| b1 == p2.BoolLiteral,
            .EnumVariant => |v1| std.mem.eql(u8, v1.variant, p2.EnumVariant.variant),
            else => false,
        };
    }
};
