---
title: Standard Library Module Inventory
description: Inventory Home's implementation-side library modules, their source locations, test evidence, and current language-facing validation boundary.
---

# Standard library module inventory

This page inventories library source in the repository. It is not a promise
that every listed Zig module is importable from `.home` source. For the public
support boundary, start with the
[standard-library status](/docs/reference/stdlib) and
[capability matrix](/docs/CAPABILITY_MATRIX#standard-library).

## `packages/basics`

`packages/basics/src/` is an implementation-side Zig package. Its current
top-level source files are grouped below.

| Area | Source modules |
|---|---|
| Core helpers | `allocator.zig`, `basics.zig`, `memory.zig`, `string.zig` |
| Collections | `collections.zig`, `hashmap.zig`, `vec.zig` |
| Files and processes | `filesystem.zig`, `fs.zig`, `process.zig` |
| Networking and web | `net.zig`, `http_router.zig`, `middleware.zig`, `session.zig` |
| Data and validation | `json.zig`, `ini_parser.zig`, `regex.zig`, `validation.zig` |
| Application helpers | `cli.zig`, `craft.zig`, `datetime.zig`, `temporal.zig`, `zyte.zig` |
| Security | `crypto.zig` |

These modules vary in maturity. The directory currently has focused Zig tests
for `craft.zig` and `http_router.zig`; that test presence does not establish a
stable `.home` import surface for the whole directory.

## Other implementation packages

Home separates larger subsystems into their own packages. Examples include:

- `packages/core/` for shared compiler and runtime-facing wrappers.
- `packages/net/` for networking implementation.
- `packages/database/` for database work.
- `packages/threading/` for threading and synchronization.
- `packages/kernel/` and `packages/drivers/` for freestanding targets.

Package names and source files are useful when contributing to Home, but they
are not a substitute for an end-to-end language test.

## Reading module status

Use these labels consistently:

- **Stable** means a capability is implemented and exercised through Home's
  language-facing tests or examples.
- **In progress** means implementation code exists but the public surface,
  integration or coverage is incomplete.
- **Not yet** means no meaningful implementation is available.

The [capability matrix](/docs/CAPABILITY_MATRIX) owns those status decisions.
This inventory deliberately avoids stale line counts, export counts and
"complete" labels that cannot prove end-to-end support.

## Contributing a module

To move a module from source presence to supported capability:

1. Define the `.home` import and API shape.
2. Wire the implementation into the compiler or runtime.
3. Add an end-to-end `.home` fixture.
4. Add focused failure-path tests.
5. Update the capability matrix with the evidence.
