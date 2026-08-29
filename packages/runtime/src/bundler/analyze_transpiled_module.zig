pub const RecordKind = enum(u8) {
    /// var_name
    declared_variable,
    /// let_name
    lexical_variable,
    /// module_name, import_name, local_name
    import_info_single,
    /// module_name, import_name, local_name
    import_info_single_type_script,
    /// module_name, import_name = '*', local_name
    import_info_namespace,
    /// export_name, import_name, module_name
    export_info_indirect,
    /// export_name, local_name, padding (for local => indirect conversion)
    export_info_local,
    /// export_name, module_name
    export_info_namespace,
    /// module_name
    export_info_star,
    /// module_name, import_name = '*', local_name (deferred phase)
    import_info_namespace_defer,
    _,

    pub fn len(record: RecordKind) !usize {
        return switch (record) {
            .declared_variable, .lexical_variable => 1,
            .import_info_single => 3,
            .import_info_single_type_script => 3,
            .import_info_namespace => 3,
            .import_info_namespace_defer => 3,
            .export_info_indirect => 3,
            .export_info_local => 3,
            .export_info_namespace => 2,
            .export_info_star => 1,
            else => return error.InvalidRecordKind,
        };
    }
};

/// JSC's module-request phase. The serialized representation is one byte per
/// requested module, parallel to the request keys and fetch parameters.
pub const ModulePhase = enum(u8) {
    evaluation = 0,
    deferred = 1,
};

pub const Flags = packed struct(u8) {
    contains_import_meta: bool = false,
    is_typescript: bool = false,
    has_tla: bool = false,
    _padding: u5 = 0,
};

