//! Deep, owner-scoped relocation of checked semantics alongside type payloads.
//!
//! The result belongs to ONE source owner. Do not merge its name-keyed tables
//! with another owner's tables or infer declaration identity from a canonical
//! signature ID. Node mappings must resolve to real source-owner/node records.
//! The caller owns those records, the type relocation, and callback allocations.
//! This operation never mutates source tables or publishes a partial result.

const std = @import("std");
const check = @import("check.zig");
const transfer = @import("type_transfer.zig");

pub const Error = transfer.Error || error{MetadataCollision};

/// One source owner's complete relocated result. The destination type pool,
/// mapped strings, and declaration provenance are owned by the caller.
pub const Imported = struct {
    ids: transfer.Relocation,
    checked: check.CheckedTypes,

    pub fn deinit(self: *Imported) void {
        self.checked.deinit(self.ids.allocator);
        self.ids.deinit();
    }
};

/// Prepare payloads and checked semantics before committing either. Failure
/// restores destination payloads, intern keys and enum entries. Callers that
/// allocate provenance in name callbacks must join that allocation transaction
/// themselves. Keep exclusive ownership of the target until this returns.
pub fn append(
    target: *@import("interner.zig").Interner,
    source: *const @import("interner.zig").Interner,
    checked: *const check.CheckedTypes,
    names: transfer.Names,
) Error!Imported {
    var pending = try transfer.prepare(target, source, names);
    defer pending.deinit();
    const copied = try clone(target.gpa, checked, pending.ids(), names);
    return .{ .ids = pending.commit(), .checked = copied };
}

const Shape = union(enum) {
    scalar,
    type_id,
    string_id,
    node_id,
    slice: *const Shape,
    list: *const Shape,
    map: *const MapShape,
    fields: []const FieldShape,
};
const FieldShape = struct { name: []const u8, shape: Shape };
const MapShape = struct { key: Shape, value: Shape };
const scalar: Shape = .scalar;
const type_id: Shape = .type_id;
const string_id: Shape = .string_id;
const node_id: Shape = .node_id;
const type_slice: Shape = .{ .slice = &type_id };
const string_slice: Shape = .{ .slice = &string_id };
const node_slice: Shape = .{ .slice = &node_id };
const scalar_slice: Shape = .{ .slice = &scalar };
const type_list: Shape = .{ .list = &type_id };
const node_list: Shape = .{ .list = &node_id };
const string_list: Shape = .{ .list = &string_id };
const name_set: Shape = .{ .map = &.{ .key = string_id, .value = scalar } };
const name_map: Shape = .{ .map = &.{ .key = string_id, .value = string_id } };
const alias: Shape = .{ .fields = &.{
    .{ .name = "params", .shape = type_slice },
    .{ .name = "body", .shape = type_id },
    .{ .name = "is_type_alias", .shape = scalar },
    .{ .name = "body_node", .shape = node_id },
} };
const predicate: Shape = .{ .fields = &.{
    .{ .name = "param_index", .shape = scalar },
    .{ .name = "target_type", .shape = type_id },
    .{ .name = "target_node", .shape = node_id },
    .{ .name = "is_asserts", .shape = scalar },
} };
const member: Shape = .{ .fields = &.{
    .{ .name = "obj_name", .shape = string_id },
    .{ .name = "prop_name", .shape = string_id },
} };
const type_member: Shape = .{ .fields = &.{
    .{ .name = "receiver_type", .shape = type_id },
    .{ .name = "member_name", .shape = string_id },
} };
const signature_param: Shape = .{ .fields = &.{
    .{ .name = "signature", .shape = type_id },
    .{ .name = "param_index", .shape = scalar },
} };
const accessor: Shape = .{ .fields = &.{
    .{ .name = "class_name", .shape = string_id },
    .{ .name = "member_name", .shape = string_id },
    .{ .name = "is_static", .shape = scalar },
} };
const variable: Shape = .{
    .fields = &.{
        .{ .name = "scope", .shape = node_id },
        .{ .name = "name", .shape = string_id },
        // A byte offset within the source owner's text, NOT a declaration ID.
        .{ .name = "virtual_section_start", .shape = scalar },
    },
};
const index_names: Shape = .{ .fields = &.{
    .{ .name = "string", .shape = string_id },
    .{ .name = "number", .shape = string_id },
    .{ .name = "symbol", .shape = string_id },
    .{ .name = "string_decl", .shape = node_id },
    .{ .name = "number_decl", .shape = node_id },
    .{ .name = "symbol_decl", .shape = node_id },
} };
const generator: Shape = .{ .fields = &.{
    .{ .name = "yield_type", .shape = type_id },
    .{ .name = "return_type", .shape = type_id },
    .{ .name = "next_type", .shape = type_id },
} };
const pattern: Shape = .{ .fields = &.{
    .{ .name = "key_type", .shape = type_id },
    .{ .name = "value_type", .shape = type_id },
    .{ .name = "decl_node", .shape = node_id },
} };
const symbolic_segment: Shape = .{ .fields = &.{
    .{ .name = "type", .shape = type_id },
    .{ .name = "is_variadic", .shape = scalar },
} };

