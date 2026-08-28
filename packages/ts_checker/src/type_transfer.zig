//! Owner-specific transfer into the destination's canonical type interner.
//!
//! This is a payload primitive, not an import resolver. CheckedTypes and real
//! source-node provenance must also be transferred before Checker consumes
//! imported types. Both source and destination require exclusive ownership
//! during this operation; name callbacks must not query or mutate type pools.

const std = @import("std");
const hir = @import("hir");
const types = @import("types.zig");
const interner = @import("interner.zig");

pub const Error = error{ OutOfMemory, InvalidTypeGraph, UnmappedName, TypeIdOverflow };

/// Map strings by contents and declarations by source-owner identity. Calls
/// must be consistent; distinct declarations must not collapse. Callback-side
/// string/provenance allocations are owned by the caller and are not rolled
/// back by this payload operation.
pub const Names = struct {
    context: *anyopaque,
    string: *const fn (*anyopaque, types.StringId) Error!types.StringId,
    declaration: *const fn (*anyopaque, hir.NodeId) Error!hir.NodeId,
};

/// IDs are source-owner-specific. Literals/structural keys may reuse existing
/// destination IDs; objects, type parameters and callable identities stay fresh.
pub const Relocation = struct {
    allocator: std.mem.Allocator,
    ids: []types.TypeId,
    source_count: u32,
    destination_start: types.TypeId,

    pub fn deinit(self: *Relocation) void {
        self.allocator.free(self.ids);
        self.ids = &.{};
    }

    pub fn typeId(self: Relocation, source: types.TypeId) Error!types.TypeId {
        if (source >= self.ids.len) return error.InvalidTypeGraph;
        const result = self.ids[source];
        if (source != types.Primitive.none and result == types.Primitive.none) return error.InvalidTypeGraph;
        return result;
    }
};

const Column = std.meta.FieldEnum(types.Pool);
const Offsets = std.enums.EnumArray(Column, u32);

/// Exclusive, unpublished destination state. Until commit/cancel, the caller
/// must not mutate or expose the destination pool, or run another transfer.
/// The pending value is uniquely owned and must not be copied. deinit cancels
/// unless commit has moved its relocation out to the caller.
pub const Pending = struct {
    target: *interner.Interner,
    lengths: Offsets,
    relocation: ?Relocation,

    pub fn ids(self: *const Pending) Relocation {
        return self.relocation.?; // Borrowed; do not deinit this view.
    }

    pub fn commit(self: *Pending) Relocation {
        const result = self.relocation.?;
        self.relocation = null;
        return result;
    }

    pub fn deinit(self: *Pending) void {
        if (self.relocation) |*relocation| {
            rollback(self.target, self.lengths);
            relocation.deinit();
            self.relocation = null;
        }
    }
};

fn payloadColumn(flags: types.TypeFlags) Error!Column {
    // Union flags include constituent flags; payload selection must not.
    if (flags.is_union) return .union_payloads;
    if (flags.is_intersection) return .intersection_payloads;
    if (flags.is_literal) return .literal_payloads;
    if (flags.is_conditional) return .conditional_payloads;
    if (flags.is_mapped) return .mapped_payloads;
    if (flags.is_indexed_access) return .indexed_access_payloads;
    if (flags.is_keyof) return .keyof_payloads;
    if (flags.is_template_literal) return .template_literal_payloads;
    if (flags.is_string_mapping) return .string_mapping_payloads;
    if (flags.is_tuple) return .tuple_payloads;
    if (flags.is_type_parameter) return .type_parameter_payloads;
    if (flags.is_signature) return .signature_payloads;
    if (flags.is_object_type) return .object_type_payloads;
    if (flags.is_instantiation) return .instantiation_payloads;
    return error.InvalidTypeGraph;
}

fn Element(comptime column: Column) type {
    return @typeInfo(@FieldType(@FieldType(types.Pool, @tagName(column)), "items")).pointer.child;
}

