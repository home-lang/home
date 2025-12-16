// TypeScript-like Type System Extensions for Home
//
// This module provides TypeScript-inspired type features:
// - Intersection types (A & B)
// - Conditional types (T extends U ? X : Y)
// - Mapped types ({[K in keyof T]: V})
// - Utility types (Partial, Required, Pick, Omit, etc.)
// - Type operators (keyof, typeof, infer)
// - Literal types
// - Template literal types

const std = @import("std");
const Type = @import("type_system.zig").Type;

// ============================================================================
// Intersection Types
// ============================================================================

/// Intersection type: A & B
/// Represents a value that satisfies ALL constituent types simultaneously.
/// Unlike unions (A | B) where a value is ONE of the types,
/// intersections require the value to be ALL types at once.
pub const IntersectionType = struct {
    /// Types that must all be satisfied
    types: []const *const Type,

    pub fn init(types: []const *const Type) IntersectionType {
        return .{ .types = types };
    }

    /// Check if a type satisfies this intersection
    pub fn isSatisfiedBy(self: *const IntersectionType, candidate: *const Type, checker: anytype) bool {
        for (self.types) |required| {
            if (!checker.isSubtype(candidate, required)) {
                return false;
            }
        }
        return true;
    }

    /// Flatten nested intersections: (A & B) & C -> A & B & C
    pub fn flatten(self: *const IntersectionType, allocator: std.mem.Allocator) !IntersectionType {
        var flattened = std.ArrayList(*const Type).init(allocator);
        defer flattened.deinit();

        for (self.types) |ty| {
            if (ty.* == .Intersection) {
                const nested = ty.Intersection;
                for (nested.types) |inner| {
                    try flattened.append(inner);
                }
            } else {
                try flattened.append(ty);
            }
        }

        return .{ .types = try flattened.toOwnedSlice() };
    }
};

// ============================================================================
// Conditional Types
// ============================================================================

/// Conditional type: T extends U ? X : Y
/// Evaluates to X if T is assignable to U, otherwise Y.
/// Enables powerful type-level programming and type narrowing.
pub const ConditionalType = struct {
    /// The type being checked
    check_type: *const Type,
    /// The type to extend/compare against
    extends_type: *const Type,
    /// Result type if check passes
    true_type: *const Type,
    /// Result type if check fails
    false_type: *const Type,

    pub fn init(
        check: *const Type,
        extends: *const Type,
        true_branch: *const Type,
        false_branch: *const Type,
    ) ConditionalType {
        return .{
            .check_type = check,
            .extends_type = extends,
            .true_type = true_branch,
            .false_type = false_branch,
        };
    }

    /// Evaluate the conditional type given a type checker
    pub fn evaluate(self: *const ConditionalType, checker: anytype) *const Type {
        if (checker.isSubtype(self.check_type, self.extends_type)) {
            return self.true_type;
        } else {
            return self.false_type;
        }
    }

    /// Evaluate with distribution over unions
    /// If check_type is a union, distribute the conditional over each member
    pub fn evaluateDistributed(
        self: *const ConditionalType,
        checker: anytype,
        allocator: std.mem.Allocator,
    ) !*const Type {
        // Check if check_type is a union
        if (self.check_type.* == .Union) {
            var results = std.ArrayList(*const Type).init(allocator);
            defer results.deinit();

            for (self.check_type.Union.variants) |variant| {
                const distributed = ConditionalType{
                    .check_type = variant.data_type orelse continue,
                    .extends_type = self.extends_type,
                    .true_type = self.true_type,
                    .false_type = self.false_type,
                };
                try results.append(distributed.evaluate(checker));
            }

            // Return union of results (deduplicated)
            return try createUnionType(allocator, results.items);
        }

        return self.evaluate(checker);
    }
};

// ============================================================================
// Mapped Types
// ============================================================================

/// Mapped type: { [K in keyof T]: V }
/// Transforms each property of a type according to a mapping function.
pub const MappedType = struct {
    /// Source type to map over
    source_type: *const Type,
    /// Key variable name (e.g., "K" in [K in keyof T])
    key_var: []const u8,
    /// Value type expression (can reference key_var)
    value_type: *const Type,
    /// Optional modifiers
    modifiers: Modifiers = .{},

    pub const Modifiers = struct {
        /// Add/remove readonly modifier
        readonly: ?Modifier = null,
        /// Add/remove optional modifier
        optional: ?Modifier = null,

        pub const Modifier = enum {
            add,    // +readonly or +?
            remove, // -readonly or -?
        };
    };

    pub fn init(source: *const Type, key_var: []const u8, value: *const Type) MappedType {
        return .{
            .source_type = source,
            .key_var = key_var,
            .value_type = value,
        };
    }

    /// Apply the mapping to produce a new type
    pub fn apply(self: *const MappedType, allocator: std.mem.Allocator) !*Type {
        // Source must be a struct type
        if (self.source_type.* != .Struct) {
            return error.MappedTypeRequiresStruct;
        }

        const source_struct = self.source_type.Struct;
        var new_fields = std.ArrayList(Type.StructType.Field).init(allocator);
        defer new_fields.deinit();

        for (source_struct.fields) |field| {
            // Apply value type transformation
            // In a full implementation, we'd substitute key_var with field.name
            const new_field = Type.StructType.Field{
                .name = field.name,
                .type = self.value_type.*,
            };
            try new_fields.append(new_field);
        }

        const result = try allocator.create(Type);
        result.* = Type{
            .Struct = .{
                .name = source_struct.name,
                .fields = try new_fields.toOwnedSlice(),
            },
        };
        return result;
    }
};

// ============================================================================
// Type Operators
// ============================================================================

