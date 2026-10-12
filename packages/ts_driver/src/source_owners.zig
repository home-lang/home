//! Source-owner identity and real declaration provenance for typed imports.
//!
//! Owners borrow immutable compilation storage. Unregister an owner BEFORE
//! destroying/replacing that storage. IDs are never reused during this registry
//! lifetime, so an old declaration handle cannot alias a replacement source.
//! Handles are NOT local HIR NodeIds; resolve them through declaration().
//! Registry and target type pool require exclusive access during importOwner.
//! Untagged provenance belongs to the source owner's local HIR; tagged values
//! are handles already owned by this registry and survive transitive transfer.
//! Never place handles from another registry in a source or target pool.

const std = @import("std");
const hir = @import("hir");
const strings = @import("string_interner");
const checker = @import("ts_checker");

pub const OwnerId = enum(u32) { none = 0, _ };
pub const Error = checker.checked_transfer.Error || error{ InvalidOwner, InvalidDeclaration };

/// Declaration-bearing type payloads use the same scalar storage as local
/// HIR NodeIds. Tag registry handles so a checked owner that already contains
/// imported declarations can be transferred again without reinterpreting a
/// foreign handle as a node in the intermediate owner's HIR.
const declaration_handle_tag: hir.NodeId = 1 << 31;
const declaration_handle_index_mask: hir.NodeId = declaration_handle_tag - 1;

pub fn isDeclarationHandle(node: hir.NodeId) bool {
    return node & declaration_handle_tag != 0;
}

pub const Source = struct {
    hir: *const hir.Hir,
    strings: *const strings.Interner,
    types: *const checker.Interner,
    checked: *const checker.CheckedTypes,
    path: []const u8,
    text: []const u8,
};

const NodeKey = struct { owner: OwnerId, node: hir.NodeId };
const TypeOrigin = struct { owner: OwnerId = .none, id: checker.TypeId = 0 };
const TargetTypes = struct {
    origins: std.ArrayListUnmanaged(TypeOrigin) = .empty,
    canonical: std.AutoHashMapUnmanaged(TypeOrigin, checker.TypeId) = .empty,

    fn deinit(self: *TargetTypes, allocator: std.mem.Allocator) void {
        self.origins.deinit(allocator);
        self.canonical.deinit(allocator);
    }
};

pub const Declaration = struct {
    owner: OwnerId,
    source: Source,
    node: hir.NodeId,

    pub fn span(self: Declaration) hir.Span {
        return self.source.hir.spanOf(self.node);
    }

    pub fn text(self: Declaration) []const u8 {
        const location = self.span();
        return self.source.text[location.start..location.end];
    }
};

