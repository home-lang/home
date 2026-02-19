const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");

const Color = enum {
    Reset,
    Red,
    Green,
    Yellow,
    Blue,
    Magenta,
    Cyan,

    fn code(self: Color) []const u8 {
        return switch (self) {
            .Reset => "\x1b[0m",
            .Red => "\x1b[31m",
            .Green => "\x1b[32m",
            .Yellow => "\x1b[33m",
            .Blue => "\x1b[34m",
            .Magenta => "\x1b[35m",
            .Cyan => "\x1b[36m",
        };
    }
};

/// Package format
pub const PackageFormat = enum {
    tarball, // .tar.gz
    zip, // .zip
    deb, // Debian package
    rpm, // RedHat package
    dmg, // macOS disk image
    msi, // Windows installer
    appimage, // Linux AppImage

    pub fn extension(self: PackageFormat) []const u8 {
        return switch (self) {
            .tarball => ".tar.gz",
            .zip => ".zip",
            .deb => ".deb",
            .rpm => ".rpm",
            .dmg => ".dmg",
            .msi => ".msi",
            .appimage => ".AppImage",
        };
    }

    pub fn fromString(str: []const u8) ?PackageFormat {
        const formats = [_]struct { name: []const u8, fmt: PackageFormat }{
            .{ .name = "tarball", .fmt = .tarball },
            .{ .name = "tar.gz", .fmt = .tarball },
            .{ .name = "zip", .fmt = .zip },
            .{ .name = "deb", .fmt = .deb },
            .{ .name = "rpm", .fmt = .rpm },
            .{ .name = "dmg", .fmt = .dmg },
            .{ .name = "msi", .fmt = .msi },
            .{ .name = "appimage", .fmt = .appimage },
        };

        for (formats) |f| {
            if (std.mem.eql(u8, str, f.name)) {
                return f.fmt;
            }
        }
        return null;
    }

    pub fn defaultForCurrentOS() PackageFormat {
        return switch (builtin.os.tag) {
            .linux => .tarball,
            .macos => .dmg,
            .windows => .zip,
            else => .tarball,
        };
    }
};

/// Package configuration loaded from package.toml or home.toml
pub const PackageConfig = struct {
    name: []const u8,
    version: []const u8,
    description: []const u8,
    author: []const u8,
    license: []const u8,
    homepage: ?[]const u8 = null,
    binary: ?[]const u8 = null,
    icon: ?[]const u8 = null,
    files: std.ArrayList(FileEntry),
    dependencies: std.ArrayList([]const u8),

    pub const FileEntry = struct {
        source: []const u8,
        destination: []const u8,
    };

    pub fn deinit(self: *PackageConfig, allocator: std.mem.Allocator) void {
        self.files.deinit(allocator);
        self.dependencies.deinit(allocator);
    }
};

/// Parse a simple TOML-like config file
fn parseConfig(allocator: std.mem.Allocator, content: []const u8) !PackageConfig {
    var config = PackageConfig{
        .name = "app",
        .version = "1.0.0",
        .description = "",
        .author = "",
        .license = "MIT",
        .files = std.ArrayList(PackageConfig.FileEntry){},
        .dependencies = std.ArrayList([]const u8){},
    };

    var lines = std.mem.splitScalar(u8, content, '\n');
    var in_package_section = false;
    var in_files_section = false;
    var in_deps_section = false;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        // Skip empty lines and comments
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        // Check for section headers
        if (trimmed[0] == '[') {
            in_package_section = std.mem.eql(u8, trimmed, "[package]");
            in_files_section = std.mem.eql(u8, trimmed, "[package.files]") or std.mem.eql(u8, trimmed, "[files]");
            in_deps_section = std.mem.eql(u8, trimmed, "[package.dependencies]") or std.mem.eql(u8, trimmed, "[dependencies]");
            continue;
        }

        // Parse key-value pairs
        if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq_pos| {
            const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
            var value = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");

            // Remove quotes
            if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
                value = value[1 .. value.len - 1];
            }

            if (in_package_section) {
                if (std.mem.eql(u8, key, "name")) {
                    config.name = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "version")) {
                    config.version = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "description")) {
                    config.description = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "author") or std.mem.eql(u8, key, "authors")) {
                    config.author = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "license")) {
                    config.license = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "homepage")) {
                    config.homepage = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "binary")) {
                    config.binary = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "icon")) {
                    config.icon = try allocator.dupe(u8, value);
                }
            } else if (in_files_section) {
                try config.files.append(allocator, .{
                    .source = try allocator.dupe(u8, key),
                    .destination = try allocator.dupe(u8, value),
                });
            } else if (in_deps_section) {
                try config.dependencies.append(allocator, try allocator.dupe(u8, key));
            }
        }
    }

    return config;
}