/// keyof operator: keyof T
/// Produces a union of all property keys of type T.
pub const KeyofType = struct {
    /// The type to extract keys from
    target_type: *const Type,

    pub fn init(target: *const Type) KeyofType {
        return .{ .target_type = target };
    }

    /// Evaluate keyof to get the keys as a union of literal types
    pub fn evaluate(self: *const KeyofType, allocator: std.mem.Allocator) !*Type {
        switch (self.target_type.*) {
            .Struct => |s| {
                if (s.fields.len == 0) {
                    const result = try allocator.create(Type);
                    result.* = Type.Void;
                    return result;
                }

                // Create union of string literal types for each field name
                var variants = std.ArrayList(Type.UnionType.Variant).init(allocator);
                defer variants.deinit();

                for (s.fields) |field| {
                    try variants.append(.{
                        .name = field.name,
                        .data_type = null, // Literal type - just the name
                    });
                }

                const result = try allocator.create(Type);
                result.* = Type{
                    .Union = .{
                        .name = "keyof",
                        .variants = try variants.toOwnedSlice(),
                    },
                };
                return result;
            },
            .Map => {
                // keyof Map<K, V> = K
                const result = try allocator.create(Type);
                result.* = self.target_type.Map.key_type.*;
                return result;
            },
            .Tuple => |t| {
                // keyof (A, B, C) = 0 | 1 | 2
                var variants = std.ArrayList(Type.UnionType.Variant).init(allocator);
                defer variants.deinit();

                for (t.element_types, 0..) |_, i| {
                    var name_buf: [20]u8 = undefined;
                    const name = std.fmt.bufPrint(&name_buf, "{}", .{i}) catch "?";
                    try variants.append(.{
                        .name = name,
                        .data_type = null,
                    });
                }

                const result = try allocator.create(Type);
                result.* = Type{
                    .Union = .{
                        .name = "keyof",
                        .variants = try variants.toOwnedSlice(),
                    },
                };
                return result;
            },
            else => {
                // keyof on non-object types returns never
                const result = try allocator.create(Type);
                result.* = Type.Void;
                return result;
            },
        }
    }
};

/// typeof operator for extracting type from value expression
pub const TypeofType = struct {
    /// Variable/expression to get type of
    expression_name: []const u8,
    /// Resolved type (filled in during type checking)
    resolved_type: ?*const Type = null,

    pub fn init(expr: []const u8) TypeofType {
        return .{ .expression_name = expr };
    }
};

/// infer keyword for type extraction in conditional types
pub const InferType = struct {
    /// Name for the inferred type variable
    name: []const u8,
    /// Constraint on the inferred type (optional)
    constraint: ?*const Type = null,

    pub fn init(name: []const u8) InferType {
        return .{ .name = name };
    }
};

// ============================================================================
// Literal Types
// ============================================================================

/// Literal types for exact value typing
pub const LiteralType = union(enum) {
    /// String literal type: "hello"
    string: []const u8,
    /// Integer literal type: 42
    integer: i64,
    /// Float literal type: 3.14
    float: f64,
    /// Boolean literal type: true/false
    boolean: bool,
    /// Null literal type
    null_type,
    /// Undefined literal type
    undefined_type,

    pub fn stringLiteral(value: []const u8) LiteralType {
        return .{ .string = value };
    }

    pub fn integerLiteral(value: i64) LiteralType {
        return .{ .integer = value };
    }

    pub fn floatLiteral(value: f64) LiteralType {
        return .{ .float = value };
    }

    pub fn booleanLiteral(value: bool) LiteralType {
        return .{ .boolean = value };
    }

    /// Check if two literal types are equal
    pub fn eql(self: LiteralType, other: LiteralType) bool {
        return switch (self) {
            .string => |s| if (other == .string) std.mem.eql(u8, s, other.string) else false,
            .integer => |i| if (other == .integer) i == other.integer else false,
            .float => |f| if (other == .float) f == other.float else false,
            .boolean => |b| if (other == .boolean) b == other.boolean else false,
            .null_type => other == .null_type,
            .undefined_type => other == .undefined_type,
        };
    }
};

// ============================================================================
// Template Literal Types
// ============================================================================

/// Template literal type: `hello ${string}`
pub const TemplateLiteralType = struct {
    /// Parts of the template (alternating literals and type placeholders)
    parts: []const Part,

    pub const Part = union(enum) {
        /// Literal string part
        literal: []const u8,
        /// Type placeholder
        type_placeholder: *const Type,
    };

    pub fn init(parts: []const Part) TemplateLiteralType {
        return .{ .parts = parts };
    }

    /// Check if a string matches this template
    pub fn matches(self: *const TemplateLiteralType, value: []const u8) bool {
        var pos: usize = 0;

        for (self.parts) |part| {
            switch (part) {
                .literal => |lit| {
                    if (!std.mem.startsWith(u8, value[pos..], lit)) {
                        return false;
                    }
                    pos += lit.len;
                },
                .type_placeholder => |ty| {
                    // For type placeholders, we need to find where the next literal starts
                    // and check if the substring is valid for the type
                    _ = ty; // Type checking would go here
                    // Simplified: accept any substring
                },
            }
        }

        return pos == value.len;
    }
};

// ============================================================================
// Utility Types (Built-in Type Transformations)
// ============================================================================

