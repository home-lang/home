const std = @import("std");
const tsc_main = @import("tsc_main");
const ts_program = @import("ts_program");
const ts_resolver = @import("ts_resolver");
const ts_watch = @import("ts_watch");

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
