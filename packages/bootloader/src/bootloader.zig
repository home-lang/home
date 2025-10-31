// Home OS Bootloader
// UEFI-based bootloader with secure boot support

const std = @import("std");

pub const uefi = @import("uefi.zig");
pub const config = @import("config.zig");
pub const loader = @import("loader.zig");
pub const secure = @import("secure.zig");
pub const menu = @import("menu.zig");

/// Bootloader version
pub const VERSION = "1.0.0";

/// Boot protocol
pub const BootProtocol = enum {
    uefi, // UEFI boot
    bios, // Legacy BIOS (not implemented)
    multiboot, // Multiboot specification
};

/// Boot stage
pub const BootStage = enum {
    firmware, // Firmware stage (UEFI)
    bootloader, // Bootloader stage
    kernel, // Kernel stage
    panic, // Boot failure
};

/// Boot status
pub const BootStatus = struct {
    stage: BootStage,
    protocol: BootProtocol,
    secure_boot_enabled: bool,
    last_error: ?BootError,

    pub fn init() BootStatus {
        return .{
            .stage = .firmware,
            .protocol = .uefi,
            .secure_boot_enabled = false,
            .last_error = null,
        };
    }
};

/// Boot errors
pub const BootError = error{
    FirmwareError,
    ConfigNotFound,
    KernelNotFound,
    InvalidKernel,
    VerificationFailed,
    OutOfMemory,
    FileSystemError,
    SecureBootRequired,
};

/// Boot entry (kernel + initrd + options)
pub const BootEntry = struct {
    name: [64]u8,
    name_len: usize,
    kernel_path: [256]u8,
    kernel_path_len: usize,
    initrd_path: [256]u8,
    initrd_path_len: usize,
    cmdline: [512]u8,
    cmdline_len: usize,
    default: bool,

    pub fn init(name: []const u8) BootEntry {
        var entry: BootEntry = undefined;

        @memset(&entry.name, 0);
        @memcpy(entry.name[0..name.len], name);
        entry.name_len = name.len;

        @memset(&entry.kernel_path, 0);
        entry.kernel_path_len = 0;

        @memset(&entry.initrd_path, 0);
        entry.initrd_path_len = 0;

        @memset(&entry.cmdline, 0);
        entry.cmdline_len = 0;

        entry.default = false;

        return entry;
    }

    pub fn getName(self: *const BootEntry) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn getKernelPath(self: *const BootEntry) []const u8 {
        return self.kernel_path[0..self.kernel_path_len];
    }

    pub fn getInitrdPath(self: *const BootEntry) []const u8 {
        return self.initrd_path[0..self.initrd_path_len];
    }

    pub fn getCmdline(self: *const BootEntry) []const u8 {
        return self.cmdline[0..self.cmdline_len];
    }

    pub fn setKernelPath(self: *BootEntry, path: []const u8) void {
        @memcpy(self.kernel_path[0..path.len], path);
        self.kernel_path_len = path.len;
    }

    pub fn setInitrdPath(self: *BootEntry, path: []const u8) void {
        @memcpy(self.initrd_path[0..path.len], path);
        self.initrd_path_len = path.len;
    }

    pub fn setCmdline(self: *BootEntry, cmdline: []const u8) void {
        @memcpy(self.cmdline[0..cmdline.len], cmdline);
        self.cmdline_len = cmdline.len;
    }
};

/// Boot configuration
pub const BootConfig = struct {
    entries: std.ArrayList(BootEntry),
    timeout_seconds: u32,
    default_entry: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) BootConfig {
        return .{
            .entries = std.ArrayList(BootEntry){},
            .timeout_seconds = 5,
            .default_entry = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BootConfig) void {
        self.entries.deinit(self.allocator);
    }

    pub fn addEntry(self: *BootConfig, entry: BootEntry) !void {
        try self.entries.append(self.allocator, entry);
    }

    pub fn getEntry(self: *BootConfig, index: usize) ?*BootEntry {
        if (index >= self.entries.items.len) return null;
        return &self.entries.items[index];
    }

    pub fn getEntryByName(self: *BootConfig, name: []const u8) ?*BootEntry {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.getName(), name)) {
                return entry;
            }
        }
        return null;
    }

    pub fn getEntryCount(self: *const BootConfig) usize {
        return self.entries.items.len;
    }
};

