# Home OS Bootloader

A modern, secure UEFI bootloader designed to replace GRUB with native support for secure boot, multiple boot entries, and an intuitive boot menu.

## Features

- **UEFI Boot Protocol**: Full UEFI support with Boot Services and Runtime Services
- **Secure Boot**: UEFI Secure Boot integration with certificate verification
- **ELF Kernel Loading**: Native support for 64-bit ELF kernel binaries
- **Interactive Boot Menu**: User-friendly text-based menu with keyboard navigation
- **Multi-Format Configuration**: Parse GRUB2, systemd-boot, and native Home OS configs
- **Boot Entry Management**: Multiple boot entries with kernel, initrd, and command-line options

## Architecture

### Modules

```
bootloader/
├── bootloader.zig    # Main bootloader logic and boot entries
├── uefi.zig          # UEFI protocol definitions and interfaces
├── loader.zig        # ELF kernel loading and parsing
├── secure.zig        # Secure Boot verification
├── menu.zig          # Interactive boot menu
└── config.zig        # Configuration file parsing
```

### Boot Flow

```
┌─────────────────┐
│  UEFI Firmware  │
└────────┬────────┘
         │
         v
┌─────────────────┐
│   Bootloader    │
│   Entry Point   │
└────────┬────────┘
         │
         v
┌─────────────────┐
│  Load Config    │
│  Parse Entries  │
└────────┬────────┘
         │
         v
┌─────────────────┐
│   Boot Menu     │
│  (Interactive)  │
└────────┬────────┘
         │
         v
┌─────────────────┐
│  Verify Secure  │
│      Boot       │
└────────┬────────┘
         │
         v
┌─────────────────┐
│  Load Kernel    │
│  Parse ELF      │
└────────┬────────┘
         │
         v
┌─────────────────┐
│ Setup Boot Params│
│  Transfer Control│
└────────┬────────┘
         │
         v
┌─────────────────┐
│  Kernel Entry   │
└─────────────────┘
```

## Usage

### Boot Entry Configuration

#### Home OS Native Format

Create `/boot/home.conf`:

```conf
# Home OS Bootloader Configuration
timeout = 5
default = 0

entry "Home OS"
  kernel = /boot/vmlinuz-home
  initrd = /boot/initrd.img
  options = root=/dev/sda1 quiet splash

entry "Home OS (Recovery)"
  kernel = /boot/vmlinuz-home
  initrd = /boot/initrd.img
  options = root=/dev/sda1 single
```

#### GRUB2 Compatibility

The bootloader can parse existing GRUB2 configurations:

```bash
# GRUB configuration
GRUB_TIMEOUT=5
GRUB_DEFAULT=0

menuentry 'Home OS' {
    linux /boot/vmlinuz root=/dev/sda1 ro quiet splash
    initrd /boot/initrd.img
}

menuentry 'Recovery Mode' {
    linux /boot/vmlinuz root=/dev/sda1 single
}
```

#### systemd-boot Format

Also supports systemd-boot entry format:

```conf
timeout 3

title Home OS
linux /vmlinuz-linux
initrd /initramfs-linux.img
options root=/dev/sda2 rw quiet
```

### Programmatic Usage

```zig
const std = @import("std");
const bootloader = @import("bootloader");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize bootloader
    var boot = bootloader.Bootloader.init(allocator);
    defer boot.deinit();

    // Load configuration
    try boot.loadConfig("/boot/home.conf");

    // Create boot menu
    var menu = bootloader.menu.BootMenu.init(allocator, &boot.config);

    // Display menu and get selection (requires UEFI console)
    // const result = try menu.run(con_out);

    // Boot selected entry
    // try boot.boot(result.entry_index);
}
```

### Creating Boot Entries

```zig
const bootloader = @import("bootloader");

// Create a new boot entry
var entry = bootloader.BootEntry.init("My OS");
entry.setKernelPath("/boot/kernel.elf");
entry.setInitrdPath("/boot/initrd.img");
entry.setCmdline("root=/dev/nvme0n1p2 quiet");
entry.default = true;

// Add to configuration
try boot_config.addEntry(entry);
```

## UEFI Integration

### System Table

The bootloader accesses UEFI services through the System Table:

```zig
const uefi = @import("uefi");

// Access UEFI System Table (provided by firmware)
const system_table: *uefi.SystemTable = ...;

// Boot Services (memory allocation, image loading)
const boot_services = system_table.boot_services;

// Runtime Services (variables, time, reset)
const runtime_services = system_table.runtime_services;

// Console output
const con_out = system_table.con_out;
```

### Memory Management

```zig
// Allocate pages for kernel
const pages: usize = 1024; // 4MB
var address: u64 = 0;

const status = boot_services.allocate_pages(
    .any_pages,
    .loader_data,
    pages,
    &address,
);

if (status != .success) {
    return error.AllocationFailed;
}
```

### Console Output