pub const Imported = struct {
    owner: OwnerId,
    types: checker.checked_transfer.Imported,

    pub fn deinit(self: *Imported) void {
        self.types.deinit();
    }
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    owners: std.ArrayListUnmanaged(?Source) = .empty,
    nodes: std.ArrayListUnmanaged(NodeKey) = .empty,
    node_ids: std.AutoHashMapUnmanaged(NodeKey, hir.NodeId) = .empty,
    target_types: std.AutoHashMapUnmanaged(*const checker.Interner, TargetTypes) = .empty,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        var targets = self.target_types.valueIterator();
        while (targets.next()) |target| target.deinit(self.allocator);
        self.target_types.deinit(self.allocator);
        self.node_ids.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.owners.deinit(self.allocator);
        self.* = init(self.allocator);
    }

    /// Every registration denotes a distinct immutable owner/revision, even
    /// when a path or memory address is reused. Callers cache by this ID.
    pub fn register(self: *Registry, view: Source) Error!OwnerId {
        if (self.owners.items.len == std.math.maxInt(u32)) return error.TypeIdOverflow;
        try self.owners.append(self.allocator, view);
        return @fromBackingInt(@intCast(self.owners.items.len));
    }

    pub fn source(self: *const Registry, id: OwnerId) Error!Source {
        const index = @backingInt(id);
        if (index == 0 or index > self.owners.items.len) return error.InvalidOwner;
        return self.owners.items[index - 1] orelse error.InvalidOwner;
    }

    /// Invalidate before freeing the borrowed compilation. Tombstone IDs are
    /// retained, but no source pointers remain reachable through this owner.
    /// Dependent imported records must no longer be used for semantic lookup.
    pub fn unregister(self: *Registry, id: OwnerId) Error!void {
        const view = try self.source(id);
        self.forgetTarget(view.types);
        self.owners.items[@backingInt(id) - 1] = null;
    }

    /// Call before destroying an importing pool, including a failed/unregistered
    /// compilation. A reused memory address must never inherit an older pool's
    /// type identities. Unregister performs this for registered source pools.
    pub fn forgetTarget(self: *Registry, target: *const checker.Interner) void {
        if (self.target_types.fetchRemove(target)) |entry| {
            var state = entry.value;
            state.deinit(self.allocator);
        }
    }

    fn typeOrigin(self: *const Registry, source_types: *const checker.Interner, owner: OwnerId, id: checker.TypeId) TypeOrigin {
        if (self.target_types.get(source_types)) |state| {
            if (id < state.origins.items.len and state.origins.items[id].owner != .none) return state.origins.items[id];
        }
        return .{ .owner = owner, .id = id };
    }

    pub fn declaration(self: *const Registry, handle: hir.NodeId) Error!Declaration {
        if (!isDeclarationHandle(handle)) return error.InvalidDeclaration;
        const raw_index = handle & declaration_handle_index_mask;
        if (raw_index == 0 or raw_index > self.nodes.items.len) return error.InvalidDeclaration;
        const key = self.nodes.items[raw_index - 1];
        const owner = try self.source(key.owner);
        if (key.node == 0 or key.node >= owner.hir.nodeCount()) return error.InvalidDeclaration;
        const location = owner.hir.spanOf(key.node);
        if (location.start > location.end or location.end > owner.text.len) return error.InvalidDeclaration;
        return .{ .owner = key.owner, .source = owner, .node = key.node };
    }

    fn internDeclaration(self: *Registry, owner: OwnerId, node: hir.NodeId) Error!hir.NodeId {
        const view = try self.source(owner);
        if (node == 0 or isDeclarationHandle(node) or node >= view.hir.nodeCount()) return error.InvalidDeclaration;
        const location = view.hir.spanOf(node);
        if (location.start > location.end or location.end > view.text.len) return error.InvalidDeclaration;
        const key: NodeKey = .{ .owner = owner, .node = node };
        if (self.node_ids.get(key)) |id| return id;
        if (self.nodes.items.len == declaration_handle_index_mask) return error.TypeIdOverflow;
        try self.nodes.ensureUnusedCapacity(self.allocator, 1);
        try self.node_ids.ensureUnusedCapacity(self.allocator, 1);
        self.nodes.appendAssumeCapacity(key);
        const id: hir.NodeId = declaration_handle_tag | @as(hir.NodeId, @intCast(self.nodes.items.len));
        self.node_ids.putAssumeCapacityNoClobber(key, id);
        return id;
    }

    fn cancelDeclarations(self: *Registry, first: usize) void {
        for (self.nodes.items[first..]) |key| {
            const removed = self.node_ids.remove(key);
            std.debug.assert(removed);
        }
        self.nodes.items.len = first;
    }

    /// Import one owner's payloads, semantics, and declaration mappings as a
    /// single publication. String interning is caller-owned and may retain
    /// unused strings/capacity on failure; no type or declaration refers to
    /// them until success. Registered owners themselves are not unregistered.
    pub fn importOwner(
        self: *Registry,
        target: *checker.Interner,
        target_strings: *strings.Interner,
        owner: OwnerId,
    ) Error!Imported {
        const view = try self.source(owner);
        if (view.types == target) return error.InvalidTypeGraph;
        const source_count = view.types.pool.typeCount();
        const target_count = target.pool.typeCount();
        if (source_count > std.math.maxInt(u32) - target_count) return error.TypeIdOverflow;
        // Verify transitive owners even when their payloads can be reused. A
        // cached destination ID does not make a tombstoned source revision live.
        for (checker.Primitive.first_dynamic..source_count) |index| {
            const origin = self.typeOrigin(view.types, owner, @intCast(index));
            _ = self.source(origin.owner) catch return error.UnmappedName;
        }
        const slot = try self.target_types.getOrPut(self.allocator, target);
        if (!slot.found_existing) slot.value_ptr.* = .{};
        try slot.value_ptr.canonical.ensureUnusedCapacity(self.allocator, source_count);
        try slot.value_ptr.origins.ensureTotalCapacity(self.allocator, target_count + source_count);
        const first = self.nodes.items.len;
        errdefer self.cancelDeclarations(first);
        var context = Context{ .registry = self, .owner = owner, .from = view.strings, .to = target_strings, .source_types = view.types, .target_types = target };
        const imported = try checker.checked_transfer.append(target, view.types, view.checked, .{
            .context = &context,
            .string = Context.string,
            .declaration = Context.node,
            .reuse_type = Context.reuseType,
        });
        // Capacity was reserved before the payload transaction. Publication of
        // provenance cannot fail after checked_transfer commits the type graph.
        const state = self.target_types.getPtr(target).?;
        const previous = state.origins.items.len;
        state.origins.items.len = target.pool.typeCount();
        @memset(state.origins.items[previous..], TypeOrigin{});
        for (checker.Primitive.first_dynamic..source_count) |index| {
            const id: checker.TypeId = @intCast(index);
            const origin = self.typeOrigin(view.types, owner, id);
            const mapped = imported.ids.ids[id];
            if (state.origins.items[mapped].owner == .none) state.origins.items[mapped] = origin;
            state.canonical.putAssumeCapacity(origin, mapped);
        }
        return .{ .owner = owner, .types = imported };
    }
};

