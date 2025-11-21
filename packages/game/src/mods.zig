// Home Game Development Framework - Mod Support System
// Load, manage, and sandbox game modifications

const std = @import("std");

// ============================================================================
// Mod Metadata
// ============================================================================

pub const ModInfo = struct {
    id: []const u8,
    name: []const u8,
    version: SemanticVersion,
    author: []const u8,
    description: []const u8,
    dependencies: []const Dependency,
    conflicts: []const []const u8,
    load_priority: i32,
    enabled: bool,
    path: []const u8,
};

pub const SemanticVersion = struct {
    major: u32,
    minor: u32,
    patch: u32,

    pub fn compare(self: SemanticVersion, other: SemanticVersion) std.math.Order {
        if (self.major != other.major) {
            return std.math.order(self.major, other.major);
        }
        if (self.minor != other.minor) {
            return std.math.order(self.minor, other.minor);
        }
        return std.math.order(self.patch, other.patch);
    }

    pub fn isCompatible(self: SemanticVersion, required: SemanticVersion) bool {
        // Same major version, and at least the required minor version
        return self.major == required.major and self.minor >= required.minor;
    }

    pub fn format(self: SemanticVersion, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{d}.{d}.{d}", .{ self.major, self.minor, self.patch });
    }
};

pub const Dependency = struct {
    mod_id: []const u8,
    min_version: ?SemanticVersion,
    max_version: ?SemanticVersion,
    optional: bool,
};

// ============================================================================
// Mod Loading State
// ============================================================================

pub const ModState = enum {
    unloaded,
    loading,
    loaded,
    active,
    error_state,
    disabled,
};

pub const LoadedMod = struct {
    info: ModInfo,
    state: ModState,
    load_order: u32,
    error_message: ?[]const u8,

    // Hooks
    assets_path: ?[]const u8,
    scripts_path: ?[]const u8,
    data_path: ?[]const u8,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, info: ModInfo) !*LoadedMod {
        const self = try allocator.create(LoadedMod);
        self.* = LoadedMod{
            .info = info,
            .state = .unloaded,
            .load_order = 0,
            .error_message = null,
            .assets_path = null,
            .scripts_path = null,
            .data_path = null,
            .allocator = allocator,
        };
        return self;
    }

    pub fn deinit(self: *LoadedMod) void {
        self.allocator.destroy(self);
    }
};

// ============================================================================
// Mod Event System
// ============================================================================

pub const ModEvent = enum {
    mod_loaded,
    mod_unloaded,
    mod_enabled,
    mod_disabled,
    mod_error,
    mods_reloaded,
};

pub const ModEventCallback = *const fn (ModEvent, ?*const ModInfo) void;

// ============================================================================
// Mod Manager
// ============================================================================

