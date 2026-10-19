const std = @import("std");
const testing = std.testing;
const modules = @import("modules");

test "module loader owns parsed source and caches a search-path module" {
    const allocator = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = "pub fn greet() { }\nfn hidden() { }";
    try tmp.dir.writeFile(io, .{ .sub_path = "greet.home", .data = source });
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    var loader = modules.ModuleLoader.init(allocator, io);
    defer loader.deinit();
    try loader.addSearchPath(root);
    const loaded = try loader.loadModule("greet");
    try testing.expectEqualStrings("greet", loaded.name);
    try testing.expectEqualStrings(source, loaded.source);
    try testing.expectEqual(@as(usize, 2), loaded.program.statements.len);
    try testing.expect(loaded.program.statements[0] == .FnDecl);
    try testing.expectEqualStrings("greet", loaded.program.statements[0].FnDecl.name);
    try testing.expect(loaded.exports.contains("greet"));
    try testing.expect(!loaded.exports.contains("hidden"));
    try testing.expect(loaded == try loader.loadModule("greet"));
}

test "module loader reports a missing module without retaining allocations" {
    const allocator = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    var loader = modules.ModuleLoader.init(allocator, io);
    defer loader.deinit();
    try loader.addSearchPath(root);
    try testing.expectError(error.ModuleNotFound, loader.loadModule("missing_module_fixture_884"));
}

test "module loader exports public values and types but not private declarations" {
    const allocator = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "symbols.home",
        .data = "pub const answer = 42;\npub var counter = 0;\npub type Alias = u32;\nconst hidden = 1;",
    });
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    var loader = modules.ModuleLoader.init(allocator, io);
    defer loader.deinit();
    try loader.addSearchPath(root);
    const loaded = try loader.loadModule("symbols");
    try testing.expectEqual(modules.Module.ExportKind.Constant, loaded.exports.get("answer").?.kind);
    try testing.expectEqual(modules.Module.ExportKind.Variable, loaded.exports.get("counter").?.kind);
    try testing.expectEqual(modules.Module.ExportKind.Type, loaded.exports.get("Alias").?.kind);
    try testing.expect(!loaded.exports.contains("hidden"));
}

test "module loader accepts the documented size limit and rejects larger source" {
    const allocator = testing.allocator;
    const io = testing.io;
    const max_size = 10 * 1024 * 1024;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const bytes = try allocator.alloc(u8, max_size + 1);
    defer allocator.free(bytes);
    @memset(bytes, ' ');
    try tmp.dir.writeFile(io, .{ .sub_path = "limit_ok.home", .data = bytes[0..max_size] });
    try tmp.dir.writeFile(io, .{ .sub_path = "limit_over.home", .data = bytes });

    var loader = modules.ModuleLoader.init(allocator, io);
    defer loader.deinit();
    try loader.addSearchPath(root);
    const accepted = try loader.loadModule("limit_ok");
    try testing.expectEqual(@as(usize, max_size), accepted.source.len);
    try testing.expectError(error.StreamTooLong, loader.loadModule("limit_over"));
}

test "module loader never caches a partial parse and can reload repaired source" {
    const allocator = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    try tmp.dir.writeFile(io, .{ .sub_path = "broken.home", .data = "pub fn broken(" });

    var loader = modules.ModuleLoader.init(allocator, io);
    defer loader.deinit();
    try loader.addSearchPath(root);
    try testing.expectError(error.ModuleParseFailed, loader.loadModule("broken"));
    try testing.expect(!loader.modules.contains("broken"));

    try tmp.dir.writeFile(io, .{ .sub_path = "broken.home", .data = "pub fn repaired() { }" });
    const loaded = try loader.loadModule("broken");
    try testing.expect(loaded.exports.contains("repaired"));
    try testing.expect(!loaded.exports.contains("broken"));
}

