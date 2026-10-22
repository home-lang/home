//! Bound export bindings and one shared source-owned annotation graph.
//! Collection precedes file checking, so root order and worker scheduling do
//! not decide whether an imported signature retains its generic arguments.
const std = @import("std");
const hir = @import("hir");
const driver = @import("ts_driver");
const resolver_mod = @import("ts_resolver");
const schemas = @import("class_schema.zig");
const export_origins = @import("export_origins.zig");

pub const Source = schemas.Source;
const Binding = struct { source: usize, name: []const u8 };
const BindingContext = struct {
    pub fn hash(_: BindingContext, key: Binding) u64 {
        return std.hash.Wyhash.hash(@intCast(key.source), key.name);
    }
    pub fn eql(_: BindingContext, a: Binding, b: Binding) bool {
        return a.source == b.source and std.mem.eql(u8, a.name, b.name);
    }
};
const Position = struct { source: usize, position: u32 };
const ModuleOwner = struct { source: usize, node: hir.NodeId };
const AmbientModuleOwners = std.StringHashMapUnmanaged(std.ArrayListUnmanaged(ModuleOwner));

const MergedAmbientNamespace = struct {
    values: []const driver.ProgramExportedValue,
    types: []const driver.ProgramExportedType,
};

const NamespaceRouteCounts = struct {
    values: usize = 0,
    types: usize = 0,
};

pub const Graph = struct {
    arena: std.heap.ArenaAllocator,
    values: []const driver.ProgramExportedValue = &.{},
    types: []const driver.ProgramExportedType = &.{},
    ambient_modules: []const driver.ProgramAmbientModule = &.{},

    pub fn init(gpa: std.mem.Allocator) Graph {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Graph) void {
        self.arena.deinit();
    }
};

fn declarationName(c: *const driver.Compilation, node: hir.NodeId) ?[]const u8 {
    const name_node = switch (c.hir.kindOf(node)) {
        .interface_decl => hir.interfaceOf(&c.hir, node).name,
        .type_alias_decl => hir.typeAliasOf(&c.hir, node).name,
        .class_decl => hir.classOf(&c.hir, node).name,
        .namespace_decl => hir.namespaceOf(&c.hir, node).name,
        .enum_decl => hir.enumOf(&c.hir, node).name,
        .fn_decl => hir.fnDeclOf(&c.hir, node).name,
        .var_decl, .let_decl, .const_decl => hir.varDeclOf(&c.hir, node).name,
        else => return null,
    };
    if (name_node == hir.none_node_id or c.hir.kindOf(name_node) != .identifier) return null;
    return c.interner.get(hir.identifierOf(&c.hir, name_node).name);
}

/// Evaluate only numeric enum expressions whose JavaScript value is exact
/// from this source-owned declaration. Unsupported operands leave the whole
/// merged route unresolved; they must not become an approximate member.
fn numericConstEnumExpression(c: *const driver.Compilation, node: hir.NodeId, earlier: []const driver.ProgramEnumMember) ?f64 {
    return switch (c.hir.kindOf(node)) {
        .literal_number => hir.literalNumberOf(&c.hir, node),
        .identifier => blk: {
            const name = c.interner.get(hir.identifierOf(&c.hir, node).name);
            for (earlier) |member| {
                if (!std.mem.eql(u8, member.name, name)) continue;
                break :blk switch (member.value) {
                    .number => |value| value,
                    .string => null,
                };
            }
            break :blk null;
        },
        .unary_op => blk: {
            const unary = hir.unaryOf(&c.hir, node);
            const value = numericConstEnumExpression(c, unary.operand, earlier) orelse break :blk null;
            break :blk switch (unary.op) {
                .plus => value,
                .neg => -value,
                .bit_not => if (enumExactInt32(value)) |int| @as(f64, @floatFromInt(~int)) else null,
                else => null,
            };
        },
        .binary_op => blk: {
            const binary = hir.binopOf(&c.hir, node);
            const lhs = numericConstEnumExpression(c, binary.lhs, earlier) orelse break :blk null;
            const rhs = numericConstEnumExpression(c, binary.rhs, earlier) orelse break :blk null;
            break :blk switch (binary.op) {
                .add => lhs + rhs,
                .sub => lhs - rhs,
                .mul => lhs * rhs,
                .div => lhs / rhs,
                .mod => if (rhs != 0) @rem(lhs, rhs) else null,
                .bit_or, .bit_and, .bit_xor => bitwiseConstEnumValue(lhs, rhs, binary.op),
                .shl, .shr, .shr_unsigned => shiftConstEnumValue(lhs, rhs, binary.op),
                else => null,
            };
        },
        else => null,
    };
}

fn enumExactInt32(value: f64) ?i32 {
    if (!std.math.isFinite(value) or @trunc(value) != value or
        value < @as(f64, @floatFromInt(std.math.minInt(i32))) or
        value > @as(f64, @floatFromInt(std.math.maxInt(i32)))) return null;
    return @intFromFloat(value);
}

fn bitwiseConstEnumValue(lhs: f64, rhs: f64, op: hir.BinOp) ?f64 {
    const left = enumExactInt32(lhs) orelse return null;
    const right = enumExactInt32(rhs) orelse return null;
    const result = switch (op) {
        .bit_or => left | right,
        .bit_and => left & right,
        .bit_xor => left ^ right,
        else => unreachable,
    };
    return @floatFromInt(result);
}

fn shiftConstEnumValue(lhs: f64, rhs: f64, op: hir.BinOp) ?f64 {
    const left = enumExactInt32(lhs) orelse return null;
    const right = enumExactInt32(rhs) orelse return null;
    // The remaining 32-bit shift counts are equivalent to their masked
    // values, but are not admitted until that coercion is represented here.
    if (right < 0 or right > 31) return null;
    const amount: u5 = @intCast(right);
    const bits: u32 = @bitCast(left);
    return switch (op) {
        .shl => @as(f64, @floatFromInt(@as(i32, @bitCast(bits << amount)))),
        .shr => @as(f64, @floatFromInt(left >> amount)),
        .shr_unsigned => @as(f64, @floatFromInt(bits >> amount)),
        else => unreachable,
    };
}

/// Transfer only enum declarations whose complete member values can be
/// represented exactly. Other constant expressions retain their existing
/// unresolved route instead of publishing an approximate member type.
fn literalConstEnumMembers(arena: std.mem.Allocator, c: *const driver.Compilation, node: hir.NodeId) !?[]const driver.ProgramEnumMember {
    var result: std.ArrayListUnmanaged(driver.ProgramEnumMember) = .empty;
    var next_number: ?f64 = 0;
    for (hir.enumMembers(&c.hir, node)) |member| {
        if (c.hir.kindOf(member) != .object_property) return null;
        const property = hir.objectPropertyOf(&c.hir, member);
        if (c.hir.kindOf(property.key) != .identifier) return null;
        const name = c.interner.get(hir.identifierOf(&c.hir, property.key).name);
        for (result.items) |existing| if (std.mem.eql(u8, existing.name, name)) return null;
        const value: driver.ProgramEnumMember.Value = if (property.value == hir.none_node_id) blk: {
            const number = next_number orelse return null;
            break :blk .{ .number = number };
        } else switch (c.hir.kindOf(property.value)) {
            .literal_string => blk: {
                const raw = c.interner.get(hir.literalStringOf(&c.hir, property.value).value);
                if (std.mem.indexOfAny(u8, raw, "\\\r") == null) break :blk .{ .string = raw };
                var cooked: std.ArrayListUnmanaged(u8) = .empty;
                try driver.ProgramClassSchema.appendCookedStringText(arena, raw, &cooked);
                break :blk .{ .string = try cooked.toOwnedSlice(arena) };
            },
            else => .{ .number = numericConstEnumExpression(c, property.value, result.items) orelse return null },
        };
        next_number = switch (value) {
            .number => |number| if (std.math.isFinite(number)) number + 1 else return null,
            .string => null,
        };
        try result.append(arena, .{ .name = name, .value = value, .owner_hir = &c.hir, .declaration_node = node });
    }
    const owned = try result.toOwnedSlice(arena);
    return owned;
}

