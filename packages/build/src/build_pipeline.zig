// Home Programming Language - Complete Build Pipeline
// Integrates compilation, LTO, and linking with linker scripts

const std = @import("std");
const parallel_build = @import("parallel_build.zig");
const lto = @import("lto.zig");
const linker_script = @import("linker_script.zig");

// ============================================================================
// Build Configuration
// ============================================================================

pub const BuildConfig = struct {
    /// Optimization mode
    optimize: std.builtin.OptimizeMode = .Debug,
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
    config: BuildConfig,
    intermediate_dir: []const u8,
    cache_dir: []const u8,

    pub fn init(allocator: std.mem.Allocator, config: BuildConfig) !BuildPipeline {
        return .{
            .allocator = allocator,
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
        defer self.allocator.free(object_files);

        // Phase 2: Link-time optimization (if enabled)
        var optimized_files = object_files;
        if (self.config.lto_enabled and self.config.optimize != .Debug) {
            if (self.config.verbose) {
                std.debug.print("\n=== Phase 2: Link-Time Optimization ===\n", .{});
            }
            optimized_files = try self.ltoPhase(object_files);
        } else if (self.config.verbose) {
            std.debug.print("\n=== Phase 2: Link-Time Optimization (skipped) ===\n", .{});
        }

        // Phase 3: Linking with optional custom linker script
        if (self.config.verbose) {
            std.debug.print("\n=== Phase 3: Linking ===\n", .{});
        }
        try self.linkPhase(optimized_files);

        if (self.config.verbose) {
            std.debug.print("\n✓ Build completed successfully: {s}\n", .{self.config.output_path});
        }
    }

    /// Phase 1: Compile sources to IR/object files
    fn compilePhase(self: *BuildPipeline) ![]const []const u8 {
        // Initialize parallel builder
        var builder = try parallel_build.ParallelBuilder.init(
            self.allocator,
            null, // Auto-detect threads
            self.cache_dir,
            "0.1.0",
        );
        defer builder.deinit();

        builder.verbose = self.config.verbose;
        builder.setAggressiveMode(true);

        // Add compilation tasks
        for (self.config.sources) |source| {
            const module_name = std.fs.path.stem(source);

            // TODO: Parse dependencies from source
            const deps = &[_][]const u8{};

            try builder.addTask(module_name, source, deps);
        }

        // Compile in parallel
        try builder.build();

        if (self.config.verbose) {
            builder.printCacheStats();
        }

        // Collect object file paths
        var object_files = std.ArrayList([]const u8).init(self.allocator);
        defer object_files.deinit();

        for (builder.tasks.items) |task| {
            if (task.status == .Completed) {
                const obj_path = try std.fmt.allocPrint(
                    self.allocator,
                    "{s}/{s}.o",
                    .{ self.intermediate_dir, task.module_name },
                );
                try object_files.append(obj_path);
            }
        }

        return try object_files.toOwnedSlice();
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
        var optimizer = lto.LtoOptimizer.init(self.allocator, lto_config);
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

            const module = try lto.IrModule.init(
                self.allocator,
                module_name,
                ir_path,
                obj_path,
            );

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

        std.fs.cwd().makeDir(optimized_dir) catch {};

        const optimized_output = try std.fmt.allocPrint(
            self.allocator,
            "{s}/optimized.o",
            .{optimized_dir},
        );

        try optimizer.emitOptimized(optimized_output);

        // Return single optimized object file
        var result = try self.allocator.alloc([]const u8, 1);
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
            .gc_sections = self.config.optimize != .Debug,
            .strip = self.config.optimize == .ReleaseSmall,
            .verbose = self.config.verbose,
        };

        var linker = linker_script.Linker.init(self.allocator, linker_config);

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

        const file = try std.fs.cwd().createFile(script_path, .{});
        defer file.close();

        try script.generateGnuLd(file.writer());

        if (self.config.verbose) {
            std.debug.print("Generated linker script: {s}\n", .{script_path});
        }

        return script_path;
    }

    /// Create intermediate directories
    fn createDirectories(self: *BuildPipeline) !void {
        std.fs.cwd().makeDir(self.intermediate_dir) catch {};
        std.fs.cwd().makeDir(self.cache_dir) catch {};
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
            .optimize = .Debug,
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
            .optimize = .ReleaseFast,
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
            .optimize = .ReleaseSmall,
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
            .optimize = .ReleaseSmall,
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
            .optimize = .ReleaseFast,
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

    var pipeline = try BuildPipeline.init(allocator, config);
    defer pipeline.deinit();

    try std.testing.expectEqual(std.builtin.OptimizeMode.Debug, pipeline.config.optimize);
    try std.testing.expect(!pipeline.config.lto_enabled);
}

test "build profiles" {
    const allocator = std.testing.allocator;
    const sources = [_][]const u8{"main.home"};

    const dev = BuildProfile.dev(allocator, &sources, "dev_output");
    try std.testing.expectEqual(std.builtin.OptimizeMode.Debug, dev.optimize);
    try std.testing.expect(!dev.lto_enabled);

    const release = BuildProfile.release(allocator, &sources, "release_output");
    try std.testing.expectEqual(std.builtin.OptimizeMode.ReleaseFast, release.optimize);
    try std.testing.expect(release.lto_enabled);
    try std.testing.expectEqual(lto.LtoLevel.Fat, release.lto_config.level);
}
