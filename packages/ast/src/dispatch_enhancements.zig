const std = @import("std");
const dispatch_nodes = @import("dispatch_nodes.zig");
const DispatchTable = dispatch_nodes.DispatchTable;
const DispatchEntry = DispatchTable.DispatchEntry;

/// Enhanced type checking for multiple dispatch
/// Implements specificity ordering and subtype relationship checking

/// Type relationship result
pub const TypeRelation = enum {
    Exact,          // Types are exactly the same
    Subtype,        // Argument is subtype of parameter
    Supertype,      // Argument is supertype of parameter (invalid)
    Unrelated,      // No relationship between types
    Compatible,     // Convertible (e.g., int literals to sized ints)
};

/// Specificity score for dispatch resolution
/// Higher scores indicate more specific signatures
pub const SpecificityScore = struct {
    exact_matches: u32,
    subtype_matches: u32,
    generic_matches: u32,
    any_matches: u32,

    pub fn init() SpecificityScore {
        return .{
            .exact_matches = 0,
            .subtype_matches = 0,
            .generic_matches = 0,
            .any_matches = 0,
        };
    }

    /// Compare two specificity scores
    /// Returns true if self is more specific than other
    pub fn isMoreSpecificThan(self: SpecificityScore, other: SpecificityScore) bool {
        // Exact matches are most important
        if (self.exact_matches != other.exact_matches) {
            return self.exact_matches > other.exact_matches;
        }

        // Then subtype matches
        if (self.subtype_matches != other.subtype_matches) {
            return self.subtype_matches > other.subtype_matches;
        }

        // Then generic matches
        if (self.generic_matches != other.generic_matches) {
            return self.generic_matches > other.generic_matches;
        }

        // Finally any matches (least specific)
        return self.any_matches < other.any_matches;
    }

    pub fn total(self: SpecificityScore) u32 {
        return self.exact_matches + self.subtype_matches + self.generic_matches + self.any_matches;
    }
};

/// Enhanced type checker with subtype relationships
pub const TypeChecker = struct {
    allocator: std.mem.Allocator,
    /// Cache of known type relationships
    type_hierarchy: std.StringHashMap(std.ArrayList([]const u8)),

    pub fn init(allocator: std.mem.Allocator) TypeChecker {
        return .{
            .allocator = allocator,
            .type_hierarchy = std.StringHashMap(std.ArrayList([]const u8)).init(allocator),
        };
    }

    pub fn deinit(self: *TypeChecker) void {
        var it = self.type_hierarchy.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.type_hierarchy.deinit();
    }

    /// Register a subtype relationship
    /// For example: registerSubtype("i32", "i64") means i32 can be used where i64 is expected
    pub fn registerSubtype(self: *TypeChecker, subtype: []const u8, supertype: []const u8) !void {
        var gop = try self.type_hierarchy.getOrPut(subtype);
        if (!gop.found_existing) {
            gop.value_ptr.* = std.ArrayList([]const u8).fromOwnedSlice(&[_][]const u8{});
        }
        try gop.value_ptr.append(self.allocator, supertype);
    }

    /// Check the relationship between two types
    pub fn checkTypeRelation(self: *TypeChecker, param_type: []const u8, arg_type: []const u8) TypeRelation {
        // Exact match
        if (std.mem.eql(u8, param_type, arg_type)) {
            return .Exact;
        }

        // Check if arg_type is a subtype of param_type
        if (self.isSubtype(arg_type, param_type)) {
            return .Subtype;
        }

        // Check if arg_type is a supertype (would be invalid)
        if (self.isSubtype(param_type, arg_type)) {
            return .Supertype;
        }

        // Check built-in numeric conversions
        if (self.isNumericConversion(arg_type, param_type)) {
            return .Subtype;
        }

        // Check for compatible generic types
        if (self.areGenericsCompatible(param_type, arg_type)) {
            return .Compatible;
        }

        return .Unrelated;
    }

    /// Check if subtype can be used where supertype is expected
    fn isSubtype(self: *TypeChecker, subtype: []const u8, supertype: []const u8) bool {
        // Direct lookup
        if (self.type_hierarchy.get(subtype)) |supertypes| {
            for (supertypes.items) |st| {
                if (std.mem.eql(u8, st, supertype)) {
                    return true;
                }
                // Transitive check: if subtype < intermediate < supertype
                if (self.isSubtype(st, supertype)) {
                    return true;
                }
            }
        }
        return false;
    }

    /// Check if types are numeric and convertible
    fn isNumericConversion(self: *TypeChecker, from: []const u8, to: []const u8) bool {
        _ = self;

        // Signed integer hierarchy: i8 < i16 < i32 < i64
        const signed_ints = [_][]const u8{ "i8", "i16", "i32", "i64" };
        const from_idx = indexOfType(from, &signed_ints);
        const to_idx = indexOfType(to, &signed_ints);

        if (from_idx != null and to_idx != null) {
            return from_idx.? < to_idx.?;
        }

        // Unsigned integer hierarchy: u8 < u16 < u32 < u64
        const unsigned_ints = [_][]const u8{ "u8", "u16", "u32", "u64" };
        const from_uidx = indexOfType(from, &unsigned_ints);
        const to_uidx = indexOfType(to, &unsigned_ints);

        if (from_uidx != null and to_uidx != null) {
            return from_uidx.? < to_uidx.?;
        }

        // Float hierarchy: f32 < f64
        if (std.mem.eql(u8, from, "f32") and std.mem.eql(u8, to, "f64")) {
            return true;
        }

        return false;
    }

    /// Check if generic types are compatible (e.g., Vec<T> with Vec<i32>)
    fn areGenericsCompatible(self: *TypeChecker, param_type: []const u8, arg_type: []const u8) bool {
        _ = self;

        // Extract base type and parameters
        // Option<T> matches Option<i32>
        if (std.mem.indexOf(u8, param_type, "<")) |param_open| {
            if (std.mem.indexOf(u8, arg_type, "<")) |arg_open| {
                const param_base = param_type[0..param_open];
                const arg_base = arg_type[0..arg_open];

                // Base types must match
                if (!std.mem.eql(u8, param_base, arg_base)) {
                    return false;
                }

                // For now, accept any compatible generic instantiation
                // Full implementation would recursively check type parameters
                return true;
            }
        }

        return false;
    }

    fn indexOfType(ty: []const u8, types: []const []const u8) ?usize {
        for (types, 0..) |t, i| {
            if (std.mem.eql(u8, ty, t)) {
                return i;
            }
        }
        return null;
    }
};

