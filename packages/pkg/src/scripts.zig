const std = @import("std");

/// Package script runner (like npm/bun run)
pub const ScriptRunner = struct {
    allocator: std.mem.Allocator,
    scripts: std.StringHashMap([]const u8),
    cwd: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, cwd: []const u8) Self {
        return .{
            .allocator = allocator,
            .scripts = std.StringHashMap([]const u8).init(allocator),
            .cwd = cwd,
        };
    }

    pub fn deinit(self: *Self) void {
        self.scripts.deinit();
    }

    /// Add a script
    pub fn addScript(self: *Self, name: []const u8, command: []const u8) !void {
        try self.scripts.put(name, command);
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
        var child = std.process.Child.init(&[_][]const u8{ "sh", "-c", command }, self.allocator);
        child.cwd = self.cwd;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
        child.stdin_behavior = .Inherit;

        const term = try child.spawnAndWait();

        switch (term) {
            .Exited => |code| {
                if (code != 0) {
                    std.debug.print("\n❌ Script failed with exit code {d}\n", .{code});
                    return error.ScriptFailed;
                }
                std.debug.print("\n✓ Script completed successfully\n", .{});
            },
            else => {
                std.debug.print("\n❌ Script terminated abnormally\n", .{});
                return error.ScriptFailed;
            },
        }
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
