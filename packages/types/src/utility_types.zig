// Utility Types for Home Type System
//
// Built-in utility type implementations similar to TypeScript.
// Partial, Required, Pick, Omit, Readonly, Record, etc.

const std = @import("std");
const Type = @import("type_system.zig").Type;

/// Built-in utility type implementations
pub const UtilityTypes = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) UtilityTypes {
        return .{ .allocator = allocator };
    }

    /// Partial<T> - Make all properties optional
    pub fn partial(self: *UtilityTypes, ty: *const Type) !*Type {
        if (std.meta.activeTag(ty.*) != .Struct) return error.PartialRequiresStruct;

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
        if (std.meta.activeTag(ty.*) != .Struct) return error.RequiredRequiresStruct;

        const source = ty.Struct;
        var new_fields = std.ArrayList(Type.StructType.Field).init(self.allocator);
        defer new_fields.deinit();

        for (source.fields) |field| {
            // Unwrap Optional types
            const unwrapped = if (std.meta.activeTag(field.type) == .Optional)
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
        if (std.meta.activeTag(ty.*) != .Struct) return error.PickRequiresStruct;

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
        if (std.meta.activeTag(ty.*) != .Struct) return error.OmitRequiresStruct;

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
        if (std.meta.activeTag(ty.*) != .Union) {
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
        if (std.meta.activeTag(ty.*) != .Union) {
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
        if (std.meta.activeTag(ty.*) == .Optional) {
            return @constCast(ty.Optional);
        }
        _ = self;
        return @constCast(ty);
    }

    /// ReturnType<T> - Extract return type of function type
    pub fn returnType(self: *UtilityTypes, ty: *const Type) !*Type {
        if (std.meta.activeTag(ty.*) != .Function) return error.ReturnTypeRequiresFunction;
        _ = self;
        return @constCast(ty.Function.return_type);
    }

    /// Parameters<T> - Extract parameter types as tuple
    pub fn parameters(self: *UtilityTypes, ty: *const Type) !*Type {
        if (std.meta.activeTag(ty.*) != .Function) return error.ParametersRequiresFunction;

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
        if (std.meta.activeTag(ty.*) == .Result) {
            return @constCast(ty.Result.ok_type);
        }
        _ = self;
        return @constCast(ty);
    }
};