/// Build a tarball package
fn buildTarball(allocator: std.mem.Allocator, config: *const PackageConfig, output_dir: []const u8, io: Io) ![]const u8 {
    const cwd = Io.Dir.cwd();
    const pkg_name = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ config.name, config.version });
    defer allocator.free(pkg_name);

    const output_path = try std.fmt.allocPrint(allocator, "{s}/{s}.tar.gz", .{ output_dir, pkg_name });

    // Create staging directory
    const staging_dir = try std.fmt.allocPrint(allocator, "{s}/.staging-{s}", .{ output_dir, pkg_name });
    defer allocator.free(staging_dir);

    cwd.createDir(io, staging_dir, .default_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Create package subdirectory
    const pkg_subdir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ staging_dir, pkg_name });
    defer allocator.free(pkg_subdir);

    cwd.createDir(io, pkg_subdir, .default_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Copy files to staging
    if (config.binary) |binary| {
        const dest = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pkg_subdir, std.fs.path.basename(binary) });
        defer allocator.free(dest);
        try cwd.copyFile(binary, cwd, dest, io, .{});
    }

    for (config.files.items) |file| {
        const dest = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pkg_subdir, file.destination });
        defer allocator.free(dest);
        cwd.copyFile(file.source, cwd, dest, io, .{}) catch |err| {
            std.debug.print("{s}Warning:{s} Could not copy {s}: {}\n", .{ Color.Yellow.code(), Color.Reset.code(), file.source, err });
        };
    }

    // Create tarball using system tar
    const tar_result = try std.process.run(allocator, io, .{
        .argv = &[_][]const u8{
            "tar", "-czf",      output_path,
            "-C",  staging_dir, pkg_name,
        },
    });
    defer allocator.free(tar_result.stdout);
    defer allocator.free(tar_result.stderr);

    if (tar_result.term.exited != 0) {
        std.debug.print("{s}Error:{s} tar failed: {s}\n", .{ Color.Red.code(), Color.Reset.code(), tar_result.stderr });
        return error.TarFailed;
    }

    // Clean up staging
    cwd.deleteTree(io, staging_dir) catch {};

    return output_path;
}

/// Build a zip package
fn buildZip(allocator: std.mem.Allocator, config: *const PackageConfig, output_dir: []const u8, io: Io) ![]const u8 {
    const cwd = Io.Dir.cwd();
    const pkg_name = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ config.name, config.version });
    defer allocator.free(pkg_name);

    const output_path = try std.fmt.allocPrint(allocator, "{s}/{s}.zip", .{ output_dir, pkg_name });

    // Create staging directory
    const staging_dir = try std.fmt.allocPrint(allocator, "{s}/.staging-{s}", .{ output_dir, pkg_name });
    defer allocator.free(staging_dir);

    cwd.createDir(io, staging_dir, .default_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Copy files to staging
    if (config.binary) |binary| {
        const dest = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ staging_dir, std.fs.path.basename(binary) });
        defer allocator.free(dest);
        try cwd.copyFile(binary, cwd, dest, io, .{});
    }

    for (config.files.items) |file| {
        const dest = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ staging_dir, file.destination });
        defer allocator.free(dest);
        cwd.copyFile(file.source, cwd, dest, io, .{}) catch |err| {
            std.debug.print("{s}Warning:{s} Could not copy {s}: {}\n", .{ Color.Yellow.code(), Color.Reset.code(), file.source, err });
        };
    }

    // Create zip using system zip
    const zip_result = try std.process.run(allocator, io, .{
        .argv = &[_][]const u8{
            "zip", "-r", output_path, ".",
        },
        .cwd = .{ .path = staging_dir },
    });
    defer allocator.free(zip_result.stdout);
    defer allocator.free(zip_result.stderr);

    if (zip_result.term.exited != 0) {
        std.debug.print("{s}Error:{s} zip failed: {s}\n", .{ Color.Red.code(), Color.Reset.code(), zip_result.stderr });
        return error.ZipFailed;
    }

    // Clean up staging
    cwd.deleteTree(io, staging_dir) catch {};

    return output_path;
}

