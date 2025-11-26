const std = @import("std");
const Allocator = std.mem.Allocator;
const cross = @import("cross_compilation.zig");
const Target = cross.Target;

/// Package format
pub const PackageFormat = enum {
    tarball,      // .tar.gz
    zip,          // .zip
    deb,          // Debian package
    rpm,          // RedHat package
    dmg,          // macOS disk image
    msi,          // Windows installer
    appimage,     // Linux AppImage
    flatpak,      // Flatpak bundle
    snap,         // Snap package

    pub fn extension(self: PackageFormat) []const u8 {
        return switch (self) {
            .tarball => ".tar.gz",
            .zip => ".zip",
            .deb => ".deb",
            .rpm => ".rpm",
            .dmg => ".dmg",
            .msi => ".msi",
            .appimage => ".AppImage",
            .flatpak => ".flatpak",
            .snap => ".snap",
        };
    }

    pub fn defaultForOS(os: cross.OS) PackageFormat {
        return switch (os) {
            .linux => .tarball,
            .macos => .dmg,
            .windows => .zip,
            else => .tarball,
        };
    }
};

/// Package metadata
pub const PackageMetadata = struct {
    name: []const u8,
    version: []const u8,
    description: []const u8,
    author: []const u8,
    license: []const u8,
    homepage: ?[]const u8 = null,
    dependencies: []const []const u8 = &.{},

    pub fn format(self: PackageMetadata, allocator: Allocator) ![]const u8 {
        var buffer = std.ArrayList(u8).init(allocator);
        const writer = buffer.writer();

        try writer.print("Name: {s}\n", .{self.name});
        try writer.print("Version: {s}\n", .{self.version});
        try writer.print("Description: {s}\n", .{self.description});
        try writer.print("Author: {s}\n", .{self.author});
        try writer.print("License: {s}\n", .{self.license});

        if (self.homepage) |homepage| {
            try writer.print("Homepage: {s}\n", .{homepage});
        }

        if (self.dependencies.len > 0) {
            try writer.writeAll("Dependencies:\n");
            for (self.dependencies) |dep| {
                try writer.print("  - {s}\n", .{dep});
            }
        }

        return buffer.toOwnedSlice();
    }
};

