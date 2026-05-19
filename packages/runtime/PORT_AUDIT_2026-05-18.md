# Bun Runtime Port Audit

> **Superseded by [`PORT_AUDIT_2026-05-20.md`](./PORT_AUDIT_2026-05-20.md).**
> This audit's totals (366 ported / 852 remaining) are stale —
> +105 files have landed since (Phase 12.2 M1-M6 JSC + Phase 12.7
> round-10 `node:*`). The Tier 0 / Tier 1 file catalogues below
> remain useful as a reference for the next-to-port pool.

**Date:** 2026-05-18  
**Upstream pinned at:** `fd0b6f1a271fca0b8124b69f230b100f4d636af6`  
**Destination:** `packages/runtime/src/`

## Totals

- **Upstream files:** 1193 `.zig` files under `~/Code/bun/src/` (excluding test/, codegen/, *_jsc/, *_macros/)
- **Ported files:** 366 files already in `packages/runtime/src/`
- **Unported files:** 852 files remaining to port

## Tier 0 — Claim First (Data Structures, <100 LOC, Pure Helpers)

30 small, self-contained files requiring no cross-subsystem imports:

| File | LOC | bun_refs | jsc_refs | Destination |
|------|-----|----------|----------|-------------|
| runtime/shell/builtin/pwd.zig | 94 | 4 | 2 | runtime/shell/builtin |
| ast/ast_memory_allocator.zig | 94 | 3 | 0 | ast |
| uws_sys/BodyReaderMixin.zig | 94 | 1 | 0 | uws_sys |
| jsc/JSSecrets.zig | 86 | 4 | 14 | jsc |
| bun_alloc/BufferFallbackAllocator.zig | 85 | 0 | 0 | bun_alloc |
| runtime/timer/EventLoopDelayMonitor.zig | 83 | 3 | 10 | runtime/timer |
| install/lockfile/Package/Meta.zig | 81 | 2 | 0 | install/lockfile/Package |
| js_parser/lexer/identifier.zig | 78 | 0 | 0 | js_parser/lexer |
| runtime/cli/shell_completions.zig | 75 | 2 | 0 | runtime/cli |
| css/properties/svg.zig | 75 | 0 | 0 | css/properties |
| ptr/raw_ref_count.zig | 74 | 4 | 0 | ptr |
| sql/mysql/protocol/EncodeInt.zig | 73 | 2 | 0 | sql/mysql/protocol |
| ptr/weak_ptr.zig | 69 | 3 | 0 | ptr |
| uws_sys/ListenSocket.zig | 69 | 2 | 0 | uws_sys |
| string/PathString.zig | 64 | 3 | 1 | string |
| css/properties/list.zig | 64 | 0 | 0 | css/properties |
| threading/work_pool.zig | 58 | 3 | 0 | threading |
| bun_alloc/MaxHeapAllocator.zig | 58 | 2 | 0 | bun_alloc |
| runtime/crypto/HMAC.zig | 57 | 4 | 2 | runtime/crypto |
| bun_alloc/NullableAllocator.zig | 48 | 2 | 0 | bun_alloc |
| install/isolated_install/FileCloner.zig | 47 | 4 | 0 | install/isolated_install |
| runtime/test_runner/DoneCallback.zig | 46 | 4 | 8 | runtime/test_runner |
| string/HashedString.zig | 44 | 2 | 0 | string |
| install/versioned_url.zig | 44 | 1 | 0 | install |
| sql/shared/ColumnIdentifier.zig | 38 | 0 | 1 | sql/shared |
| sql/mysql/AuthMethod.zig | 37 | 1 | 0 | sql/mysql |
| runtime/shell/builtin/true_.zig | 27 | 2 | 2 | runtime/shell/builtin |
| runtime/shell/builtin/false_.zig | 27 | 2 | 2 | runtime/shell/builtin |
| jsc/config.zig | 26 | 1 | 0 | jsc |
| sql/mysql/protocol/StmtPrepareOKPacket.zig | 26 | 0 | 0 | sql/mysql/protocol |

## Tier 1 — Claim After Tier 0 (Primitive Helpers, <300 LOC)

30 small utility files with light subsystem coupling:

