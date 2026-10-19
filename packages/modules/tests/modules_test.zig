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
