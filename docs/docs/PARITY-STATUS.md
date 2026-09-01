---
title: Parity Status
description: Every parity number Home publishes, with the harness, package or upstream baseline that produces it.
---

# Parity status

The whole status, percentage-based. Every number here is a **byte-for-byte,
file-count, or row-count measurement** against an external baseline — not an
aspirational target. Each row cites the package, harness, or upstream source
that produces it.

This page is the drill-down behind the summary table in the
[repository README](https://github.com/home-lang/home#project-status). Refresh
the live counts with:

```bash
scripts/measure-parity.sh --values     # raw numbers
scripts/measure-parity.sh --markdown   # ready-to-paste table
scripts/measure-parity.sh --diff       # fail if this page drifted
```

> Refreshed 2026-08-28. Coarse-mode TS corpus and full exact mode are
> regression-gated on every PR; the Bun port percentage is file-count
> progress over integrated Home ports, while raw source presence is
> reported separately now that the full Bun source backlog has been
> staged.
>
> TS diagnostic-code coverage (1,620 / 2,079 emitted) tracks the catalog-
> only → emitted ratchet; each `feat(ts-parity): implement TSxxxx`
> commit moves this row by 1. Note: faithful "100% parity" is the
> **reachable** subset — the codes the reference compiler
> (typescript-go) actually emits — and that subset is now effectively
> complete: **0 reachable parity targets remain**. The ~455 still-
> unemitted codes are dead in the reference (obsolete/superseded wording
> it never produces), plus 4 blocked/subsystem-gated references; see
> [Diagnostic reachability](/docs/TS_DIAGNOSTIC_REACHABILITY).

**Per-feature drill-downs** — modeled after Bun's
[Node.js compatibility doc](https://bun.com/docs/runtime/nodejs-apis):

- [TypeScript parity](/docs/PARITY-TYPESCRIPT) — every TypeScript feature with 🟢 / 🟡 / 🔴 status
- [Node.js parity](/docs/PARITY-NODE) — every `node:*` module with 🟢 / 🟡 / 🔴 / ❌ status
- [Bun parity](/docs/PARITY-BUN) — every Bun API + phase-by-phase port status
- [Bun compat shim](/docs/PARITY-BUN-COMPAT) — `packages/compat/` shim symbol-by-symbol status
- [Capability matrix](/docs/CAPABILITY_MATRIX) — full language / codegen / tooling / stdlib matrix
- [TypeScript parity plan](/docs/TS_PARITY_PLAN) — parity plan + dated journal entries
- [Conformance categories](/docs/CONFORMANCE_CATEGORIES) — per-category TS conformance breakdown
- [Bun runtime port audit](https://github.com/home-lang/home/blob/main/packages/runtime/PORT_AUDIT_2026-05-20.md) — file-by-file port audit; live counts come from `scripts/measure-parity.sh --values`

## Headline numbers

| Area | Coverage | Source |
|---|---|---|
| **TypeScript — coarse corpus** | **5,907 / 5,907 — 100%** | `HOME_TS_CONFORMANCE_FULL=1` against upstream conformance corpus |
| **TypeScript — exact (byte-for-byte)** | **5,907 / 5,907 — 100%** | Canonical tsgo-generated baselines; 0 exact cases remain |
| **TypeScript — baseline-aware (19 folders)** | **586 / 586 — 100%** | per-fixture `.errors.txt` byte comparison |
| **TypeScript — named-category survey** | **86 / 86 — 100%** | `assignmentCompatibility` + `comparable` + `inOperator` + `stringLiteral` |
| **TypeScript — diagnostic codes emitted** | **1,620 / 2,079 — ~77.9%** | [Diagnostic code status](/docs/TS_DIAGNOSTIC_CODE_STATUS) — codes referenced from production source; 459 catalog-only remain, but **0 are reachable parity targets** (the reachable subset is complete) — ~455 are dead-in-reference + 4 blocked, see [Diagnostic reachability](/docs/TS_DIAGNOSTIC_REACHABILITY) |
| **LSP wire methods** | **76 / ~80 — ~95%** | `SUPPORTED_METHODS` in `packages/ts_lsp_server/`; LSP 3.17 sync/lifecycle complete, notebook + window meta wired, workspaceSymbol/resolve + $/progress + codeAction/resolve + workspace/textDocumentContent (LSP 3.18) |
| **Bun runtime — source files present** | **1,438 files in `packages/runtime/src/`** | live count from `scripts/measure-parity.sh --values`; audited Bun baseline is 1,193 files |
| **Bun runtime — files integrated** | **552 / 1,193 — ~46.3%** | Home-import-rewritten, Zig 0.17-clean, build-wired, and tested |
| **Bun compat shim — `bun.*` symbols** | **16 / ~103 — ~15.5%** | Tier-0 + Tier-1 (`Output`, `strings`, `String`, `AllocationScope`, `Environment`, `JSError`, `create`, `debugAssert`, `env_var`) lets vendored Bun source compile against Home's stdlib |
| **Node.js — `node:*` modules JS-callable** | **24 / 47 — ~51% (🟡 subsets)** | callable via Home's own JSC realm (`home eval` / `HOME_NATIVE_RUN`), unit-tested; see [Node.js parity](/docs/PARITY-NODE). Not yet wired into the bun-corpus gate |
| **JSC bring-up (Phase 12.2)** | **JS-callable bridge live** | `home eval` / `HOME_NATIVE_RUN` run through Home's own JSC; 24 `node:*` modules + a broad `Bun.*` surface (spawn/spawnSync/which/file/write/hash/gzipSync/Glob/…) callable & unit-tested. Native subsystems: zlib (`std.compress`), crypto HMAC/pbkdf2 (`std.crypto`), spawn (`std.process`) |
| **Language features (capability matrix)** | **19 stable / 42 partial / 2 not-yet — 63 total** | ~30.2% stable, ~66.7% in progress, ~3.2% not yet (includes TS frontend + Runtime/Bun rows) |
| **Total test count** | **~8,415 tests** (unit + integration + conformance-pin) | `./pantry/.bin/zig build test --summary all` on Zig 0.17.0-dev.131. The full exact TypeScript conformance corpus is 5,907 / 5,907; the `home_rt` runtime target needs Bun's JSC/uWS C++ artifacts to link. |

## TypeScript parity — `home tsc` vs `tsc` / `tsgo`

Measured by running the upstream TypeScript conformance corpus through
`packages/ts_conformance/`. The harness compares **byte-for-byte against
upstream `.errors.txt` baselines** in exact mode (`HOME_TS_CONFORMANCE_EXACT=1`);
coarse mode (`HOME_TS_CONFORMANCE_FULL=1` alone) only asserts that we emit
the same *families* of diagnostics.

**Frontend performance snapshot** (`49641900e`, Apple M3 Pro, shared workstation;
30 interleaved runs after three warmups; lower is better):

| Workload | tsc 6.0.3 | native TS 7.0.2 | Home 0.1.0 | Home vs fastest competitor |
|---|---:|---:|---:|---:|
| Startup | 116.9 ms | 62.5 ms | **6.8 ms** | **9.21× faster** |
| 256 files | 478.5 ms | 109.9 ms | **43.8 ms** | **2.51× faster** |
| Deep types | 232.4 ms | 74.7 ms | **34.3 ms** | **2.17× faster** |
| 128-module import graph | 181.2 ms | 62.2 ms | **29.7 ms** | **2.09× faster** |
| 64-leaf barrel graph | 140.5 ms | 55.7 ms | **27.3 ms** | **2.04× faster** |
| 256 typed TSX components | 242.5 ms | 64.9 ms | **28.0 ms** | **2.32× faster** |
| 256 generic call groups | 436.3 ms | 106.3 ms | **37.9 ms** | **2.81× faster** |
| 256 exhaustive control-flow functions | 359.9 ms | 106.4 ms | **60.1 ms** | **1.77× faster** |
| 256 type-predicate/assertion families | 316.0 ms | 87.3 ms | **39.0 ms** | **2.24× faster** |
| 2,048 type-predicate/assertion families | 1455.3 ms | 484.6 ms | **329.4 ms** | **1.47× faster** |
| 256 null-safe-access families | 228.4 ms | 66.5 ms | **38.6 ms** | **1.73× faster** |
| 128 destructuring/rest/spread families | 148.8 ms | 50.5 ms | **17.3 ms** | **2.93× faster** |
| 128 × 8 overload calls | 219.8 ms | 68.4 ms | **28.1 ms** | **2.44× faster** |
| 128 generic class families | 267.5 ms | 75.8 ms | **34.7 ms** | **2.18× faster** |
| 128 structural object families | 208.9 ms | 66.2 ms | **27.7 ms** | **2.39× faster** |
| 128 interface/namespace families | 235.1 ms | 70.6 ms | **44.4 ms** | **1.59× faster** |
| 256 variadic tuple families | 317.7 ms | 90.1 ms | **40.4 ms** | **2.23× faster** |
| 128 checked-JavaScript/JSDoc families | 238.5 ms | 60.8 ms | **37.4 ms** | **1.63× faster** |
| 128 checked-CommonJS owners + app | 179.9 ms | 55.7 ms | **30.4 ms** | **1.83× faster** |
| 256 recursive generic payloads | 166.3 ms | 77.1 ms | **15.6 ms** | **4.95× faster** |

**Cross-platform confirmation** (same admitted corpus, TS 6.0.3 versus native
TS 7.0.2, 30 interleaved runs after three warmups):

| Platform | Raw result | Home lower means | Narrowest mean lead | Full documentation |
|---|---|---:|---:|---|
| Apple M3 Pro / macOS arm64 | `20260901T013443Z` | **20/20** | 1.47×, large predicates | [macOS snapshot](/docs/TS_PERFORMANCE#current-snapshot) |
| Linux arm64 / pinned Bookworm container | `20260829T035150Z` | **20/20** | 1.02×, CheckJS/JSDoc | [Linux checkpoint](/docs/TS_PERFORMANCE#linux-arm64-container-checkpoint) |

Home has lower means on **20/20 admitted timed workloads** and wins
**598/600 paired rounds**. The large-predicate row has the narrowest mean
lead at **1.47×**. All 20 workloads pass admission
before timing; all 600 round files and 1,800 successful samples are retained,
and every row's paired 95% interval is above zero. This local synthetic
snapshot is not universal benchmark leadership. Real-project validation and
additional architectures remain incomplete. See the
[full results, controls, variance and reproduction](/docs/TS_PERFORMANCE#current-snapshot).
Earlier snapshots are retained separately, not averaged into this table.
Async/await coverage is still undergoing validation and is not timed.
The [untimed program-discovery checks](/docs/TS_PERFORMANCE#prepared-program-discovery-and-expanded-global-audit-untimed)
verify that checking uses the completed graph without reparsing bound sources.
False reference/global-presence errors are fixed, but cross-file type linkage
remains incomplete outside the audited feature families. The [callable-identity audit](/docs/TS_PERFORMANCE#callable-identity-and-scoped-inference-untimed)
passes **56/56** after isolating callable metadata and nested generic inference.
The latest [callable-union audit](/docs/TS_PERFORMANCE#callable-union-predicates-and-receivers-untimed)
improves from **120/256 to 256/256** after fixing predicate composition and
receiver requirements. These separate correctness audits keep remaining
failures visible:

| Correctness audit (not a timing result) | TS 6.0.3 | Native TS 7.0.2 | Home |
|---|---:|---:|---:|
| Callable identity controls | 56/56 | 56/56 | 56/56 |
| Callable union controls | 256/256 | 256/256 | 256/256 |
| Variadic tuple controls | 14/14 | 14/14 | 14/14 |
| Global declaration controls | 56/56 | 56/56 | 32/56 |
| [Bound-global discovery controls](/docs/TS_PERFORMANCE#program-wide-name-identity-and-bound-global-ownership-untimed) | 56/56 | 56/56 | 44/56 |
| Imported-owner controls | 20/20 | 20/20 | 12/20 |
| [Exported generic-factory controls](/docs/TS_PERFORMANCE#source-owned-exported-factory-contracts-untimed) | 240/240 | 240/240 | 240/240 |
| [Exported variable-list controls](/docs/TS_PERFORMANCE#indexed-export-queries-and-variable-list-ownership) | 96/96 | 96/96 | 80/96 |
| [Static CommonJS discovery controls](/docs/TS_PERFORMANCE#static-commonjs-dependency-discovery-untimed) | 44/44 | 44/44 | 44/44 |
| [CommonJS instance controls](/docs/TS_PERFORMANCE#checked-commonjs-export-type-transfer-untimed) | 66/66 | 66/66 | 66/66 |
| [Imported nominal-identity controls](/docs/TS_PERFORMANCE#imported-generic-class-instantiation-untimed) | 52/52 | 52/52 | 44/52 |
| [Bound-class export controls](/docs/TS_PERFORMANCE#imported-static-values-and-module-namespace-consumers-untimed) | 52/52 | 52/52 | 52/52 |
| [Imported static-value controls](/docs/TS_PERFORMANCE#imported-static-values-and-module-namespace-consumers-untimed) | 84/84 | 84/84 | 84/84 |
| [Imported generic-class controls](/docs/TS_PERFORMANCE#lazy-source-owned-generic-consumers) | 120/120 | 120/120 | 120/120 |
| [Recursive generic-consumer controls](/docs/TS_PERFORMANCE#lazy-source-owned-generic-consumers) | 288/288 | 288/288 | 288/288 |
| [Re-export discovery controls](/docs/TS_PERFORMANCE#re-export-discovery-and-declaration-origins-untimed) | 28/28 | 28/28 | 28/28 |
| Export-origin controls | 32/32 | 32/32 | 32/32 |
| Imported graph admission | 2/2 | 2/2 | 2/2 |
| Transitive reference probe | 3/3 | 3/3 | 2/3 |

The [re-export discovery and declaration-origin checkpoint](/docs/TS_PERFORMANCE#re-export-discovery-and-declaration-origins-untimed)
fixes omitted dependencies and false alias/ambiguity errors. Automatic cross-file
type transfer remains incomplete; its historical graph timing claims remain ineligible.
The [imported static-value checkpoint](/docs/TS_PERFORMANCE#imported-static-values-and-module-namespace-consumers-untimed)
preserves class values through namespace aliases, captures, destructuring, and
cycles: its controls improve from 52/84 to 84/84. Bound-class controls now pass
52/52. The latest [lazy generic-consumer checkpoint](/docs/TS_PERFORMANCE#lazy-source-owned-generic-consumers)
improves recursive controls from 112/288 to 288/288 and imported generic-class
controls from 118/120 to 120/120. Requested type surfaces expand from cached,
source-owned definitions while nested references remain symbolic. Eight nominal
inheritance controls still fail. The newer [exported-factory checkpoint](/docs/TS_PERFORMANCE#source-owned-exported-factory-contracts-untimed)
improves factory controls from 130/240 to 240/240 and passes both unchanged graph
gates. The checked CommonJS checkpoint adds its own six-error admission control,
bringing Release workload admission to **20/20**. These counts are correctness
results, separate from the timing table above.

See the [TypeScript performance methodology and full results](/docs/TS_PERFORMANCE)
for workload definitions, uncertainty, environment details, caveats, and exact
reproduction commands. Expansion and optimization work is tracked in
[GitHub issue #416](https://github.com/home-lang/home/issues/416).

| Measurement | Pass rate | Notes |
|---|---|---|
| **Coarse mode (5,907 cases)** | **5,907 / 5,907 — 100%** | Saturated; remains the per-PR merge gate. |
| **Exact mode (byte-for-byte, full corpus)** | **5,907 / 5,907 — 100%** | Compared with canonical tsgo-generated baselines; 0 exact cases remain. |
| Baseline-aware exact categories (19 folders, 586 cases) | 586 / 586 — 100% | `apparentType`, `bestCommonType`, `recursiveTypes`, `typeInference`, `keyof`, `conditional`, `instanceOf`, `widenedTypes`, `specifyingTypes`, `primitives`, `any`, `import`, `uniqueSymbol`, `namedTypes`, `localTypes`, `forAwait`, `unknown`, `witness`, `typeAliases`, `asyncGenerators`. |
| Named-category exact survey (4 folders, 86 cases) | 86 / 86 — 100% | `assignmentCompatibility` 70/70, `comparable` 13/13, `inOperator` 2/2, `stringLiteral` 1/1. |
| Smoke (3 folders, 16 cases) | 16 / 16 — 100% | Per-PR fast path. |
| TS diagnostic-code catalogue | **1,620 / 2,079 emitted — ~77.9%** | Mirrors the full upstream code → message table; powers `home-lsp` hover-on-`TS1234`. 459 catalog-only entries remain, but **0 are reachable parity targets** (the reachable subset is complete): ~455 are dead-in-reference + 4 blocked/subsystem-gated; see [Diagnostic code status](/docs/TS_DIAGNOSTIC_CODE_STATUS) + [Diagnostic reachability](/docs/TS_DIAGNOSTIC_REACHABILITY). |

**Exact mode by 1,000-case slice** (snapshot; the per-slice breakdown is
recomputed less often than the aggregate above and lags it slightly —
re-run the command below to refresh):

| Slice | Pass rate | % |
|---|---|---|
| `START=0   LIMIT=1000` | 1,000 / 1,000 | 100% |
| `START=1000 LIMIT=1000` | 1,000 / 1,000 | 100% |
| `START=2000 LIMIT=1000` | 1,000 / 1,000 | 100% |
| `START=3000 LIMIT=1000` | 1,000 / 1,000 | 100% |
| `START=4000 LIMIT=1000` | 1,000 / 1,000 | 100% |
| `START=5000 LIMIT=907`  | 907 / 907   | 100% |

Reproduce locally:

```bash
HOME_TS_CONFORMANCE_FULL=1 \
HOME_TS_CONFORMANCE_EXACT=1 \
HOME_TS_CONFORMANCE_START=2000 \
HOME_TS_CONFORMANCE_LIMIT=1000 \
./pantry/.bin/zig build test -Dfilter=ts_conformance
```

## Bun runtime port (`packages/runtime/`)

Phase 12 vendors Bun's Zig source under MIT and rewrites it to compile
against Home's stdlib. **The JS-callable bridge is live**: `home eval` and
`HOME_NATIVE_RUN=1 home run` execute JavaScript through Home's **own**
JavaScriptCore realm (not system `bun`), with 24 `node:*` modules and a
broad `Bun.*` surface callable and unit-tested. The default `home run`
still delegates to pantry `bun`, and the bun-corpus gate still routes
through the bootstrap harness — wiring the realm into those is the next
convergence step (see [Bun parity plan](/docs/BUN_PARITY_PLAN)).

`home build app.ts -o app` (and the equivalent JS/JSX/TSX module extensions)
now creates a self-contained host executable through LLVM. LLVM compiles the
native launcher, while the binary embeds the entry source and Home's own
JavaScriptCore runtime so JavaScript semantics remain faithful to the runtime.
Arguments and exit status are forwarded to the entrypoint. This first slice is
single-entrypoint; bundling imported files and cross-target builds remain part
of the standalone module-graph work. Native JS/TS builds currently require a
JavaScriptCore-enabled Home compiler plus LLVM/Clang on `PATH`, and are
available on arm64 and x86-64 macOS/Linux hosts.

| Measurement | Coverage | % |
|---|---|---|
| **Runtime Zig source files present** | **1,438 files** | live `packages/runtime/src/**/*.zig` count; includes Home glue and staged Bun integration backlog |
| **Bun source files integrated** | **552 / 1,193** | **~46.3%** |
| Subsystems scaffolded | 100 directories under `packages/runtime/src/` | — |
| Functional runtime | 🟡 JS-callable realm live (`home eval` / `HOME_NATIVE_RUN`); default `home run` + corpus gate still delegate | — |
| JS-callable realm surface | 24 `node:*` modules + broad `Bun.*` | 🟡 subsets, unit-tested; see [Node.js parity](/docs/PARITY-NODE) / [Bun parity](/docs/PARITY-BUN) |
| JSC bring-up (Phase 12.2) | 156 files | M1-M6 + JS-callable bridge live (eval/run through Home's own JSC; realm globals: console/process/web/crypto/timers/url/webcore/fetch/Bun/require) |
| `node:*` substrate (Phase 12.7) | 28 files | round-15 landed (buffer, stream, fs, events, util, assert, os, url, querystring, crypto, process, string_decoder, tty + binding files) |

Upstream pinned at `fd0b6f1a` (see
[`packages/runtime/UPSTREAM_SHA.txt`](https://github.com/home-lang/home/blob/main/packages/runtime/UPSTREAM_SHA.txt));
full audit at
[Bun runtime port audit](https://github.com/home-lang/home/blob/main/packages/runtime/PORT_AUDIT_2026-05-20.md).
The release gate per [`packages/runtime/README.md`](https://github.com/home-lang/home/blob/main/packages/runtime/README.md):
Bun's `test/` corpus must pass **100% with no skips** once feature-complete.

**Phase-by-phase status:**

| Sub-phase | Source under `~/Code/bun/src/` | Status |
|---|---|---|
| 12.1 — CLI | `cli/` | 🚧 scaffold landed |
| 12.2 — JSC bring-up | `jsc/`, `bun.js.zig` | 🟡 M6 milestone landed (156 files: JSON + Promise + Iterator + Global helpers); JS-callable bridge live |
| 12.3 — Event loop / IO / async | `event_loop/`, `io/`, `async/` | 🟡 substrate landing (~30+ leaves ported via wave-19+ grinders) |
| 12.4 — Module loader | `resolver/`, `module_loader.zig` | 🚧 blocked on 12.2 |
| 12.5 — Web / HTTP / DNS | `web/`, `http/`, `csrf/`, `dns/` | 🚧 blocked on 12.3 |
| 12.6 — Home.* JS surface | `bun.zig` (renamed to `Home.*`) | 🚧 blocked on 12.2 |
| 12.7 — `node:*` shims | `node/` | 🟡 substrate landing module-by-module (28 files: buffer, stream, fs, events, util, assert, os, url, querystring, crypto, process, string_decoder, tty) |
| 12.8 — `home test` runner | `test/` | 🚧 blocked on 12.2 |
| 12.9 — Pantry integration | `install/` | 🚧 scaffold in progress |
| 12.10 — CLI surface | `cli/` | 🚧 scaffold landed |
| 12.11 — Cross-compile + bundles | `build/` | 🚧 not started |

## Bun compatibility shim (`packages/compat/`)

Top-level package that re-exports the minimal Bun surface against
Home's stdlib so vendored Bun source compiles without modification.
The build wires `@import("bun")` to this shim (see
[`build.zig:503-510`](https://github.com/home-lang/home/blob/main/build.zig)), letting the
[Bun bundler vendor files](https://github.com/home-lang/home/blob/main/packages/bundler/src/) and the
[Bun runtime port](https://github.com/home-lang/home/blob/main/packages/runtime/src/) keep their upstream
imports diff-clean and re-syncable.

| Measurement | Coverage | % |
|---|---|---|
| **Symbols implemented** | **16 / ~103** | **~15.5%** |
| Test surfaces | inline (~9 tests) + bundler-side integration (7 tests) | regression-gated |

**Implemented surface (16 symbols across Tier-0 + Tier-1):**

| Symbol | Status | Purpose |
|---|---|---|
| `bun.OOM` | 🟢 | `error{OutOfMemory}` alias for explicit error-return signatures (`bun.OOM!void`) |
| `bun.JSError` | 🟢 | `error{ JSException, OutOfMemory }` union for JSC-touching callers |
| `bun.Environment` | 🟢 | Build-time flags (`isDebug`, `isWindows`, `isMac`, `ci_assert`, `enable_logs`) |
| `bun.env_var` | 🟢 | Run-time env-var namespace (`WANTS_LOUD.get()`) |
| `bun.handleOom` | 🟢 | Unwrap OOM-returning calls or panic on OOM for call sites that can't propagate |
| `bun.default_allocator` | 🟢 | Process-wide allocator (re-exports `std.heap.smp_allocator`) |
| `bun.assert` | 🟢 | Alias for `std.debug.assert` |
| `bun.AllocationScope` | 🟢 | Allocator-scope wrapper for region-style lifetimes |
| `bun.Output` | 🟢 | Logger / stderr namespace (`enable_ansi_colors_stderr`, `isAIAgent`) |
| `bun.debugAssert` | 🟢 | Debug-only assert (compiles away in release builds) |
| `bun.create` | 🟢 | Typed allocator helper: `allocator.create + value` |
| `bun.StringHashMapUnmanaged` | 🟢 | Alias for the std-lib generic |
| `bun.String` | 🟢 | Interned-string newtype with `.static(...)` + `.slice()` |
| `bun.strings` | 🟢 | String utilities (`isValidUTF8` so far) |
| `bun.ast.Index` | 🟢 | Strongly-typed source-file / module index with `.Int = u32` companion |
| `bun.fs.Path` | 🟡 | Path record; Tier-0 callers read only `.text` (struct will grow per tier) |

Each subsequent tier opens the door for more vendored Bun files to
compile. See [Bun compat shim](/docs/PARITY-BUN-COMPAT)
for the per-symbol drill-down, planned Tier-2+ categories
(`bun.JSC.*`, `bun.path`, `bun.options`, `bun.resolver`,
`bun.MutableString`, `bun.bake`, `bun.css`, `bun.transpiler`,
`bun.SourceMap`), and the test wiring.

## Node.js compatibility (`packages/runtime/src/node/`)

Node's `node:*` namespace lands as part of the Bun runtime port (Bun
ships `node:*` shims natively, which we vendor verbatim). Numbers
below are Zig-side only; the JS-visible `node:*` surface attaches once
JSC's JS-callable bridge ships (Phase 12.2 has reached M6 — JSON +
Promise + Iterator + Global helpers — across 156 files).

| Measurement | Coverage | Notes |
|---|---|---|
| Node binding files ported | 28 files | `path`, `Stat`, `StatFS`, `dir_iterator`, `time_like`, `fs_events`, `os_constants`, `nodejs_error_code`, `node_fs_constant`, `node_net_binding`, `node_error_binding`, `uv_signal_handle_windows`, `types`, `util/parse_args_utils`, `assert/myers_diff`, plus top-level `buffer.zig`, `stream.zig`, `fs.zig`, `events.zig`, `util.zig`, `assert.zig`, `os.zig`, `url.zig`, `querystring.zig`, `crypto.zig`, `process.zig`, `string_decoder.zig`, `tty.zig` (Phase 12.7 round-15). |
| Functional `node:*` modules | 🚧 Awaiting JSC JS-callable bridge | Pantry CLI replaces `npm install` / `bun install`; everything else routes through the Bun runtime port once JSC ships its JS bridge (Phase 12.2 milestones M3-M6 are in; the JS-callable wire-up is the remaining piece). |

## LSP / IDE coverage — `home-lsp` vs `tsserver`

| Measurement | Coverage | % |
|---|---|---|
| **Wire methods routed** | **76 / ~80** | **~95%** |

Routed methods (`SUPPORTED_METHODS` in
[`packages/ts_lsp_server/src/ts_lsp_server.zig`](https://github.com/home-lang/home/blob/main/packages/ts_lsp_server/src/ts_lsp_server.zig)):
hover, definition, declaration, typeDefinition, implementation,
references (cross-file), completion + completionItem/resolve,
signatureHelp, semanticTokens (full + delta + range), inlayHint
(+ resolve), codeAction, codeLens (+ resolve), documentLink (+ resolve),
foldingRange, selectionRange, linkedEditingRange, documentHighlight,
documentSymbol + workspace/symbol, rename + prepareRename,
prepareCallHierarchy + incoming/outgoingCalls,
prepareTypeHierarchy + supertypes/subtypes, willSaveWaitUntil,
willRenameFiles, executeCommand, moniker (LSIF), inlineValue,
inlineCompletion, formatting + onTypeFormatting,
documentColor + colorPresentation, pull-based diagnostic +
workspace/diagnostic, lifecycle (initialize / initialized /
shutdown / exit), synchronization (didOpen / didChange / didClose /
publishDiagnostics).

**Remaining surface:** quick-fix breadth (organize imports + add
import + add explicit type annotation landed; fix-all,
missing-return-type, infer-parameter-types pending), FS-event-driven
push diagnostics, full formatter pass (current `formatDocument`
returns source unchanged), richer auto-import completion via
cross-file interner search.

## Language features

16 language rows from the
[Capability Matrix](/docs/CAPABILITY_MATRIX):

| Status | Count | % |
|---|---|---|
| ✅ Stable | 3 | 18.8% |
| 🚧 In progress / partial | 12 | 75.0% |
| ❌ Not yet | 1 | 6.3% |

**Per-feature:**

| Feature | Status |
|---|---|
| Lexer (full token set, escapes, line/col tracking) | ✅ Stable |
| Recursive-descent parser with error recovery | ✅ Stable |
| Type inference (primitives, structs, enums, arrays) | ✅ Stable |
| Pattern matching (`match` over enums, primitives, wildcards) | 🚧 In progress |
| Closures | 🚧 In progress |
| Traits / `impl` blocks | 🚧 In progress |
| Trait objects / dynamic dispatch | 🚧 In progress |
| Generics (functions and types) | 🚧 In progress |
| Comptime evaluation | 🚧 In progress |
| Macros (`todo!`, `assert!`, `unreachable!`, …) | 🚧 In progress |
| Null-safety operators (`?.`, `?:`, `??`, `?[]`) | 🚧 In progress |
| Result types and `?` propagation | 🚧 In progress |
| Async / await | 🚧 In progress |
| Ownership / move checking | 🚧 In progress |
| Borrow checker | 🚧 In progress |
| Const generics | ❌ Not yet |

## Codegen targets

7 codegen rows:

| Status | Count | % |
|---|---|---|
| ✅ Stable | 1 | 14.3% |
| 🚧 In progress / partial | 6 | 85.7% |

**Per-target:**

| Target | Status |
|---|---|
| Tree-walking interpreter | ✅ Stable |
| x86-64 native codegen | 🚧 Substantial (primary target) |
| arm64 codegen | 🚧 In progress (Path B-lite M1-M11 shipped) |
| WebAssembly codegen | 🚧 Stub |
| LLVM backend | 🚧 JS/TS native launcher shipped; Home AST lowering in progress |
| ELF object emission | 🚧 In progress |
| Mach-O object emission | 🚧 In progress |

## Tooling

11 tooling rows:

| Status | Count | % |
|---|---|---|
| ✅ Stable | 2 | 18.2% |
| 🚧 In progress / partial | 9 | 81.8% |

**Per-tool:**

| Tool | Status |
|---|---|
| `home check` (type-check) | ✅ Stable |
| `home run` (interpret) | ✅ Stable |
| `home build` (native binary) | 🚧 Home native codegen + self-contained LLVM JS/TS entrypoints |
| `home test` runner | 🚧 In progress |
| Formatter | 🚧 In progress |
| Linter | 🚧 In progress |
| LSP / IDE integration | 🚧 In progress (see [LSP coverage](#lsp--ide-coverage--home-lsp-vs-tsserver)) |
| VSCode extension | 🚧 In progress |
| REPL | 🚧 In progress |
| Package manager (`pkg`) | 🚧 In progress |
| Incremental compilation / IR cache | 🚧 In progress |

## Standard library

9 stdlib categories tracked in the capability matrix (the project ships
**136 packages under `packages/`** — most are 🚧 until end-to-end validated):

| Status | Count | % |
|---|---|---|
| ✅ Stable | 3 | 33.3% |
| 🚧 In progress / partial | 6 | 66.7% |

**Per-module:**

| Module | Status |
|---|---|
| Core primitives (`int`, `float`, `bool`, `string`, arrays) | ✅ Stable |
| String methods (`trim`, `upper`, `split`, …) | ✅ Stable |
| Range methods (`len`, `step`, `contains`, …) | ✅ Stable |
| HTTP server | 🚧 In progress |
| Database / SQL | 🚧 In progress |
| Threading | 🚧 In progress |
| FFI / C interop | 🚧 In progress |
| Audio / video / graphics | 🚧 In progress |
| Kernel / OS modules | 🚧 In progress |

## Capability matrix — combined totals

All 63 rows from [Capability matrix](/docs/CAPABILITY_MATRIX)
(language + codegen + tooling + stdlib + TypeScript frontend + runtime/Bun):

| Status | Count | % |
|---|---|---|
| ✅ Stable | 19 | ~30.2% |
| 🚧 In progress / partial | 42 | ~66.7% |
| ❌ Not yet | 2 | ~3.2% |

The conservative bias is intentional: anything not exercised by an
example or test stays 🚧 even when the underlying code is largely there.