const Builder = struct {
    source: *const interner.Interner,
    target: *interner.Interner,
    names: Names,
    relocation: Relocation,
    signatures: []types.TypeId,

    fn string(self: *Builder, id: types.StringId) Error!types.StringId {
        return self.names.string(self.names.context, id);
    }

    fn node(self: *Builder, id: hir.NodeId) Error!hir.NodeId {
        if (id == hir.none_node_id) return id;
        const mapped = try self.names.declaration(self.names.context, id);
        if (mapped == hir.none_node_id) return error.UnmappedName;
        return mapped;
    }

    fn typeId(self: *Builder, id: types.TypeId) Error!types.TypeId {
        return self.relocation.typeId(id);
    }

    fn payload(self: *Builder, comptime column: Column, id: types.TypeId) Error!Element(column) {
        if (id >= self.source.pool.typeCount()) return error.InvalidTypeGraph;
        const index = self.source.pool.payloadOf(id);
        const values = @field(self.source.pool, @tagName(column)).items;
        if (index == 0 or index >= values.len) return error.InvalidTypeGraph;
        return values[index];
    }

    fn slice(self: *Builder, comptime column: Column, start: u32, len: u32) Error![]const Element(column) {
        const values = @field(self.source.pool, @tagName(column)).items;
        if (start > values.len or len > values.len - start or (start == 0 and len != 0)) return error.InvalidTypeGraph;
        return values[start..][0..len];
    }

    fn mappedTypes(self: *Builder, values: []const types.TypeId) Error![]types.TypeId {
        const result = try self.target.gpa.alloc(types.TypeId, values.len);
        errdefer self.target.gpa.free(result);
        for (values, result) |value, *mapped| mapped.* = try self.typeId(value);
        return result;
    }

    fn dependencies(self: *Builder, id: types.TypeId, output: *std.ArrayListUnmanaged(types.TypeId)) Error!void {
        const allocator = self.target.gpa;
        switch (try payloadColumn(self.source.pool.flagsOf(id))) {
            .literal_payloads, .object_type_payloads, .type_parameter_payloads => {},
            .union_payloads => {
                const p = try self.payload(.union_payloads, id);
                try output.appendSlice(allocator, try self.slice(.member_pool, p.members_start, p.members_len));
            },
            .intersection_payloads => {
                const p = try self.payload(.intersection_payloads, id);
                try output.appendSlice(allocator, try self.slice(.member_pool, p.members_start, p.members_len));
            },
            .conditional_payloads => {
                const p = try self.payload(.conditional_payloads, id);
                try output.appendSlice(allocator, &.{ p.check_type, p.extends_type, p.true_branch, p.false_branch });
            },
            .mapped_payloads => {
                const p = try self.payload(.mapped_payloads, id);
                try output.appendSlice(allocator, &.{ p.constraint, p.template });
            },
            .indexed_access_payloads => {
                const p = try self.payload(.indexed_access_payloads, id);
                try output.appendSlice(allocator, &.{ p.object, p.index });
            },
            .keyof_payloads => try output.append(allocator, (try self.payload(.keyof_payloads, id)).operand),
            .template_literal_payloads => {
                const p = try self.payload(.template_literal_payloads, id);
                try output.appendSlice(allocator, try self.slice(.type_arg_pool, p.types_start, p.types_len));
            },
            .string_mapping_payloads => try output.append(allocator, (try self.payload(.string_mapping_payloads, id)).inner),
            .tuple_payloads => {
                const p = try self.payload(.tuple_payloads, id);
                for (try self.slice(.tuple_element_pool, p.elements_start, p.elements_len)) |element| try output.append(allocator, element.type);
            },
            .signature_payloads => {
                const p = try self.payload(.signature_payloads, id);
                try output.appendSlice(allocator, try self.slice(.type_arg_pool, p.params_start, p.params_len));
                try output.appendSlice(allocator, try self.slice(.type_arg_pool, p.type_params_start, p.type_params_len));
                try output.appendSlice(allocator, &.{ p.return_type, p.this_type });
            },
            .instantiation_payloads => {
                const p = try self.payload(.instantiation_payloads, id);
                try output.append(allocator, p.origin);
                try output.appendSlice(allocator, try self.slice(.type_arg_pool, p.args_start, p.args_len));
            },
            else => return error.InvalidTypeGraph,
        }
    }

    fn materialize(self: *Builder, id: types.TypeId) Error!types.TypeId {
        const target = self.target;
        const allocator = target.gpa;
        const header = self.source.pool.headers.items[id];
        // Header declaration identities are currently produced only for
        // fresh object types, not interned structural keys.
        if (header.symbol != 0) return error.InvalidTypeGraph;
        return switch (try payloadColumn(header.flags)) {
            .literal_payloads => blk: {
                const value = try self.payload(.literal_payloads, id);
                if (header.flags.is_enum_literal) {
                    const identity = self.source.enum_literal_info.get(id) orelse return error.InvalidTypeGraph;
                    const mapped: types.LiteralData = switch (value) {
                        .string_lit => |text| .{ .string_lit = try self.string(text) },
                        .number_lit => value,
                        else => return error.InvalidTypeGraph,
                    };
                    // Enum declaration identity is owner-relative, not merely
                    // its display name. Keep the fresh ID for metadata import.
                    const payload_index: u32 = @intCast(target.pool.literal_payloads.items.len);
                    try target.pool.literal_payloads.append(allocator, mapped);
                    const result = target.pool.typeCount();
                    try target.pool.headers.append(allocator, .{ .flags = header.flags, .symbol = 0, .payload = payload_index });
                    try target.enum_literal_info.put(allocator, result, .{
                        .enum_name = try self.string(identity.enum_name),
                        .member_name = try self.string(identity.member_name),
                    });
                    break :blk result;
                }
                break :blk switch (value) {
                    .string_lit => |text| try target.internStringLiteral(try self.string(text)),
                    .number_lit => |bits| try target.internNumberLiteral(@bitCast(bits)),
                    .bigint_lit => |text| try target.internBigIntLiteral(try self.string(text)),
                    .boolean_lit => |value_bool| target.internBooleanLiteral(value_bool),
                };
            },
            .union_payloads => blk: {
                const p = try self.payload(.union_payloads, id);
                const members = try self.mappedTypes(try self.slice(.member_pool, p.members_start, p.members_len));
                defer allocator.free(members);
                break :blk try target.internUnion(members);
            },
            .intersection_payloads => blk: {
                const p = try self.payload(.intersection_payloads, id);
                const members = try self.mappedTypes(try self.slice(.member_pool, p.members_start, p.members_len));
                defer allocator.free(members);
                break :blk try target.internIntersection(members);
            },
            .conditional_payloads => blk: {
                const p = try self.payload(.conditional_payloads, id);
                break :blk try target.internConditionalWithDistribution(try self.typeId(p.check_type), try self.typeId(p.extends_type), try self.typeId(p.true_branch), try self.typeId(p.false_branch), p.is_distributive);
            },
            .mapped_payloads => blk: {
                const p = try self.payload(.mapped_payloads, id);
                break :blk try target.internMapped(try self.typeId(p.constraint), try self.typeId(p.template), p.readonly, p.optional);
            },
            .indexed_access_payloads => blk: {
                const p = try self.payload(.indexed_access_payloads, id);
                break :blk try target.internIndexedAccess(try self.typeId(p.object), try self.typeId(p.index));
            },
            .keyof_payloads => try target.internKeyof(try self.typeId((try self.payload(.keyof_payloads, id)).operand)),
            .template_literal_payloads => blk: {
                const p = try self.payload(.template_literal_payloads, id);
                const source_texts = try self.slice(.string_id_pool, p.texts_start, p.texts_len);
                const texts = try allocator.alloc(types.StringId, source_texts.len);
                defer allocator.free(texts);
                for (source_texts, texts) |text, *mapped| mapped.* = try self.string(text);
                const args = try self.mappedTypes(try self.slice(.type_arg_pool, p.types_start, p.types_len));
                defer allocator.free(args);
                break :blk try target.internTemplateLiteral(texts, args);
            },
            .string_mapping_payloads => blk: {
                const p = try self.payload(.string_mapping_payloads, id);
                break :blk try target.internStringMapping(p.kind, try self.typeId(p.inner));
            },
            .tuple_payloads => blk: {
                const p = try self.payload(.tuple_payloads, id);
                const elements = try allocator.dupe(types.TupleElement, try self.slice(.tuple_element_pool, p.elements_start, p.elements_len));
                defer allocator.free(elements);
                for (elements) |*element| element.type = try self.typeId(element.type);
                break :blk try target.internTupleType(elements);
            },
            .signature_payloads => blk: {
                const p = try self.payload(.signature_payloads, id);
                if (p.has_this_type != (p.this_type != types.Primitive.none)) return error.InvalidTypeGraph;
                const params = try self.mappedTypes(try self.slice(.type_arg_pool, p.params_start, p.params_len));
                defer allocator.free(params);
                const result = try target.internSignatureWithThisType(params, try self.typeId(p.return_type), p.is_construct, p.is_abstract_construct, try self.typeId(p.this_type));
                const generics = try self.mappedTypes(try self.slice(.type_arg_pool, p.type_params_start, p.type_params_len));
                defer allocator.free(generics);
                const index = target.pool.payloadOf(result);
                if (result < self.relocation.destination_start) {
                    const existing = target.pool.signature_payloads.items[index];
                    const existing_params = target.pool.type_arg_pool.items[existing.type_params_start..][0..existing.type_params_len];
                    if (!std.mem.eql(types.TypeId, generics, existing_params)) return error.InvalidTypeGraph;
                } else if (generics.len != 0) {
                    const start: u32 = @intCast(target.pool.type_arg_pool.items.len);
                    try target.pool.type_arg_pool.appendSlice(allocator, generics);
                    target.pool.signature_payloads.items[index].type_params_start = start;
                    target.pool.signature_payloads.items[index].type_params_len = @intCast(generics.len);
                }
                break :blk result;
            },
            .instantiation_payloads => blk: {
                const p = try self.payload(.instantiation_payloads, id);
                const args = try self.mappedTypes(try self.slice(.type_arg_pool, p.args_start, p.args_len));
                defer allocator.free(args);
                break :blk try target.internInstantiation(try self.typeId(p.origin), args);
            },
            else => error.InvalidTypeGraph,
        };
    }

    fn signaturePayload(self: *Builder, source_index: u32) Error!u32 {
        if (source_index == 0) return 0;
        if (source_index >= self.signatures.len or self.signatures[source_index] == 0) return error.InvalidTypeGraph;
        return self.target.pool.payloadOf(try self.typeId(self.signatures[source_index]));
    }

    fn finalizeFresh(self: *Builder, id: types.TypeId) Error!void {
        const target = self.target;
        const mapped_id = try self.typeId(id);
        switch (try payloadColumn(self.source.pool.flagsOf(id))) {
            .type_parameter_payloads => {
                const p = try self.payload(.type_parameter_payloads, id);
                const index = target.pool.payloadOf(mapped_id);
                target.pool.type_parameter_payloads.items[index].constraint = try self.typeId(p.constraint);
                target.pool.type_parameter_payloads.items[index].default = try self.typeId(p.default);
                const symbol = self.source.typeSymbol(id);
                if (symbol != 0) {
                    const mapped_symbol = try self.node(symbol);
                    if (mapped_symbol == 0) return error.UnmappedName;
                    target.setTypeSymbol(mapped_id, mapped_symbol);
                }
            },
            .object_type_payloads => {
                const p = try self.payload(.object_type_payloads, id);
                const source_members = try self.slice(.object_member_pool, p.members_start, p.members_len);
                const members_start: u32 = @intCast(target.pool.object_member_pool.items.len);
                for (source_members) |member| {
                    var mapped = member;
                    mapped.name = try self.string(member.name);
                    mapped.type = try self.typeId(member.type);
                    mapped.decl_node = try self.node(member.decl_node);
                    try target.pool.object_member_pool.append(target.gpa, mapped);
                }
                target.pool.object_type_payloads.items[target.pool.payloadOf(mapped_id)] = .{
                    .members_start = if (source_members.len == 0) 0 else members_start,
                    .members_len = p.members_len,
                    .call_sig = try self.signaturePayload(p.call_sig),
                    .construct_sig = try self.signaturePayload(p.construct_sig),
                    .string_index_type = try self.typeId(p.string_index_type),
                    .number_index_type = try self.typeId(p.number_index_type),
                    .symbol_index_type = try self.typeId(p.symbol_index_type),
                };
                const symbol = self.source.typeSymbol(id);
                if (symbol != 0) {
                    const mapped_symbol = try self.node(symbol);
                    if (mapped_symbol == 0) return error.UnmappedName;
                    target.setTypeSymbol(mapped_id, mapped_symbol);
                }
            },
            else => {},
        }
    }
};

