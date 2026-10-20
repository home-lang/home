const std = @import("std");
const tsc_main = @import("tsc_main");
const ts_program = @import("ts_program");
const ts_resolver = @import("ts_resolver");
const ts_watch = @import("ts_watch");
const ts_driver = @import("ts_driver");

const ProgramResolverAdapter = struct {
    resolver: *ts_resolver.Resolver,
    program: *const ts_program.Program,

    const vtable = ts_driver.ExternalResolver.VTable{ .resolve = resolve };

    fn resolve(ptr: *anyopaque, specifier: []const u8, containing_file: []const u8) ?ts_driver.ExternalResolver.Resolution {
        const self: *ProgramResolverAdapter = @ptrCast(@alignCast(ptr));
        const found = self.resolver.resolve(specifier, containing_file) catch return null;
        const admitted_js = (std.mem.endsWith(u8, found.path, ".js") or
            std.mem.endsWith(u8, found.path, ".jsx") or
            std.mem.endsWith(u8, found.path, ".mjs") or
            std.mem.endsWith(u8, found.path, ".cjs")) and self.program.lookupPath(found.path) != null;
        return .{ .path = found.path, .is_declaration = found.is_declaration or admitted_js };
    }
};

test "watch mode retries a revision after update and compile allocation failures" {
    const gpa = std.testing.allocator;
    const root_source = "import { value } from './dep'; const result: number = value;";
    const initial_dependency = "export const value: number = 1;";
    const revised_dependency = "export const value: string = 'bad';";

    var sources = ts_resolver.VirtualFs.init(gpa);
    defer sources.deinit();
    try sources.addFile("/project/main.ts", root_source);
    try sources.addFile("/project/dep.ts", initial_dependency);
    var resolver = ts_resolver.Resolver.init(gpa, sources.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(gpa, &resolver);
    defer program.deinit();
    const root_id = try program.add("/project/main.ts", root_source);
    const options: @import("ts_driver").CompileOptions = .{ .strict = true, .no_emit = true };
    try std.testing.expectEqual(@as(usize, 1), try program.loadImportClosure(options));
    try program.compileAll(options);

    var stats = ts_watch.VirtualWatchFs.init(gpa);
    defer stats.deinit();
    try stats.add("/project/main.ts", 1, root_source.len);
    try stats.add("/project/dep.ts", 1, initial_dependency.len);
    var watcher = ts_watch.Watcher.init(gpa, stats.fs());
    defer watcher.deinit();
    try tsc_main.trackProgramFiles(&watcher, &program);
    try stats.add("/project/dep.ts", 2, revised_dependency.len);

    {
        var first = try watcher.observe();
        defer first.deinit();
        try std.testing.expectEqual(@as(usize, 1), first.changes.changes.items.len);
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
        program.gpa = failing.allocator();
        defer program.gpa = gpa;
        try std.testing.expectError(error.OutOfMemory, program.updateSource("/project/dep.ts", revised_dependency));
    }
    {
        var second = try watcher.observe();
        defer second.deinit();
        try std.testing.expectEqual(@as(usize, 1), second.changes.changes.items.len);
        _ = (try program.updateSource("/project/dep.ts", revised_dependency)) orelse return error.MissingDependency;
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
        program.gpa = failing.allocator();
        defer program.gpa = gpa;
        const paths = [_][]const u8{second.changes.changes.items[0].path};
        try std.testing.expectError(error.OutOfMemory, program.recompileChanged(&paths, options));
    }
    {
        var third = try watcher.observe();
        defer third.deinit();
        try std.testing.expectEqual(@as(usize, 1), third.changes.changes.items.len);
        _ = (try program.updateSource("/project/dep.ts", revised_dependency)) orelse return error.MissingDependency;
        const paths = [_][]const u8{third.changes.changes.items[0].path};
        try std.testing.expectEqual(@as(u32, 2), try program.recompileChanged(&paths, options));
        try tsc_main.trackProgramFiles(&watcher, &program);
        third.commit(&watcher);
    }
    var settled = try watcher.observe();
    defer settled.deinit();
    try std.testing.expect(settled.changes.isEmpty());
    var saw_type_error = false;
    for (program.fileById(root_id).compilation.?.diagnostics.items) |diagnostic| {
        if (diagnostic.code == 2322) saw_type_error = true;
    }
    try std.testing.expect(saw_type_error);
}

test "watch mode retires an imported source and restores its FileId with unchanged metadata" {
    const gpa = std.testing.allocator;
    const root_source = "import { value } from './dep'; const result: number = value;";
    const dependency_source = "export const value: number = 1;";
    const dependency_path = "/project/dep.ts";

    var sources = ts_resolver.VirtualFs.init(gpa);
    defer sources.deinit();
    try sources.addFile("/project/main.ts", root_source);
    try sources.addFile(dependency_path, dependency_source);
    var resolver = ts_resolver.Resolver.init(gpa, sources.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(gpa, &resolver);
    defer program.deinit();
    var adapter = ProgramResolverAdapter{ .resolver = &resolver, .program = &program };
    const main_id = try program.add("/project/main.ts", root_source);
    const options: ts_driver.CompileOptions = .{
        .strict = true,
        .no_emit = true,
        .external_resolver = .{ .ptr = &adapter, .vtable = &ProgramResolverAdapter.vtable },
    };
    try std.testing.expectEqual(@as(usize, 1), try program.loadImportClosure(options));
    const dependency_id = program.lookupPath(dependency_path) orelse return error.MissingDependency;
    try program.compileAll(options);

    var stats = ts_watch.VirtualWatchFs.init(gpa);
    defer stats.deinit();
    try stats.add("/project/main.ts", 1, root_source.len);
    try stats.add(dependency_path, 1, dependency_source.len);
    var watcher = ts_watch.Watcher.init(gpa, stats.fs());
    defer watcher.deinit();
    try tsc_main.trackProgramFiles(&watcher, &program);

    stats.remove(dependency_path);
    try std.testing.expect(sources.removeFile(dependency_path));
    var removed = try watcher.observe();
    defer removed.deinit();
    try std.testing.expectEqual(@as(usize, 1), removed.changes.changes.items.len);
    try std.testing.expectEqual(ts_watch.ChangeKind.removed, removed.changes.changes.items[0].kind);
    try std.testing.expectEqualStrings(dependency_path, removed.changes.changes.items[0].path);
    resolver.invalidateCaches();
    try std.testing.expectEqual(dependency_id, (try program.removeSource(dependency_path)).?);
    const changed = [_][]const u8{dependency_path};
    _ = try program.recompileChanged(&changed, options);
    removed.commit(&watcher);
    try std.testing.expect(program.lookupPath(dependency_path) == null);
    try std.testing.expect(!program.fileById(dependency_id).present);
    try std.testing.expect(program.fileById(dependency_id).compilation == null);
    var saw_missing_import = false;
    for (program.fileById(main_id).compilation.?.diagnostics.items) |diagnostic| {
        if (diagnostic.code == 2307) saw_missing_import = true;
    }
    try std.testing.expect(saw_missing_import);

    var still_missing = try watcher.observe();
    defer still_missing.deinit();
    try std.testing.expect(still_missing.changes.isEmpty());

    // The replacement has precisely the old mtime and size. A watcher that
    // remembered the pre-removal stat would miss this creation altogether.
    try sources.addFile(dependency_path, dependency_source);
    try stats.add(dependency_path, 1, dependency_source.len);
    var restored = try watcher.observe();
    defer restored.deinit();
    try std.testing.expectEqual(@as(usize, 1), restored.changes.changes.items.len);
    try std.testing.expectEqual(ts_watch.ChangeKind.added, restored.changes.changes.items[0].kind);
    resolver.invalidateCaches();
    try std.testing.expectEqual(dependency_id, (try program.updateSource(dependency_path, dependency_source)).?);
    _ = try program.recompileChanged(&changed, options);
    restored.commit(&watcher);
    try std.testing.expectEqual(dependency_id, program.lookupPath(dependency_path).?);
    try std.testing.expect(program.fileById(dependency_id).compilation != null);
    for (program.fileById(main_id).compilation.?.diagnostics.items) |diagnostic| {
        try std.testing.expect(diagnostic.code != 2307);
    }
    var settled = try watcher.observe();
    defer settled.deinit();
    try std.testing.expect(settled.changes.isEmpty());
}

test "watch mode observes a transitive imported source and recompiles its importer" {
    const gpa = std.testing.allocator;
    const root_source = "import { value } from './dep'; const result: number = value;";
    const old_dependency = "export const value: string = 'old';";
    const new_dependency = "export const value: number = 1;";

    var sources = ts_resolver.VirtualFs.init(gpa);
    defer sources.deinit();
    try sources.addFile("/project/main.ts", root_source);
    try sources.addFile("/project/dep.ts", old_dependency);
    var resolver = ts_resolver.Resolver.init(gpa, sources.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(gpa, &resolver);
    defer program.deinit();
    const root_id = try program.add("/project/main.ts", root_source);
    const options: @import("ts_driver").CompileOptions = .{ .strict = true, .no_emit = true };
    try std.testing.expectEqual(@as(usize, 1), try program.loadImportClosure(options));
    const dep_id = program.lookupPath("/project/dep.ts") orelse return error.MissingDependency;
    try program.compileAll(options);
    const old_owner = program.fileById(root_id).owner;
    try std.testing.expect(old_owner != .none);
    var saw_type_error = false;
    for (program.fileById(root_id).compilation.?.diagnostics.items) |diagnostic| {
        if (diagnostic.code == 2322) saw_type_error = true;
    }
    try std.testing.expect(saw_type_error);

    var stats = ts_watch.VirtualWatchFs.init(gpa);
    defer stats.deinit();
    try stats.add("/project/main.ts", 1, root_source.len);
    try stats.add("/project/dep.ts", 1, old_dependency.len);
    var watcher = ts_watch.Watcher.init(gpa, stats.fs());
    defer watcher.deinit();
    try watcher.track("/project/main.ts");
    try tsc_main.trackProgramFiles(&watcher, &program);
    try std.testing.expectEqual(@as(usize, 2), watcher.count());
    var unchanged = try watcher.tick();
    defer unchanged.deinit(gpa);
    try std.testing.expect(unchanged.isEmpty());

    try stats.add("/project/dep.ts", 2, new_dependency.len);
    var changes = try watcher.tick();
    defer changes.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), changes.changes.items.len);
    try std.testing.expectEqual(ts_watch.ChangeKind.modified, changes.changes.items[0].kind);
    try std.testing.expectEqualStrings("/project/dep.ts", changes.changes.items[0].path);

    _ = (try program.updateSource(changes.changes.items[0].path, new_dependency)) orelse return error.MissingDependency;
    try std.testing.expect(program.fileById(dep_id).compilation == null);
    try std.testing.expect(program.fileById(root_id).compilation == null);
    const changed_paths = [_][]const u8{changes.changes.items[0].path};
    try std.testing.expectEqual(@as(u32, 2), try program.recompileChanged(&changed_paths, options));
    try std.testing.expect(program.fileById(root_id).owner != old_owner);
    for (program.fileById(root_id).compilation.?.diagnostics.items) |diagnostic| {
        try std.testing.expect(diagnostic.code != 2322);
    }
}

test "watch mode admits a later transitive import without recompiling unrelated sources" {
    const gpa = std.testing.allocator;
    const initial_source = "import { value } from './first'; const result: number = value;";
    const revised_source = "import { value } from './second'; const result: number = value;";
    const first_source = "export const value: number = 1;";
    const second_source = "export { value } from './third';";
    const third_source = "export const value: number = 2;";
    const unrelated_source = "export const stable = 1;";

    var sources = ts_resolver.VirtualFs.init(gpa);
    defer sources.deinit();
    try sources.addFile("/project/main.ts", initial_source);
    try sources.addFile("/project/first.ts", first_source);
    try sources.addFile("/project/second.ts", second_source);
    try sources.addFile("/project/third.ts", third_source);
    try sources.addFile("/project/unrelated.ts", unrelated_source);
    var resolver = ts_resolver.Resolver.init(gpa, sources.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(gpa, &resolver);
    defer program.deinit();
    const main_id = try program.add("/project/main.ts", initial_source);
    const unrelated_id = try program.add("/project/unrelated.ts", unrelated_source);
    const options: @import("ts_driver").CompileOptions = .{ .strict = true, .no_emit = true };
    try std.testing.expectEqual(@as(usize, 1), try program.loadImportClosure(options));
    try program.compileAll(options);
    const unrelated_owner = program.fileById(unrelated_id).owner;
    try std.testing.expect(unrelated_owner != .none);
    try std.testing.expect(program.lookupPath("/project/second.ts") == null);

    var stats = ts_watch.VirtualWatchFs.init(gpa);
    defer stats.deinit();
    try stats.add("/project/main.ts", 1, initial_source.len);
    try stats.add("/project/first.ts", 1, first_source.len);
    try stats.add("/project/second.ts", 1, second_source.len);
    try stats.add("/project/third.ts", 1, third_source.len);
    try stats.add("/project/unrelated.ts", 1, unrelated_source.len);
    var watcher = ts_watch.Watcher.init(gpa, stats.fs());
    defer watcher.deinit();
    try watcher.track("/project/main.ts");
    try tsc_main.trackProgramFiles(&watcher, &program);
    try std.testing.expectEqual(@as(usize, 3), watcher.count());

    _ = (try program.updateSource("/project/main.ts", revised_source)) orelse return error.MissingRoot;
    const changed_paths = [_][]const u8{"/project/main.ts"};
    try std.testing.expectEqual(@as(u32, 3), try program.recompileChanged(&changed_paths, options));
    const second_id = program.lookupPath("/project/second.ts") orelse return error.MissingNewImport;
    const third_id = program.lookupPath("/project/third.ts") orelse return error.MissingTransitiveImport;
    try std.testing.expect(program.fileById(second_id).compilation != null);
    try std.testing.expect(program.fileById(third_id).compilation != null);
    try std.testing.expectEqual(unrelated_owner, program.fileById(unrelated_id).owner);
    try std.testing.expectEqualSlices(ts_program.FileId, &.{second_id}, program.fileById(main_id).imports.items);
    try std.testing.expectEqualSlices(ts_program.FileId, &.{third_id}, program.fileById(second_id).imports.items);

    try tsc_main.trackProgramFiles(&watcher, &program);
    try std.testing.expectEqual(@as(usize, 5), watcher.count());
    try stats.add("/project/third.ts", 2, third_source.len + 1);
    var changes = try watcher.tick();
    defer changes.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), changes.changes.items.len);
    try std.testing.expectEqualStrings("/project/third.ts", changes.changes.items[0].path);

    _ = (try program.updateSource("/project/third.ts", "export const value: string = 'changed';")) orelse return error.MissingTransitiveImport;
    try std.testing.expect(program.fileById(main_id).compilation == null);
    try std.testing.expect(program.fileById(second_id).compilation == null);
    const dependency_change = [_][]const u8{"/project/third.ts"};
    try std.testing.expectEqual(@as(u32, 3), try program.recompileChanged(&dependency_change, options));
    try std.testing.expect(program.fileById(main_id).compilation != null);
    try std.testing.expect(program.fileById(second_id).compilation != null);
    try std.testing.expectEqual(unrelated_owner, program.fileById(unrelated_id).owner);
}