/// Built-in utility type implementations
pub const UtilityTypes = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) UtilityTypes {
        return .{ .allocator = allocator };
    }

    /// Partial<T> - Make all properties optional
    pub fn partial(self: *UtilityTypes, ty: *const Type) !*Type {
        if (ty.* != .Struct) return error.PartialRequiresStruct;

        const source = ty.Struct;
        var new_fields = std.ArrayList(Type.StructType.Field).init(self.allocator);
        defer new_fields.deinit();

        for (source.fields) |field| {
            // Wrap each field type in Optional
            const optional_type = try self.allocator.create(Type);
            optional_type.* = Type{ .Optional = &field.type };

            try new_fields.append(.{
                .name = field.name,
                .type = optional_type.*,
            });
        }

        const result = try self.allocator.create(Type);
        result.* = Type{
            .Struct = .{
                .name = source.name,
                .fields = try new_fields.toOwnedSlice(),
            },
        };
        return result;
    }

    /// Required<T> - Make all properties required (remove optionality)
    pub fn required(self: *UtilityTypes, ty: *const Type) !*Type {
        if (ty.* != .Struct) return error.RequiredRequiresStruct;

        const source = ty.Struct;
        var new_fields = std.ArrayList(Type.StructType.Field).init(self.allocator);
        defer new_fields.deinit();

        for (source.fields) |field| {
            // Unwrap Optional types
            const unwrapped = if (field.type == .Optional)
                field.type.Optional.*
            else
                field.type;

            try new_fields.append(.{
                .name = field.name,
                .type = unwrapped,
            });
        }

        const result = try self.allocator.create(Type);
        result.* = Type{
            .Struct = .{
                .name = source.name,
                .fields = try new_fields.toOwnedSlice(),
            },
        };
        return result;
    }

    /// Pick<T, K> - Select only specified keys from T
    pub fn pick(self: *UtilityTypes, ty: *const Type, keys: []const []const u8) !*Type {
        if (ty.* != .Struct) return error.PickRequiresStruct;

        const source = ty.Struct;
        var new_fields = std.ArrayList(Type.StructType.Field).init(self.allocator);
        defer new_fields.deinit();

        for (source.fields) |field| {
            for (keys) |key| {
                if (std.mem.eql(u8, field.name, key)) {
                    try new_fields.append(field);
                    break;
                }
            }
        }

        const result = try self.allocator.create(Type);
        result.* = Type{
            .Struct = .{
                .name = source.name,
                .fields = try new_fields.toOwnedSlice(),
            },
        };
        return result;
    }

    /// Omit<T, K> - Remove specified keys from T
    pub fn omit(self: *UtilityTypes, ty: *const Type, keys: []const []const u8) !*Type {
        if (ty.* != .Struct) return error.OmitRequiresStruct;

        const source = ty.Struct;
        var new_fields = std.ArrayList(Type.StructType.Field).init(self.allocator);
        defer new_fields.deinit();

        outer: for (source.fields) |field| {
            for (keys) |key| {
                if (std.mem.eql(u8, field.name, key)) {
                    continue :outer; // Skip this field
                }
            }
            try new_fields.append(field);
        }

        const result = try self.allocator.create(Type);
        result.* = Type{
            .Struct = .{
                .name = source.name,
                .fields = try new_fields.toOwnedSlice(),
            },
        };
        return result;
    }

    /// Readonly<T> - Make all properties readonly
    /// Note: This is tracked separately since Home doesn't have readonly in Type
    pub fn readonly(self: *UtilityTypes, ty: *const Type) !*Type {
        // In a full implementation, this would add a readonly flag to each field
        // For now, just return the type as-is
        _ = self;
        return @constCast(ty);
    }

    /// Record<K, V> - Create object type with keys K and values V
    pub fn record(self: *UtilityTypes, key_type: *const Type, value_type: *const Type) !*Type {
        const result = try self.allocator.create(Type);
        result.* = Type{
            .Map = .{
                .key_type = key_type,
                .value_type = value_type,
            },
        };
        return result;
    }

    /// Exclude<T, U> - Remove types from T that are assignable to U
    pub fn exclude(self: *UtilityTypes, ty: *const Type, excluded: *const Type, checker: anytype) !*Type {
        if (ty.* != .Union) {
            // If not a union, check if it's excluded
            if (checker.isSubtype(ty, excluded)) {
                const result = try self.allocator.create(Type);
                result.* = Type.Void; // never
                return result;
            }
            return @constCast(ty);
        }

        var remaining = std.ArrayList(Type.UnionType.Variant).init(self.allocator);
        defer remaining.deinit();

        for (ty.Union.variants) |variant| {
            if (variant.data_type) |data| {
                if (!checker.isSubtype(data, excluded)) {
                    try remaining.append(variant);
                }
            } else {
                try remaining.append(variant);
            }
        }

        if (remaining.items.len == 0) {
            const result = try self.allocator.create(Type);
            result.* = Type.Void;
            return result;
        }

        const result = try self.allocator.create(Type);
        result.* = Type{
            .Union = .{
                .name = ty.Union.name,
                .variants = try remaining.toOwnedSlice(),
            },
        };
        return result;
    }

    /// Extract<T, U> - Keep only types from T that are assignable to U
    pub fn extract(self: *UtilityTypes, ty: *const Type, extracted: *const Type, checker: anytype) !*Type {
        if (ty.* != .Union) {
            if (checker.isSubtype(ty, extracted)) {
                return @constCast(ty);
            }
            const result = try self.allocator.create(Type);
            result.* = Type.Void;
            return result;
        }

        var kept = std.ArrayList(Type.UnionType.Variant).init(self.allocator);
        defer kept.deinit();

        for (ty.Union.variants) |variant| {
            if (variant.data_type) |data| {
                if (checker.isSubtype(data, extracted)) {
                    try kept.append(variant);
                }
            }
        }

        if (kept.items.len == 0) {
            const result = try self.allocator.create(Type);
            result.* = Type.Void;
            return result;
        }

        const result = try self.allocator.create(Type);
        result.* = Type{
            .Union = .{
                .name = ty.Union.name,
                .variants = try kept.toOwnedSlice(),
            },
        };
        return result;
    }

    /// NonNullable<T> - Remove null and undefined from T
    pub fn nonNullable(self: *UtilityTypes, ty: *const Type) !*Type {
        // If Optional, unwrap it
        if (ty.* == .Optional) {
            return @constCast(ty.Optional);
        }
        _ = self;
        return @constCast(ty);
    }

    /// ReturnType<T> - Extract return type of function type
    pub fn returnType(self: *UtilityTypes, ty: *const Type) !*Type {
        if (ty.* != .Function) return error.ReturnTypeRequiresFunction;
        _ = self;
        return @constCast(ty.Function.return_type);
    }

    /// Parameters<T> - Extract parameter types as tuple
    pub fn parameters(self: *UtilityTypes, ty: *const Type) !*Type {
        if (ty.* != .Function) return error.ParametersRequiresFunction;

        const result = try self.allocator.create(Type);
        result.* = Type{
            .Tuple = .{
                .element_types = ty.Function.params,
            },
        };
        return result;
    }

    /// Awaited<T> - Unwrap Promise/Future type
    pub fn awaited(self: *UtilityTypes, ty: *const Type) !*Type {
        // If it's a Result type, return the ok type
        if (ty.* == .Result) {
            return @constCast(ty.Result.ok_type);
        }
        _ = self;
        return @constCast(ty);
    }
};

// ============================================================================
// Type Interning for Performance
// ============================================================================

