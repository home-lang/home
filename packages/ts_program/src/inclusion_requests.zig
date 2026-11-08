//! Owned inclusion requests, independent of source-file existence. Captured
//! filename policy groups paths; request identity retains every authored site.
const std = @import("std");
const ts_resolver = @import("ts_resolver");
pub const FileId = u32;

pub const IncludeKind = enum {
    root,
    import,
    reference_file,
    type_reference,
    lib_reference,
    imported_helper,
    jsx_runtime_import,
    compiler_type_reference,
    implicit_type_reference,
    compiler_lib_reference,
    default_lib_reference,
};

pub const IncludeReason = struct {
    kind: IncludeKind = .root,
    /// For non-root reasons: the file id that pulled this one in (the
    /// importer, or the file containing the triple-slash directive).
    importer: FileId = 0,
    /// The reference text as written: for `.import` the module specifier
    /// quoted to match tsgo's `referenceLocation.text()`; for
    /// triple-slash references the bare target text. Owned by the program.
    specifier_text: []const u8 = "",
    /// tsc package identity for node_modules imports/type-reference
    /// directives when the resolver found one. Owned by the program when
    /// non-empty.
    package_id: []const u8 = "",
    /// Emitted declaration output path that redirected to this source file
    /// through project-reference resolution. Owned by the program when non-empty.
    project_reference_output: []const u8 = "",
    /// Byte offset of the import/reference specifier in the importer.
    /// Used for related-information anchors.
    specifier_pos: u32 = 0,

    pub fn relatedDiagnosticCode(self: IncludeReason) ?u32 {
        const code_file_included_via_import_here: u32 = 1399;
        const code_file_included_via_reference_here: u32 = 1401;
        const code_file_included_via_type_reference_here: u32 = 1404;
        const code_file_included_via_lib_reference_here: u32 = 1406;
        const code_file_is_entry_point_of_type_library_specified_here: u32 = 1419;
        const code_file_is_library_specified_here: u32 = 1423;
        const code_file_is_default_library_for_target_specified_here: u32 = 1426;
        return switch (self.kind) {
            .import => code_file_included_via_import_here,
            .reference_file => code_file_included_via_reference_here,
            .type_reference => code_file_included_via_type_reference_here,
            .lib_reference => code_file_included_via_lib_reference_here,
            .compiler_type_reference => code_file_is_entry_point_of_type_library_specified_here,
            .compiler_lib_reference => code_file_is_library_specified_here,
            .default_lib_reference => code_file_is_default_library_for_target_specified_here,
            .root, .imported_helper, .jsx_runtime_import, .implicit_type_reference => null,
        };
    }

    pub fn relatedDiagnosticMessage(self: IncludeReason) ?[]const u8 {
        return switch (self.kind) {
            .import => "File is included via import here.",
            .reference_file => "File is included via reference here.",
            .type_reference => "File is included via type library reference here.",
            .lib_reference => "File is included via library reference here.",
            .compiler_type_reference => "File is entry point of type library specified here.",
            .compiler_lib_reference => "File is library specified here.",
            .default_lib_reference => "File is default library for target specified here.",
            .root, .imported_helper, .jsx_runtime_import, .implicit_type_reference => null,
        };
    }

    pub fn specifierSpanLen(self: IncludeReason) u32 {
        return @intCast(@min(self.specifier_text.len, std.math.maxInt(u32)));
    }

    pub fn ownedClone(self: IncludeReason, gpa: std.mem.Allocator) !IncludeReason {
        var result = self;
        result.specifier_text = try gpa.dupe(u8, self.specifier_text);
        errdefer gpa.free(result.specifier_text);
        result.package_id = try gpa.dupe(u8, self.package_id);
        errdefer gpa.free(result.package_id);
        result.project_reference_output = try gpa.dupe(u8, self.project_reference_output);
        return result;
    }

    pub fn releaseOwned(self: IncludeReason, gpa: std.mem.Allocator) void {
        gpa.free(self.specifier_text);
        gpa.free(self.package_id);
        gpa.free(self.project_reference_output);
    }
};

pub const RootOrigin = struct {
    kind: enum { command_line, files, include, inferred },
    input_index: usize,
    spec_index: ?usize = null,
};

