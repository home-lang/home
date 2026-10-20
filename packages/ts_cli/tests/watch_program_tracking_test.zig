const std = @import("std");
const tsc_main = @import("tsc_main");
const ts_program = @import("ts_program");
const ts_resolver = @import("ts_resolver");
const ts_watch = @import("ts_watch");

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