test "newly imported global declarations recheck unrelated checked sources" {
    const gpa = std.testing.allocator;
    const initial_source = "export const entry = 1;";
    const revised_source = "import './ambient'; export const entry = 1;";
    var sources = ts_resolver.VirtualFs.init(gpa);
    defer sources.deinit();
    try sources.addFile("/project/main.ts", initial_source);
    try sources.addFile("/project/ambient.d.ts", "interface Shared { value: number; }");
    try sources.addFile("/project/unrelated.ts", "const item: Shared = { value: 1 };");
    var resolver = ts_resolver.Resolver.init(gpa, sources.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(gpa, &resolver);
    defer program.deinit();
    _ = try program.add("/project/main.ts", initial_source);
    const unrelated_id = try program.add("/project/unrelated.ts", "const item: Shared = { value: 1 };");
    const options: @import("ts_driver").CompileOptions = .{ .strict = true, .no_emit = true };
    try std.testing.expectEqual(@as(usize, 0), try program.loadImportClosure(options));
    try program.compileAll(options);
    const prior_owner = program.fileById(unrelated_id).owner;
    try std.testing.expect(prior_owner != .none);

    _ = (try program.updateSource("/project/main.ts", revised_source)) orelse return error.MissingRoot;
    const changed = [_][]const u8{"/project/main.ts"};
    try std.testing.expectEqual(@as(u32, 3), try program.recompileChanged(&changed, options));
    try std.testing.expect(program.lookupPath("/project/ambient.d.ts") != null);
    try std.testing.expect(program.fileById(unrelated_id).owner != prior_owner);
}

test "watch revision admits a source after a cached missing import" {
    const gpa = std.testing.allocator;
    const initial_root = "import { value } from './dep'; const result: number = value;";
    const revised_root = initial_root ++ "\n// A later edit makes the importer eligible for incremental checking.";
    const typescript_source = "export const value: string = 'wrong';";

    var sources = ts_resolver.VirtualFs.init(gpa);
    defer sources.deinit();
    try sources.addFile("/project/main.ts", initial_root);
    var resolver = ts_resolver.Resolver.init(gpa, sources.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(gpa, &resolver);
    defer program.deinit();
    const main_id = try program.add("/project/main.ts", initial_root);
    const options: @import("ts_driver").CompileOptions = .{ .strict = true, .no_emit = true };
    try std.testing.expectEqual(@as(usize, 0), try program.loadImportClosure(options));
    try program.compileAll(options);
    try std.testing.expect(program.lookupPath("/project/dep.ts") == null);
    try std.testing.expectError(error.NotFound, resolver.resolve("./dep", "/project/main.ts"));

    try sources.addFile("/project/dep.ts", typescript_source);
    try sources.addFile("/project/main.ts", revised_root);
    _ = (try program.updateSource("/project/main.ts", revised_root)) orelse return error.MissingRoot;
    resolver.invalidateCaches();
    const changed = [_][]const u8{"/project/main.ts"};
    _ = try program.recompileChanged(&changed, options);

    const typescript_id = program.lookupPath("/project/dep.ts") orelse return error.MissingNewImport;
    try std.testing.expect(program.fileById(typescript_id).compilation != null);
    try std.testing.expectEqualSlices(ts_program.FileId, &.{typescript_id}, program.fileById(main_id).imports.items);
    var saw_type_error = false;
    for (program.fileById(main_id).compilation.?.diagnostics.items) |diagnostic| {
        if (diagnostic.code == 2322) saw_type_error = true;
    }
    try std.testing.expect(saw_type_error);
}

test "watch revision prefers a newly admitted TypeScript source over retained JavaScript" {
    const gpa = std.testing.allocator;
    const initial = "import { value } from './dep'; const result: number = value;";
    const revised = initial ++ "\n// Recheck after source priority changes.";
    const old_js = "export const value = 1;";
    const new_ts = "export const value: string = 'wrong';";

    var sources = ts_resolver.VirtualFs.init(gpa);
    defer sources.deinit();
    try sources.addFile("/project/main.ts", initial);
    try sources.addFile("/project/dep.js", old_js);
    var resolver = ts_resolver.Resolver.init(gpa, sources.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(gpa, &resolver);
    defer program.deinit();
    var adapter = ProgramResolverAdapter{ .resolver = &resolver, .program = &program };
    const main_id = try program.add("/project/main.ts", initial);
    const options: ts_driver.CompileOptions = .{
        .strict = true,
        .allow_js = true,
        .no_emit = true,
        .external_resolver = .{ .ptr = &adapter, .vtable = &ProgramResolverAdapter.vtable },
    };
    try std.testing.expectEqual(@as(usize, 1), try program.loadImportClosure(options));
    try program.compileAll(options);

    var stats = ts_watch.VirtualWatchFs.init(gpa);
    defer stats.deinit();
    try stats.add("/project/main.ts", 1, initial.len);
    try stats.add("/project/dep.js", 1, old_js.len);
    var watcher = ts_watch.Watcher.init(gpa, stats.fs());
    defer watcher.deinit();
    try tsc_main.trackProgramFiles(&watcher, &program);
    try std.testing.expectEqual(@as(usize, 2), watcher.count());

    try sources.addFile("/project/dep.ts", new_ts);
    try sources.addFile("/project/main.ts", revised);
    try stats.add("/project/dep.ts", 1, new_ts.len);
    try stats.add("/project/main.ts", 2, revised.len);
    var revision = try watcher.observe();
    defer revision.deinit();
    try std.testing.expectEqual(@as(usize, 1), revision.changes.changes.items.len);
    _ = (try program.updateSource("/project/main.ts", revised)) orelse return error.MissingRoot;
    resolver.invalidateCaches();
    const changed = [_][]const u8{"/project/main.ts"};
    _ = try program.recompileChanged(&changed, options);
    const preferred = program.lookupPath("/project/dep.ts") orelse return error.MissingPreferredSource;
    try std.testing.expectEqualSlices(ts_program.FileId, &.{preferred}, program.fileById(main_id).imports.items);
    var has_2322 = false;
    for (program.fileById(main_id).compilation.?.diagnostics.items) |diagnostic| {
        if (diagnostic.code == 2322) has_2322 = true;
    }
    try std.testing.expect(has_2322);
    try tsc_main.trackProgramFiles(&watcher, &program);
    revision.commit(&watcher);
    try std.testing.expectEqual(@as(usize, 3), watcher.count());

    const corrected = "export const value: number = 2;";
    try sources.addFile("/project/dep.ts", corrected);
    try stats.add("/project/dep.ts", 2, corrected.len);
    var next = try watcher.observe();
    defer next.deinit();
    try std.testing.expectEqual(@as(usize, 1), next.changes.changes.items.len);
    try std.testing.expectEqualStrings("/project/dep.ts", next.changes.changes.items[0].path);
    _ = (try program.updateSource("/project/dep.ts", corrected)) orelse return error.MissingPreferredSource;
    resolver.invalidateCaches();
    const dependency_change = [_][]const u8{"/project/dep.ts"};
    _ = try program.recompileChanged(&dependency_change, options);
    for (program.fileById(main_id).compilation.?.diagnostics.items) |diagnostic| {
        try std.testing.expect(diagnostic.code != 2322);
    }
}
