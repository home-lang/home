//! Source-owner identity and real declaration provenance for typed imports.
//!
//! Owners borrow immutable compilation storage. Unregister an owner BEFORE
//! destroying/replacing that storage. IDs are never reused during this registry
//! lifetime, so an old declaration handle cannot alias a replacement source.
//! Handles are NOT local HIR NodeIds; resolve them through declaration().
//! The registry locks itself, so imports into distinct target pools may run
//! concurrently; a target pool needs exclusive access during importOwner.
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

/// Short critical sections only (a lookup or one append), so spin.
const SpinMutex = struct {
    state: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn lock(self: *SpinMutex) void {
        while (self.state.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *SpinMutex) void {
        self.state.store(false, .release);
    }
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    owners: std.ArrayListUnmanaged(?Source) = .empty,
    nodes: std.ArrayListUnmanaged(NodeKey) = .empty,
    node_ids: std.AutoHashMapUnmanaged(NodeKey, hir.NodeId) = .empty,
    /// Guards `owners`, `nodes` and `node_ids`. The type transfer itself runs
    /// outside it: one file's import no longer stalls every other worker.
    mutex: SpinMutex = .{},
    /// Per owner (parallel to `owners`), node -> declaration handle, 0 until
    /// interned. Published under `mutex`, read lock-free by importers: a
    /// handle never changes once set (cancellation clears unpublished ones).
    handles: std.ArrayListUnmanaged([]std.atomic.Value(hir.NodeId)) = .empty,

    fn lockShared(self: *const Registry) *SpinMutex {
        const mutex = @constCast(&self.mutex);
        mutex.lock();
        return mutex;
    }

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        for (self.handles.items) |table| self.allocator.free(table);
        self.handles.deinit(self.allocator);
        self.node_ids.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.owners.deinit(self.allocator);
        self.* = init(self.allocator);
    }

    /// Every registration denotes a distinct immutable owner/revision, even
    /// when a path or memory address is reused. Callers cache by this ID.
    pub fn register(self: *Registry, view: Source) Error!OwnerId {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.owners.items.len == std.math.maxInt(u32)) return error.TypeIdOverflow;
        const table = try self.allocator.alloc(std.atomic.Value(hir.NodeId), view.hir.nodeCount());
        errdefer self.allocator.free(table);
        @memset(table, std.atomic.Value(hir.NodeId).init(0));
        try self.handles.ensureUnusedCapacity(self.allocator, 1);
        try self.owners.append(self.allocator, view);
        self.handles.appendAssumeCapacity(table);
        return @fromBackingInt(@intCast(self.owners.items.len));
    }

    pub fn source(self: *const Registry, id: OwnerId) Error!Source {
        const mutex = self.lockShared();
        defer mutex.unlock();
        return self.sourceLocked(id);
    }

    fn sourceAndHandles(self: *Registry, id: OwnerId) Error!struct { Source, []std.atomic.Value(hir.NodeId) } {
        self.mutex.lock();
        defer self.mutex.unlock();
        const view = try self.sourceLocked(id);
        return .{ view, self.handles.items[@backingInt(id) - 1] };
    }

    fn sourceLocked(self: *const Registry, id: OwnerId) Error!Source {
        const index = @backingInt(id);
        if (index == 0 or index > self.owners.items.len) return error.InvalidOwner;
        return self.owners.items[index - 1] orelse error.InvalidOwner;
    }

    /// Invalidate before freeing the borrowed compilation. Tombstone IDs are
    /// retained, but no source pointers remain reachable through this owner.
    /// Dependent imported records must no longer be used for semantic lookup.
    pub fn unregister(self: *Registry, id: OwnerId) Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = try self.sourceLocked(id);
        self.owners.items[@backingInt(id) - 1] = null;
    }

    pub fn declaration(self: *const Registry, handle: hir.NodeId) Error!Declaration {
        if (!isDeclarationHandle(handle)) return error.InvalidDeclaration;
        const mutex = self.lockShared();
        defer mutex.unlock();
        const raw_index = handle & declaration_handle_index_mask;
        if (raw_index == 0 or raw_index > self.nodes.items.len) return error.InvalidDeclaration;
        const key = self.nodes.items[raw_index - 1];
        const owner = try self.sourceLocked(key.owner);
        if (key.node == 0 or key.node >= owner.hir.nodeCount()) return error.InvalidDeclaration;
        const location = owner.hir.spanOf(key.node);
        if (location.start > location.end or location.end > owner.text.len) return error.InvalidDeclaration;
        return .{ .owner = key.owner, .source = owner, .node = key.node };
    }

    fn internDeclaration(self: *Registry, owner: OwnerId, node: hir.NodeId, added: ?*std.ArrayListUnmanaged(u32)) Error!hir.NodeId {
        self.mutex.lock();
        defer self.mutex.unlock();
        const view = try self.sourceLocked(owner);
        if (node == 0 or isDeclarationHandle(node) or node >= view.hir.nodeCount()) return error.InvalidDeclaration;
        const location = view.hir.spanOf(node);
        if (location.start > location.end or location.end > view.text.len) return error.InvalidDeclaration;
        const key: NodeKey = .{ .owner = owner, .node = node };
        const table = self.handles.items[@backingInt(owner) - 1];
        if (self.node_ids.get(key)) |id| {
            table[node].store(id, .release);
            return id;
        }
        if (self.nodes.items.len == declaration_handle_index_mask) return error.TypeIdOverflow;
        try self.nodes.ensureUnusedCapacity(self.allocator, 1);
        try self.node_ids.ensureUnusedCapacity(self.allocator, 1);
        if (added) |list| try list.ensureUnusedCapacity(self.allocator, 1);
        if (added) |list| list.appendAssumeCapacity(@intCast(self.nodes.items.len));
        self.nodes.appendAssumeCapacity(key);
        const id: hir.NodeId = declaration_handle_tag | @as(hir.NodeId, @intCast(self.nodes.items.len));
        self.node_ids.putAssumeCapacityNoClobber(key, id);
        table[node].store(id, .release);
        return id;
    }

    /// Withdraw the declarations one failed import added (`added` holds
    /// their indices in `nodes`). When nothing was appended after them the
    /// records are dropped; otherwise a concurrent import owns later handles,
    /// so the withdrawn slots stay as unreachable tombstones.
    fn cancelDeclarations(self: *Registry, added: []const u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (added) |index| {
            const key = self.nodes.items[index];
            const removed = self.node_ids.remove(key);
            std.debug.assert(removed);
            self.handles.items[@backingInt(key.owner) - 1][key.node].store(0, .release);
            self.nodes.items[index] = .{ .owner = .none, .node = 0 };
        }
        while (self.nodes.items.len > 0 and self.nodes.items[self.nodes.items.len - 1].owner == .none) {
            self.nodes.items.len -= 1;
        }
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
        const view, const handles = try self.sourceAndHandles(owner);
        var added: std.ArrayListUnmanaged(u32) = .empty;
        defer added.deinit(self.allocator);
        errdefer self.cancelDeclarations(added.items);
        var context = Context{ .registry = self, .owner = owner, .from = view.strings, .to = target_strings, .added = &added, .handles = handles };
        const imported = try checker.checked_transfer.append(target, view.types, view.checked, .{
            .context = &context,
            .string = Context.string,
            .declaration = Context.node,
            .owner = @backingInt(owner),
        });
        return .{ .owner = owner, .types = imported };
    }

    /// Map `id` of `owner`'s pool into `target` without importing the owner,
    /// for a target that already holds every identity `id` reaches (it
    /// imported an owner whose pool covers this one). Null means import it.
    pub fn projectType(
        self: *Registry,
        target: *checker.Interner,
        target_strings: *strings.Interner,
        owner: OwnerId,
        id: checker.TypeId,
    ) Error!?checker.TypeId {
        const view, const handles = try self.sourceAndHandles(owner);
        var added: std.ArrayListUnmanaged(u32) = .empty;
        defer added.deinit(self.allocator);
        var context = Context{ .registry = self, .owner = owner, .from = view.strings, .to = target_strings, .added = &added, .handles = handles };
        return checker.type_transfer.project(target, view.types, .{
            .context = &context,
            .string = Context.string,
            .declaration = Context.node,
            .owner = @backingInt(owner),
        }, id);
    }
};

