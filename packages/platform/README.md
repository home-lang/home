// Home Programming Language - Platform-Specific Code Blocks
# Platform-Specific Code Blocks Package

Comprehensive platform detection and conditional compilation for handling x86, ARM, RISC-V, and OS differences in the Home programming language.

## Features

### Architecture Detection
- **x86**: 32-bit Intel/AMD
- **x86_64**: 64-bit Intel/AMD (AMD64)
- **ARM**: 32-bit ARM
- **AArch64**: 64-bit ARM (Apple Silicon, server ARM)
- **RISC-V**: riscv32 and riscv64
- **WebAssembly**: wasm32 and wasm64

### OS Detection
- **Linux**: All distributions
- **macOS**: Darwin/XNU kernel
- **Windows**: Win32/Win64
- **BSD**: FreeBSD, OpenBSD, NetBSD
- **WASI**: WebAssembly System Interface
- **Freestanding**: Bare metal/kernel mode

### Platform Categories
- **Unix**: Linux, macOS, BSD
- **BSD**: macOS, FreeBSD, OpenBSD, NetBSD
- **64-bit**: x86_64, aarch64, riscv64, wasm64

## Usage

### Platform Detection

```zig
const platform = @import("platform");

// Get current architecture
const arch = platform.Arch.current();
std.debug.print("Running on: {s}\n", .{arch.name()});

// Check architecture type
if (arch.isX86()) {
    // x86 or x86_64
}

if (arch.isARM()) {
    // arm or aarch64
}

if (arch.is64Bit()) {
    // 64-bit architecture
}

// Get current OS
const os = platform.OS.current();
std.debug.print("OS: {s}\n", .{os.name()});

// Check OS type
if (os.isUnix()) {
    // Linux, macOS, BSD
}

// Get full platform info
const plat = platform.Platform.current();
const name = try plat.name(allocator);
defer allocator.free(name);
std.debug.print("Platform: {s}\n", .{name}); // e.g., "x86_64-linux"
```

### Conditional Execution

```zig
// Execute only on x86/x86_64
platform.onX86(struct {
    fn impl() void {
        std.debug.print("Running x86-specific code\n", .{});
        // Use SSE/AVX instructions
    }
}.impl);

// Execute only on ARM/AArch64
platform.onARM(struct {
    fn impl() void {
        std.debug.print("Running ARM-specific code\n", .{});
        // Use NEON instructions
    }
}.impl);

// Execute only on specific architecture
platform.onArch(.aarch64, struct {
    fn impl() void {
        // Apple Silicon specific optimizations
    }
}.impl);

// Execute only on specific OS
platform.onOS(.linux, struct {
    fn impl() void {
        // Linux-specific code
    }
}.impl);

// Execute only on Unix-like systems
platform.onUnix(struct {
    fn impl() void {
        // POSIX-compliant code
    }
}.impl);

// Execute on specific platform combination
platform.onPlatform(.x86_64, .linux, struct {
    fn impl() void {
        // x86_64 Linux specific
    }
}.impl);
```

### Compile-Time Value Selection

```zig
// Select value based on architecture
const page_size = platform.selectByArch(usize, .{
    .default = 4096,
    .x86_64 = 4096,
    .aarch64 = 16384, // Apple Silicon uses 16KB pages on macOS
});

// Select value based on OS
const path_sep = platform.selectByOS([]const u8, .{
    .default = "/",
    .windows = "\\",
});

// Complex architecture-specific configuration
const config = platform.selectByArch(Config, .{
    .default = .{ .cache_line = 64, .alignment = 8 },
    .x86_64 = .{ .cache_line = 64, .alignment = 16 },
    .aarch64 = .{ .cache_line = 64, .alignment = 16 },
    .riscv64 = .{ .cache_line = 64, .alignment = 16 },
});
```

### Architecture Features