pub const ModuleInfoDeserialized = struct {
    strings_buf: []const u8,
    strings_lens: []align(1) const u32,
    requested_modules_keys: []align(1) const StringID,
    requested_modules_values: []align(1) const ModuleInfo.FetchParameters,
    requested_modules_phases: []const u8,
    buffer: []align(1) const StringID,
    record_kinds: []align(1) const RecordKind,
    flags: Flags,
    owner: union(enum) {
        module_info,
        allocated_slice: struct {
            slice: []const u8,
            allocator: std.mem.Allocator,
        },
    },
    pub fn deinit(self: *ModuleInfoDeserialized) void {
        switch (self.owner) {
            .module_info => {
                const mi: *ModuleInfo = @fieldParentPtr("_deserialized", self);
                mi.destroy();
            },
            .allocated_slice => |as| {
                as.allocator.free(as.slice);
                as.allocator.destroy(self);
            },
        }
    }

    inline fn eat(rem: *[]const u8, len: usize) ![]const u8 {
        if (rem.*.len < len) return error.BadModuleInfo;
        const res = rem.*[0..len];
        rem.* = rem.*[len..];
        return res;
    }
    inline fn eatC(rem: *[]const u8, comptime len: usize) !*const [len]u8 {
        if (rem.*.len < len) return error.BadModuleInfo;
        const res = rem.*[0..len];
        rem.* = rem.*[len..];
        return res;
    }
    pub fn create(source: []const u8, gpa: std.mem.Allocator) !*ModuleInfoDeserialized {
        const duped = try gpa.dupe(u8, source);
        errdefer gpa.free(duped);
        var rem: []const u8 = duped;
        const res = try gpa.create(ModuleInfoDeserialized);
        errdefer gpa.destroy(res);

        const record_kinds_len = std.mem.readInt(u32, try eatC(&rem, 4), .little);
        const record_kinds = std.mem.bytesAsSlice(RecordKind, try eat(&rem, record_kinds_len * @sizeOf(RecordKind)));
        _ = try eat(&rem, (4 - (record_kinds_len % 4)) % 4); // alignment padding

        const buffer_len = std.mem.readInt(u32, try eatC(&rem, 4), .little);
        const buffer = std.mem.bytesAsSlice(StringID, try eat(&rem, buffer_len * @sizeOf(StringID)));

        const requested_modules_len = std.mem.readInt(u32, try eatC(&rem, 4), .little);
        const requested_modules_keys = std.mem.bytesAsSlice(StringID, try eat(&rem, requested_modules_len * @sizeOf(StringID)));
        const requested_modules_values = std.mem.bytesAsSlice(ModuleInfo.FetchParameters, try eat(&rem, requested_modules_len * @sizeOf(ModuleInfo.FetchParameters)));
        const requested_modules_phases = try eat(&rem, requested_modules_len);
        for (requested_modules_phases) |phase| {
            if (phase > @intFromEnum(ModulePhase.deferred)) return error.BadModuleInfo;
        }
        _ = try eat(&rem, (4 - (requested_modules_len % 4)) % 4); // alignment padding

        const flags: Flags = @bitCast((try eatC(&rem, 1))[0]);
        _ = try eat(&rem, 3); // alignment padding

        const strings_len = std.mem.readInt(u32, try eatC(&rem, 4), .little);
        const strings_lens = std.mem.bytesAsSlice(u32, try eat(&rem, strings_len * @sizeOf(u32)));
        const strings_buf = rem;

        res.* = .{
            .strings_buf = strings_buf,
            .strings_lens = strings_lens,
            .requested_modules_keys = requested_modules_keys,
            .requested_modules_values = requested_modules_values,
            .requested_modules_phases = requested_modules_phases,
            .buffer = buffer,
            .record_kinds = record_kinds,
            .flags = flags,
            .owner = .{ .allocated_slice = .{
                .slice = duped,
                .allocator = gpa,
            } },
        };
        return res;
    }

    /// Wrapper around `create` for use when loading from a cache (transpiler cache or standalone module graph).
    /// Returns `null` instead of panicking on corrupt/truncated data.
    pub fn createFromCachedRecord(source: []const u8, gpa: std.mem.Allocator) ?*ModuleInfoDeserialized {
        return create(source, gpa) catch |e| switch (e) {
            error.OutOfMemory => bun.outOfMemory(),
            error.BadModuleInfo => null,
        };
    }

    pub fn serialize(self: *const ModuleInfoDeserialized, writer: anytype) !void {
        try writer.writeInt(u32, @truncate(self.record_kinds.len), .little);
        try writer.writeAll(std.mem.sliceAsBytes(self.record_kinds));
        try writeZeroes(writer, (4 - (self.record_kinds.len % 4)) % 4); // alignment padding

        try writer.writeInt(u32, @truncate(self.buffer.len), .little);
        try writer.writeAll(std.mem.sliceAsBytes(self.buffer));

        try writer.writeInt(u32, @truncate(self.requested_modules_keys.len), .little);
        try writer.writeAll(std.mem.sliceAsBytes(self.requested_modules_keys));
        try writer.writeAll(std.mem.sliceAsBytes(self.requested_modules_values));
        bun.assert(self.requested_modules_phases.len == self.requested_modules_keys.len);
        try writer.writeAll(self.requested_modules_phases);
        try writeZeroes(writer, (4 - (self.requested_modules_phases.len % 4)) % 4); // alignment padding

        try writer.writeByte(@bitCast(self.flags));
        try writeZeroes(writer, 3); // alignment padding

        try writer.writeInt(u32, @truncate(self.strings_lens.len), .little);
        try writer.writeAll(std.mem.sliceAsBytes(self.strings_lens));
        try writer.writeAll(self.strings_buf);
    }
};

fn writeZeroes(writer: anytype, count: usize) !void {
    var remaining = count;
    while (remaining > 0) : (remaining -= 1) {
        try writer.writeByte(0);
    }
}

const StringMapKey = enum(u32) {
    _,
};
pub const StringContext = struct {
    strings_buf: []const u8,
    strings_lens: []const u32,

    pub fn hash(_: @This(), s: []const u8) u32 {
        return @as(u32, @truncate(std.hash.Wyhash.hash(0, s)));
    }
    pub fn eql(self: @This(), fetch_key: []const u8, item_key: StringMapKey, item_i: usize) bool {
        return bun.strings.eqlLong(fetch_key, self.strings_buf[@intFromEnum(item_key)..][0..self.strings_lens[item_i]], true);
    }
};