```zig
const uefi = @import("uefi");

// Print to UEFI console
try uefi.UEFIHelper.print(con_out, "Booting Home OS...\n", allocator);

// Clear screen
uefi.UEFIHelper.clearScreen(con_out);
```

## Secure Boot

### Certificate Verification

The bootloader implements UEFI Secure Boot with certificate-based verification:

```zig
const secure = @import("secure");

// Initialize secure boot verifier
var verifier = secure.SecureBootVerifier.init(allocator);
defer verifier.deinit();

// Enable secure boot
verifier.enable();

// Add trusted certificate
const cert_data = try loadCertificate("/boot/certs/home-os.crt");
const cert = secure.Certificate.init(cert_data, .rsa2048_sha256);
try verifier.database.addCertificate(cert);

// Verify kernel binary
const kernel_data = try loadKernel("/boot/kernel.elf");
const signature = try loadSignature("/boot/kernel.sig");

const verified = try verifier.verifyBinary(kernel_data, &signature);
if (!verified) {
    return error.SignatureVerificationFailed;
}
```

### Security Features

- **Certificate Database**: Maintain allowed and forbidden certificates
- **Hash Blacklist**: Block known malicious binaries by hash
- **Signature Algorithms**: RSA-2048/3072/4096 and ECDSA-P256/P384
- **Validity Checking**: Certificate expiration and time validation
- **UEFI Variables**: Integration with PK, KEK, db, and dbx

## ELF Kernel Loading

### Loading Process

```zig
const loader = @import("loader");

// Initialize kernel loader
var kernel_loader = loader.KernelLoader.init(allocator);

// Load kernel from binary
const kernel_data = try std.fs.cwd().readFileAlloc(allocator, "/boot/kernel.elf", 10 * 1024 * 1024);
defer allocator.free(kernel_data);

// Parse ELF and prepare for execution
var loaded_kernel = try kernel_loader.loadKernel(kernel_data);
defer loaded_kernel.deinit();

// Access kernel information
std.debug.print("Entry point: 0x{x}\n", .{loaded_kernel.entry_point});
std.debug.print("Loaded segments: {d}\n", .{loaded_kernel.segments.items.len});

for (loaded_kernel.segments.items) |segment| {
    std.debug.print("  Virtual: 0x{x}, Physical: 0x{x}, Size: 0x{x}\n", .{
        segment.virtual_addr,
        segment.physical_addr,
        segment.size,
    });
}
```

### ELF Support

- **64-bit ELF**: Full support for x86_64 ELF binaries
- **Program Headers**: Parse and load LOAD segments
- **Entry Point**: Automatic detection of kernel entry point
- **Memory Layout**: Virtual and physical address mapping

## Boot Menu

### Features

- **Visual Selection**: Highlighted current selection
- **Keyboard Navigation**: Arrow keys, Enter, Escape
- **Auto-boot Timeout**: Configurable countdown timer
- **Entry Details**: Display kernel path and options
- **Command Line Editor**: Press 'E' to edit kernel parameters

### Menu Navigation

```
┌───────────────────────────────────────────────────────────┐
│                    Home OS Bootloader                     │
│                       Version 1.0.0                       │
└───────────────────────────────────────────────────────────┘

  > Home OS (default)
      Kernel: /boot/vmlinuz-home
      Initrd: /boot/initrd.img

    Home OS (Recovery)

  Booting in 5 seconds... (press any key to stop)

  ↑/↓: Select  |  Enter: Boot  |  E: Edit  |  Esc: Firmware Setup
```

### Customization

```zig
const menu = @import("menu");

var boot_menu = menu.BootMenu.init(allocator, &config);

// Change timeout
boot_menu.timeout_remaining = 10; // 10 seconds

// Select different entry
boot_menu.selected_index = 1;

// Cancel auto-boot
boot_menu.cancelTimeout();
```

## Configuration Parsing

### Parser Initialization

```zig
const config = @import("config");

// Auto-detect format
const format = config.detectFormat("/boot/grub/grub.cfg"); // .grub2

// Create parser
var parser = config.ConfigParser.init(allocator, format);

// Parse configuration
const config_content = try std.fs.cwd().readFileAlloc(
    allocator,
    "/boot/grub/grub.cfg",
    1024 * 1024,
);
defer allocator.free(config_content);

var boot_config = try parser.parse(config_content);
defer boot_config.deinit();
```

### Serialization

```zig
// Convert to Home OS format
var parser = config.ConfigParser.init(allocator, .home_os);
const serialized = try parser.serialize(&boot_config);
defer allocator.free(serialized);

// Write to file
try std.fs.cwd().writeFile("/boot/home.conf", serialized);
```

## Migration from GRUB

### Why Replace GRUB?

1. **Complexity**: GRUB has accumulated significant complexity over decades
2. **Security**: Tighter integration with Home OS security model
3. **Performance**: Faster boot times with optimized code paths
4. **Maintainability**: Clean, modern codebase written in Zig
5. **Features**: Better support for modern boot protocols

### Migration Steps