```zig
const features = platform.ArchFeatures;

// Endianness
if (features.isLittleEndian()) {
    // Little-endian byte order (x86, ARM, RISC-V)
}

// Alignment requirements
if (features.strictAlignment()) {
    // Must use aligned memory access (ARM, RISC-V)
    // x86 allows unaligned access but it's slower
}

// Cache line size for optimization
const cache_line = features.cacheLineSize(); // Usually 64 bytes

// Page size for memory management
const page_size = features.pageSize(); // 4KB or 16KB

// Stack alignment for ABI compliance
const stack_align = features.stackAlignment(); // 16 bytes on x86_64, aarch64
```

### Platform-Specific Constants

```zig
const constants = platform.PlatformConstants;

// System call numbers differ by architecture
const exit_syscall = constants.SYSCALL_EXIT;
// x86_64: 60
// aarch64: 93
// riscv64: 93

const write_syscall = constants.SYSCALL_WRITE;
// x86_64: 1
// aarch64: 64
// riscv64: 64

// Signal numbers
const sigint = constants.SIGINT; // Ctrl+C
const sigsegv = constants.SIGSEGV; // Segmentation fault
```

### Code Block Selection

```zig
// Define platform-specific code blocks
const impl = platform.CodeBlock{
    .x86_64 =
        \\ mov rax, 60
        \\ xor rdi, rdi
        \\ syscall
    ,
    .aarch64 =
        \\ mov x8, #93
        \\ mov x0, #0
        \\ svc #0
    ,
    .riscv64 =
        \\ li a7, 93
        \\ li a0, 0
        \\ ecall
    ,
    .default = "/* Generic implementation */",
};

// Select appropriate code for current platform
const code = impl.select();
```

### Feature Detection

```zig
const features = platform.Features;

// Check SIMD availability
if (features.hasSIMD()) {
    // Use SSE/AVX on x86, NEON on ARM
}

// Check atomic operations
if (features.hasAtomics()) {
    // Use lock-free algorithms
}

// Check unaligned access efficiency
if (features.hasEfficientUnalignedAccess()) {
    // x86 - unaligned access is slow but works
} else {
    // ARM/RISC-V - use aligned access
}
```

## Real-World Examples

### Example 1: System Call Wrapper

```zig
pub fn exit(code: i32) noreturn {
    const syscall_num = platform.PlatformConstants.SYSCALL_EXIT;

    platform.onArch(.x86_64, struct {
        fn impl(num: usize, arg: i32) noreturn {
            asm volatile ("syscall"
                :
                : [number] "{rax}" (num),
                  [arg1] "{rdi}" (arg),
                : "rcx", "r11", "memory"
            );
            unreachable;
        }
    }.impl);

    platform.onArch(.aarch64, struct {
        fn impl(num: usize, arg: i32) noreturn {
            asm volatile ("svc #0"
                :
                : [number] "{x8}" (num),
                  [arg1] "{x0}" (arg),
                : "memory"
            );
            unreachable;
        }
    }.impl);

    _ = syscall_num;
    _ = code;
    unreachable;
}
```

### Example 2: SIMD Optimization

```zig
pub fn addVectors(dst: []f32, a: []const f32, b: []const f32) void {
    std.debug.assert(dst.len == a.len and a.len == b.len);

    if (platform.Arch.current().isX86() and platform.Features.hasSIMD()) {
        // Use SSE/AVX on x86_64
        addVectorsSSE(dst, a, b);
    } else if (platform.Arch.current().isARM() and platform.Features.hasSIMD()) {
        // Use NEON on AArch64
        addVectorsNEON(dst, a, b);
    } else {
        // Fallback scalar implementation
        for (dst, a, b) |*d, a_val, b_val| {
            d.* = a_val + b_val;
        }
    }
}
```

### Example 3: Memory Alignment