pub const ModuleInfo = struct {
    const RequestedModuleKey = struct {
        path: StringID,
        phase: ModulePhase,
    };

    /// all strings in wtf-8. index in hashmap = StringID
    gpa: std.mem.Allocator,
    strings_map: std.ArrayHashMapUnmanaged(StringMapKey, void, void, true),
    strings_buf: std.ArrayListUnmanaged(u8),
    strings_lens: std.ArrayListUnmanaged(u32),
    /// JSC deduplicates requests by `(specifier, phase)`, so eager and deferred
    /// requests for the same specifier must remain distinct.
    requested_modules: std.ArrayHashMapUnmanaged(RequestedModuleKey, FetchParameters, std.array_hash_map.AutoContext(RequestedModuleKey), true),
    requested_module_paths: std.ArrayListUnmanaged(StringID),
    requested_module_phases: std.ArrayListUnmanaged(u8),
    buffer: std.ArrayListUnmanaged(StringID),
    record_kinds: std.ArrayListUnmanaged(RecordKind),
    flags: Flags,
    exported_names: std.ArrayHashMapUnmanaged(StringID, void, std.array_hash_map.AutoContext(StringID), true),
    finalized: bool = false,

    /// only initialized after .finalize() is called
    _deserialized: ModuleInfoDeserialized,

    pub fn asDeserialized(self: *ModuleInfo) *ModuleInfoDeserialized {
        bun.assert(self.finalized);
        return &self._deserialized;
    }

    pub const FetchParameters = enum(u32) {
        none = std.math.maxInt(u32),
        javascript = std.math.maxInt(u32) - 1,
        webassembly = std.math.maxInt(u32) - 2,
        json = std.math.maxInt(u32) - 3,
        _, // host_defined: cast to StringID
        pub fn hostDefined(value: StringID) FetchParameters {
            return @enumFromInt(@intFromEnum(value));
        }
    };

    pub const VarKind = enum { declared, lexical };
    pub fn addVar(self: *ModuleInfo, name: StringID, kind: VarKind) !void {
        switch (kind) {
            .declared => try self.addDeclaredVariable(name),
            .lexical => try self.addLexicalVariable(name),
        }
    }

    fn _addRecord(self: *ModuleInfo, kind: RecordKind, data: []const StringID) !void {
        bun.assert(!self.finalized);
        bun.assert(data.len == kind.len() catch unreachable);
        try self.record_kinds.append(self.gpa, kind);
        try self.buffer.appendSlice(self.gpa, data);
    }
    pub fn addDeclaredVariable(self: *ModuleInfo, id: StringID) !void {
        try self._addRecord(.declared_variable, &.{id});
    }
    pub fn addLexicalVariable(self: *ModuleInfo, id: StringID) !void {
        try self._addRecord(.lexical_variable, &.{id});
    }
    pub fn addImportInfoSingle(self: *ModuleInfo, module_name: StringID, import_name: StringID, local_name: StringID, only_used_as_type: bool) !void {
        try self._addRecord(if (only_used_as_type) .import_info_single_type_script else .import_info_single, &.{ module_name, import_name, local_name });
    }
    pub fn addImportInfoNamespace(self: *ModuleInfo, module_name: StringID, local_name: StringID) !void {
        try self._addRecord(.import_info_namespace, &.{ module_name, .star_namespace, local_name });
    }
    pub fn addImportInfoNamespaceDefer(self: *ModuleInfo, module_name: StringID, local_name: StringID) !void {
        try self._addRecord(.import_info_namespace_defer, &.{ module_name, .star_namespace, local_name });
    }
    pub fn addExportInfoIndirect(self: *ModuleInfo, export_name: StringID, import_name: StringID, module_name: StringID) !void {
        if (try self._hasOrAddExportedName(export_name)) return; // a syntax error will be emitted later in this case
        try self._addRecord(.export_info_indirect, &.{ export_name, import_name, module_name });
    }
    pub fn addExportInfoLocal(self: *ModuleInfo, export_name: StringID, local_name: StringID) !void {
        if (try self._hasOrAddExportedName(export_name)) return; // a syntax error will be emitted later in this case
        try self._addRecord(.export_info_local, &.{ export_name, local_name, @enumFromInt(std.math.maxInt(u32)) });
    }
    pub fn addExportInfoNamespace(self: *ModuleInfo, export_name: StringID, module_name: StringID) !void {
        if (try self._hasOrAddExportedName(export_name)) return; // a syntax error will be emitted later in this case
        try self._addRecord(.export_info_namespace, &.{ export_name, module_name });
    }
    pub fn addExportInfoStar(self: *ModuleInfo, module_name: StringID) !void {
        try self._addRecord(.export_info_star, &.{module_name});
    }

    pub fn _hasOrAddExportedName(self: *ModuleInfo, name: StringID) !bool {
        if (try self.exported_names.fetchPut(self.gpa, name, {}) != null) return true;
        return false;
    }

    pub fn create(gpa: std.mem.Allocator, is_typescript: bool) !*ModuleInfo {
        const res = try gpa.create(ModuleInfo);
        res.* = ModuleInfo.init(gpa, is_typescript);
        return res;
    }
    fn init(allocator: std.mem.Allocator, is_typescript: bool) ModuleInfo {
        return .{
            .gpa = allocator,
            .strings_map = .empty,
            .strings_buf = .empty,
            .strings_lens = .empty,
            .exported_names = .empty,
            .requested_modules = .empty,
            .requested_module_paths = .empty,
            .requested_module_phases = .empty,
            .buffer = .empty,
            .record_kinds = .empty,
            .flags = .{ .contains_import_meta = false, .is_typescript = is_typescript },
            ._deserialized = undefined,
        };
    }
    fn deinit(self: *ModuleInfo) void {
        self.strings_map.deinit(self.gpa);
        self.strings_buf.deinit(self.gpa);
        self.strings_lens.deinit(self.gpa);
        self.exported_names.deinit(self.gpa);
        self.requested_modules.deinit(self.gpa);
        self.requested_module_paths.deinit(self.gpa);
        self.requested_module_phases.deinit(self.gpa);
        self.buffer.deinit(self.gpa);
        self.record_kinds.deinit(self.gpa);
    }
    pub fn destroy(self: *ModuleInfo) void {
        const alloc = self.gpa;
        self.deinit();
        alloc.destroy(self);
    }
    pub fn str(self: *ModuleInfo, value: []const u8) !StringID {
        try self.strings_buf.ensureUnusedCapacity(self.gpa, value.len);
        try self.strings_lens.ensureUnusedCapacity(self.gpa, 1);
        const gpres = try self.strings_map.getOrPutAdapted(self.gpa, value, StringContext{
            .strings_buf = self.strings_buf.items,
            .strings_lens = self.strings_lens.items,
        });
        if (gpres.found_existing) return @enumFromInt(@as(u32, @intCast(gpres.index)));

        gpres.key_ptr.* = @enumFromInt(@as(u32, @truncate(self.strings_buf.items.len)));
        gpres.value_ptr.* = {};
        self.strings_buf.appendSliceAssumeCapacity(value);
        self.strings_lens.appendAssumeCapacity(@as(u32, @truncate(value.len)));
        return @enumFromInt(@as(u32, @intCast(gpres.index)));
    }
    pub fn requestModule(self: *ModuleInfo, import_record_path: StringID, fetch_parameters: FetchParameters) !void {
        return self.requestModuleWithPhase(import_record_path, fetch_parameters, .evaluation);
    }
    pub fn requestModuleWithPhase(self: *ModuleInfo, import_record_path: StringID, fetch_parameters: FetchParameters, phase: ModulePhase) !void {
        // JSC records the attributes of the first request for each
        // `(specifier, phase)` pair.
        const gpres = try self.requested_modules.getOrPut(self.gpa, .{ .path = import_record_path, .phase = phase });
        if (!gpres.found_existing) gpres.value_ptr.* = fetch_parameters;
    }

    /// Replace all occurrences of old_id with new_id in records and requested_modules.
    /// Used to fix up cross-chunk import specifiers after final paths are computed.
    pub fn replaceStringID(self: *ModuleInfo, old_id: StringID, new_id: StringID) void {
        bun.assert(!self.finalized);
        // Replace in record buffer
        for (self.buffer.items) |*item| {
            if (item.* == old_id) item.* = new_id;
        }
        // Replace in requested_modules keys (preserving insertion order)
        var changed = false;
        for (self.requested_modules.keys()) |*key| {
            if (key.path == old_id) {
                key.path = new_id;
                changed = true;
            }
        }
        if (changed) {
            self.requested_modules.reIndex(self.gpa) catch {};
        }
    }

    /// find any exports marked as 'local' that are actually 'indirect' and fix them
    pub fn finalize(self: *ModuleInfo) !void {
        bun.assert(!self.finalized);

        try self.requested_module_paths.ensureTotalCapacity(self.gpa, self.requested_modules.count());
        try self.requested_module_phases.ensureTotalCapacity(self.gpa, self.requested_modules.count());
        for (self.requested_modules.keys()) |key| {
            self.requested_module_paths.appendAssumeCapacity(key.path);
            self.requested_module_phases.appendAssumeCapacity(@intFromEnum(key.phase));
        }

        var local_name_to_module_name: std.array_hash_map.Auto(StringID, struct { module_name: StringID, import_name: StringID, record_kinds_idx: usize, is_namespace: bool }) = .empty;
        defer local_name_to_module_name.deinit(bun.default_allocator);
        {
            var i: usize = 0;
            for (self.record_kinds.items, 0..) |k, idx| {
                if (k == .import_info_single or k == .import_info_single_type_script) {
                    try local_name_to_module_name.put(bun.default_allocator, self.buffer.items[i + 2], .{ .module_name = self.buffer.items[i], .import_name = self.buffer.items[i + 1], .record_kinds_idx = idx, .is_namespace = false });
                } else if (k == .import_info_namespace) {
                    try local_name_to_module_name.put(bun.default_allocator, self.buffer.items[i + 2], .{ .module_name = self.buffer.items[i], .import_name = .star_namespace, .record_kinds_idx = idx, .is_namespace = true });
                }
                i += k.len() catch unreachable;
            }
        }

        {
            var i: usize = 0;
            for (self.record_kinds.items) |*k| {
                if (k.* == .export_info_local) {
                    if (local_name_to_module_name.get(self.buffer.items[i + 1])) |ip| {
                        // `import * as z from M; export { z }` is a Namespace export per
                        // spec; encode it as indirect with import_name = .star_namespace
                        // so the record stays the same length and toJSModuleRecord
                        // dispatches to addNamespaceExport.
                        k.* = .export_info_indirect;
                        self.buffer.items[i + 1] = ip.import_name;
                        self.buffer.items[i + 2] = ip.module_name;
                        // In TypeScript, the re-exported import may target a type-only
                        // export that was elided. Convert the import to SingleTypeScript
                        // so JSC tolerates it being NotFound during linking.
                        if (!ip.is_namespace and self.flags.is_typescript) {
                            self.record_kinds.items[ip.record_kinds_idx] = .import_info_single_type_script;
                        }
                    }
                }
                i += k.len() catch unreachable;
            }
        }

        self._deserialized = .{
            .strings_buf = self.strings_buf.items,
            .strings_lens = self.strings_lens.items,
            .requested_modules_keys = self.requested_module_paths.items,
            .requested_modules_values = self.requested_modules.values(),
            .requested_modules_phases = self.requested_module_phases.items,
            .buffer = self.buffer.items,
            .record_kinds = self.record_kinds.items,
            .flags = self.flags,
            .owner = .module_info,
        };

        self.finalized = true;
    }
};
pub const StringID = enum(u32) {
    star_default = std.math.maxInt(u32),
    star_namespace = std.math.maxInt(u32) - 1,
    _,
};

