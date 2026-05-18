# `home_test` — Jest-compatible testing for Home

A vendored copy of Bun's `bun:test` framework, ported into Home so
we can keep maintaining the Zig portion of it as Bun shifts to Rust.

## Why

Bun has announced its core is being rewritten in Rust. Home is a Zig
codebase, and we don't want to lose Bun's excellent test-runner work
(the API editors and tooling already understand: `describe`, `test`,
`it`, `expect`, snapshots, fake timers, async `done` callbacks,
mocking via `mock`/`spyOn`, the full ~70-matcher surface). So we
vendor Bun's `src/runtime/test_runner/` Zig source verbatim under
`src/bun/` and adapt it to Home's runtime over time.

The Rust port that lives next to each `.zig` upstream (e.g.
`jest.rs` next to `jest.zig`) is **not** copied — that fork is going
where Home isn't.

## What you get (post-activation)

```ts
// in a Home test file
import { describe, test, expect, beforeEach } from "home:test";

describe("math", () => {
  beforeEach(() => { /* … */ });
  test("adds", () => {
    expect(1 + 1).toBe(2);
  });
});
```

The full intended public API is documented in
[`src/home_test.zig`](./src/home_test.zig) — it mirrors `bun:test`
1:1 (matchers, lifecycle hooks, `jest.useFakeTimers()`, snapshot
APIs, `expect.extend`, asymmetric matchers like
`expect.objectContaining(...)`, etc).

## Status

**Not yet activated.** The vendored sources under `src/bun/` import
Bun's stdlib aggregator (`@import("bun")`) and so do not compile
against Home's stdlib today. The file-by-file porting plan, top
external dependency list, and tier-ordered build plan live in
[`src/PORTING_STATUS.md`](./src/PORTING_STATUS.md).

The same `compat/` shim work the bundler port also needs
(see `packages/bundler/src/bun/PORTING_STATUS.md`) will unblock
Tier 0/1 of this package — at that point we can wire `src/bun/` into
the package's test step incrementally.

## Layout

```
packages/home_test/
  src/
    bun/                     # Verbatim copy of upstream Bun (MIT)
      bun_test.zig           #   entrypoint
      jest.zig               #   describe/test/lifecycle
      expect.zig             #   expect() harness
      expect/*.zig           #   70 individual matchers
      Collection.zig         #   test collection
      Execution.zig          #   scheduler
      Order.zig              #   deterministic ordering
      ScopeFunctions.zig     #   describe/test/hook factories
      DoneCallback.zig       #   async done callbacks
      snapshot.zig           #   snapshot persistence
      pretty_format.zig      #   value pretty-printer
      diff_format.zig        #   top-level diff formatter
      diff/*.zig             #   diff algorithms (Google's diff-match-patch)
      harness/*.zig          #   fixture harness
      timers/FakeTimers.zig  #   Jest-style fake timers
      cli/test_command.zig   #   `bun test` CLI driver
      jest.classes.ts        #   TypeScript bridge (class registry)
    home_test.zig            # Public Home-side facade module
    PORTING_STATUS.md        # File-by-file adaptation status + plan
    LICENSE.bun.md           # Bun MIT license + linked-library notices
  README.md                  # This file
```

## License

Bun is MIT-licensed. See [`src/LICENSE.bun.md`](./src/LICENSE.bun.md)
for the full license text including all upstream linked-library
notices. Each vendored `.zig` file carries a 3-line attribution
header pointing back to its upstream source path.