/// Resolve all fragments of one exported namespace together. A reference to
/// another fragment can point forward in file order, but a reference to a
/// later member of the *same* declaration cannot. The recursion state also
/// makes cycles fail without publishing a partial enum route.
const MergedEnumValues = struct {
    const Entry = struct {
        source: usize,
        declaration: hir.NodeId,
        group: []const u8,
        enum_name: []const u8,
        name: []const u8,
        ordinal: usize,
        initializer: hir.NodeId,
        previous: ?usize,
        state: enum { pending, resolving, resolved, invalid } = .pending,
        value: ?driver.ProgramEnumMember.Value = null,
    };
    const Fragment = struct {
        source: usize,
        declaration: hir.NodeId,
        group: []const u8,
        entries: []const usize,
        members: ?[]const driver.ProgramEnumMember = null,
    };

    arena: std.mem.Allocator,
    sources: []const Source,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    fragments: std.ArrayListUnmanaged(Fragment) = .empty,

    fn collectNamespace(self: *MergedEnumValues, source_index: usize, node: hir.NodeId, namespace_path: []const u8) !bool {
        const c = self.sources[source_index].compilation;
        for (hir.namespaceBody(&c.hir, node)) |raw| {
            const member = if (c.hir.kindOf(raw) == .export_decl) hir.exportOf(&c.hir, raw).decl else raw;
            if (member == hir.none_node_id) continue;
            switch (c.hir.kindOf(member)) {
                .namespace_decl => {
                    const name = declarationName(c, member) orelse return false;
                    const nested = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ namespace_path, name });
                    if (!try self.collectNamespace(source_index, member, nested)) return false;
                },
                .enum_decl => {
                    if (!hir.enumOf(&c.hir, member).is_const) continue;
                    const enum_name = declarationName(c, member) orelse return false;
                    const group = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ namespace_path, enum_name });
                    var indexes: std.ArrayListUnmanaged(usize) = .empty;
                    for (hir.enumMembers(&c.hir, member), 0..) |raw_property, ordinal| {
                        if (c.hir.kindOf(raw_property) != .object_property) return false;
                        const property = hir.objectPropertyOf(&c.hir, raw_property);
                        if (c.hir.kindOf(property.key) != .identifier) return false;
                        const name = c.interner.get(hir.identifierOf(&c.hir, property.key).name);
                        for (self.entries.items) |existing| {
                            if (std.mem.eql(u8, existing.group, group) and std.mem.eql(u8, existing.name, name)) return false;
                        }
                        const index = self.entries.items.len;
                        try self.entries.append(self.arena, .{
                            .source = source_index,
                            .declaration = member,
                            .group = group,
                            .enum_name = enum_name,
                            .name = name,
                            .ordinal = ordinal,
                            .initializer = property.value,
                            .previous = if (indexes.items.len == 0) null else indexes.items[indexes.items.len - 1],
                        });
                        try indexes.append(self.arena, index);
                    }
                    try self.fragments.append(self.arena, .{
                        .source = source_index,
                        .declaration = member,
                        .group = group,
                        .entries = try indexes.toOwnedSlice(self.arena),
                    });
                },
                else => {},
            }
        }
        return true;
    }

    fn hasRepeatedFragment(self: *const MergedEnumValues) bool {
        for (self.fragments.items, 0..) |fragment, index| {
            for (self.fragments.items[0..index]) |previous| {
                if (std.mem.eql(u8, fragment.group, previous.group)) return true;
            }
        }
        return false;
    }

    fn lookup(self: *MergedEnumValues, current: usize, name: []const u8) anyerror!?f64 {
        const owner = self.entries.items[current];
        for (self.entries.items, 0..) |candidate, index| {
            if (!std.mem.eql(u8, candidate.group, owner.group) or !std.mem.eql(u8, candidate.name, name)) continue;
            // `A = B` cannot see a later B in this declaration, even when a
            // different declaration fragment happens to be collected first.
            if (candidate.source == owner.source and candidate.declaration == owner.declaration and candidate.ordinal >= owner.ordinal) return null;
            const value = (try self.resolve(index)) orelse return null;
            return switch (value) {
                .number => |number| number,
                .string => null,
            };
        }
        return null;
    }

    fn numeric(self: *MergedEnumValues, current: usize, node: hir.NodeId) anyerror!?f64 {
        const c = self.sources[self.entries.items[current].source].compilation;
        return switch (c.hir.kindOf(node)) {
            .literal_number => hir.literalNumberOf(&c.hir, node),
            .identifier => try self.lookup(current, c.interner.get(hir.identifierOf(&c.hir, node).name)),
            .member_access => blk: {
                const access = hir.memberOf(&c.hir, node);
                if (c.hir.kindOf(access.object) != .identifier) break :blk null;
                const object = c.interner.get(hir.identifierOf(&c.hir, access.object).name);
                if (!std.mem.eql(u8, object, self.entries.items[current].enum_name)) break :blk null;
                break :blk try self.lookup(current, c.interner.get(access.name));
            },
            .unary_op => blk: {
                const unary = hir.unaryOf(&c.hir, node);
                const value = (try self.numeric(current, unary.operand)) orelse break :blk null;
                break :blk switch (unary.op) {
                    .plus => value,
                    .neg => -value,
                    .bit_not => if (enumExactInt32(value)) |int| @as(f64, @floatFromInt(~int)) else null,
                    else => null,
                };
            },
            .binary_op => blk: {
                const binary = hir.binopOf(&c.hir, node);
                const lhs = (try self.numeric(current, binary.lhs)) orelse break :blk null;
                const rhs = (try self.numeric(current, binary.rhs)) orelse break :blk null;
                break :blk switch (binary.op) {
                    .add => lhs + rhs,
                    .sub => lhs - rhs,
                    .mul => lhs * rhs,
                    .div => lhs / rhs,
                    .mod => if (rhs != 0) @rem(lhs, rhs) else null,
                    .bit_or, .bit_and, .bit_xor => bitwiseConstEnumValue(lhs, rhs, binary.op),
                    .shl, .shr, .shr_unsigned => shiftConstEnumValue(lhs, rhs, binary.op),
                    else => null,
                };
            },
            else => null,
        };
    }

    fn resolve(self: *MergedEnumValues, index: usize) anyerror!?driver.ProgramEnumMember.Value {
        const entry = self.entries.items[index];
        switch (entry.state) {
            .resolved => return entry.value,
            .invalid, .resolving => return null,
            .pending => {},
        }
        self.entries.items[index].state = .resolving;
        const c = self.sources[entry.source].compilation;
        const value: ?driver.ProgramEnumMember.Value = if (entry.initializer == hir.none_node_id) blk: {
            const number: f64 = if (entry.previous) |previous| previous_number: {
                const prior = (try self.resolve(previous)) orelse break :blk null;
                break :previous_number switch (prior) {
                    .number => |n| n + 1,
                    .string => break :blk null,
                };
            } else 0;
            if (!std.math.isFinite(number)) break :blk null;
            break :blk .{ .number = number };
        } else switch (c.hir.kindOf(entry.initializer)) {
            .literal_string => blk: {
                const raw = c.interner.get(hir.literalStringOf(&c.hir, entry.initializer).value);
                if (std.mem.indexOfAny(u8, raw, "\\\r") == null) break :blk .{ .string = raw };
                var cooked: std.ArrayListUnmanaged(u8) = .empty;
                try driver.ProgramClassSchema.appendCookedStringText(self.arena, raw, &cooked);
                break :blk .{ .string = try cooked.toOwnedSlice(self.arena) };
            },
            else => if (try self.numeric(index, entry.initializer)) |number|
                if (std.math.isFinite(number)) .{ .number = number } else null
            else
                null,
        };
        self.entries.items[index].value = value;
        self.entries.items[index].state = if (value == null) .invalid else .resolved;
        return value;
    }

    fn finish(self: *MergedEnumValues) !bool {
        for (self.fragments.items) |*fragment| {
            const c = self.sources[fragment.source].compilation;
            const members = try self.arena.alloc(driver.ProgramEnumMember, fragment.entries.len);
            for (fragment.entries, members) |index, *member| {
                const entry = self.entries.items[index];
                const value = (try self.resolve(index)) orelse return false;
                member.* = .{ .name = entry.name, .value = value, .owner_hir = &c.hir, .declaration_node = fragment.declaration };
            }
            fragment.members = members;
        }
        return true;
    }

    fn membersFor(self: *const MergedEnumValues, c: *const driver.Compilation, node: hir.NodeId) ?[]const driver.ProgramEnumMember {
        for (self.fragments.items) |fragment| {
            const source = self.sources[fragment.source].compilation;
            if (source == c and fragment.declaration == node) return fragment.members;
        }
        return null;
    }
};

