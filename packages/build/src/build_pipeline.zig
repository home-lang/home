// Home Programming Language - Complete Build Pipeline
// Integrates compilation, LTO, and linking with linker scripts

const std = @import("std");
const parallel_build = @import("parallel_build.zig");
const lto = @import("lto.zig");
const linker_script = @import("linker_script.zig");

fn freePathList(allocator: std.mem.Allocator, paths: []const []const u8) void {
    for (paths) |path| allocator.free(path);
    allocator.free(paths);
}

// ============================================================================
// Build Configuration
// ============================================================================

pub const BuildConfig = struct {
    /// Optimization mode
    optimize: std.builtin.OptimizeMode = .debug,
    /// Target architecture
    target: std.Target,
    /// Output executable path
    output_path: []const u8,
    /// Source files
    sources: []const []const u8,
    /// Enable LTO
    lto_enabled: bool = true,
    /// LTO configuration
    lto_config: lto.LtoConfig = .{},
    /// Custom linker script
    linker_script_path: ?[]const u8 = null,
    /// Generate linker script from config
    generate_linker_script: bool = false,
    /// Linker script template (for generation)
    linker_template: ?LinkerTemplate = null,
    /// Additional linker flags
    linker_flags: []const []const u8 = &[_][]const u8{},
    /// Build mode
    build_mode: BuildMode = .Executable,
    /// Verbose output
    verbose: bool = false,

    pub const BuildMode = enum {
        Executable,
        StaticLibrary,
        DynamicLibrary,
        Object,
    };

    pub const LinkerTemplate = enum {
        ArmCortexM,
        X86_64Kernel,
        RiscVBareMetal,
        Hosted, // Standard hosted environment
    };
};

// ============================================================================
// Build Pipeline
// ============================================================================

