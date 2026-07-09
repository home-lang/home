// Copied from bun/src/runtime/api/bun/spawn.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../../cli/LICENSE.bun.md.
//
// Rewrites:
//   - @import("bun")                              → @import("home")
//   - bun.default_allocator                        → std.heap.c_allocator
//     (matches the `std.heap.c_allocator` re-export but works in
//     standalone `zig test` mode where the home_rt module isn't wired up)
//   - bun.span                                     → std.mem.span
//   - bun.FD                                       → local fd_t alias
//   - bun.Environment                              → home_rt.Environment
//   - bun.sys.Maybe                                → home_rt.sys.Maybe
//   - std.c.POSIX_SPAWN packed flags               → bit-cast helpers for
//     Zig 0.17's Darwin libc declarations
//
// This file keeps Bun's POSIX spawn action/attribute layout and exposes the
// copied process/stdin/stdout/stderr leaves through the same public names.

const std = @import("std");
const bun = @import("bun");

const fd_t = std.posix.fd_t;
const mode_t = std.posix.mode_t;
const pid_t = std.posix.pid_t;
const system = std.posix.system;
const errno = std.posix.errno;
const unexpectedErrno = std.posix.unexpectedErrno;

const SpawnFlags = @TypeOf(std.mem.zeroes(system.POSIX_SPAWN));

fn spawnFlagsFromBits(flags: u16) SpawnFlags {
    return @bitCast(flags);
}

fn spawnFlagsToBits(flags: SpawnFlags) u16 {
    return @bitCast(flags);
}

fn spawnFlagFieldBits(comptime field_name: []const u8) ?u16 {
    return switch (@typeInfo(SpawnFlags)) {
        .@"struct" => {
            if (!@hasField(SpawnFlags, field_name)) return null;
            var flags = std.mem.zeroes(SpawnFlags);
            @field(flags, field_name) = true;
            return spawnFlagsToBits(flags);
        },
        else => null,
    };
}

pub const BunSpawn = struct {
    pub const Action = extern struct {
        pub const FileActionType = enum(u8) {
            none = 0,
            close = 1,
            dup2 = 2,
            open = 3,
        };

        kind: FileActionType = .none,
        path: ?[*:0]const u8 = null,
        fds: [2]fd_t,
        flags: c_int = 0,
        mode: c_int = 0,

        pub fn init() !Action {
            return .{ .fds = .{ 0, 0 } };
        }

        pub fn deinit(self: *Action, allocator: std.mem.Allocator) void {
            if (self.kind == .open) {
                if (self.path) |path| {
                    allocator.free(std.mem.span(path));
                }
            }
        }
    };

    pub const Actions = struct {
        chdir_buf: ?[*:0]u8 = null,
        actions: std.array_list.Managed(Action),
        detached: bool = false,

        pub fn init() !Actions {
            return .{
                .actions = std.array_list.Managed(Action).init(std.heap.c_allocator),
            };
        }

        pub fn deinit(self: *Actions) void {
            if (self.chdir_buf) |buf| {
                std.heap.c_allocator.free(std.mem.span(buf));
            }

            for (self.actions.items) |*action| {
                action.deinit(std.heap.c_allocator);
            }

            self.actions.deinit();
        }

        pub fn open(self: *Actions, fd: fd_t, path: []const u8, flags: u32, mode: i32) !void {
            const posix_path = try std.posix.toPosixPath(path);
            return self.openZ(fd, &posix_path, flags, mode);
        }

        pub fn openZ(self: *Actions, fd: fd_t, path: [*:0]const u8, flags: u32, mode: i32) !void {
            const dup = try bun.dupeZ(std.heap.c_allocator, u8, std.mem.span(path));
            try self.actions.append(.{
                .kind = .open,
                .path = dup.ptr,
                .flags = @intCast(flags),
                .mode = @intCast(mode),
                .fds = .{ fd, 0 },
            });
        }

        pub fn close(self: *Actions, fd: fd_t) !void {
            try self.actions.append(.{
                .kind = .close,
                .fds = .{ fd, 0 },
            });
        }

        pub fn dup2(self: *Actions, fd: fd_t, newfd: fd_t) !void {
            try self.actions.append(.{
                .kind = .dup2,
                .fds = .{ fd, newfd },
            });
        }

        pub fn inherit(self: *Actions, fd: fd_t) !void {
            try self.dup2(fd, fd);
        }

        pub fn chdir(self: *Actions, path: []const u8) !void {
            if (self.chdir_buf) |buf| {
                std.heap.c_allocator.free(std.mem.span(buf));
            }

            self.chdir_buf = (try bun.dupeZ(std.heap.c_allocator, u8, path)).ptr;
        }
    };

    pub const Attr = struct {
        detached: bool = false,
        new_process_group: bool = false,
        pty_slave_fd: i32 = -1,
        flags: u16 = 0,
        reset_signals: bool = false,
        linux_pdeathsig: i32 = 0,

        pub fn init() !Attr {
            return Attr{};
        }

        pub fn deinit(_: *Attr) void {}

        pub fn get(self: Attr) !u16 {
            return self.flags;
        }

        pub fn set(self: *Attr, flags: u16) !void {
            self.flags = flags;
            // FreeBSD's <spawn.h> has no POSIX_SPAWN_SETSID; bun-spawn.cpp
            // calls setsid() in the child for `detached`, which process.zig
            // sets directly on this struct BEFORE calling set(). Preserve
            // that value when the flag bit isn't available.
            if (comptime spawnFlagFieldBits("SETSID")) |setsid| {
                self.detached = (flags & setsid) != 0;
            }
        }

        pub fn resetSignals(self: *Attr) !void {
            self.reset_signals = true;
        }
    };
};