/// Build a Debian package
fn buildDeb(allocator: std.mem.Allocator, config: *const PackageConfig, output_dir: []const u8, io: Io) ![]const u8 {
    const cwd = Io.Dir.cwd();
    const pkg_name = try std.fmt.allocPrint(allocator, "{s}_{s}_amd64", .{ config.name, config.version });
    defer allocator.free(pkg_name);

    const output_path = try std.fmt.allocPrint(allocator, "{s}/{s}.deb", .{ output_dir, pkg_name });

    // Create package directory structure
    const pkg_dir = try std.fmt.allocPrint(allocator, "{s}/.deb-{s}", .{ output_dir, config.name });
    defer allocator.free(pkg_dir);

    // Clean up any existing directory
    cwd.deleteTree(io, pkg_dir) catch {};

    // Create DEBIAN directory
    const debian_dir = try std.fmt.allocPrint(allocator, "{s}/DEBIAN", .{pkg_dir});
    defer allocator.free(debian_dir);
    try cwd.createDirPath(io, debian_dir);

    // Create usr/local/bin directory
    const bin_dir = try std.fmt.allocPrint(allocator, "{s}/usr/local/bin", .{pkg_dir});
    defer allocator.free(bin_dir);
    try cwd.createDirPath(io, bin_dir);

    // Create control file
    const control_path = try std.fmt.allocPrint(allocator, "{s}/control", .{debian_dir});
    defer allocator.free(control_path);

    var deps_str: []const u8 = "";
    if (config.dependencies.items.len > 0) {
        var deps_buf = std.ArrayList(u8){};
        defer deps_buf.deinit(allocator);
        for (config.dependencies.items, 0..) |dep, i| {
            if (i > 0) try deps_buf.appendSlice(allocator, ", ");
            try deps_buf.appendSlice(allocator, dep);
        }
        deps_str = try deps_buf.toOwnedSlice(allocator);
    }
    defer if (deps_str.len > 0) allocator.free(deps_str);

    const control_content = try std.fmt.allocPrint(allocator,
        \\Package: {s}
        \\Version: {s}
        \\Section: utils
        \\Priority: optional
        \\Architecture: amd64
        \\Maintainer: {s}
        \\Description: {s}
        \\{s}
    , .{
        config.name,
        config.version,
        config.author,
        config.description,
        if (deps_str.len > 0) try std.fmt.allocPrint(allocator, "Depends: {s}\n", .{deps_str}) else "",
    });
    defer allocator.free(control_content);

    const control_file = try cwd.createFile(io, control_path, .{});
    defer control_file.close(io);
    try control_file.writeStreamingAll(io, control_content);

    // Copy binary
    if (config.binary) |binary| {
        const dest = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ bin_dir, std.fs.path.basename(binary) });
        defer allocator.free(dest);
        try cwd.copyFile(binary, cwd, dest, io, .{});
        // Make executable
        const chmod_result = try std.process.run(allocator, io, .{
            .argv = &[_][]const u8{ "chmod", "+x", dest },
        });
        defer allocator.free(chmod_result.stdout);
        defer allocator.free(chmod_result.stderr);
    }

    // Build deb package
    const dpkg_result = try std.process.run(allocator, io, .{
        .argv = &[_][]const u8{ "dpkg-deb", "--build", pkg_dir, output_path },
    });
    defer allocator.free(dpkg_result.stdout);
    defer allocator.free(dpkg_result.stderr);

    if (dpkg_result.term.exited != 0) {
        std.debug.print("{s}Warning:{s} dpkg-deb not available, falling back to tarball\n", .{ Color.Yellow.code(), Color.Reset.code() });
        // Clean up and fall back
        cwd.deleteTree(io, pkg_dir) catch {};
        return buildTarball(allocator, config, output_dir, io);
    }

    // Clean up
    cwd.deleteTree(io, pkg_dir) catch {};

    return output_path;
}