fn singleEnumDeclarationInNamespace(c: *const driver.Compilation, namespace_node: hir.NodeId, name: []const u8) bool {
    var count: usize = 0;
    for (hir.namespaceBody(&c.hir, namespace_node)) |raw| {
        const member = if (c.hir.kindOf(raw) == .export_decl) hir.exportOf(&c.hir, raw).decl else raw;
        if (member == hir.none_node_id or c.hir.kindOf(member) != .enum_decl) continue;
        const found = declarationName(c, member) orelse continue;
        if (std.mem.eql(u8, found, name)) count += 1;
    }
    return count == 1;
}

fn appendNamespaceValueRoute(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    builder: *schemas.Builder,
    supported: *std.AutoHashMapUnmanaged(*const driver.ProgramClassSchema.Declaration, bool),
    source_index: usize,
    source: Source,
    node: hir.NodeId,
    target_path: []const u8,
    namespace_path: []const u8,
    class_namespace_merges: ?*const std.StringHashMapUnmanaged(void),
    merged_enums: ?*const MergedEnumValues,
    values: *std.ArrayListUnmanaged(driver.ProgramExportedValue),
) !void {
    const c = source.compilation;
    const ambient = hir.namespaceOf(&c.hir, node).is_ambient or c.is_declaration_file;
    for (hir.namespaceBody(&c.hir, node)) |raw| {
        const member = if (c.hir.kindOf(raw) == .export_decl) hir.exportOf(&c.hir, raw).decl else if (ambient) raw else continue;
        if (member == hir.none_node_id) continue;
        if (declarationName(c, member)) |name| {
            const visible = try builder.query.resolveInNamespace(source.path, node, name);
            const origin = visible.value orelse visible.type_only_value orelse visible.namespace orelse continue;
            const same_origin = std.mem.eql(u8, origin.path, source.path) and origin.position == c.hir.spanOf(member).start;
            const kind = c.hir.kindOf(member);
            const merged_contributor = if (!same_origin and (kind == .class_decl or kind == .namespace_decl) and class_namespace_merges != null) blk: {
                const full = try std.fmt.allocPrint(arena, "{s}.{s}", .{ namespace_path, name });
                break :blk class_namespace_merges.?.contains(full);
            } else false;
            const merged_enum_contributor = !same_origin and kind == .enum_decl and merged_enums != null and
                merged_enums.?.membersFor(c, member) != null;
            if (!visible.complete or visible.ambiguous or (!same_origin and !merged_contributor and !merged_enum_contributor)) continue;
        }
        if (c.hir.kindOf(member) == .namespace_decl) {
            const namespace = hir.namespaceOf(&c.hir, member);
            if (c.hir.kindOf(namespace.name) != .identifier) continue;
            const nested_path = try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ namespace_path, if (namespace_path.len == 0) "" else ".", c.interner.get(hir.identifierOf(&c.hir, namespace.name).name) });
            try appendNamespaceValueRoute(gpa, arena, builder, supported, source_index, source, member, target_path, nested_path, class_namespace_merges, merged_enums, values);
            continue;
        }
        if (c.hir.kindOf(member) == .enum_decl) {
            if (!ambient or !hir.enumOf(&c.hir, member).is_const) continue;
            const name = declarationName(c, member) orelse continue;
            if (merged_enums == null and !singleEnumDeclarationInNamespace(c, node, name)) continue;
            const enum_members = if (merged_enums) |resolved|
                resolved.membersFor(c, member) orelse continue
            else
                (try literalConstEnumMembers(arena, c, member)) orelse continue;
            try values.append(arena, .{
                .target_path = target_path,
                .namespace_path = namespace_path,
                .export_name = name,
                .kind = .variable,
                .enum_members = enum_members,
            });
            continue;
        }
        if (c.hir.kindOf(member) == .class_decl) {
            const name = declarationName(c, member) orelse continue;
            const declaration = try builder.declaration(.{ .source = source_index, .node = member });
            const support = try supported.getOrPut(arena, declaration);
            if (!support.found_existing) support.value_ptr.* = try driver.ProgramClassSchema.Schema.declarationSupported(declaration, gpa);
            var exact = support.value_ptr.*;
            if (exact) if (declaration.constructors) |constructors| {
                exact = try driver.ProgramClassSchema.Schema.expressionSupported(constructors, gpa);
            };
            if (exact and (try builder.classStaticMembers(.{ .source = source_index, .node = member })) == null) exact = false;
            const expression = try arena.create(driver.ProgramClassSchema.Expression);
            expression.* = .{ .typeof_class = declaration };
            const wrapper = try arena.create(driver.ProgramClassSchema.Declaration);
            wrapper.* = .{
                .path = declaration.path,
                .position = declaration.position,
                .name = declaration.name,
                .body = expression,
                .value_side = true,
            };
            try values.append(arena, .{
                .target_path = target_path,
                .namespace_path = namespace_path,
                .export_name = name,
                .kind = .variable,
                .declaration = wrapper,
                .projection_only = !exact,
            });
            continue;
        }
        switch (c.hir.kindOf(member)) {
            .fn_decl, .var_decl, .let_decl, .const_decl => {},
            else => continue,
        }
        const name = declarationName(c, member) orelse continue;
        const declaration = try builder.declaration(.{ .source = source_index, .node = member });
        const support = try supported.getOrPut(arena, declaration);
        if (!support.found_existing) support.value_ptr.* = try driver.ProgramClassSchema.Schema.declarationSupported(declaration, gpa);
        var duplicate = false;
        for (values.items) |existing| {
            if (existing.declaration == declaration and std.mem.eql(u8, existing.target_path, target_path) and
                std.mem.eql(u8, existing.namespace_path, namespace_path) and std.mem.eql(u8, existing.export_name, name)) duplicate = true;
        }
        if (!duplicate) try values.append(arena, .{
            .target_path = target_path,
            .namespace_path = namespace_path,
            .export_name = name,
            .kind = if (declaration.is_function) .function else .variable,
            .declaration = declaration,
            .projection_only = !support.value_ptr.*,
        });
    }
}

fn appendNamespaceTypeRoute(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    builder: *schemas.Builder,
    supported: *std.AutoHashMapUnmanaged(*const driver.ProgramClassSchema.Declaration, bool),
    source_index: usize,
    source: Source,
    namespace_node: hir.NodeId,
    target_path: []const u8,
    namespace_path: []const u8,
    types: *std.ArrayListUnmanaged(driver.ProgramExportedType),
) !void {
    const c = source.compilation;
    for (hir.namespaceBody(&c.hir, namespace_node)) |raw| {
        const ambient = hir.namespaceOf(&c.hir, namespace_node).is_ambient or c.is_declaration_file;
        const member = if (c.hir.kindOf(raw) == .export_decl) hir.exportOf(&c.hir, raw).decl else if (ambient) raw else continue;
        if (member == hir.none_node_id) continue;
        switch (c.hir.kindOf(member)) {
            .interface_decl, .type_alias_decl, .class_decl => {
                const name = declarationName(c, member) orelse continue;
                const visible = try builder.query.resolveInNamespace(source.path, namespace_node, name);
                const origin = visible.type orelse continue;
                if (!visible.complete or visible.ambiguous or !std.mem.eql(u8, origin.path, source.path) or origin.position != c.hir.spanOf(member).start) continue;
                const declaration = try builder.declaration(.{ .source = source_index, .node = member });
                const support = try supported.getOrPut(arena, declaration);
                if (!support.found_existing) {
                    support.value_ptr.* = try driver.ProgramClassSchema.Schema.declarationSupported(declaration, gpa);
                }
                var duplicate = false;
                for (types.items) |existing| {
                    if (existing.declaration == declaration and
                        std.mem.eql(u8, existing.target_path, target_path) and
                        std.mem.eql(u8, existing.namespace_path, namespace_path) and
                        std.mem.eql(u8, existing.export_name, name))
                    {
                        duplicate = true;
                        break;
                    }
                }
                if (!duplicate) try types.append(arena, .{
                    .target_path = target_path,
                    .namespace_path = namespace_path,
                    .export_name = name,
                    .declaration = declaration,
                    .contextual_only = declaration.contextual_only,
                    .projection_only = !support.value_ptr.*,
                });
            },
            .namespace_decl => {
                const nested = hir.namespaceOf(&c.hir, member);
                if (nested.name == hir.none_node_id or c.hir.kindOf(nested.name) != .identifier) continue;
                const nested_name = c.interner.get(hir.identifierOf(&c.hir, nested.name).name);
                const nested_path = try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ namespace_path, if (namespace_path.len == 0) "" else ".", nested_name });
                try appendNamespaceTypeRoute(
                    gpa,
                    arena,
                    builder,
                    supported,
                    source_index,
                    source,
                    member,
                    target_path,
                    nested_path,
                    types,
                );
            },
            else => {},
        }
    }
}