// Mostly taken from Bun's copy of Zig's posix_spawn.zig.
pub const PosixSpawn = struct {
    pub const WaitPidResult = struct {
        pid: pid_t,
        status: u32,
    };

    pub fn spawnZ(
        path: [*:0]const u8,
        actions: Actions,
        attr: Attr,
        argv: [*:null]?[*:0]const u8,
        envp: [*:null]?[*:0]const u8,
    ) @import("bun").sys.Maybe(pid_t) {
        const M = @import("bun").sys.Maybe(pid_t);
        var native_actions = PosixSpawnActions.init() catch return .{ .err = .{
            .errno = @intFromEnum(std.posix.E.NOMEM),
            .syscall = .posix_spawn,
        } };
        defer native_actions.deinit();

        for (actions.actions.items) |action| {
            switch (action.kind) {
                .none => {},
                .close => native_actions.close(action.fds[0]) catch {},
                .dup2 => native_actions.dup2(action.fds[0], action.fds[1]) catch {},
                .open => if (action.path) |action_path| {
                    native_actions.openZ(action.fds[0], action_path, @bitCast(action.flags), @intCast(action.mode)) catch {};
                },
            }
        }
        if (actions.chdir_buf) |cwd| {
            native_actions.chdirZ(cwd) catch {};
        }

        var native_attr = PosixSpawnAttr.init() catch return .{ .err = .{
            .errno = @intFromEnum(std.posix.E.NOMEM),
            .syscall = .posix_spawn,
        } };
        defer native_attr.deinit();
        native_attr.set(attr.flags) catch {};
        if (attr.reset_signals) native_attr.resetSignals() catch {};

        var pid: pid_t = 0;
        const rc = system.posix_spawn(&pid, path, &native_actions.actions, &native_attr.attr, argv, envp);
        if (M.errnoSys(rc, .posix_spawn)) |err| return err;
        return .{ .result = pid };
    }

    /// Forward-port: std.posix.wait4 was removed in Home's Zig fork; wrap the
    /// libc wait4 directly. `usage` is a pointer to process.Rusage (layout-
    /// compatible with std.c.rusage).
    pub fn wait4(pid: pid_t, options: c_int, usage: anytype) @import("bun").sys.Maybe(WaitPidResult) {
        const M = @import("bun").sys.Maybe(WaitPidResult);
        var status: c_int = 0;
        const rc = std.c.wait4(pid, &status, options, @ptrCast(usage));
        if (M.errnoSys(rc, .waitpid)) |err| return err;
        return .{ .result = .{ .pid = @intCast(rc), .status = @bitCast(status) } };
    }

    pub const PosixSpawnAttr = struct {
        attr: system.posix_spawnattr_t,
        detached: bool = false,
        pty_slave_fd: i32 = -1,

        pub fn init() !PosixSpawnAttr {
            var attr: system.posix_spawnattr_t = undefined;
            switch (errno(system.posix_spawnattr_init(&attr))) {
                .SUCCESS => return PosixSpawnAttr{ .attr = attr },
                .NOMEM => return error.SystemResources,
                .INVAL => unreachable,
                else => |err| return unexpectedErrno(err),
            }
        }

        pub fn deinit(self: *PosixSpawnAttr) void {
            _ = system.posix_spawnattr_destroy(&self.attr);
        }

        pub fn get(self: PosixSpawnAttr) !u16 {
            var flags: SpawnFlags = undefined;
            switch (errno(system.posix_spawnattr_getflags(&self.attr, &flags))) {
                .SUCCESS => return spawnFlagsToBits(flags),
                .INVAL => unreachable,
                else => |err| return unexpectedErrno(err),
            }
        }

        pub fn set(self: *PosixSpawnAttr, flags: u16) !void {
            switch (errno(system.posix_spawnattr_setflags(&self.attr, spawnFlagsFromBits(flags)))) {
                .SUCCESS => return,
                .INVAL => unreachable,
                else => |err| return unexpectedErrno(err),
            }
        }

        pub fn resetSignals(this: *PosixSpawnAttr) !void {
            if (posix_spawnattr_reset_signals(&this.attr) != 0) {
                return error.SystemResources;
            }
        }

        extern fn posix_spawnattr_reset_signals(attr: *system.posix_spawnattr_t) c_int;
    };

    pub const PosixSpawnActions = struct {
        actions: system.posix_spawn_file_actions_t,

        pub fn init() !PosixSpawnActions {
            var actions: system.posix_spawn_file_actions_t = undefined;
            switch (errno(system.posix_spawn_file_actions_init(&actions))) {
                .SUCCESS => return PosixSpawnActions{ .actions = actions },
                .NOMEM => return error.SystemResources,
                .INVAL => unreachable,
                else => |err| return unexpectedErrno(err),
            }
        }

        pub fn deinit(self: *PosixSpawnActions) void {
            _ = system.posix_spawn_file_actions_destroy(&self.actions);
            self.* = undefined;
        }

        pub fn open(self: *PosixSpawnActions, fd: fd_t, path: []const u8, flags: u32, mode: mode_t) !void {
            const posix_path = try std.posix.toPosixPath(path);
            return self.openZ(fd, &posix_path, flags, mode);
        }

        pub fn openZ(self: *PosixSpawnActions, fd: fd_t, path: [*:0]const u8, flags: u32, mode: mode_t) !void {
            switch (errno(system.posix_spawn_file_actions_addopen(&self.actions, fd, path, @as(c_int, @bitCast(flags)), mode))) {
                .SUCCESS => return,
                .BADF => return error.InvalidFileDescriptor,
                .NOMEM => return error.SystemResources,
                .NAMETOOLONG => return error.NameTooLong,
                .INVAL => unreachable,
                else => |err| return unexpectedErrno(err),
            }
        }

        pub fn close(self: *PosixSpawnActions, fd: fd_t) !void {
            switch (errno(system.posix_spawn_file_actions_addclose(&self.actions, fd))) {
                .SUCCESS => return,
                .BADF => return error.InvalidFileDescriptor,
                .NOMEM => return error.SystemResources,
                .INVAL => unreachable,
                .NAMETOOLONG => unreachable,
                else => |err| return unexpectedErrno(err),
            }
        }

        pub fn dup2(self: *PosixSpawnActions, fd: fd_t, newfd: fd_t) !void {
            if (fd == newfd) {
                return self.inherit(fd);
            }

            switch (errno(system.posix_spawn_file_actions_adddup2(&self.actions, fd, newfd))) {
                .SUCCESS => return,
                .BADF => return error.InvalidFileDescriptor,
                .NOMEM => return error.SystemResources,
                .INVAL => unreachable,
                .NAMETOOLONG => unreachable,
                else => |err| return unexpectedErrno(err),
            }
        }

        pub fn inherit(self: *PosixSpawnActions, fd: fd_t) !void {
            switch (errno(system.posix_spawn_file_actions_addinherit_np(&self.actions, fd))) {
                .SUCCESS => return,
                .BADF => return error.InvalidFileDescriptor,
                .NOMEM => return error.SystemResources,
                .INVAL => unreachable,
                .NAMETOOLONG => unreachable,
                else => |err| return unexpectedErrno(err),
            }
        }

        pub fn chdir(self: *PosixSpawnActions, path: []const u8) !void {
            const posix_path = try std.posix.toPosixPath(path);
            return self.chdirZ(&posix_path);
        }

        fn chdirZ(self: *PosixSpawnActions, path: [*:0]const u8) !void {
            switch (errno(system.posix_spawn_file_actions_addchdir_np(&self.actions, path))) {
                .SUCCESS => return,
                .NOMEM => return error.SystemResources,
                .NAMETOOLONG => return error.NameTooLong,
                .BADF => unreachable,
                .INVAL => unreachable,
                else => |err| return unexpectedErrno(err),
            }
        }
    };

    pub const Actions = BunSpawn.Actions;
    pub const Attr = BunSpawn.Attr;
    pub const process = @import("./process.zig");
    pub const Process = process.Process;
    pub const SpawnOptions = process.SpawnOptions;
    pub const Status = process.Status;
    pub const sync = process.sync;
    pub const spawnProcess = process.spawnProcess;
    pub const WindowsSpawnResult = process.WindowsSpawnResult;
    pub const PosixSpawnResult = process.PosixSpawnResult;
    pub const SpawnProcessResult = process.SpawnProcessResult;
    pub const WindowsSpawnOptions = process.WindowsSpawnOptions;
    pub const Rusage = process.Rusage;
    pub const Stdio = @import("./spawn/stdio.zig").Stdio;
};