/// Roll back unpublished keys before truncating their payload columns.
/// Arena capacity may remain, but no key or enum entry may refer to removed IDs.
fn rollback(target: *interner.Interner, lengths: Offsets) void {
    const first = lengths.get(.headers);
    for (&target.shards) |*shard| {
        shard.mu.lock();
        var entries = shard.table.iterator();
        while (entries.next()) |entry| {
            if (entry.value_ptr.* >= first) _ = shard.table.removeContext(entry.key_ptr.*, .{});
        }
        shard.mu.unlock();
    }
    var enums = target.enum_literal_info.iterator();
    while (enums.next()) |entry| {
        if (entry.key_ptr.* >= first) _ = target.enum_literal_info.remove(entry.key_ptr.*);
    }
    inline for (comptime std.meta.fieldNames(types.Pool)) |name| {
        const column = @field(Column, name);
        if (comptime column != .gpa) @field(target.pool, name).items.len = lengths.get(column);
    }
}

/// Transfer all represented types. Fresh declaration nodes break recursive
/// object/parameter cycles; structural dependencies are resolved iteratively,
/// then canonicalized through the normal interner. Unanchored cycles between
/// immutable intern keys cannot be constructed by Interner and are rejected.
/// On failure no new type, intern key, or enum entry remains published.
pub fn append(target: *interner.Interner, source: *const interner.Interner, names: Names) Error!Relocation {
    var pending = try prepare(target, source, names);
    return pending.commit();
}

