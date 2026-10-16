const std = @import("std");
const Io = std.Io;

/// Package script runner (like npm/bun run)
pub const ScriptRunner = struct {
    allocator: std.mem.Allocator,
    io: Io,
    scripts: std.StringHashMap([]const u8),
    cwd: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, cwd: []const u8) Self {
        return initWithIo(allocator, Io.Threaded.global_single_threaded.io(), cwd);
    }

    pub fn initWithIo(allocator: std.mem.Allocator, io: Io, cwd: []const u8) Self {
        return .{
            .allocator = allocator,
            .io = io,
            .scripts = std.StringHashMap([]const u8).init(allocator),
            .cwd = cwd,
        };
    }

    pub fn deinit(self: *Self) void {
        var iterator = self.scripts.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.scripts.deinit();
        self.* = undefined;
    }

    /// Add a script
    pub fn addScript(self: *Self, name: []const u8, command: []const u8) !void {
        const command_copy = try self.allocator.dupe(u8, command);
        errdefer self.allocator.free(command_copy);

        if (self.scripts.getEntry(name)) |entry| {
            self.allocator.free(entry.value_ptr.*);
            entry.value_ptr.* = command_copy;
            return;
        }

        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);
        try self.scripts.put(name_copy, command_copy);
    }

    /// Run a script by name
    pub fn run(self: *Self, name: []const u8) !void {
        const command = self.scripts.get(name) orelse {
            std.debug.print("❌ Script '{s}' not found\n", .{name});
            std.debug.print("\nAvailable scripts:\n", .{});
            self.listScripts();
            return error.ScriptNotFound;
        };

        std.debug.print("🚀 Running script: {s}\n", .{name});
        std.debug.print("   {s}\n\n", .{command});

        try self.executeCommand(command);
    }

    /// List all available scripts
    pub fn listScripts(self: *const Self) void {
        var iter = self.scripts.iterator();
        while (iter.next()) |entry| {
            std.debug.print("  • {s:<20} {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
    }

    /// Execute a shell command
    fn executeCommand(self: *Self, command: []const u8) !void {
        var child = try std.process.spawn(self.io, .{
            .argv = &.{ "sh", "-c", command },
            .cwd = .{ .path = self.cwd },
        });
        const term = try child.wait(self.io);

        if (!term.success()) {
            std.debug.print("\n❌ Script terminated: {any}\n", .{term});
            return error.ScriptFailed;
        }
        std.debug.print("\n✓ Script completed successfully\n", .{});
    }
};

/// Pre-defined script lifecycle hooks
pub const LifecycleHooks = struct {
    pub const PREINSTALL = "preinstall";
    pub const INSTALL = "install";
    pub const POSTINSTALL = "postinstall";
    pub const PRETEST = "pretest";
    pub const TEST = "test";
    pub const POSTTEST = "posttest";
    pub const PREBUILD = "prebuild";
    pub const BUILD = "build";
    pub const POSTBUILD = "postbuild";
};