fn scopeFor(c: *const driver.Compilation, node: hir.NodeId) ?*const @import("binder").Scope {
    for (c.module.scopes.items) |scope| if (scope.introducing_node == node) return scope;
    return null;
}

fn collectClassNamespaceNames(
    arena: std.mem.Allocator,
    c: *const driver.Compilation,
    node: hir.NodeId,
    path: []const u8,
    classes: *std.StringHashMapUnmanaged(void),
    namespaces: *std.StringHashMapUnmanaged(void),
) !void {
    for (hir.namespaceBody(&c.hir, node)) |raw| {
        const member = if (c.hir.kindOf(raw) == .export_decl) hir.exportOf(&c.hir, raw).decl else raw;
        if (member == hir.none_node_id) continue;
        const kind = c.hir.kindOf(member);
        if (kind != .class_decl and kind != .namespace_decl) continue;
        const leaf = declarationName(c, member) orelse continue;
        const full = try std.fmt.allocPrint(arena, "{s}.{s}", .{ path, leaf });
        if (kind == .class_decl) {
            try classes.put(arena, full, {});
        } else {
            try namespaces.put(arena, full, {});
            try collectClassNamespaceNames(arena, c, member, full, classes, namespaces);
        }
    }
}

fn classNamespaceMergeConflict(arena: std.mem.Allocator, sources: []const Source, owners: []const ModuleOwner, name: []const u8) !bool {
    var classes: std.StringHashMapUnmanaged(void) = .empty;
    var namespaces: std.StringHashMapUnmanaged(void) = .empty;
    for (owners) |owner| {
        const c = sources[owner.source].compilation;
        const scope = scopeFor(c, owner.node) orelse continue;
        const id = c.interner.lookup(name) orelse continue;
        const symbol = scope.namespaces.get(id) orelse continue;
        for (symbol.decls.items) |decl| {
            if (c.hir.kindOf(decl) != .namespace_decl) continue;
            try collectClassNamespaceNames(arena, c, decl, name, &classes, &namespaces);
        }
    }
    // Even one ambient module fragment may contain a class and a same-named
    // namespace in the same scope. If exact collection fails, withhold that
    // merge instead of publishing only the class or only its namespace.
    var class_names = classes.keyIterator();
    while (class_names.next()) |class_name| if (namespaces.contains(class_name.*)) return true;
    return false;
}

fn originKey(by_path: *const std.StringHashMapUnmanaged(usize), declarations: *const std.AutoHashMapUnmanaged(Position, hir.NodeId), origin: export_origins.Origin) ?schemas.Key {
    const source = by_path.get(origin.path) orelse return null;
    const node = declarations.get(.{ .source = source, .position = origin.position }) orelse return null;
    return .{ .source = source, .node = node };
}

fn namespaceContainsNode(c: *const driver.Compilation, namespace_node: hir.NodeId, target: hir.NodeId) bool {
    if (namespace_node == target) return true;
    for (hir.namespaceBody(&c.hir, namespace_node)) |raw| {
        const member = if (c.hir.kindOf(raw) == .export_decl) hir.exportOf(&c.hir, raw).decl else raw;
        if (member == target) return true;
        if (member != hir.none_node_id and c.hir.kindOf(member) == .namespace_decl and namespaceContainsNode(c, member, target)) return true;
    }
    return false;
}

fn ambientConstEnumOrigin(
    by_path: *const std.StringHashMapUnmanaged(usize),
    ambient_const_enums: *const std.AutoHashMapUnmanaged(Position, void),
    origin: export_origins.Origin,
) bool {
    const source = by_path.get(origin.path) orelse return false;
    return ambient_const_enums.contains(.{ .source = source, .position = origin.position });
}

fn enumIsInAmbientModule(c: *const driver.Compilation, node: hir.NodeId) bool {
    var parent = c.hir.parentOf(node);
    while (parent != hir.none_node_id) : (parent = c.hir.parentOf(parent)) {
        if (c.hir.kindOf(parent) != .namespace_decl) continue;
        const name = hir.namespaceOf(&c.hir, parent).name;
        const span = c.hir.spanOf(name);
        if (span.start < c.source.len and (c.source[span.start] == '"' or c.source[span.start] == '\'')) return true;
    }
    return false;
}

/// The merged route must account for every value or type leaf. If a contributor
/// contains a declaration this graph cannot transfer exactly, leave the
/// entire merge unresolved rather than exposing a misleading partial type.
fn exactNamespaceRouteCounts(arena: std.mem.Allocator, c: *const driver.Compilation, node: hir.NodeId, merged_enums: ?*const MergedEnumValues) !?NamespaceRouteCounts {
    const ambient = hir.namespaceOf(&c.hir, node).is_ambient or c.is_declaration_file;
    var counts: NamespaceRouteCounts = .{};
    for (hir.namespaceBody(&c.hir, node)) |raw| {
        const member = if (c.hir.kindOf(raw) == .export_decl)
            hir.exportOf(&c.hir, raw).decl
        else if (ambient)
            raw
        else
            return null;
        if (member == hir.none_node_id) return null;
        switch (c.hir.kindOf(member)) {
            .namespace_decl => {
                const nested = (try exactNamespaceRouteCounts(arena, c, member, merged_enums)) orelse return null;
                counts.values += nested.values;
                counts.types += nested.types;
            },
            .enum_decl => {
                if (!hir.enumOf(&c.hir, member).is_const) return null;
                if (merged_enums) |resolved| {
                    if (resolved.membersFor(c, member) == null) return null;
                } else if ((try literalConstEnumMembers(arena, c, member)) == null) return null;
                counts.values += 1;
            },
            .class_decl => {
                counts.values += 1;
                counts.types += 1;
            },
            .fn_decl, .var_decl, .let_decl, .const_decl => counts.values += 1,
            .interface_decl, .type_alias_decl => counts.types += 1,
            else => return null,
        }
    }
    return counts;
}

