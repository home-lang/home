//! Owner-thread child ownership. No JS callbacks or background JS execution.
const std = @import("std");

pub const Started = struct { id: u64, pid: std.posix.pid_t };
const Entry = struct { id: u64, child: std.process.Child };

pub const Pool = struct {
    allocator: std.mem.Allocator,
    threaded: *std.Io.Threaded,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    next_id: u64 = 1,

    pub fn init(allocator: std.mem.Allocator) !Pool {
        const threaded = try allocator.create(std.Io.Threaded);
        threaded.* = .init(allocator, .{});
        return .{ .allocator = allocator, .threaded = threaded };
    }

    pub fn deinit(self: *Pool) void {
        for (self.entries.items) |*entry| entry.child.kill(self.threaded.io());
        self.entries.deinit(self.allocator);
        self.threaded.deinit();
        self.allocator.destroy(self.threaded);
    }

    pub fn spawn(self: *Pool, argv: []const []const u8, cwd: ?[]const u8, env: *const std.process.Environ.Map, inherit: [3]bool) !Started {
        if (argv.len == 0 or self.next_id >= 0x1fffffffffffff) return error.InvalidRequest;
        // Reserve ownership before creating a process: allocation failure must
        // never leave an untracked child behind.
        try self.entries.ensureUnusedCapacity(self.allocator, 1);
        const child = if (std.mem.indexOfScalar(u8, argv[0], '/') != null)
            try self.spawnPath(argv[0], argv, cwd, env, inherit)
        else child: {
            const path = env.get("PATH") orelse if (std.c.getenv("PATH")) |p| std.mem.span(p) else "/usr/bin:/bin";
            var directories = std.mem.splitScalar(u8, path, ':');
            var denied = false;
            while (directories.next()) |directory| {
                const candidate = try std.fs.path.join(self.allocator, &.{ if (directory.len == 0) "." else directory, argv[0] });
                defer self.allocator.free(candidate);
                if (self.spawnPath(candidate, argv, cwd, env, inherit)) |result| break :child result else |err| switch (err) {
                    error.FileNotFound, error.NotDir => continue,
                    error.AccessDenied => denied = true,
                    else => return err,
                }
            }
            return if (denied) error.AccessDenied else error.FileNotFound;
        };
        const result: Started = .{ .id = self.next_id, .pid = child.id.? };
        self.entries.appendAssumeCapacity(.{ .id = result.id, .child = child });
        self.next_id += 1;
        return result;
    }

    fn spawnPath(self: *Pool, path: []const u8, argv: []const []const u8, cwd: ?[]const u8, env: *const std.process.Environ.Map, inherit: [3]bool) !std.process.Child {
        return std.process.spawn(self.threaded.io(), .{
            .exe = .{ .explicit = .{ .dir = .cwd(), .path = path } },
            .argv = argv,
            .cwd = if (cwd) |p| .{ .path = p } else .inherit,
            .environ_map = env,
            .stdin = if (inherit[0]) .inherit else .ignore,
            .stdout = if (inherit[1]) .inherit else .ignore,
            .stderr = if (inherit[2]) .inherit else .ignore,
        });
    }

    pub fn poll(self: *Pool, id: u64) !?std.process.Child.Term {
        for (self.entries.items, 0..) |*entry, index| {
            if (entry.id != id) continue;
            var status: c_int = 0;
            const result = std.c.waitpid(entry.child.id.?, &status, std.c.W.NOHANG);
            if (result == 0) return null;
            if (result < 0) return switch (std.posix.errno(result)) {
                .INTR => null,
                .CHILD => blk: {
                    // An external reaper has invalidated ownership. Never send
                    // a later signal to a PID the kernel could now reuse.
                    entry.child.id = null;
                    _ = self.entries.swapRemove(index);
                    break :blk error.ChildWaitFailed;
                },
                else => error.ChildWaitFailed,
            };
            // Only inherited/ignored stdio is admitted: there are no parent
            // pipe handles to close. waitpid has already reaped this child.
            std.debug.assert(entry.child.stdin == null and entry.child.stdout == null and entry.child.stderr == null);
            entry.child.id = null;
            _ = self.entries.swapRemove(index);
            return std.Io.Threaded.statusToTerm(@bitCast(status));
        }
        return error.InvalidHandle;
    }

    pub fn close(self: *Pool, id: u64) void {
        for (self.entries.items, 0..) |*entry, index| {
            if (entry.id != id) continue;
            entry.child.kill(self.threaded.io());
            _ = self.entries.swapRemove(index);
            return;
        }
    }

    pub fn signal(self: *Pool, id: u64, sig: std.posix.SIG) !bool {
        for (self.entries.items) |entry| {
            if (entry.id != id) continue;
            if (std.c.kill(entry.child.id.?, sig) == 0) return true;
            return switch (std.posix.errno(-1)) {
                .SRCH => false,
                else => error.ChildSignalFailed,
            };
        }
        // Tokens are never reused, even if the kernel reuses a PID.
        return false;
    }
};

test "children are owned, reaped and isolated from stale tokens" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const first = try pool.spawn(&.{ "/bin/sh", "-c", "exec sleep 5" }, null, &env, .{ false, false, false });
    try std.testing.expectEqual(null, try pool.poll(first.id));
    try std.testing.expect(try pool.signal(first.id, .TERM));
    const io = pool.threaded.io();
    while (try pool.poll(first.id) == null) try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    try std.testing.expect(!try pool.signal(first.id, .KILL));
    try std.testing.expectError(error.InvalidHandle, pool.poll(first.id));
    const second = try pool.spawn(&.{ "/bin/sh", "-c", "exit 17" }, null, &env, .{ false, false, false });
    try std.testing.expect(second.id > first.id);
    while (true) {
        if (try pool.poll(second.id)) |term| {
            try std.testing.expectEqual(@as(u8, 17), term.exited);
            break;
        }
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expectEqual(@as(usize, 0), pool.entries.items.len);
}

fn allocationLifecycle(allocator: std.mem.Allocator) !void {
    var pool = try Pool.init(allocator);
    defer pool.deinit();
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    _ = try pool.spawn(&.{ "/bin/sh", "-c", "exec sleep 5" }, null, &env, .{ false, false, false });
    // Teardown kills and reaps the live child, including allocation failures.
}

test "child creation allocation failures retain no process ownership" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationLifecycle, .{});
}
