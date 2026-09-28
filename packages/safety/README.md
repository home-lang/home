# Home Safety Checks

## Overview

Ownership and borrow checking support for the Home compiler.

Unsafe boundaries are enforced by the authoritative type checker in
`packages/types/src/type_system.zig`. Keeping that enforcement in the type
checker ensures raw-pointer operations and calls to unsafe or external
functions are validated against the same resolved types used by the rest of
semantic analysis.

## Features

- Ownership tracking
- Borrow checking
- Scope-aware diagnostics

## Usage

```zig
const safety = @import("safety");
```

## Testing

```bash
zig test packages/safety/tests/safety_test.zig
```

Unsafe-boundary regression coverage lives in
`packages/types/tests/control_flow_checker_test.zig`.

## License

Part of the Home programming language project.