test "relative imports use the importing file and canonical cache identity" {
    const allocator = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "first/nested");
    try tmp.dir.createDirPath(io, "second");
    try tmp.dir.writeFile(io, .{ .sub_path = "first/entry_first.home", .data = "pub fn first() { }" });
    try tmp.dir.writeFile(io, .{ .sub_path = "second/entry_second.home", .data = "pub fn second() { }" });
    try tmp.dir.writeFile(io, .{ .sub_path = "first/shared.home", .data = "pub fn from_first() { }" });
    try tmp.dir.writeFile(io, .{ .sub_path = "second/shared.home", .data = "pub fn from_second() { }" });
    try tmp.dir.writeFile(io, .{ .sub_path = "first/nested/child.home", .data = "pub fn child() { }" });
    const first_root = try tmp.dir.realPathFileAlloc(io, "first", allocator);
    defer allocator.free(first_root);
    const second_root = try tmp.dir.realPathFileAlloc(io, "second", allocator);
    defer allocator.free(second_root);
    const first_shared_path = try tmp.dir.realPathFileAlloc(io, "first/shared.home", allocator);
    defer allocator.free(first_shared_path);
    const second_shared_path = try tmp.dir.realPathFileAlloc(io, "second/shared.home", allocator);
    defer allocator.free(second_shared_path);

    var loader = modules.ModuleLoader.init(allocator, io);
    defer loader.deinit();
    try loader.addSearchPath(first_root);
    try loader.addSearchPath(second_root);
    const first = try loader.loadModule("entry_first");
    const second = try loader.loadModule("entry_second");

    const first_shared = try loader.resolveImport(first.file_path, "./shared");
    const second_shared = try loader.resolveImport(second.file_path, "./shared.home");
    try testing.expect(first_shared != second_shared);
    try testing.expectEqualStrings(first_shared_path, first_shared.file_path);
    try testing.expectEqualStrings(second_shared_path, second_shared.file_path);
    try testing.expect(first_shared.exports.contains("from_first"));
    try testing.expect(second_shared.exports.contains("from_second"));
    try testing.expect(first_shared == try loader.resolveImport(first.file_path, "./nested/../shared"));
    try testing.expect(first_shared == try loader.loadModule("shared"));

    const child = try loader.resolveImport(first.file_path, "./nested/child");
    try testing.expect(first_shared == try loader.resolveImport(child.file_path, "../shared"));
    try testing.expectEqual(@as(usize, 5), loader.modules.count());
    try testing.expectError(error.ModuleNotFound, loader.resolveImport(second.file_path, "./missing"));
    try testing.expectError(error.ImportingModuleNotLoaded, loader.resolveImport("not-loaded", "./shared"));
    try testing.expectEqual(@as(usize, 5), loader.modules.count());
}

test "bare-name cache retains a loaded module after its file is removed" {
    const allocator = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "cached.home", .data = "pub fn retained() { }" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    var loader = modules.ModuleLoader.init(allocator, io);
    defer loader.deinit();
    try loader.addSearchPath(root);
    const first = try loader.loadModule("cached");
    try tmp.dir.deleteFile(io, "cached.home");
    try testing.expect(first == try loader.loadModule("cached"));
    try testing.expect(first.exports.contains("retained"));
    try testing.expectEqual(@as(usize, 1), loader.modules.count());
}

test "relative import cache retains each importer's module after source removal" {
    const allocator = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "first");
    try tmp.dir.createDirPath(io, "second");
    try tmp.dir.writeFile(io, .{ .sub_path = "first/entry_first.home", .data = "pub fn first() { }" });
    try tmp.dir.writeFile(io, .{ .sub_path = "second/entry_second.home", .data = "pub fn second() { }" });
    try tmp.dir.writeFile(io, .{ .sub_path = "first/shared.home", .data = "pub fn from_first() { }" });
    try tmp.dir.writeFile(io, .{ .sub_path = "second/shared.home", .data = "pub fn from_second() { }" });
    const first_root = try tmp.dir.realPathFileAlloc(io, "first", allocator);
    defer allocator.free(first_root);
    const second_root = try tmp.dir.realPathFileAlloc(io, "second", allocator);
    defer allocator.free(second_root);

    var loader = modules.ModuleLoader.init(allocator, io);
    defer loader.deinit();
    try loader.addSearchPath(first_root);
    try loader.addSearchPath(second_root);
    const first = try loader.loadModule("entry_first");
    const second = try loader.loadModule("entry_second");
    const first_shared = try loader.resolveImport(first.file_path, "./shared");
    const second_shared = try loader.resolveImport(second.file_path, "./shared");
    try testing.expect(first_shared != second_shared);

    try tmp.dir.deleteFile(io, "first/shared.home");
    try tmp.dir.deleteFile(io, "second/shared.home");
    try testing.expect(first_shared == try loader.resolveImport(first.file_path, "./shared"));
    try testing.expect(second_shared == try loader.resolveImport(second.file_path, "./shared"));
    try testing.expect(first_shared.exports.contains("from_first"));
    try testing.expect(second_shared.exports.contains("from_second"));
    try testing.expectError(error.ModuleNotFound, loader.resolveImport(first.file_path, "./missing"));
    try testing.expectEqual(@as(usize, 4), loader.modules.count());

    try tmp.dir.writeFile(io, .{ .sub_path = "first/broken.home", .data = "pub fn broken(" });
    try testing.expectError(error.ModuleParseFailed, loader.resolveImport(first.file_path, "./broken"));
    try tmp.dir.writeFile(io, .{ .sub_path = "first/broken.home", .data = "pub fn repaired() { }" });
    const repaired = try loader.resolveImport(first.file_path, "./broken");
    try testing.expect(repaired.exports.contains("repaired"));
    try testing.expectEqual(@as(usize, 5), loader.modules.count());
}