/// Prepare payloads without publishing them, allowing semantic/provenance
/// preparation to join the same transaction. Caller must commit or deinit.
pub fn prepare(target: *interner.Interner, source: *const interner.Interner, names: Names) Error!Pending {
    if (target == source or target.pool.headers.items.ptr == source.pool.headers.items.ptr) return error.InvalidTypeGraph;
    const allocator = target.gpa;
    const count = source.pool.typeCount();
    if (count < types.Primitive.first_dynamic) return error.InvalidTypeGraph;
    // Existing interner builders use u32 indices. Bound the worst-case
    // combined columns before they allocate or narrow an index.
    if (source.pool.headers.items.len > std.math.maxInt(u32) - target.pool.headers.items.len) return error.TypeIdOverflow;
    var lengths = Offsets.initFill(0);
    inline for (comptime std.meta.fieldNames(types.Pool)) |name| {
        const column = @field(Column, name);
        if (comptime column != .gpa) {
            const first: usize = if (column == .headers) types.Primitive.first_dynamic else 1;
            if (@field(source.pool, name).items.len < first or @field(target.pool, name).items.len < first) return error.InvalidTypeGraph;
            if (@field(source.pool, name).items.len > std.math.maxInt(u32) - @field(target.pool, name).items.len) return error.TypeIdOverflow;
            lengths.set(column, @intCast(@field(target.pool, name).items.len));
        }
    }
    for (0..types.Primitive.first_dynamic) |id| {
        if (!std.meta.eql(source.pool.headers.items[id], target.pool.headers.items[id])) return error.InvalidTypeGraph;
    }
    var relocation: Relocation = .{
        .allocator = allocator,
        .ids = try allocator.alloc(types.TypeId, count),
        .source_count = count,
        .destination_start = target.pool.typeCount(),
    };
    errdefer relocation.deinit();
    @memset(relocation.ids, 0);
    for (0..types.Primitive.first_dynamic) |id| relocation.ids[id] = @intCast(id);
    const signatures = try allocator.alloc(types.TypeId, source.pool.signature_payloads.items.len);
    defer allocator.free(signatures);
    @memset(signatures, 0);
    var builder: Builder = .{ .source = source, .target = target, .names = names, .relocation = relocation, .signatures = signatures };
    errdefer rollback(target, lengths);
    // Allocate declaration-scoped identities before walking any structural
    // keys. Their constraints/members are filled only after all IDs resolve.
    for (types.Primitive.first_dynamic..count) |index| {
        const id: types.TypeId = @intCast(index);
        switch (try payloadColumn(source.pool.flagsOf(id))) {
            .object_type_payloads => {
                _ = try builder.payload(.object_type_payloads, id);
                relocation.ids[id] = try target.internObjectType(&.{});
            },
            .type_parameter_payloads => {
                const p = try builder.payload(.type_parameter_payloads, id);
                relocation.ids[id] = try target.internFreshTypeParameterWithFlags(try builder.string(p.name), types.Primitive.none, types.Primitive.none, p.variance, p.is_const);
            },
            .signature_payloads => {
                _ = try builder.payload(.signature_payloads, id);
                signatures[source.pool.payloadOf(id)] = id;
            },
            else => {},
        }
    }
    const state = try allocator.alloc(u8, count);
    defer allocator.free(state);
    @memset(state, 0);
    const Frame = struct { id: types.TypeId, start: usize, len: usize, next: usize = 0 };
    var stack: std.ArrayListUnmanaged(Frame) = .empty;
    defer stack.deinit(allocator);
    var edges: std.ArrayListUnmanaged(types.TypeId) = .empty;
    defer edges.deinit(allocator);
    for (types.Primitive.first_dynamic..count) |root_index| {
        const root: types.TypeId = @intCast(root_index);
        if (relocation.ids[root] != 0) continue;
        try builder.dependencies(root, &edges);
        try stack.append(allocator, .{ .id = root, .start = 0, .len = edges.items.len });
        state[root] = 1;
        while (stack.items.len != 0) {
            const top = &stack.items[stack.items.len - 1];
            if (top.next < top.len) {
                const child = edges.items[top.start + top.next];
                top.next += 1;
                if (child >= count) return error.InvalidTypeGraph;
                if (child < types.Primitive.first_dynamic or relocation.ids[child] != 0) continue;
                if (state[child] == 1) return error.InvalidTypeGraph;
                const start = edges.items.len;
                try builder.dependencies(child, &edges);
                try stack.append(allocator, .{ .id = child, .start = start, .len = edges.items.len - start });
                state[child] = 1;
            } else {
                const finished = top.*;
                relocation.ids[finished.id] = try builder.materialize(finished.id);
                state[finished.id] = 2;
                edges.items.len = finished.start;
                stack.items.len -= 1;
            }
        }
    }
    for (types.Primitive.first_dynamic..count) |index| try builder.finalizeFresh(@intCast(index));
    for (source.pool.signature_param_pool.items[1..]) |parameter| {
        var mapped = parameter;
        mapped.name = try builder.string(parameter.name);
        mapped.type = try builder.typeId(parameter.type);
        try target.pool.signature_param_pool.append(allocator, mapped);
    }
    var enum_entries = source.enum_literal_info.iterator();
    while (enum_entries.next()) |entry| {
        if (entry.key_ptr.* < types.Primitive.first_dynamic or entry.key_ptr.* >= count or
            !source.pool.flagsOf(entry.key_ptr.*).is_enum_literal or
            try payloadColumn(source.pool.flagsOf(entry.key_ptr.*)) != .literal_payloads) return error.InvalidTypeGraph;
    }
    return .{ .target = target, .lengths = lengths, .relocation = relocation };
}

const T = std.testing;

const TestNames = struct {
    string_base: u32 = 100,
    node_base: u32 = 1000,
    reject_node: bool = false,
    reject_string: bool = false,
    synthetic_node: bool = false,

    fn names(self: *TestNames) Names {
        return .{ .context = self, .string = mapString, .declaration = mapDeclaration };
    }

    fn mapString(context: *anyopaque, id: types.StringId) Error!types.StringId {
        const self: *TestNames = @ptrCast(@alignCast(context));
        if (self.reject_string) return error.UnmappedName;
        return if (id == 0) 0 else std.math.add(u32, id, self.string_base) catch error.TypeIdOverflow;
    }

    fn mapDeclaration(context: *anyopaque, id: hir.NodeId) Error!hir.NodeId {
        const self: *TestNames = @ptrCast(@alignCast(context));
        if (self.reject_node) return error.UnmappedName;
        if (self.synthetic_node) return 0;
        return std.math.add(u32, id, self.node_base) catch error.TypeIdOverflow;
    }
};

const TestGraph = struct {
    text: types.TypeId,
    number: types.TypeId,
    bigint: types.TypeId,
    enumeration: types.TypeId,
    parameter: types.TypeId,
    object: types.TypeId,
    signature: types.TypeId,
    union_type: types.TypeId,
    intersection: types.TypeId,
    conditional: types.TypeId,
    mapped: types.TypeId,
    indexed: types.TypeId,
    keyof_type: types.TypeId,
    template: types.TypeId,
    string_mapping: types.TypeId,
    tuple: types.TypeId,
    instance: types.TypeId,
};

