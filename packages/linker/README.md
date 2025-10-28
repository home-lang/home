# Home OS Linker Script Control

A comprehensive linker script generation and control system for the Home Operating System. This package provides high-level APIs for creating, validating, and generating linker scripts for OS development.

## Features

- ✅ **Custom Section Placement** - Fine-grained control over where sections are placed in memory
- ✅ **Symbol Visibility Control** - Manage symbol visibility (global, local, weak, hidden, protected)
- ✅ **Memory Region Definitions** - Define memory regions with attributes (readable, writable, executable)
- ✅ **Kernel/User Space Separation** - Built-in support for kernel and user space layouts
- ✅ **Script Validation** - Comprehensive validation catches errors before linking
- ✅ **Script Generation** - Generate linker scripts from high-level descriptions
- ✅ **Multiple Architectures** - Support for x86-64, ARM64, embedded systems
- ✅ **Preset Layouts** - Common layouts (kernel, higher-half, embedded) ready to use
- ✅ **Type-Safe API** - Zig's type system prevents common linker script errors

## Quick Start

### Simple Kernel Script

```zig
const linker = @import("linker");

// Create a simple kernel script at 1MB
var script = try linker.LinkerScript.kernelScript(
    allocator,
    "my-kernel",
    0x10_0000, // 1MB
);
defer script.deinit();

// Generate to file
try script.generateToFile("kernel.ld", .{
    .validate = true,
    .include_comments = true,
});
```

### Higher-Half Kernel

```zig
// Create a higher-half kernel script (kernel at -2GB)
var script = try linker.LinkerScript.higherHalfScript(
    allocator,
    "higher-half-kernel",
);
defer script.deinit();

// Validate before generating
const result = try script.validate();
defer result.deinit();

if (result.valid) {
    try script.generateToFile("higher_half.ld", .{});
}
```

### Custom Configuration

```zig
// Build a completely custom layout
var script = linker.LinkerScript.init(allocator, "custom");
defer script.deinit();

// Add memory regions
try script.addKernelRegion(0x10_0000, 64 * 1024 * 1024);

// Add sections
try script.addStandardSections("kernel", 0x10_0000);

// Add custom section
try script.addSection(
    linker.Section.init(".kheap", .Custom, .{
        .alloc = true,
        .writable = true,
    }).withAlignment(.Page).withRegion("kernel")
);

// Add symbols
try script.addStandardSymbols();
try script.addSymbol(linker.Symbol.init(
    "_kheap_start",
    .Section,
    .Global,
).withSection(".kheap"));

// Generate with validation
try script.generateToFile("custom.ld", .{ .validate = true });
```

## Architecture

The linker package is organized into several modules:

### Core Modules

- **`linker.zig`** - Main module with types, enums, and utilities
- **`memory.zig`** - Memory region definitions and standard layouts
- **`section.zig`** - Section placement and configuration
- **`symbol.zig`** - Symbol visibility control and management
- **`script.zig`** - High-level linker script API
- **`validator.zig`** - Validation engine for catching errors
- **`generator.zig`** - Linker script generator

### Key Types

#### Memory Layout

```zig
pub const MemoryLayout = enum {
    Kernel,        // Simple kernel at specified address
    UserSpace,     // User-space only
    KernelUser,    // Kernel + user space
    Embedded,      // Embedded system (Flash + RAM)
    Custom,        // Fully custom
};
```

#### Section Types

```zig
pub const SectionType = enum {
    Text,      // Executable code
    Rodata,    // Read-only data
    Data,      // Initialized data
    Bss,       // Uninitialized data
    TData,     // Thread-local initialized data
    Tbss,      // Thread-local uninitialized data
    Init,      // Initialization code
    Fini,      // Finalization code
    Debug,     // Debug information
    Custom,    // Custom section
};
```

#### Symbol Visibility

```zig
pub const SymbolVisibility = enum {
    Local,      // File-local symbol
    Global,     // Globally visible
    Weak,       // Weak symbol (can be overridden)
    Hidden,     // Hidden (not exported)
    Protected,  // Protected (visible but not preemptible)
    Internal,   // Internal (not visible outside shared object)
};
```

## Memory Regions

Memory regions define where code and data can be placed:

```zig
const region = linker.MemoryRegion.init(
    "kernel",           // Name
    0x10_0000,          // Base address
    64 * 1024 * 1024,   // Size (64MB)
    .{
        .readable = true,
        .writable = true,
        .executable = true,
        .cacheable = true,
    },
);
```

### Standard Regions

```zig
// x86-64 higher-half kernel
const regions = linker.StandardRegions.x86_64_higher_half();

// x86-64 lower-half kernel
const regions = linker.StandardRegions.x86_64_lower_half();

// ARM64 kernel
const regions = linker.StandardRegions.arm64_kernel();

// Embedded system (no MMU)
const regions = linker.StandardRegions.embedded_nommu();
```

## Sections

Sections define how code and data are organized:

```zig
// Standard text section
const text = linker.Section.init(".text", .Text, .{
    .alloc = true,
    .load = true,
    .readonly = true,
    .executable = true,
});

// With custom placement
const text_placed = text
    .withVma(0x10_0000)           // Virtual memory address
    .withAlignment(.Page)         // Page-aligned
    .withRegion("kernel");        // In kernel region
```

### Standard Sections