test "spawn: BunSpawn.Action default kind is .none" {
    const a = try BunSpawn.Action.init();
    try std.testing.expectEqual(BunSpawn.Action.FileActionType.none, a.kind);
    try std.testing.expect(a.path == null);
    try std.testing.expectEqual(@as(c_int, 0), a.flags);
}

test "spawn: BunSpawn.Action FileActionType tag values are extern-stable" {
    // The C++ side of posix_spawn_bun reads these as u8 enum values;
    // pin them so a renumbering in the upstream zig file would fire here.
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(BunSpawn.Action.FileActionType.none));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(BunSpawn.Action.FileActionType.close));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(BunSpawn.Action.FileActionType.dup2));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(BunSpawn.Action.FileActionType.open));
}

test "spawn: BunSpawn.Actions close/dup2/inherit record one action each" {
    var actions = try BunSpawn.Actions.init();
    defer actions.deinit();

    try actions.close(3);
    try actions.dup2(4, 5);
    try actions.inherit(6);

    try std.testing.expectEqual(@as(usize, 3), actions.actions.items.len);
    try std.testing.expectEqual(BunSpawn.Action.FileActionType.close, actions.actions.items[0].kind);
    try std.testing.expectEqual([2]fd_t{ 3, 0 }, actions.actions.items[0].fds);
    try std.testing.expectEqual(BunSpawn.Action.FileActionType.dup2, actions.actions.items[1].kind);
    try std.testing.expectEqual([2]fd_t{ 4, 5 }, actions.actions.items[1].fds);
    // inherit is dup2(fd, fd)
    try std.testing.expectEqual(BunSpawn.Action.FileActionType.dup2, actions.actions.items[2].kind);
    try std.testing.expectEqual([2]fd_t{ 6, 6 }, actions.actions.items[2].fds);
}

