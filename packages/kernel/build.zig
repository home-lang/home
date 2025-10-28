const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ========================================================================
    // Kernel Configuration
    // ========================================================================

    // Force x86_64 target for kernel (freestanding OS)
    const kernel_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
    });

    // ========================================================================
    // Kernel Executable
    // ========================================================================

    const kernel = b.addExecutable(.{
        .name = "home-kernel.elf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/boot.zig"),
            .target = kernel_target,
            .optimize = optimize,
        }),
    });

    // Disable stack protector (not available in freestanding environment)
    kernel.root_module.stack_protector = false;

    // Disable red zone (required for kernel development)
    kernel.root_module.red_zone = false;

    // Set code model for kernel
    kernel.root_module.code_model = .kernel;

    // Add kernel dependencies
    const basics_module = b.createModule(.{
        .root_source_file = b.path("../../packages/basics/src/basics.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    kernel.root_module.addImport("basics", basics_module);

    // Use custom linker script
    kernel.setLinkerScript(b.path("linker.ld"));

    // Add boot assembly file
    kernel.addAssemblyFile(b.path("src/boot.s"));

    // Install kernel
    b.installArtifact(kernel);

    // ========================================================================
    // ISO Creation (Bootable Image)
    // ========================================================================

    const iso_dir = b.fmt("{s}/iso", .{b.install_path});
    const iso_file = b.fmt("{s}/home-os.iso", .{b.install_path});

    // Step 1: Create ISO directory structure
    const create_iso_dir = b.addSystemCommand(&[_][]const u8{
        "mkdir",
        "-p",
        b.fmt("{s}/boot/grub", .{iso_dir}),
    });

    // Step 2: Copy kernel to ISO directory
    const copy_kernel = b.addSystemCommand(&[_][]const u8{
        "cp",
        b.getInstallPath(.bin, "home-kernel.elf"),
        b.fmt("{s}/boot/home-kernel.elf", .{iso_dir}),
    });
    copy_kernel.step.dependOn(b.getInstallStep());
    copy_kernel.step.dependOn(&create_iso_dir.step);

    // Step 3: Copy GRUB configuration
    const copy_grub_cfg = b.addSystemCommand(&[_][]const u8{
        "cp",
        "iso/boot/grub/grub.cfg",
        b.fmt("{s}/boot/grub/grub.cfg", .{iso_dir}),
    });
    copy_grub_cfg.step.dependOn(&create_iso_dir.step);

    // Step 4: Create ISO image using grub-mkrescue
    const create_iso = b.addSystemCommand(&[_][]const u8{
        "grub-mkrescue",
        "-o",
        iso_file,
        iso_dir,
    });
    create_iso.step.dependOn(&copy_kernel.step);
    create_iso.step.dependOn(&copy_grub_cfg.step);

    const iso_step = b.step("iso", "Create bootable ISO image");
    iso_step.dependOn(&create_iso.step);

    // ========================================================================
    // QEMU Testing
    // ========================================================================

    // Run kernel in QEMU (standard mode)
    const qemu_run = b.addSystemCommand(&[_][]const u8{
        "qemu-system-x86_64",
        "-cdrom",
        iso_file,
        "-m",
        "512M",
        "-serial",
        "stdio",
        "-vga",
        "std",
    });
    qemu_run.step.dependOn(&create_iso.step);

    const qemu_step = b.step("qemu", "Run kernel in QEMU");
    qemu_step.dependOn(&qemu_run.step);

    // Run kernel in QEMU (debug mode with GDB)
    const qemu_debug = b.addSystemCommand(&[_][]const u8{
        "qemu-system-x86_64",
        "-cdrom",
        iso_file,
        "-m",
        "512M",
        "-serial",
        "stdio",
        "-vga",
        "std",
        "-s",        // GDB server on port 1234
        "-S",        // Start paused
    });
    qemu_debug.step.dependOn(&create_iso.step);

    const qemu_debug_step = b.step("qemu-debug", "Run kernel in QEMU with GDB support");
    qemu_debug_step.dependOn(&qemu_debug.step);

    // Run kernel in QEMU (with KVM acceleration)
    const qemu_kvm = b.addSystemCommand(&[_][]const u8{
        "qemu-system-x86_64",
        "-cdrom",
        iso_file,
        "-m",
        "512M",
        "-serial",
        "stdio",
        "-vga",
        "std",
        "-enable-kvm",
        "-cpu",
        "host",
    });
    qemu_kvm.step.dependOn(&create_iso.step);

    const qemu_kvm_step = b.step("qemu-kvm", "Run kernel in QEMU with KVM acceleration");
    qemu_kvm_step.dependOn(&qemu_kvm.step);

    // ========================================================================
    // Kernel Module (for linking with other packages)
    // ========================================================================

    const kernel_module = b.addModule("kernel", .{
        .root_source_file = b.path("src/kernel.zig"),
        .target = target,
        .optimize = optimize,
    });
    kernel_module.addImport("basics", basics_module);

    // ========================================================================
    // Tests
    // ========================================================================

    // Multiboot2 tests
    const multiboot2_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/multiboot2.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_multiboot2_tests = b.addRunArtifact(multiboot2_tests);

    // Multiboot2 module for boot tests
    const multiboot2_module = b.createModule(.{
        .root_source_file = b.path("src/multiboot2.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Boot tests
    const boot_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/test_boot.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    boot_tests.root_module.addImport("basics", basics_module);
    boot_tests.root_module.addImport("multiboot2", multiboot2_module);

    const run_boot_tests = b.addRunArtifact(boot_tests);

    // Memory tests
    const memory_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/test_memory.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    memory_tests.root_module.addImport("kernel", kernel_module);

    const run_memory_tests = b.addRunArtifact(memory_tests);

    // Integration tests
    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/test_integration.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    integration_tests.root_module.addImport("kernel", kernel_module);

    const run_integration_tests = b.addRunArtifact(integration_tests);

    // Test step
    const test_step = b.step("test", "Run kernel tests");
    test_step.dependOn(&run_multiboot2_tests.step);
    test_step.dependOn(&run_boot_tests.step);
    test_step.dependOn(&run_memory_tests.step);
    test_step.dependOn(&run_integration_tests.step);

    // ========================================================================
    // Kernel Information
    // ========================================================================

    const kernel_info = b.addSystemCommand(&[_][]const u8{
        "sh",
        "-c",
        b.fmt("echo 'Kernel built successfully!' && " ++
            "echo 'Size: '$(stat -f%z {s}/home-kernel.elf) bytes && " ++
            "echo 'Target: x86_64-freestanding' && " ++
            "echo 'Optimize: {s}'", .{
            b.getInstallPath(.bin, ""),
            @tagName(optimize),
        }),
    });
    kernel_info.step.dependOn(b.getInstallStep());

    const info_step = b.step("info", "Display kernel build information");
    info_step.dependOn(&kernel_info.step);

    // ========================================================================
    // Clean
    // ========================================================================

    const clean = b.addSystemCommand(&[_][]const u8{
        "rm",
        "-rf",
        b.install_path,
        iso_dir,
    });

    const clean_step = b.step("clean", "Clean build artifacts");
    clean_step.dependOn(&clean.step);
}