```zig
// Get all standard kernel sections (.text, .rodata, .data, .bss)
const sections = linker.StandardSections.kernel_sections();

// Individual sections
const text = linker.StandardSections.text();
const rodata = linker.StandardSections.rodata();
const data = linker.StandardSections.data();
const bss = linker.StandardSections.bss();

// TLS sections
const tdata = linker.StandardSections.tdata();
const tbss = linker.StandardSections.tbss();
```

## Symbols

Symbols define named addresses in the linker script:

```zig
// Section boundary symbol
const kernel_start = linker.Symbol.init(
    "__kernel_start",
    .Section,
    .Global,
).withSection(".text");

// Constant address symbol
const stack_top = linker.Symbol.init(
    "__stack_top",
    .Object,
    .Global,
).withValue(0x2000_0000);
```

### Standard Symbols

```zig
// Get all standard kernel symbols
const symbols = try linker.KernelSymbols.standard_symbols(allocator);

// Includes:
// - __kernel_start, __kernel_end
// - __text_start, __text_end
// - __rodata_start, __rodata_end
// - __data_start, __data_end
// - __bss_start, __bss_end
// - __tls_start, __tls_end
// - __stack_top, __stack_bottom
// - __heap_start, __heap_end
```

## Validation

The validator catches common errors:

```zig
const result = try script.validate();
defer result.deinit();

if (!result.valid) {
    std.debug.print("Errors:\n", .{});
    for (result.errors) |err| {
        std.debug.print("  {s}\n", .{err});
    }
}

if (result.warnings.len > 0) {
    std.debug.print("Warnings:\n", .{});
    for (result.warnings) |warn| {
        std.debug.print("  {}\n", .{warn});
    }
}
```

### What's Validated

- ✅ Overlapping memory regions
- ✅ Zero-size regions
- ✅ Overlapping sections
- ✅ Sections outside their regions
- ✅ Misaligned sections
- ✅ Duplicate symbols
- ✅ Undefined symbol references
- ✅ Invalid section flags
- ✅ Security issues (writable + executable)

## Generation

Generate linker scripts in multiple ways:

```zig
// To file
try script.generateToFile("output.ld", .{
    .validate = true,
    .include_comments = true,
    .verbose = false,
});

// To string
const script_text = try script.generateToString(.{
    .validate = true,
    .include_comments = false,
});
defer allocator.free(script_text);

// To writer
try script.generate(std.io.getStdOut().writer(), .{
    .validate = true,
    .include_comments = true,
});
```

## Alignment Utilities

Helper functions for address alignment:

```zig
// Align up to page boundary
const aligned = linker.alignUp(0x10001, .Page); // 0x11000

// Align down
const aligned = linker.alignDown(0x10fff, .Page); // 0x10000

// Check alignment
const is_aligned = linker.isAligned(0x10000, .Page); // true
```

### Alignment Values

```zig
pub const Alignment = enum(usize) {
    Byte = 1,
    Word = 2,
    DWord = 4,
    QWord = 8,
    Page = 4096,
    HugePage = 2 * 1024 * 1024,
    GigaPage = 1024 * 1024 * 1024,
};
```

## Examples

The `examples/` directory contains complete examples:

- **`kernel_example.zig`** - Simple kernel script generation
- **`higher_half_example.zig`** - Higher-half kernel with validation
- **`embedded_example.zig`** - Embedded system (ARM Cortex-M)
- **`custom_example.zig`** - Fully custom configuration

Run examples:

```bash
# Build all examples
zig build

# Run specific example
zig build run-kernel
zig build run-higher-half
zig build run-embedded
zig build run-custom

# Run all examples
zig build run-examples
```

## Templates

The `templates/` directory contains hand-written linker script templates:

- **`kernel.ld.template`** - Simple kernel at 1MB
- **`higher_half.ld.template`** - Higher-half kernel
- **`embedded.ld.template`** - ARM Cortex-M embedded system

## Testing

Comprehensive test suite:

```bash
# Run all tests
zig build test

# Individual test modules
zig test src/linker.zig
zig test src/memory.zig
zig test src/section.zig
zig test src/symbol.zig
zig test src/validator.zig
zig test src/generator.zig
zig test src/script.zig
zig test tests/linker_test.zig
```

### Test Coverage

- ✅ 80+ unit tests across all modules
- ✅ 20+ integration tests
- ✅ Memory region operations
- ✅ Section placement and ordering
- ✅ Symbol management
- ✅ Validation (errors and warnings)
- ✅ Script generation
- ✅ Complete end-to-end workflows

## Use Cases

### OS Development

Perfect for building operating systems:

- Kernel linker scripts with custom memory layouts
- Higher-half kernels with identity mapping
- Kernel/user space separation
- Custom sections for kernel heap, stack, per-CPU data

### Embedded Systems

Ideal for embedded development:

- Flash + RAM memory layouts
- Vector table placement
- Data initialization (copy from flash to RAM)
- Stack and heap management

### Bootloaders

Great for bootloader development:

- Multiboot2 header placement
- Boot code at specific physical addresses
- Early page table setup sections

## Performance

- **Fast validation**: O(n²) for overlap checks, O(n) for most validations
- **Efficient generation**: Single-pass generation with buffered I/O
- **Low memory overhead**: ~256 bytes per region/section/symbol

## License

MIT License - See LICENSE file for details

## Contributing

Contributions welcome! Please ensure:

- All tests pass (`zig build test`)
- New features include tests
- Code follows existing style
- Documentation is updated

## Status

✅ **Production Ready**

- Complete API implementation
- Comprehensive test coverage
- Multiple examples and templates
- Full documentation
- Validation and error handling
- Performance optimized

Version: 0.1.0