pub const ModManager = struct {
    allocator: std.mem.Allocator,
    mods: std.StringHashMap(*LoadedMod),
    load_order: std.ArrayList(*LoadedMod),
    mods_directory: []const u8,
    event_listeners: std.ArrayList(ModEventCallback),
    game_version: SemanticVersion,

    pub fn init(allocator: std.mem.Allocator) !*ModManager {
        const self = try allocator.create(ModManager);
        self.* = ModManager{
            .allocator = allocator,
            .mods = std.StringHashMap(*LoadedMod).init(allocator),
            .load_order = .{},
            .mods_directory = "mods",
            .event_listeners = .{},
            .game_version = .{ .major = 1, .minor = 0, .patch = 0 },
        };
        return self;
    }

    pub fn deinit(self: *ModManager) void {
        var iter = self.mods.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        self.mods.deinit();
        self.load_order.deinit(self.allocator);
        self.event_listeners.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn setModsDirectory(self: *ModManager, path: []const u8) void {
        self.mods_directory = path;
    }

    pub fn setGameVersion(self: *ModManager, version: SemanticVersion) void {
        self.game_version = version;
    }

    pub fn addEventListener(self: *ModManager, callback: ModEventCallback) !void {
        try self.event_listeners.append(self.allocator, callback);
    }

    fn emitEvent(self: *ModManager, event: ModEvent, mod_info: ?*const ModInfo) void {
        for (self.event_listeners.items) |callback| {
            callback(event, mod_info);
        }
    }

    pub fn discoverMods(self: *ModManager) !void {
        // In a real implementation, this would scan the mods directory
        // for mod.json files and parse them
        _ = self;
    }

    pub fn registerMod(self: *ModManager, info: ModInfo) !void {
        const mod = try LoadedMod.init(self.allocator, info);
        try self.mods.put(info.id, mod);
    }

    pub fn getMod(self: *const ModManager, mod_id: []const u8) ?*LoadedMod {
        return self.mods.get(mod_id);
    }

    pub fn enableMod(self: *ModManager, mod_id: []const u8) !void {
        if (self.mods.get(mod_id)) |mod| {
            // Check dependencies
            if (!try self.checkDependencies(mod)) {
                mod.state = .error_state;
                mod.error_message = "Missing dependencies";
                return error.MissingDependencies;
            }

            // Check conflicts
            if (self.hasConflicts(mod)) {
                mod.state = .error_state;
                mod.error_message = "Conflicting mods enabled";
                return error.ConflictingMods;
            }

            mod.info.enabled = true;
            mod.state = .loaded;
            self.emitEvent(.mod_enabled, &mod.info);
        }
    }

    pub fn disableMod(self: *ModManager, mod_id: []const u8) void {
        if (self.mods.get(mod_id)) |mod| {
            mod.info.enabled = false;
            mod.state = .disabled;
            self.emitEvent(.mod_disabled, &mod.info);
        }
    }

    pub fn loadMod(self: *ModManager, mod_id: []const u8) !void {
        if (self.mods.get(mod_id)) |mod| {
            mod.state = .loading;

            // Would load mod assets and scripts here

            mod.state = .loaded;
            try self.load_order.append(mod);
            self.emitEvent(.mod_loaded, &mod.info);
        }
    }

    pub fn unloadMod(self: *ModManager, mod_id: []const u8) void {
        if (self.mods.get(mod_id)) |mod| {
            mod.state = .unloaded;

            // Remove from load order
            var i: usize = 0;
            while (i < self.load_order.items.len) {
                if (std.mem.eql(u8, self.load_order.items[i].info.id, mod_id)) {
                    _ = self.load_order.orderedRemove(i);
                } else {
                    i += 1;
                }
            }

            self.emitEvent(.mod_unloaded, &mod.info);
        }
    }

    pub fn reloadAllMods(self: *ModManager) !void {
        // Unload all
        for (self.load_order.items) |mod| {
            mod.state = .unloaded;
        }
        self.load_order.clearRetainingCapacity();

        // Reload enabled mods in order
        var mods_to_load = std.ArrayList(*LoadedMod).init(self.allocator);
        defer mods_to_load.deinit();

        var iter = self.mods.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.*.info.enabled) {
                try mods_to_load.append(entry.value_ptr.*);
            }
        }

        // Sort by load priority
        std.mem.sort(*LoadedMod, mods_to_load.items, {}, struct {
            fn lessThan(_: void, a: *LoadedMod, b: *LoadedMod) bool {
                return a.info.load_priority < b.info.load_priority;
            }
        }.lessThan);

        // Load in order
        for (mods_to_load.items) |mod| {
            try self.loadMod(mod.info.id);
        }

        self.emitEvent(.mods_reloaded, null);
    }

    fn checkDependencies(self: *ModManager, mod: *LoadedMod) !bool {
        for (mod.info.dependencies) |dep| {
            if (self.mods.get(dep.mod_id)) |dep_mod| {
                if (!dep_mod.info.enabled and !dep.optional) {
                    return false;
                }
                if (dep.min_version) |min| {
                    if (dep_mod.info.version.compare(min) == .lt) {
                        return false;
                    }
                }
            } else if (!dep.optional) {
                return false;
            }
        }
        return true;
    }

    fn hasConflicts(self: *ModManager, mod: *LoadedMod) bool {
        for (mod.info.conflicts) |conflict_id| {
            if (self.mods.get(conflict_id)) |conflict_mod| {
                if (conflict_mod.info.enabled) {
                    return true;
                }
            }
        }
        return false;
    }

    pub fn getEnabledMods(self: *ModManager) ![]*LoadedMod {
        var result = std.ArrayList(*LoadedMod).init(self.allocator);
        errdefer result.deinit();

        var iter = self.mods.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.*.info.enabled) {
                try result.append(entry.value_ptr.*);
            }
        }

        return result.toOwnedSlice();
    }

    pub fn getLoadOrder(self: *const ModManager) []*LoadedMod {
        return self.load_order.items;
    }
};

