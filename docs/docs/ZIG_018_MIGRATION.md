---
title: Zig 0.18 migration gate
description: Scope and local reproduction of Home's Zig 0.18 CI baseline.
---

# Zig 0.18 migration gate

Home's production toolchain remains Pantry-pinned to Zig
`0.17.0-dev.2163+89ff10d56`. The [Zig master compatibility
workflow](https://github.com/home-lang/home/blob/main/.github/workflows/zig-master.yml)
now has two independent jobs:

- The existing moving-master job detects new standard-library changes in its
  narrow crypto, optimize-mode, and I/O tests.
- The fixed `0.18.0-dev.146+35accc06e` job builds the standalone TypeScript
  compiler (`home-tsc`) and both compiles and runs the real `packages/io` and
  `packages/build` package tests. Their `check` steps also compile the shipped
  libraries, not just test-only modules.

To reproduce the fixed gate locally with that exact Zig version on `PATH`:

```bash
bash scripts/verify-zig-018.sh
```

The fixed gate is deliberately scoped to sources verified on both the current
pin and 0.18. It does **not** establish that the full Home compiler, runtime,
release artifacts, or all package sources build on 0.18. Keep the existing
0.17 production/test jobs until those surfaces are migrated and verified. See
[issue #884](https://github.com/home-lang/home/issues/884) for the migration
checklist and [issue #66](https://github.com/home-lang/home/issues/66) for the
broader Bun-port status.