pub const Entry = struct {
    file_name: []const u8,
    reason: IncludeReason,
    target_id: ?FileId = null,
    load_state: enum { pending, attempted } = .attempted,
    root_origins: []const RootOrigin = &.{},

    fn ownedClone(self: Entry, gpa: std.mem.Allocator) !Entry {
        var result = self;
        result.file_name = try gpa.dupe(u8, self.file_name);
        errdefer gpa.free(result.file_name);
        result.reason = try self.reason.ownedClone(gpa);
        errdefer result.reason.releaseOwned(gpa);
        result.root_origins = try gpa.dupe(RootOrigin, self.root_origins);
        return result;
    }

    fn releaseOwned(self: Entry, gpa: std.mem.Allocator) void {
        gpa.free(self.file_name);
        self.reason.releaseOwned(gpa);
        gpa.free(self.root_origins);
    }
};

pub const Category = enum { root, compiler, injected, reference };

fn categoryFor(kind: IncludeKind) Category {
    return switch (kind) {
        .root => .root,
        .compiler_type_reference, .implicit_type_reference, .compiler_lib_reference, .default_lib_reference => .compiler,
        .imported_helper, .jsx_runtime_import => .injected,
        .import, .reference_file, .type_reference, .lib_reference => .reference,
    };
}

pub const Id = struct { category: Category, index: usize, generation: u64 };

const Key = struct {
    entry: Entry,

    const Context = struct {
        fn stringHash(hasher: *std.hash.Wyhash, value: []const u8) void {
            std.hash.autoHash(hasher, value.len);
            hasher.update(value);
        }

        pub fn hash(_: @This(), key: Key) u64 {
            const entry = key.entry;
            var hasher = std.hash.Wyhash.init(0);
            stringHash(&hasher, entry.file_name);
            std.hash.autoHash(&hasher, entry.reason.kind);
            std.hash.autoHash(&hasher, entry.reason.importer);
            std.hash.autoHash(&hasher, entry.reason.specifier_pos);
            stringHash(&hasher, entry.reason.specifier_text);
            stringHash(&hasher, entry.reason.package_id);
            stringHash(&hasher, entry.reason.project_reference_output);
            std.hash.autoHash(&hasher, entry.root_origins.len);
            for (entry.root_origins) |origin| std.hash.autoHash(&hasher, origin);
            return hasher.final();
        }

        pub fn eql(_: @This(), first: Key, second: Key) bool {
            const a = first.entry;
            const b = second.entry;
            if (!std.mem.eql(u8, a.file_name, b.file_name) or
                a.reason.kind != b.reason.kind or a.reason.importer != b.reason.importer or
                a.reason.specifier_pos != b.reason.specifier_pos or
                !std.mem.eql(u8, a.reason.specifier_text, b.reason.specifier_text) or
                !std.mem.eql(u8, a.reason.package_id, b.reason.package_id) or
                !std.mem.eql(u8, a.reason.project_reference_output, b.reason.project_reference_output) or
                a.root_origins.len != b.root_origins.len) return false;
            for (a.root_origins, b.root_origins) |left, right| {
                if (!std.meta.eql(left, right)) return false;
            }
            return true;
        }
    };
};

/// Appending preserves IDs and owned strings. Clearing a category invalidates
/// its IDs and any views. The allocator remains supplied by Program so injected
/// allocation failures cannot bypass its active allocator.
pub const Registry = struct {
    context: ts_resolver.FileNameContext,
    entries: [4]std.ArrayListUnmanaged(Entry) = .{ .empty, .empty, .empty, .empty },
    generations: [4]u64 = .{ 0, 0, 0, 0 },
    by_request: std.HashMapUnmanaged(Key, Id, Key.Context, 80) = .empty,

    pub fn init(context: ts_resolver.FileNameContext) Registry {
        return .{ .context = context };
    }

    pub fn deinit(self: *Registry, gpa: std.mem.Allocator) void {
        self.by_request.deinit(gpa);
        for (&self.entries) |*list| {
            for (list.items) |entry| entry.releaseOwned(gpa);
            list.deinit(gpa);
        }
        self.* = undefined;
    }

    pub fn count(self: *const Registry) usize {
        var total: usize = 0;
        for (self.entries) |list| total += list.items.len;
        return total;
    }

    pub fn get(self: *const Registry, id: Id) ?*const Entry {
        const category = @backingInt(id.category);
        if (self.generations[category] != id.generation or id.index >= self.entries[category].items.len) return null;
        return &self.entries[category].items[id.index];
    }

    pub fn record(self: *Registry, gpa: std.mem.Allocator, input: Entry) !Id {
        if (self.by_request.get(.{ .entry = input })) |id| {
            const entry = &self.entries[@backingInt(id.category)].items[id.index];
            if (input.target_id) |target| entry.target_id = target;
            if (input.load_state == .attempted) entry.load_state = .attempted;
            return id;
        }
        const owned = try input.ownedClone(gpa);
        errdefer owned.releaseOwned(gpa);
        const category = categoryFor(input.reason.kind);
        const index = @backingInt(category);
        const list = &self.entries[index];
        try list.ensureUnusedCapacity(gpa, 1);
        try self.by_request.ensureUnusedCapacity(gpa, 1);
        const id: Id = .{ .category = category, .index = list.items.len, .generation = self.generations[index] };
        list.appendAssumeCapacity(owned);
        self.by_request.putAssumeCapacityNoClobber(.{ .entry = owned }, id);
        return id;
    }

    pub fn bind(self: *Registry, id: Id, target: ?FileId) void {
        std.debug.assert(self.get(id) != null);
        const entry = &self.entries[@backingInt(id.category)].items[id.index];
        entry.target_id = target;
        entry.load_state = .attempted;
    }

    pub fn clear(self: *Registry, gpa: std.mem.Allocator, category: Category) void {
        const index = @backingInt(category);
        const list = &self.entries[index];
        for (list.items) |entry| {
            std.debug.assert(self.by_request.remove(.{ .entry = entry }));
            entry.releaseOwned(gpa);
        }
        list.clearRetainingCapacity();
        self.generations[index] +%= 1;
    }

    pub fn view(self: *const Registry, gpa: std.mem.Allocator) !View {
        return View.init(gpa, self);
    }
};

