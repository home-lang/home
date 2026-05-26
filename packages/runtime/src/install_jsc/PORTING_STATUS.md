# Bun `install_jsc` Port

Upstream: `/Users/chrisbreuer/Code/bun/src/install_jsc/` at
`fd0b6f1a271fca0b8124b69f230b100f4d636af6`.

Copied checked-in Zig outputs:

- `dependency_jsc.zig`
- `hosted_git_info_jsc.zig`
- `ini_jsc.zig`
- `install_binding.zig`
- `npm_jsc.zig`
- `update_request_jsc.zig`

Adaptation: `@import("bun")` is rewritten to `@import("home_rt")` so the copied
files bind through Home's Bun-compatible runtime aggregator. No generated
surrogates or shortcut implementations were added.

Current blocker status is tracked by
`./pantry/.bin/zig build test -Dfilter=home_rt --summary failures`.