const Context = struct {
    registry: *Registry,
    owner: OwnerId,
    from: *const strings.Interner,
    to: *strings.Interner,
    source_types: ?*const checker.Interner = null,
    target_types: ?*const checker.Interner = null,

    fn reuseType(context: *anyopaque, id: checker.TypeId) checker.type_transfer.Error!?checker.TypeId {
        const self: *Context = @ptrCast(@alignCast(context));
        const origin = self.registry.typeOrigin(self.source_types.?, self.owner, id);
        const state = self.registry.target_types.get(self.target_types.?) orelse return null;
        return state.canonical.get(origin);
    }

    fn string(context: *anyopaque, id: hir.StringId) checker.type_transfer.Error!hir.StringId {
        const self: *Context = @ptrCast(@alignCast(context));
        const value = self.from.getOptional(id) orelse return error.UnmappedName;
        return self.to.intern(value) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.ShardCapacityExceeded => error.TypeIdOverflow,
        };
    }

    fn node(context: *anyopaque, id: hir.NodeId) checker.type_transfer.Error!hir.NodeId {
        const self: *Context = @ptrCast(@alignCast(context));
        if (isDeclarationHandle(id)) {
            _ = self.registry.declaration(id) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.TypeIdOverflow => error.TypeIdOverflow,
                else => error.UnmappedName,
            };
            return id;
        }
        return self.registry.internDeclaration(self.owner, id) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.TypeIdOverflow => error.TypeIdOverflow,
            else => error.UnmappedName,
        };
    }
};

const T = std.testing;