/// Build a macOS DMG
fn buildDmg(allocator: std.mem.Allocator, config: *const PackageConfig, output_dir: []const u8, io: Io) ![]const u8 {
    const cwd = Io.Dir.cwd();
    const output_path = try std.fmt.allocPrint(allocator, "{s}/{s}-{s}.dmg", .{ output_dir, config.name, config.version });

    // Create staging directory
    const staging_dir = try std.fmt.allocPrint(allocator, "{s}/.dmg-{s}", .{ output_dir, config.name });
    defer allocator.free(staging_dir);

    // Clean up any existing directory
    cwd.deleteTree(io, staging_dir) catch {};
    try cwd.createDirPath(io, staging_dir);

    // Create .app bundle structure
    const app_name = try std.fmt.allocPrint(allocator, "{s}.app", .{config.name});
    defer allocator.free(app_name);

    const app_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ staging_dir, app_name });
    defer allocator.free(app_dir);

    const contents_dir = try std.fmt.allocPrint(allocator, "{s}/Contents", .{app_dir});
    defer allocator.free(contents_dir);
    try cwd.createDirPath(io, contents_dir);

    const macos_dir = try std.fmt.allocPrint(allocator, "{s}/MacOS", .{contents_dir});
    defer allocator.free(macos_dir);
    try cwd.createDirPath(io, macos_dir);

    const resources_dir = try std.fmt.allocPrint(allocator, "{s}/Resources", .{contents_dir});
    defer allocator.free(resources_dir);
    try cwd.createDirPath(io, resources_dir);

    // Copy binary
    if (config.binary) |binary| {
        const dest = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ macos_dir, config.name });
        defer allocator.free(dest);
        try cwd.copyFile(binary, cwd, dest, io, .{});
        // Make executable
        const chmod_result = try std.process.run(allocator, io, .{
            .argv = &[_][]const u8{ "chmod", "+x", dest },
        });
        defer allocator.free(chmod_result.stdout);
        defer allocator.free(chmod_result.stderr);
    }

    // Create Info.plist
    const plist_path = try std.fmt.allocPrint(allocator, "{s}/Info.plist", .{contents_dir});
    defer allocator.free(plist_path);

    const bundle_id = try std.fmt.allocPrint(allocator, "com.{s}.{s}", .{
        if (config.author.len > 0) config.author else "app",
        config.name,
    });
    defer allocator.free(bundle_id);

    const plist_content = try std.fmt.allocPrint(allocator,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\    <key>CFBundleExecutable</key>
        \\    <string>{s}</string>
        \\    <key>CFBundleIdentifier</key>
        \\    <string>{s}</string>
        \\    <key>CFBundleName</key>
        \\    <string>{s}</string>
        \\    <key>CFBundleVersion</key>
        \\    <string>{s}</string>
        \\    <key>CFBundleShortVersionString</key>
        \\    <string>{s}</string>
        \\    <key>CFBundlePackageType</key>
        \\    <string>APPL</string>
        \\    <key>LSMinimumSystemVersion</key>
        \\    <string>10.13</string>
        \\    <key>NSHighResolutionCapable</key>
        \\    <true/>
        \\</dict>
        \\</plist>
    , .{ config.name, bundle_id, config.name, config.version, config.version });
    defer allocator.free(plist_content);

    const plist_file = try cwd.createFile(io, plist_path, .{});
    defer plist_file.close(io);
    try plist_file.writeStreamingAll(io, plist_content);

    // Create Applications symlink
    const apps_link = try std.fmt.allocPrint(allocator, "{s}/Applications", .{staging_dir});
    defer allocator.free(apps_link);

    const symlink_result = try std.process.run(allocator, io, .{
        .argv = &[_][]const u8{ "ln", "-s", "/Applications", apps_link },
    });
    defer allocator.free(symlink_result.stdout);
    defer allocator.free(symlink_result.stderr);

    // Create DMG
    const hdiutil_result = try std.process.run(allocator, io, .{
        .argv = &[_][]const u8{
            "hdiutil",
            "create",
            "-volname",
            config.name,
            "-srcfolder",
            staging_dir,
            "-ov",
            "-format",
            "UDZO",
            output_path,
        },
    });
    defer allocator.free(hdiutil_result.stdout);
    defer allocator.free(hdiutil_result.stderr);

    if (hdiutil_result.term.exited != 0) {
        std.debug.print("{s}Warning:{s} hdiutil failed, falling back to tarball\n", .{ Color.Yellow.code(), Color.Reset.code() });
        cwd.deleteTree(io, staging_dir) catch {};
        return buildTarball(allocator, config, output_dir, io);
    }

    // Clean up
    cwd.deleteTree(io, staging_dir) catch {};

    return output_path;
}

