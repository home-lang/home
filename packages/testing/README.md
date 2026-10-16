# Home Testing Framework

## Overview

Native Vitest-style testing with nested suites, lifecycle hooks, matchers,
mocks, snapshots, retries, filters, timeouts, and multiple reporters.

## Features

- `describe`/`it` suites with lifecycle hooks
- Typed equality, numeric, string, mock, and error matchers
- Allocation-safe snapshots and call tracking
- Explicit `std.Io` and writer injection for embedders
- Pretty, minimal, verbose, JSON, and TAP reporters

## Usage

```zig
const testing = @import("vitest");
const t = testing.t;

fn adds(expectation: *testing.ModernTest.Expect) !void {
    expectation.* = t.expect(expectation.allocator, 2 + 3, expectation.failures);
    try expectation.toBe(5);
}
```

## Testing

```bash
./pantry/.bin/zig build test -Dfilter=testing_vitest

# Compile and execute the user-facing examples too.
./pantry/.bin/zig build test -Dfilter=testing_vitest_examples
```

## License

Part of the Home programming language project.