const Fixture = struct {
    tree: hir.Hir,
    names: strings.Interner,
    types: checker.Interner,
    checked: checker.CheckedTypes = .{},
    decl: hir.NodeId,
    name: hir.StringId,
    object: checker.TypeId,
    const text = "interface Item {}";

    fn init() !Fixture {
        var tree = try hir.Hir.init(T.allocator);
        errdefer tree.deinit();
        var names = try strings.Interner.init(T.allocator);
        errdefer names.deinit();
        var types = try checker.Interner.init(T.allocator);
        errdefer types.deinit();
        var checked: checker.CheckedTypes = .{};
        errdefer checked.deinit(T.allocator);
        var builder = hir.Builder.init(&tree);
        defer builder.deinit();
        const name = try names.intern("Item");
        const identifier = try builder.addIdentifier(.{ .start = 10, .end = 14 }, name);
        const decl = try builder.addInterface(.{ .start = 0, .end = text.len }, identifier, &.{}, &.{}, &.{});
        const object = try types.internObjectType(&.{});
        types.pool.headers.items[object].symbol = decl;
        try checked.type_names.put(T.allocator, name, object);
        try checked.last_iface_decl_for_name.put(T.allocator, name, decl);
        const display = try T.allocator.dupe(u8, "Item");
        checked.alias_display_names.put(T.allocator, object, display) catch |err| {
            T.allocator.free(display);
            return err;
        };
        return .{ .tree = tree, .names = names, .types = types, .checked = checked, .decl = decl, .name = name, .object = object };
    }

    fn deinit(self: *Fixture) void {
        self.checked.deinit(T.allocator);
        self.types.deinit();
        self.names.deinit();
        self.tree.deinit();
    }

    fn view(self: *const Fixture) Source {
        return .{ .hir = &self.tree, .strings = &self.names, .types = &self.types, .checked = &self.checked, .path = "/same.ts", .text = text };
    }
};

test "source owners: real declarations remain distinct and stale revisions cannot alias replacements" {
    var registry = Registry.init(T.allocator);
    defer registry.deinit();
    var first = try Fixture.init();
    const first_owner = try registry.register(first.view());
    const old = try registry.internDeclaration(first_owner, first.decl);
    try T.expect(isDeclarationHandle(old));
    try T.expectError(error.InvalidDeclaration, registry.declaration(first.decl));
    try T.expectEqual(old, try registry.internDeclaration(first_owner, first.decl));
    try T.expectEqualStrings(Fixture.text, (try registry.declaration(old)).text());
    try registry.unregister(first_owner);
    first.deinit();
    try T.expectError(error.InvalidOwner, registry.declaration(old));
    try T.expectError(error.InvalidOwner, registry.source(first_owner));
    try T.expectError(error.InvalidOwner, registry.unregister(first_owner));
    var second = try Fixture.init();
    defer second.deinit();
    const second_owner = try registry.register(second.view());
    defer registry.unregister(second_owner) catch unreachable;
    const current = try registry.internDeclaration(second_owner, second.decl);
    try T.expect(isDeclarationHandle(current));
    try T.expect(first_owner != second_owner and old != current);
    var context = Context{ .registry = &registry, .owner = second_owner, .from = &second.names, .to = &second.names };
    try T.expectEqual(current, try Context.node(&context, current));
    try T.expectError(error.UnmappedName, Context.node(&context, old));
    try T.expectEqualStrings("/same.ts", (try registry.declaration(current)).source.path);
    try T.expectEqual(hir.NodeKind.interface_decl, (try registry.declaration(current)).source.hir.kindOf(second.decl));
    try T.expectError(error.InvalidOwner, registry.declaration(old));
    try T.expectError(error.InvalidDeclaration, registry.declaration(0));
    try T.expectError(error.InvalidDeclaration, registry.declaration(current + 1));
    try T.expectError(error.InvalidDeclaration, registry.internDeclaration(second_owner, second.tree.nodeCount()));
    const span = second.tree.spans.items[second.decl];
    second.tree.spans.items[second.decl].end = Fixture.text.len + 1;
    try T.expectError(error.InvalidDeclaration, registry.declaration(current));
    second.tree.spans.items[second.decl] = span;
}