fn addTestPayload(ti: *interner.Interner, comptime column: Column, payload: anytype, flags: types.TypeFlags) !types.TypeId {
    const values = &@field(ti.pool, @tagName(column));
    const index: u32 = @intCast(values.items.len);
    try values.append(ti.gpa, payload);
    const id: types.TypeId = ti.pool.typeCount();
    try ti.pool.headers.append(ti.gpa, .{ .flags = flags, .payload = index, .symbol = 0 });
    return id;
}

fn testGraph(ti: *interner.Interner) !TestGraph {
    const p = types.Primitive;
    const text = try ti.internStringLiteral(10);
    const number = try ti.internNumberLiteral(42.5);
    const bigint = try ti.internBigIntLiteral(20);
    const enumeration = try ti.internEnumStringLiteral(10, 30, 40);
    const parameter = try ti.internFreshTypeParameterWithFlags(50, p.unknown, text, .contravariant, true);
    const object = try ti.internObjectTypeWithIndexAndSymbol(&.{
        .{ .name = 60, .type = parameter, .is_optional = true, .is_readonly = true, .is_method = false, .visibility = .private, .decl_node = 7 },
        .{ .name = 70, .type = parameter, .is_optional = false, .is_readonly = false, .is_method = true },
    }, text, number, bigint);
    ti.setTypeSymbol(object, 9);
    // A recursive generic constraint plus shared members exercises forward
    // and back edges without recursive traversal or placeholder erasure.
    ti.pool.type_parameter_payloads.items[ti.pool.payloadOf(parameter)].constraint = object;
    const signature = try ti.internSignatureWithThisType(&.{ parameter, object }, object, true, true, object);
    const signature_payload = ti.pool.payloadOf(signature);
    const tp_start: u32 = @intCast(ti.pool.type_arg_pool.items.len);
    try ti.pool.type_arg_pool.append(ti.gpa, parameter);
    ti.pool.signature_payloads.items[signature_payload].type_params_start = tp_start;
    ti.pool.signature_payloads.items[signature_payload].type_params_len = 1;
    ti.pool.object_type_payloads.items[ti.pool.payloadOf(object)].call_sig = signature_payload;
    ti.pool.object_type_payloads.items[ti.pool.payloadOf(object)].construct_sig = signature_payload;
    try ti.pool.signature_param_pool.append(ti.gpa, .{ .name = 80, .type = parameter, .is_optional = true, .is_rest = true });
    const union_type = try ti.internUnion(&.{ text, enumeration, signature, parameter });
    const intersection = try ti.internIntersection(&.{ object, parameter });
    const conditional = try ti.internConditionalWithDistribution(parameter, object, text, number, false);
    const keyof_type = try ti.internKeyof(object);
    const indexed = try ti.internIndexedAccess(object, parameter);
    const mapped = try ti.internMapped(keyof_type, indexed, .remove, .add);
    const template = try ti.internTemplateLiteral(&.{ 10, 20 }, &.{parameter});
    const string_mapping = try ti.internStringMapping(.capitalize, template);
    const elements_start: u32 = @intCast(ti.pool.tuple_element_pool.items.len);
    try ti.pool.tuple_element_pool.appendSlice(ti.gpa, &.{
        .{ .type = text, .is_optional = true, .is_rest = false },
        .{ .type = parameter, .is_optional = false, .is_rest = true },
    });
    const tuple = try addTestPayload(ti, .tuple_payloads, types.TuplePayload{ .elements_start = elements_start, .elements_len = 2 }, .{ .is_tuple = true });
    const args_start: u32 = @intCast(ti.pool.type_arg_pool.items.len);
    try ti.pool.type_arg_pool.appendSlice(ti.gpa, &.{ text, tuple });
    const instance = try addTestPayload(ti, .instantiation_payloads, types.InstantiationPayload{ .origin = object, .args_start = args_start, .args_len = 2 }, .{ .is_instantiation = true });
    return .{
        .text = text,
        .number = number,
        .bigint = bigint,
        .enumeration = enumeration,
        .parameter = parameter,
        .object = object,
        .signature = signature,
        .union_type = union_type,
        .intersection = intersection,
        .conditional = conditional,
        .mapped = mapped,
        .indexed = indexed,
        .keyof_type = keyof_type,
        .template = template,
        .string_mapping = string_mapping,
        .tuple = tuple,
        .instance = instance,
    };
}