1. **Parse Existing Config**: Use GRUB2 parser to read current configuration
2. **Generate Native Config**: Convert to Home OS format
3. **Install Bootloader**: Copy bootloader to EFI system partition
4. **Update UEFI Variables**: Set Home OS bootloader as default
5. **Test Boot**: Verify all boot entries work correctly
6. **Remove GRUB**: Clean up old bootloader files

### Migration Tool

```zig
const std = @import("std");
const config = @import("config");

pub fn migrateFromGrub(allocator: std.mem.Allocator) !void {
    // Read GRUB configuration
    const grub_content = try std.fs.cwd().readFileAlloc(
        allocator,
        "/boot/grub/grub.cfg",
        1024 * 1024,
    );
    defer allocator.free(grub_content);

    // Parse GRUB config
    var grub_parser = config.ConfigParser.init(allocator, .grub2);
    var boot_config = try grub_parser.parse(grub_content);
    defer boot_config.deinit();

    // Convert to Home OS format
    var home_parser = config.ConfigParser.init(allocator, .home_os);
    const home_content = try home_parser.serialize(&boot_config);
    defer allocator.free(home_content);

    // Write new configuration
    try std.fs.cwd().writeFile("/boot/home.conf", home_content);

    std.debug.print("Successfully migrated {d} boot entries\n", .{
        boot_config.getEntryCount(),
    });
}
```

## Security Considerations

### Secure Boot

- Always enable Secure Boot in production environments
- Keep certificate databases up to date
- Use strong signature algorithms (RSA-4096 or ECDSA-P384)
- Regularly audit the forbidden hash list (dbx)

### Configuration Security

- Protect `/boot/home.conf` with appropriate file permissions
- Validate all configuration inputs
- Sanitize kernel command-line parameters
- Implement rate limiting for boot attempts

### Memory Safety

- Zig's memory safety prevents buffer overflows
- All allocations are explicitly tracked and freed
- Bounds checking on all array accesses
- No undefined behavior in bootloader code

## Performance

### Boot Time Optimization

- **Fast ELF Parsing**: Optimized binary loading
- **Minimal Memory Allocation**: Efficient memory usage
- **Direct UEFI Access**: No intermediate layers
- **Parallel Loading**: Load kernel and initrd concurrently

### Memory Footprint

- Bootloader code: ~50KB
- Runtime memory: ~1MB for typical configurations
- Kernel loading buffer: Configured per kernel size

## Testing

### Unit Tests

```bash
# Run all bootloader tests
zig build test --match bootloader

# Test specific modules
zig build test --match "boot entry"
zig build test --match "ELF header"
zig build test --match "secure boot"
```

### Integration Testing

```bash
# Test in QEMU with OVMF (UEFI firmware)
qemu-system-x86_64 \
  -bios /usr/share/ovmf/OVMF.fd \
  -drive format=raw,file=test-disk.img \
  -m 2G

# Test with Secure Boot enabled
qemu-system-x86_64 \
  -machine q35,smm=on \
  -global driver=cfi.pflash01,property=secure,value=on \
  -drive if=pflash,format=raw,readonly=on,file=OVMF_CODE.secboot.fd \
  -drive if=pflash,format=raw,file=OVMF_VARS.fd \
  -drive format=raw,file=test-disk.img
```

## Troubleshooting

### Boot Failures

**Problem**: Bootloader doesn't start
- Check UEFI boot order
- Verify EFI system partition is properly mounted
- Ensure bootloader is installed to correct path (`/EFI/Home/bootx64.efi`)

**Problem**: Kernel not found
- Verify kernel path in configuration
- Check file permissions
- Ensure kernel is valid ELF64 binary

**Problem**: Secure Boot verification failed
- Install trusted certificates
- Sign kernel with valid key
- Check certificate validity dates

### Menu Issues

**Problem**: Menu doesn't display
- Check UEFI console output support
- Verify UTF-16 string conversion
- Test with different firmware

**Problem**: Keyboard input not working
- Ensure UEFI input protocol is available
- Check keyboard scan codes
- Try different keyboard

## Future Enhancements

- [ ] Multi-boot support (Windows, Linux, BSD)
- [ ] Graphical boot menu with logo
- [ ] Network boot (PXE) support
- [ ] TPM 2.0 integration for measured boot
- [ ] Encrypted kernel loading
- [ ] Boot splash screen
- [ ] Remote attestation
- [ ] A/B update system integration

## References

- [UEFI Specification 2.10](https://uefi.org/specifications)
- [ELF-64 Object File Format](https://refspecs.linuxfoundation.org/elf/elf.pdf)
- [UEFI Secure Boot](https://uefi.org/sites/default/files/resources/UEFI_Secure_Boot.pdf)
- [Linux Boot Protocol](https://www.kernel.org/doc/html/latest/x86/boot.html)
- [systemd-boot Documentation](https://www.freedesktop.org/wiki/Software/systemd/systemd-boot/)

## License

This bootloader is part of Home OS and follows the project's licensing terms.