test "spawn: BunSpawn.Actions openZ duplicates the path and frees on deinit" {
    var actions = try BunSpawn.Actions.init();
    defer actions.deinit();

    try actions.openZ(7, "/tmp/spawn-test-path", 0o2, 0o644);
    try std.testing.expectEqual(@as(usize, 1), actions.actions.items.len);

    const path_ptr = actions.actions.items[0].path orelse return error.NullPath;
    try std.testing.expectEqualStrings("/tmp/spawn-test-path", std.mem.span(path_ptr));
    try std.testing.expectEqual(@as(c_int, 0o2), actions.actions.items[0].flags);
    try std.testing.expectEqual(@as(c_int, 0o644), actions.actions.items[0].mode);
}

test "spawn: BunSpawn.Actions.chdir replaces the chdir_buf" {
    var actions = try BunSpawn.Actions.init();
    defer actions.deinit();

    try actions.chdir("/first");
    try actions.chdir("/second");
    const buf = actions.chdir_buf orelse return error.NullChdir;
    try std.testing.expectEqualStrings("/second", std.mem.span(buf));
}

test "spawn: BunSpawn.Attr round-trips flags through set/get" {
    var attr = try BunSpawn.Attr.init();
    defer attr.deinit();

    try attr.set(0x42);
    try std.testing.expectEqual(@as(u16, 0x42), try attr.get());

    try attr.resetSignals();
    try std.testing.expect(attr.reset_signals);
}