const PoolLengths = std.enums.EnumArray(std.meta.FieldEnum(checker.Pool), usize);

fn poolLengths(pool: *const checker.Pool) PoolLengths {
    var result = PoolLengths.initFill(0);
    inline for (comptime std.meta.fieldNames(checker.Pool)) |name| {
        if (comptime !std.mem.eql(u8, name, "gpa")) result.set(@field(std.meta.FieldEnum(checker.Pool), name), @field(pool, name).items.len);
    }
    return result;
}

fn keyCount(value: *const checker.Interner) usize {
    var result: usize = 0;
    for (&value.shards) |*shard| result += shard.table.count();
    return result;
}

fn testImportAllocationFailures(allocator: std.mem.Allocator) !void {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var registry = Registry.init(allocator);
    defer registry.deinit();
    const existing_owner = try registry.register(fixture.view());
    const existing_handle = try registry.internDeclaration(existing_owner, fixture.decl);
    const owner = try registry.register(fixture.view());
    var target = try checker.Interner.init(allocator);
    defer target.deinit();
    _ = try target.internNumberLiteral(-1);
    // String storage is a separate caller-owned pool; rollback must not remove
    // its existing strings or require interner allocator substitution.
    var target_strings = try strings.Interner.init(T.allocator);
    defer target_strings.deinit();
    const before = poolLengths(&target.pool);
    const keys = keyCount(&target);
    const nodes = registry.nodes.items.len;
    const mappings = registry.node_ids.count();
    var imported = registry.importOwner(&target, &target_strings, owner) catch |err| {
        try T.expectEqualDeep(before, poolLengths(&target.pool));
        try T.expectEqual(keys, keyCount(&target));
        try T.expectEqual(nodes, registry.nodes.items.len);
        try T.expectEqual(mappings, registry.node_ids.count());
        try T.expectEqualStrings(Fixture.text, (try registry.declaration(existing_handle)).text());
        try T.expectEqual(fixture.object, fixture.checked.type_names.get(fixture.name).?);
        return err;
    };
    defer imported.deinit();
    const handle = imported.types.checked.last_iface_decl_for_name.get(target_strings.lookup("Item").?).?;
    try T.expect(handle != existing_handle);
    try T.expectEqual(owner, (try registry.declaration(handle)).owner);
    try T.expectEqualStrings(Fixture.text, (try registry.declaration(handle)).text());
    try T.expectEqual(handle, target.pool.headers.items[try imported.types.ids.typeId(fixture.object)].symbol);
}

test "source owners: import allocation failures roll back payloads semantics and new provenance together" {
    try T.checkAllAllocationFailures(T.allocator, testImportAllocationFailures, .{});
}

test "source owners: invalid semantic nodes cancel prepared types and provenance and allow retry" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var registry = Registry.init(T.allocator);
    defer registry.deinit();
    const owner = try registry.register(fixture.view());
    var target = try checker.Interner.init(T.allocator);
    defer target.deinit();
    var target_strings = try strings.Interner.init(T.allocator);
    defer target_strings.deinit();
    const before = poolLengths(&target.pool);
    // The object header prepares a real declaration mapping first. The later
    // metadata-only node is invalid, so both preparations must be cancelled.
    try fixture.checked.last_iface_decl_for_name.put(T.allocator, fixture.name, fixture.tree.nodeCount());
    try T.expectError(error.UnmappedName, registry.importOwner(&target, &target_strings, owner));
    try T.expectEqualDeep(before, poolLengths(&target.pool));
    try T.expectEqual(@as(usize, 0), registry.nodes.items.len);
    try T.expectEqual(@as(usize, 0), registry.node_ids.count());
    try T.expectEqual(@as(usize, 0), keyCount(&target));
    try fixture.checked.last_iface_decl_for_name.put(T.allocator, fixture.name, fixture.decl);
    var imported = try registry.importOwner(&target, &target_strings, owner);
    defer imported.deinit();
    try T.expectEqual(@as(usize, 1), registry.nodes.items.len);
    try T.expectEqual(@as(usize, 1), registry.node_ids.count());
    try registry.unregister(owner);
    try T.expectError(error.InvalidOwner, registry.importOwner(&target, &target_strings, owner));
}