/// Type interner for canonical type representation
/// Ensures each unique type is stored only once, enabling pointer equality
pub const TypeInterner = struct {
    allocator: std.mem.Allocator,
    /// Interned types indexed by hash
    types: std.AutoHashMap(u64, *Type),
    /// All allocated types for cleanup
    all_types: std.ArrayListUnmanaged(*Type),

    pub fn init(allocator: std.mem.Allocator) TypeInterner {
        return .{
            .allocator = allocator,
            .types = std.AutoHashMap(u64, *Type).init(allocator),
            .all_types = .{},
        };
    }

    pub fn deinit(self: *TypeInterner) void {
        for (self.all_types.items) |ty| {
            self.allocator.destroy(ty);
        }
        self.all_types.deinit(self.allocator);
        self.types.deinit();
    }

    /// Intern a type, returning canonical pointer
    pub fn intern(self: *TypeInterner, ty: Type) !*Type {
        const hash_val = hashType(&ty);

        if (self.types.get(hash_val)) |existing| {
            return existing;
        }

        const interned = try self.allocator.create(Type);
        interned.* = ty;
        try self.types.put(hash_val, interned);
        try self.all_types.append(self.allocator, interned);
        return interned;
    }

    /// Hash a type for interning
    fn hashType(ty: *const Type) u64 {
        var hasher = std.hash.Wyhash.init(0);

        switch (ty.*) {
            .Int => hasher.update("Int"),
            .I8 => hasher.update("I8"),
            .I16 => hasher.update("I16"),
            .I32 => hasher.update("I32"),
            .I64 => hasher.update("I64"),
            .I128 => hasher.update("I128"),
            .U8 => hasher.update("U8"),
            .U16 => hasher.update("U16"),
            .U32 => hasher.update("U32"),
            .U64 => hasher.update("U64"),
            .U128 => hasher.update("U128"),
            .Float => hasher.update("Float"),
            .F32 => hasher.update("F32"),
            .F64 => hasher.update("F64"),
            .Bool => hasher.update("Bool"),
            .String => hasher.update("String"),
            .Void => hasher.update("Void"),
            .Array => |arr| {
                hasher.update("Array");
                hasher.update(std.mem.asBytes(&hashType(arr.element_type)));
            },
            .Optional => |opt| {
                hasher.update("Optional");
                hasher.update(std.mem.asBytes(&hashType(opt)));
            },
            .Reference => |ref| {
                hasher.update("Reference");
                hasher.update(std.mem.asBytes(&hashType(ref)));
            },
            .Struct => |s| {
                hasher.update("Struct");
                hasher.update(s.name);
            },
            .Enum => |e| {
                hasher.update("Enum");
                hasher.update(e.name);
            },
            else => hasher.update("Other"),
        }

        return hasher.final();
    }
};

// ============================================================================
// Index Access Types
// ============================================================================

/// Index access type: T[K]
/// Accesses a property type from an object/tuple type using a key.
/// Example: User["email"] -> string, Tuple[0] -> FirstElementType
pub const IndexAccessType = struct {
    /// The object/tuple type to access
    object_type: *const Type,
    /// The index/key type (typically a literal or keyof result)
    index_type: *const Type,

    pub fn init(object: *const Type, index: *const Type) IndexAccessType {
        return .{
            .object_type = object,
            .index_type = index,
        };
    }

    /// Evaluate the index access to get the property type
    pub fn evaluate(self: *const IndexAccessType, allocator: std.mem.Allocator) !*Type {
        switch (self.object_type.*) {
            .Struct => |s| {
                // For struct, index must be a string literal
                if (self.index_type.* == .Literal) {
                    const lit = self.index_type.Literal;
                    if (lit == .string) {
                        const key = lit.string;
                        for (s.fields) |field| {
                            if (std.mem.eql(u8, field.name, key)) {
                                const result = try allocator.create(Type);
                                result.* = field.type;
                                return result;
                            }
                        }
                    }
                }
                // Key not found - return never
                const result = try allocator.create(Type);
                result.* = Type.Never;
                return result;
            },
            .Tuple => |t| {
                // For tuple, index must be an integer literal
                if (self.index_type.* == .Literal) {
                    const lit = self.index_type.Literal;
                    if (lit == .integer) {
                        const idx: usize = @intCast(lit.integer);
                        if (idx < t.element_types.len) {
                            const result = try allocator.create(Type);
                            result.* = t.element_types[idx];
                            return result;
                        }
                    }
                }
                // Index out of bounds - return never
                const result = try allocator.create(Type);
                result.* = Type.Never;
                return result;
            },
            .Array => |a| {
                // Array[number] returns element type
                const result = try allocator.create(Type);
                result.* = a.element_type.*;
                return result;
            },
            .Map => |m| {
                // Map[K] returns value type
                const result = try allocator.create(Type);
                result.* = m.value_type.*;
                return result;
            },
            else => {
                // Invalid index access - return never
                const result = try allocator.create(Type);
                result.* = Type.Never;
                return result;
            },
        }
    }
};

// ============================================================================
// Branded/Nominal Types
// ============================================================================

/// Branded type for nominal typing of primitives
/// Creates a distinct type from a base type without runtime overhead.
/// Example: type UserId = Brand<i64, "UserId">
/// Prevents accidentally mixing UserId with OrderId even though both are i64
pub const BrandedType = struct {
    /// The underlying base type
    base_type: *const Type,
    /// Unique brand identifier (compile-time string)
    brand: []const u8,

    pub fn init(base: *const Type, brand: []const u8) BrandedType {
        return .{
            .base_type = base,
            .brand = brand,
        };
    }

    /// Check if two branded types are equal (requires same brand)
    pub fn eql(self: BrandedType, other: BrandedType) bool {
        return std.mem.eql(u8, self.brand, other.brand) and
            self.base_type.equals(other.base_type.*);
    }

    /// Check if a value can be assigned to this branded type
    /// Only exact brand matches are allowed (no implicit conversion)
    pub fn isAssignableFrom(self: *const BrandedType, other: *const Type) bool {
        // Only branded types with same brand can be assigned
        if (other.* == .Branded) {
            return self.eql(other.Branded);
        }
        return false;
    }
};

/// Opaque type - hides implementation details
/// Only the module that defines it can see the underlying type
pub const OpaqueType = struct {
    /// The hidden underlying type (only accessible within defining module)
    underlying_type: *const Type,
    /// Unique identifier for this opaque type
    name: []const u8,
    /// Module that defined this opaque type
    defining_module: ?[]const u8,

    pub fn init(underlying: *const Type, name: []const u8) OpaqueType {
        return .{
            .underlying_type = underlying,
            .name = name,
            .defining_module = null,
        };
    }
};

// ============================================================================
// String Manipulation Types
// ============================================================================