// Exhaustive field enumeration: additions to CheckedTypes require a conscious
// classification here. TypeId, StringId and NodeId are all u32 aliases; their
// meaning cannot be recovered through reflection on their Zig type alone.
fn tableShape(comptime field: std.meta.FieldEnum(check.CheckedTypes)) MapShape {
    return switch (field) {
        .type_names,
        .class_instance_types,
        .class_static_types,
        .class_constructor_sigs,
        .type_alias_bodies,
        .jsdoc_typedef_object_types,
        .jsdoc_callback_signatures,
        => .{ .key = string_id, .value = type_id },
        .generic_aliases => .{ .key = string_id, .value = alias },
        .generic_interfaces_by_decl => .{ .key = node_id, .value = alias },
        .generic_fns => .{ .key = string_id, .value = type_slice },
        .generic_signature_params, .alias_type_args => .{ .key = type_id, .value = type_slice },
        .generic_interface_decl_by_instance,
        .signature_decl_nodes,
        .type_parameter_decl_nodes,
        .class_decl_by_instance,
        .enum_nominal_decls,
        => .{ .key = type_id, .value = node_id },
        .rest_signatures,
        .jsdoc_constrained_type_params,
        .string_named_export_types,
        .unknown_empty_object_types,
        .readonly_index_types,
        .tuple_origin_types,
        .array_origin_types,
        .normalized_object_literal_unions,
        .infer_type_parameters,
        .module_augmentation_callback_signatures,
        .constructor_signature_visibility,
        .signature_min_args,
        .signature_display_min_args,
        .inferred_variance,
        => .{ .key = type_id, .value = scalar },
        .signature_this_params,
        .type_parameter_placeholder_targets,
        .recursive_interface_targets,
        .merged_class_instance_types,
        .decl_single_base,
        .relation_display_base,
        .this_type_markers,
        .no_infer_types,
        .tuple_trailing_rest_types,
        .tuple_trailing_variadic_types,
        .module_augmented_interface_types,
        => .{ .key = type_id, .value = type_id },
        .signature_nullish_array_defaults,
        .jsdoc_constraint_display_names,
        .alias_display_names,
        .diagnostic_union_display_names,
        .qualified_alias_diagnostic_names,
        .builtin_object_names,
        => .{ .key = type_id, .value = scalar_slice },
        .signature_param_names, .signature_param_name_occurrences => .{ .key = type_id, .value = string_slice },
        .signature_param_nodes => .{ .key = type_id, .value = node_slice },
        .fn_predicates => .{ .key = string_id, .value = predicate },
        .signature_predicates => .{ .key = type_id, .value = predicate },
        .member_predicates => .{ .key = type_member, .value = predicate },
        .signature_param_predicates => .{ .key = signature_param, .value = predicate },
        .signature_param_this_types => .{ .key = signature_param, .value = type_id },
        .overloads, .class_constructor_overload_sigs => .{ .key = string_id, .value = type_list },
        .overload_decls => .{ .key = string_id, .value = node_list },
        .overload_has_implementation,
        .abstract_classes,
        .private_constructor_classes,
        .protected_constructor_classes,
        .recursive_indexed_access_aliases,
        .recursive_mapped_index_aliases,
        .const_enums,
        .ambient_const_enums,
        .numeric_enums,
        .jsdoc_generic_typedef_aliases,
        => .{ .key = string_id, .value = scalar },
        .mapped_type_params,
        .class_this_types,
        .class_static_type_by_node,
        .namespace_value_object_types,
        => .{ .key = node_id, .value = type_id },
        .commonjs_export_narrows, .checkjs_object_expando_narrows => .{ .key = member, .value = type_id },
        .class_name_by_instance,
        .class_name_by_static,
        .named_type_by_id,
        .enum_nominal_names,
        .synthetic_program_class_origins,
        => .{ .key = type_id, .value = string_id },
        .interface_extends_visibility_class, .class_parent => .{ .key = string_id, .value = string_id },
        .class_accessor_setter_types => .{ .key = accessor, .value = type_id },
        .last_iface_decl_for_name => .{ .key = string_id, .value = node_id },
        .enum_member_values, .enum_member_string_syntax => .{ .key = member, .value = scalar },
        .enum_member_string_values => .{ .key = member, .value = string_id },
        .var_decl_types => .{ .key = variable, .value = type_id },
        .var_decl_explicit => .{ .key = variable, .value = scalar },
        .var_decl_jsdoc_type_names => .{ .key = variable, .value = string_id },
        .var_decl_annotation_nodes => .{ .key = variable, .value = node_id },
        .index_param_names => .{ .key = type_id, .value = index_names },
        .generator_type_info => .{ .key = type_id, .value = generator },
        .interface_merge_predecessor => .{ .key = node_id, .value = node_id },
        .class_private_members,
        .class_protected_members,
        .class_static_private_members,
        .class_static_protected_members,
        .class_instance_member_names,
        .class_static_member_names,
        .class_abstract_members,
        .class_property_members,
        .class_accessor_members,
        .class_getter_members,
        .class_static_getter_members,
        .class_method_members,
        .class_private_method_members,
        .class_static_private_method_members,
        .class_private_set_only_accessors,
        .class_static_private_set_only_accessors,
        => .{ .key = string_id, .value = name_set },
        .class_abstract_members_order => .{ .key = string_id, .value = string_list },
        .class_abstract_property_origins => .{ .key = string_id, .value = name_map },
        .pattern_index_signatures => .{ .key = type_id, .value = .{ .slice = &pattern } },
        .symbolic_tuple_layouts => .{ .key = type_id, .value = .{ .slice = &symbolic_segment } },
    };
}

