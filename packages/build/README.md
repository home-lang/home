# Home Build System

## Overview

Build configuration and incremental compilation. Manages the compilation process.

## Features

- Core build functionality
- Type-safe operations
- Well-tested implementation
- Kernel and ISO staging helpers accept an explicit `std.Io` and destination
  directory. Their tests verify the written linker script, multiboot header,
  copied kernel bytes, and GRUB configuration in temporary directories. These
  helpers stage inputs only; they do not yet compile a kernel or create an ISO.

## Usage

```zig
const build = @import("build");

// Example usage
```

## Testing

```bash
pantry/.bin/zig build --build-file packages/build/build.zig test -j1 --summary all
zig build --build-file packages/build/build.zig test -j1 --summary all
```

## License

Part of the Home programming language project.