```zig
pub fn allocateAligned(allocator: std.mem.Allocator, size: usize) ![]u8 {
    const alignment = if (platform.ArchFeatures.strictAlignment())
        platform.ArchFeatures.cacheLineSize()
    else
        @sizeOf(usize);

    return try allocator.alignedAlloc(u8, alignment, size);
}
```

### Example 4: Path Handling

```zig
pub const PATH_SEPARATOR = platform.selectByOS([]const u8, .{
    .default = "/",
    .windows = "\\",
});

pub const LINE_ENDING = platform.selectByOS([]const u8, .{
    .default = "\n",
    .windows = "\r\n",
});

pub fn joinPath(allocator: std.mem.Allocator, parts: []const []const u8) ![]const u8 {
    return std.mem.join(allocator, PATH_SEPARATOR, parts);
}
```

### Example 5: Atomic Operations

```zig
pub fn atomicIncrement(ptr: *usize) usize {
    if (platform.Features.hasAtomics()) {
        return @atomicRmw(usize, ptr, .Add, 1, .seq_cst);
    } else {
        // Fallback for platforms without atomics
        const old = ptr.*;
        ptr.* += 1;
        return old;
    }
}
```

### Example 6: Stack Red Zone

```zig
// x86_64 ABI has 128-byte red zone below stack pointer
// AArch64 has no red zone
pub const STACK_RED_ZONE = platform.selectByArch(usize, .{
    .default = 0,
    .x86_64 = 128,
    .aarch64 = 0,
});
```

## Platform-Specific Differences

### x86 vs ARM

| Feature | x86/x86_64 | ARM/AArch64 |
|---------|------------|-------------|
| Endianness | Little | Little (typically) |
| Unaligned access | Allowed (slow) | Requires alignment |
| SIMD | SSE/AVX | NEON |
| Atomics | Native | LDREX/STREX or LSE |
| Stack alignment | 16 bytes | 16 bytes |
| Cache line | 64 bytes | 64 bytes |
| Page size | 4 KB | 4 KB or 16 KB |
| Syscall instruction | `syscall` | `svc #0` |

### Linux vs macOS vs Windows

| Feature | Linux | macOS | Windows |
|---------|-------|-------|---------|
| Path separator | `/` | `/` | `\` |
| Line ending | `\n` | `\n` | `\r\n` |
| Syscall interface | Direct | Direct | Indirect (ntdll) |
| Page size (x86_64) | 4 KB | 4 KB | 4 KB |
| Page size (aarch64) | 4 KB | 16 KB | 4 KB |

## Testing

Run the test suite:

```bash
cd packages/platform
zig build test
```

All 11 tests validate:
- Architecture detection
- OS detection
- Platform detection and naming
- Architecture categories (x86, ARM, RISC-V)
- Value selection by architecture
- Value selection by OS
- Architecture features (endianness, cache, alignment)
- Code block selection
- Feature detection (SIMD, atomics)
- Platform constants (syscalls, signals)
- Strict alignment requirements

## Integration

This package integrates with:
- **Codegen**: Generate platform-specific assembly
- **Syscall**: Use correct syscall numbers per platform
- **Memory**: Respect alignment requirements
- **Threading**: Use platform-specific atomics
- **Drivers**: Handle hardware differences

## Best Practices

1. **Default implementations**: Always provide a `.default` fallback
2. **Feature detection**: Use runtime checks for optional features
3. **Graceful degradation**: Fall back to portable code when optimizations unavailable
4. **Test on multiple platforms**: Validate behavior on x86_64, aarch64, etc.
5. **Document assumptions**: Note platform-specific behavior in comments
6. **Avoid hard-coding**: Use constants from `PlatformConstants`
7. **Respect alignment**: Use `ArchFeatures.strictAlignment()` checks

## Performance Considerations

- **Compile-time selection**: No runtime overhead for platform checks
- **Inline execution**: Conditional functions are inlined away
- **Zero-cost abstraction**: Resolves to native code for each platform
- **Optimized paths**: Enable SIMD and architecture-specific optimizations