// ============================================================================
// Mod Asset Override System
// ============================================================================

pub const AssetOverride = struct {
    mod_id: []const u8,
    original_path: []const u8,
    override_path: []const u8,
    priority: i32,
};

pub const AssetOverrideManager = struct {
    allocator: std.mem.Allocator,
    overrides: std.StringHashMap(std.ArrayList(AssetOverride)),

    pub fn init(allocator: std.mem.Allocator) AssetOverrideManager {
        return AssetOverrideManager{
            .allocator = allocator,
            .overrides = std.StringHashMap(std.ArrayList(AssetOverride)).init(allocator),
        };
    }

    pub fn deinit(self: *AssetOverrideManager) void {
        var iter = self.overrides.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.overrides.deinit();
    }

    pub fn registerOverride(self: *AssetOverrideManager, override: AssetOverride) !void {
        const result = try self.overrides.getOrPut(override.original_path);
        if (!result.found_existing) {
            result.value_ptr.* = .{};
        }
        try result.value_ptr.append(self.allocator, override);
    }

    pub fn getOverridePath(self: *const AssetOverrideManager, original_path: []const u8) ?[]const u8 {
        if (self.overrides.get(original_path)) |override_list| {
            if (override_list.items.len > 0) {
                // Return highest priority override
                var best: ?*const AssetOverride = null;
                var best_priority: i32 = std.math.minInt(i32);

                for (override_list.items) |*override| {
                    if (override.priority > best_priority) {
                        best_priority = override.priority;
                        best = override;
                    }
                }

                if (best) |b| {
                    return b.override_path;
                }
            }
        }
        return null;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "SemanticVersion comparison" {
    const v1 = SemanticVersion{ .major = 1, .minor = 0, .patch = 0 };
    const v2 = SemanticVersion{ .major = 1, .minor = 1, .patch = 0 };
    const v3 = SemanticVersion{ .major = 2, .minor = 0, .patch = 0 };

    try std.testing.expectEqual(std.math.Order.lt, v1.compare(v2));
    try std.testing.expectEqual(std.math.Order.lt, v2.compare(v3));
    try std.testing.expectEqual(std.math.Order.eq, v1.compare(v1));
}

test "SemanticVersion compatibility" {
    const game = SemanticVersion{ .major = 1, .minor = 2, .patch = 0 };
    const mod1 = SemanticVersion{ .major = 1, .minor = 1, .patch = 0 };
    const mod2 = SemanticVersion{ .major = 2, .minor = 0, .patch = 0 };

    try std.testing.expect(game.isCompatible(mod1));
    try std.testing.expect(!game.isCompatible(mod2));
}

test "ModManager" {
    var manager = try ModManager.init(std.testing.allocator);
    defer manager.deinit();

    try manager.registerMod(.{
        .id = "test_mod",
        .name = "Test Mod",
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .author = "Test",
        .description = "A test mod",
        .dependencies = &[_]Dependency{},
        .conflicts = &[_][]const u8{},
        .load_priority = 0,
        .enabled = false,
        .path = "mods/test_mod",
    });

    const mod = manager.getMod("test_mod");
    try std.testing.expect(mod != null);
    try std.testing.expectEqualStrings("Test Mod", mod.?.info.name);
}

test "AssetOverrideManager" {
    var override_manager = AssetOverrideManager.init(std.testing.allocator);
    defer override_manager.deinit();

    try override_manager.registerOverride(.{
        .mod_id = "test",
        .original_path = "textures/player.png",
        .override_path = "mods/test/textures/player.png",
        .priority = 10,
    });

    const override = override_manager.getOverridePath("textures/player.png");
    try std.testing.expect(override != null);
    try std.testing.expectEqualStrings("mods/test/textures/player.png", override.?);
}