/// Clone a single owner's metadata into the destination identifier spaces.
/// Retain this record separately from all other owners, even if keys compare
/// equal. The caller must keep the mapped type pool and provenance alive.
/// A many-to-one mapping within a table fails explicitly; no entry wins by
/// iteration order, including when structurally equal signatures coalesce.
pub fn clone(
    allocator: std.mem.Allocator,
    source: *const check.CheckedTypes,
    ids: transfer.Relocation,
    names: transfer.Names,
) Error!check.CheckedTypes {
    @setEvalBranchQuota(30000);
    const copier = Copier{ .allocator = allocator, .ids = ids, .names = names };
    var result: check.CheckedTypes = .{};
    errdefer result.deinit(allocator);
    inline for (comptime std.meta.fieldNames(check.CheckedTypes)) |name| {
        const shape: Shape = comptime .{ .map = &tableShape(@field(std.meta.FieldEnum(check.CheckedTypes), name)) };
        @field(result, name) = try copier.copy(@FieldType(check.CheckedTypes, name), shape, @field(source, name));
    }
    return result;
}

const Copier = struct {
    allocator: std.mem.Allocator,
    ids: transfer.Relocation,
    names: transfer.Names,

    fn copy(self: Copier, comptime Value: type, comptime shape: Shape, source: Value) Error!Value {
        switch (shape) {
            .scalar => switch (@typeInfo(Value)) {
                .int, .float, .bool, .@"enum", .void => return source,
                else => @compileError("Non-scalar metadata needs an explicit transfer shape: " ++ @typeName(Value)),
            },
            .type_id => return self.ids.typeId(source),
            .string_id, .node_id => {
                if (source == 0) return 0;
                const mapped = if (shape == .string_id)
                    try self.names.string(self.names.context, source)
                else
                    try self.names.declaration(self.names.context, source);
                if (mapped == 0) return error.UnmappedName;
                return mapped;
            },
            .slice => |element| {
                const Child = @typeInfo(Value).pointer.child;
                const result = try self.allocator.alloc(Child, source.len);
                var initialized: usize = 0;
                errdefer {
                    for (result[0..initialized]) |item| release(self.allocator, Child, element.*, item);
                    self.allocator.free(result);
                }
                for (source, result) |item, *output| {
                    output.* = try self.copy(Child, element.*, item);
                    initialized += 1;
                }
                return result;
            },
            .list => |element| {
                var result: Value = .empty;
                errdefer release(self.allocator, Value, shape, result);
                try result.ensureTotalCapacity(self.allocator, source.items.len);
                for (source.items) |item| result.appendAssumeCapacity(try self.copy(@TypeOf(item), element.*, item));
                return result;
            },
            .map => |mapping| {
                var result: Value = .empty;
                errdefer release(self.allocator, Value, shape, result);
                try result.ensureTotalCapacity(self.allocator, source.count());
                var entries = source.iterator();
                while (entries.next()) |entry| {
                    const key = try self.copy(@TypeOf(entry.key_ptr.*), mapping.key, entry.key_ptr.*);
                    errdefer release(self.allocator, @TypeOf(key), mapping.key, key);
                    if (result.contains(key)) return error.MetadataCollision;
                    const value = try self.copy(@TypeOf(entry.value_ptr.*), mapping.value, entry.value_ptr.*);
                    result.putAssumeCapacityNoClobber(key, value);
                }
                return result;
            },
            .fields => |fields| {
                comptime validateFields(Value, fields);
                var result: Value = undefined;
                var initialized: usize = 0;
                errdefer inline for (fields, 0..) |field, i| {
                    if (i < initialized) release(self.allocator, @FieldType(Value, field.name), field.shape, @field(result, field.name));
                };
                inline for (fields) |field| {
                    @field(result, field.name) = try self.copy(@FieldType(Value, field.name), field.shape, @field(source, field.name));
                    initialized += 1;
                }
                return result;
            },
        }
    }
};