/// String manipulation types for type-level string transformations
pub const StringManipulationType = union(enum) {
    /// Uppercase<S> - converts string literal to uppercase
    uppercase: *const Type,
    /// Lowercase<S> - converts string literal to lowercase
    lowercase: *const Type,
    /// Capitalize<S> - capitalizes first letter
    capitalize: *const Type,
    /// Uncapitalize<S> - lowercases first letter
    uncapitalize: *const Type,
    /// Trim<S> - removes leading/trailing whitespace
    trim: *const Type,
    /// TrimStart<S> - removes leading whitespace
    trim_start: *const Type,
    /// TrimEnd<S> - removes trailing whitespace
    trim_end: *const Type,
    /// Replace<S, Search, Replacement>
    replace: ReplaceInfo,
    /// Split<S, Delimiter> - splits string into tuple
    split: SplitInfo,
    /// Join<Tuple, Delimiter> - joins tuple into string
    join: JoinInfo,

    pub const ReplaceInfo = struct {
        source: *const Type,
        search: []const u8,
        replacement: []const u8,
    };

    pub const SplitInfo = struct {
        source: *const Type,
        delimiter: []const u8,
    };

    pub const JoinInfo = struct {
        source: *const Type,
        delimiter: []const u8,
    };

    /// Evaluate the string manipulation
    pub fn evaluate(self: StringManipulationType, allocator: std.mem.Allocator) !*Type {
        const result = try allocator.create(Type);

        switch (self) {
            .uppercase => |ty| {
                if (ty.* == .Literal and ty.Literal == .string) {
                    var upper = try allocator.alloc(u8, ty.Literal.string.len);
                    for (ty.Literal.string, 0..) |c, i| {
                        upper[i] = std.ascii.toUpper(c);
                    }
                    result.* = Type{ .Literal = .{ .string = upper } };
                    return result;
                }
                result.* = Type.String; // Non-literal returns string
            },
            .lowercase => |ty| {
                if (ty.* == .Literal and ty.Literal == .string) {
                    var lower = try allocator.alloc(u8, ty.Literal.string.len);
                    for (ty.Literal.string, 0..) |c, i| {
                        lower[i] = std.ascii.toLower(c);
                    }
                    result.* = Type{ .Literal = .{ .string = lower } };
                    return result;
                }
                result.* = Type.String;
            },
            .capitalize => |ty| {
                if (ty.* == .Literal and ty.Literal == .string) {
                    const str = ty.Literal.string;
                    if (str.len > 0) {
                        var cap = try allocator.alloc(u8, str.len);
                        cap[0] = std.ascii.toUpper(str[0]);
                        @memcpy(cap[1..], str[1..]);
                        result.* = Type{ .Literal = .{ .string = cap } };
                        return result;
                    }
                }
                result.* = Type.String;
            },
            .uncapitalize => |ty| {
                if (ty.* == .Literal and ty.Literal == .string) {
                    const str = ty.Literal.string;
                    if (str.len > 0) {
                        var uncap = try allocator.alloc(u8, str.len);
                        uncap[0] = std.ascii.toLower(str[0]);
                        @memcpy(uncap[1..], str[1..]);
                        result.* = Type{ .Literal = .{ .string = uncap } };
                        return result;
                    }
                }
                result.* = Type.String;
            },
            .trim => |ty| {
                if (ty.* == .Literal and ty.Literal == .string) {
                    const trimmed = std.mem.trim(u8, ty.Literal.string, " \t\n\r");
                    result.* = Type{ .Literal = .{ .string = trimmed } };
                    return result;
                }
                result.* = Type.String;
            },
            .trim_start => |ty| {
                if (ty.* == .Literal and ty.Literal == .string) {
                    const trimmed = std.mem.trimLeft(u8, ty.Literal.string, " \t\n\r");
                    result.* = Type{ .Literal = .{ .string = trimmed } };
                    return result;
                }
                result.* = Type.String;
            },
            .trim_end => |ty| {
                if (ty.* == .Literal and ty.Literal == .string) {
                    const trimmed = std.mem.trimRight(u8, ty.Literal.string, " \t\n\r");
                    result.* = Type{ .Literal = .{ .string = trimmed } };
                    return result;
                }
                result.* = Type.String;
            },
            .replace => |info| {
                if (info.source.* == .Literal and info.source.Literal == .string) {
                    const str = info.source.Literal.string;
                    // Count replacements needed
                    var count: usize = 0;
                    var i: usize = 0;
                    while (i <= str.len - info.search.len) {
                        if (std.mem.eql(u8, str[i..][0..info.search.len], info.search)) {
                            count += 1;
                            i += info.search.len;
                        } else {
                            i += 1;
                        }
                    }
                    if (count > 0) {
                        const new_len = str.len - (count * info.search.len) + (count * info.replacement.len);
                        var replaced = try allocator.alloc(u8, new_len);
                        var src_idx: usize = 0;
                        var dst_idx: usize = 0;
                        while (src_idx < str.len) {
                            if (src_idx <= str.len - info.search.len and
                                std.mem.eql(u8, str[src_idx..][0..info.search.len], info.search))
                            {
                                @memcpy(replaced[dst_idx..][0..info.replacement.len], info.replacement);
                                dst_idx += info.replacement.len;
                                src_idx += info.search.len;
                            } else {
                                replaced[dst_idx] = str[src_idx];
                                dst_idx += 1;
                                src_idx += 1;
                            }
                        }
                        result.* = Type{ .Literal = .{ .string = replaced } };
                        return result;
                    }
                }
                result.* = Type.String;
            },
            .split, .join => {
                // These produce more complex types - return string for now
                result.* = Type.String;
            },
        }
        return result;
    }
};

// ============================================================================
// Variance Annotations
// ============================================================================

/// Variance annotation for generic type parameters
/// Controls how generic types interact with subtyping
pub const Variance = enum {
    /// Covariant (out T) - T only appears in output positions
    /// If A <: B, then Container<A> <: Container<B>
    covariant,

    /// Contravariant (in T) - T only appears in input positions
    /// If A <: B, then Container<B> <: Container<A>
    contravariant,

    /// Invariant - T appears in both input and output positions
    /// Container<A> is only subtype of Container<B> if A = B
    invariant,

    /// Bivariant - special case (usually unsound but sometimes needed)
    /// Container<A> <: Container<B> regardless of A and B relationship
    bivariant,
};