const Context = struct {
    registry: *Registry,
    owner: OwnerId,
    from: *const strings.Interner,
    to: *strings.Interner,
    /// Declarations this import created, withdrawn if it fails.
    added: *std.ArrayListUnmanaged(u32),
    /// The owner's published handles (`Registry.handles`), read lock-free.
    handles: []std.atomic.Value(hir.NodeId),

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
        if (!isDeclarationHandle(id) and id != 0 and id < self.handles.len) {
            const published = self.handles[id].load(.acquire);
            if (published != 0) return published;
        }
        // Handles come from this registry; checking them costs a lock per
        // transferred declaration, so only safety builds re-validate.
        if (isDeclarationHandle(id) and !std.debug.runtime_safety) return id;
        if (isDeclarationHandle(id)) {
            _ = self.registry.declaration(id) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.TypeIdOverflow => error.TypeIdOverflow,
                else => error.UnmappedName,
            };
            return id;
        }
        return self.registry.internDeclaration(self.owner, id, self.added) catch |err| switch (err) {
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
    const old = try registry.internDeclaration(first_owner, first.decl, null);
    try T.expect(isDeclarationHandle(old));
    try T.expectError(error.InvalidDeclaration, registry.declaration(first.decl));
    try T.expectEqual(old, try registry.internDeclaration(first_owner, first.decl, null));
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
    const current = try registry.internDeclaration(second_owner, second.decl, null);
    try T.expect(isDeclarationHandle(current));
    try T.expect(first_owner != second_owner and old != current);
    var added: std.ArrayListUnmanaged(u32) = .empty;
    defer added.deinit(T.allocator);
    var context = Context{ .registry = &registry, .owner = second_owner, .from = &second.names, .to = &second.names, .added = &added, .handles = registry.handles.items[@backingInt(second_owner) - 1] };
    try T.expectEqual(current, try Context.node(&context, current));
    try T.expectError(error.UnmappedName, Context.node(&context, old));
    try T.expectEqualStrings("/same.ts", (try registry.declaration(current)).source.path);
    try T.expectEqual(hir.NodeKind.interface_decl, (try registry.declaration(current)).source.hir.kindOf(second.decl));
    try T.expectError(error.InvalidOwner, registry.declaration(old));
    try T.expectError(error.InvalidDeclaration, registry.declaration(0));
    try T.expectError(error.InvalidDeclaration, registry.declaration(current + 1));
    try T.expectError(error.InvalidDeclaration, registry.internDeclaration(second_owner, second.tree.nodeCount(), null));
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
    const existing_handle = try registry.internDeclaration(existing_owner, fixture.decl, null);
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