test "spawn: BunSpawn.Attr.set derives detached from SETSID when available" {
    var attr = try BunSpawn.Attr.init();
    defer attr.deinit();

    if (comptime spawnFlagFieldBits("SETSID")) |setsid| {
        attr.detached = true;
        try attr.set(0);
        try std.testing.expect(!attr.detached);

        try attr.set(setsid);
        try std.testing.expect(attr.detached);
        try std.testing.expectEqual(setsid, try attr.get());
    } else {
        attr.detached = true;
        try attr.set(0);
        try std.testing.expect(attr.detached);
    }
}

test "spawn: PosixSpawn.WaitPidResult pins pid/status fields" {
    const result = PosixSpawn.WaitPidResult{ .pid = 123, .status = 9 };
    try std.testing.expectEqual(@as(pid_t, 123), result.pid);
    try std.testing.expectEqual(@as(u32, 9), result.status);
}

test "spawn: PosixSpawnAttr init/get/set/deinit round-trips flags" {
    var attr = try PosixSpawn.PosixSpawnAttr.init();
    defer attr.deinit();

    try attr.set(0);
    try std.testing.expectEqual(@as(u16, 0), try attr.get());
}

test "spawn: PosixSpawnActions init/deinit and file action helpers" {
    var actions = try PosixSpawn.PosixSpawnActions.init();
    defer actions.deinit();

    try actions.close(3);
    try actions.dup2(4, 5);
    try actions.inherit(6);
    try actions.openZ(7, "/tmp/home-spawn-posix-action", 0o2, 0o644);
    try actions.chdir("/tmp");
}

test "spawn: PosixSpawn aliases active action and attr wrappers" {
    try std.testing.expectEqual(BunSpawn.Actions, PosixSpawn.Actions);
    try std.testing.expectEqual(BunSpawn.Attr, PosixSpawn.Attr);
}

test "spawn: BunSpawn.Action layout is C-ABI compatible" {
    try std.testing.expect(@typeInfo(BunSpawn.Action).@"struct".layout == .@"extern");
}