/// Calculate specificity score for a dispatch signature
pub fn calculateSpecificity(
    type_checker: *TypeChecker,
    signature: []const []const u8,
    arg_types: []const []const u8,
) !SpecificityScore {
    var score = SpecificityScore.init();

    if (signature.len != arg_types.len) {
        return score; // Signature doesn't match
    }

    for (signature, arg_types) |sig_type, arg_type| {
        const relation = type_checker.checkTypeRelation(sig_type, arg_type);

        switch (relation) {
            .Exact => score.exact_matches += 1,
            .Subtype, .Compatible => score.subtype_matches += 1,
            .Supertype, .Unrelated => {
                // Invalid match
                return SpecificityScore.init();
            },
        }

        // Check for generic or Any types
        if (std.mem.eql(u8, sig_type, "Any")) {
            score.any_matches += 1;
        } else if (sig_type.len == 1 and sig_type[0] >= 'A' and sig_type[0] <= 'Z') {
            // Single uppercase letter = generic parameter
            score.generic_matches += 1;
        }
    }

    return score;
}

/// Find the most specific matching dispatch variant
pub fn findMostSpecificVariant(
    type_checker: *TypeChecker,
    dispatch_table: *DispatchTable,
    arg_types: []const []const u8,
) !?usize {
    var best_variant: ?usize = null;
    var best_score = SpecificityScore.init();
    var found_any = false;

    for (dispatch_table.entries.items, 0..) |entry, index| {
        const score = try calculateSpecificity(type_checker, entry.signature, arg_types);

        // Skip if no matches
        if (score.total() == 0) {
            continue;
        }

        if (!found_any or score.isMoreSpecificThan(best_score)) {
            best_variant = index;
            best_score = score;
            found_any = true;
        }
    }

    return if (found_any) best_variant else null;
}

/// Check for ambiguous dispatch
/// Returns true if multiple variants have the same specificity
pub fn checkAmbiguousDispatch(
    type_checker: *TypeChecker,
    dispatch_table: *DispatchTable,
    arg_types: []const []const u8,
) !bool {
    var candidates = std.ArrayList(SpecificityScore).fromOwnedSlice(&[_]SpecificityScore{});
    defer candidates.deinit(type_checker.allocator);

    for (dispatch_table.entries.items) |entry| {
        const score = try calculateSpecificity(type_checker, entry.signature, arg_types);
        if (score.total() > 0) {
            try candidates.append(type_checker.allocator, score);
        }
    }

    if (candidates.items.len <= 1) {
        return false;
    }

    // Check if any two candidates have the same specificity
    for (candidates.items, 0..) |score1, i| {
        for (candidates.items[i + 1 ..]) |score2| {
            if (!score1.isMoreSpecificThan(score2) and !score2.isMoreSpecificThan(score1)) {
                // Equal specificity = ambiguous
                return true;
            }
        }
    }

    return false;
}