/// A namespace export may have several declarations in one or more ambient
/// module blocks. Distinct declaration positions are not conflicting exports
/// when every contributor is the same namespace meaning. Collect all owners
/// before publishing a route; a partial member set would be unsound.
fn mergedAmbientNamespace(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    builder: *schemas.Builder,
    supported: *std.AutoHashMapUnmanaged(*const driver.ProgramClassSchema.Declaration, bool),
    sources: []const Source,
    owners: []const ModuleOwner,
    target_path: []const u8,
    lookup_name: []const u8,
    route_name: []const u8,
) !?MergedAmbientNamespace {
    var declarations: std.ArrayListUnmanaged(ModuleOwner) = .empty;
    for (owners) |owner| {
        const source = sources[owner.source];
        const c = source.compilation;
        const scope = scopeFor(c, owner.node) orelse return null;
        // A re-export can contribute an unrelated origin with the same name.
        // Named exports of other names do not affect this merge; export-star
        // has an unknown name set here, so it cannot prove non-conflict.
        for (hir.namespaceBody(&c.hir, owner.node)) |raw| {
            if (c.hir.kindOf(raw) != .export_decl) continue;
            const export_info = hir.exportOf(&c.hir, raw);
            if (c.interner.get(export_info.module).len == 0) continue;
            if (export_info.is_namespace) {
                const alias = c.interner.get(export_info.namespace_alias);
                if (alias.len == 0 or std.mem.eql(u8, alias, lookup_name)) return null;
            }
            for (hir.exportNamed(&c.hir, raw)) |alias_node| {
                const alias = hir.importSpecifierOf(&c.hir, alias_node);
                if (std.mem.eql(u8, c.interner.get(alias.local), lookup_name)) return null;
            }
        }
        const id = c.interner.lookup(lookup_name) orelse continue;
        inline for (.{ "types", "values", "namespaces" }) |field| {
            if (@field(scope, field).get(id)) |symbol| for (symbol.decls.items) |decl| {
                if (c.hir.kindOf(decl) != .namespace_decl) return null;
            };
        }
        const symbol = scope.namespaces.get(id) orelse continue;
        for (symbol.decls.items) |decl| {
            if (c.hir.kindOf(decl) != .namespace_decl) return null;
            try declarations.append(arena, .{ .source = owner.source, .node = decl });
        }
    }
    if (declarations.items.len == 0) return null;

    var merged_enums = MergedEnumValues{ .arena = arena, .sources = sources };
    for (declarations.items) |declaration| {
        if (!try merged_enums.collectNamespace(declaration.source, declaration.node, route_name)) return null;
    }
    if (!try merged_enums.finish()) return null;

    // A class and a namespace with the same qualified name are one exported
    // value. A single resolved origin cannot identify both declaration nodes;
    // record the proven pairs before collecting either contributor.
    var classes: std.StringHashMapUnmanaged(void) = .empty;
    var namespaces: std.StringHashMapUnmanaged(void) = .empty;
    var class_namespace_merges: std.StringHashMapUnmanaged(void) = .empty;
    for (declarations.items) |declaration| {
        const c = sources[declaration.source].compilation;
        try collectClassNamespaceNames(arena, c, declaration.node, route_name, &classes, &namespaces);
    }
    var class_names = classes.keyIterator();
    while (class_names.next()) |class_name| {
        if (namespaces.contains(class_name.*)) try class_namespace_merges.put(arena, class_name.*, {});
    }
    if (declarations.items.len == 1 and !merged_enums.hasRepeatedFragment() and class_namespace_merges.count() == 0) return null;

    var collected_values: std.ArrayListUnmanaged(driver.ProgramExportedValue) = .empty;
    var collected_types: std.ArrayListUnmanaged(driver.ProgramExportedType) = .empty;
    var expected: NamespaceRouteCounts = .{};
    for (declarations.items) |declaration| {
        const source = sources[declaration.source];
        const counts = (try exactNamespaceRouteCounts(arena, source.compilation, declaration.node, &merged_enums)) orelse return null;
        expected.values += counts.values;
        expected.types += counts.types;
        try appendNamespaceValueRoute(gpa, arena, builder, supported, declaration.source, source, declaration.node, target_path, route_name, &class_namespace_merges, &merged_enums, &collected_values);
        try appendNamespaceTypeRoute(gpa, arena, builder, supported, declaration.source, source, declaration.node, target_path, route_name, &collected_types);
    }
    if (expected.values + expected.types == 0 or
        collected_values.items.len != expected.values or
        collected_types.items.len != expected.types) return null;

    var values: std.ArrayListUnmanaged(driver.ProgramExportedValue) = .empty;
    for (collected_values.items) |route| {
        if (route.projection_only or (route.declaration == null and route.enum_members == null)) return null;
        var existing_route: ?*driver.ProgramExportedValue = null;
        for (values.items) |*existing| {
            if (std.mem.eql(u8, existing.namespace_path, route.namespace_path) and
                std.mem.eql(u8, existing.export_name, route.export_name))
            {
                existing_route = existing;
                break;
            }
        }
        if (existing_route) |existing| {
            const previous = existing.enum_members orelse return null;
            const additional = route.enum_members orelse return null;
            for (additional) |member| for (previous) |prior| {
                if (std.mem.eql(u8, member.name, prior.name)) return null;
            };
            const joined = try arena.alloc(driver.ProgramEnumMember, previous.len + additional.len);
            @memcpy(joined[0..previous.len], previous);
            @memcpy(joined[previous.len..], additional);
            existing.enum_members = joined;
        } else {
            try values.append(arena, route);
        }
    }
    for (collected_types.items, 0..) |route, index| {
        if (route.contextual_only or route.projection_only) return null;
        for (collected_types.items[0..index]) |previous| {
            if (std.mem.eql(u8, previous.namespace_path, route.namespace_path) and
                std.mem.eql(u8, previous.export_name, route.export_name)) return null;
        }
        for (values.items) |value| {
            if (std.mem.eql(u8, value.namespace_path, route.namespace_path) and
                std.mem.eql(u8, value.export_name, route.export_name))
            {
                const value_declaration = value.declaration orelse return null;
                const body = value_declaration.body orelse return null;
                if (!route.declaration.is_class or body.* != .typeof_class or
                    body.typeof_class != route.declaration) return null;
            }
        }
    }
    return .{ .values = try values.toOwnedSlice(arena), .types = try collected_types.toOwnedSlice(arena) };
}

const ForwardedAmbientMerge = struct {
    routes: ?MergedAmbientNamespace = null,
    unresolved: bool = false,
    source_module: []const u8 = "",
    source_name: []const u8 = "",
};

const PendingAmbientForward = struct {
    source_module: []const u8,
    source_name: []const u8,
    target_module: []const u8,
    target_path: []const u8,
    public_name: []const u8,
};

const AmbientOriginOwner = struct {
    specifier: []const u8,
    owners: []const ModuleOwner,
};

fn ambientModuleContainingOrigin(
    sources: []const Source,
    modules: *const AmbientModuleOwners,
    key: schemas.Key,
) ?AmbientOriginOwner {
    const c = sources[key.source].compilation;
    var iterator = modules.iterator();
    while (iterator.next()) |entry| {
        for (entry.value_ptr.items) |owner| {
            if (owner.source != key.source or !namespaceContainsNode(c, owner.node, key.node)) continue;
            return .{ .specifier = entry.key_ptr.*, .owners = entry.value_ptr.items };
        }
    }
    return null;
}

fn forwardedNamespacePath(arena: std.mem.Allocator, path: []const u8, source_name: []const u8, public_name: []const u8) !?[]const u8 {
    // `export * as name from "ambient-module"` forwards the whole module,
    // rather than one named namespace within it.
    if (source_name.len == 0) {
        if (path.len == 0) return public_name;
        return try std.fmt.allocPrint(arena, "{s}.{s}", .{ public_name, path });
    }
    if (std.mem.eql(u8, path, source_name)) return public_name;
    if (!std.mem.startsWith(u8, path, source_name) or path.len <= source_name.len or path[source_name.len] != '.') return null;
    if (std.mem.eql(u8, source_name, public_name)) return path;
    return try std.fmt.allocPrint(arena, "{s}{s}", .{ public_name, path[source_name.len..] });
}

fn hasDottedNamespaceAugmentation(sources: []const Source, owners: []const ModuleOwner, root_name: []const u8) bool {
    for (owners) |owner| {
        const c = sources[owner.source].compilation;
        for (hir.namespaceBody(&c.hir, owner.node)) |raw| {
            const member = if (c.hir.kindOf(raw) == .export_decl) hir.exportOf(&c.hir, raw).decl else raw;
            if (member == hir.none_node_id or c.hir.kindOf(member) != .namespace_decl) continue;
            const name = declarationName(c, member) orelse continue;
            if (std.mem.startsWith(u8, name, root_name) and name.len > root_name.len and name[root_name.len] == '.') return true;
        }
    }
    return false;
}

/// Resolve a barrel's namespace meaning back to its ambient module owner.
/// An origin points at one declaration, not at all merged fragments; routing
/// that one declaration would silently drop later class/namespace members.
fn forwardedAmbientNamespace(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    builder: *schemas.Builder,
    supported: *std.AutoHashMapUnmanaged(*const driver.ProgramClassSchema.Declaration, bool),
    sources: []const Source,
    modules: *const AmbientModuleOwners,
    by_path: *const std.StringHashMapUnmanaged(usize),
    declarations: *const std.AutoHashMapUnmanaged(Position, hir.NodeId),
    resolved: export_origins.Origins,
    target_path: []const u8,
    public_name: []const u8,
) !ForwardedAmbientMerge {
    if (!resolved.complete or resolved.ambiguous or resolved.restriction != null or resolved.value == null) return .{};
    const origin = resolved.namespace orelse return .{};
    const key = originKey(by_path, declarations, origin) orelse return .{};
    const source = sources[key.source];
    if (source.compilation.hir.kindOf(key.node) != .namespace_decl) return .{};
    const source_name = declarationName(source.compilation, key.node) orelse return .{};
    const module_owner = ambientModuleContainingOrigin(sources, modules, key) orelse return .{};
    const specifier = module_owner.specifier;
    const module_owners = module_owner.owners;
    const source_origins = try builder.query.resolveModule(specifier, source.path, source_name);
    if (!export_origins.Origins.sameDeclaration(resolved, source_origins)) return .{};
    if (try mergedAmbientNamespace(gpa, arena, builder, supported, sources, module_owners, target_path, source_name, public_name)) |routes| {
        return .{ .routes = routes, .source_module = specifier, .source_name = source_name };
    }
    if (try classNamespaceMergeConflict(arena, sources, module_owners, source_name)) {
        return .{ .unresolved = true, .source_module = specifier, .source_name = source_name };
    }
    if (!hasDottedNamespaceAugmentation(sources, module_owners, source_name)) return .{};
    return .{ .source_module = specifier, .source_name = source_name };
}

