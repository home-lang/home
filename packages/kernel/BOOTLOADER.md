# Home OS Bootloader Documentation

## Overview

The Home OS bootloader implements the **Multiboot2 specification** to boot a 64-bit x86-64 kernel. This document describes the bootloader architecture, build process, and testing procedures.

## Architecture

### Boot Sequence

1. **BIOS/UEFI Stage** → Loads GRUB2 bootloader
2. **GRUB2 Stage** → Reads Multiboot2 header, loads kernel into memory
3. **Boot Assembly (boot.s)** → 32-bit protected mode entry point
4. **Long Mode Transition** → Setup paging, switch to 64-bit mode
5. **Kernel Entry (boot.zig)** → Parse boot info, initialize kernel

### Memory Layout

```
0x0000000000000000 - 0x0000000000000fff : Null page (unmapped)
0x0000000000001000 - 0x00000000000fffff : Low memory (BIOS, VGA, etc.)
0x0000000000100000 - 0x00000000ffffffff : Kernel space (loaded at 1MB)
0xffff800000000000 - 0xffffffffffffffff : Higher half kernel (future)
```

## Components

### 1. Multiboot2 Header (`multiboot2.zig`)

**Purpose:** Defines Multiboot2 data structures and parsing functions

**Key Features:**
- Magic number verification
- Tag-based information parsing
- Memory map interpretation
- Framebuffer info extraction
- Command line parsing

**Example Usage:**
```zig
const mb_info = multiboot2.Multiboot2Info.fromAddress(info_addr);

// Get memory map
if (mb_info.getMemoryMap()) |mmap| {
    for (mmap.entries()) |entry| {
        // Process memory region
    }
}

// Get command line
if (mb_info.getCommandLine()) |cmdline| {
    // Parse kernel arguments
}
```

### 2. Boot Assembly (`boot.s`)

**Purpose:** Early boot code that transitions from 32-bit to 64-bit mode

**Key Operations:**
1. **CPUID Check** - Verify CPU supports long mode
2. **Page Tables** - Setup identity-mapped pages (first 1GB)
3. **PAE Enable** - Enable Physical Address Extension
4. **Long Mode** - Enable 64-bit mode via EFER MSR
5. **Paging** - Enable paging in CR0
6. **GDT Load** - Load 64-bit Global Descriptor Table
7. **Jump** - Far jump to 64-bit kernel entry

**Memory Layout:**
- Stack: 16KB (`.bss` section)
- PML4: 4KB page table (level 4)
- PDPT: 4KB page table (level 3)
- PD: 4KB page table (level 2, 2MB pages)

### 3. Kernel Entry Point (`boot.zig`)

**Purpose:** Main kernel initialization in 64-bit mode

**Initialization Sequence:**
1. Initialize VGA and serial console
2. Verify Multiboot2 magic number
3. Parse Multiboot2 information
4. Initialize GDT (Global Descriptor Table)
5. Initialize IDT (Interrupt Descriptor Table)
6. Setup memory management
7. Initialize paging
8. Enable interrupts

### 4. Linker Script (`linker.ld`)

**Purpose:** Controls memory layout and section placement

**Key Sections:**
- `.multiboot` - Multiboot2 header (must be in first 32KB)
- `.text` - Kernel code (4KB aligned)
- `.rodata` - Read-only data (4KB aligned)
- `.data` - Initialized data (4KB aligned)
- `.bss` - Uninitialized data (4KB aligned)
- `.tdata/.tbss` - Thread-local storage

**Symbols Exported:**
- `__kernel_start` / `__kernel_end` - Kernel boundaries
- `__text_start` / `__text_end` - Code section
- `__bss_start` / `__bss_end` - BSS section
- `__tls_start` / `__tls_end` - TLS section

### 5. GRUB Configuration (`grub.cfg`)

**Purpose:** Bootloader menu configuration

**Boot Options:**
- **Default** - Normal boot
- **Debug Mode** - Boot with verbose logging
- **Safe Mode** - Boot with minimal features
- **Memory Test** - Run memtest86+ (if available)

## Building

### Prerequisites

```bash
# macOS
brew install qemu grub xorriso

# Ubuntu/Debian
sudo apt install qemu-system-x86 grub-pc-bin xorriso

# Arch Linux
sudo pacman -S qemu grub xorriso
```

### Build Commands

```bash
# Navigate to kernel directory
cd packages/kernel

# Build kernel (debug mode)
zig build

# Build kernel (release mode)
zig build -Doptimize=ReleaseFast

# Create bootable ISO
zig build iso

# Run in QEMU
zig build qemu

# Run in QEMU with GDB support
zig build qemu-debug

# Run in QEMU with KVM acceleration
zig build qemu-kvm

# Display kernel info
zig build info

# Run all tests
zig build test

# Clean build artifacts
zig build clean
```

### Using the Build Script