/// Trait implementation checking
pub const TraitChecker = struct {
    allocator: std.mem.Allocator,
    /// Map from type name to implemented traits
    type_traits: std.StringHashMap(std.ArrayList([]const u8)),

    pub fn init(allocator: std.mem.Allocator) TraitChecker {
        return .{
            .allocator = allocator,
            .type_traits = std.StringHashMap(std.ArrayList([]const u8)).init(allocator),
        };
    }

    pub fn deinit(self: *TraitChecker) void {
        var it = self.type_traits.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.type_traits.deinit();
    }

    /// Register that a type implements a trait
    pub fn registerTrait(self: *TraitChecker, type_name: []const u8, trait_name: []const u8) !void {
        var gop = try self.type_traits.getOrPut(type_name);
        if (!gop.found_existing) {
            gop.value_ptr.* = std.ArrayList([]const u8).fromOwnedSlice(&[_][]const u8{});
        }
        try gop.value_ptr.append(self.allocator, trait_name);
    }

    /// Check if a type implements a trait
    pub fn implementsTrait(self: *TraitChecker, type_name: []const u8, trait_name: []const u8) bool {
        if (self.type_traits.get(type_name)) |traits| {
            for (traits.items) |t| {
                if (std.mem.eql(u8, t, trait_name)) {
                    return true;
                }
            }
        }
        return false;
    }
};

// Tests

test "TypeChecker - numeric hierarchy" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var checker = TypeChecker.init(allocator);
    defer checker.deinit();

    // i8 < i16 < i32 < i64
    try testing.expectEqual(TypeRelation.Exact, checker.checkTypeRelation("i32", "i32"));
    try testing.expectEqual(TypeRelation.Subtype, checker.checkTypeRelation("i64", "i8"));
    try testing.expectEqual(TypeRelation.Subtype, checker.checkTypeRelation("i64", "i16"));
    try testing.expectEqual(TypeRelation.Subtype, checker.checkTypeRelation("i64", "i32"));

    // Unsigned hierarchy
    try testing.expectEqual(TypeRelation.Subtype, checker.checkTypeRelation("u64", "u8"));
    try testing.expectEqual(TypeRelation.Subtype, checker.checkTypeRelation("u32", "u16"));

    // Float hierarchy
    try testing.expectEqual(TypeRelation.Subtype, checker.checkTypeRelation("f64", "f32"));
}

test "TypeChecker - custom subtypes" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var checker = TypeChecker.init(allocator);
    defer checker.deinit();

    // Register: Circle < Shape
    try checker.registerSubtype("Circle", "Shape");
    try checker.registerSubtype("Rectangle", "Shape");

    try testing.expectEqual(TypeRelation.Subtype, checker.checkTypeRelation("Shape", "Circle"));
    try testing.expectEqual(TypeRelation.Subtype, checker.checkTypeRelation("Shape", "Rectangle"));
    try testing.expectEqual(TypeRelation.Unrelated, checker.checkTypeRelation("Circle", "Rectangle"));
}

test "SpecificityScore - ordering" {
    const testing = std.testing;

    var score1 = SpecificityScore.init();
    score1.exact_matches = 2;
    score1.subtype_matches = 0;

    var score2 = SpecificityScore.init();
    score2.exact_matches = 1;
    score2.subtype_matches = 1;

    try testing.expect(score1.isMoreSpecificThan(score2));
    try testing.expect(!score2.isMoreSpecificThan(score1));
}

test "calculateSpecificity - exact match" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var checker = TypeChecker.init(allocator);
    defer checker.deinit();

    const signature = [_][]const u8{ "i32", "String", "bool" };
    const arg_types = [_][]const u8{ "i32", "String", "bool" };

    const score = try calculateSpecificity(&checker, &signature, &arg_types);
    try testing.expectEqual(@as(u32, 3), score.exact_matches);
    try testing.expectEqual(@as(u32, 0), score.subtype_matches);
}

test "calculateSpecificity - with subtypes" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var checker = TypeChecker.init(allocator);
    defer checker.deinit();

    const signature = [_][]const u8{ "i64", "String" };
    const arg_types = [_][]const u8{ "i32", "String" };

    const score = try calculateSpecificity(&checker, &signature, &arg_types);
    try testing.expectEqual(@as(u32, 1), score.exact_matches);
    try testing.expectEqual(@as(u32, 1), score.subtype_matches);
}

test "TraitChecker - implementation check" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var checker = TraitChecker.init(allocator);
    defer checker.deinit();

    try checker.registerTrait("String", "Display");
    try checker.registerTrait("String", "Debug");
    try checker.registerTrait("i32", "Display");

    try testing.expect(checker.implementsTrait("String", "Display"));
    try testing.expect(checker.implementsTrait("String", "Debug"));
    try testing.expect(checker.implementsTrait("i32", "Display"));
    try testing.expect(!checker.implementsTrait("i32", "Debug"));
}
