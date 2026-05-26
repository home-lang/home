# Bun Logger Source Slice

Upstream: `/Users/chrisbreuer/Code/bun`, SHA
`fd0b6f1a271fca0b8124b69f230b100f4d636af6`.

`logger/logger.zig` is copied from Bun `src/ast/logger.zig`. Bun
`bundler/bundle_v2.zig` imports this surface as `../logger/logger.zig`; Home
keeps that import path build-visible while preserving the upstream logger
implementation.