| File | LOC | bun_refs | jsc_refs | Destination |
|------|-----|----------|----------|-------------|
| resolver/node_fallbacks.zig | 99 | 10 | 0 | resolver |
| sql/mysql/protocol/ColumnDefinition41.zig | 99 | 1 | 0 | sql/mysql/protocol |
| unicode/uucode/grapheme_gen.zig | 97 | 0 | 0 | unicode/uucode |
| sql/shared/Data.zig | 94 | 13 | 0 | sql/shared |
| platform/linux.zig | 93 | 8 | 0 | platform |
| bundler/linker_context/StaticRouteVisitor.zig | 93 | 10 | 0 | bundler/linker_context |
| css/values/resolution.zig | 91 | 8 | 0 | css/values |
| sys/tmp.zig | 89 | 13 | 0 | sys |
| sql/postgres/protocol/FieldMessage.zig | 85 | 2 | 0 | sql/postgres/protocol |
| sql/mysql/protocol/HandshakeV10.zig | 82 | 1 | 0 | sql/mysql/protocol |
| sys/PosixStat.zig | 80 | 12 | 0 | sys |
| zlib_sys/posix.zig | 80 | 0 | 0 | zlib_sys |
| sql/mysql/protocol/StackReader.zig | 78 | 1 | 0 | sql/mysql/protocol |
| sql/mysql/protocol/StackReader.zig | 78 | 1 | 0 | sql/mysql/protocol |
| runtime/cli/scan_command.zig | 76 | 2 | 0 | runtime/cli |
| runtime/cli/fuzzilli_command.zig | 74 | 14 | 0 | runtime/cli |
| crash_handler/CPUFeatures.zig | 71 | 6 | 0 | crash_handler |
| sql/mysql/protocol/Query.zig | 70 | 1 | 0 | sql/mysql/protocol |
| sql/postgres/protocol/FieldDescription.zig | 69 | 0 | 0 | sql/postgres/protocol |
| runtime/cli/colon_list_type.zig | 62 | 8 | 0 | runtime/cli |
| sql/postgres/PostgresProtocol.zig | 62 | 0 | 0 | sql/postgres |
| sql/postgres/protocol/StartupMessage.zig | 50 | 0 | 0 | sql/postgres/protocol |
| sql/mysql/protocol/OKPacket.zig | 49 | 0 | 0 | sql/mysql/protocol |
| runtime/shell/RefCountedStr.zig | 47 | 5 | 0 | runtime/shell |
| bundler/PathToSourceIndexMap.zig | 46 | 7 | 0 | bundler |
| sql/postgres/protocol/Parse.zig | 45 | 0 | 0 | sql/postgres/protocol |
| sql/postgres/protocol/RowDescription.zig | 43 | 3 | 0 | sql/postgres/protocol |
| runtime/shell/AllocScope.zig | 43 | 10 | 0 | runtime/shell |
| sql/postgres/protocol/NegotiateProtocolVersion.zig | 42 | 4 | 0 | sql/postgres/protocol |
| sql/mysql/protocol/AuthSwitchRequest.zig | 42 | 2 | 0 | sql/mysql/protocol |

## Tier 2–3 — Subsystem Cores & Leaves (Sampled)

Mid-complexity subsystem code (300–1000+ LOC) with Phase 12 prerequisites:

- **Tier 2:** bundler, md parsing, css subsystems (800–1000 LOC)
- **Tier 3:** runtime/api (archive, blob), test runner, bun.zig surface (1000–4000 LOC)
- **Blockers:** event_loop, io, resolver, module_loader form DAG rooted in JSC bridge (Phase 12.2)

## Deferred — JSC Bridge (Phase 12.2)

20 files with heavy JSC/NAPI integration (>20 JSC keyword refs), deferred to Phase 12.2:

- `runtime/api/BunObject.zig` (2176 LOC, 226 jsc_refs)
- `runtime/api/Archive.zig` (1146 LOC, 58 jsc_refs)
- `runtime/test_runner/bun_test.zig` (1072 LOC, 58 jsc_refs)
- `runtime/bake/bake.zig` (1008 LOC, 12 jsc_refs)
- `jsc/AsyncModule.zig` (782 LOC, 52 jsc_refs)
- Plus 15 others in `jsc/`, `bun.js.zig`, NAPI bindings

## Porting Strategy

1. **Parallel agents:** Each claim a disjoint Tier 0 or Tier 1 file from this audit.
2. **Copy → rewrite:** `@import("bun")` → `@import("home_rt")`, `bun.X` → `home_rt.X`.
3. **Test:** Add inline test per README §5. Verify `zig build test --summary all` green.
4. **Blockers:** Tier 2–3 and JSC deferred until Phase 12.2 JSC engine lands.

All files pinned at Bun SHA `fd0b6f1a271fca0b8124b69f230b100f4d636af6`.