fn validateFields(comptime Value: type, comptime fields: []const FieldShape) void {
    const declared = std.meta.fieldNames(Value);
    if (declared.len != fields.len) @compileError("Update metadata transfer fields for " ++ @typeName(Value));
    for (declared) |field| {
        var matches: usize = 0;
        for (fields) |shape| {
            if (std.mem.eql(u8, shape.name, field)) matches += 1;
        }
        if (matches != 1) @compileError("Missing or repeated metadata transfer field: " ++ field);
    }
}

fn release(allocator: std.mem.Allocator, comptime Value: type, comptime shape: Shape, value: Value) void {
    switch (shape) {
        .scalar, .type_id, .string_id, .node_id => {},
        .slice => |element| {
            for (value) |item| release(allocator, @TypeOf(item), element.*, item);
            allocator.free(value);
        },
        .list => |element| {
            for (value.items) |item| release(allocator, @TypeOf(item), element.*, item);
            var owned = value;
            owned.deinit(allocator);
        },
        .map => |mapping| {
            var entries = value.iterator();
            while (entries.next()) |entry| {
                release(allocator, @TypeOf(entry.key_ptr.*), mapping.key, entry.key_ptr.*);
                release(allocator, @TypeOf(entry.value_ptr.*), mapping.value, entry.value_ptr.*);
            }
            var owned = value;
            owned.deinit(allocator);
        },
        .fields => |fields| inline for (fields) |field| release(allocator, @FieldType(Value, field.name), field.shape, @field(value, field.name)),
    }
}

const T = std.testing;

const TestNames = struct {
    reject: bool = false,
    collapse: bool = false,
    zero: bool = false,

    fn string(context: *anyopaque, id: u32) transfer.Error!u32 {
        const self: *TestNames = @ptrCast(@alignCast(context));
        if (self.reject) return error.UnmappedName;
        if (self.zero) return 0;
        return 2000 + if (self.collapse) @as(u32, 27) else id;
    }

    fn node(context: *anyopaque, id: u32) transfer.Error!u32 {
        const self: *TestNames = @ptrCast(@alignCast(context));
        if (self.reject) return error.UnmappedName;
        if (self.zero) return 0;
        return 3000 + if (self.collapse) @as(u32, 27) else id;
    }

    fn callbacks(self: *TestNames) transfer.Names {
        return .{ .context = self, .string = string, .declaration = node };
    }
};

fn testIds(buffer: *[64]u32) transfer.Relocation {
    for (buffer, 0..) |*id, i| id.* = @intCast(if (i < 16) i else i + 100);
    return .{ .allocator = T.allocator, .ids = buffer, .source_count = buffer.len, .destination_start = 116 };
}