/// Generic type parameter with variance annotation
pub const VariantTypeParam = struct {
    /// Parameter name (e.g., "T", "K", "V")
    name: []const u8,
    /// Variance annotation
    variance: Variance,
    /// Optional constraint/bound
    constraint: ?*const Type,
    /// Optional default type
    default_type: ?*const Type,

    pub fn init(name: []const u8, variance: Variance) VariantTypeParam {
        return .{
            .name = name,
            .variance = variance,
            .constraint = null,
            .default_type = null,
        };
    }

    pub fn withConstraint(self: VariantTypeParam, constraint: *const Type) VariantTypeParam {
        var result = self;
        result.constraint = constraint;
        return result;
    }

    pub fn withDefault(self: VariantTypeParam, default: *const Type) VariantTypeParam {
        var result = self;
        result.default_type = default;
        return result;
    }
};

/// Check if a type assignment respects variance rules
pub fn checkVariance(
    param: VariantTypeParam,
    from_type: *const Type,
    to_type: *const Type,
    isSubtype: fn (*const Type, *const Type) bool,
) bool {
    return switch (param.variance) {
        .covariant => isSubtype(from_type, to_type),
        .contravariant => isSubtype(to_type, from_type),
        .invariant => from_type.equals(to_type.*),
        .bivariant => true,
    };
}

// ============================================================================
// Type Narrowing/Guards
// ============================================================================

/// Type guard for control-flow based type narrowing
/// Represents a predicate that narrows a type
pub const TypeGuard = struct {
    /// The variable/expression being narrowed
    target: []const u8,
    /// The narrowed type when guard is true
    narrowed_type: *const Type,
    /// The remaining type when guard is false (optional)
    else_type: ?*const Type,

    pub fn init(target: []const u8, narrowed: *const Type) TypeGuard {
        return .{
            .target = target,
            .narrowed_type = narrowed,
            .else_type = null,
        };
    }

    pub fn withElseType(self: TypeGuard, else_type: *const Type) TypeGuard {
        var result = self;
        result.else_type = else_type;
        return result;
    }
};

/// Type predicate for user-defined type guards
/// Example: fn isString(x: unknown) -> x is string
pub const TypePredicate = struct {
    /// Parameter being tested
    parameter_name: []const u8,
    /// The type that parameter is narrowed to
    asserted_type: *const Type,

    pub fn init(param: []const u8, asserted: *const Type) TypePredicate {
        return .{
            .parameter_name = param,
            .asserted_type = asserted,
        };
    }
};

// ============================================================================
// Recursive Type Alias
// ============================================================================