fn collectAmbientModules(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    builder: *schemas.Builder,
    supported: *std.AutoHashMapUnmanaged(*const driver.ProgramClassSchema.Declaration, bool),
    sources: []const Source,
    by_path: *const std.StringHashMapUnmanaged(usize),
    declarations: *const std.AutoHashMapUnmanaged(Position, hir.NodeId),
    ambient_const_enums: *const std.AutoHashMapUnmanaged(Position, void),
    values: *std.ArrayListUnmanaged(driver.ProgramExportedValue),
    types: *std.ArrayListUnmanaged(driver.ProgramExportedType),
) ![]const driver.ProgramAmbientModule {
    var modules: AmbientModuleOwners = .empty;
    for (sources, 0..) |source, index| {
        const c = source.compilation;
        if (c.hir.kindOf(c.root) != .block_stmt or @import("ts_program.zig").Program.boundSourceIsExternalModule(c)) continue;
        for (hir.blockStmts(&c.hir, c.root)) |node| {
            if (c.hir.kindOf(node) != .namespace_decl) continue;
            const namespace = hir.namespaceOf(&c.hir, node);
            const span = c.hir.spanOf(namespace.name);
            if (span.start >= c.source.len or (c.source[span.start] != '"' and c.source[span.start] != '\'')) continue;
            const name = switch (c.hir.kindOf(namespace.name)) {
                .identifier => c.interner.get(hir.identifierOf(&c.hir, namespace.name).name),
                .literal_string => c.interner.get(hir.literalStringOf(&c.hir, namespace.name).value),
                else => continue,
            };
            const owners = try modules.getOrPut(arena, name);
            if (!owners.found_existing) owners.value_ptr.* = .empty;
            try owners.value_ptr.append(arena, .{ .source = index, .node = node });
        }
    }
    var result: std.ArrayListUnmanaged(driver.ProgramAmbientModule) = .empty;
    var pending_forwards: std.ArrayListUnmanaged(PendingAmbientForward) = .empty;
    var iterator = modules.iterator();
    while (iterator.next()) |entry| {
        const specifier = entry.key_ptr.*;
        const owners = entry.value_ptr.items;
        const host = sources[owners[0].source];
        const public_names = try builder.query.exportNamesForModule(specifier, host.path);
        // Export-name closure is independent of resolving each alias target.
        const complete = public_names.complete;
        var names: std.StringHashMapUnmanaged(void) = .empty;
        for (public_names.names) |name| try names.put(arena, name, {});
        for (owners) |owner| {
            const c = sources[owner.source].compilation;
            const scope = scopeFor(c, owner.node) orelse continue;
            inline for (.{ "types", "values", "namespaces" }) |field| {
                var bindings = @field(scope, field).keyIterator();
                while (bindings.next()) |name| try names.put(arena, c.interner.get(name.*), {});
            }
        }
        const rendered = try std.fmt.allocPrint(arena, "\"{s}\"", .{specifier});
        var facts: std.ArrayListUnmanaged(driver.ProgramAmbientModuleExport) = .empty;
        var named = names.keyIterator();
        while (named.next()) |name| {
            const resolved = try builder.query.resolveModule(specifier, host.path, name.*);
            // A star can expose a dotted augmentation independently of its
            // root namespace. TypeScript only applies that augmentation when
            // the winning root export comes from the same ambient module.
            if (std.mem.indexOfScalar(u8, name.*, '.')) |dot| {
                const root = try builder.query.resolveModule(specifier, host.path, name.*[0..dot]);
                const root_key = if (root.namespace) |origin| originKey(by_path, declarations, origin) else null;
                const member_key = if (resolved.namespace) |origin| originKey(by_path, declarations, origin) else null;
                const root_owner = if (root_key) |key| ambientModuleContainingOrigin(sources, &modules, key) else null;
                const member_owner = if (member_key) |key| ambientModuleContainingOrigin(sources, &modules, key) else null;
                if (root_owner != null and member_owner != null and
                    !std.mem.eql(u8, root_owner.?.specifier, member_owner.?.specifier)) continue;
            }
            var merged: ?MergedAmbientNamespace = null;
            var forwarded_unresolved = false;
            var deferred_forward = false;
            var module_alias_source: []const u8 = "";
            if (resolved.complete and public_names.complete) {
                merged = try mergedAmbientNamespace(gpa, arena, builder, supported, sources, owners, host.path, name.*, name.*);
                if (merged == null) {
                    const forwarded = try forwardedAmbientNamespace(gpa, arena, builder, supported, sources, &modules, by_path, declarations, resolved, host.path, name.*);
                    merged = forwarded.routes;
                    forwarded_unresolved = forwarded.unresolved;
                    if (merged == null and !forwarded_unresolved and forwarded.source_module.len != 0 and
                        !std.mem.eql(u8, forwarded.source_module, specifier))
                    {
                        deferred_forward = true;
                        try pending_forwards.append(arena, .{
                            .source_module = forwarded.source_module,
                            .source_name = forwarded.source_name,
                            .target_module = specifier,
                            .target_path = host.path,
                            .public_name = name.*,
                        });
                    }
                    if (merged == null and !forwarded_unresolved and !deferred_forward and
                        !resolved.ambiguous and resolved.restriction == null)
                    {
                        // A module-namespace alias points at one arbitrary
                        // declaration fragment. Forward the completed source
                        // module after every fragment has contributed routes.
                        if (resolved.namespace) |origin| {
                            if (originKey(by_path, declarations, origin)) |key| {
                                if (ambientModuleContainingOrigin(sources, &modules, key)) |module_owner| {
                                    for (module_owner.owners) |owner| {
                                        if (owner.source != key.source or owner.node != key.node) continue;
                                        if (std.mem.eql(u8, module_owner.specifier, specifier)) break;
                                        module_alias_source = module_owner.specifier;
                                        deferred_forward = true;
                                        try pending_forwards.append(arena, .{
                                            .source_module = module_owner.specifier,
                                            .source_name = "",
                                            .target_module = specifier,
                                            .target_path = host.path,
                                            .public_name = name.*,
                                        });
                                        break;
                                    }
                                }
                            }
                        }
                    }
                }
            }
            const unresolved_merge = merged == null and (forwarded_unresolved or try classNamespaceMergeConflict(arena, sources, owners, name.*));
            const merged_has_value = if (merged) |routes| routes.values.len != 0 else false;
            const known = merged != null or (resolved.complete and !resolved.ambiguous and
                (public_names.complete or resolved.type != null or resolved.value != null or resolved.type_only_value != null or resolved.namespace != null));
            var local = false;
            var renamed: []const u8 = "";
            for (owners) |owner| {
                const c = sources[owner.source].compilation;
                const scope = scopeFor(c, owner.node) orelse continue;
                const id = c.interner.lookup(name.*) orelse continue;
                inline for (.{ "types", "values", "namespaces" }) |field| {
                    if (@field(scope, field).get(id)) |symbol| for (symbol.decls.items) |declaration_node| {
                        const parent = c.hir.parentOf(declaration_node);
                        // A named default declaration does not make its
                        // internal name an ordinary private import candidate.
                        if (parent != 0 and c.hir.kindOf(parent) == .export_decl and hir.exportOf(&c.hir, parent).is_default) continue;
                        local = true;
                    };
                }
                for (hir.namespaceBody(&c.hir, owner.node)) |statement| {
                    if (c.hir.kindOf(statement) != .export_decl) continue;
                    const export_info = hir.exportOf(&c.hir, statement);
                    if (c.interner.get(export_info.module).len != 0) continue;
                    for (hir.exportNamed(&c.hir, statement)) |alias| {
                        const item = hir.importSpecifierOf(&c.hir, alias);
                        if (item.imported == id and item.local != id and renamed.len == 0) renamed = c.interner.get(item.local);
                    }
                }
            }
            const value = resolved.value orelse resolved.type_only_value;
            const ambient_const_enum = if (known and value != null)
                ambientConstEnumOrigin(by_path, ambient_const_enums, value.?)
            else
                false;
            try facts.append(arena, .{ .name = name.*, .facts = .{
                .module_name = rendered,
                .exported_type = known and resolved.type != null,
                .exported_value = known and (if (merged != null) merged_has_value else value != null),
                .namespace_meaning = if (known) merged != null or resolved.namespace != null else null,
                .declares_local = local,
                .local_exported_as = renamed,
                .runtime_value = if (known) (if (merged != null) merged_has_value else resolved.value != null) else null,
                .ambient_const_enum = ambient_const_enum,
                .generic_function = if (value) |found| found.generic_function else false,
                .call_only_function = if (value) |found| found.call_only_function else false,
                .type_only_export = if (resolved.restriction) |restriction| restriction.kind == .export_type else false,
                .type_only_import = if (resolved.restriction) |restriction| restriction.kind == .import_type else false,
                .export_path = if (resolved.restriction) |restriction| restriction.path else "",
                .export_pos = if (resolved.restriction) |restriction| restriction.position else 0,
                .namespace_module_path = if (merged != null) host.path else if (resolved.namespace) |namespace| if (namespace.kind == .namespace) namespace.path else "" else "",
                .namespace_ambient_module = module_alias_source,
                .ambient_module = true,
                .ambient_module_exports_known = known,
                .module_is_external = true,
            } });
            if (!known) continue;
            if (merged) |routes| {
                for (routes.values) |route| {
                    var exported = route;
                    exported.ambient_module_name = specifier;
                    try values.append(arena, exported);
                }
                for (routes.types) |route| {
                    var exported = route;
                    exported.ambient_module_name = specifier;
                    try types.append(arena, exported);
                }
                continue;
            }
            if (unresolved_merge or deferred_forward) continue;
            if (resolved.type) |origin| if (originKey(by_path, declarations, origin)) |key| {
                const c = sources[key.source].compilation;
                if (c.hir.kindOf(key.node) != .namespace_decl) {
                    const declaration = try builder.declaration(key);
                    const support = try supported.getOrPut(arena, declaration);
                    if (!support.found_existing) support.value_ptr.* = try driver.ProgramClassSchema.Schema.declarationSupported(declaration, gpa);
                    try types.append(arena, .{ .target_path = host.path, .ambient_module_name = specifier, .export_name = name.*, .declaration = declaration, .contextual_only = declaration.contextual_only, .projection_only = !support.value_ptr.* });
                }
            };
            if (value) |origin| {
                if (originKey(by_path, declarations, origin)) |key| {
                    const c = sources[key.source].compilation;
                    if (c.hir.kindOf(key.node) != .namespace_decl) {
                        const declaration = try builder.declaration(key);
                        const support = try supported.getOrPut(arena, declaration);
                        if (!support.found_existing) support.value_ptr.* = try driver.ProgramClassSchema.Schema.declarationSupported(declaration, gpa);
                        var value_declaration = declaration;
                        if (declaration.is_class) {
                            const expression = try arena.create(driver.ProgramClassSchema.Expression);
                            expression.* = .{ .typeof_class = declaration };
                            const wrapper = try arena.create(driver.ProgramClassSchema.Declaration);
                            wrapper.* = .{ .path = declaration.path, .position = declaration.position, .name = declaration.name, .body = expression, .value_side = true };
                            value_declaration = wrapper;
                        }
                        try values.append(arena, .{ .target_path = host.path, .ambient_module_name = specifier, .export_name = name.*, .kind = if (declaration.is_function) .function else .variable, .declaration = value_declaration, .runtime_value = resolved.value != null, .projection_only = !support.value_ptr.* });
                    }
                }
            }
            if (resolved.namespace) |origin| {
                const namespace_values_start = values.items.len;
                if (originKey(by_path, declarations, origin)) |key| {
                    const c = sources[key.source].compilation;
                    if (c.hir.kindOf(key.node) == .namespace_decl) {
                        const first_value = values.items.len;
                        const first_type = types.items.len;
                        try appendNamespaceValueRoute(gpa, arena, builder, supported, key.source, sources[key.source], key.node, host.path, name.*, null, null, values);
                        try appendNamespaceTypeRoute(gpa, arena, builder, supported, key.source, sources[key.source], key.node, host.path, name.*, types);
                        for (values.items[first_value..]) |*route| route.ambient_module_name = specifier;
                        for (types.items[first_type..]) |*route| route.ambient_module_name = specifier;
                    }
                }
                if (resolved.value != null and values.items.len == namespace_values_start) try values.append(arena, .{ .target_path = host.path, .ambient_module_name = specifier, .export_name = name.*, .kind = .variable });
            }
        }
        try result.append(arena, .{ .specifier = specifier, .rendered_name = rendered, .exports = try facts.toOwnedSlice(arena), .complete = complete });
    }
    // Dotted augmentations and module-namespace aliases can themselves be
    // reexported. Resolve their dependency graph after every direct module
    // route is collected; hash-map iteration order must not decide whether a
    // barrel sees all source fragments. A failed or cyclic dependency is never
    // published as a partial subtree.
    const ForwardState = enum { pending, complete, failed };
    const states = try arena.alloc(ForwardState, pending_forwards.items.len);
    @memset(states, .pending);
    var remaining = states.len;
    while (remaining != 0) {
        var advanced = false;
        for (pending_forwards.items, 0..) |forward, index| {
            if (states[index] != .pending) continue;
            var waiting = false;
            var failed_dependency = false;
            for (pending_forwards.items, 0..) |dependency, dependency_index| {
                if (!std.mem.eql(u8, dependency.target_module, forward.source_module)) continue;
                if (forward.source_name.len != 0 and
                    !std.mem.eql(u8, dependency.public_name, forward.source_name)) continue;
                switch (states[dependency_index]) {
                    .pending => waiting = true,
                    .failed => failed_dependency = true,
                    .complete => {},
                }
            }
            if (failed_dependency) {
                states[index] = .failed;
                remaining -= 1;
                advanced = true;
                continue;
            }
            if (waiting) continue;
            var selected_values: std.ArrayListUnmanaged(driver.ProgramExportedValue) = .empty;
            var selected_types: std.ArrayListUnmanaged(driver.ProgramExportedType) = .empty;
            var exact = true;
            for (values.items) |route| {
                if (!std.mem.eql(u8, route.ambient_module_name, forward.source_module)) continue;
                const path = try forwardedNamespacePath(arena, route.namespace_path, forward.source_name, forward.public_name) orelse continue;
                if (route.projection_only or (route.declaration == null and route.enum_members == null)) {
                    exact = false;
                    break;
                }
                var forwarded = route;
                forwarded.target_path = forward.target_path;
                forwarded.ambient_module_name = forward.target_module;
                forwarded.namespace_path = path;
                try selected_values.append(arena, forwarded);
            }
            if (exact) for (types.items) |route| {
                if (!std.mem.eql(u8, route.ambient_module_name, forward.source_module)) continue;
                const path = try forwardedNamespacePath(arena, route.namespace_path, forward.source_name, forward.public_name) orelse continue;
                if (route.contextual_only or route.projection_only) {
                    exact = false;
                    break;
                }
                var forwarded = route;
                forwarded.target_path = forward.target_path;
                forwarded.ambient_module_name = forward.target_module;
                forwarded.namespace_path = path;
                try selected_types.append(arena, forwarded);
            };
            if (exact and selected_values.items.len + selected_types.items.len != 0) {
                try values.appendSlice(arena, selected_values.items);
                try types.appendSlice(arena, selected_types.items);
                states[index] = .complete;
            } else states[index] = .failed;
            remaining -= 1;
            advanced = true;
        }
        if (!advanced) break;
    }
    return result.toOwnedSlice(arena);
}

