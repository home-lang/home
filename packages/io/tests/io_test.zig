const std = @import("std");
const home_io = @import("io");

test "public declarations compile" {
    std.testing.refAllDecls(home_io);
    std.testing.refAllDecls(home_io.IniFile);
}

test "public fs API round trip and size" {
    const allocator = std.testing.allocator;
    const path = "home_io_public_api_test.txt";
    const contents = "Home std.Io migration";
    const io = std.Io.Threaded.global_single_threaded.io();

    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    try home_io.fs.writeFile(allocator, path, contents);

    try std.testing.expect(home_io.fs.exists(path));
    try std.testing.expectEqual(contents.len, try home_io.fs.getSize(path));

    const actual = try home_io.fs.readFile(allocator, path);
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(contents, actual);
}

test "configured async runtime performs file IO" {
    const allocator = std.testing.allocator;
    const path = "home_io_async_runtime_test.txt";
    const contents = "bounded worker pool";

    var runtime = home_io.AsyncRuntime.initWithThreads(allocator, 1);
    defer runtime.deinit();
    defer std.Io.Dir.cwd().deleteFile(runtime.io(), path) catch {};

    try runtime.writeFile(path, contents);
    try std.testing.expect(runtime.fileExists(path));

    const actual = try runtime.readFile(path);
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(contents, actual);
}

test "INI files use explicit IO and replace duplicate owned values" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "units.ini" });
    defer allocator.free(path);
    const contents =
        \\Object Unit
        \\  Health = 1
        \\  Health = 2
        \\End
        \\Object Unit
        \\  Health = 3
        \\  Enabled = Yes
        \\End
    ;
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = contents });

    var ini = try home_io.IniFile.parseFileWithIo(allocator, std.testing.io, path);
    defer ini.deinit();
    const unit = ini.getSection("Unit").?;
    try std.testing.expectEqual(@as(?i32, 3), unit.getInt("Health"));
    try std.testing.expectEqual(@as(?bool, true), unit.getBool("Enabled"));
    try std.testing.expectEqual(@as(usize, 1), ini.sections.size());

    const names = try ini.getSectionNames();
    defer allocator.free(names);
    try std.testing.expectEqual(@as(usize, 1), names.len);
    try std.testing.expectEqualStrings("Unit", names[0]);

    var compatibility_ini = try home_io.IniFile.parseFile(allocator, path);
    defer compatibility_ini.deinit();
    try std.testing.expectEqual(@as(?i32, 3), compatibility_ini.getSection("Unit").?.getInt("Health"));
}

fn parseIniForAllocationFailure(allocator: std.mem.Allocator) !void {
    const contents =
        \\Object Unit
        \\  Health = 100
        \\  Draw = Mesh ModuleTag_01
        \\    Model = unit.mesh
        \\    Animation = idle.anim
        \\  End
        \\End
        \\Object Unit
        \\  Health = 125
        \\  Behavior = Logic ModuleTag_02
        \\    Enabled = Yes
        \\  End
        \\End
    ;
    var ini = try home_io.IniFile.parse(allocator, contents);
    defer ini.deinit();
    const unit = ini.getSection("Unit").?;
    try std.testing.expectEqual(@as(?i32, 125), unit.getInt("Health"));
    try std.testing.expectEqual(@as(usize, 1), unit.blocks.items.len);
}

test "INI parsing releases every partial allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        parseIniForAllocationFailure,
        .{},
    );
}