/// Bootloader context
pub const Bootloader = struct {
    config: BootConfig,
    status: BootStatus,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Bootloader {
        return .{
            .config = BootConfig.init(allocator),
            .status = BootStatus.init(),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Bootloader) void {
        self.config.deinit();
    }

    pub fn loadConfig(self: *Bootloader, config_path: []const u8) !void {
        _ = config_path;
        // In production, would parse configuration file
        // For now, create default entries

        var entry = BootEntry.init("Home OS");
        entry.setKernelPath("/boot/home-kernel");
        entry.setInitrdPath("/boot/initrd.img");
        entry.setCmdline("root=/dev/sda1 quiet splash");
        entry.default = true;

        try self.config.addEntry(entry);

        var recovery = BootEntry.init("Home OS (Recovery)");
        recovery.setKernelPath("/boot/home-kernel");
        recovery.setInitrdPath("/boot/initrd.img");
        recovery.setCmdline("root=/dev/sda1 single");

        try self.config.addEntry(recovery);
    }

    pub fn boot(self: *Bootloader, entry_index: usize) !void {
        const entry = self.config.getEntry(entry_index) orelse return error.InvalidEntry;

        self.status.stage = .bootloader;

        // In production, would:
        // 1. Verify signature if secure boot enabled
        // 2. Load kernel into memory
        // 3. Setup boot protocol
        // 4. Transfer control to kernel

        _ = entry;
        self.status.stage = .kernel;
    }
};

test "boot entry" {
    const testing = std.testing;

    var entry = BootEntry.init("Test Entry");
    entry.setKernelPath("/boot/vmlinuz");
    entry.setInitrdPath("/boot/initrd");
    entry.setCmdline("quiet splash");

    try testing.expectEqualStrings("Test Entry", entry.getName());
    try testing.expectEqualStrings("/boot/vmlinuz", entry.getKernelPath());
    try testing.expectEqualStrings("/boot/initrd", entry.getInitrdPath());
    try testing.expectEqualStrings("quiet splash", entry.getCmdline());
}

test "boot configuration" {
    const testing = std.testing;

    var boot_config = BootConfig.init(testing.allocator);
    defer boot_config.deinit();

    var entry1 = BootEntry.init("Entry 1");
    entry1.setKernelPath("/boot/kernel1");

    var entry2 = BootEntry.init("Entry 2");
    entry2.setKernelPath("/boot/kernel2");

    try boot_config.addEntry(entry1);
    try boot_config.addEntry(entry2);

    try testing.expectEqual(@as(usize, 2), boot_config.getEntryCount());

    const retrieved = boot_config.getEntry(0);
    try testing.expect(retrieved != null);
    try testing.expectEqualStrings("Entry 1", retrieved.?.getName());

    const by_name = boot_config.getEntryByName("Entry 2");
    try testing.expect(by_name != null);
    try testing.expectEqualStrings("/boot/kernel2", by_name.?.getKernelPath());
}

test "bootloader initialization" {
    const testing = std.testing;

    var bootloader = Bootloader.init(testing.allocator);
    defer bootloader.deinit();

    try testing.expectEqual(BootStage.firmware, bootloader.status.stage);
    try testing.expectEqual(BootProtocol.uefi, bootloader.status.protocol);
}

test "load default config" {
    const testing = std.testing;

    var bootloader = Bootloader.init(testing.allocator);
    defer bootloader.deinit();

    try bootloader.loadConfig("/boot/bootloader.conf");

    try testing.expectEqual(@as(usize, 2), bootloader.config.getEntryCount());

    const first = bootloader.config.getEntry(0);
    try testing.expect(first != null);
    try testing.expectEqualStrings("Home OS", first.?.getName());
}