fn sample(comptime Value: type, comptime shape: Shape) !Value {
    switch (shape) {
        .type_id, .string_id, .node_id => return 27,
        .scalar => return switch (@typeInfo(Value)) {
            .int => 17,
            .float => 1.25,
            .bool => true,
            .@"enum" => @fromBackingInt(@intCast(0)),
            .void => {},
            else => @compileError("unclassified scalar"),
        },
        .slice => |element| {
            const Child = @typeInfo(Value).pointer.child;
            const result = try T.allocator.alloc(Child, 2);
            var initialized: usize = 0;
            errdefer {
                for (result[0..initialized]) |item| release(T.allocator, Child, element.*, item);
                T.allocator.free(result);
            }
            for (result) |*item| {
                item.* = try sample(Child, element.*);
                initialized += 1;
            }
            return result;
        },
        .list => |element| {
            var result: Value = .empty;
            errdefer release(T.allocator, Value, shape, result);
            try result.ensureTotalCapacity(T.allocator, 2);
            for (0..2) |_| result.appendAssumeCapacity(try sample(@typeInfo(@FieldType(Value, "items")).pointer.child, element.*));
            return result;
        },
        .map => |mapping| {
            var result: Value = .empty;
            errdefer release(T.allocator, Value, shape, result);
            try result.ensureTotalCapacity(T.allocator, 1);
            const Entry = Value.Entry;
            const Key = @typeInfo(@FieldType(Entry, "key_ptr")).pointer.child;
            const Item = @typeInfo(@FieldType(Entry, "value_ptr")).pointer.child;
            const key = try sample(Key, mapping.key);
            errdefer release(T.allocator, Key, mapping.key, key);
            result.putAssumeCapacityNoClobber(key, try sample(Item, mapping.value));
            return result;
        },
        .fields => |fields| {
            comptime validateFields(Value, fields);
            var result: Value = undefined;
            var initialized: usize = 0;
            errdefer inline for (fields, 0..) |field, i| {
                if (i < initialized) release(T.allocator, @FieldType(Value, field.name), field.shape, @field(result, field.name));
            };
            inline for (fields) |field| {
                @field(result, field.name) = try sample(@FieldType(Value, field.name), field.shape);
                initialized += 1;
            }
            return result;
        },
    }
}

fn sampleTables() !check.CheckedTypes {
    @setEvalBranchQuota(30000);
    var result: check.CheckedTypes = .{};
    errdefer result.deinit(T.allocator);
    inline for (comptime std.meta.fieldNames(check.CheckedTypes)) |name| {
        @field(result, name) = try sample(@FieldType(check.CheckedTypes, name), .{ .map = &tableShape(@field(std.meta.FieldEnum(check.CheckedTypes), name)) });
    }
    return result;
}

fn expectSample(comptime Value: type, comptime shape: Shape, value: Value, remapped: bool) !void {
    switch (shape) {
        .type_id => try T.expectEqual(@as(Value, if (remapped) 127 else 27), value),
        .string_id => try T.expectEqual(@as(Value, if (remapped) 2027 else 27), value),
        .node_id => try T.expectEqual(@as(Value, if (remapped) 3027 else 27), value),
        .scalar => try T.expectEqual(try sample(Value, .scalar), value),
        .slice => |element| {
            try T.expectEqual(@as(usize, 2), value.len);
            for (value) |item| try expectSample(@TypeOf(item), element.*, item, remapped);
        },
        .list => |element| {
            try T.expectEqual(@as(usize, 2), value.items.len);
            for (value.items) |item| try expectSample(@TypeOf(item), element.*, item, remapped);
        },
        .map => |mapping| {
            try T.expectEqual(@as(usize, 1), value.count());
            var entries = value.iterator();
            while (entries.next()) |entry| {
                try expectSample(@TypeOf(entry.key_ptr.*), mapping.key, entry.key_ptr.*, remapped);
                try expectSample(@TypeOf(entry.value_ptr.*), mapping.value, entry.value_ptr.*, remapped);
            }
        },
        .fields => |fields| inline for (fields) |field| try expectSample(@FieldType(Value, field.name), field.shape, @field(value, field.name), remapped),
    }
}

fn expectTables(value: *const check.CheckedTypes, remapped: bool) !void {
    @setEvalBranchQuota(30000);
    inline for (comptime std.meta.fieldNames(check.CheckedTypes)) |name| {
        try expectSample(@FieldType(check.CheckedTypes, name), .{ .map = &tableShape(@field(std.meta.FieldEnum(check.CheckedTypes), name)) }, @field(value, name), remapped);
    }
}