test "source owners: transitive imports preserve original type identity without copying diamonds" {
    var registry = Registry.init(T.allocator);
    defer registry.deinit();
    var original = try Fixture.init();
    defer original.deinit();
    const original_owner = try registry.register(original.view());
    var intermediate = try Fixture.init();
    defer intermediate.deinit();
    var through_intermediate = try registry.importOwner(&intermediate.types, &intermediate.names, original_owner);
    defer through_intermediate.deinit();
    const intermediate_owner = try registry.register(intermediate.view());
    var destination = try checker.Interner.init(T.allocator);
    defer destination.deinit();
    var destination_names = try strings.Interner.init(T.allocator);
    defer destination_names.deinit();
    var direct = try registry.importOwner(&destination, &destination_names, original_owner);
    defer direct.deinit();
    const original_type = try direct.types.ids.typeId(original.object);
    const before = destination.pool.typeCount();
    var indirect = try registry.importOwner(&destination, &destination_names, intermediate_owner);
    defer indirect.deinit();
    const intermediate_type = try through_intermediate.types.ids.typeId(original.object);
    try T.expectEqual(original_type, try indirect.types.ids.typeId(intermediate_type));
    try T.expect(original_type != try indirect.types.ids.typeId(intermediate.object));
    try T.expectEqual(before + 1, destination.pool.typeCount());
    const completed = poolLengths(&destination.pool);
    var repeated = try registry.importOwner(&destination, &destination_names, intermediate_owner);
    defer repeated.deinit();
    try T.expectEqualDeep(completed, poolLengths(&destination.pool));
    try T.expectEqual(try indirect.types.ids.typeId(intermediate.object), try repeated.types.ids.typeId(intermediate.object));
}

test "source owners: cached imports still roll back failed metadata and reject stale dependencies" {
    var registry = Registry.init(T.allocator);
    defer registry.deinit();
    var original = try Fixture.init();
    defer original.deinit();
    const original_owner = try registry.register(original.view());
    var intermediate = try Fixture.init();
    defer intermediate.deinit();
    var imported_original = try registry.importOwner(&intermediate.types, &intermediate.names, original_owner);
    defer imported_original.deinit();
    const intermediate_owner = try registry.register(intermediate.view());
    var target = try checker.Interner.init(T.allocator);
    defer target.deinit();
    var names = try strings.Interner.init(T.allocator);
    defer names.deinit();
    var first = try registry.importOwner(&target, &names, intermediate_owner);
    defer first.deinit();
    const before = poolLengths(&target.pool);
    const canonical_count = registry.target_types.get(&target).?.canonical.count();
    const nodes = registry.nodes.items.len;
    try intermediate.checked.last_iface_decl_for_name.put(T.allocator, intermediate.name, intermediate.tree.nodeCount());
    try T.expectError(error.UnmappedName, registry.importOwner(&target, &names, intermediate_owner));
    try T.expectEqualDeep(before, poolLengths(&target.pool));
    try T.expectEqual(canonical_count, registry.target_types.get(&target).?.canonical.count());
    try T.expectEqual(nodes, registry.nodes.items.len);
    try intermediate.checked.last_iface_decl_for_name.put(T.allocator, intermediate.name, intermediate.decl);
    var retried = try registry.importOwner(&target, &names, intermediate_owner);
    defer retried.deinit();
    try T.expectEqualDeep(before, poolLengths(&target.pool));
    try registry.unregister(original_owner);
    try T.expectError(error.UnmappedName, registry.importOwner(&target, &names, intermediate_owner));
}