/// Build an AppImage
fn buildAppImage(allocator: std.mem.Allocator, config: *const PackageConfig, output_dir: []const u8, io: Io) ![]const u8 {
    const cwd = Io.Dir.cwd();
    const output_path = try std.fmt.allocPrint(allocator, "{s}/{s}-{s}.AppImage", .{ output_dir, config.name, config.version });

    // Create AppDir structure
    const app_dir = try std.fmt.allocPrint(allocator, "{s}/.AppDir-{s}", .{ output_dir, config.name });
    defer allocator.free(app_dir);

    cwd.deleteTree(io, app_dir) catch {};
    try cwd.createDirPath(io, app_dir);

    const usr_bin = try std.fmt.allocPrint(allocator, "{s}/usr/bin", .{app_dir});
    defer allocator.free(usr_bin);
    try cwd.createDirPath(io, usr_bin);

    const usr_share = try std.fmt.allocPrint(allocator, "{s}/usr/share/applications", .{app_dir});
    defer allocator.free(usr_share);
    try cwd.createDirPath(io, usr_share);

    // Copy binary
    if (config.binary) |binary| {
        const dest = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ usr_bin, config.name });
        defer allocator.free(dest);
        try cwd.copyFile(binary, cwd, dest, io, .{});
        const chmod_result = try std.process.run(allocator, io, .{
            .argv = &[_][]const u8{ "chmod", "+x", dest },
        });
        defer allocator.free(chmod_result.stdout);
        defer allocator.free(chmod_result.stderr);
    }

    // Create .desktop file
    const desktop_path = try std.fmt.allocPrint(allocator, "{s}/{s}.desktop", .{ app_dir, config.name });
    defer allocator.free(desktop_path);

    const desktop_content = try std.fmt.allocPrint(allocator,
        \\[Desktop Entry]
        \\Type=Application
        \\Name={s}
        \\Exec={s}
        \\Icon={s}
        \\Comment={s}
        \\Categories=Utility;
        \\Terminal=false
    , .{ config.name, config.name, config.name, config.description });
    defer allocator.free(desktop_content);

    const desktop_file = try cwd.createFile(io, desktop_path, .{});
    defer desktop_file.close(io);
    try desktop_file.writeStreamingAll(io, desktop_content);

    // Create AppRun script
    const apprun_path = try std.fmt.allocPrint(allocator, "{s}/AppRun", .{app_dir});
    defer allocator.free(apprun_path);

    const apprun_content = try std.fmt.allocPrint(allocator,
        \\#!/bin/bash
        \\SELF=$(readlink -f "$0")
        \\HERE=${{SELF%/*}}
        \\exec "$HERE/usr/bin/{s}" "$@"
    , .{config.name});
    defer allocator.free(apprun_content);

    const apprun_file = try cwd.createFile(io, apprun_path, .{});
    defer apprun_file.close(io);
    try apprun_file.writeStreamingAll(io, apprun_content);

    const chmod_apprun = try std.process.run(allocator, io, .{
        .argv = &[_][]const u8{ "chmod", "+x", apprun_path },
    });
    defer allocator.free(chmod_apprun.stdout);
    defer allocator.free(chmod_apprun.stderr);

    // Try to use appimagetool
    const appimage_result = std.process.run(allocator, io, .{
        .argv = &[_][]const u8{ "appimagetool", app_dir, output_path },
    }) catch {
        std.debug.print("{s}Warning:{s} appimagetool not available, falling back to tarball\n", .{ Color.Yellow.code(), Color.Reset.code() });
        cwd.deleteTree(io, app_dir) catch {};
        return buildTarball(allocator, config, output_dir, io);
    };
    defer allocator.free(appimage_result.stdout);
    defer allocator.free(appimage_result.stderr);

    if (appimage_result.term.exited != 0) {
        std.debug.print("{s}Warning:{s} appimagetool failed, falling back to tarball\n", .{ Color.Yellow.code(), Color.Reset.code() });
        cwd.deleteTree(io, app_dir) catch {};
        return buildTarball(allocator, config, output_dir, io);
    }

    // Clean up
    cwd.deleteTree(io, app_dir) catch {};

    return output_path;
}

/// Build an RPM package (stub - requires rpmbuild)
fn buildRpm(allocator: std.mem.Allocator, config: *const PackageConfig, output_dir: []const u8, io: Io) ![]const u8 {
    // For now, fall back to tarball since rpmbuild requires complex setup
    std.debug.print("{s}Info:{s} RPM build not fully implemented, creating tarball instead\n", .{ Color.Cyan.code(), Color.Reset.code() });
    return buildTarball(allocator, config, output_dir, io);
}

/// Build an MSI package (stub - requires WiX on Windows)
fn buildMsi(allocator: std.mem.Allocator, config: *const PackageConfig, output_dir: []const u8, io: Io) ![]const u8 {
    // For now, fall back to zip since MSI requires WiX toolset
    std.debug.print("{s}Info:{s} MSI build not fully implemented, creating zip instead\n", .{ Color.Cyan.code(), Color.Reset.code() });
    return buildZip(allocator, config, output_dir, io);
}

/// Print package command usage
fn printPackageUsage() void {
    std.debug.print(
        \\{s}Home Package{s} - Create distributable packages
        \\
        \\{s}Usage:{s}
        \\  home package [options]
        \\
        \\{s}Options:{s}
        \\  --config <file>     Config file (default: package.toml or home.toml)
        \\  --format <format>   Package format (tarball, zip, deb, rpm, dmg, msi, appimage)
        \\  --output <dir>      Output directory (default: dist/)
        \\  --binary <file>     Binary to package
        \\  --name <name>       Package name
        \\  --version <ver>     Package version
        \\  --all               Build all supported formats for current platform
        \\  --help              Show this help
        \\
        \\{s}Examples:{s}
        \\  home package                            # Use package.toml, default format
        \\  home package --format deb               # Create .deb package
        \\  home package --format dmg --binary app  # Create DMG with binary
        \\  home package --all                      # Create all supported formats
        \\
        \\{s}Config file format (package.toml):{s}
        \\  [package]
        \\  name = "myapp"
        \\  version = "1.0.0"
        \\  description = "My application"
        \\  author = "Your Name"
        \\  license = "MIT"
        \\  binary = "dist/myapp"
        \\
        \\  [files]
        \\  "README.md" = "README.md"
        \\  "LICENSE" = "LICENSE"
        \\
    , .{
        Color.Blue.code(),
        Color.Reset.code(),
        Color.Green.code(),
        Color.Reset.code(),
        Color.Green.code(),
        Color.Reset.code(),
        Color.Green.code(),
        Color.Reset.code(),
        Color.Cyan.code(),
        Color.Reset.code(),
    });
}

/// Main package command handler
pub fn packageCommand(allocator: std.mem.Allocator, args: []const [:0]const u8, io: Io) !void {
    var config_path: ?[]const u8 = null;
    var format: ?PackageFormat = null;
    var output_dir: []const u8 = "dist";
    var binary_override: ?[]const u8 = null;
    var name_override: ?[]const u8 = null;
    var version_override: ?[]const u8 = null;
    var build_all = false;

    // Parse arguments
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printPackageUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--config") and i + 1 < args.len) {
            i += 1;
            config_path = args[i];
        } else if (std.mem.eql(u8, arg, "--format") and i + 1 < args.len) {
            i += 1;
            format = PackageFormat.fromString(args[i]);
            if (format == null) {
                std.debug.print("{s}Error:{s} Unknown format '{s}'\n", .{ Color.Red.code(), Color.Reset.code(), args[i] });
                return error.UnknownFormat;
            }
        } else if (std.mem.eql(u8, arg, "--output") and i + 1 < args.len) {
            i += 1;
            output_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--binary") and i + 1 < args.len) {
            i += 1;
            binary_override = args[i];
        } else if (std.mem.eql(u8, arg, "--name") and i + 1 < args.len) {
            i += 1;
            name_override = args[i];
        } else if (std.mem.eql(u8, arg, "--version") and i + 1 < args.len) {
            i += 1;
            version_override = args[i];
        } else if (std.mem.eql(u8, arg, "--all")) {
            build_all = true;
        }
    }

    // Try to find config file
    const cwd = Io.Dir.cwd();
    const config_files = [_][]const u8{ "package.toml", "home.toml", "Cargo.toml" };
    var found_config: ?[]const u8 = config_path;

    if (found_config == null) {
        for (config_files) |cf| {
            if (cwd.access(io, cf, .{})) |_| {
                found_config = cf;
                break;
            } else |_| {}
        }
    }

    // Load or create config
    var config: PackageConfig = undefined;
    if (found_config) |path| {
        std.debug.print("{s}Loading config:{s} {s}\n", .{ Color.Blue.code(), Color.Reset.code(), path });
        const content = try cwd.readFileAlloc(io, path, allocator, std.Io.Limit.unlimited);
        defer allocator.free(content);
        config = try parseConfig(allocator, content);
    } else {
        // Create default config
        config = PackageConfig{
            .name = name_override orelse "app",
            .version = version_override orelse "1.0.0",
            .description = "A Home application",
            .author = "",
            .license = "MIT",
            .files = std.ArrayList(PackageConfig.FileEntry){},
            .dependencies = std.ArrayList([]const u8){},
        };
    }
    defer config.deinit(allocator);

    // Apply overrides
    if (name_override) |name| config.name = name;
    if (version_override) |version| config.version = version;
    if (binary_override) |binary| config.binary = binary;

    // Check for binary
    if (config.binary == null) {
        std.debug.print("{s}Warning:{s} No binary specified. Use --binary <file> or set 'binary' in config.\n", .{ Color.Yellow.code(), Color.Reset.code() });
    }

    // Create output directory
    cwd.createDir(io, output_dir, .default_dir) catch |err| {
        if (err != error.PathAlreadyExists) {
            std.debug.print("{s}Error:{s} Failed to create output directory: {}\n", .{ Color.Red.code(), Color.Reset.code(), err });
            return err;
        }
    };

    std.debug.print("\n{s}Package Info:{s}\n", .{ Color.Blue.code(), Color.Reset.code() });
    std.debug.print("  Name:    {s}\n", .{config.name});
    std.debug.print("  Version: {s}\n", .{config.version});
    if (config.binary) |binary| {
        std.debug.print("  Binary:  {s}\n", .{binary});
    }
    std.debug.print("\n", .{});

    if (build_all) {
        // Build all formats for current platform
        const formats: []const PackageFormat = switch (builtin.os.tag) {
            .linux => &[_]PackageFormat{ .tarball, .deb, .appimage },
            .macos => &[_]PackageFormat{ .tarball, .dmg, .zip },
            .windows => &[_]PackageFormat{ .zip, .msi },
            else => &[_]PackageFormat{.tarball},
        };

        for (formats) |fmt| {
            std.debug.print("{s}Building:{s} {s}\n", .{ Color.Cyan.code(), Color.Reset.code(), @tagName(fmt) });
            const output_path = try buildFormat(allocator, &config, output_dir, fmt, io);
            std.debug.print("{s}✓{s} Created: {s}\n\n", .{ Color.Green.code(), Color.Reset.code(), output_path });
            allocator.free(output_path);
        }
    } else {
        // Build single format
        const pkg_format = format orelse PackageFormat.defaultForCurrentOS();
        std.debug.print("{s}Building:{s} {s} package\n", .{ Color.Cyan.code(), Color.Reset.code(), @tagName(pkg_format) });

        const output_path = try buildFormat(allocator, &config, output_dir, pkg_format, io);
        std.debug.print("\n{s}✓{s} Package created: {s}\n", .{ Color.Green.code(), Color.Reset.code(), output_path });
        allocator.free(output_path);
    }
}

fn buildFormat(allocator: std.mem.Allocator, config: *const PackageConfig, output_dir: []const u8, fmt: PackageFormat, io: Io) ![]const u8 {
    return switch (fmt) {
        .tarball => buildTarball(allocator, config, output_dir, io),
        .zip => buildZip(allocator, config, output_dir, io),
        .deb => buildDeb(allocator, config, output_dir, io),
        .rpm => buildRpm(allocator, config, output_dir, io),
        .dmg => buildDmg(allocator, config, output_dir, io),
        .msi => buildMsi(allocator, config, output_dir, io),
        .appimage => buildAppImage(allocator, config, output_dir, io),
    };
}
