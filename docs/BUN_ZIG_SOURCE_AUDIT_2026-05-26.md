# Bun Zig Source Audit - 2026-05-26

Audit workspace: `/tmp/home-bun-parity-main`

Pinned upstream:
`/Users/chrisbreuer/Code/bun@fd0b6f1a271fca0b8124b69f230b100f4d636af6`

## Summary

- `packages/runtime/UPSTREAM_SHA.txt` matches upstream Bun HEAD.
- `packages/runtime/src/` contains 1391 Zig files.
- `scripts/measure-parity.sh --values` reports 98 runtime source
  subsystems, 128 JSC files, and the unchanged 552 / 1193 integrated
  baseline.
- Full upstream Zig source presence is now complete in this worktree:
  the 72-file source presence gap has been closed, leaving zero missing
  upstream Zig paths in `packages/runtime/src/`.
- Copied Bun corpus presence is complete for `.test.ts` / `.test.js`
  files: upstream Bun and Home both have 1720 paths, with zero missing
  and zero extra copied test files.
- The copied bundler corpus has 89 `bundler/**/*.test.{ts,js}` files.
  Current green evidence covers 82 unique files, leaving the exact
  7-file frontier listed in `docs/BUN_PARITY_PLAN.md`.

## SQL / Valkey / DNS JSC Integration Audit

- Fidelity check against `/Users/chrisbreuer/Code/bun/src`:
  `packages/runtime/src/sql_jsc/**` and
  `packages/runtime/src/runtime/dns_jsc/**` Zig files are byte-identical to
  their Bun upstream counterparts; only Bun's sibling Rust/Cargo files are
  absent from Home.
- `packages/runtime/src/runtime/valkey_jsc/**` is byte-identical for copied
  Zig files except `ValkeyContext.zig`, which already carries a local
  provenance comment plus a no-op unit test around the upstream empty
  `deinit`.
- Current build wiring has the standalone Valkey context reachable via
  `home_rt.runtime.valkey.Context` and pulled into the `home_rt` test root.
  The remaining SQL JSC, DNS JSC, and Valkey JSC leaves immediately reach
  larger unported surfaces (`jsc.Codegen`, DNS/c-ares bridges, socket groups,
  crypto, and protocol/runtime back-edges), so they should be integrated as
  follow-up chunks after narrow compatibility aliases are identified per leaf.
- Focused gate run on 2026-05-26:
  `/Users/chrisbreuer/Code/Home/lang/pantry/.bin/zig build test -Dfilter=home_rt -Denable_jsc=false --summary failures`
  exits 0 with the current worktree. During this audit it briefly stopped
  before the SQL/Valkey/DNS JSC chunk on an unrelated concurrent
  `runtime/cli/test/parallel/Channel.zig` Zig 0.17 whitespace parse issue;
  that file is outside the SQL/Valkey/DNS JSC ownership slice.

## Parallel Test Runner Integration Audit

- The copied `runtime/cli/test/parallel/{Channel,Coordinator,Worker,aggregate,runner}.zig`
  files are now namespace-visible through
  `home_rt.runtime.cli.test_.parallel` alongside the previously wired
  `FileRange.zig` and `Frame.zig` leaves.
- Home adds only narrow compatibility around the copied source: a minimal
  `uws` socket/vtable shim in `home_rt.zig`, Zig 0.17 syntax cleanup for
  `Channel`'s scratch buffer, and the upstream-compatible enum decode
  replacement for `std.meta.intToEnum`.
- Focused evidence currently covers channel frame ingestion/remainder
  handling, unknown-frame recovery, oversized-payload termination, and
  aggregate JUnit attribute parsing. This is compile-frontier integration,
  not full `home test --parallel` behavior; worker process spawning,
  coordinator scheduling, and end-to-end parallel corpus execution remain
  the next behavioral gates.

## Closed Source Presence Gap

Copied paths grouped by top-level upstream source directory:

| Directory | Copied paths |
|---|---:|
| `sql_jsc/` | 38 |
| `runtime/` | 14 |
| `http_jsc/` | 7 |
| `css_jsc/` | 3 |
| `sys_jsc/` | 3 |
| `js_parser_jsc/` | 2 |
| `semver_jsc/` | 2 |
| `ast_jsc/` | 1 |
| `patch_jsc/` | 1 |
| `url_jsc/` | 1 |

Copied paths:

- `ast_jsc/logger_jsc.zig`
- `css_jsc/color_js.zig`
- `css_jsc/css_internals.zig`
- `css_jsc/error_jsc.zig`
- `http_jsc/headers_jsc.zig`
- `http_jsc/websocket_client.zig`
- `http_jsc/websocket_client/CppWebSocket.zig`
- `http_jsc/websocket_client/WebSocketDeflate.zig`
- `http_jsc/websocket_client/WebSocketProxy.zig`
- `http_jsc/websocket_client/WebSocketProxyTunnel.zig`
- `http_jsc/websocket_client/WebSocketUpgradeClient.zig`
- `js_parser_jsc/Macro.zig`
- `js_parser_jsc/expr_jsc.zig`
- `patch_jsc/testing.zig`
- `runtime/cli/test/parallel/Channel.zig`
- `runtime/cli/test/parallel/Coordinator.zig`
- `runtime/cli/test/parallel/Worker.zig`
- `runtime/cli/test/parallel/aggregate.zig`
- `runtime/cli/test/parallel/runner.zig`
- `runtime/dns_jsc/cares_jsc.zig`
- `runtime/dns_jsc/dns.zig`
- `runtime/dns_jsc/options_jsc.zig`
- `runtime/valkey_jsc/ValkeyCommand.zig`
- `runtime/valkey_jsc/index.zig`
- `runtime/valkey_jsc/js_valkey.zig`
- `runtime/valkey_jsc/js_valkey_functions.zig`
- `runtime/valkey_jsc/protocol_jsc.zig`
- `runtime/valkey_jsc/valkey.zig`
- `semver_jsc/SemverObject.zig`
- `semver_jsc/SemverString_jsc.zig`
- `sql_jsc/mysql.zig`
- `sql_jsc/mysql/JSMySQLConnection.zig`
- `sql_jsc/mysql/JSMySQLQuery.zig`
- `sql_jsc/mysql/MySQLConnection.zig`
- `sql_jsc/mysql/MySQLContext.zig`
- `sql_jsc/mysql/MySQLQuery.zig`
- `sql_jsc/mysql/MySQLRequestQueue.zig`
- `sql_jsc/mysql/MySQLStatement.zig`
- `sql_jsc/mysql/MySQLValue.zig`
- `sql_jsc/mysql/protocol/DecodeBinaryValue.zig`
- `sql_jsc/mysql/protocol/ResultSet.zig`
- `sql_jsc/mysql/protocol/Signature.zig`
- `sql_jsc/mysql/protocol/any_mysql_error_jsc.zig`
- `sql_jsc/mysql/protocol/error_packet_jsc.zig`
- `sql_jsc/postgres.zig`
- `sql_jsc/postgres/AuthenticationState.zig`
- `sql_jsc/postgres/DataCell.zig`
- `sql_jsc/postgres/PostgresRequest.zig`
- `sql_jsc/postgres/PostgresSQLConnection.zig`
- `sql_jsc/postgres/PostgresSQLContext.zig`
- `sql_jsc/postgres/PostgresSQLQuery.zig`
- `sql_jsc/postgres/PostgresSQLStatement.zig`
- `sql_jsc/postgres/SASL.zig`
- `sql_jsc/postgres/Signature.zig`
- `sql_jsc/postgres/command_tag_jsc.zig`
- `sql_jsc/postgres/error_jsc.zig`
- `sql_jsc/postgres/protocol/error_response_jsc.zig`
- `sql_jsc/postgres/protocol/notice_response_jsc.zig`
- `sql_jsc/postgres/types/PostgresString.zig`
- `sql_jsc/postgres/types/bool.zig`
- `sql_jsc/postgres/types/bytea.zig`
- `sql_jsc/postgres/types/date.zig`
- `sql_jsc/postgres/types/json.zig`
- `sql_jsc/postgres/types/tag_jsc.zig`
- `sql_jsc/shared/CachedStructure.zig`
- `sql_jsc/shared/ObjectIterator.zig`
- `sql_jsc/shared/QueryBindingIterator.zig`
- `sql_jsc/shared/SQLDataCell.zig`
- `sys_jsc/error_jsc.zig`
- `sys_jsc/fd_jsc.zig`
- `sys_jsc/signal_code_jsc.zig`
- `url_jsc/url_jsc.zig`

## Recount Commands

```sh
git -C /Users/chrisbreuer/Code/bun rev-parse HEAD
cat packages/runtime/UPSTREAM_SHA.txt
./scripts/measure-parity.sh --values
find /Users/chrisbreuer/Code/bun/test -type f \( -name '*.test.ts' -o -name '*.test.js' \) | wc -l
find packages/runtime/test/bun-corpus -type f \( -name '*.test.ts' -o -name '*.test.js' \) | wc -l
```