pub const BuildPipeline = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: BuildConfig,
    intermediate_dir: []const u8,
    cache_dir: []const u8,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: BuildConfig) !BuildPipeline {
        return .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .intermediate_dir = ".home-build",
            .cache_dir = ".home-cache",
        };
    }

    pub fn deinit(self: *BuildPipeline) void {
        _ = self;
    }

    /// Run complete build pipeline
    pub fn build(self: *BuildPipeline) !void {
        if (self.config.verbose) {
            std.debug.print("Starting build pipeline...\n", .{});
            std.debug.print("  Mode: {s}\n", .{@tagName(self.config.optimize)});
            std.debug.print("  LTO: {s}\n", .{if (self.config.lto_enabled) "enabled" else "disabled"});
            std.debug.print("  Sources: {d} files\n", .{self.config.sources.len});
        }

        // Create intermediate directories
        try self.createDirectories();

        // Phase 1: Parallel compilation to IR/object files
        if (self.config.verbose) {
            std.debug.print("\n=== Phase 1: Compilation ===\n", .{});
        }
        const object_files = try self.compilePhase();
        defer freePathList(self.allocator, object_files);

        // Phase 2: Link-time optimization (if enabled)
        var optimized_files: ?[]const []const u8 = null;
        defer if (optimized_files) |paths| freePathList(self.allocator, paths);
        if (self.config.lto_enabled and self.config.optimize != .debug) {
            if (self.config.verbose) {
                std.debug.print("\n=== Phase 2: Link-Time Optimization ===\n", .{});
            }
            optimized_files = try self.ltoPhase(object_files);
        } else if (self.config.verbose) {
            std.debug.print("\n=== Phase 2: Link-Time Optimization (skipped) ===\n", .{});
        }

        if (self.config.verbose) {
            std.debug.print("\n=== Phase 3: Linking ===\n", .{});
        }
        try self.linkPhase(optimized_files orelse object_files);

        if (self.config.verbose) {
            std.debug.print("\n✓ Build completed successfully: {s}\n", .{self.config.output_path});
        }
    }

    /// Phase 1: Compile sources to IR/object files
    fn compilePhase(self: *BuildPipeline) ![]const []const u8 {
        // Initialize parallel builder
        var builder = try parallel_build.ParallelBuilder.initWithIo(
            self.allocator,
            null, // Auto-detect threads
            self.cache_dir,
            "0.1.0",
            self.io,
        );
        defer builder.deinit();

        builder.verbose = self.config.verbose;
        builder.setAggressiveMode(true);

        // Add compilation tasks
        for (self.config.sources) |source| {
            const module_name = std.fs.path.stem(source);

            // Parse dependencies from source
            const deps = try self.parseDependencies(source);
            defer freePathList(self.allocator, deps);

            try builder.addTask(module_name, source, deps);
        }

        // Compile in parallel
        try builder.build();

        if (self.config.verbose) {
            builder.printCacheStats();
        }

        // Collect object file paths
        var object_files: std.ArrayList([]const u8) = .empty;
        defer object_files.deinit(self.allocator);
        errdefer for (object_files.items) |path| self.allocator.free(path);

        for (builder.tasks.items) |task| {
            if (task.status == .Completed) {
                const obj_path = try std.fmt.allocPrint(
                    self.allocator,
                    "{s}/{s}.o",
                    .{ self.intermediate_dir, task.module_name },
                );
                errdefer self.allocator.free(obj_path);
                try object_files.append(self.allocator, obj_path);
            }
        }

        return try object_files.toOwnedSlice(self.allocator);
    }

    /// Phase 2: Link-time optimization
    fn ltoPhase(self: *BuildPipeline, object_files: []const []const u8) ![]const []const u8 {
        // Determine LTO level
        var lto_config = self.config.lto_config;
        if (lto_config.level == .Auto) {
            lto_config.level = lto.LtoLevel.fromBuildMode(self.config.optimize);
        }
        lto_config.verbose = self.config.verbose;

        // Initialize LTO optimizer
        var optimizer = lto.LtoOptimizer.init(self.allocator, self.io, lto_config);
        defer optimizer.deinit();

        // Add modules
        for (object_files) |obj_path| {
            const module_name = std.fs.path.stem(obj_path);
            const ir_path = try std.fmt.allocPrint(
                self.allocator,
                "{s}/{s}.ir",
                .{ self.cache_dir, module_name },
            );
            defer self.allocator.free(ir_path);

            var module = try lto.IrModule.init(
                self.allocator,
                module_name,
                ir_path,
                obj_path,
            );
            errdefer module.deinit();

            try optimizer.addModule(module);
        }

        // Run LTO optimization
        try optimizer.optimize();

        // Emit optimized output
        const optimized_dir = try std.fmt.allocPrint(
            self.allocator,
            "{s}/lto",
            .{self.intermediate_dir},
        );
        defer self.allocator.free(optimized_dir);

        std.Io.Dir.cwd().createDir(self.io, optimized_dir, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        const optimized_output = try std.fmt.allocPrint(
            self.allocator,
            "{s}/optimized.o",
            .{optimized_dir},
        );
        errdefer self.allocator.free(optimized_output);

        try optimizer.emitOptimized(optimized_output);

        // Return single optimized object file
        const result = try self.allocator.alloc([]const u8, 1);
        result[0] = optimized_output;
        return result;
    }

    /// Phase 3: Link object files
    fn linkPhase(self: *BuildPipeline, object_files: []const []const u8) !void {
        // Generate linker script if requested
        var script_path_owned: ?[]const u8 = null;
        defer if (script_path_owned) |p| self.allocator.free(p);

        const script_path = if (self.config.generate_linker_script) blk: {
            if (self.config.linker_template) |template| {
                const path = try self.generateLinkerScript(template);
                script_path_owned = path;
                break :blk path;
            } else {
                break :blk self.config.linker_script_path;
            }
        } else self.config.linker_script_path;

        // Configure linker
        const linker_config = linker_script.LinkerConfig{
            .type_ = .Lld,
            .script_path = script_path,
            .output_path = self.config.output_path,
            .object_files = object_files,
            .gc_sections = self.config.optimize != .debug,
            .strip = self.config.optimize == .small,
            .verbose = self.config.verbose,
        };

        var linker = linker_script.Linker.init(self.allocator, self.io, linker_config);

        // Link
        try linker.link();
    }

    /// Generate linker script from template
    fn generateLinkerScript(self: *BuildPipeline, template: BuildConfig.LinkerTemplate) ![]const u8 {
        var script = switch (template) {
            .ArmCortexM => try linker_script.TargetConfig.armCortexM(
                self.allocator,
                128 * 1024, // 128KB flash
                32 * 1024, // 32KB RAM
            ),
            .X86_64Kernel => try linker_script.TargetConfig.x86_64Kernel(
                self.allocator,
                0xFFFFFFFF80000000, // Higher half kernel
            ),
            .RiscVBareMetal => try linker_script.TargetConfig.riscvBareMetal(
                self.allocator,
                0x80000000,
                64 * 1024, // 64KB RAM
            ),
            .Hosted => blk: {
                // Standard hosted environment - no custom script needed
                var s = linker_script.LinkerScript.init(self.allocator);
                s.entry = "main";
                break :blk s;
            },
        };
        defer script.deinit();

        // Validate script
        try script.validate();

        // Write to file
        const script_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/linker.ld",
            .{self.intermediate_dir},
        );

        const file = try std.Io.Dir.cwd().createFile(self.io, script_path, .{});
        defer file.close(self.io);

        var buffer: [4096]u8 = undefined;
        var writer = file.writer(self.io, &buffer);
        try script.generateGnuLd(&writer.interface);
        try writer.interface.flush();

        if (self.config.verbose) {
            std.debug.print("Generated linker script: {s}\n", .{script_path});
        }

        return script_path;
    }

    /// Create intermediate directories
    fn createDirectories(self: *BuildPipeline) !void {
        try std.Io.Dir.cwd().createDirPath(self.io, self.intermediate_dir);
        try std.Io.Dir.cwd().createDirPath(self.io, self.cache_dir);
    }

    /// Parse module dependencies from source file
    fn parseDependencies(self: *BuildPipeline, source_path: []const u8) ![]const []const u8 {
        // Read source file
        const file_content = std.Io.Dir.cwd().readFileAlloc(
            self.io,
            source_path,
            self.allocator,
            .limited(10 * 1024 * 1024),
        ) catch |err| {
            if (self.config.verbose) {
                std.debug.print("Warning: Could not read {s} for dependency parsing: {}\n", .{ source_path, err });
            }
            return self.allocator.alloc([]const u8, 0);
        };
        defer self.allocator.free(file_content);

        // Parse import statements
        // Look for patterns like:
        //   import "module_name"
        //   from "module_name" import ...
        var deps: std.ArrayList([]const u8) = .empty;
        defer deps.deinit(self.allocator);
        errdefer for (deps.items) |dep| self.allocator.free(dep);

        var line_iter = std.mem.splitScalar(u8, file_content, '\n');
        while (line_iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");

            // Check for import statements
            if (std.mem.startsWith(u8, trimmed, "import ")) {
                // Extract module name from: import "module_name"
                if (std.mem.indexOf(u8, trimmed, "\"")) |first_quote| {
                    if (std.mem.indexOf(u8, trimmed[first_quote + 1 ..], "\"")) |second_quote_rel| {
                        const module_name = trimmed[first_quote + 1 .. first_quote + 1 + second_quote_rel];
                        const owned_module = try self.allocator.dupe(u8, module_name);
                        errdefer self.allocator.free(owned_module);
                        try deps.append(self.allocator, owned_module);
                    }
                }
            } else if (std.mem.startsWith(u8, trimmed, "from ")) {
                // Extract module name from: from "module_name" import ...
                if (std.mem.indexOf(u8, trimmed, "\"")) |first_quote| {
                    if (std.mem.indexOf(u8, trimmed[first_quote + 1 ..], "\"")) |second_quote_rel| {
                        const module_name = trimmed[first_quote + 1 .. first_quote + 1 + second_quote_rel];
                        const owned_module = try self.allocator.dupe(u8, module_name);
                        errdefer self.allocator.free(owned_module);
                        try deps.append(self.allocator, owned_module);
                    }
                }
            }
        }

        return try deps.toOwnedSlice(self.allocator);
    }
};