test "source owners: target address reuse and source revisions cannot inherit cached types" {
    var registry = Registry.init(T.allocator);
    defer registry.deinit();
    var original = try Fixture.init();
    defer original.deinit();
    const original_owner = try registry.register(original.view());
    var target = try checker.Interner.init(T.allocator);
    defer target.deinit();
    var names = try strings.Interner.init(T.allocator);
    defer names.deinit();
    _ = try target.internNumberLiteral(42);
    var old = try registry.importOwner(&target, &names, original_owner);
    defer old.deinit();
    const old_type = try old.types.ids.typeId(original.object);
    registry.forgetTarget(&target);
    target.deinit();
    target = try checker.Interner.init(T.allocator);
    var current = try registry.importOwner(&target, &names, original_owner);
    defer current.deinit();
    const current_type = try current.types.ids.typeId(original.object);
    try T.expect(current_type != old_type);
    try T.expect(current_type < target.pool.typeCount());
    try registry.unregister(original_owner);
    const replacement_owner = try registry.register(original.view());
    var replacement = try registry.importOwner(&target, &names, replacement_owner);
    defer replacement.deinit();
    try T.expect(current_type != try replacement.types.ids.typeId(original.object));
}

test "source owners: dense declaration import graphs grow by unique owners" {
    var registry = Registry.init(T.allocator);
    defer registry.deinit();
    var fixtures: [16]Fixture = undefined;
    var owners: [16]OwnerId = undefined;
    var initialized: usize = 0;
    defer for (fixtures[0..initialized]) |*fixture| fixture.deinit();
    for (&fixtures, 0..) |*fixture, index| {
        fixture.* = try Fixture.init();
        initialized += 1;
        for (owners[0..index]) |owner| {
            var imported = try registry.importOwner(&fixture.types, &fixture.names, owner);
            imported.deinit();
        }
        try T.expectEqual(@as(u32, checker.Primitive.first_dynamic + @as(u32, @intCast(index)) + 1), fixture.types.pool.typeCount());
        owners[index] = try registry.register(fixture.view());
    }
}

fn testCachedImportAllocationFailures(allocator: std.mem.Allocator) !void {
    var registry = Registry.init(allocator);
    defer registry.deinit();
    var original = try Fixture.init();
    defer original.deinit();
    const original_owner = try registry.register(original.view());
    var intermediate = try Fixture.init();
    defer intermediate.deinit();
    var imported_original = try registry.importOwner(&intermediate.types, &intermediate.names, original_owner);
    defer imported_original.deinit();
    const intermediate_owner = try registry.register(intermediate.view());
    var target = try checker.Interner.init(allocator);
    defer target.deinit();
    var names = try strings.Interner.init(T.allocator);
    defer names.deinit();
    var direct = try registry.importOwner(&target, &names, original_owner);
    defer direct.deinit();
    const before = poolLengths(&target.pool);
    const keys = keyCount(&target);
    const nodes = registry.nodes.items.len;
    const cache = registry.target_types.get(&target).?;
    const canonical_count = cache.canonical.count();
    const origins_len = cache.origins.items.len;
    var imported = registry.importOwner(&target, &names, intermediate_owner) catch |err| {
        try T.expectEqualDeep(before, poolLengths(&target.pool));
        try T.expectEqual(keys, keyCount(&target));
        try T.expectEqual(nodes, registry.nodes.items.len);
        try T.expectEqual(canonical_count, registry.target_types.get(&target).?.canonical.count());
        try T.expectEqual(origins_len, registry.target_types.get(&target).?.origins.items.len);
        try T.expectEqual(original_owner, (try registry.declaration(target.typeSymbol(try direct.types.ids.typeId(original.object)))).owner);
        return err;
    };
    defer imported.deinit();
    try T.expectEqual(try direct.types.ids.typeId(original.object), try imported.types.ids.typeId(try imported_original.types.ids.typeId(original.object)));
}

test "source owners: cached import allocation failures preserve existing graph identities" {
    try T.checkAllAllocationFailures(T.allocator, testCachedImportAllocationFailures, .{});
}