fn expectGraph(destination: *const interner.Interner, graph: TestGraph, relocation: Relocation) !void {
    const pool = &destination.pool;
    const parameter = try relocation.typeId(graph.parameter);
    const object = try relocation.typeId(graph.object);
    const signature = try relocation.typeId(graph.signature);
    const text = try relocation.typeId(graph.text);
    const number = try relocation.typeId(graph.number);
    try T.expectEqual(@as(u32, 110), pool.literal_payloads.items[pool.payloadOf(text)].string_lit);
    try T.expectEqual(@as(u64, @bitCast(@as(f64, 42.5))), pool.literal_payloads.items[pool.payloadOf(number)].number_lit);
    try T.expectEqual(@as(u32, 120), pool.literal_payloads.items[pool.payloadOf(try relocation.typeId(graph.bigint))].bigint_lit);
    const enum_id = try relocation.typeId(graph.enumeration);
    try T.expectEqualDeep(types.EnumLiteralInfo{ .enum_name = 130, .member_name = 140 }, destination.enumLiteralInfo(enum_id).?);
    try T.expectEqual(@as(u32, 110), pool.literal_payloads.items[pool.payloadOf(enum_id)].string_lit);
    const tp = pool.type_parameter_payloads.items[pool.payloadOf(parameter)];
    try T.expectEqualDeep(types.TypeParameterPayload{ .name = 150, .constraint = object, .default = text, .variance = .contravariant, .is_const = true }, tp);
    const obj = pool.object_type_payloads.items[pool.payloadOf(object)];
    try T.expectEqual(@as(u32, 1009), pool.headers.items[object].symbol);
    try T.expectEqualDeep(types.ObjectMember{ .name = 160, .type = parameter, .is_optional = true, .is_readonly = true, .is_method = false, .visibility = .private, .decl_node = 1007 }, pool.object_member_pool.items[obj.members_start]);
    try T.expectEqual(parameter, pool.object_member_pool.items[obj.members_start + 1].type);
    try T.expectEqual(@as(u32, 170), pool.object_member_pool.items[obj.members_start + 1].name);
    try T.expectEqual(hir.none_node_id, pool.object_member_pool.items[obj.members_start + 1].decl_node);
    try T.expectEqual(pool.payloadOf(signature), obj.call_sig);
    try T.expectEqual(pool.payloadOf(signature), obj.construct_sig);
    try T.expectEqual(text, obj.string_index_type);
    try T.expectEqual(number, obj.number_index_type);
    try T.expectEqual(try relocation.typeId(graph.bigint), obj.symbol_index_type);
    const sig = pool.signature_payloads.items[pool.payloadOf(signature)];
    try T.expect(sig.is_construct and sig.is_abstract_construct and sig.has_this_type);
    try T.expectEqual(object, sig.return_type);
    try T.expectEqual(object, sig.this_type);
    try T.expectEqualSlices(types.TypeId, &.{ parameter, object }, destination.signatureParams(signature));
    try T.expectEqualSlices(types.TypeId, &.{parameter}, pool.type_arg_pool.items[sig.type_params_start .. sig.type_params_start + sig.type_params_len]);
    const source_parameter = pool.signature_param_pool.items[pool.signature_param_pool.items.len - 1];
    try T.expectEqualDeep(types.SignatureParameter{ .name = 180, .type = parameter, .is_optional = true, .is_rest = true }, source_parameter);
    const members = destination.unionMembers(try relocation.typeId(graph.union_type));
    try T.expectEqual(@as(usize, 4), members.len);
    for ([_]types.TypeId{ text, enum_id, signature, parameter }) |id| try T.expect(std.mem.indexOfScalar(types.TypeId, members, id) != null);
    const intersection = destination.intersectionMembers(try relocation.typeId(graph.intersection));
    try T.expectEqual(@as(usize, 2), intersection.len);
    for ([_]types.TypeId{ object, parameter }) |id| try T.expect(std.mem.indexOfScalar(types.TypeId, intersection, id) != null);
    const cond = pool.conditional_payloads.items[pool.payloadOf(try relocation.typeId(graph.conditional))];
    try T.expectEqualDeep(types.ConditionalPayload{ .check_type = parameter, .extends_type = object, .true_branch = text, .false_branch = number, .is_distributive = false }, cond);
    try T.expectEqual(object, pool.keyof_payloads.items[pool.payloadOf(try relocation.typeId(graph.keyof_type))].operand);
    const indexed = pool.indexed_access_payloads.items[pool.payloadOf(try relocation.typeId(graph.indexed))];
    try T.expectEqualDeep(types.IndexedAccessPayload{ .object = object, .index = parameter }, indexed);
    const mapped = pool.mapped_payloads.items[pool.payloadOf(try relocation.typeId(graph.mapped))];
    try T.expectEqualDeep(types.MappedPayload{ .constraint = try relocation.typeId(graph.keyof_type), .template = try relocation.typeId(graph.indexed), .readonly = .remove, .optional = .add }, mapped);
    const template = try relocation.typeId(graph.template);
    try T.expectEqualSlices(u32, &.{ 110, 120 }, destination.templateLiteralTexts(template));
    try T.expectEqualSlices(types.TypeId, &.{parameter}, destination.templateLiteralTypes(template));
    const string_mapping = pool.string_mapping_payloads.items[pool.payloadOf(try relocation.typeId(graph.string_mapping))];
    try T.expectEqualDeep(types.StringMappingPayload{ .kind = .capitalize, .inner = template }, string_mapping);
    const tuple = pool.tuple_payloads.items[pool.payloadOf(try relocation.typeId(graph.tuple))];
    try T.expectEqual(@as(u32, 2), tuple.elements_len);
    try T.expectEqualDeep(types.TupleElement{ .type = text, .is_optional = true, .is_rest = false }, pool.tuple_element_pool.items[tuple.elements_start]);
    try T.expectEqualDeep(types.TupleElement{ .type = parameter, .is_optional = false, .is_rest = true }, pool.tuple_element_pool.items[tuple.elements_start + 1]);
    const instance = pool.instantiation_payloads.items[pool.payloadOf(try relocation.typeId(graph.instance))];
    try T.expectEqual(object, instance.origin);
    try T.expectEqualSlices(types.TypeId, &.{ text, try relocation.typeId(graph.tuple) }, pool.type_arg_pool.items[instance.args_start .. instance.args_start + instance.args_len]);
}

test "type transfer: every payload kind preserves shared recursive edges and mapped names" {
    var destination = try interner.Interner.init(T.allocator);
    defer destination.deinit();
    const existing = try testGraph(&destination);
    const existing_count = destination.pool.typeCount();
    var names: TestNames = .{};
    var copied = blk: {
        var source = try interner.Interner.init(T.allocator);
        defer source.deinit();
        const graph = try testGraph(&source);
        const relocation = try append(&destination, &source, names.names());
        try T.expectEqual(existing_count, relocation.destination_start);
        for (0..types.Primitive.first_dynamic) |id| try T.expectEqual(@as(u32, @intCast(id)), try relocation.typeId(@intCast(id)));
        try T.expectError(error.InvalidTypeGraph, relocation.typeId(source.pool.typeCount()));
        break :blk .{ .graph = graph, .relocation = relocation };
    };
    defer copied.relocation.deinit();
    // No source allocation is alive here; all payload slices are destination-owned.
    try expectGraph(&destination, copied.graph, copied.relocation);
    try T.expectEqual(@as(u32, 9), destination.typeSymbol(existing.object));
    try T.expectEqual(@as(u32, 10), destination.pool.literal_payloads.items[destination.pool.payloadOf(existing.text)].string_lit);
    // Original intern keys must still work after the appended range.
    try T.expectEqual(existing.text, try destination.internStringLiteral(10));
}

test "type transfer: equal source IDs from different owners keep distinct generic and declaration identities" {
    var source = try interner.Interner.init(T.allocator);
    defer source.deinit();
    const graph = try testGraph(&source);
    var other = try interner.Interner.init(T.allocator);
    defer other.deinit();
    const other_graph = try testGraph(&other);
    try T.expectEqual(graph.parameter, other_graph.parameter);
    var destination = try interner.Interner.init(T.allocator);
    defer destination.deinit();
    var first: TestNames = .{};
    var second: TestNames = .{ .node_base = 2000 };
    var a = try append(&destination, &source, first.names());
    defer a.deinit();
    var b = try append(&destination, &other, second.names());
    defer b.deinit();
    try T.expect(try a.typeId(graph.parameter) != try b.typeId(other_graph.parameter));
    try T.expect(try a.typeId(graph.object) != try b.typeId(other_graph.object));
    try T.expect(try a.typeId(graph.enumeration) != try b.typeId(other_graph.enumeration));
    try T.expectEqual(@as(u32, 1009), destination.typeSymbol(try a.typeId(graph.object)));
    try T.expectEqual(@as(u32, 2009), destination.typeSymbol(try b.typeId(other_graph.object)));
}