// ============================================================================
// Build Profiles
// ============================================================================

pub const BuildProfile = struct {
    /// Development profile: fast compilation, no optimizations
    pub fn dev(allocator: std.mem.Allocator, sources: []const []const u8, output: []const u8) BuildConfig {
        _ = allocator;
        return .{
            .optimize = .debug,
            .target = @import("builtin").target,
            .output_path = output,
            .sources = sources,
            .lto_enabled = false,
            .verbose = true,
        };
    }

    /// Release profile: full optimizations, LTO enabled
    pub fn release(allocator: std.mem.Allocator, sources: []const []const u8, output: []const u8) BuildConfig {
        _ = allocator;
        return .{
            .optimize = .fast,
            .target = @import("builtin").target,
            .output_path = output,
            .sources = sources,
            .lto_enabled = true,
            .lto_config = .{
                .level = .Fat,
                .ipo = true,
                .cross_module_inline = true,
                .dce = true,
                .const_prop = true,
                .merge_functions = true,
                .globopt = true,
            },
            .verbose = false,
        };
    }

    /// Size-optimized profile: minimize binary size
    pub fn releaseSmall(allocator: std.mem.Allocator, sources: []const []const u8, output: []const u8) BuildConfig {
        _ = allocator;
        return .{
            .optimize = .small,
            .target = @import("builtin").target,
            .output_path = output,
            .sources = sources,
            .lto_enabled = true,
            .lto_config = .{
                .level = .Fat,
                .ipo = true,
                .cross_module_inline = true,
                .dce = true,
                .const_prop = true,
                .merge_functions = true,
                .globopt = true,
            },
            .verbose = false,
        };
    }

    /// Embedded ARM Cortex-M profile
    pub fn armCortexM(allocator: std.mem.Allocator, sources: []const []const u8, output: []const u8) BuildConfig {
        _ = allocator;
        return .{
            .optimize = .small,
            .target = std.Target{
                .cpu = std.Target.Cpu{
                    .arch = .thumb,
                    .model = &std.Target.arm.cpu.cortex_m4,
                    .features = std.Target.Cpu.Feature.Set.empty,
                },
                .os = std.Target.Os{
                    .tag = .freestanding,
                    .version_range = .{ .none = {} },
                },
                .abi = .eabi,
                .ofmt = .elf,
            },
            .output_path = output,
            .sources = sources,
            .lto_enabled = true,
            .generate_linker_script = true,
            .linker_template = .ArmCortexM,
            .verbose = true,
        };
    }

    /// x86-64 kernel profile
    pub fn x86_64Kernel(allocator: std.mem.Allocator, sources: []const []const u8, output: []const u8) BuildConfig {
        _ = allocator;
        return .{
            .optimize = .fast,
            .target = std.Target{
                .cpu = std.Target.Cpu{
                    .arch = .x86_64,
                    .model = &std.Target.x86.cpu.x86_64,
                    .features = std.Target.Cpu.Feature.Set.empty,
                },
                .os = std.Target.Os{
                    .tag = .freestanding,
                    .version_range = .{ .none = {} },
                },
                .abi = .none,
                .ofmt = .elf,
            },
            .output_path = output,
            .sources = sources,
            .lto_enabled = true,
            .generate_linker_script = true,
            .linker_template = .X86_64Kernel,
            .verbose = true,
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "build pipeline creation" {
    const allocator = std.testing.allocator;

    const sources = [_][]const u8{ "main.home", "utils.home" };
    const config = BuildProfile.dev(allocator, &sources, "test_output");

    var pipeline = try BuildPipeline.init(allocator, std.testing.io, config);
    defer pipeline.deinit();

    try std.testing.expectEqual(std.builtin.OptimizeMode.debug, pipeline.config.optimize);
    try std.testing.expect(!pipeline.config.lto_enabled);
}

test "build profiles" {
    const allocator = std.testing.allocator;
    const sources = [_][]const u8{"main.home"};

    const dev = BuildProfile.dev(allocator, &sources, "dev_output");
    try std.testing.expectEqual(std.builtin.OptimizeMode.debug, dev.optimize);
    try std.testing.expect(!dev.lto_enabled);

    const release = BuildProfile.release(allocator, &sources, "release_output");
    try std.testing.expectEqual(std.builtin.OptimizeMode.fast, release.optimize);
    try std.testing.expect(release.lto_enabled);
    try std.testing.expectEqual(lto.LtoLevel.Fat, release.lto_config.level);
}
