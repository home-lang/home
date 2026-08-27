const std = @import("std");

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) return error.MissingLauncherArguments;

    var environ_map = try init.environ_map.clone(init.gpa);
    defer environ_map.deinit();
    try environ_map.put("HOME_BUN_TEST_EXECUTABLE", args[1]);

    var child = try std.process.spawn(init.io, .{
        .argv = args[2..],
        .environ_map = &environ_map,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(init.io);

    return switch (term) {
        .exited => |code| code,
        .signal => |signal| @intCast(@min(255, 128 + @backingInt(signal))),
        .stopped => |signal| @intCast(@min(255, 128 + @backingInt(signal))),
        .unknown => 1,
    };
}
