// Boot Configuration Parser
// Parse bootloader configuration files

const std = @import("std");
const bootloader = @import("bootloader.zig");

/// Configuration format
pub const ConfigFormat = enum {
    home_os, // Native Home OS format
    grub2, // GRUB2 configuration
    systemd_boot, // systemd-boot entries
};

/// Configuration parser
pub const ConfigParser = struct {
    allocator: std.mem.Allocator,
    format: ConfigFormat,

    pub fn init(allocator: std.mem.Allocator, format: ConfigFormat) ConfigParser {
        return .{
            .allocator = allocator,
            .format = format,
        };
    }

    /// Parse configuration from string
    pub fn parse(self: *ConfigParser, content: []const u8) !bootloader.BootConfig {
        return switch (self.format) {
            .home_os => try self.parseHomeOS(content),
            .grub2 => try self.parseGrub2(content),
            .systemd_boot => try self.parseSystemdBoot(content),
        };
    }

    /// Parse Home OS native format
    fn parseHomeOS(self: *ConfigParser, content: []const u8) !bootloader.BootConfig {
        var config = bootloader.BootConfig.init(self.allocator);
        errdefer config.deinit();

        var lines = std.mem.splitScalar(u8, content, '\n');
        var current_entry: ?bootloader.BootEntry = null;

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");

            // Skip empty lines and comments
            if (trimmed.len == 0 or trimmed[0] == '#') {
                continue;
            }

            // Parse directives
            if (std.mem.startsWith(u8, trimmed, "timeout")) {
                const timeout_str = std.mem.trim(u8, trimmed[7..], " \t=");
                config.timeout_seconds = try std.fmt.parseInt(u32, timeout_str, 10);
            } else if (std.mem.startsWith(u8, trimmed, "default")) {
                const default_str = std.mem.trim(u8, trimmed[7..], " \t=");
                config.default_entry = try std.fmt.parseInt(usize, default_str, 10);
            } else if (std.mem.startsWith(u8, trimmed, "entry")) {
                // Save previous entry
                if (current_entry) |entry| {
                    try config.addEntry(entry);
                }

                // Start new entry
                const name_start = std.mem.indexOf(u8, trimmed, "\"") orelse continue;
                const name_end = std.mem.lastIndexOf(u8, trimmed, "\"") orelse continue;

                if (name_end <= name_start + 1) continue;

                const name = trimmed[name_start + 1 .. name_end];
                current_entry = bootloader.BootEntry.init(name);
            } else if (std.mem.startsWith(u8, trimmed, "kernel")) {
                if (current_entry) |*entry| {
                    const path = std.mem.trim(u8, trimmed[6..], " \t=");
                    entry.setKernelPath(path);
                }
            } else if (std.mem.startsWith(u8, trimmed, "initrd")) {
                if (current_entry) |*entry| {
                    const path = std.mem.trim(u8, trimmed[6..], " \t=");
                    entry.setInitrdPath(path);
                }
            } else if (std.mem.startsWith(u8, trimmed, "options")) {
                if (current_entry) |*entry| {
                    const options = std.mem.trim(u8, trimmed[7..], " \t=");
                    entry.setCmdline(options);
                }
            }
        }

        // Add final entry
        if (current_entry) |entry| {
            try config.addEntry(entry);
        }

        return config;
    }

    /// Parse GRUB2 configuration (simplified)
    fn parseGrub2(self: *ConfigParser, content: []const u8) !bootloader.BootConfig {
        var config = bootloader.BootConfig.init(self.allocator);
        errdefer config.deinit();

        var lines = std.mem.splitScalar(u8, content, '\n');
        var current_entry: ?bootloader.BootEntry = null;
        var in_menuentry = false;

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");

            if (trimmed.len == 0 or trimmed[0] == '#') {
                continue;
            }

            // Parse GRUB timeout
            if (std.mem.startsWith(u8, trimmed, "GRUB_TIMEOUT=")) {
                const timeout_str = trimmed[13..];
                config.timeout_seconds = try std.fmt.parseInt(u32, timeout_str, 10);
            }
            // Parse menu entry
            else if (std.mem.startsWith(u8, trimmed, "menuentry")) {
                // Save previous entry
                if (current_entry) |entry| {
                    try config.addEntry(entry);
                }

                // Extract entry name
                const name_start = std.mem.indexOf(u8, trimmed, "'") orelse
                    std.mem.indexOf(u8, trimmed, "\"") orelse continue;
                const quote_char = trimmed[name_start];
                const name_end = std.mem.indexOfPos(u8, trimmed, name_start + 1, &[_]u8{quote_char}) orelse continue;

                const name = trimmed[name_start + 1 .. name_end];
                current_entry = bootloader.BootEntry.init(name);
                in_menuentry = true;
            }
            // Parse linux kernel
            else if (in_menuentry and std.mem.indexOf(u8, trimmed, "linux") != null) {
                const linux_pos = std.mem.indexOf(u8, trimmed, "linux").?;
                if (current_entry) |*entry| {
                    // Find kernel path
                    var parts = std.mem.tokenizeAny(u8, trimmed[linux_pos + 5 ..], " \t");

                    if (parts.next()) |kernel_path| {
                        entry.setKernelPath(kernel_path);

                        // Collect remaining as command line options
                        var cmdline_buf: [512]u8 = undefined;
                        var cmdline_len: usize = 0;

                        while (parts.next()) |arg| {
                            if (cmdline_len + arg.len + 1 < cmdline_buf.len) {
                                if (cmdline_len > 0) {
                                    cmdline_buf[cmdline_len] = ' ';
                                    cmdline_len += 1;
                                }
                                @memcpy(cmdline_buf[cmdline_len .. cmdline_len + arg.len], arg);
                                cmdline_len += arg.len;
                            }
                        }

                        if (cmdline_len > 0) {
                            entry.setCmdline(cmdline_buf[0..cmdline_len]);
                        }
                    }
                }
            }
            // Parse initrd
            else if (in_menuentry and std.mem.indexOf(u8, trimmed, "initrd") != null) {
                const initrd_pos = std.mem.indexOf(u8, trimmed, "initrd").?;
                if (current_entry) |*entry| {
                    var parts = std.mem.tokenizeAny(u8, trimmed[initrd_pos + 6 ..], " \t");
                    if (parts.next()) |initrd_path| {
                        entry.setInitrdPath(initrd_path);
                    }
                }
            }
            // End of menuentry
            else if (in_menuentry and trimmed[0] == '}') {
                in_menuentry = false;
            }
        }

        // Add final entry
        if (current_entry) |entry| {
            try config.addEntry(entry);
        }

        return config;
    }

    /// Parse systemd-boot configuration
    fn parseSystemdBoot(self: *ConfigParser, content: []const u8) !bootloader.BootConfig {
        var config = bootloader.BootConfig.init(self.allocator);
        errdefer config.deinit();

        var lines = std.mem.splitScalar(u8, content, '\n');
        var current_entry: ?bootloader.BootEntry = null;

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");

            if (trimmed.len == 0 or trimmed[0] == '#') {
                continue;
            }

            // Parse timeout
            if (std.mem.startsWith(u8, trimmed, "timeout")) {
                const timeout_str = std.mem.trim(u8, trimmed[7..], " \t");
                config.timeout_seconds = try std.fmt.parseInt(u32, timeout_str, 10);
            }
            // Parse title
            else if (std.mem.startsWith(u8, trimmed, "title")) {
                // Save previous entry
                if (current_entry) |entry| {
                    try config.addEntry(entry);
                }

                const title = std.mem.trim(u8, trimmed[5..], " \t");
                current_entry = bootloader.BootEntry.init(title);
            }
            // Parse linux kernel
            else if (std.mem.startsWith(u8, trimmed, "linux")) {
                if (current_entry) |*entry| {
                    const path = std.mem.trim(u8, trimmed[5..], " \t");
                    entry.setKernelPath(path);
                }
            }
            // Parse initrd
            else if (std.mem.startsWith(u8, trimmed, "initrd")) {
                if (current_entry) |*entry| {
                    const path = std.mem.trim(u8, trimmed[6..], " \t");
                    entry.setInitrdPath(path);
                }
            }
            // Parse options
            else if (std.mem.startsWith(u8, trimmed, "options")) {
                if (current_entry) |*entry| {
                    const options = std.mem.trim(u8, trimmed[7..], " \t");
                    entry.setCmdline(options);
                }
            }
        }

        // Add final entry
        if (current_entry) |entry| {
            try config.addEntry(entry);
        }

        return config;
    }

    /// Serialize configuration to Home OS format
    pub fn serialize(self: *ConfigParser, config: *const bootloader.BootConfig) ![]u8 {
        var output = std.ArrayList(u8){};
        errdefer output.deinit(self.allocator);

        const writer = output.writer(self.allocator);

        // Write header
        try writer.writeAll("# Home OS Bootloader Configuration\n\n");

        // Write global settings
        try writer.print("timeout = {d}\n", .{config.timeout_seconds});
        try writer.print("default = {d}\n\n", .{config.default_entry});

        // Write entries
        for (config.entries.items, 0..) |*entry, i| {
            try writer.print("# Entry {d}\n", .{i});
            try writer.print("entry \"{s}\"\n", .{entry.getName()});
            try writer.print("  kernel = {s}\n", .{entry.getKernelPath()});

            if (entry.getInitrdPath().len > 0) {
                try writer.print("  initrd = {s}\n", .{entry.getInitrdPath()});
            }

            if (entry.getCmdline().len > 0) {
                try writer.print("  options = {s}\n", .{entry.getCmdline()});
            }

            try writer.writeAll("\n");
        }

        return output.toOwnedSlice(self.allocator);
    }
};

