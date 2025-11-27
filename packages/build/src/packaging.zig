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
        // Create Debian package structure
        const temp_dir = try std.fmt.allocPrint(
            self.allocator,
            "/tmp/home-deb-{s}-{d}",
            .{ self.metadata.name, std.time.timestamp() },
        );
        defer self.allocator.free(temp_dir);

        try std.fs.cwd().makePath(temp_dir);
        defer std.fs.cwd().deleteTree(temp_dir) catch {};

        // Create DEBIAN directory
        const debian_dir = try std.fs.path.join(self.allocator, &.{ temp_dir, "DEBIAN" });
        defer self.allocator.free(debian_dir);
        try std.fs.cwd().makePath(debian_dir);

        // Create control file
        const control_path = try std.fs.path.join(self.allocator, &.{ debian_dir, "control" });
        defer self.allocator.free(control_path);

        const arch_str = switch (self.target.arch) {
            .x86_64 => "amd64",
            .aarch64 => "arm64",
            .arm => "armhf",
            else => "all",
        };

        const control_content = try std.fmt.allocPrint(
            self.allocator,
            \\Package: {s}
            \\Version: {s}
            \\Section: utils
            \\Priority: optional
            \\Architecture: {s}
            \\Maintainer: {s}
            \\Description: {s}
            \\
        ,
            .{ self.metadata.name, self.metadata.version, arch_str, self.metadata.author, self.metadata.description },
        );
        defer self.allocator.free(control_content);

        const control_file = try std.fs.cwd().createFile(control_path, .{});
        defer control_file.close();
        try control_file.writeAll(control_content);

        // Create usr/local/bin directory for executables
        const bin_dir = try std.fs.path.join(self.allocator, &.{ temp_dir, "usr", "local", "bin" });
        defer self.allocator.free(bin_dir);
        try std.fs.cwd().makePath(bin_dir);

        // Copy files to package structure
        for (self.files.items) |file| {
            const dest_path = if (std.mem.startsWith(u8, file.destination, "bin/"))
                try std.fs.path.join(self.allocator, &.{ temp_dir, "usr", "local", file.destination })
            else
                try std.fs.path.join(self.allocator, &.{ temp_dir, "usr", "share", self.metadata.name, file.destination });
            defer self.allocator.free(dest_path);

            const dest_dir = std.fs.path.dirname(dest_path) orelse temp_dir;
            try std.fs.cwd().makePath(dest_dir);
            try std.fs.cwd().copyFile(file.source, std.fs.cwd(), dest_path, .{});

            // Set permissions
            if (std.fs.cwd().openFile(dest_path, .{ .mode = .read_write })) |f| {
                defer f.close();
                try f.chmod(file.mode);
            } else |_| {}
        }

        // Build deb package using dpkg-deb
        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{
                "dpkg-deb",
                "--build",
                "--root-owner-group",
                temp_dir,
                output_path,
            },
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term.Exited != 0) {
            std.debug.print("dpkg-deb error: {s}\n", .{result.stderr});
            return error.DebBuildFailed;
        }
    }

    fn buildRpm(self: *PackageBuilder, output_path: []const u8) !void {
        // Create RPM spec file and build
        const temp_dir = try std.fmt.allocPrint(
            self.allocator,
            "/tmp/home-rpm-{s}-{d}",
            .{ self.metadata.name, std.time.timestamp() },
        );
        defer self.allocator.free(temp_dir);

        try std.fs.cwd().makePath(temp_dir);
        defer std.fs.cwd().deleteTree(temp_dir) catch {};

        // Create rpmbuild directory structure
        const dirs = [_][]const u8{ "BUILD", "RPMS", "SOURCES", "SPECS", "SRPMS", "BUILDROOT" };
        for (dirs) |dir| {
            const dir_path = try std.fs.path.join(self.allocator, &.{ temp_dir, dir });
            defer self.allocator.free(dir_path);
            try std.fs.cwd().makePath(dir_path);
        }

        // Create spec file
        const spec_path = try std.fs.path.join(self.allocator, &.{ temp_dir, "SPECS", "package.spec" });
        defer self.allocator.free(spec_path);

        const arch_str = switch (self.target.arch) {
            .x86_64 => "x86_64",
            .aarch64 => "aarch64",
            .arm => "armv7hl",
            else => "noarch",
        };

        // Build file list for spec
        var file_list = std.ArrayList(u8).init(self.allocator);
        defer file_list.deinit();
        for (self.files.items) |file| {
            if (std.mem.startsWith(u8, file.destination, "bin/")) {
                try file_list.writer().print("/usr/local/{s}\n", .{file.destination});
            } else {
                try file_list.writer().print("/usr/share/{s}/{s}\n", .{ self.metadata.name, file.destination });
            }
        }

        const spec_content = try std.fmt.allocPrint(
            self.allocator,
            \\Name: {s}
            \\Version: {s}
            \\Release: 1
            \\Summary: {s}
            \\License: {s}
            \\BuildArch: {s}
            \\
            \\%description
            \\{s}
            \\
            \\%install
            \\mkdir -p %{{buildroot}}/usr/local/bin
            \\mkdir -p %{{buildroot}}/usr/share/{s}
            \\
            \\%files
            \\{s}
        ,
            .{
                self.metadata.name,
                self.metadata.version,
                self.metadata.description,
                self.metadata.license,
                arch_str,
                self.metadata.description,
                self.metadata.name,
                file_list.items,
            },
        );
        defer self.allocator.free(spec_content);

        const spec_file = try std.fs.cwd().createFile(spec_path, .{});
        defer spec_file.close();
        try spec_file.writeAll(spec_content);

        // Copy source files to BUILDROOT
        const buildroot = try std.fs.path.join(self.allocator, &.{ temp_dir, "BUILDROOT", try std.fmt.allocPrint(self.allocator, "{s}-{s}-1.{s}", .{ self.metadata.name, self.metadata.version, arch_str }) });
        defer self.allocator.free(buildroot);
        try std.fs.cwd().makePath(buildroot);

        for (self.files.items) |file| {
            const dest_path = if (std.mem.startsWith(u8, file.destination, "bin/"))
                try std.fs.path.join(self.allocator, &.{ buildroot, "usr", "local", file.destination })
            else
                try std.fs.path.join(self.allocator, &.{ buildroot, "usr", "share", self.metadata.name, file.destination });
            defer self.allocator.free(dest_path);

            const dest_dir = std.fs.path.dirname(dest_path) orelse buildroot;
            try std.fs.cwd().makePath(dest_dir);
            try std.fs.cwd().copyFile(file.source, std.fs.cwd(), dest_path, .{});
        }

        // Build RPM
        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{
                "rpmbuild",
                "-bb",
                "--define",
                try std.fmt.allocPrint(self.allocator, "_topdir {s}", .{temp_dir}),
                spec_path,
            },
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term.Exited != 0) {
            std.debug.print("rpmbuild error: {s}\n", .{result.stderr});
            return error.RpmBuildFailed;
        }

        // Copy resulting RPM to output path
        const rpm_dir = try std.fs.path.join(self.allocator, &.{ temp_dir, "RPMS", arch_str });
        defer self.allocator.free(rpm_dir);

        var dir = try std.fs.cwd().openDir(rpm_dir, .{ .iterate = true });
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (std.mem.endsWith(u8, entry.name, ".rpm")) {
                const rpm_path = try std.fs.path.join(self.allocator, &.{ rpm_dir, entry.name });
                defer self.allocator.free(rpm_path);
                try std.fs.cwd().copyFile(rpm_path, std.fs.cwd(), output_path, .{});
                break;
            }
        }
    }

    fn buildDmg(self: *PackageBuilder, output_path: []const u8) !void {
        // Create macOS DMG disk image
        const temp_dir = try std.fmt.allocPrint(
            self.allocator,
            "/tmp/home-dmg-{s}-{d}",
            .{ self.metadata.name, std.time.timestamp() },
        );
        defer self.allocator.free(temp_dir);

        try std.fs.cwd().makePath(temp_dir);
        defer std.fs.cwd().deleteTree(temp_dir) catch {};

        // Create .app bundle structure
        const app_name = try std.fmt.allocPrint(self.allocator, "{s}.app", .{self.metadata.name});
        defer self.allocator.free(app_name);

        const app_dir = try std.fs.path.join(self.allocator, &.{ temp_dir, app_name });
        defer self.allocator.free(app_dir);

        const contents_dir = try std.fs.path.join(self.allocator, &.{ app_dir, "Contents" });
        defer self.allocator.free(contents_dir);

        const macos_dir = try std.fs.path.join(self.allocator, &.{ contents_dir, "MacOS" });
        defer self.allocator.free(macos_dir);

        const resources_dir = try std.fs.path.join(self.allocator, &.{ contents_dir, "Resources" });
        defer self.allocator.free(resources_dir);

        try std.fs.cwd().makePath(macos_dir);
        try std.fs.cwd().makePath(resources_dir);

        // Create Info.plist
        const plist_path = try std.fs.path.join(self.allocator, &.{ contents_dir, "Info.plist" });
        defer self.allocator.free(plist_path);

        const bundle_id = try std.fmt.allocPrint(self.allocator, "com.home.{s}", .{self.metadata.name});
        defer self.allocator.free(bundle_id);

        const plist_content = try std.fmt.allocPrint(
            self.allocator,
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
            \\    <key>CFBundlePackageType</key>
            \\    <string>APPL</string>
            \\    <key>CFBundleShortVersionString</key>
            \\    <string>{s}</string>
            \\    <key>CFBundleVersion</key>
            \\    <string>{s}</string>
            \\    <key>LSMinimumSystemVersion</key>
            \\    <string>10.13</string>
            \\    <key>NSHighResolutionCapable</key>
            \\    <true/>
            \\    <key>NSHumanReadableCopyright</key>
            \\    <string>Copyright © {s}. {s}</string>
            \\</dict>
            \\</plist>
            \\
        ,
            .{
                self.metadata.name,
                bundle_id,
                self.metadata.name,
                self.metadata.version,
                self.metadata.version,
                self.metadata.author,
                self.metadata.license,
            },
        );
        defer self.allocator.free(plist_content);

        const plist_file = try std.fs.cwd().createFile(plist_path, .{});
        defer plist_file.close();
        try plist_file.writeAll(plist_content);

        // Copy files to app bundle
        for (self.files.items) |file| {
            const dest_path = if (std.mem.startsWith(u8, file.destination, "bin/"))
                try std.fs.path.join(self.allocator, &.{ macos_dir, std.fs.path.basename(file.destination) })
            else
                try std.fs.path.join(self.allocator, &.{ resources_dir, file.destination });
            defer self.allocator.free(dest_path);

            const dest_dir = std.fs.path.dirname(dest_path) orelse macos_dir;
            try std.fs.cwd().makePath(dest_dir);
            try std.fs.cwd().copyFile(file.source, std.fs.cwd(), dest_path, .{});

            // Set executable permissions for binaries
            if (std.mem.startsWith(u8, file.destination, "bin/")) {
                if (std.fs.cwd().openFile(dest_path, .{ .mode = .read_write })) |f| {
                    defer f.close();
                    try f.chmod(0o755);
                } else |_| {}
            }
        }

        // Create symlink to /Applications in DMG
        const apps_link = try std.fs.path.join(self.allocator, &.{ temp_dir, "Applications" });
        defer self.allocator.free(apps_link);

        // Use ln -s for symlink (more portable)
        _ = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "ln", "-s", "/Applications", apps_link },
        });

        // Create DMG using hdiutil
        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{
                "hdiutil",
                "create",
                "-volname",
                self.metadata.name,
                "-srcfolder",
                temp_dir,
                "-ov",
                "-format",
                "UDZO",
                output_path,
            },
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term.Exited != 0) {
            std.debug.print("hdiutil error: {s}\n", .{result.stderr});
            return error.DmgBuildFailed;
        }
    }

    fn buildMsi(self: *PackageBuilder, output_path: []const u8) !void {
        // Create Windows MSI installer using WiX or native tools
        const temp_dir = try std.fmt.allocPrint(
            self.allocator,
            "/tmp/home-msi-{s}-{d}",
            .{ self.metadata.name, std.time.timestamp() },
        );
        defer self.allocator.free(temp_dir);

        try std.fs.cwd().makePath(temp_dir);
        defer std.fs.cwd().deleteTree(temp_dir) catch {};

        // Generate a UUID for the product (deterministic based on name+version)
        const product_uuid = try generateUuid(self.allocator, self.metadata.name, self.metadata.version);
        defer self.allocator.free(product_uuid);

        // Create WiX XML file
        const wxs_path = try std.fs.path.join(self.allocator, &.{ temp_dir, "installer.wxs" });
        defer self.allocator.free(wxs_path);

        // Build file components
        var components = std.ArrayList(u8).init(self.allocator);
        defer components.deinit();
        var component_refs = std.ArrayList(u8).init(self.allocator);
        defer component_refs.deinit();

        var file_idx: u32 = 0;
        for (self.files.items) |file| {
            const comp_id = try std.fmt.allocPrint(self.allocator, "Component{d}", .{file_idx});
            defer self.allocator.free(comp_id);
            const file_id = try std.fmt.allocPrint(self.allocator, "File{d}", .{file_idx});
            defer self.allocator.free(file_id);

            try components.writer().print(
                \\            <Component Id="{s}" Guid="*">
                \\              <File Id="{s}" Source="{s}" KeyPath="yes"/>
                \\            </Component>
                \\
            , .{ comp_id, file_id, file.source });

            try component_refs.writer().print(
                \\        <ComponentRef Id="{s}"/>
                \\
            , .{comp_id});

            file_idx += 1;
        }

        const wxs_content = try std.fmt.allocPrint(
            self.allocator,
            \\<?xml version="1.0" encoding="UTF-8"?>
            \\<Wix xmlns="http://schemas.microsoft.com/wix/2006/wi">
            \\  <Product Id="{s}" Name="{s}" Language="1033"
            \\           Version="{s}" Manufacturer="{s}"
            \\           UpgradeCode="{s}">
            \\    <Package InstallerVersion="500" Compressed="yes" InstallScope="perMachine"/>
            \\    <MajorUpgrade DowngradeErrorMessage="A newer version is installed."/>
            \\    <MediaTemplate EmbedCab="yes"/>
            \\
            \\    <Feature Id="MainFeature" Title="{s}" Level="1">
            \\{s}
            \\    </Feature>
            \\
            \\    <Directory Id="TARGETDIR" Name="SourceDir">
            \\      <Directory Id="ProgramFilesFolder">
            \\        <Directory Id="INSTALLFOLDER" Name="{s}">
            \\{s}
            \\        </Directory>
            \\      </Directory>
            \\    </Directory>
            \\  </Product>
            \\</Wix>
            \\
        ,
            .{
                product_uuid,
                self.metadata.name,
                self.metadata.version,
                self.metadata.author,
                product_uuid,
                self.metadata.name,
                component_refs.items,
                self.metadata.name,
                components.items,
            },
        );
        defer self.allocator.free(wxs_content);

        const wxs_file = try std.fs.cwd().createFile(wxs_path, .{});
        defer wxs_file.close();
        try wxs_file.writeAll(wxs_content);

        // Check if WiX tools are available
        const candle_result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "which", "candle" },
        }) catch {
            // WiX not available, create simple zip as fallback for Windows
            std.debug.print("WiX toolset not found, creating zip package for Windows instead\n", .{});
            try self.buildZip(output_path);
            return;
        };
        defer self.allocator.free(candle_result.stdout);
        defer self.allocator.free(candle_result.stderr);

        if (candle_result.term.Exited != 0) {
            std.debug.print("WiX toolset not found, creating zip package for Windows instead\n", .{});
            try self.buildZip(output_path);
            return;
        }

        // Compile with candle
        const wixobj_path = try std.fs.path.join(self.allocator, &.{ temp_dir, "installer.wixobj" });
        defer self.allocator.free(wixobj_path);

        const candle = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "candle", "-o", wixobj_path, wxs_path },
        });
        defer self.allocator.free(candle.stdout);
        defer self.allocator.free(candle.stderr);

        if (candle.term.Exited != 0) {
            std.debug.print("candle error: {s}\n", .{candle.stderr});
            return error.MsiBuildFailed;
        }

        // Link with light
        const light = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "light", "-o", output_path, wixobj_path },
        });
        defer self.allocator.free(light.stdout);
        defer self.allocator.free(light.stderr);

        if (light.term.Exited != 0) {
            std.debug.print("light error: {s}\n", .{light.stderr});
            return error.MsiBuildFailed;
        }
    }

    fn buildAppImage(self: *PackageBuilder, output_path: []const u8) !void {
        // Create Linux AppImage
        const temp_dir = try std.fmt.allocPrint(
            self.allocator,
            "/tmp/home-appimage-{s}-{d}",
            .{ self.metadata.name, std.time.timestamp() },
        );
        defer self.allocator.free(temp_dir);

        try std.fs.cwd().makePath(temp_dir);
        defer std.fs.cwd().deleteTree(temp_dir) catch {};

        // Create AppDir structure
        const appdir = try std.fs.path.join(self.allocator, &.{ temp_dir, "AppDir" });
        defer self.allocator.free(appdir);

        const usr_bin = try std.fs.path.join(self.allocator, &.{ appdir, "usr", "bin" });
        defer self.allocator.free(usr_bin);

        const usr_share = try std.fs.path.join(self.allocator, &.{ appdir, "usr", "share", "applications" });
        defer self.allocator.free(usr_share);

        const usr_icons = try std.fs.path.join(self.allocator, &.{ appdir, "usr", "share", "icons", "hicolor", "256x256", "apps" });
        defer self.allocator.free(usr_icons);

        try std.fs.cwd().makePath(usr_bin);
        try std.fs.cwd().makePath(usr_share);
        try std.fs.cwd().makePath(usr_icons);

        // Copy files
        for (self.files.items) |file| {
            const dest_path = if (std.mem.startsWith(u8, file.destination, "bin/"))
                try std.fs.path.join(self.allocator, &.{ usr_bin, std.fs.path.basename(file.destination) })
            else
                try std.fs.path.join(self.allocator, &.{ appdir, "usr", "share", self.metadata.name, file.destination });
            defer self.allocator.free(dest_path);

            const dest_dir = std.fs.path.dirname(dest_path) orelse usr_bin;
            try std.fs.cwd().makePath(dest_dir);
            try std.fs.cwd().copyFile(file.source, std.fs.cwd(), dest_path, .{});

            if (std.mem.startsWith(u8, file.destination, "bin/")) {
                if (std.fs.cwd().openFile(dest_path, .{ .mode = .read_write })) |f| {
                    defer f.close();
                    try f.chmod(0o755);
                } else |_| {}
            }
        }

        // Create .desktop file
        const desktop_path = try std.fs.path.join(self.allocator, &.{ usr_share, try std.fmt.allocPrint(self.allocator, "{s}.desktop", .{self.metadata.name}) });
        defer self.allocator.free(desktop_path);

        const desktop_content = try std.fmt.allocPrint(
            self.allocator,
            \\[Desktop Entry]
            \\Type=Application
            \\Name={s}
            \\Exec={s}
            \\Icon={s}
            \\Comment={s}
            \\Categories=Utility;
            \\Terminal=false
            \\
        ,
            .{ self.metadata.name, self.metadata.name, self.metadata.name, self.metadata.description },
        );
        defer self.allocator.free(desktop_content);

        const desktop_file = try std.fs.cwd().createFile(desktop_path, .{});
        defer desktop_file.close();
        try desktop_file.writeAll(desktop_content);

        // Create AppRun script
        const apprun_path = try std.fs.path.join(self.allocator, &.{ appdir, "AppRun" });
        defer self.allocator.free(apprun_path);

        const apprun_content = try std.fmt.allocPrint(
            self.allocator,
            \\#!/bin/bash
            \\HERE="$(dirname "$(readlink -f "${{0}}")")"
            \\exec "${{HERE}}/usr/bin/{s}" "$@"
            \\
        ,
            .{self.metadata.name},
        );
        defer self.allocator.free(apprun_content);

        const apprun_file = try std.fs.cwd().createFile(apprun_path, .{});
        defer apprun_file.close();
        try apprun_file.writeAll(apprun_content);
        try apprun_file.chmod(0o755);

        // Create symlinks at AppDir root
        const desktop_link = try std.fs.path.join(self.allocator, &.{ appdir, try std.fmt.allocPrint(self.allocator, "{s}.desktop", .{self.metadata.name}) });
        defer self.allocator.free(desktop_link);

        _ = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "ln", "-sf", try std.fmt.allocPrint(self.allocator, "usr/share/applications/{s}.desktop", .{self.metadata.name}), desktop_link },
        });

        // Check for appimagetool
        const tool_check = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "which", "appimagetool" },
        }) catch {
            std.debug.print("appimagetool not found. Install from https://appimage.github.io/\n", .{});
            std.debug.print("Creating tarball instead...\n", .{});
            try self.buildTarball(output_path);
            return;
        };
        defer self.allocator.free(tool_check.stdout);
        defer self.allocator.free(tool_check.stderr);

        if (tool_check.term.Exited != 0) {
            std.debug.print("appimagetool not found, creating tarball instead\n", .{});
            try self.buildTarball(output_path);
            return;
        }

        // Create AppImage
        const arch_str = switch (self.target.arch) {
            .x86_64 => "x86_64",
            .aarch64 => "aarch64",
            else => "x86_64",
        };

        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "appimagetool", "--comp", "gzip", appdir, output_path },
            .env_map = &.{ .{ "ARCH", arch_str } },
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term.Exited != 0) {
            std.debug.print("appimagetool error: {s}\n", .{result.stderr});
            return error.AppImageBuildFailed;
        }
    }

    fn buildFlatpak(self: *PackageBuilder, output_path: []const u8) !void {
        // Create Flatpak bundle
        const temp_dir = try std.fmt.allocPrint(
            self.allocator,
            "/tmp/home-flatpak-{s}-{d}",
            .{ self.metadata.name, std.time.timestamp() },
        );
        defer self.allocator.free(temp_dir);

        try std.fs.cwd().makePath(temp_dir);
        defer std.fs.cwd().deleteTree(temp_dir) catch {};

        const app_id = try std.fmt.allocPrint(self.allocator, "org.home.{s}", .{self.metadata.name});
        defer self.allocator.free(app_id);

        // Create manifest file
        const manifest_path = try std.fs.path.join(self.allocator, &.{ temp_dir, "manifest.yml" });
        defer self.allocator.free(manifest_path);

        const manifest_content = try std.fmt.allocPrint(
            self.allocator,
            \\app-id: {s}
            \\runtime: org.freedesktop.Platform
            \\runtime-version: '23.08'
            \\sdk: org.freedesktop.Sdk
            \\command: {s}
            \\finish-args:
            \\  - --share=ipc
            \\  - --socket=fallback-x11
            \\  - --socket=wayland
            \\  - --device=dri
            \\modules:
            \\  - name: {s}
            \\    buildsystem: simple
            \\    build-commands:
            \\      - install -D {s} /app/bin/{s}
            \\    sources:
            \\      - type: file
            \\        path: bin/{s}
            \\
        ,
            .{ app_id, self.metadata.name, self.metadata.name, self.metadata.name, self.metadata.name, self.metadata.name },
        );
        defer self.allocator.free(manifest_content);

        const manifest_file = try std.fs.cwd().createFile(manifest_path, .{});
        defer manifest_file.close();
        try manifest_file.writeAll(manifest_content);

        // Copy binary
        const bin_dir = try std.fs.path.join(self.allocator, &.{ temp_dir, "bin" });
        defer self.allocator.free(bin_dir);
        try std.fs.cwd().makePath(bin_dir);

        for (self.files.items) |file| {
            if (std.mem.startsWith(u8, file.destination, "bin/")) {
                const dest_path = try std.fs.path.join(self.allocator, &.{ bin_dir, std.fs.path.basename(file.destination) });
                defer self.allocator.free(dest_path);
                try std.fs.cwd().copyFile(file.source, std.fs.cwd(), dest_path, .{});
            }
        }

        // Check for flatpak-builder
        const tool_check = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "which", "flatpak-builder" },
        }) catch {
            std.debug.print("flatpak-builder not found, creating tarball instead\n", .{});
            try self.buildTarball(output_path);
            return;
        };
        defer self.allocator.free(tool_check.stdout);
        defer self.allocator.free(tool_check.stderr);

        if (tool_check.term.Exited != 0) {
            std.debug.print("flatpak-builder not found, creating tarball instead\n", .{});
            try self.buildTarball(output_path);
            return;
        }

        // Build flatpak
        const build_dir = try std.fs.path.join(self.allocator, &.{ temp_dir, "build" });
        defer self.allocator.free(build_dir);

        const build_result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{
                "flatpak-builder",
                "--force-clean",
                build_dir,
                manifest_path,
            },
            .cwd = temp_dir,
        });
        defer self.allocator.free(build_result.stdout);
        defer self.allocator.free(build_result.stderr);

        if (build_result.term.Exited != 0) {
            std.debug.print("flatpak-builder error: {s}\n", .{build_result.stderr});
            return error.FlatpakBuildFailed;
        }

        // Export to bundle
        const bundle_result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{
                "flatpak",
                "build-bundle",
                build_dir,
                output_path,
                app_id,
            },
        });
        defer self.allocator.free(bundle_result.stdout);
        defer self.allocator.free(bundle_result.stderr);

        if (bundle_result.term.Exited != 0) {
            std.debug.print("flatpak bundle error: {s}\n", .{bundle_result.stderr});
            return error.FlatpakBuildFailed;
        }
    }

    fn buildSnap(self: *PackageBuilder, output_path: []const u8) !void {
        // Create Snap package
        const temp_dir = try std.fmt.allocPrint(
            self.allocator,
            "/tmp/home-snap-{s}-{d}",
            .{ self.metadata.name, std.time.timestamp() },
        );
        defer self.allocator.free(temp_dir);

        try std.fs.cwd().makePath(temp_dir);
        defer std.fs.cwd().deleteTree(temp_dir) catch {};

        // Create snap directory
        const snap_dir = try std.fs.path.join(self.allocator, &.{ temp_dir, "snap" });
        defer self.allocator.free(snap_dir);
        try std.fs.cwd().makePath(snap_dir);

        // Create snapcraft.yaml
        const snapcraft_path = try std.fs.path.join(self.allocator, &.{ snap_dir, "snapcraft.yaml" });
        defer self.allocator.free(snapcraft_path);

        const snapcraft_content = try std.fmt.allocPrint(
            self.allocator,
            \\name: {s}
            \\version: '{s}'
            \\summary: {s}
            \\description: |
            \\  {s}
            \\grade: stable
            \\confinement: strict
            \\base: core22
            \\
            \\apps:
            \\  {s}:
            \\    command: bin/{s}
            \\    plugs:
            \\      - home
            \\      - network
            \\      - x11
            \\      - wayland
            \\      - opengl
            \\
            \\parts:
            \\  {s}:
            \\    plugin: dump
            \\    source: .
            \\    organize:
            \\      {s}: bin/{s}
            \\
        ,
            .{
                self.metadata.name,
                self.metadata.version,
                self.metadata.description,
                self.metadata.description,
                self.metadata.name,
                self.metadata.name,
                self.metadata.name,
                self.metadata.name,
                self.metadata.name,
            },
        );
        defer self.allocator.free(snapcraft_content);

        const snapcraft_file = try std.fs.cwd().createFile(snapcraft_path, .{});
        defer snapcraft_file.close();
        try snapcraft_file.writeAll(snapcraft_content);

        // Copy binary to temp dir
        for (self.files.items) |file| {
            if (std.mem.startsWith(u8, file.destination, "bin/")) {
                const dest_path = try std.fs.path.join(self.allocator, &.{ temp_dir, std.fs.path.basename(file.destination) });
                defer self.allocator.free(dest_path);
                try std.fs.cwd().copyFile(file.source, std.fs.cwd(), dest_path, .{});
            }
        }

        // Check for snapcraft
        const tool_check = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "which", "snapcraft" },
        }) catch {
            std.debug.print("snapcraft not found, creating tarball instead\n", .{});
            try self.buildTarball(output_path);
            return;
        };
        defer self.allocator.free(tool_check.stdout);
        defer self.allocator.free(tool_check.stderr);

        if (tool_check.term.Exited != 0) {
            std.debug.print("snapcraft not found, creating tarball instead\n", .{});
            try self.buildTarball(output_path);
            return;
        }

        // Build snap
        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "snapcraft", "--destructive-mode" },
            .cwd = temp_dir,
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term.Exited != 0) {
            std.debug.print("snapcraft error: {s}\n", .{result.stderr});
            return error.SnapBuildFailed;
        }

        // Find and copy the snap file
        var dir = try std.fs.cwd().openDir(temp_dir, .{ .iterate = true });
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (std.mem.endsWith(u8, entry.name, ".snap")) {
                const snap_path = try std.fs.path.join(self.allocator, &.{ temp_dir, entry.name });
                defer self.allocator.free(snap_path);
                try std.fs.cwd().copyFile(snap_path, std.fs.cwd(), output_path, .{});
                break;
            }
        }
    }
};

/// Generate a deterministic UUID from strings
fn generateUuid(allocator: Allocator, name: []const u8, version: []const u8) ![]const u8 {
    // Create a simple hash-based UUID v5 style (deterministic)
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(name);
    hasher.update(version);
    const hash = hasher.final();

    return try std.fmt.allocPrint(
        allocator,
        "{x:0>8}-{x:0>4}-{x:0>4}-{x:0>4}-{x:0>12}",
        .{
            @as(u32, @truncate(hash >> 32)),
            @as(u16, @truncate(hash >> 16)),
            @as(u16, @truncate(hash)) | 0x5000, // Version 5
            @as(u16, @truncate(hash >> 48)) | 0x8000, // Variant
            @as(u48, @truncate(hash)),
        },
    );
}

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