fn testCloneFailures(allocator: std.mem.Allocator) !void {
    var source = try sampleTables();
    defer source.deinit(T.allocator);
    var buffer: [64]u32 = undefined;
    var names: TestNames = .{};
    var result = clone(allocator, &source, testIds(&buffer), names.callbacks()) catch |err| {
        try expectTables(&source, false);
        return err;
    };
    defer result.deinit(allocator);
    try expectTables(&source, false);
    source.deinit(T.allocator);
    try expectTables(&result, true);
}

test "checked transfer: all tables own remapped leaves and survive source destruction and OOM" {
    try T.checkAllAllocationFailures(T.allocator, testCloneFailures, .{});
}

test "checked transfer: mixed keys preserve positions flags offsets and empty sentinels" {
    var source = try sampleTables();
    defer source.deinit(T.allocator);
    try source.signature_predicates.put(T.allocator, 28, .{
        .param_index = 0xffff,
        .target_type = 0,
        .target_node = 0,
        .is_asserts = false,
    });
    try source.index_param_names.put(T.allocator, 28, .{});
    var buffer: [64]u32 = undefined;
    var names: TestNames = .{};
    var result = try clone(T.allocator, &source, testIds(&buffer), names.callbacks());
    defer result.deinit(T.allocator);
    const pred = result.signature_param_predicates.get(.{ .signature = 127, .param_index = 17 }).?;
    try T.expectEqual(@as(u16, 17), pred.param_index);
    try T.expectEqual(@as(u32, 127), pred.target_type);
    try T.expectEqual(@as(u32, 3027), pred.target_node);
    try T.expect(pred.is_asserts);
    try T.expect(result.member_predicates.contains(.{ .receiver_type = 127, .member_name = 2027 }));
    try T.expectEqual(@as(u32, 127), result.var_decl_types.get(.{ .scope = 3027, .name = 2027, .virtual_section_start = 17 }).?);
    try T.expectEqual(@as(u32, 3027), result.var_decl_annotation_nodes.get(.{ .scope = 3027, .name = 2027, .virtual_section_start = 17 }).?);
    try T.expectEqual(@as(u32, 127), result.class_accessor_setter_types.get(.{ .class_name = 2027, .member_name = 2027, .is_static = true }).?);
    try T.expectEqual(@as(u32, 3027), result.index_param_names.get(127).?.string_decl);
    try T.expectEqual(@as(u32, 2027), result.index_param_names.get(127).?.string);
    const empty = result.signature_predicates.get(128).?;
    try T.expectEqual(@as(u16, 0xffff), empty.param_index);
    try T.expectEqual(@as(u32, 0), empty.target_type);
    try T.expectEqual(@as(u32, 0), empty.target_node);
    try T.expect(!empty.is_asserts);
    try T.expectEqual(@as(u32, 0), result.index_param_names.get(128).?.string);
    try T.expectEqual(@as(u32, 0), result.index_param_names.get(128).?.string_decl);
}

test "checked transfer: invalid references mappings and key collisions fail without changing source" {
    var source = try sampleTables();
    defer source.deinit(T.allocator);
    var buffer: [64]u32 = undefined;
    const ids = testIds(&buffer);
    var names: TestNames = .{ .reject = true };
    try T.expectError(error.UnmappedName, clone(T.allocator, &source, ids, names.callbacks()));
    names = .{ .zero = true };
    try T.expectError(error.UnmappedName, clone(T.allocator, &source, ids, names.callbacks()));
    names = .{};
    buffer[27] = 0;
    try T.expectError(error.InvalidTypeGraph, clone(T.allocator, &source, ids, names.callbacks()));
    buffer[27] = 127;
    try T.expectError(error.InvalidTypeGraph, clone(T.allocator, &source, .{
        .allocator = T.allocator,
        .ids = buffer[0..20],
        .source_count = 20,
        .destination_start = 116,
    }, names.callbacks()));
    try expectTables(&source, false);
    try source.rest_signatures.put(T.allocator, 28, {});
    buffer[28] = 127;
    try T.expectError(error.MetadataCollision, clone(T.allocator, &source, ids, names.callbacks()));
    try T.expect(source.rest_signatures.remove(28));
    buffer[28] = 128;
    try source.type_names.put(T.allocator, 28, 28);
    names = .{ .collapse = true };
    try T.expectError(error.MetadataCollision, clone(T.allocator, &source, ids, names.callbacks()));
    try T.expect(source.type_names.remove(28));
    try source.generic_interfaces_by_decl.put(T.allocator, 28, .{ .params = &.{}, .body = 28 });
    try T.expectError(error.MetadataCollision, clone(T.allocator, &source, ids, names.callbacks()));
    try T.expect(source.generic_interfaces_by_decl.remove(28));
    names = .{};
    var result = try clone(T.allocator, &source, ids, names.callbacks());
    defer result.deinit(T.allocator);
    try expectTables(&source, false);
    try expectTables(&result, true);
}

