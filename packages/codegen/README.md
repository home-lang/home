# Home Code Generator

## Overview

Native code generation. Compiles AST to machine code.

Semantic checking is owned by
[`packages/types/src/type_system.zig`](../types/src/type_system.zig) and runs
before native code generation. Codegen deliberately does not maintain a second
Hindley–Milner inference pass: the former `type_integration.zig` path was
unwired, diverged from the authoritative checker, and has been removed. The
legacy move-analysis pass remains conservative when typed metadata has not been
threaded into codegen.

## Features

- Core codegen functionality
- Type-safe operations
- Well-tested implementation

## Usage

```zig
const codegen = @import("codegen");

// Example usage
```

## Testing

```bash
./pantry/.bin/zig build test -Dfilter=codegen -j1 --summary all
```

## License

Part of the Home programming language project.