fn poolLengths(pool: *const types.Pool) Offsets {
    var result = Offsets.initFill(0);
    inline for (comptime std.meta.fieldNames(types.Pool)) |name| {
        const column = @field(Column, name);
        if (comptime column != .gpa) result.set(column, @intCast(@field(pool, name).items.len));
    }
    return result;
}

fn keyCount(value: *const interner.Interner) usize {
    var count: usize = 0;
    for (&value.shards) |*shard| count += shard.table.count();
    return count;
}

fn testAllocationFailures(allocator: std.mem.Allocator) !void {
    var source = try interner.Interner.init(T.allocator);
    defer source.deinit();
    const graph = try testGraph(&source);
    var destination = try interner.Interner.init(allocator);
    defer destination.deinit();
    const before = poolLengths(&destination.pool);
    var names: TestNames = .{};
    var relocated = append(&destination, &source, names.names()) catch |err| {
        try T.expectEqualDeep(before, poolLengths(&destination.pool));
        try T.expectEqual(@as(usize, 0), destination.enum_literal_info.count());
        try T.expectEqual(@as(usize, 0), keyCount(&destination));
        return err;
    };
    defer relocated.deinit();
    try expectGraph(&destination, graph, relocated);
}

test "type transfer: allocation failures leave unpublished destination state unchanged" {
    try std.testing.checkAllAllocationFailures(T.allocator, testAllocationFailures, .{});
}

test "type transfer: pending cancellation restores keys payloads and enum metadata" {
    var source = try interner.Interner.init(T.allocator);
    defer source.deinit();
    const graph = try testGraph(&source);
    var destination = try interner.Interner.init(T.allocator);
    defer destination.deinit();
    _ = try testGraph(&destination);
    const before = poolLengths(&destination.pool);
    const keys = keyCount(&destination);
    const enums = destination.enum_literal_info.count();
    var names: TestNames = .{};
    var pending = try prepare(&destination, &source, names.names());
    try expectGraph(&destination, graph, pending.ids());
    pending.deinit();
    pending.deinit();
    try T.expectEqualDeep(before, poolLengths(&destination.pool));
    try T.expectEqual(keys, keyCount(&destination));
    try T.expectEqual(enums, destination.enum_literal_info.count());
    var committed = try prepare(&destination, &source, names.names());
    var ids = committed.commit();
    defer ids.deinit();
    committed.deinit();
    try expectGraph(&destination, graph, ids);
}

test "type transfer: rejected names and malformed graph references roll back every column" {
    var source = try interner.Interner.init(T.allocator);
    defer source.deinit();
    const graph = try testGraph(&source);
    var destination = try interner.Interner.init(T.allocator);
    defer destination.deinit();
    _ = try testGraph(&destination);
    const before = poolLengths(&destination.pool);
    const enum_count = destination.enum_literal_info.count();
    const keys_before = keyCount(&destination);
    var names: TestNames = .{};
    names.reject_node = true;
    try T.expectError(error.UnmappedName, append(&destination, &source, names.names()));
    try T.expectEqualDeep(before, poolLengths(&destination.pool));
    names.reject_node = false;
    names.synthetic_node = true;
    try T.expectError(error.UnmappedName, append(&destination, &source, names.names()));
    try T.expectEqualDeep(before, poolLengths(&destination.pool));
    names.synthetic_node = false;
    names.reject_string = true;
    try T.expectError(error.UnmappedName, append(&destination, &source, names.names()));
    try T.expectEqualDeep(before, poolLengths(&destination.pool));
    names.reject_string = false;

    const object_payload = source.pool.payloadOf(graph.object);
    const member_index = source.pool.object_type_payloads.items[object_payload].members_start;
    const member_type = source.pool.object_member_pool.items[member_index].type;
    source.pool.object_member_pool.items[member_index].type = source.pool.typeCount();
    try T.expectError(error.InvalidTypeGraph, append(&destination, &source, names.names()));
    try T.expectEqualDeep(before, poolLengths(&destination.pool));
    source.pool.object_member_pool.items[member_index].type = member_type;
    const original_payload = source.pool.headers.items[graph.text].payload;
    source.pool.headers.items[graph.text].payload = @intCast(source.pool.literal_payloads.items.len);
    try T.expectError(error.InvalidTypeGraph, append(&destination, &source, names.names()));
    try T.expectEqualDeep(before, poolLengths(&destination.pool));
    source.pool.headers.items[graph.text].payload = original_payload;
    const start = source.pool.object_type_payloads.items[object_payload].members_start;
    source.pool.object_type_payloads.items[object_payload].members_start = std.math.maxInt(u32);
    try T.expectError(error.InvalidTypeGraph, append(&destination, &source, names.names()));
    try T.expectEqualDeep(before, poolLengths(&destination.pool));
    source.pool.object_type_payloads.items[object_payload].members_start = start;
    const identity = source.enum_literal_info.get(graph.enumeration).?;
    _ = source.enum_literal_info.remove(graph.enumeration);
    try T.expectError(error.InvalidTypeGraph, append(&destination, &source, names.names()));
    try T.expectEqualDeep(before, poolLengths(&destination.pool));
    try source.enum_literal_info.put(source.gpa, graph.enumeration, identity);
    try T.expectEqual(enum_count, destination.enum_literal_info.count());
    try T.expectEqual(keys_before, keyCount(&destination));
    try T.expectError(error.InvalidTypeGraph, append(&source, &source, names.names()));
    // Failed attempts must not poison a subsequent successful transfer.
    var relocation = try append(&destination, &source, names.names());
    defer relocation.deinit();
    try expectGraph(&destination, graph, relocation);
}