const Interner = @import("interner.zig").Interner;
const Pool = @import("types.zig").Pool;
const PoolLengths = std.enums.EnumArray(std.meta.FieldEnum(Pool), usize);

fn poolLengths(pool: *const Pool) PoolLengths {
    var result = PoolLengths.initFill(0);
    inline for (comptime std.meta.fieldNames(Pool)) |name| {
        if (comptime !std.mem.eql(u8, name, "gpa")) result.set(@field(std.meta.FieldEnum(Pool), name), @field(pool, name).items.len);
    }
    return result;
}

fn internKeyCount(value: *const Interner) usize {
    var count: usize = 0;
    for (&value.shards) |*shard| count += shard.table.count();
    return count;
}

fn sampleInterner() !Interner {
    var result = try Interner.init(T.allocator);
    errdefer result.deinit();
    for (0..48) |index| _ = try result.internNumberLiteral(@floatFromInt(index));
    return result;
}

fn testCombinedAllocationFailures(allocator: std.mem.Allocator) !void {
    var source = try sampleInterner();
    defer source.deinit();
    var checked = try sampleTables();
    defer checked.deinit(T.allocator);
    var target = try Interner.init(allocator);
    defer target.deinit();
    const old = try target.internNumberLiteral(-1);
    const before = poolLengths(&target.pool);
    const keys = internKeyCount(&target);
    var names: TestNames = .{};
    var result = append(&target, &source, &checked, names.callbacks()) catch |err| {
        try T.expectEqualDeep(before, poolLengths(&target.pool));
        try T.expectEqual(keys, internKeyCount(&target));
        try T.expectEqual(@as(usize, 0), target.enum_literal_info.count());
        try T.expectEqual(old, try target.internNumberLiteral(-1));
        try expectTables(&checked, false);
        return err;
    };
    defer result.deinit();
    try T.expectEqual(try result.ids.typeId(27), result.checked.type_names.get(2027).?);
    checked.deinit(T.allocator);
    try T.expect(result.checked.class_private_members.get(2027).?.contains(2027));
}

test "checked transfer: combined payload and metadata publication rolls back on every allocation failure" {
    try T.checkAllAllocationFailures(T.allocator, testCombinedAllocationFailures, .{});
}

test "checked transfer: failures after payload preparation cancel every new type and key" {
    var source = try sampleInterner();
    defer source.deinit();
    var checked = try sampleTables();
    defer checked.deinit(T.allocator);
    var target = try Interner.init(T.allocator);
    defer target.deinit();
    _ = try target.internNumberLiteral(-1);
    const before = poolLengths(&target.pool);
    const keys = internKeyCount(&target);
    // Pure numeric payloads do not call the name mapper. These failures are
    // therefore necessarily AFTER the complete payload graph was prepared.
    var names: TestNames = .{ .reject = true };
    try T.expectError(error.UnmappedName, append(&target, &source, &checked, names.callbacks()));
    try T.expectEqualDeep(before, poolLengths(&target.pool));
    try T.expectEqual(keys, internKeyCount(&target));
    try checked.type_names.put(T.allocator, 28, 28);
    names = .{ .collapse = true };
    try T.expectError(error.MetadataCollision, append(&target, &source, &checked, names.callbacks()));
    try T.expectEqualDeep(before, poolLengths(&target.pool));
    try T.expectEqual(keys, internKeyCount(&target));
    try T.expect(checked.type_names.remove(28));
    names = .{};
    var result = try append(&target, &source, &checked, names.callbacks());
    defer result.deinit();
    try T.expectEqual(try result.ids.typeId(27), result.checked.type_names.get(2027).?);
}
