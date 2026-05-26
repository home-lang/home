# Bun WebCore Runtime Port

This directory is a verbatim copy of Bun's Zig WebCore runtime source from
`/Users/chrisbreuer/Code/bun/src/runtime/webcore/*.zig`, plus the aggregator
at `packages/runtime/src/runtime/webcore.zig` copied from
`/Users/chrisbreuer/Code/bun/src/runtime/webcore.zig`.

The copy is intentionally source-first: these files are not rewritten as
Home-specific JavaScript harness shims. They are the upstream Bun
implementation surface for Body, Blob, Request, Response, Fetch, streams,
encoding, FormData, object URLs, sinks, and related Web APIs. Adaptation work
from here should keep the Bun structure intact, wire missing imports through
Home runtime packages, and make Zig 0.17-dev changes as narrowly as possible.

## Inventory

- Aggregator: `../webcore.zig`
- Source files: 29 `.zig` files copied from Bun `src/runtime/webcore/`
- Total copied Zig source: 20,765 lines, including the aggregator

## Current State

- **Copied:** complete WebCore Zig source snapshot from the local Bun checkout.
- **License:** Bun MIT / linked-library attribution preserved in
  `LICENSE.bun.md`.
- **Build wiring:** pending. These files still reference Bun's native module
  graph (`bun`, `jsc`, event loop, server, HTTP, S3, and WebKit/JSC bindings).
- **Parity target:** replace the remaining Web API bootstrap behavior in the
  Bun corpus runner with this copied native implementation, then run the copied
  Bun Web API tests through Home until the full Bun suite passes.