test "type transfer: real string owners preserve literal and signature relations" {
    const strings = @import("string_interner");
    const relation = @import("relation.zig");
    const Context = struct {
        from: *const strings.Interner,
        to: *strings.Interner,

        fn string(context: *anyopaque, id: types.StringId) Error!types.StringId {
            const self: *@This() = @ptrCast(@alignCast(context));
            const value = self.from.getOptional(id) orelse return error.UnmappedName;
            return self.to.intern(value) catch |err| switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.ShardCapacityExceeded => error.TypeIdOverflow,
            };
        }

        fn declaration(_: *anyopaque, _: hir.NodeId) Error!hir.NodeId {
            return error.UnmappedName;
        }
    };
    var source_strings = try strings.Interner.init(T.allocator);
    defer source_strings.deinit();
    var target_strings = try strings.Interner.init(T.allocator);
    defer target_strings.deinit();
    var source = try interner.Interner.init(T.allocator);
    defer source.deinit();
    var target = try interner.Interner.init(T.allocator);
    defer target.deinit();
    const source_literal = try source.internStringLiteral(try source_strings.intern("text"));
    const target_other = try target.internStringLiteral(try target_strings.intern("other"));
    const source_sig = try source.internSignature(&.{source_literal}, source_literal, false);
    const target_literal = try target.internStringLiteral(try target_strings.intern("text"));
    const good_sig = try target.internSignature(&.{target_literal}, target_literal, false);
    const bad_sig = try target.internSignature(&.{target_other}, target_other, false);
    var context: Context = .{ .from = &source_strings, .to = &target_strings };
    var relocated = try append(&target, &source, .{ .context = &context, .string = Context.string, .declaration = Context.declaration });
    defer relocated.deinit();
    const imported_literal = try relocated.typeId(source_literal);
    const imported_sig = try relocated.typeId(source_sig);
    var engine = try relation.Engine.init(T.allocator, &target);
    defer engine.deinit();
    engine.setStringInterner(&target_strings);
    try T.expectEqual(target_literal, imported_literal);
    try T.expect(good_sig != imported_sig);
    try T.expect(try engine.isAssignableTo(imported_literal, target_literal));
    try T.expect(try engine.isAssignableTo(target_literal, imported_literal));
    try T.expect(!try engine.isAssignableTo(imported_literal, target_other));
    try T.expect(try engine.isAssignableTo(imported_sig, good_sig));
    try T.expect(try engine.isAssignableTo(good_sig, imported_sig));
    try T.expect(!try engine.isAssignableTo(imported_sig, bad_sig));
    const payload = target.pool.literal_payloads.items[target.pool.payloadOf(imported_literal)];
    try T.expectEqualStrings("text", target_strings.get(payload.string_lit));
}

fn canonicalGraph(value: *interner.Interner) ![14]types.TypeId {
    const text = try value.internStringLiteral(10);
    const number = try value.internNumberLiteral(42.5);
    const bigint = try value.internBigIntLiteral(20);
    const union_type = try value.internUnion(&.{ text, number });
    const intersection = try value.internIntersection(&.{ types.Primitive.string_t, types.Primitive.object_t });
    const keyof_type = try value.internKeyof(types.Primitive.object_t);
    const indexed = try value.internIndexedAccess(types.Primitive.object_t, text);
    const mapped = try value.internMapped(keyof_type, indexed, .add, .remove);
    const conditional = try value.internConditional(text, types.Primitive.string_t, union_type, types.Primitive.never);
    const template = try value.internTemplateLiteral(&.{ 10, 20 }, &.{union_type});
    const string_mapping = try value.internStringMapping(.capitalize, template);
    const tuple = try value.internTupleType(&.{.{ .type = union_type, .is_optional = false, .is_rest = true }});
    const instance = try value.internInstantiation(types.Primitive.object_t, &.{tuple});
    const signature = try value.internSignature(&.{instance}, conditional, false);
    return .{ text, number, bigint, union_type, intersection, keyof_type, indexed, mapped, conditional, template, string_mapping, tuple, instance, signature };
}

test "type transfer: immutable keys stay canonical while callable identities stay fresh" {
    var source = try interner.Interner.init(T.allocator);
    defer source.deinit();
    const originals = try canonicalGraph(&source);
    var target = try interner.Interner.init(T.allocator);
    defer target.deinit();
    const existing = try canonicalGraph(&target);
    var expected_lengths = poolLengths(&target.pool);
    var names: TestNames = .{ .string_base = 0 };
    var relocation = try append(&target, &source, names.names());
    defer relocation.deinit();
    for (originals[0..13], existing[0..13]) |a, b| try T.expectEqual(b, try relocation.typeId(a));
    try T.expect(existing[13] != try relocation.typeId(originals[13]));
    expected_lengths.set(.headers, expected_lengths.get(.headers) + 1);
    expected_lengths.set(.signature_payloads, expected_lengths.get(.signature_payloads) + 1);
    expected_lengths.set(.type_arg_pool, expected_lengths.get(.type_arg_pool) + 1);
    try T.expectEqualDeep(expected_lengths, poolLengths(&target.pool));
    // Tuple/instantiation builders retain keys independently of the caller's
    // temporary arrays; another call after transfer must still deduplicate.
    const repeated = try canonicalGraph(&target);
    try T.expectEqualSlices(types.TypeId, existing[0..13], repeated[0..13]);
    try T.expect(existing[13] != repeated[13]);
}

test "type transfer: deep forward references are iterative and unanchored key cycles are rejected" {
    var source = try interner.Interner.init(T.allocator);
    defer source.deinit();
    const size = 8192;
    for (0..size) |index| {
        const operand: types.TypeId = if (index + 1 == size) types.Primitive.string_t else @intCast(types.Primitive.first_dynamic + index + 1);
        _ = try addTestPayload(&source, .keyof_payloads, types.KeyofPayload{ .operand = operand }, .{ .is_keyof = true });
    }
    var target = try interner.Interner.init(T.allocator);
    defer target.deinit();
    var names: TestNames = .{};
    var relocation = try append(&target, &source, names.names());
    defer relocation.deinit();
    var current = try relocation.typeId(types.Primitive.first_dynamic);
    for (0..size) |_| current = target.pool.keyof_payloads.items[target.pool.payloadOf(current)].operand;
    try T.expectEqual(types.Primitive.string_t, current);
    const before = poolLengths(&target.pool);
    const keys_before = keyCount(&target);
    source.pool.keyof_payloads.items[source.pool.payloadOf(types.Primitive.first_dynamic)].operand = types.Primitive.first_dynamic;
    try T.expectError(error.InvalidTypeGraph, append(&target, &source, names.names()));
    try T.expectEqualDeep(before, poolLengths(&target.pool));
    try T.expectEqual(keys_before, keyCount(&target));
}