// zig__renderDiff, zig__ModuleInfoDeserialized__toJSModuleRecord, and the
// JSModuleRecord/IdentifierArray opaques: see src/bundler_jsc/analyze_jsc.zig.
// Only force the JSC module-record bridge exports when JSC is actually linked;
// otherwise their JSC_JSModuleRecord__*/JSC__IdentifierArray__*/
// JSC__VariableEnvironment__* extern deps become undefined symbols in non-JSC
// binaries (e.g. the corpus `home-debug`) that never call them.
comptime {
    if (@import("build_options").enable_jsc) {
        _ = @import("../bundler_jsc/analyze_jsc.zig");
    }
}

export fn zig__ModuleInfo__destroy(info: *ModuleInfo) void {
    info.destroy();
}
export fn zig__ModuleInfoDeserialized__deinit(info: *ModuleInfoDeserialized) void {
    info.deinit();
}

export fn zig_log(msg: [*:0]const u8) void {
    bun.Output.errorWriter().print("{s}\n", .{std.mem.span(msg)}) catch {};
}

test "ModuleInfo preserves deferred module phases through serialization" {
    const allocator = std.testing.allocator;
    const mi = try ModuleInfo.create(allocator, false);
    defer mi.destroy();

    const path = try mi.str("./dep.js");
    const local_name = try mi.str("ns");
    try mi.requestModuleWithPhase(path, .javascript, .evaluation);
    try mi.requestModuleWithPhase(path, .json, .evaluation); // first attributes win per phase
    try mi.requestModuleWithPhase(path, .json, .deferred);
    try mi.addImportInfoNamespaceDefer(path, local_name);
    try mi.addExportInfoLocal(local_name, local_name);
    try mi.finalize();

    const view = mi.asDeserialized();
    try std.testing.expectEqual(@as(usize, 2), view.requested_modules_keys.len);
    try std.testing.expectEqual(path, view.requested_modules_keys[0]);
    try std.testing.expectEqual(path, view.requested_modules_keys[1]);
    try std.testing.expectEqual(ModuleInfo.FetchParameters.javascript, view.requested_modules_values[0]);
    try std.testing.expectEqual(ModuleInfo.FetchParameters.json, view.requested_modules_values[1]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1 }, view.requested_modules_phases);
    try std.testing.expectEqual(@as(usize, 2), view.record_kinds.len);
    try std.testing.expectEqual(RecordKind.import_info_namespace_defer, view.record_kinds[0]);
    try std.testing.expectEqual(RecordKind.export_info_local, view.record_kinds[1]);

    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    try view.serialize(&writer.writer);
    const bytes = try writer.toOwnedSlice();
    defer allocator.free(bytes);

    const restored = try ModuleInfoDeserialized.create(bytes, allocator);
    defer restored.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 0, 1 }, restored.requested_modules_phases);
    try std.testing.expectEqual(view.record_kinds.len, restored.record_kinds.len);
    for (view.record_kinds, restored.record_kinds) |expected, actual| {
        try std.testing.expectEqual(expected, actual);
    }

    const record_padding = (4 - (view.record_kinds.len % 4)) % 4;
    const phase_offset = 4 + view.record_kinds.len + record_padding +
        4 + view.buffer.len * @sizeOf(StringID) +
        4 + view.requested_modules_keys.len * @sizeOf(StringID) +
        view.requested_modules_values.len * @sizeOf(ModuleInfo.FetchParameters);
    bytes[phase_offset + 1] = 2;
    try std.testing.expect(ModuleInfoDeserialized.createFromCachedRecord(bytes, allocator) == null);
}

const bun = @import("bun");
const std = @import("std");