/// Configuration file locations
pub const ConfigLocation = struct {
    pub const HOME_OS_CONFIG = "/boot/home.conf";
    pub const GRUB2_CONFIG = "/boot/grub/grub.cfg";
    pub const SYSTEMD_BOOT_CONFIG = "/boot/loader/entries/*.conf";
};

/// Auto-detect configuration format
pub fn detectFormat(path: []const u8) ConfigFormat {
    if (std.mem.endsWith(u8, path, "grub.cfg")) {
        return .grub2;
    } else if (std.mem.indexOf(u8, path, "loader/entries") != null) {
        return .systemd_boot;
    } else {
        return .home_os;
    }
}

test "parse home os config" {
    const testing = std.testing;

    const config_content =
        \\# Home OS Configuration
        \\timeout = 10
        \\default = 0
        \\
        \\entry "Home OS"
        \\  kernel = /boot/vmlinuz-home
        \\  initrd = /boot/initrd.img
        \\  options = root=/dev/sda1 quiet splash
        \\
        \\entry "Home OS (Recovery)"
        \\  kernel = /boot/vmlinuz-home
        \\  options = root=/dev/sda1 single
    ;

    var parser = ConfigParser.init(testing.allocator, .home_os);
    var config = try parser.parse(config_content);
    defer config.deinit();

    try testing.expectEqual(@as(u32, 10), config.timeout_seconds);
    try testing.expectEqual(@as(usize, 0), config.default_entry);
    try testing.expectEqual(@as(usize, 2), config.getEntryCount());

    const entry1 = config.getEntry(0).?;
    try testing.expectEqualStrings("Home OS", entry1.getName());
    try testing.expectEqualStrings("/boot/vmlinuz-home", entry1.getKernelPath());
    try testing.expectEqualStrings("/boot/initrd.img", entry1.getInitrdPath());
    try testing.expectEqualStrings("root=/dev/sda1 quiet splash", entry1.getCmdline());
}

