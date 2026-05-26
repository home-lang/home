# Bun CLI Test Support Port

Upstream: `/Users/chrisbreuer/Code/bun/src/runtime/cli/test/` at
`fd0b6f1a271fca0b8124b69f230b100f4d636af6`.

Copied checked-in Zig support modules for the Home runtime test command:

- `ChangedFilesFilter.zig`
- `Scanner.zig`

Adaptation: `@import("bun")` is rewritten to `@import("home_rt")` so the copied
files bind through Home's Bun-compatible runtime aggregator. Existing local
`ParallelRunner.zig` was left untouched.

Current blocker status is tracked by
`./pantry/.bin/zig build test -Dfilter=home_rt --summary failures`.