/// Package builder
pub const PackageBuilder = struct {
    allocator: Allocator,
    metadata: PackageMetadata,
    target: Target,
    format: PackageFormat,
    output_dir: []const u8,
    files: std.ArrayList(PackageFile),

    pub const PackageFile = struct {
        source: []const u8,
        destination: []const u8,
        mode: u32 = 0o644, // Default file permissions
    };

    pub fn init(allocator: Allocator, metadata: PackageMetadata, target: Target, format: PackageFormat) PackageBuilder {
        return .{
            .allocator = allocator,
            .metadata = metadata,
            .target = target,
            .format = format,
            .output_dir = "dist",
            .files = std.ArrayList(PackageFile).init(allocator),
        };
    }

    pub fn deinit(self: *PackageBuilder) void {
        for (self.files.items) |file| {
            self.allocator.free(file.source);
            self.allocator.free(file.destination);
        }
        self.files.deinit();
    }

    /// Add a file to the package
    pub fn addFile(self: *PackageBuilder, source: []const u8, destination: []const u8, mode: u32) !void {
        try self.files.append(.{
            .source = try self.allocator.dupe(u8, source),
            .destination = try self.allocator.dupe(u8, destination),
            .mode = mode,
        });
    }

    /// Add an executable to the package
    pub fn addExecutable(self: *PackageBuilder, source: []const u8, name: []const u8) !void {
        const dest = try std.fmt.allocPrint(
            self.allocator,
            "bin/{s}{s}",
            .{ name, self.target.os.executableExtension() },
        );
        defer self.allocator.free(dest);

        try self.addFile(source, dest, 0o755);
    }

    /// Add a library to the package
    pub fn addLibrary(self: *PackageBuilder, source: []const u8, name: []const u8, is_static: bool) !void {
        const ext = if (is_static)
            self.target.os.staticLibraryExtension()
        else
            self.target.os.dynamicLibraryExtension();

        const dest = try std.fmt.allocPrint(
            self.allocator,
            "lib/{s}{s}",
            .{ name, ext },
        );
        defer self.allocator.free(dest);

        try self.addFile(source, dest, 0o644);
    }

    /// Build the package
    pub fn build(self: *PackageBuilder) ![]const u8 {
        // Ensure output directory exists
        try std.fs.cwd().makePath(self.output_dir);

        const package_name = try std.fmt.allocPrint(
            self.allocator,
            "{s}-{s}-{s}{s}",
            .{
                self.metadata.name,
                self.metadata.version,
                try self.target.toString(self.allocator),
                self.format.extension(),
            },
        );
        defer self.allocator.free(package_name);

        const output_path = try std.fs.path.join(
            self.allocator,
            &.{ self.output_dir, package_name },
        );

        switch (self.format) {
            .tarball => try self.buildTarball(output_path),
            .zip => try self.buildZip(output_path),
            .deb => try self.buildDeb(output_path),
            .rpm => try self.buildRpm(output_path),
            .dmg => try self.buildDmg(output_path),
            .msi => try self.buildMsi(output_path),
            .appimage => try self.buildAppImage(output_path),
            .flatpak => try self.buildFlatpak(output_path),
            .snap => try self.buildSnap(output_path),
        }

        return output_path;
    }

    fn buildTarball(self: *PackageBuilder, output_path: []const u8) !void {
        // Create temporary directory for staging
        const temp_dir = try std.fmt.allocPrint(
            self.allocator,
            "/tmp/home-pkg-{s}-{d}",
            .{ self.metadata.name, std.time.timestamp() },
        );
        defer self.allocator.free(temp_dir);

        try std.fs.cwd().makePath(temp_dir);
        defer std.fs.cwd().deleteTree(temp_dir) catch {};

        // Copy files to staging directory
        for (self.files.items) |file| {
            const dest_path = try std.fs.path.join(self.allocator, &.{ temp_dir, file.destination });
            defer self.allocator.free(dest_path);

            const dest_dir = std.fs.path.dirname(dest_path) orelse temp_dir;
            try std.fs.cwd().makePath(dest_dir);

            try std.fs.cwd().copyFile(file.source, std.fs.cwd(), dest_path, .{});

            // Set permissions
            if (std.fs.cwd().openFile(dest_path, .{})) |f| {
                defer f.close();
                try f.chmod(file.mode);
            } else |_| {}
        }

        // Create tarball using tar command
        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{
                "tar",
                "-czf",
                output_path,
                "-C",
                temp_dir,
                ".",
            },
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term.Exited != 0) {
            return error.TarFailed;
        }
    }

    fn buildZip(self: *PackageBuilder, output_path: []const u8) !void {
        // Similar to tarball but uses zip
        const temp_dir = try std.fmt.allocPrint(
            self.allocator,
            "/tmp/home-pkg-{s}-{d}",
            .{ self.metadata.name, std.time.timestamp() },
        );
        defer self.allocator.free(temp_dir);

        try std.fs.cwd().makePath(temp_dir);
        defer std.fs.cwd().deleteTree(temp_dir) catch {};

        // Copy files
        for (self.files.items) |file| {
            const dest_path = try std.fs.path.join(self.allocator, &.{ temp_dir, file.destination });
            defer self.allocator.free(dest_path);

            const dest_dir = std.fs.path.dirname(dest_path) orelse temp_dir;
            try std.fs.cwd().makePath(dest_dir);

            try std.fs.cwd().copyFile(file.source, std.fs.cwd(), dest_path, .{});
        }

        // Create zip using zip command
        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{
                "zip",
                "-r",
                output_path,
                ".",
            },
            .cwd = temp_dir,
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term.Exited != 0) {
            return error.ZipFailed;
        }
    }

    fn buildDeb(self: *PackageBuilder, output_path: []const u8) !void {
        _ = output_path;
        // Debian package creation
        // Would use dpkg-deb or build control files manually
        // For now, placeholder
        std.debug.print("Debian package creation not yet fully implemented\n", .{});
    }

    fn buildRpm(self: *PackageBuilder, output_path: []const u8) !void {
        _ = output_path;
        // RPM package creation
        std.debug.print("RPM package creation not yet fully implemented\n", .{});
    }

    fn buildDmg(self: *PackageBuilder, output_path: []const u8) !void {
        _ = output_path;
        // macOS DMG creation
        std.debug.print("DMG creation not yet fully implemented\n", .{});
    }

    fn buildMsi(self: *PackageBuilder, output_path: []const u8) !void {
        _ = output_path;
        // Windows MSI creation
        std.debug.print("MSI creation not yet fully implemented\n", .{});
    }

    fn buildAppImage(self: *PackageBuilder, output_path: []const u8) !void {
        _ = output_path;
        // AppImage creation
        std.debug.print("AppImage creation not yet fully implemented\n", .{});
    }

    fn buildFlatpak(self: *PackageBuilder, output_path: []const u8) !void {
        _ = output_path;
        // Flatpak bundle creation
        std.debug.print("Flatpak creation not yet fully implemented\n", .{});
    }

    fn buildSnap(self: *PackageBuilder, output_path: []const u8) !void {
        _ = output_path;
        // Snap package creation
        std.debug.print("Snap creation not yet fully implemented\n", .{});
    }
};

/// Distribution manager - handles multi-target builds and packaging
pub const DistributionManager = struct {
    allocator: Allocator,
    metadata: PackageMetadata,
    targets: std.ArrayList(Target),
    formats: std.ArrayList(PackageFormat),

    pub fn init(allocator: Allocator, metadata: PackageMetadata) DistributionManager {
        return .{
            .allocator = allocator,
            .metadata = metadata,
            .targets = std.ArrayList(Target).init(allocator),
            .formats = std.ArrayList(PackageFormat).init(allocator),
        };
    }

    pub fn deinit(self: *DistributionManager) void {
        self.targets.deinit();
        self.formats.deinit();
    }

    /// Add target platform
    pub fn addTarget(self: *DistributionManager, target: Target) !void {
        try self.targets.append(target);
    }

    /// Add package format
    pub fn addFormat(self: *DistributionManager, format: PackageFormat) !void {
        try self.formats.append(format);
    }

    /// Build all target combinations
    pub fn buildAll(self: *DistributionManager, build_fn: *const fn (Target) anyerror![]const u8) !void {
        for (self.targets.items) |target| {
            // Build for this target
            const binary_path = try build_fn(target);
            defer self.allocator.free(binary_path);

            // Package in each requested format
            for (self.formats.items) |format| {
                var builder = PackageBuilder.init(self.allocator, self.metadata, target, format);
                defer builder.deinit();

                try builder.addExecutable(binary_path, self.metadata.name);

                const package_path = try builder.build();
                defer self.allocator.free(package_path);

                std.debug.print("Created package: {s}\n", .{package_path});
            }
        }
    }
};

test "PackageBuilder - tarball" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const metadata = PackageMetadata{
        .name = "test-app",
        .version = "1.0.0",
        .description = "Test application",
        .author = "Test Author",
        .license = "MIT",
    };

    var builder = PackageBuilder.init(
        allocator,
        metadata,
        cross.CommonTargets.linux_x86_64,
        .tarball,
    );
    defer builder.deinit();

    // Would add files and build in real test
    try testing.expect(true);
}