pub fn collect(gpa: std.mem.Allocator, resolver: *resolver_mod.Resolver, sources: []const Source) !Graph {
    var result = Graph.init(gpa);
    errdefer result.deinit();
    const arena = result.arena.allocator();
    var builder = try schemas.Builder.init(gpa, arena, resolver, sources);
    defer builder.query.deinit();
    var by_path: std.StringHashMapUnmanaged(usize) = .empty;
    var declarations: std.AutoHashMapUnmanaged(Position, hir.NodeId) = .empty;
    var ambient_const_enums: std.AutoHashMapUnmanaged(Position, void) = .empty;
    var pending: std.ArrayListUnmanaged(Binding) = .empty;
    var visited: std.HashMapUnmanaged(Binding, void, BindingContext, 80) = .empty;
    var supported: std.AutoHashMapUnmanaged(*const driver.ProgramClassSchema.Declaration, bool) = .empty;
    const importers = try arena.alloc(std.ArrayListUnmanaged(usize), sources.len);
    @memset(importers, .empty);
    var values: std.ArrayListUnmanaged(driver.ProgramExportedValue) = .empty;
    var types: std.ArrayListUnmanaged(driver.ProgramExportedType) = .empty;
    for (sources, 0..) |source, index| {
        try by_path.put(arena, source.path, index);
        const c = source.compilation;
        for (c.hir.kinds.items, 0..) |kind, node| {
            switch (kind) {
                .fn_decl, .var_decl, .let_decl, .const_decl, .interface_decl, .type_alias_decl, .class_decl, .namespace_decl => try declarations.put(arena, .{ .source = index, .position = c.hir.spanOf(@intCast(node)).start }, @intCast(node)),
                .enum_decl => {
                    const id: hir.NodeId = @intCast(node);
                    if (hir.enumOf(&c.hir, id).is_const and (c.is_declaration_file or enumIsInAmbientModule(c, id))) {
                        try ambient_const_enums.put(arena, .{ .source = index, .position = c.hir.spanOf(id).start }, {});
                    }
                },
                else => {},
            }
        }
        for (c.module.symbols.items) |symbol| {
            if (symbol.parent_scope != c.module.root or !symbol.flags.is_export) continue;
            try pending.append(arena, .{ .source = index, .name = if (symbol.flags.is_default_export) "default" else c.interner.get(symbol.name) });
        }
    }
    result.ambient_modules = try collectAmbientModules(gpa, arena, &builder, &supported, sources, &by_path, &declarations, &ambient_const_enums, &values, &types);
    for (sources, 0..) |source, index| {
        const c = source.compilation;
        if (c.root == 0 or c.hir.kindOf(c.root) != .block_stmt) continue;
        for (hir.blockStmts(&c.hir, c.root)) |statement| {
            if (c.hir.kindOf(statement) != .export_decl) continue;
            const ex = hir.exportOf(&c.hir, statement);
            if (ex.is_default and !ex.is_export_equals) {
                try pending.append(arena, .{ .source = index, .name = "default" });
            }
            for (hir.exportNamed(&c.hir, statement)) |specifier| {
                const spec = hir.importSpecifierOf(&c.hir, specifier);
                try pending.append(arena, .{ .source = index, .name = c.interner.get(spec.local) });
            }
            if (!ex.is_namespace or c.interner.get(ex.namespace_alias).len != 0) continue;
            const specifier = c.interner.get(ex.module);
            if (specifier.len == 0) continue;
            const target = resolver.resolve(specifier, source.path) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => continue,
            };
            if (by_path.get(target.path)) |target_index| try importers[target_index].append(arena, index);
        }
    }
    var cursor: usize = 0;
    while (cursor < pending.items.len) : (cursor += 1) {
        const binding = pending.items[cursor];
        const seen = try visited.getOrPut(arena, binding);
        if (seen.found_existing) continue;
        if (!std.mem.eql(u8, binding.name, "default")) {
            for (importers[binding.source].items) |index| try pending.append(arena, .{ .source = index, .name = binding.name });
        }
        const origins = try builder.query.resolve(sources[binding.source].path, binding.name);
        if (!origins.complete or origins.ambiguous) continue;
        if (origins.namespace) |origin| {
            if (by_path.get(origin.path)) |owner| {
                if (declarations.get(.{ .source = owner, .position = origin.position })) |node| {
                    if (sources[owner].compilation.hir.kindOf(node) == .namespace_decl) {
                        try appendNamespaceValueRoute(gpa, arena, &builder, &supported, owner, sources[owner], node, sources[binding.source].path, binding.name, null, null, &values);
                        try appendNamespaceTypeRoute(gpa, arena, &builder, &supported, owner, sources[owner], node, sources[binding.source].path, binding.name, &types);
                    }
                }
            }
        }
        for (0..2) |space| {
            const origin = (if (space == 1) origins.value orelse origins.type_only_value else origins.type) orelse continue;
            const owner = by_path.get(origin.path) orelse continue;
            const node = declarations.get(.{ .source = owner, .position = origin.position }) orelse continue;
            if (sources[owner].compilation.hir.kindOf(node) == .namespace_decl or
                sources[owner].compilation.hir.kindOf(node) == .class_decl) continue;
            const declaration = try builder.declaration(.{ .source = owner, .node = node });
            const entry = try supported.getOrPut(arena, declaration);
            if (!entry.found_existing) entry.value_ptr.* = try driver.ProgramClassSchema.Schema.declarationSupported(declaration, gpa);
            if (space == 0) {
                try types.append(arena, .{
                    .target_path = sources[binding.source].path,
                    .export_name = binding.name,
                    .declaration = declaration,
                    .contextual_only = declaration.contextual_only,
                    .projection_only = !entry.value_ptr.*,
                });
            } else {
                // Parse-diagnostic files publish only the closed literal
                // recovery surface below. An unsupported declaration from a
                // malformed statement is not trustworthy projection metadata.
                if (!entry.value_ptr.* and sources[binding.source].compilation.has_syntactic_parse_diagnostics) continue;
                try values.append(arena, .{
                    .target_path = sources[binding.source].path,
                    .export_name = binding.name,
                    .kind = if (declaration.is_function) .function else .variable,
                    .declaration = declaration,
                    .projection_only = !entry.value_ptr.*,
                });
            }
        }
    }
    // A merged interface/namespace exports its nested types through the root
    // namespace binding. Route those exact source-owned declarations through
    // every direct or export-star target already proven unambiguous above.
    // This keeps `import type { Root }; Root.Member` on the same lossless
    // declaration graph as ordinary top-level imports.
    // `types` grows while nested declarations are appended, so retain a
    // stable snapshot of the proven top-level routes instead of iterating a
    // slice that an ArrayList reallocation could invalidate.
    const routed_types = try arena.dupe(driver.ProgramExportedType, types.items);
    for (sources, 0..) |source, source_index| {
        const c = source.compilation;
        if (c.root == hir.none_node_id or c.hir.kindOf(c.root) != .block_stmt) continue;
        for (hir.blockStmts(&c.hir, c.root)) |raw| {
            if (c.hir.kindOf(raw) != .export_decl) continue;
            const namespace_node = hir.exportOf(&c.hir, raw).decl;
            if (namespace_node == hir.none_node_id or c.hir.kindOf(namespace_node) != .namespace_decl) continue;
            const namespace = hir.namespaceOf(&c.hir, namespace_node);
            if (namespace.name == hir.none_node_id or c.hir.kindOf(namespace.name) != .identifier) continue;
            const namespace_name = c.interner.get(hir.identifierOf(&c.hir, namespace.name).name);
            for (routed_types) |route| {
                if (route.namespace_path.len != 0 or
                    !std.mem.eql(u8, route.declaration.path, source.path) or
                    !std.mem.eql(u8, route.declaration.name, namespace_name))
                {
                    continue;
                }
                try appendNamespaceTypeRoute(
                    gpa,
                    arena,
                    &builder,
                    &supported,
                    source_index,
                    source,
                    namespace_node,
                    route.target_path,
                    route.export_name,
                    &types,
                );
            }
        }
    }
    // A self-contained literal `export const` remains trustworthy even when
    // an unrelated parser diagnostic makes the file's broader export graph
    // incomplete. Publish only that closed form: no aliases, dependencies,
    // or partially reconstructed object/function shapes can leak through.
    for (sources, 0..) |source, index| {
        const c = source.compilation;
        if (!c.has_syntactic_parse_diagnostics) continue;
        var symbols = c.module.root.values.iterator();
        while (symbols.next()) |entry| {
            const symbol = entry.value_ptr.*;
            if (!symbol.flags.is_export or symbol.flags.is_import or symbol.decls.items.len != 1) continue;
            const node = symbol.decls.items[0];
            if (c.hir.kindOf(node) != .const_decl) continue;
            const variable = hir.varDeclOf(&c.hir, node);
            if (variable.type_annotation != hir.none_node_id or variable.init == hir.none_node_id) continue;
            switch (c.hir.kindOf(variable.init)) {
                .literal_string, .literal_number, .literal_bool => {},
                else => continue,
            }
            const export_name = if (symbol.flags.is_default_export) "default" else c.interner.get(entry.key_ptr.*);
            var present = false;
            for (values.items) |value| {
                if (std.mem.eql(u8, value.target_path, source.path) and std.mem.eql(u8, value.export_name, export_name)) {
                    present = true;
                    break;
                }
            }
            if (present) continue;
            const declaration = try builder.declaration(.{ .source = index, .node = node });
            const supported_entry = try supported.getOrPut(arena, declaration);
            if (!supported_entry.found_existing) supported_entry.value_ptr.* = try driver.ProgramClassSchema.Schema.declarationSupported(declaration, gpa);
            if (!supported_entry.value_ptr.*) continue;
            try values.append(arena, .{
                .target_path = source.path,
                .export_name = export_name,
                .kind = .variable,
                .declaration = declaration,
            });
        }
    }
    result.values = try values.toOwnedSlice(arena);
    result.types = try types.toOwnedSlice(arena);
    return result;
}