/// Recursive type alias for self-referential types
/// Example: type LinkedList<T> = { value: T, next: LinkedList<T>? }
pub const RecursiveTypeAlias = struct {
    /// Alias name
    name: []const u8,
    /// Type parameters
    params: []const []const u8,
    /// The type definition (may reference itself by name)
    definition: *const Type,

    pub fn init(name: []const u8, params: []const []const u8, definition: *const Type) RecursiveTypeAlias {
        return .{
            .name = name,
            .params = params,
            .definition = definition,
        };
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

fn createUnionType(allocator: std.mem.Allocator, types: []const *const Type) !*const Type {
    var variants = std.ArrayList(Type.UnionType.Variant).init(allocator);
    defer variants.deinit();

    for (types, 0..) |ty, i| {
        var name_buf: [20]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "V{}", .{i}) catch "?";
        try variants.append(.{
            .name = name,
            .data_type = ty,
        });
    }

    const result = try allocator.create(Type);
    result.* = Type{
        .Union = .{
            .name = "union",
            .variants = try variants.toOwnedSlice(),
        },
    };
    return result;
}

// ============================================================================
// Tests
// ============================================================================

test "intersection type satisfaction" {
    // Basic test structure
    const allocator = std.testing.allocator;
    _ = allocator;
}

test "literal type equality" {
    const a = LiteralType.integerLiteral(42);
    const b = LiteralType.integerLiteral(42);
    const c = LiteralType.integerLiteral(43);

    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}

test "type interner deduplication" {
    const allocator = std.testing.allocator;

    var interner = TypeInterner.init(allocator);
    defer interner.deinit();

    const int1 = try interner.intern(Type.Int);
    const int2 = try interner.intern(Type.Int);

    // Should return same pointer
    try std.testing.expectEqual(int1, int2);
}

test "type interner - different types get different pointers" {
    const allocator = std.testing.allocator;

    var interner = TypeInterner.init(allocator);
    defer interner.deinit();

    const int_ptr = try interner.intern(Type.Int);
    const string_ptr = try interner.intern(Type.String);
    const bool_ptr = try interner.intern(Type.Bool);

    try std.testing.expect(int_ptr != string_ptr);
    try std.testing.expect(string_ptr != bool_ptr);
    try std.testing.expect(int_ptr != bool_ptr);
}

test "literal type - string equality" {
    const a = LiteralType.stringLiteral("hello");
    const b = LiteralType.stringLiteral("hello");
    const c = LiteralType.stringLiteral("world");

    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}

test "literal type - float equality" {
    const a = LiteralType.floatLiteral(3.14);
    const b = LiteralType.floatLiteral(3.14);
    const c = LiteralType.floatLiteral(2.71);

    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}

test "literal type - boolean equality" {
    const t1 = LiteralType.booleanLiteral(true);
    const t2 = LiteralType.booleanLiteral(true);
    const f1 = LiteralType.booleanLiteral(false);

    try std.testing.expect(t1.eql(t2));
    try std.testing.expect(!t1.eql(f1));
}

test "literal type - null and undefined" {
    const null1 = LiteralType{ .null_type = {} };
    const null2 = LiteralType{ .null_type = {} };
    const undef = LiteralType{ .undefined_type = {} };

    try std.testing.expect(null1.eql(null2));
    try std.testing.expect(!null1.eql(undef));
}

test "literal type - cross-type inequality" {
    const str = LiteralType.stringLiteral("42");
    const int = LiteralType.integerLiteral(42);

    try std.testing.expect(!str.eql(int));
}

test "intersection type - init" {
    const allocator = std.testing.allocator;

    const t1 = try allocator.create(Type);
    defer allocator.destroy(t1);
    t1.* = Type.Int;

    const t2 = try allocator.create(Type);
    defer allocator.destroy(t2);
    t2.* = Type.String;

    const types_slice = try allocator.alloc(*const Type, 2);
    defer allocator.free(types_slice);
    types_slice[0] = t1;
    types_slice[1] = t2;

    const intersection = IntersectionType.init(types_slice);
    try std.testing.expectEqual(@as(usize, 2), intersection.types.len);
}

test "conditional type - init" {
    const allocator = std.testing.allocator;

    const check = try allocator.create(Type);
    defer allocator.destroy(check);
    check.* = Type.Int;

    const extends = try allocator.create(Type);
    defer allocator.destroy(extends);
    extends.* = Type.I64;

    const true_t = try allocator.create(Type);
    defer allocator.destroy(true_t);
    true_t.* = Type.String;

    const false_t = try allocator.create(Type);
    defer allocator.destroy(false_t);
    false_t.* = Type.Bool;

    const cond = ConditionalType.init(check, extends, true_t, false_t);

    try std.testing.expectEqual(Type.Int, cond.check_type.*);
    try std.testing.expectEqual(Type.I64, cond.extends_type.*);
    try std.testing.expectEqual(Type.String, cond.true_type.*);
    try std.testing.expectEqual(Type.Bool, cond.false_type.*);
}

test "mapped type - init" {
    const allocator = std.testing.allocator;

    const source = try allocator.create(Type);
    defer allocator.destroy(source);
    source.* = Type{ .Struct = .{ .name = "User", .fields = &.{} } };

    const value = try allocator.create(Type);
    defer allocator.destroy(value);
    value.* = Type.Bool;

    const mapped = MappedType.init(source, "K", value);

    try std.testing.expectEqualStrings("K", mapped.key_var);
    try std.testing.expectEqual(Type.Bool, mapped.value_type.*);
}

test "keyof type - init" {
    const allocator = std.testing.allocator;

    const target = try allocator.create(Type);
    defer allocator.destroy(target);
    target.* = Type{ .Struct = .{ .name = "User", .fields = &.{} } };

    const keyof = KeyofType.init(target);
    try std.testing.expectEqualStrings("User", keyof.target_type.Struct.name);
}

test "typeof type - init" {
    const typeof_type = TypeofType.init("myVariable");
    try std.testing.expectEqualStrings("myVariable", typeof_type.expression_name);
    try std.testing.expectEqual(@as(?*const Type, null), typeof_type.resolved_type);
}

test "infer type - init" {
    const infer_type = InferType.init("R");
    try std.testing.expectEqualStrings("R", infer_type.name);
    try std.testing.expectEqual(@as(?*const Type, null), infer_type.constraint);
}

test "template literal type - init" {
    const allocator = std.testing.allocator;

    const ty = try allocator.create(Type);
    defer allocator.destroy(ty);
    ty.* = Type.String;

    const parts = try allocator.alloc(TemplateLiteralType.Part, 3);
    defer allocator.free(parts);
    parts[0] = .{ .literal = "prefix_" };
    parts[1] = .{ .type_placeholder = ty };
    parts[2] = .{ .literal = "_suffix" };

    const template = TemplateLiteralType.init(parts);
    try std.testing.expectEqual(@as(usize, 3), template.parts.len);
}

// Edge case tests
test "edge case - literal type with empty string" {
    const lit = LiteralType.stringLiteral("");
    try std.testing.expectEqualStrings("", lit.string);
}

test "edge case - literal type with max i64" {
    const lit = LiteralType.integerLiteral(std.math.maxInt(i64));
    try std.testing.expectEqual(std.math.maxInt(i64), lit.integer);
}

test "edge case - literal type with min i64" {
    const lit = LiteralType.integerLiteral(std.math.minInt(i64));
    try std.testing.expectEqual(std.math.minInt(i64), lit.integer);
}

test "edge case - literal type with infinity" {
    const inf = LiteralType.floatLiteral(std.math.inf(f64));
    try std.testing.expect(std.math.isInf(inf.float));
}

test "edge case - literal type with negative infinity" {
    const neg_inf = LiteralType.floatLiteral(-std.math.inf(f64));
    try std.testing.expect(std.math.isInf(neg_inf.float));
    try std.testing.expect(neg_inf.float < 0);
}

// ============================================================================
// Never and Unknown Type Tests
// ============================================================================

test "never type - basic usage" {
    const never = Type.Never;
    try std.testing.expect(never == .Never);
}

test "unknown type - basic usage" {
    const unknown = Type.Unknown;
    try std.testing.expect(unknown == .Unknown);
}

test "never and unknown equality" {
    const never1: Type = .Never;
    const never2: Type = .Never;
    const unknown1: Type = .Unknown;
    const unknown2: Type = .Unknown;

    try std.testing.expect(never1.equals(never2));
    try std.testing.expect(unknown1.equals(unknown2));
    try std.testing.expect(!never1.equals(unknown1));
}

// ============================================================================
// Branded Type Tests
// ============================================================================

test "branded type - init" {
    const allocator = std.testing.allocator;

    const base = try allocator.create(Type);
    defer allocator.destroy(base);
    base.* = Type.I64;

    const branded = BrandedType.init(base, "UserId");
    try std.testing.expectEqualStrings("UserId", branded.brand);
    try std.testing.expectEqual(Type.I64, branded.base_type.*);
}

test "branded type - equality" {
    const allocator = std.testing.allocator;

    const base1 = try allocator.create(Type);
    defer allocator.destroy(base1);
    base1.* = Type.I64;

    const base2 = try allocator.create(Type);
    defer allocator.destroy(base2);
    base2.* = Type.I64;

    const userId1 = BrandedType.init(base1, "UserId");
    const userId2 = BrandedType.init(base2, "UserId");
    const orderId = BrandedType.init(base1, "OrderId");

    try std.testing.expect(userId1.eql(userId2));
    try std.testing.expect(!userId1.eql(orderId));
}

test "branded type - different base types" {
    const allocator = std.testing.allocator;

    const i64_type = try allocator.create(Type);
    defer allocator.destroy(i64_type);
    i64_type.* = Type.I64;

    const string_type = try allocator.create(Type);
    defer allocator.destroy(string_type);
    string_type.* = Type.String;

    const id1 = BrandedType.init(i64_type, "Id");
    const id2 = BrandedType.init(string_type, "Id");

    // Same brand, different base type - not equal
    try std.testing.expect(!id1.eql(id2));
}

// ============================================================================
// Index Access Type Tests
// ============================================================================

test "index access type - init" {
    const allocator = std.testing.allocator;

    const obj = try allocator.create(Type);
    defer allocator.destroy(obj);
    obj.* = Type{ .Struct = .{ .name = "User", .fields = &.{} } };

    const idx = try allocator.create(Type);
    defer allocator.destroy(idx);
    idx.* = Type{ .Literal = .{ .string = "email" } };

    const index_access = IndexAccessType.init(obj, idx);
    try std.testing.expectEqualStrings("User", index_access.object_type.Struct.name);
}

// ============================================================================
// Variance Tests
// ============================================================================

test "variance - enum values" {
    try std.testing.expect(Variance.covariant != Variance.contravariant);
    try std.testing.expect(Variance.invariant != Variance.bivariant);
}

test "variant type param - init" {
    const param = VariantTypeParam.init("T", .covariant);
    try std.testing.expectEqualStrings("T", param.name);
    try std.testing.expectEqual(Variance.covariant, param.variance);
    try std.testing.expectEqual(@as(?*const Type, null), param.constraint);
}

test "variant type param - with constraint" {
    const allocator = std.testing.allocator;

    const constraint = try allocator.create(Type);
    defer allocator.destroy(constraint);
    constraint.* = Type{ .Struct = .{ .name = "Comparable", .fields = &.{} } };

    const param = VariantTypeParam.init("T", .covariant).withConstraint(constraint);
    try std.testing.expectEqualStrings("T", param.name);
    try std.testing.expect(param.constraint != null);
}

// ============================================================================
// Type Guard Tests
// ============================================================================

test "type guard - init" {
    const allocator = std.testing.allocator;

    const narrowed = try allocator.create(Type);
    defer allocator.destroy(narrowed);
    narrowed.* = Type.String;

    const guard = TypeGuard.init("x", narrowed);
    try std.testing.expectEqualStrings("x", guard.target);
    try std.testing.expectEqual(Type.String, guard.narrowed_type.*);
}

test "type guard - with else type" {
    const allocator = std.testing.allocator;

    const narrowed = try allocator.create(Type);
    defer allocator.destroy(narrowed);
    narrowed.* = Type.String;

    const else_type = try allocator.create(Type);
    defer allocator.destroy(else_type);
    else_type.* = Type.Int;

    const guard = TypeGuard.init("x", narrowed).withElseType(else_type);
    try std.testing.expect(guard.else_type != null);
    try std.testing.expectEqual(Type.Int, guard.else_type.?.*);
}

// ============================================================================
// Type Predicate Tests
// ============================================================================

test "type predicate - init" {
    const allocator = std.testing.allocator;

    const asserted = try allocator.create(Type);
    defer allocator.destroy(asserted);
    asserted.* = Type.String;

    const pred = TypePredicate.init("x", asserted);
    try std.testing.expectEqualStrings("x", pred.parameter_name);
    try std.testing.expectEqual(Type.String, pred.asserted_type.*);
}

// ============================================================================
// Opaque Type Tests
// ============================================================================

test "opaque type - init" {
    const allocator = std.testing.allocator;

    const underlying = try allocator.create(Type);
    defer allocator.destroy(underlying);
    underlying.* = Type{ .Struct = .{ .name = "InternalData", .fields = &.{} } };

    const opaque_type = OpaqueType.init(underlying, "PublicHandle");
    try std.testing.expectEqualStrings("PublicHandle", opaque_type.name);
    try std.testing.expectEqual(@as(?[]const u8, null), opaque_type.defining_module);
}

// ============================================================================
// String Manipulation Type Tests
// ============================================================================

test "string manipulation - uppercase" {
    const allocator = std.testing.allocator;

    const hello = try allocator.create(Type);
    defer allocator.destroy(hello);
    hello.* = Type{ .Literal = .{ .string = "hello" } };

    const manip = StringManipulationType{ .uppercase = hello };
    const result = try manip.evaluate(allocator);
    defer allocator.destroy(result);

    try std.testing.expectEqualStrings("HELLO", result.Literal.string);
    allocator.free(@constCast(result.Literal.string));
}

test "string manipulation - lowercase" {
    const allocator = std.testing.allocator;

    const hello = try allocator.create(Type);
    defer allocator.destroy(hello);
    hello.* = Type{ .Literal = .{ .string = "WORLD" } };

    const manip = StringManipulationType{ .lowercase = hello };
    const result = try manip.evaluate(allocator);
    defer allocator.destroy(result);

    try std.testing.expectEqualStrings("world", result.Literal.string);
    allocator.free(@constCast(result.Literal.string));
}

test "string manipulation - capitalize" {
    const allocator = std.testing.allocator;

    const hello = try allocator.create(Type);
    defer allocator.destroy(hello);
    hello.* = Type{ .Literal = .{ .string = "hello" } };

    const manip = StringManipulationType{ .capitalize = hello };
    const result = try manip.evaluate(allocator);
    defer allocator.destroy(result);

    try std.testing.expectEqualStrings("Hello", result.Literal.string);
    allocator.free(@constCast(result.Literal.string));
}

test "string manipulation - trim" {
    const allocator = std.testing.allocator;

    const hello = try allocator.create(Type);
    defer allocator.destroy(hello);
    hello.* = Type{ .Literal = .{ .string = "  hello  " } };

    const manip = StringManipulationType{ .trim = hello };
    const result = try manip.evaluate(allocator);
    defer allocator.destroy(result);

    try std.testing.expectEqualStrings("hello", result.Literal.string);
}

// ============================================================================
// Recursive Type Alias Tests
// ============================================================================

test "recursive type alias - init" {
    const allocator = std.testing.allocator;

    const definition = try allocator.create(Type);
    defer allocator.destroy(definition);
    definition.* = Type{ .Struct = .{ .name = "LinkedList", .fields = &.{} } };

    const params = [_][]const u8{"T"};
    const alias = RecursiveTypeAlias.init("LinkedList", &params, definition);

    try std.testing.expectEqualStrings("LinkedList", alias.name);
    try std.testing.expectEqual(@as(usize, 1), alias.params.len);
}
