# Bun `bundler_jsc` Port

Upstream: `/Users/chrisbreuer/Code/bun/src/bundler_jsc/` at
`fd0b6f1a271fca0b8124b69f230b100f4d636af6`.

Copied checked-in Zig outputs:

- `JSBundleCompletionTask.zig`
- `PluginRunner.zig`
- `analyze_jsc.zig`
- `options_jsc.zig`
- `output_file_jsc.zig`
- `source_map_mode_jsc.zig`

Adaptation: `@import("bun")` is rewritten to `@import("home_rt")` so the copied
files bind through Home's Bun-compatible runtime aggregator. No JavaScript
harness shims or substitute implementations were added.

Current blocker status is tracked by
`./pantry/.bin/zig build test -Dfilter=home_rt --summary failures`.