test "parse grub2 config" {
    const testing = std.testing;

    const config_content =
        \\GRUB_TIMEOUT=5
        \\
        \\menuentry 'Ubuntu Linux' {
        \\    linux /boot/vmlinuz root=/dev/sda1 ro quiet
        \\    initrd /boot/initrd.img
        \\}
        \\
        \\menuentry 'Recovery Mode' {
        \\    linux /boot/vmlinuz root=/dev/sda1 single
        \\}
    ;

    var parser = ConfigParser.init(testing.allocator, .grub2);
    var config = try parser.parse(config_content);
    defer config.deinit();

    try testing.expectEqual(@as(u32, 5), config.timeout_seconds);
    try testing.expectEqual(@as(usize, 2), config.getEntryCount());

    const entry1 = config.getEntry(0).?;
    try testing.expectEqualStrings("Ubuntu Linux", entry1.getName());
    try testing.expectEqualStrings("/boot/vmlinuz", entry1.getKernelPath());
    try testing.expectEqualStrings("/boot/initrd.img", entry1.getInitrdPath());
}

test "parse systemd-boot config" {
    const testing = std.testing;

    const config_content =
        \\timeout 3
        \\
        \\title Home OS
        \\linux /vmlinuz-linux
        \\initrd /initramfs-linux.img
        \\options root=/dev/sda2 rw quiet
        \\
        \\title Home OS (Fallback)
        \\linux /vmlinuz-linux
        \\initrd /initramfs-linux-fallback.img
        \\options root=/dev/sda2 rw
    ;

    var parser = ConfigParser.init(testing.allocator, .systemd_boot);
    var config = try parser.parse(config_content);
    defer config.deinit();

    try testing.expectEqual(@as(u32, 3), config.timeout_seconds);
    try testing.expectEqual(@as(usize, 2), config.getEntryCount());

    const entry1 = config.getEntry(0).?;
    try testing.expectEqualStrings("Home OS", entry1.getName());
    try testing.expectEqualStrings("/vmlinuz-linux", entry1.getKernelPath());
    try testing.expectEqualStrings("/initramfs-linux.img", entry1.getInitrdPath());
    try testing.expectEqualStrings("root=/dev/sda2 rw quiet", entry1.getCmdline());
}

test "serialize config" {
    const testing = std.testing;

    var config = bootloader.BootConfig.init(testing.allocator);
    defer config.deinit();

    config.timeout_seconds = 5;
    config.default_entry = 0;

    var entry = bootloader.BootEntry.init("Test OS");
    entry.setKernelPath("/boot/kernel");
    entry.setInitrdPath("/boot/initrd");
    entry.setCmdline("root=/dev/sda1");

    try config.addEntry(entry);

    var parser = ConfigParser.init(testing.allocator, .home_os);
    const serialized = try parser.serialize(&config);
    defer testing.allocator.free(serialized);

    try testing.expect(std.mem.indexOf(u8, serialized, "timeout = 5") != null);
    try testing.expect(std.mem.indexOf(u8, serialized, "entry \"Test OS\"") != null);
    try testing.expect(std.mem.indexOf(u8, serialized, "kernel = /boot/kernel") != null);
}

test "detect format" {
    const testing = std.testing;

    try testing.expectEqual(ConfigFormat.grub2, detectFormat("/boot/grub/grub.cfg"));
    try testing.expectEqual(ConfigFormat.systemd_boot, detectFormat("/boot/loader/entries/home.conf"));
    try testing.expectEqual(ConfigFormat.home_os, detectFormat("/boot/home.conf"));
}