```bash
# Build and run (debug mode)
./scripts/build-and-run.sh

# Build and run (release mode)
./scripts/build-and-run.sh --release

# Build and run with KVM
./scripts/build-and-run.sh --kvm

# Build and run with GDB
./scripts/build-and-run.sh --debug

# Clean and rebuild
./scripts/build-and-run.sh --clean

# Show help
./scripts/build-and-run.sh --help
```

## Testing

### Unit Tests

```bash
# Run all bootloader tests
zig build test

# Run specific test file
zig test tests/test_boot.zig
```

### Test Coverage

- ✅ Multiboot2 magic number verification
- ✅ Header checksum calculation
- ✅ Tag structure parsing
- ✅ Memory map parsing
- ✅ Tag iteration
- ✅ Framebuffer info extraction
- ✅ Mock boot info creation
- ✅ Alignment requirements
- ✅ Structure size validation

### Integration Testing (QEMU)

```bash
# Test basic boot
zig build qemu

# Expected output:
# ╔════════════════════════════════════════╗
# ║     Home Operating System v0.1.0      ║
# ║   Built with Home Programming Lang    ║
# ╚════════════════════════════════════════╝
#
# ✓ Multiboot2 magic verified
# === Multiboot2 Information ===
# Bootloader: GRUB 2.xx
# ...
```

### Debugging with GDB

```bash
# Terminal 1: Start QEMU with GDB server
zig build qemu-debug

# Terminal 2: Connect GDB
gdb zig-out/bin/home-kernel.elf
(gdb) target remote localhost:1234
(gdb) break kernel_main
(gdb) continue
```

## Boot Information Available

### From Multiboot2

- **Memory Map** - Physical memory regions
- **Command Line** - Kernel boot parameters
- **Bootloader Name** - GRUB version
- **Framebuffer** - Graphics mode info (if available)
- **ACPI Tables** - ACPI RSDP address
- **EFI System Table** - EFI info (if booted via UEFI)
- **Modules** - Loaded initrd/modules

### Parsed by Kernel

```zig
const mb_info = multiboot2.Multiboot2Info.fromAddress(info_addr);

// Memory information
const mmap = mb_info.getMemoryMap();
const basic_mem = mb_info.getBasicMeminfo();

// Boot parameters
const cmdline = mb_info.getCommandLine();
const bootloader = mb_info.getBootloaderName();

// Graphics
const fb = mb_info.getFramebuffer();

// Iterate all tags
var iter = mb_info.iterateTags();
while (iter.next()) |tag| {
    // Process tag
}
```

## Troubleshooting

### Kernel doesn't boot

**Problem:** QEMU shows blank screen
**Solution:**
1. Check if ISO was created: `ls zig-out/iso/home-os.iso`
2. Verify kernel was built: `ls zig-out/bin/home-kernel.elf`
3. Check serial output: `zig build qemu` (output goes to stdout)

### Multiboot2 header not found

**Problem:** GRUB says "no multiboot header found"
**Solution:**
1. Ensure `.multiboot` section is in first 32KB
2. Verify linker script places it correctly
3. Check with: `objdump -h zig-out/bin/home-kernel.elf | grep multiboot`

### Page fault on boot

**Problem:** Triple fault or page fault exception
**Solution:**
1. Verify page tables are correctly setup in `boot.s`
2. Check stack is properly aligned (16-byte boundary)
3. Enable QEMU debug: `qemu-system-x86_64 -d int,cpu_reset`

### GDB connection fails

**Problem:** GDB can't connect to localhost:1234
**Solution:**
1. Ensure QEMU is started with `-s -S` flags
2. Check if port 1234 is already in use: `lsof -i :1234`
3. Try different port: `-gdb tcp::5678`

## Advanced Topics

### Higher Half Kernel

To move kernel to higher half (0xffff800000000000):

1. Update linker script with higher base address
2. Modify page tables to map higher half
3. Update boot assembly to setup correct mapping
4. Add trampoline code to jump to higher half

### UEFI Boot

To support UEFI boot:

1. Add EFI entry point tags to multiboot2 header
2. Implement EFI boot services calls
3. Handle EFI memory map format
4. Support GOP (Graphics Output Protocol)

### Secure Boot

For secure boot support:

1. Sign kernel with valid certificate
2. Verify Multiboot2 module signatures
3. Implement measured boot (TPM)
4. Enable lockdown mode early

## References

- [Multiboot2 Specification](https://www.gnu.org/software/grub/manual/multiboot2/multiboot.html)
- [Intel 64 and IA-32 Architectures Software Developer's Manual](https://software.intel.com/content/www/us/en/develop/articles/intel-sdm.html)
- [OSDev Wiki - Bare Bones](https://wiki.osdev.org/Bare_Bones)
- [OSDev Wiki - Higher Half x86 Bare Bones](https://wiki.osdev.org/Higher_Half_x86_Bare_Bones)

## License

Part of the Home Programming Language project.