/// Derived indexes borrow an immutable registry and own only their arena.
/// Build once per reporting/collection pass instead of rescanning every
/// request for every source file. Drop the view before mutating the registry.
pub const View = struct {
    arena: std.heap.ArenaAllocator,
    registry: *const Registry,
    by_target: std.AutoHashMapUnmanaged(FileId, std.ArrayListUnmanaged(Id)) = .empty,
    by_importer: std.AutoHashMapUnmanaged(FileId, std.ArrayListUnmanaged(Id)) = .empty,
    by_path: std.HashMapUnmanaged([]const u8, std.ArrayListUnmanaged(Id), ts_resolver.FileNameContext, 80) = .empty,

    fn init(gpa: std.mem.Allocator, registry: *const Registry) !View {
        var result: View = .{ .arena = std.heap.ArenaAllocator.init(gpa), .registry = registry };
        errdefer result.arena.deinit();
        const allocator = result.arena.allocator();
        for (registry.entries, 0..) |list, category| {
            for (list.items, 0..) |entry, index| {
                const id: Id = .{ .category = @fromBackingInt(@intCast(category)), .index = index, .generation = registry.generations[category] };
                const path = try result.by_path.getOrPutContext(allocator, entry.file_name, registry.context);
                if (!path.found_existing) path.value_ptr.* = .empty;
                try path.value_ptr.append(allocator, id);
                if (entry.target_id) |target| {
                    const slot = try result.by_target.getOrPut(allocator, target);
                    if (!slot.found_existing) slot.value_ptr.* = .empty;
                    try slot.value_ptr.append(allocator, id);
                }
                switch (entry.reason.kind) {
                    .import, .reference_file, .type_reference, .lib_reference, .imported_helper, .jsx_runtime_import => {
                        const slot = try result.by_importer.getOrPut(allocator, entry.reason.importer);
                        if (!slot.found_existing) slot.value_ptr.* = .empty;
                        try slot.value_ptr.append(allocator, id);
                    },
                    else => {},
                }
            }
        }
        return result;
    }

    pub fn deinit(self: *View) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn forTarget(self: *const View, target: FileId) []const Id {
        return if (self.by_target.get(target)) |list| list.items else &.{};
    }

    pub fn forImporter(self: *const View, importer: FileId) []const Id {
        return if (self.by_importer.get(importer)) |list| list.items else &.{};
    }

    pub fn forPath(self: *const View, path: []const u8) []const Id {
        return if (self.by_path.getContext(path, self.registry.context)) |list| list.items else &.{};
    }
};

test "inclusion requests retain sites, missing roots, and host path identity" {
    const t = std.testing;
    for ([_]bool{ true, false }) |sensitive| {
        var registry = Registry.init(.{ .case_sensitive = sensitive });
        defer registry.deinit(t.allocator);
        const missing = try registry.record(t.allocator, .{
            .file_name = "/app/Missing.ts",
            .reason = .{ .kind = .root },
            .load_state = .pending,
            .root_origins = &.{.{ .kind = .files, .input_index = 7, .spec_index = 2 }},
        });
        const first = try registry.record(t.allocator, .{
            .file_name = "/app/Shared.ts",
            .target_id = 9,
            .reason = .{ .kind = .import, .importer = 1, .specifier_text = "'./Shared'", .specifier_pos = 12 },
        });
        const repeated = try registry.record(t.allocator, registry.get(first).?.*);
        try t.expectEqual(first, repeated);
        _ = try registry.record(t.allocator, .{
            .file_name = "/app/shared.ts",
            .target_id = 9,
            .reason = .{ .kind = .import, .importer = 1, .specifier_text = "'./shared'", .specifier_pos = 40 },
        });
        _ = try registry.record(t.allocator, .{
            .file_name = "/app/Shared.ts",
            .target_id = 9,
            .reason = .{ .kind = .reference_file, .importer = 2, .specifier_text = "./Shared.ts", .specifier_pos = 22 },
        });
        var view = try registry.view(t.allocator);
        defer view.deinit();
        try t.expectEqual(@as(usize, 4), registry.count());
        try t.expectEqual(@as(usize, 3), view.forTarget(9).len);
        try t.expectEqual(@as(usize, 2), view.forImporter(1).len);
        try t.expectEqual(@as(usize, if (sensitive) 2 else 3), view.forPath("/app/Shared.ts").len);
        try t.expectEqual(missing, view.forPath("/app/Missing.ts")[0]);
        try t.expectEqual(@as(?FileId, null), registry.get(missing).?.target_id);
        try t.expectEqual(@as(usize, 7), registry.get(missing).?.root_origins[0].input_index);
    }
}

test "inclusion request refresh invalidates only the cleared category" {
    const t = std.testing;
    var registry = Registry.init(.{ .case_sensitive = true });
    defer registry.deinit(t.allocator);
    const root = try registry.record(t.allocator, .{ .file_name = "/root.ts", .reason = .{} });
    const compiler = try registry.record(t.allocator, .{ .file_name = "/lib.d.ts", .reason = .{ .kind = .default_lib_reference } });
    const old = try registry.record(t.allocator, .{ .file_name = "/old.ts", .reason = .{ .kind = .import, .importer = 1 } });
    registry.clear(t.allocator, .reference);
    const current = try registry.record(t.allocator, .{ .file_name = "/current.ts", .reason = .{ .kind = .import, .importer = 1 } });
    try t.expect(registry.get(old) == null);
    try t.expect(registry.get(current) != null);
    try t.expect(registry.get(root) != null);
    try t.expect(registry.get(compiler) != null);
    registry.bind(root, 0);
    try t.expectEqual(@as(?FileId, 0), registry.get(root).?.target_id);
    var view = try registry.view(t.allocator);
    defer view.deinit();
    try t.expectEqual(@as(usize, 0), view.forPath("/old.ts").len);
}

fn allocationFailureExercise(gpa: std.mem.Allocator) !void {
    const t = std.testing;
    var registry = Registry.init(.{ .case_sensitive = false });
    defer registry.deinit(gpa);
    const root = try registry.record(gpa, .{ .file_name = "/root.ts", .reason = .{} });
    const before = registry.count();
    const request: Entry = .{
        .file_name = "/shared.ts",
        .target_id = 2,
        .reason = .{ .kind = .import, .importer = 0, .specifier_text = "'./shared'", .package_id = "pkg@1", .project_reference_output = "/dist/shared.d.ts" },
        .root_origins = &.{.{ .kind = .files, .input_index = 3 }},
    };
    _ = registry.record(gpa, request) catch |err| {
        try t.expectEqual(before, registry.count());
        try t.expectEqualStrings("/root.ts", registry.get(root).?.file_name);
        return err;
    };
    var view = try registry.view(gpa);
    defer view.deinit();
    try t.expectEqual(@as(usize, 1), view.forTarget(2).len);
    const owned = registry.get(view.forTarget(2)[0]).?;
    try t.expect(owned.file_name.ptr != request.file_name.ptr);
    try t.expect(owned.reason.specifier_text.ptr != request.reason.specifier_text.ptr);
    try t.expect(owned.reason.package_id.ptr != request.reason.package_id.ptr);
    try t.expect(owned.reason.project_reference_output.ptr != request.reason.project_reference_output.ptr);
    try t.expect(owned.root_origins.ptr != request.root_origins.ptr);
}

test "inclusion request publication and view construction survive every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureExercise, .{});
}
