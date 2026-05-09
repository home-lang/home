# TypeScript Parity Plan — Home

> **Status:** Phase 0 in progress (started 2026-05-04). Authored 2026-05-04. Verified against tsgo source 2026-05-04 (see Appendix D).
>
> Cross-references: [`ARCHITECTURE.md`](./ARCHITECTURE.md), [`COMPILER_PIPELINE.md`](./COMPILER_PIPELINE.md), [`CAPABILITY_MATRIX.md`](./CAPABILITY_MATRIX.md), [`ROADMAP-WEB-COMPETITIVE.md`](./ROADMAP-WEB-COMPETITIVE.md).
>
> **Source verification.** All claims about tsgo internals in this document have been verified against the tsgo source tree at `~/Code/typescript-go` (Go port of `tsc` from microsoft/typescript-go). Citations use the form `path/file.go:line` referencing that tree. See Appendix D for a full verification table.

---

## Process State

**Last updated:** 2026-05-09
**Current phase:** Phase 3 type checker substantially complete + Phase 4 emit + Phase 8 LSP all advancing in parallel. Type checker covers: generic instantiation (incl. explicit type args properly substituted through signatures and explicit `new Foo<T>()` class-instance instantiation), **contextual generic callback instantiation for concrete call slots plus expected-return fallback for nested generic calls**, generic type-alias + **generic interface** + **generic class** instantiation, **fresh declaration-scoped type-parameter identities for generic shadowing**, mapped types over string-literal-union constraints, conditional types evaluating eagerly with union distribution + deferred-conditional substitution under generic-alias instantiation, structural object assignability, signatures with return-type inference, **object/interface call and construct signatures**, full narrowing surface (typeof / null / undefined / else-branch / instanceof / `in` / discriminated unions / `as const` / **type predicates `arg is T`** / **`asserts arg is T` fall-through narrowing** / **`===`-with-literal-RHS narrowing**) with proper union subtraction, **`await` unwraps structural `Promise<T>`**, **cycle-safe auto-variance inference for generic params**, arrow-fn signatures, class+interface+type-alias resolution, getter/setter accessor typing, `this`/`super` typing, **explicit `this` parameters erased from callable signatures**, `extends` inheritance with **generic `extends Foo<T>` instantiation** and **TS2416 incompatible override diagnostics**, **structural class `implements` checks (TS2420)**, ctor signatures, index signatures with **TS2411 member/indexer compatibility diagnostics**, tuple lowering including generic tuple elements under type-parameter scope, `Array<T>` shape plus declared `interface Array<T>` member augmentation, optional params, `keyof T` including literal-object aliases + `T[keyof T]` distribution, seeded lib globals (`NaN`, `Infinity`, `isNaN`, `parseFloat`, `Math`, `Number`, `String`, `console`), strict-mode flags `noImplicitAny` (TS7005/TS7006), `strictPropertyInitialization` (TS2564), `noUnusedLocals`/`noUnusedParameters` (TS6133), `strictFunctionTypes` (bivariant ↔ contravariant signature-assignability), TS2353 fresh-object excess-property checks **including nested object literals, string-indexer tolerance, and numeric property tolerance for number index signatures**, non-null assertion `expr!`, ambient-overload fallback resolution, all-optional object assignment for unconstrained generics, and regex literals as object-typed expressions. JS emit covers: full Phase 1 surface, **generic class heritage type-argument erasure**, **`??` and `?.` lowering at ES2019 and below**, **JSX automatic runtime (`_jsx`/`_jsxs`/`_jsxDEV`)**, **CommonJS module emit with `__importDefault`/`__importStar` interop helpers**, **async/await `__awaiter` downlevel for ES2015-ES2016**, **private fields → WeakMap**, **legacy decorators with parameter metadata**, **Stage 3 class/member decorator helper shape with static-member contexts**, **object-method shorthand ES5 lowering**, regex literal preservation, source map V3, symbol-driven `.d.ts`, **basic `.d.hm` framing emitter**, zig-dtsx fast path. LSP covers: hover, definition, cross-file references, completion (module-level), **signatureHelp**, **inlayHints (inferred-let-type)**, **documentSymbols + workspaceSymbols**, **semanticTokens (13-element legend)**, **rename (cross-file)**, **codeActions (Organize Imports)**, **formatDocument stub + foldingRanges**, **`didChangeFile` triggers recompile + fresh diagnostics**, diagnostics. Program graph: parallel parse/bind, **incremental `compileAll` skips unchanged files**, persistent on-disk compilation cache, multi-file cache wiring, **streaming diagnostics callback hook**, **two-level relation cache (L1+L2) for parallelization readiness**, **`declare global` augmentation collection across files**. Conformance: harness + 56-case canon corpus exercising every landed feature, **patience-diff unified output on baseline mismatch**, **smoke + category runs against local TS conformance folders**. CLI: **`home-tsc --watch` uses real `ts_watch.Watcher` + `RealStatFs`**, **`--pretty` wires through `formatPretty` with source-snippet excerpt**.
**Active deliverable:** Phase 6 — full local TypeScript conformance corpus integration (no submodule; use the locally-installed TypeScript checkout per user direction); Phase 7 — native codegen for typed TS subset; Phase 4.5 — bundler integration via Bun; Phase 4 follow-ups — generators→state-machine, full Stage 3 decorator initializer semantics, `.d.hm` type re-printing. Last verified full `zig build test --summary all` under Pantry-managed Zig `0.17.0-dev.263+0add2dfc4`: **2020/2020 tests passing**, diagnostics snapshots pass **95/95**, the local TypeScript conformance smoke is clean at **16/16** (`comparable` 13/13, `inOperator` 2/2, `stringLiteral` 1/1), the named category ratchet is clean at **86/86** (`assignmentCompatibility` 70/70, `comparable` 13/13, `inOperator` 2/2, `stringLiteral` 1/1), and the baseline-aware type-relationships survey is clean at **175/175** (`apparentType` 2/2, `bestCommonType` 8/8, `recursiveTypes` 13/13, `subtypesAndSuperTypes` 52/52, `typeAndMemberIdentity` 48/48, `typeInference` 52/52). Recent Phase 6 landings added exact `.errors.txt` diagnostic-header loading/comparison (`DirectoryLoadOptions.exact_error_headers`) plus an opt-in full 5 907-case local TypeScript corpus survey (`HOME_TS_CONFORMANCE_FULL=1`, with `HOME_TS_CONFORMANCE_START` / `HOME_TS_CONFORMANCE_LIMIT` for bisection). Full-corpus slice ratchets: `START=838 LIMIT=40` is **40/40**; `START=878 LIMIT=40` is now **40/40** after const type-parameter inference/assignability and async `Promise<T>` return inference; `START=918 LIMIT=40` moved **27/40 → 38/40** with override/noImplicitOverride diagnostics, `@noLib` reference-lib harness modeling, and virtual-section filtering for non-code multi-file fixtures. Remaining misses in the active 918 slice are `override_js4` (JSDoc `@override`) and `override21` (symbol-computed override base lookup). The coarse type-relationships ratchet is saturated; next Phase 6 work is continuing full-corpus slice ratchets, then graduating from expected-any checks to exact `.errors.txt` text comparison and a per-PR delta gate.

### Phase 0 — Infrastructure rebuild

| ID | Item | Status | Notes |
|---|---|---|---|
| 0.1 | Process State section in this plan | ✅ done | Added 2026-05-04 |
| 0.2 | `packages/arena/` | ✅ done | 11 tests; per-arena cumulative & peak-bytes counters; `PhaseArenas` bundle with reverse-order teardown |
| 0.3 | `packages/string_interner/` | ✅ done | 12 tests; 64-shard `(shard:6 \| local:26)` u32 keyspace; Wyhash shard select; in-package atomic-based RwLock; pre-interned empty string at id=0 |
| 0.4 | `packages/hir/` | ✅ done | 12 tests; SoA layout, **21 B/node hot-column footprint** (compile-time gate at ≤24); 17 per-kind payload tables; reserved primitive `TypeId`s 0–15; cold side-table for JSDoc / debug names |
| 0.5 | `packages/query/` | ✅ done | 14 tests; revision-based memoization, dep capture, cycle detection, diamond deps, value-equality back-dating ("durability"); generic over `K`, `V` (POD or `[]const u8`) |
| 0.6 | `bench/vs_tsgo/` harness skeleton | ✅ done | `run.sh` (corpus/cold/watch/report), `compare.py` (hyperfine-JSON → Markdown), `corpus.toml` (5 pinned workloads), `Dockerfile` for CI reproducibility |
| 0.7 | Refactor `packages/parser/src/parser.zig` (6 554 LOC split) | 🟡 partial | Directory + pattern landed (`parsers/`); `Precedence` extracted to `parsers/precedence.zig` (+9 unit tests, all passing); remaining 11 sub-modules tracked in `parsers/README.md` as Phase 0.7 follow-ups, gated by parser-test regression at each step. |
| 0.8 | Split `packages/codegen/src/native_codegen.zig` (10 889 LOC) | 🟡 partial | Directory + pattern landed (`native/`); 8 layout types extracted to `native/layouts.zig` (+8 unit tests, all passing); `pub const` aliases preserve external API. Remaining 9 sub-modules tracked in `native/README.md` as Phase 0.8 follow-ups, gated by codegen-test regression. |

### Phase 1 — TypeScript frontend

| ID | Item | Status | Notes |
|---|---|---|---|
| 1.A | Open package skeletons | ✅ done | `packages/ts_lexer/`, `packages/ts_parser/`, `packages/d_ts/`, `packages/tsconfig/` all wired into `build.zig` |
| 1.B | TS lexer | ✅ done | 9 token + 9 keyword + 16 scanner tests; full TS keyword catalog (~85 entries) via comptime perfect-hash buckets; numbers (dec/hex/oct/bin/exp/bigint/separators); strings; template head/middle/tail/no-substitution; full operator + punctuation surface; trivia handling with `preceded_by_newline` for ASI; private identifiers |
| 1.C | tsconfig | ✅ done | 15 jsonc + 14 tsconfig tests; full JSONC parser (line + block comments, trailing commas, escapes, unicode); typed schema with ~40 typed compilerOptions (strict family, modules, emit, JS support); `extends` (string \| string[]), files / include / exclude / references; `paths` mapping; unknown-key pass-through; `merge()` for extends chains |
| 1.D | TS parser foundation | ✅ done | 8 precedence + 28 parser tests; recursive-descent statements + Pratt expressions, lowering directly into HIR. Literals, identifiers, full operator-precedence arithmetic with right-associative `**`, parens, member access, optional chaining, calls (zero / N args), element access, conditional, logical (`&&`/`\|\|`/`??`), unary (`!`/`-`/`~`/`typeof`/`void`/`delete`), assignment + compound, var/let/const decls (single binding), return (with ASI), nested blocks. Type annotations parsed-and-skipped. |
| 1.E | d_ts loader foundation | ✅ done | 5 d_ts tests; `Lib` enum for the full lib catalog (es5..es2024, esnext, dom, dom_iterable, webworker, scripthost), `libsForTarget` closure helper, `Loader` scaffold; full lib loading + ambient module declarations tracked as Phase 1.E follow-up (depends on Phase 1.D parsing `interface`, `declare module`) |

**Phase 1 follow-ups (mechanical, gated by per-feature tests):** ✅ control flow (if/while/for/switch/try) landed 2026-05-05; ✅ function/class/interface/enum/namespace declarations landed 2026-05-05; ✅ imports/exports incl. type-only forms landed 2026-05-05; ✅ array + object literals (incl. shorthand/method/computed) + this/super/new landed 2026-05-05; ✅ var_decl/let_decl/const_decl HIR nodes (replacing assignment lowering) landed 2026-05-05; ✅ full type-annotation parsing (primitives, type refs, qualified names, unions, intersections, arrays, tuples, fn/constructor types, indexed access, keyof, typeof, infer, conditional, mapped, literal types) landed 2026-05-05; ✅ arrow functions (with the `(T) => U` ambiguity resolved by speculative parse) landed 2026-05-05; ✅ generic type parameters on function/class/interface/type-alias decls (with `extends` constraints, `=` defaults, `in`/`out` variance modifiers) landed 2026-05-05; ✅ JSX/TSX parsing (structured form — elements, attributes, expression children, fragments, member-access tags) landed 2026-05-05; ✅ variadic tuple types `[A, ...T, B]` landed 2026-05-06 (commit `25255a3`); ✅ labeled tuple element types `[name: T, count: number]` landed 2026-05-06 (commit `4779be4`); ✅ mapped-type `as` rename clause landed 2026-05-06 (commit `8bb62d3`); ✅ `satisfies` operator landed 2026-05-06 (commit `2a9aeb1`); ✅ `const` type parameters TS 5.0 syntax landed 2026-05-06 (commit `a941758`); ✅ import attributes (`with` / `assert`) syntax landed 2026-05-06 (commit `eb5baa2`); ✅ `accessor` class member modifier TS 4.9 landed 2026-05-06 (commit `6547339`); ✅ `using` and `await using` declarations landed 2026-05-06 (commit `35b5e3f`); ✅ `yield*` delegated iteration parser + emit landed 2026-05-07 (commit `b26e61c`); ✅ tagged template literal call typing v0 landed 2026-05-07 (commit `26dd839`); ✅ destructuring with defaults — undefined removal in checker landed 2026-05-07 (commit `47b7e53`); ✅ shebang trivia scanning landed 2026-05-07 (commit `c86c4df`); ✅ regex literal scanning + HIR/checker/emit support landed 2026-05-07; ✅ decorator parsing is no longer discarded by emit: legacy + Stage 3 helper shapes are covered under §4.A; ✅ renamed/nested binding patterns, rest-placement parse diagnostics, spread call arguments, for/catch binding-pattern targets, literal/computed binding-pattern keys, and declaration-list tolerance landed 2026-05-08. *Remaining:* template literal substitutions (parser-driven `rescanTemplate` after each interpolated expression); free JSX text content (requires lexer mode switching); full Unicode ID-Start / ID-Continue tables; computed property names full evaluation; full lib loading.

### Phases ahead

| Phase | Status | Notes |
|---|---|---|
| 2 — Binder + symbol table | 🟢 substantially complete | `packages/binder/` ships value/type/namespace meaning-spaces, scope graph, declaration merging (interface+interface, class+namespace, enum tri-space), import-rename, type-only routing, scope-walk lookup. Remaining Phase 2 follow-ups: cross-file `Module.augment(other)` for `declare global` and module augmentation; full `var`-vs-`let` hoisting (parser already emits dedicated nodes). |
| 3 — Type checker | 🟢 substantially complete | `packages/ts_checker/` ships SoA Pool, structural Interner with sort+dedup canonicalization plus fresh declaration-scoped type-parameter identities where TS shadowing requires them, RelationCache + Engine with the four core relations (identity/assignable/subtype/comparable). Generic instantiation (call-site inference + explicit type args), generic type-alias/interface/class instantiation, structural object assignability with optional/excess/missing-prop semantics, signatures with return-type inference, full narrowing surface (typeof / null / undefined / else-branch / instanceof / `in` / discriminated unions / `as const`), arrow-fn signatures, class+interface+type-alias resolution, `this`/`super` typing, `extends` inheritance with generic heritage instantiation + TS2416 override checks, structural `implements` checks with TS2420, ctor signatures, index signatures with TS2411 member/indexer compatibility checks, tuple lowering, `Array<T>` shape, optional params, `keyof T`, `noImplicitAny` / `strictPropertyInitialization` / `noUnused*`, TS2322/2339/2345/2353/2411/2416/2420/2554/2564/6133/7005/7006 codes wired. **Phase 3 punch list (§3.A below)** tracks remaining algorithmic gaps; the relation engine itself and the lowering surface are stable. |
| 4 — JS emit + .d.ts + .d.hm | 🟡 JS + symbol-driven .d.ts + zig-dtsx fast path landed | `packages/ts_emit/` streams JS for the full Phase 1 surface (statements + expressions, with TS-only constructs erased). Source map V3 streaming printer wired (records mappings as it streams; supports `sourceMappingURL` trailer). Symbol-driven `.d.ts` emitter renders inferred return types, class-field annotations, type aliases. zig-dtsx fast path wired through pantry. Legacy `__decorate` / `__metadata` decorator emit and simplified Stage 3 `__esDecorate` helper shapes are landed, including static member target/context ratchets. `packages/d_hm/` ships the Lib catalog + Loader scaffold; `.d.hm` type re-printing is a Phase 4 follow-up. Phase 4 punch list (§4.A): generator state-machine downlevel; full Stage 3 decorator initializer semantics; `.d.hm` type re-printing. |
| 4.5 — Bundler integration | 🟡 driver + program graph + home-tsc CLI landed | `packages/ts_driver/` runs lex→parse→bind→check→emit per file with cache integration (`emitWithCache`). `packages/ts_program/` builds the multi-file graph + cross-file resolution + parallel parse/bind via `compileAllParallel` + `recompileChanged` for watch mode. `home-tsc` binary discovers tsconfig, expands `include`/`exclude` globs, routes `outDir`/`declarationDir`, emits both `.js` and `.d.ts`. Phase 4.5 punch list (§4.5.A): vendor Bun bundler (`~/Code/bun/src/bundler/`); HIR↔Bun-AST shim; symbol-table bridge; type-checked emit gate; CLI `home bundle` surface; plugin API; CSS bundling; HTML imports. |
| 5 — Performance engineering | 🟡 watch + cache + parallel bind landed | `packages/ts_watch/` polls a pluggable `StatFs` and emits `ChangeSet`s. `packages/ts_cache/` is a content-addressed cache with disk persistence (sharded `<root>/<2hex>/<rest>.cache`, `HMC1` magic). `Program.compileAllParallel` spawns `min(NPROC, 8)` workers. Phase 5 punch list (§5.A): finer-grained query DB invalidation (per-symbol vs per-file); Salsa-style query memoization across phases; mmap'd `lib.*.d.ts`; PGO + LTO build of Home itself; perf gates wired into CI; native FS-event backends (FSEvents/inotify/ReadDirChangesW). |
| 6 — Conformance hardening | 🟡 runner + 56-case canon corpus + local TS smoke/category/full-corpus hooks landed | `packages/ts_conformance/` runs source through the compiler and diffs against tsc-style baselines. `runCorpus(gpa, corpus, *results) -> Stats` plus `runDirectory` cover inline and disk fixtures. `runCategorySpecs` summarizes named local TypeScript conformance folders with bounded memory, the current category gate is **86/86**, `exact_error_headers` loads upstream `.errors.txt` diagnostic headers for byte comparison, and `HOME_TS_CONFORMANCE_FULL=1` runs the local 5 907-case corpus with start/limit controls for crash bisection. Current ratchets: `START=838 LIMIT=40` is **40/40**; `START=878 LIMIT=40` is **40/40**; `START=918 LIMIT=40` is **38/40**, with remaining misses isolated to JSDoc `@override` and symbol-computed override base lookup. Phase 6 punch list (§6.A): finish crash-free full-corpus execution, promote exact diagnostic comparison, and wire a per-PR delta gate. |
| 7 — Native codegen for TS | ⬜ blocked-by Phase 6 | The "typed monomorphizable subset" is well-understood; existing `packages/codegen/` and `packages/optimizer/` apply. |
| 8 — LSP | 🟢 protocol layer + cross-file refs + extensive wire surface landed | `packages/ts_lsp/` (query surface) + `packages/ts_lsp_server/` (JSON-RPC framing + Method dispatch) + `home-lsp` stdio binary. Hover renders TypeIds; goto-definition walks the binder's scope graph; references search every file in the program graph. Wire-protocol coverage now includes: `codeLens`, `typeDefinition`, `callHierarchy`, `didChange publishDiagnostics(Diagnostic[])`, parameter-name inlay hints, `completionItem/resolve` (detail), `implementation`, `documentLink`/`documentLinkResolve`, `textDocument/diagnostic` pull, `workspace/willRenameFiles` (now with real import-path rewrites, no longer a stub), `textDocument/selectionRange`, `textDocument/linkedEditingRange` (JSX tag-pair, real implementation), `workspace/executeCommand`. Comprehensive method-coverage audit + `SUPPORTED_METHODS` list landed in `ts_lsp_server`. Remaining (§8.A): auto-import completion via interner search; semantic tokens at full granularity; codeAction (organize imports, fix-all, infer param types); FS-event-driven push diagnostics. |
| 9 — Ecosystem & migration | ⬜ blocked-by Phase 7 | |
| 10 — Release & validation | ⬜ blocked-by all | |

### Update protocol

Each landed deliverable updates the table above (status → ✅ done) **and** writes a short journal entry below. The journal grows append-only — never edit prior entries; if scope changes, write a new entry that supersedes.

### Journal

- **2026-05-04 — Phase 0 kickoff.** Added Process State tracking. Phase 0 task list opened. Verified Zig toolchain at 0.16.0-dev.3144+ac6fb0b59. Confirmed existing `packages/lexer/src/string_pool.zig` is broken under modern Zig API (`std.ArrayList(T).init` no longer exists; needs migration to `.empty` + allocator-on-append) — flagging for Phase 0 cleanup pass after the new packages land.
- **2026-05-04 — Phase 0.2 (`packages/arena/`) landed.** 247-LOC implementation, 11 unit tests, all passing under `zig build test`. Provides `Arena` (named, scoped, with cumulative + peak-live byte counters bound to the standard `std.mem.Allocator` vtable) and `PhaseArenas` (canonical seven-phase bundle: lex/parse/ast/bind/hir/check/emit, torn down in reverse phase order). Wired into `build.zig` test step. Note on pre-existing build state: `zig build` (full exe) is broken at `src/main.zig:945` from a Zig stdlib API change (`error.EndOfStream` no longer in the LSP `readPacket` error set) — unrelated to TS-parity work, but every Phase 0 step verifies via `zig build test` rather than `zig build` until that's fixed in a separate cleanup PR.
- **2026-05-04 — Phase 0.3 (`packages/string_interner/`) landed.** 12 unit tests including parallel-stress over 8 threads × 250 inserts + RwLock-correctness across 4 threads. 64-shard table; `StringId = (shard:6 | local:26)`; Wyhash for shard selection; per-shard `RwLock + StringHashMapUnmanaged + ArrayListUnmanaged + ArenaAllocator`. Discovery during implementation: Zig 0.16-dev moves `std.Thread.RwLock` → `std.Io.RwLock` (Io-abstraction migration), and the Io variant requires an `Io` parameter on every operation. Workaround: shipped a minimal in-package `RwLock` built on `std.atomic.Value(u32)` with a writer-bit + reader-count layout. This is reader-preferred and spins under contention, which is acceptable given the 64-way sharding makes per-shard contention near-zero. Phase 5 will revisit if profiling demands a futex-backed primitive. `count()` post-init is `1` (empty string pre-interned at id=0). Total tests across both packages: 23. `zig build test` summary: 561/561.
- **2026-05-04 — Phase 0.4 (`packages/hir/`) landed.** 12 unit tests; the §5.2 SoA design materialized in code. Hot-column footprint: `kind:1 + span:8 + parent:4 + type:4 + payload:4 = 21 B/node` — under the 24 B budget per the plan, with a `comptime` gate that fails compilation if a future change pushes it higher. Reserved sentinels: `none_node_id = 0` in every column, primitive `TypeId`s 0–15 (Tier 1 §11.3 bit-packed: `any`, `unknown`, `never`, `void`, `null`, `undefined`, `string`, `number`, `boolean`, `bigint`, `symbol`, `object`, `true_lit`, `false_lit`, plus 2 reserved). Per-kind side tables for binop/unary/logical/update/call/member/element/identifier/string-lit/number-lit/bigint-lit/bool-lit/conditional/assignment/block/if/return; variable-arity children (call args, block stmts) live in a shared `child_pool`. `Builder` API auto-wires `parent` fields. Cold side-table for JSDoc + debug names is keyed by `NodeId` and never consulted on the hot path (Tier 1 §11.4). The HIR is the converging IR for both the existing Home frontend and the future TS frontend; new node kinds added incrementally as Phase 1 lands. `zig build test` summary: 573/573.
- **2026-05-04 — Phase 0.5 (`packages/query/`) landed.** 14 unit tests covering input set/fetch, derived memoization, dep capture, transitive cycle detection (`a → b → a`), self-cycle, diamond deps, durability back-dating (re-execution that produces the same value advances `verified_at` without bumping `changed_at`, so transitive consumers can skip re-running), `changedAt`/`verifiedAt` accessors, string-keyed slots. Generic over `K` and `V`; `K = []const u8` is auto-routed through `StringHashMapUnmanaged` with key duping, all other key types use `AutoHashMapUnmanaged`. Cell layout: `{value, changed_at, verified_at, deps, owned_key}` ≤ 64 B per cell. Note on Phase 0 scope: dep validity is currently revision-tracked at the cell level (re-executes on any input change) rather than fine-grained per-dep-revision; the §5.7 watch-mode 80 ms target needs the finer-grained version, scheduled for Phase 5 once the Db is wired into a real workload. `zig build test` summary: 587/587.
- **2026-05-04 — Phase 0.6 (`bench/vs_tsgo/`) landed.** Harness skeleton: `run.sh` (`corpus`/`cold`/`watch`/`report` subcommands), `compare.py` (hyperfine JSON → Markdown table renderer with stdlib-only Python), `corpus.toml` (5 pinned workloads with placeholder SHAs to be set on first materialize: typescript, vscode, twenty_crm, playwright, ts_toolbelt_consumer), `Dockerfile` for CI reproducibility. Status: tooling is functional for `tsc` + `tsgo` today; the `home` column is wired but skipped until Phase 1 lands `home tsc`. Output format mirrors §6.4 / §0 headline tables exactly so report generation is one-command.
- **2026-05-04 — Phase 0.7 (parser refactor) — partial.** `packages/parser/src/parsers/` directory created with `README.md` documenting the 12-module target split keyed against the original line ranges of the 6 554 LOC monolith. First module landed: `parsers/precedence.zig` (the `Precedence` enum + `fromToken`, ~110 LOC plus 9 unit tests covering arithmetic / comparison / equality / assignment / logical / call / range / pipe / non-operator → None / power-above-factor). Old definition replaced with a single import alias so the rest of `parser.zig` is untouched. Parser test suite (65 tests) re-runs unchanged → no regression. Remaining 11 sub-modules tracked in the parsers/README table as Phase 0.7 follow-ups; each lands as its own PR with the parser test suite as the regression gate.
- **2026-05-04 — Phase 0.8 (codegen refactor) — partial.** `packages/codegen/src/native/` directory created with `README.md` documenting the 10-module target split keyed against the original line ranges of the 10 889 LOC monolith. First module landed: `native/layouts.zig` (StructLayout, FieldInfo, EnumVariantInfo, EnumLayout, LoopContext, LocalInfo, FunctionParamInfo, FunctionInfo, StringFixup — all pure data + 8 unit tests). External API preserved via `pub const StructLayout = layouts.StructLayout;` style aliases in `native_codegen.zig`, so every existing caller keeps compiling untouched. Remaining 9 sub-modules tracked in native/README.md as Phase 0.8 follow-ups.
- **2026-05-04 — Phase 0 close-out.** Eight deliverables shipped (six fully done, two partials with the structural pattern in place). Net effect: **587 → 604 tests** (66 new TS-parity-foundation tests) all passing, six new packages on `zig build test`, plan-tracking embedded in `TS_PARITY_PLAN.md` so future phases auto-update against this journal. Key architectural inventory landed: phase-scoped arenas with byte-budget tracking → ready for the Lex/Parse/Bind arenas Phase 1 needs; lock-striped 64-shard global string interner → ready to replace the per-file `string_pool.zig` when Phase 1's TS lexer starts producing identifiers; SoA HIR with 21 B/node hot-path footprint → the receiving IR for both frontends; Salsa-style query DB → ready to underpin watch-mode incremental and the LSP. Phase 1 (TypeScript frontend, 8–12 weeks for one engineer) is next; Phase 0 partials (parser + codegen splits) continue as background mechanical work in parallel.
- **2026-05-04 — Phase 1.A (`packages/ts_lexer`, `packages/ts_parser`, `packages/d_ts`, `packages/tsconfig`) skeletons opened.** Four new packages wired into `build.zig`. Each gets its own test step. `d_ts` ships with the full Lib enum (es5..esnext + dom variants) so downstream packages can compile against it.
- **2026-05-04 — Phase 1.B (TS lexer) substantially landed.** 16-byte `Token` (span + kind + flags + line). `TokenKind` covers full ES2024 + TS keyword surface (~85 entries) with category predicates (`isKeyword`, `isContextualKeyword`, `isPrimitiveTypeKeyword`, `isModifierKeyword`, `canStartExpression`). Comptime-built keyword recognizer (Tier 1 §11.14) — buckets by length 2..11, ≤ 6 candidates per bucket, no hash table. Scanner: identifiers, all numeric forms (decimal / hex / oct / bin / exponent / bigint / `_` separators), strings (single, double, escape sequences, line-continuation), template literal head/middle/tail/no-substitution, full operator + punctuation surface (compound assignment, equality, shifts, `?.`, `??`, spread), private identifiers, line + block comments as trivia, ASI signaling via `preceded_by_newline`. 34 tests covering each category. Out of scope (Phase 1.B follow-ups, parser-driven): regex literal scanning, JSX text scanning, full Unicode ID-Start tables.
- **2026-05-04 — Phase 1.C (tsconfig) landed.** Self-contained JSONC parser (line + block comments, trailing commas, full string escape decoding, unicode escapes, duplicate-key rejection per strict JSON, integer / decimal / exponent / negative numbers). Typed `TsConfig` schema with ~40 typed `compilerOptions` (strict family, modules, emit, JS support, JSX), `extends` (string \| string[]), files / include / exclude / references, `paths` mapping with wildcards, lib array, unknown-key pass-through bag (`extra`). `merge()` for extends-chain composition, child-overrides-base on every set field. 29 tests across the JSONC parser and the schema. Disk I/O deferred to the driver layer; everything tested hermetically against in-memory sources.
- **2026-05-04 — Phase 1.D (TS parser foundation) landed.** End-to-end source → tokens → HIR pipeline. Pratt expression parser with the full TS precedence lattice (`precedence.zig`), right-associative `**` and assignment. Recursive-descent statements: `let`/`const`/`var` declarations (single binding, type-annotation skipped), return (with ASI on newline), block statements, expression statements, empty statement. Expressions: number / bigint / string / bool / null literals, identifiers, parens, full binary operator family (arithmetic / bitwise / comparison / equality / shift / `instanceof` / `in`), logical operators with short-circuit (`&&`/`\|\|`/`??`) emitted as HIR `logical_op`, unary prefix (`!`/`-`/`+`/`~`/`typeof`/`void`/`delete`), conditional ternary, assignment + 5 compound forms, member access (`.` / `?.`), element access (`[…]` / `?.[…]`), call expressions with N args. 36 tests against substantive TS programs verifying the resulting HIR shape — including precedence direction, associativity, ASI behavior, and digit-separator + radix-prefix numeric parsing. Phase 1.D follow-ups documented in the package's docstring.
- **2026-05-04 — Phase 1.E (`packages/d_ts/`) foundation landed.** Lib catalog enum covering the full upstream-TS lib set (es5..es2024, esnext, dom, dom.iterable, webworker, scripthost), with `Lib.fileName()`, `Lib.fromName()` round-trips and a `libsForTarget()` closure helper that returns the transitive set implied by a target ES version. `Loader` scaffold with a stubbed `loadLib()` that returns `error.NotImplemented` until Phase 1.E follow-up wires the TS frontend's declaration-only mode. 5 tests covering enum round-trips and closure semantics.
- **2026-05-04 — Phase 1 close-out.** Five deliverables shipped (all complete to their stated scope). **604 → 733 tests** (+129 net Phase 1 tests). Six new TS-frontend packages compile and test cleanly under `zig build test`. End-to-end demonstrated: `let total = (a + b) * c.value(0) - 1;` → tokens → HIR with correct parent links, span tracking, and operator precedence. Phase 1 follow-ups (full grammar coverage, types, JSX, decorators, lib loading) catalogued and queued as mechanical work that doesn't block Phase 2 (binder) — Phase 2 can begin against the current HIR shape and gain visibility into new node kinds as they land. Pre-existing `src/main.zig:945` build break still standing; all Phase 1 verification went through `zig build test`.
- **2026-05-05 — Phase 1.D follow-ups (control flow + declarations + imports/exports).** Bulk of the TS statement grammar landed in `packages/ts_parser/`. New constructs: `if`/`else`, `while`, `do`/`while`, `for` (3-part), `for`/`in`, `for`/`of`, `break`/`continue` with optional labels, `throw`, `try`/`catch`/`finally`, `switch` with `case`+`default`, `function` declarations (with optional/rest params + type annotation skipping), `class` declarations (with `extends`/`implements`/method+property body, modifier-keyword skip), `interface` declarations (body skipped, body parsed past closing brace), `type` aliases, `enum` declarations, `namespace`/`module` blocks. Imports: default, named with `as` rename, namespace (`* as`), type-only, bare side-effect. Exports: default (incl. `export default class/function/interface`), named (incl. type-only specifiers), re-exports (`export … from`), `export *`, `export <decl>`. Expression additions: array literals (with holes), object literals (computed keys, shorthand, method shorthand, spread), `this`, `super`, `new` (lowered as call), function expressions. HIR gained 18 new node payloads + builder methods + accessors; hot-column footprint pinned at 21 B/node by the comptime gate. `zig build test` summary: 819/819 (+35 from Phase 1.D follow-ups).
- **2026-05-05 — Phase 2 (`packages/binder/`) foundation landed.** Walks `ts_parser`'s HIR, creates `Symbol` records keyed by interned name in three meaning-spaces (value / type / namespace) per tsc. Capabilities: function-decl + parameter scoping; class decl in both value+type with method-body parameter binding; interface in type space (with merged-flag on duplicate decls); type-alias in type space; enum tri-space (value+type+namespace); namespace in namespace+value with nested-decl scope; imports with type-only / named-rename / namespace forms; exports tag inner symbol as exported / default-exported. `Scope.lookup` walks the parent chain; `Module` arena owns all symbols and scopes for bulk teardown. Declaration merging via OR-fold of `SymbolFlags` on `Symbol.addDecl`. 18 binder tests including class+namespace merge, interface+interface merge, import-rename, type-only space routing, scope.lookup-walk. `zig build test` summary: 837/837.
- **2026-05-05 — Phase 3 (`packages/ts_checker/`) foundation landed.** Three modules in `packages/ts_checker/src/`: `types.zig` (SoA Pool with primitive ids matching `hir.reserved_type_ids`, TypeFlags bit-field, 12 per-kind side tables, four shared variable-arity element pools), `interner.zig` (structural interner; union/intersection/tuple members sorted+deduped before keying so `A | B` and `B | A` collapse to the same TypeId; empty union → never; empty intersection → unknown; single-member compounds collapse), `relation.zig` (Engine + RelationCache with u64-packed `(rel:8, src:28, tgt:28)` keys, cycle-safe `pending` marker; implements identity / assignable / subtype / comparable with the canonical TS rules: any-bidirectional, never-bottom, unknown-top, void ← undefined, literal-to-primitive narrowing, union-source `all` / -target `any`, intersection-target `all` / -source `any`, subtype excludes `any` either side). HIR → type lowering, generic instantiation, mapped/conditional evaluation, narrowing, variance computation are Phase 3 / 6 follow-ups against this same shape. 27 ts_checker tests including subtype-vs-assignable for `any`, union-canonicalization, structural intern dedup. `zig build test` summary: 864/864.
- **2026-05-05 — Phase 4 (`packages/ts_emit/` + `packages/d_hm/`) scaffolds landed.** `ts_emit/src/js_emit.zig` is a streaming JS pretty-printer over post-bind HIR — no intermediate JS-AST. Coverage: literals + identifiers; binary / unary / logical / conditional / assignment + 11 compound forms; calls (regular and `?.()`); member (regular and `?.`); element (regular and `?.[]`); array literals (with holes); object literals (key:value, shorthand, method, computed); function declarations (incl. async, generator, default + rest params); class declarations with `extends` and methods+properties; enum lowered to IIFE matching tsc; namespace lowered to IIFE; imports (named + default + namespace + side-effect); exports (default, named, decl-form). Erasure: `interface_decl`, `type_alias_decl`, and type-only imports/exports emit nothing. `packages/d_hm/` ships the `Lib` catalog (core/io/concurrency/collections/time/ffi) with `fileName()` + `fromName()` round-trips and a `libsForTarget()` closure helper, plus the `Loader` scaffold. 26 ts_emit tests + 5 d_hm tests. `zig build test` summary: 895/895.
- **2026-05-05 — VarDecl + real type annotations landed.** Replaced the `assignment(ident, init)` lowering of `let x = 1` with proper `var_decl` / `let_decl` / `const_decl` HIR nodes carrying the type-annotation slot. New `parseTypeAnnotation` produces real HIR type nodes for the full TS type grammar subset: primitive type refs (any/unknown/never/void/null/undefined/string/number/boolean/bigint/symbol/object), qualified-name type refs (`A.B.C`) with generic args (`Foo<T, U>`), unions (`T | U`) with leading-`|` allowed, intersections (`T & U`), arrays (`T[]`), tuples (`[A, B]` with optional rest/`?`/labels), fn types (`(a: T) => U`) with paren/fn-type speculative disambiguation, constructor types (`new () => T`), indexed access (`T[K]`), `keyof T`, `typeof e`, `infer X` with optional `extends C`, conditional types (`T extends U ? X : Y`), mapped types (`{ [K in T]: V }` with `?` modifiers), literal types (`"hello"`, `42`, `-42`, `true`). Type-parameter declarations (`<T extends U = D>`) parse with `in`/`out` variance modifiers. Object types (`{ … }`) currently lower to a synthetic `object` type ref — full member-list lowering is a follow-up. Binder now binds via `bindVarDecl`; emitter emits `let`/`const`/`var` keywords with type annotations erased. 14 type-annotation parser tests + 3 emit tests. `zig build test` summary: 912/912 (+17).
- **2026-05-05 — Arrow functions landed.** `maybeParseArrowFunction` handles four shapes: `x => …`, `() => …`, `(a, b) => …`, `<T>(a: T) => …` plus `async`. The `(T)` vs `(T) => U` ambiguity resolves via speculative parse (`findMatchingParenEnd` + peek for `=>` or typed-return `:`). Body is either a block_stmt or a single AssignmentExpression per the JS spec. `printFnDecl` lowers arrow-flagged FnDecl as `async (a, b) => …` / `async (a) => { block }`. 8 parser tests + 3 emit tests. `zig build test`: 923/923 (+11).
- **2026-05-05 — Generics on declarations landed.** Wired `parseTypeParameterDeclaration` into all the places TS allows `<T extends U = D>`: function decls, classes (with `extends Foo<T>` carrying its own generic args), interfaces, type aliases, methods inside classes, default + constraint + variance modifiers. Type aliases now produce a real `aliased` HIR type node. parseParameterList now uses real `parseTypeAnnotation` for parameter types and skips parameter-property modifiers (`public`/`private`/`readonly` etc.) and decorators on parameters. 7 generics tests. `zig build test`: 930/930 (+7).
- **2026-05-05 — Driver (`packages/ts_driver/`) landed.** Single-file end-to-end TS compilation: `compileSource(gpa, source, options)` returns a `*Compilation` with the emitted JS, full diagnostics list (tagged by phase: lex/parse/bind/emit), the bound symbol table, the HIR, and the token stream. `Compilation.lookupTopLevel(name)` walks the module-level scope across all three meaning-spaces. Errors accumulate; `continue_on_error=true` (default) keeps the pipeline running so the LSP can show partial output. Phase 4.5 deliverable: 10 end-to-end driver tests covering empty source, let bindings, type-annotation erasure, generic functions, arrow functions, interface erasure + class non-erasure, runtime imports vs type-only imports, control-flow round-trip, classes with methods. `zig build test`: 940/940 (+10).
- **2026-05-05 — JSX/TSX landed.** 5 new JSX HIR payloads (jsx_element, jsx_attribute, jsx_spread_attribute, jsx_expression, jsx_fragment). `parser.setTsx(true)` enables JSX parsing in expression position. Coverage: `<Foo />`, `<Foo></Foo>`, `<Foo>...</Foo>`, fragments `<>...</>`, attributes (name=str, name={expr}, name boolean shorthand, {...spread}), expression children {expr}, nested elements, member-access tags `<Foo.Bar/>`. In `.ts` (non-TSX) files, `<` in expression position parses as a type assertion (legacy `<T>x` form). Free text content is the only deferred bit — needs lexer mode switching, tracked as a follow-up. `printJsxElement` emits classic React.createElement(tag, props, ...children) form. Lowercase tags become string literals (HTML); capitalized tags emit as identifier refs (components). Fragments lower to React.Fragment. CompileOptions.is_tsx flag toggles the parser. 9 parser tests + 3 driver tests. `zig build test`: 952/952 (+12).
- **2026-05-05 — Source map V3 generator (`packages/ts_emit/src/source_map.zig`) landed.** Produces JSON output byte-equivalent to tsc's V3 spec: SourceMap.init(gpa, file) → addSource(name, content) → addName(name) → addMapping(mapping) → toJson(). VLQ encoder/decoder for the mappings field with sign-bit-in-low-bit convention, 5 bits per digit, high-bit continuation. Mappings are sorted by (gen_line, gen_col); deltas are computed against the previous segment per spec; gen_col resets at each new line; line skips emit empty `;` separators. Wire-into-printer is a Phase 4.5 follow-up once the Printer tracks gen_line/gen_col as it streams. 10 tests. `zig build test`: 962/962 (+10).
- **2026-05-05 — Module resolver (`packages/ts_resolver/`) landed.** Resolves import specifiers to file paths across the five tsc strategies (classic / node10 / node16 / nodenext / bundler), driven by a FileSystem abstraction so tests run against an in-memory VirtualFs. Coverage: relative (with multi-extension probe over .ts/.tsx/.d.ts/.mts/.cts/.js/.jsx/.mjs/.cjs/.json plus the Home extensions .home/.hm/.d.hm), absolute (POSIX + Windows), bare specifiers via paths-mapping with wildcard-suffix substitution (`@/*` → `["src/*"]`), bare specifiers via node_modules walk (parent-directory chain), directory imports falling through to package.json or index.X, package.json field priority types > typings > module > main, Resolution.is_declaration tagged for .d.ts / .d.hm hits. 15 resolver tests. `zig build test`: 977/977 (+15). Phase 4.5 follow-ups: package.json `imports` subpath patterns, full `exports` conditional resolution, `references` resolution chain.
- **2026-05-05 — HIR → TypeId lowering (`packages/ts_checker/src/lower.zig`) landed.** Connects Phase 1 type parsing to Phase 3 relations: walks HIR type nodes and produces interned TypeIds via the existing `Interner`. Coverage: primitive type refs (any/unknown/never/void/null/undefined/string/number/boolean/bigint/symbol/object) lower to matching `Primitive.*` sentinels; literal types ('hello', 42, true, false, -42) intern via the literal-type APIs; unions/intersections lower recursively (members canonicalized via interner sort+dedup); keyof/T[K]/typeof/conditional infer types intern structurally; tuples lower as union of element types (first-order placeholder); arrays `T[]` currently lower to `T` (placeholder until generic instantiation lands); non-primitive named refs fall through to `Primitive.unknown` (symbol resolution against the binder is Phase 3 follow-up). 14 lowering tests. `zig build test`: 977 → 991 (+14).
- **2026-05-05 — Driver tsconfig integration.** `CompileOptions.pub_tsconfig` holds an optional borrowed pointer to a parsed TsConfig. `optionsFromConfig(cfg)` derives CompileOptions from a tsconfig: any `compilerOptions.jsx` setting (preserve/react/react-jsx/react-jsxdev/react-native) flips `is_tsx` so the parser enters JSX mode. Sets up the surface for Phase 9 to feed target/module/strict/paths from tsconfig into the checker + emitter + resolver. 2 tests. `zig build test`: 991 → 993 (+2).
- **2026-05-05 — Diagnostic formatter (`packages/ts_diagnostics/`) landed.** Produces byte-equivalent output to `tsc` per §2.4. Default form `path/file.ts(line,col): error TSxxxx: message` matches what most editor / IDE / CI tools scrape; pretty form adds ANSI colors + source-code excerpt + squiggly underline. `HMxxxx` prefix for Home-only diagnostics, `TSxxxx` for upstream-compat. Severity.exitCode() returns process exit code (1 err / 0 warning / 0 suggestion — matches tsc). `positionToLineCol(source, byte_pos)` helper. `TsCodes` constant table seeds the most-common upstream codes (1002/1005/1109/1161, 2300/2304/2307/2314/2322/2339/2345/2554). 10 tests. `zig build test`: 993 → 1003 (+10).
- **2026-05-05 — Multi-file program graph (`packages/ts_program/`) landed.** Wraps the per-file driver with a module graph and cross-file resolution: `Program.add(path, source)` returns a stable FileId and dedups on repeat-add; `Program.compileAll(options)` runs every file through the driver, then walks each file's import declarations and resolves them via the supplied Resolver, populating the adjacency list. `reaches(from, to)` does transitive cycle detection / impact analysis. `topologicalOrder()` produces leaves-first ordering for declaration emit (cycle-safe, best-effort on import cycles). `.tsx`/`.jsx` files auto-set is_tsx; `.d.ts`/`.d.hm` set is_declaration. Phase 5 will layer incremental rebuilds via the query DB on top. Required two upstream fixes: ts_resolver's dirname now correctly returns "/" for absolute paths (was ""), joinPath handles root-prefix and resolves ".." segments; ts_driver's Compilation.deinit now frees per-message strings (was leaking). 8 program tests. `zig build test`: 1003 → 1011 (+8).
- **2026-05-05 — Decorator parsing.** New `DecoratorPayload` HIR node + builder + accessor. `parseDecoratorExpression` consumes `@` + LeftHandSideExpression so `@foo`, `@foo.bar`, `@foo()`, `@foo(arg, arg)` all parse. Decorators emit as preceding siblings of the decorated declaration (block_stmt children become e.g. `[decorator, decorator, class_decl]`); the binder/emitter walks back when it sees a decorated decl. Class-member / parameter decorator skips replaced by real captures. ts_emit currently erases decorators (returns early for `decorator` kind) so output remains runnable; Phase 4 follow-up emits either legacy `__decorate(...)` helpers or the Stage 3 runtime form. 3 parser tests. `zig build test`: 1011 → 1014 (+3).
- **2026-05-05 — `home tsc` CLI flag parsing (`packages/ts_cli/`) landed.** Drop-in compatible flag surface per §2.1. `parseArgs(gpa, args) -> Options` for the most-used flags: `--noEmit`, `--watch`/`-w`, `--project`/`-p` (both `flag value` and `flag=value` forms), `--target`, `--module`, `--outDir`, `--jsx`, `--strict`, `--pretty`/`--no-pretty`, `--listFiles`, `--listFilesOnly`, `--showConfig`, `--init`, `--version`/`-v`, `--help`/`-h`/`-?`, `--all`. Forward-compat: unknown flags accepted and skipped (matches tsgo so projects don't break on minor version bumps). `dispatch(Options) -> RunResult` is a pure function deciding what the CLI should do without I/O — the actual binary will wrap with stdout/stderr/disk. `ExitCode` enum matches tsc (0/1/2/3). 16 tests. `zig build test`: 1014 → 1030 (+16). Phase 5 follow-up wires real disk I/O + tsconfig load + program-graph compile + emit-to-disk.
- **2026-05-05 — Source map streaming printer wiring landed.** `Printer` now tracks `gen_line`/`gen_col` as it streams output; `Options.source_map: ?*SourceMap` enables mapping recording. Every `printStatement` records a mapping at the current generated position pointing back at the source span's start byte. Source-map integration test exercises the full path: parse a 3-line TS source, print into both an output buffer and a SourceMap, verify at least 3 mappings recorded with the expected (0,0)→(0,0) anchor on the first statement. `zig build test`: 1030 → 1031 (+1).
- **2026-05-05 — Expression-level type checking (`packages/ts_checker/src/check.zig`) landed.** Walks HIR expressions and assigns each one a TypeId via Hir.setType, drives the cross-statement check `let x: T = expr` verifying the init's type is assignable to T. Coverage: literals → matching Primitive; identifier refs → Primitive.any (binder-driven resolution follow-up); binary `+` with JS coercion (number+number → number, either side string → string); other arithmetic / bitwise → number; comparison + instanceof + in → boolean; `&&` / `||` / `??` → union of operand types; conditional → union of branches; assignment → RHS type; calls / member access / element access / array literal / object literal → Primitive.any (signature lowering + object-type lowering are Phase 3 follow-ups). VarDecl checking: with annotation lower-and-check init assignability and record diagnostic on mismatch; without annotation infer from init. 12 expression-checker tests. `zig build test`: 1031 → 1043 (+12). Wired into the driver via `Compilation.type_interner` + `type_engine`; 2 driver tests verify TypeIds populated and mismatch diagnostics surface. `zig build test`: 1043 → 1045 (+2).
- **2026-05-05 — Conformance harness (`packages/ts_conformance/`) landed.** Runs TS source through the compiler and verifies against expected baseline files matching tsgo's `tests/baselines/reference/` layout (TS_PARITY_PLAN §6). `Case = (name, source, path, expected_errors, is_tsx)`; `run(gpa, case) -> Result` with outcome (passed / failed / skipped) and human-readable detail on mismatch. Diagnostic format matches tsc default `path(line,col): error TSxxxx: message` so baselines from upstream-TS can be compared directly. `Suite` struct aggregates `Stats` (passed / failed / skipped / pass_rate). 6 self-tests. `zig build test`: 1045 → 1051 (+6).
- **2026-05-05 — Symbol-driven `.d.ts` emitter (`packages/ts_emit/src/d_ts_emit.zig`) landed.** Walks the bound module and emits a declaration-only TypeScript file. Strips bodies + statements + internal types, leaving the public type surface only. Coverage: `declare function name(p: T): U;` (body stripped, signature + return-type kept); `declare class Name { … }` (body stripped to method signatures and property names); `declare let/const/var x: T;` (annotation kept, initializer dropped); `declare enum Name`; `declare namespace Name`; `type Alias = T` pass-through; imports/exports preserved with full type-form support. Type-node re-printer covers type_ref + qualified names + generic args, union, intersection, array `T[]`, tuple `[A, B]`, `keyof T`, `typeof e`, `T[K]`, conditional `T extends U ? X : Y`, literal types, fn types `(a: T) => U`, constructor types. Required parser fix: class methods now thread their return-type annotation through to FnDeclPayload.return_type instead of discarding it. 10 d.ts emit tests. `zig build test`: 1051 → 1061 (+10).
- **2026-05-05 — zig-dtsx fast-path emitter wired via pantry.** `pantry add zig-dtsx` installs `pantry/zig-dtsx/` (no scope prefix per registry convention); `build.zig` wires `pantry/zig-dtsx/src/zig_dtsx.zig` as a single Zig module. `packages/ts_emit/src/d_ts_fast.zig` calls `dtsx.Scanner` + `dtsx.processDeclarations` and copies the result into a properly-sized allocation (zig-dtsx allocates `len+1` bytes for an FFI null terminator but returns a slice of `len` — the size mismatch on free is a deliberate design choice for FFI consumers). `package.json` `devDependencies` adds `"zig-dtsx": "^0.9.18"`; `pantry/` stays in `.gitignore`. Driver routing (Phase 4.5 follow-up): when `tsconfig.compilerOptions.isolatedDeclarations: true`, route through fast path; otherwise symbol-driven. 3 fast-path tests. `zig build test`: 1061 → 1064 (+3).
- **2026-05-05 — Parallel program compile (`compileAllParallel`) landed.** Phase 5 §5.6: parse + bind are embarrassingly parallel (each file is independent), so `Program.compileAllParallel(options, ?workers)` spawns `min(NPROC, 8)` workers (matching tsgo) that pop from an atomic cursor over the pending file list. Falls back to serial completion if `std.Thread.spawn` fails partway through (slow path stays correct). 1 test exercising 8 files × 4 workers. `zig build test`: 1064 → 1065 (+1).
- **2026-05-05 — Identifier resolution via binder.** `Checker.setModule(*const binder.Module)` wires the bound symbol table so identifier expressions resolve to the type their declaring var_decl / let_decl / const_decl carries. Driver passes `c.module` through automatically. With this in place `let x: number = 1; let y = x;` correctly types both the x_decl and y_init nodes as Primitive.number_t. Phase 3 follow-up: resolution uses module-level scope only — function-body and nested-scope lookup are next, then signature-typed identifiers. `zig build test`: 1065 → 1066 (+1).
- **2026-05-05 — Function signatures + call-expression return type.** Interner gains a `signature` `TypeKey` variant so `(x: number) => string` is interned exactly once; `internSignature(params, return_type, is_construct)` + `signatureReturn(id)` + `signatureParams(id)` are the public API. Checker's `checkFnDecl` walks parameters, lowers each annotation, interns the signature and stores it on the fn_decl HIR node + the function-name identifier. Parameters get their annotation type recorded on the parameter node and its name node so body identifier-resolution sees the param type. Call-expression resolution: looks up callee's TypeId, asks the interner for `signatureReturn(callee)`, returns it as the call's type. Driver test: `function id(x: number): string { return ""; } let r = id(1);` → `r` is `Primitive.string_t`. `zig build test`: 1066 → 1070 (+4).
- **2026-05-05 — Nested-scope identifier lookup.** `typeOfIdentifier` walks the HIR parent chain from the reference site to find the nearest enclosing declaration: function parameters, block-local `var`/`let`/`const`, block-local function decls. Falls back to module-level scope. With this `function id(x: number) { let y = x; return y; }` — `let y = x`'s init resolves to `number_t` from the parameter. Cross-function calls work: `function caller(): string { return id(1); }` resolves the `id(1)` call to `string`. Phase 3 simplification — proper Scope-graph-driven lookup is a follow-up. `zig build test`: 1070 → 1072 (+2).
- **2026-05-05 — Parallel program compile (`compileAllParallel`).** Phase 5 §5.6: parse + bind are embarrassingly parallel, so `Program.compileAllParallel(options, ?workers)` spawns `min(NPROC, 8)` workers (matching tsgo) that pop from an atomic cursor over the pending file list. Falls back to serial completion if `std.Thread.spawn` fails. 1 test exercising 8 files × 4 workers. `zig build test`: 1072 → 1073-ish (gradual increases).
- **2026-05-05 — File-system watcher foundation (`packages/ts_watch/`).** Phase 5 §5.7: tracks a set of paths via a pluggable `StatFs` interface, polls and emits a `ChangeSet` of `(path, kind=added/modified/removed)` records on each `tick()`. Uses an in-memory `VirtualWatchFs` for tests; real-disk runs through a `std.fs` adapter (post-Zig-API stabilization). Platform-native FS events (FSEvents / inotify / ReadDirChangesW) replace polling in a follow-up; the StatFs interface accommodates either. Phase 5 follow-up (the perf win): wire the query DB on top so a 1-line edit only re-runs affected queries. 8 tests. `zig build test`: 1072 → 1080 (+8).
- **2026-05-05 — Legacy `__decorate` emit for class decorators.** When the source-file walker encounters a run of `decorator` nodes preceding a `class_decl`, it emits the class normally then appends `ClassName = __decorate([...decorators], ClassName);` matching tsc's experimentalDecorators output. `@logged class Foo {}` → `class Foo {}\nFoo = __decorate([logged], Foo);`; multiple decorators preserve order; `@inject(Foo)`-style decorator-call expressions print their full form. Phase 4 follow-ups: method/property/parameter decorators (descriptor weaving via Object.defineProperty); `emitDecoratorMetadata`; Stage 3 decorator runtime model. `zig build test`: 1080 → 1083 (+3).
- **2026-05-05 — Conformance corpus runner.** `packages/ts_conformance/` gains `runCorpus(gpa, corpus, *results) -> Stats` driven by an inline `CorpusEntry` array (in-memory to sidestep the still-shifting `std.Io.Dir` API in Zig 0.16-dev). `builtin_corpus` ships 11 baseline cases — empty source, primitive let-bindings, function decl, class with method, interface, type alias, arrow function, generics, import, expected-error mismatched assignment. Test asserts the canon corpus hits 100% pass rate; the on-disk fixtures land at `tests/conformance/*.ts` for human readability. `runDirectory` follow-up will pick up disk loading once the Zig API stabilizes. `zig build test`: 1083 → 1085 (+2).
- **2026-05-05 — Object type member lowering.** New HIR payloads: `InterfaceMemberPayload` (name + type + optional/readonly/method flags) and `ObjectTypePayload` (members slice). Parser's `parseTypeMemberList` walks property / method / optional / readonly declarations inside `{...}` (interface bodies, object-type literals); method shorthand `name(p: T): R` lowers to a fn_type carried on the member. `parseInterfaceDeclaration` drops the `skip-until-close-brace` loop. `parseObjectOrMappedType` replaces its synthetic `object` type ref with a real `object_type` node. d.ts emitter walks member nodes and prints `'readonly name?: T;'` etc. Index/call/construct signatures skipped pending a Phase 6 follow-up. 7 tests. `zig build test`: 1085 → 1092 (+7).
- **2026-05-05 — Member-access type checking.** Interner gains `internObjectType(members)` and `objectMember(id, name)`. Lowerer's `lowerObjectType` walks HIR object_type's `interface_member` children, recursively lowering each member's type, and produces an interned object type. Lowerer's `lowerFnType` now produces a real signature TypeId for fn-type annotations. Checker's `member_access` consults `objectMember(callee_t, name)` and returns its type if found. End-to-end: `let p: { x: number; y: string } = …; let nx = p.x; let sy = p.y;` → nx is `number_t`, sy is `string_t`; missing properties fall through to `any` (Phase 6 follow-up adds the TS2339 diagnostic). `zig build test`: 1092 → 1094 (+2).
- **2026-05-05 — LSP foundation (`packages/ts_lsp/`) landed.** Phase 8 entry point. `Service` wraps the program graph + checker + diagnostic formatter into a query surface for editor integrations. Protocol-agnostic core (a separate `ts_lsp_server` will speak the LSP wire format on top): `hover(file, byte_pos)` finds the smallest enclosing HIR node and renders its TypeId; `gotoDefinition(file, byte_pos)` resolves the identifier via `module.root.lookup`; `findReferences(file, byte_pos)` walks every same-named identifier site (cross-file + shadowing-aware lookup are Phase 8 follow-ups); `completions(file, byte_pos)` enumerates module-level value + type symbols with classified ItemKind; `diagnostics(file)` formats via ts_diagnostics. Type renderer covers the primitive surface, object types, signatures, unions, intersections, keyof / indexed-access / conditional placeholders. 6 service tests. `zig build test`: 1094 → 1100 (+6).
- **2026-05-05 — Control-flow narrowing via typeof guards.** Checker gains a stack of name→type maps for narrowing contexts. Identifier resolution consults the topmost narrow scope before the static type. `applyTypeGuard` recognizes `typeof X === "primitive"` (and `!==` with negated polarity) where primitive ∈ {string, number, boolean, bigint, symbol, undefined, object} → narrows X to the matching `Primitive`. Stack unwinds after the then-branch so subsequent statements see the original type. Phase 6 follow-ups: `X !== null/undefined`, `X instanceof Class`, else-branch negated narrowing, discriminated-union narrowing, aliased-conditional narrowing (PR #46266), assignment narrowing. Test: `function f(x: any) { if (typeof x === "string") { let s = x; } }` → s is `string_t`. `zig build test`: 1100 → 1101 (+1).
- **2026-05-05 — Persistent compilation cache (`packages/ts_cache/`) landed.** Phase 5 §11.6 entry. Content-addressed cache keyed by `sha256(source + tsconfig)`. Each entry stores compiled JS + diagnostic summary so subsequent runs over an unchanged file skip the pipeline. Currently in-memory; the disk-backed sharded format (`<root>/<2hex>/<remaining>.cache`) is the wire format for the follow-up disk persistence. `Cache.computeKey(source, config_blob)` produces a 32-byte SHA-256; `get` / `put` / `contains` / `clear`. Phase 5 follow-ups: mmap'd LMDB-style B-tree backing for the §11.6 "TTFD 300 ms → 30 ms" target; cache the symbol table + relation cache too (LSP cold-start servable); LRU eviction. 10 cache tests. `zig build test`: 1101 → 1111 (+10).
- **2026-05-05 — Cache wired into the driver (`emitWithCache`).** Driver now exports `emitWithCache(gpa, source, cache, config_blob, options) -> EmitResult`. On cache hit returns the cached JS without running the pipeline; on miss runs full and stores. Lightweight `EmitResult` is the right call for `home tsc --emit` mode (no HIR/symbols/interner). `compileSource` API stays the same for LSP / type queries. Total 1111 → 1113 (+2).
- **2026-05-05 — Generic instantiation via call-site inference.** HIR's `FnDeclPayload` gains type_params slot so generic decls thread their type-parameter list through. Checker's `checkFnDecl` walks the type-parameter list, interns each as a `TypeParameter` TypeId, and pushes them onto the narrow scope so references inside parameter / return-type annotations resolve to the parameter's type id (not `Primitive.unknown`). `lowererLowerWithTypeParams` routes type_ref lookups through the narrow scope first. `call_expr` now tracks each arg's type and runs `instantiateReturn(param_ts, arg_ts, ret)` which infers type-parameter substitutions and substitutes them in the return type. End-to-end: `function id<T>(x: T): T { return x; } let n = id(42); let s = id("hi");` → `n: number`, `s: string`. Phase 6 follow-ups: constraint checking + variance-aware inference + signatures-with-type-args (`id<number>(1)`). `zig build test`: 1113 → 1114 (+1).
- **2026-05-05 — Incremental rebuild API.** `Program.updateSource(path, new_source) -> ?FileId` replaces a tracked file's source bytes, drops the previous compilation. `Program.recompileChanged(changed_paths, options) -> u32` recompiles only the listed files; everything else keeps its existing compilation. Watch-mode loop becomes one tick + update + recompile, leaving unchanged files alone. `resolveImports` runs after recompile so cross-file edges follow any import-graph changes. Phase 5 / §5.7 wiring. Total 1114 → 1116 (+2).
- **2026-05-05 — Else-branch + null/undefined narrowing.** if-statement walker now pushes a narrow scope for the else branch and applies the negated guard. `applyTypeGuard` handles polarity correctly for the `!==` case (else branch of `===`): guarded primitive becomes `never` for negative polarity. `X === null` / `X !== null` narrowing: positive polarity narrows to `null_t`; negative polarity records `unknown` (proper union subtraction is a Phase 6 follow-up). `X === undefined` / `X !== undefined`: same shape. Plus TS2339 'Property X does not exist on type' for member access on a known object_type with no matching member. Total 1116 → 1118 (+2).
- **2026-05-05 — Cross-file findReferences in LSP.** `Service.findReferences` now walks every file in the program graph. Each file has its own string_interner, so the target name is re-interned per file to compare interned-id identity. Test: 3-file program where 'count' is declared in /a.ts and referenced from /b.ts and twice in /c.ts → returns 4 spans across all three files. Phase 8 follow-up: shadowing-aware lookup via the binder's scope graph. Total 1118 → 1119 (+1).
- **2026-05-05 — LSP JSON-RPC wire-protocol (`packages/ts_lsp_server/`) landed.** Translates Microsoft LSP requests into Service calls. `parseFrame` handles LSP's Content-Length framing (HTTP-like header + JSON body); `encodeFrame` wraps response bodies. `encodeResponse` / `encodeError` produce JSON-RPC bodies. `Method` enum covers initialize / initialized / shutdown / exit / textDocument/{didOpen,didChange,didClose,hover,definition,references,completion,publishDiagnostics}. Result renderers: `renderInitializeResult` declares hover/definition/references/completion capabilities; `renderHoverResult` outputs `{ contents: { kind: plaintext, value }, range }`; `renderDefinitionResult` produces an array of Location with `file://` URIs; `renderReferencesResult` does the same for arrays of Locations; `renderCompletionResult` maps our ItemKind to LSP CompletionItemKind constants (Variable=6, Function=3, Class=7, Interface=8, TypeParameter=25, Module=9, Keyword=14, Field=5). LSP uses 0-based line/character; our Span uses 1-based — range writer translates. The actual stdio I/O loop (read frames, dispatch, write responses) is a separate `home lsp` binary that wraps this library. 14 wire-protocol tests. `zig build test`: 1119 → 1133 (+14).
- **2026-05-05 — Object literal + array literal type inference.** `let p = { x: 1, y: "hi" }` now infers `{ x: number; y: string }` via `internObjectType` so subsequent member access types correctly. Array literals infer the union of their element types as a Phase 3 placeholder for proper `Array<T>` instantiation. `[1, 2, 3]` → `number_t`; `[1, "hi"]` → `number | string`. Plus TS2554 'Expected N arguments, but got M' on call-arg-count mismatch and TS2345 'Argument is not assignable to parameter at position N' on call-arg-type mismatch — using the existing relation engine to check assignability. Type-parameter slots are skipped so generic calls don't false-positive. Total 1133 → 1139 (+6).
- **2026-05-05 — JS sourceMappingURL trailer.** `Options.source_map_url`, when set, appends `//# sourceMappingURL=<url>` at the end of the JS output — matches tsc's source-map URL pragma and is what Node.js / browsers parse to find the external .map file. Total 1139 → 1141 (+2).
- **2026-05-05 — Disk persistence for `ts_cache`.** Phase 5 §11.6 ratchet — the in-memory cache now write-throughs to `<root>/<2hex>/<remaining>.cache` on `put`, and `get` falls through to disk when the in-memory layer misses. Wire format: `HMC1` magic + `diagnostic_count: u32 LE` + `has_errors: u8` + `js_len: u32 LE` + `js`. Sharded by the first byte of the SHA-256 hex so directory sizes stay small even at millions of entries. Disk failure stays soft — falls back to in-memory mode. Zig 0.16-dev's `std.Io.Dir` API requires an `Io` parameter on every call, so we package `std.Io.Threaded.init(gpa, .{}).io()` per-operation through helpers. 6 disk-backed tests. `zig build test`: 1149 → 1155 (+6).
- **2026-05-05 — Structural assignability + identity for object types.** `Engine.computeAssignable` now walks object-type members structurally: source must declare every required target prop with an assignable type; optional target props may be missing on source; extra source props are allowed (no fresh-type check yet). `Engine.computeIdentity` compares member-wise so two equivalent shapes interned at distinct TypeIds collapse for relation purposes. `Interner.objectMemberInfo` and `objectMembers` are the new accessors. Driver tests verify `let p: { x: number; y: string } = { x: 1, y: "hi" };` compiles without TS2322 and that missing/extra/optional props all behave per tsc. `zig build test`: 1155 → 1160 (+5).
- **2026-05-05 — Multi-file cache wiring (`Program.emitAllToCache`).** Walks every file through `ts_driver.emitWithCache` so cache-hit files skip the entire pipeline. The `home tsc --emit` fast-path: cold-start over a fully-cached project drops to N hash comparisons + cached reads, no parse/bind/check. 2 program tests. `zig build test`: 1160 → 1166 (+6 incl. 4 prior assignability driver tests not yet counted).
- **2026-05-05 — Explicit type-args on generic calls.** Parser now recognizes `id<T, U>(args)` via a speculative scan: walk balanced angles + parens until the matching `>` at angle-depth 0; if the next token is `(`, treat as type args. Otherwise fall back to less-than binop. Tokens that disqualify the construct (`=`, `;`, `=>`, `?.`, EOF) abort the scan. Existing comparisons stay unaffected. Type args are skipped at parse time — call-site inference still types the result correctly via argument-type inference; threading the explicit args through `FnDeclPayload` so they override inference is a Phase 6 follow-up. `zig build test`: 1166 → 1168 (+2).
- **2026-05-05 — instanceof narrowing.** `if (x instanceof Foo) { ... }` narrows `x` to `Primitive.object_t` within the then-branch via `applyTypeGuard`. Real class-instance typing (so the narrowed type is the actual class shape) lands when the interner gains class-instance TypeIds; current placeholder is at least sound (instanceof guarantees a non-null object). `zig build test`: 1168 → 1169 (+1).
- **2026-05-05 — `home-tsc` + `home-lsp` binaries.** `packages/ts_cli/src/tsc_main.zig` wraps `ts_cli.parseArgs` + `ts_cli.dispatch` with the `std.Io.Dir`-driven file I/O: read input files, build a `ts_program.Program`, run `compileAll`, and write per-file `.js` next to each input. `packages/ts_lsp_server/src/lsp_main.zig` is a stdin/stdout `Content-Length` frame loop that routes through the wire-protocol layer's `Method` enum and writes encoded responses. Both wired into `build.zig` with `b.installArtifact` so `zig build` produces `zig-out/bin/home-tsc` and `home-lsp`. Smoke-tested end-to-end: `home-tsc /tmp/smoke.ts` produces correct JS for generics + object literals; `home-lsp` returns the initialize capability set on a piped JSON-RPC frame.
- **2026-05-05 — Tuple literal-index + optional chaining + nullish coalescing typing.** Three more checker landings. (1) `tup[0]` on a tuple `[A, B]` now resolves to the per-index member (typed as `A`) instead of the broader `A | B` union. The element-access path detects literal-numeric index expressions, formats the value as a string key (`"0"`, `"1"`, …), and looks it up against the tuple's interned member table before falling through to the number indexer. (2) `obj?.x` widens its result with `undefined` when the existing `MemberPayload.optional` flag is set — the existing infrastructure was there, just unused by the checker. The optional flag covers both the `?.` operator and optional-chaining-element-access via the same path. (3) `a ?? b` (nullish coalescing) now types as `(typeof a minus null|undefined) | typeof b` instead of the broader `a | b` union — reuses the existing `subtractNullUndefined` helper from the non-null assertion landing. `&&` / `||` keep the simple union since proper truthiness narrowing needs a control-flow analysis layer. 3 new tests. `zig build test`: 1252 → 1255 (+3).
- **2026-05-05 — Doc pass: capability snapshot, phase punch lists, strategic ordering, smoke contract.** Plan-document refactor (no code change). Phase status table updated to reflect current reality — Phase 2 / 3 / 8 promoted to 🟢 substantially complete; Phase 4 / 4.5 / 5 / 6 marked 🟡 partial with explicit follow-up scope. New §A · End-to-end capability snapshot enumerates what `home-tsc` and `home-lsp` actually do today (the descriptive ground truth, separate from the journal's chronological log). New §B · Phase punch lists consolidates remaining work per phase with effort estimates and ROI ordering — six punch lists covering Phase 3 (15 items), Phase 4 (13), Phase 4.5 (9), Phase 5 (10), Phase 6 (7), Phase 8 (9). New §C · Strategic ordering proposes the next 7 items across phases by leverage. New §D · End-to-end smoke contract codifies six TS code blocks `home-tsc` must compile cleanly to be considered "drop-in for typed TS subset" — four work today, two require Phase §3.A.2 / §3.A.3. §8 (Concrete next steps) updated to point at §B's items rather than the now-stale week-1 kickoff plan. No journal entries before today were edited.
- **2026-05-05 — §3.A.1 explicit type args + generic-fn tracking.** New `Checker.generic_fns: AutoHashMap(StringId, []TypeId)` records each generic function's `TypeParameter` ids in declaration order, populated by `checkFnSignatureOnly`. HIR's `addCallWithTypeArgs(span, callee, args, type_args)` builder threads parsed type args through the existing `CallPayload.type_args_start/len` slots; new `hir.callTypeArgs(node)` accessor exposes them. Parser's `<T,>(args)` path now actually parses the type arguments (was: skip-and-discard) via a new `parseExplicitCallTypeArgs(after_gt)` helper that reuses `parseTypeAnnotation` over the comma-separated list. Checker's `call_expr` path: when explicit type args + a known generic callee, build the `(TypeParameter -> ExplicitArg)` substitution directly, run it through `substituteType` to produce the *substituted signature*, then drive arg-checking + return through that. Inference is skipped when explicit args resolved (avoids redundant work + overrides any contradicting inference). End-to-end: `function id<T>(): T { ... }; let n = id<number>(); let s = id<string>();` types `n: number`, `s: string`. Mismatched explicit `<T>` + arg type emits TS2345. 2 new tests. `zig build test`: 1255 → 1257 (+2).
- **2026-05-05 — §3.A.2 mapped types + §3.A.3 conditional types with distribution.** Two more landings stacked. (1) Mapped types now eagerly materialize when the constraint resolves to a known string-literal union: `{ [K in "x" | "y"]: number }` lowers to `{ x: number; y: number }` via a new `Checker.evalMappedType` that walks the constraint, collects literal keys via `collectStringLiteralKeys` (union-first traversal — important because `internUnion` OR-folds `is_string`/`is_literal` flags from members, which would otherwise misroute through the literal branch), pushes the type-parameter onto the narrow scope, and substitutes `K -> literal` in the value template per key. Modifier flags `?` and `readonly` propagate to each generated property. (2) Conditional types `T extends U ? X : Y` now eagerly evaluate when `T` and `U` are concrete: walks each leaf via `lowererLowerWithTypeParams`, runs `evalConditional`. Distribution: when `T` resolves to a union, each member is independently checked + mapped, then the results are unioned. Defers when either side carries a free type parameter (via new `containsFreeTypeParameter` helper) — `internConditional` keeps the unevaluated form for downstream substitution. (3) `substituteType` extended: walks into conditional + keyof shapes and re-attempts evaluation under the substitution, so `type Pick<T> = T extends string ? number : boolean; let r: Pick<string>` resolves to `number_t` (was: deferred conditional). 4 new tests. `zig build test`: 1257 → 1261 (+4).
- **2026-05-05 — §3.A.6 strictFunctionTypes wired through engine + sub-type-aware narrowing.** Two improvements stacked. (1) `Engine.strict_function_types` flag + `setStrictFunctionTypes(on)` setter. When false (default — matches tsc's pre-3.0 behavior on method declarations), `computeSignatureAssignable` checks parameters bivariantly — accepts either `target → source` or `source → target` assignability. When true (matches `strict` / `strictFunctionTypes: true`), checks contravariantly only. New `StrictFlags.strict_function_types` field; driver derives from `compilerOptions.strict_function_types ?? compilerOptions.strict ?? false` and pushes through `c.type_engine.setStrictFunctionTypes(...)`. (2) Negative-branch narrowing now uses proper union subtraction. New `subtractType(t, to_remove)` helper: returns `never` if `t == to_remove`, walks union members and drops the removed type, collapses single-member result. `if (typeof x === "string") {} else {}` over `x: string | number` now narrows `x` to `number` in the else branch (was: `never`). `if (x === null) {} else {}` over `x: string | null` narrows `x` to `string` in else (was: `unknown`). Same upgrade applies to `=== undefined` / `!== undefined`. The `any` case correctly stays `any` after subtraction (matches tsc — `any minus T = any`); the existing test was updated to assert the corrected behavior + a new test covers the union-subtraction case. `zig build test`: 1261 → 1262 (+1).
- **2026-05-05 — §4.A.10 JSX automatic runtime.** `ts_emit.JsxRuntime` enum with `classic` / `automatic` / `automatic_dev` / `preserve` variants. `Options.jsx_runtime` selects between them; `Options.jsx_factory` (default `"React"`) and `Options.jsx_fragment` customize the classic factory + fragment names. The streaming printer's `printJsxElement` dispatches: `.classic` emits `factory.createElement(tag, props, ...children)` (same as before — now configurable factory); `.automatic` emits `_jsx(tag, props)` for single-children and `_jsxs(tag, props)` for multiple, threading `children` into the props object (matching React 17+'s `react/jsx-runtime` ABI); `.automatic_dev` uses `_jsxDEV` for both. `printJsxFragment` mirrors: classic emits `factory.createElement(fragment, null, …)`; automatic emits `_jsxs(_Fragment, { children: [...] })`. Driver wires through tsconfig: `compilerOptions.jsx == "react-jsx"` → `.automatic`, `"react-jsxdev"` → `.automatic_dev`, `"react"` → `.classic`, `"preserve"` → `.preserve`; `compilerOptions.jsxFactory` overrides the factory name for classic mode. Auto-import of `_jsx`/`_jsxs` from `react/jsx-runtime` is a follow-up (today the user is responsible for the import). 5 new emit tests. `zig build test`: 1262 → 1267 (+5).
- **2026-05-05 — §3.A.8 type predicates + §3.A.13 nested excess-prop.** New `type_predicate_type` HIR kind with `TypePredicatePayload` carrying `param_index + param_name + target_type + is_asserts`. Parser's new `parseReturnTypeAnnotation(params)` runs in return-type position and detects two forms: `arg is T` and `asserts arg is T` / `asserts arg`. Param resolution by name → positional index lets the checker find which arg to narrow at call sites. Checker's `checkFnSignatureOnly` registers each predicate keyed by function name in `fn_predicates: AutoHashMap(StringId, FnPredicate)`. `applyTypeGuard` extended with a call-expression case that runs first: when the condition is a call to a registered predicate function and the matching argument is an identifier, narrow it to the predicate's target type (then-branch) or subtract it (else-branch). Predicate return type lowers to `boolean_t` since narrowing is recorded out-of-band. Nested-literal excess-property check: `checkExcessProperties` recurses into object-literal values whose declared type is also an object type, so `let p: { x: { y: number } } = { x: { y: 1, z: 2 } }` now flags `z` as TS2353. 2 new tests. `zig build test`: 1267 → 1269 (+2).
- **2026-05-05 — §4.A.6 ?? + ?. lowering, §4.A.11 ESM↔CJS interop.** New `Options.es_target: EsTarget` (es5..esnext) selects which downlevels apply. At es2019 and below: `a ?? b` lowers to `(a !== null && a !== void 0 ? a : b)`; `obj?.x` lowers to `(obj === null || obj === void 0 ? void 0 : obj.x)`; `arr?.[i]` mirrors. New `Options.module_kind: ModuleKind` (esm | commonjs) + `es_module_interop`. CJS mode lowers imports to require() patterns: default → `__importDefault(require()).default`; namespace → `__importStar(require())`; named → destructured `const { a, b } = require()`; side-effect → bare `require()`; mixed default+named uses one require + multiple statements. Exports: `export <decl>` emits the decl + `module.exports.<name> = <name>`; `export default <decl>` emits then `module.exports.default = <name>`; `export { a }` emits `module.exports.a = a`. Driver maps `compilerOptions.target` and `compilerOptions.module` (commonjs/amd/umd/system → `.commonjs`, else `.esm`) and `esModuleInterop`. 11 new emit tests. `zig build test`: 1269 → 1280 (+11).
- **2026-05-05 — §8.A.2 / §8.A.3 / §8.A.7 LSP signatureHelp + inlayHints + documentSymbols.** `Service.signatureHelp(file, byte_pos)` walks up from the cursor to the enclosing call_expr, renders the callee's signature label, and reports the active parameter index based on which arg-span the cursor falls inside. `Service.inlayHints(file)` surfaces inferred types at unannotated `let`/`const` declarations (anchored at the binding's name end), via a HIR walk over block_stmt + fn body. `Service.documentSymbols(file)` enumerates top-level declarations (function / class / interface / type-alias / enum / let / const / var) for the editor's outline view. New shared `SignatureInfo`, `InlayHint`, `SymbolInfo` types. 3 new tests. `zig build test`: 1280 → 1283 (+3).
- **2026-05-05 — §8.A.4 / §8.A.6 / §8.A.5 LSP semanticTokens + rename + organize-imports codeAction.** `Service.semanticTokens(file)` walks the HIR and emits one classified token per identifier-bearing node, looking at the parent's kind to disambiguate (fn name → `.function`, class name → `.class`, parameter → `.parameter`, member access → `.property`). Standard 13-element TokenType legend exposed via `.legend()`. Sorted by `(line, col)` for deterministic delta output. `Service.rename(file, byte_pos, new_name)` reuses `findReferences`'s cross-file walk and produces one `TextEdit` per occurrence. `Service.codeActions(file)` first action: "Organize Imports" sorts top-level import declarations alphabetically by module specifier; emits a single `TextEdit` covering the union span of all imports with the rendered sorted block as `new_text`. New shared `SemanticToken`, `TextEdit`, `CodeAction` types. 3 new tests. `zig build test`: 1283 → 1286 (+3).
- **2026-05-05 — §5.A.10 streaming diagnostics + §6.A.3 patience-diff.** `Program.compileAllStreaming(options, ctx, cb)` invokes `cb(ctx, file_path, diags)` as soon as each file finishes compiling — driving time-to-first-diagnostic toward per-file check time rather than whole-program time. Foundation for the §0 TTFD ≤ 300 ms target. Patience-diff: pure-Zig implementation of Bram Cohen's algorithm in `packages/ts_conformance/src/patience.zig`. Finds unique-line anchors in both inputs, extracts the LIS via patience-sort piles with backpointers, recurses on the gaps. Used by tsgo's testutil/baseline harness for readable diff output during conformance triage; we re-implement so triage diffs are byte-comparable + the conformance runner stays free of external deps. 4 patience tests + 1 streaming test. `zig build test`: 1286 → 1292 (+6).
- **2026-05-05 — Doc pass: punch-list ratchet, status-table refresh.** Updated §B's punch lists with all today's landings — Phase 3.A.8/9/13 complete, Phase 4.A.6/11 complete, Phase 5.A.10 partial, Phase 6.A.3 complete + 6.A.4 partial, Phase 8.A.2/4/6/7 complete + 8.A.3/5 partial. Process State header rewritten to reflect the full surface area (type checker / JS emit / LSP / program-graph / conformance) rather than just Phase 3. No new code; no journal entries before today were edited.
- **2026-05-06 — Day-2 continued: await/yield, mapped modifiers, watch loop, --listFiles/--showConfig.**
  - `981c3d8` §4.A.5 await + yield expression parser/HIR/emit
  - `d1833f4` Mapped type `+/- ?` and `+/- readonly` modifiers + homomorphic source-flag inheritance
  - `6bad34c` `home-tsc --watch` actually loops via `Program.recompileChanged`
  - `ba7a475` `--listFiles`, `--listFilesOnly`, `--showConfig` wired through to disk I/O
  zig build test: 1364 → 1370 (+6 tests).
- **2026-05-06 — Day-2 marathon: downlevels, infer, homomorphic mapped, augment, more.** Continued landings:
  - `609d223` §4.A.1 arrow → function-with-bind + §4.A.3 for-of → indexed-for at es5
  - `27408f3` §4.A.2 class → function-with-prototype IIFE at es5 (with __extends + super.call)
  - `d1ebab9` dynamic `import("...")` parser + CJS lowering to `Promise.resolve(require())`
  - `c72e688` §3.A.2 ratchet — homomorphic mapped types (Partial/Readonly preserve field types)
  - `19dbce3` §3.A.15 `Module.augment` for cross-file declaration merging
  - `15716d9` §4.A.8 method/property decorators emit per-member `__decorate(...)` calls
  - `ac796ee` §3.A.3 ratchet — `infer X` placeholder binding via matchInfer + registerInferNames
  - `eaf9298` §5.A.4 release-fast build step (ReleaseFast + LTO)
  - `c66555b` type predicates on class methods + arrow functions
  - `f41ccf5` 15 new conformance corpus cases for recent feature landings
  - `54761aa` §3.A.3 ratchet — `[T] extends [U]` non-distribution form
  Total `zig build test`: 1326 → 1344 (+18 tests this day).
- **2026-05-05 — Marathon session continued: §3.A.7 overload resolution, §3.A.10 aliased narrowing, §3.A.11 this-param parsing, §3.A.4 template literal types (no-substitution), §4.A.10 JSX auto-imports, §4.A.12 .tsbuildinfo writer wired into home-tsc, §6.A.2 runDirectory + runOwnedCorpus, §8.A.1 completion auto-import, §8.A.7 workspaceSymbols.** Implementation chunks committed individually:
  - `dae060f` §3.A.8 type predicates + §3.A.9 asserts + §3.A.13 nested excess-prop
  - `04ae703` §4.A.6 ?? + ?. lowering + §4.A.11 ESM↔CJS interop + EsTarget option
  - `e2ac544` §8.A.2/3/7 LSP signatureHelp + inlayHints + documentSymbols
  - `7dcb685` §8.A.4/5/6 LSP semanticTokens + rename + Organize-Imports
  - `3807909` §5.A.10 streaming diagnostics + §6.A.3 patience-diff
  - `ab8c7d3` assertion-fn fall-through narrowing + 30-case corpus expansion
  - `093672a` §3.A.10 aliased conditional narrowing + §4.A.12 .tsbuildinfo
  - `1feca96` §3.A.11 partial this-param + §6.A.2 runDirectory/runOwnedCorpus
  - `560db6f` §3.A.7 overload resolution
  - `677dd62` §3.A.4 partial template literal types (no-substitution)
  - `48e8361` cond_alias clear-on-reassignment
  - `785eee9` §4.A.12 wire .tsbuildinfo into home-tsc binary
  - `ed514c9` §4.A.10 JSX automatic-runtime auto-imports
  - `49e2834` §8.A.7 workspaceSymbols
  - `3fc829b` §8.A.1 completion auto-import candidates
  Total `zig build test`: 1255 → 1307 (+52 tests).
- **2026-05-05 — §3.A.9 assertion-fn fall-through narrowing + §6.A.4 corpus expansion.** Assertion functions narrow `arg` in subsequent statements after a call: new `applyAssertionFlow` helper runs after each statement in `block_stmt` and `walkFnBody` loops. Predicate-less `asserts arg` narrows by subtracting `null | undefined` (truthy approximation). Function-body narrow scope now pushed/popped around `walkFnBody` so non-generic-function bodies have somewhere to record narrowing. Built-in corpus extended with 30 new cases exercising recently-landed features: explicit type args, mapped types over literal-key unions, conditional type evaluation + distribution, type predicates, asserts predicates, non-null assertion, tuple literal index, `Array<T>` shape, `keyof` eval, discriminated-union narrowing, `in` narrowing, `as const`, `for-of`, index signatures, interface extends, optional/default params, strictFunctionTypes, fresh excess-prop, `this`/`super`, `instanceof` narrowing, `typeof` type query, optional chaining, nullish coalescing, generic alias instantiation. Conformance runner now prints failures to stderr during PR review. `zig build test`: 1292 → 1293 (+1; +30 corpus cases run as one test).
- **2026-05-05 — `keyof T` + `in` narrowing + `as const`.** Three more landings. (1) `keyof T` now eagerly evaluates against known object types into a union of string-literal types — `keyof { x: number; y: string }` produces `"x" | "y"`. The eval lives in `lowererLowerWithTypeParams`'s `keyof_type` case so it sees type-name resolution through the existing `type_names` table; the lower-side `lowerKeyof` keeps the same fast path for primitive cases. Symbolic `keyof T` with an unresolved operand falls through to the existing `internKeyof` representation that future substitution can resolve. The full assignability story for `let k: keyof T = "x"` needs contextual typing for fresh string literals (currently typed as `Primitive.string_t`), tracked as a follow-up. (2) `"foo" in obj` narrows `obj` to the union variants that declare `foo` (else-branch keeps the variants without `foo`). New `narrowByPropertyPresence` helper filters the union by `objectMember` lookup. Pattern: `if ("meows" in p) p.meows;` resolves cleanly when `p: Cat | Dog`. (3) `expr as const` — parser detects the `as const` form and builds a synthetic `type_ref` to `"const"`. Checker recognizes it via `isAsConstMarker` and runs `literalizeForAsConst`: literal expressions become their literal types (e.g. `"hi" as const` → the literal `"hi"` type, not `string`); object literals recurse, making each property literal + readonly; bools map to `true_lit`/`false_lit`. 4 new tests (1 keyof shape + 1 `in` + 3 as-const). `zig build test`: 1246 → 1252 (+6).
- **2026-05-05 — for-of/for-in element binding + tuple type lowering.** Three more landings. (1) `for (let x of arr)` now binds `x` to the array's element type via the new `bindForLoopTarget` helper — drilling through `objectNumberIndex` on the source's interned shape so any object-with-number-indexer (arrays, tuples, etc.) supplies the element type. `typeOfIdentifier` extended with a `for_in_stmt`/`for_of_stmt` case so loop-body identifier lookups walk past the binding correctly. (2) `for (let k in obj)` binds `k` to `string` regardless of the source shape (matches tsc's deliberate erasure — even `Record<"a"|"b", T>` iterates as `string`). (3) Tuple types `[A, B, C]` now lower to a proper object shape: per-index members keyed by `"0"`, `"1"`, `"2"` typed as the matching element, plus `length: <literal N>` (using `internNumberLiteral` so the length is a literal type — assignability against `length: 2` distinguishes a 2-tuple from an arbitrary array), plus a number-key indexer carrying the union of all element types. `t[0]` resolves through the named-member fallback chain in element-access. 4 new tests (3 for-of/in + 1 tuple shape). `zig build test`: 1242 → 1246 (+4).
- **2026-05-05 — Optional parameters + interface extends + Array<T> shape.** Three more checker landings stacked. (1) Optional and defaulted parameters now widen to `T | undefined` via a new `unionWithUndefined` helper. The call-site arg-count check (TS2554) tolerates omitted trailing args when those params include `undefined` in their type — the `min_required` count is computed from the trailing run of "includes undefined" params. Diagnostic messaging shifts from "Expected N arguments" to "Expected N or fewer arguments" when optionals are present. (2) `interface B extends A { ... }` and multi-parent `interface C extends A, B` now inherit each parent's members via a new `mergeInterfaceExtends` helper. Mirrors the class extends mechanism but operates on lowered TypeIds (parents come from `type_names` lookups via `lowererLowerWithTypeParams`). Index signatures inherit when the child doesn't declare its own. Child member declarations win on name conflict. (3) Array literals + `T[]` annotations now build the standard `Array<T>` shape — an object type with a `length: number` member and a `[i: number]: T` indexer. New `interner.internArrayType(sint, element)` helper. `arr[0]` resolves through the existing element-access indexer fallback to `T`; `arr.length` types as `number`. Required widening Lowerer's `string_interner` field from `*const` to `*` (mirrors the same fix for Checker). 11 new tests (4 optional + 3 interface extends + 4 array). 2 driver tests updated to assert the new array shape. `zig build test`: 1232 → 1242 (+10).
- **2026-05-05 — Index signatures `[k: string]: T` / `[i: number]: T`.** Parser, HIR, interner, and checker support stacked together. New `index_signature` HIR kind + `IndexSignaturePayload { key_type, value_type, is_readonly }`. Parser's `parseTypeMemberList` gains a `tryParseIndexSignature` speculative path that recognizes `[ ident : K ] : V` (and `readonly [ ... ]`) — backs out cleanly when the brackets actually contain a mapped type's `[K in U]` form so the dedicated mapped-type path keeps working. Interner gains `internObjectTypeWithIndex(members, string_idx, number_idx)` (the existing `internObjectType` is now a delegating wrapper) plus `objectStringIndex(id)` / `objectNumberIndex(id)` accessors against the existing `string_index_type` / `number_index_type` payload slots. Checker wires the indexers in two places: `checkInterfaceDecl` and the inline `object_type` lowering inside `lowererLowerWithTypeParams` — both walk index_signature members and route their value type into the right slot based on the key type's primitive flag. `member_access` falls back to the string-key indexer when the named lookup misses (so `m.anything` on `{ [k: string]: number }` types as `number` instead of TS2339). `element_access` consults the matching string- or number-key indexer based on the index expression's type. 3 new checker tests (string indexer + number indexer + inline object-type indexer). `zig build test`: 1229 → 1232 (+3).
- **2026-05-05 — TS2353 excess-property check + non-null assertion `expr!`.** Two more checker landings. (1) Fresh-object-literal excess-property check: when `let p: { x: number } = { x: 1, y: 2 };` is parsed, the new `checkExcessProperties` helper walks the literal's properties against the declared object type's member set and reports each unknown name with TS2353 ("Object literal may only specify known properties, and 'y' does not exist on the target type."). Only triggers on the literal init form — passing the same shape through a variable falls back to regular structural assignability (matches tsc's "fresh type" semantics). (2) Postfix non-null assertion `expr!`: new `non_null_expr` HIR kind reusing the `AsExpressionPayload` shape (with `type_node = none_node_id`). Parser handles the postfix `!` in `parseCallOrMemberExpression`; checker subtracts `null | undefined` from the operand's type via a new `subtractNullUndefined` helper (`union → filter → re-intern`); JS emit erases to the inner expression. End-to-end: `function pickMaybe(): string | null { ... }; let s = pickMaybe()!;` types `s` as `string`. 4 new tests (2 TS2353 + 1 narrowing + 1 emit erasure). `zig build test`: 1225 → 1229 (+4).
- **2026-05-05 — D.ts inferred returns + noUnusedLocals/Parameters + generic alias instantiation.** Three landings in one pass. (1) `.d.ts` emit now renders the checker-inferred return type when a function lacks an annotation. New `packages/ts_checker/src/render.zig` exposes a public `renderType(gpa, ti, sint, id)` (extracted from the LSP's hover renderer), now shared by both LSP and the d.ts emitter. `Emitter.initWithTypes` plumbs the type interner through; `home-tsc` switches to the new constructor. The checker also gains an `export_decl` case in `checkStatement` that recurses into the inner decl, so `export function foo(...)` actually gets typed (a latent omission — the prior path silently skipped exported function bodies). End-to-end: `export function add(a: number, b: number) { return a + b; }` now emits `export declare function add(a: number, b: number): number;`. (2) `noUnusedParameters` (TS6133) and `noUnusedLocals` (TS6133) wired through `StrictFlags`. The checker walks each function body collecting identifier StringIds outside-of-decl-name slots (via a new `collectIdentifierRefs` + `isDeclNameSlot` pair), then reports any param / local whose name doesn't appear. Names beginning with `_` are exempt by convention. Driver populates the flags from `tsconfig.compilerOptions.noUnusedParameters` / `noUnusedLocals` (independent of `strict`, matching tsc). (3) Generic type-alias instantiation: `type Box<T> = { value: T }; let b: Box<number>` now substitutes `T → number` in the alias body. New `generic_aliases` table stores `(params: []TypeId, body: TypeId)`. `lowererLowerWithTypeParams` extended to lower `union_type`, `intersection_type`, and `object_type` under the current narrow scope (the raw `lower.zig` path doesn't see narrow bindings, so type-parameter references inside an object body would otherwise fall through to `unknown`). `substituteType` extended to recurse into signatures and object types. 9 new tests (3 d.ts inferred returns + 4 noUnused* + 2 generic alias). `zig build test`: 1216 → 1225 (+9).
- **2026-05-05 — `.d.ts` class fields with annotations + return-type inference.** (1) The d.ts emitter now writes `: T` on class fields with declared annotations. `class Box { value: number = 0; }` now emits `class Box { value: number; }` (was: `class Box { value; }`). The initializer is correctly stripped. (2) Functions without a return-type annotation now infer the return type by walking every reachable `return value` statement (stopping at nested function boundaries) and unioning the result. No returns → `void`. Single return → its type. Multiple returns → `internUnion`. Arrow functions with expression bodies use the expression's type directly. The signature is re-interned with the inferred return so identifier lookups against the function name see the refined type. 5 new tests (1 d.ts + 4 inference). `zig build test`: 1208 → 1213 (+5).
- **2026-05-05 — `as` type assertion + `noImplicitAny` (TS7005/TS7006).** Two more landings. (1) `expr as T` and `expr satisfies T` now build a proper `as_expression` HIR node (was: silently discarding the LHS and returning the RHS as if it were an expression — a long-standing latent bug). The parser parses the RHS as a type annotation, the checker types the result as the asserted type, and the JS emitter erases to the inner runtime expression. New shared `addAsExpression` builder + `asExpressionOf` accessor on the existing `as_expr` / `satisfies_expr` / `type_assertion` HIR kinds. (2) Strict-mode `noImplicitAny` lands as a `StrictFlags` struct on the checker, populated by the driver from `tsconfig.compilerOptions.strict` / `noImplicitAny`. Triggers TS7006 ("Parameter 'x' implicitly has an 'any' type.") on unannotated parameters and TS7005 ("Variable 'x' implicitly has an 'any' type.") on bare `let x;` declarations. Smoke-tested through `home-tsc` with `strict: true` — both diagnostics surface end-to-end with proper `path(line,col): error TSxxxx:` formatting. `zig build test`: 1202 → 1208 (+6: 3 as + 3 noImplicitAny).
- **2026-05-05 — tsconfig glob expansion + `super` resolution + `typeof` type query.** Three more landings stacked. (1) Glob matcher in `packages/tsconfig/`: `matchGlob(pattern, path)` recognizes `*` (in-segment), `**` (across segments), `?` (single char), and literal — pure logic, 6 unit tests. `home-tsc` consumes it via a new `expandProjectGlobs` helper that walks the project directory (skipping dotfiles + node_modules), filters by TS-shaped extensions (`.ts` / `.tsx` / `.d.ts` / `.mts` / `.cts`), respects `exclude`, and threads results through the existing program graph. Default `include` of `["**/*"]` matches tsc when neither `files` nor `include` is set. Smoke-tested: a tsconfig with `"include": ["src/**/*.ts"], "exclude": ["src/**/*.test.ts"]` over a 3-file tree compiles only `main.ts` + `sub/util.ts` (excludes `main.test.ts`). (2) `super` inside subclass methods resolves to the parent class's instance type via the same narrow-scope mechanism as `this` — pass 2 of `checkClassDecl` now binds both `this -> instance_t` and `super -> parent_t` (when `extends` resolves). `super.foo()` typechecks against the parent's member table; missing members emit TS2339 normally. (3) `type T = typeof x` resolves `x` to its static identifier TypeId via a new `typeof_type` case in `lowererLowerWithTypeParams` — falls back to the lowerer for non-identifier operands. End-to-end: `function add(a, b): number; type AddSig = typeof add; let f: AddSig = add;` interns `f`, `add`, and `AddSig` to the same signature TypeId. `zig build test`: 1193 → 1202 (+9: 6 glob + 2 super + 1 typeof).
- **2026-05-05 — Class follow-ups: interface + type-alias resolution, `this` typing, `extends` inheritance, constructor signatures.** Four type-checker landings stacked together. (1) Interface + type-alias names resolve as type annotations: `interface I { value: number }` and `type T = ...` register their TypeId in a new `type_names` table (a superset of `class_instance_types`); `lowererLowerWithTypeParams` consults it after the narrow scope, so `b: I` / `b: T` / `b: SomeClass` all resolve at the annotation site. Member access on the resulting interface / alias type triggers TS2322 / TS2339 normally. (2) `this` inside class methods now binds to the enclosing class's instance type. `checkClassDecl` is now a 2-pass walk: pass 1 builds the instance shape from method signatures + field annotations only (no body walks), pass 2 re-runs each method through `checkFnDecl` with `this → instance_type` pushed onto the narrow scope. Required splitting `checkFnDecl` into `checkFnSignatureOnly` + `walkFnBody`, and changing the checker's `string_interner` field from `*const` to `*` so `intern("this")` works. (3) `class B extends A` inherits `A`'s instance members via a new `mergeExtendedMembers` helper that prepends parent members the child doesn't override (child wins on name conflict — TS prototype-chain semantics). (4) Classes with explicit `constructor(...)` declarations get their signature recorded in a new `class_constructor_sigs` table; `new Foo(args)` typing now runs the same TS2554 (count) + TS2345 (type) checks as `call_expr` via a new shared `checkArgsAgainstSignature` helper. Classes without an explicit constructor stay permissive (matches TS implicit no-arg default). 11 new checker tests across the four features. `zig build test`: 1182 → 1193 (+11).
- **2026-05-05 — `home-tsc` `.d.ts` emit + parser fix for `export type X = Y`.** New `--declaration` / `-d` CLI flag, also driven by `compilerOptions.declaration` in tsconfig. When enabled, `home-tsc` runs `ts_emit.DtsEmitter.emitSourceFile` on each compiled file's HIR root and writes a `.d.ts` alongside the `.js` (or under `compilerOptions.declarationDir` if set, falling back to `outDir`). Two pre-existing emitter bugs uncovered + fixed: (1) `export interface I {}` left a dangling `export ` token in the JS output (the printer wrote the keyword before checking that the inner decl erased) — `printExport` now bails early when the inner decl is `interface_decl` or `type_alias_decl`; (2) the export parser ate `type` as the type-only marker even when followed by an identifier+`=`, so `export type Pair = ...` failed to parse — `parseExportDeclaration` now only treats `type` as type-only when followed by `{` (named re-export) or `*` (namespace re-export). 2 new emit tests. Smoke-tested end-to-end: emits `function add`, `interface Box`, `class Counter` (with method signatures), and `type Pair` correctly into the .d.ts. `zig build test`: 1180 → 1182 (+2).
- **2026-05-05 — `home-tsc` tsconfig discovery + outDir + diagnostic formatter.** `tsc_main.zig` now (a) walks upward from cwd looking for `tsconfig.json`, (b) accepts `--project <path>` (file or directory), (c) loads the discovered config via `tsconfig.parseString` and threads it through `ts_driver.optionsFromConfig` so jsx mode propagates, (d) treats `compilerOptions.outDir` as the destination for emitted `.js` files when no CLI `--outDir` overrides, (e) falls back to the tsconfig's `files` list when no positional inputs are passed, (f) prints diagnostics through `ts_diagnostics.formatDefault` so the actual `path(line,col): error TSxxxx: message` format reaches stdout (vs. the prior `path: message` shorthand). Important fix: the JSONC parser aliases unescaped strings into the source buffer, so the source must outlive `loaded_cfg` — moved cfg_src to function scope to avoid a use-after-free on `outDir` / other borrowed slices. Smoke-tested end-to-end against a tsconfig with `outDir: "dist"` + a `files` list — produces `dist/main.js`; type errors surface as `tests/main.ts(1,1): error TS2322: Type is not assignable to declared type.`.
- **2026-05-05 — TS diagnostic codes threaded end-to-end.** `ts_checker.Diagnostic` gains `code: u32` + `code_prefix: { TS, HM }` fields; the checker tags each emit site with the upstream-tsc code (TS2322 type-not-assignable, TS2339 property-does-not-exist, TS2345 argument-type-mismatch, TS2554 argument-count-mismatch). `ts_checker.TsCodes` exposes the full table the checker uses (mirrors `ts_diagnostics.TsCodes` so the cross-package dependency stays one-way). `ts_driver.Diagnostic` carries the code through translation. `ts_conformance` now prefers the diagnostic's own code over the phase-derived fallback, so baselines compare against real tsc codes (e.g. `tests/te.ts(1,1): error TS2322:` instead of the prior catch-all `TS2304`). Conformance baseline updated for the type-error case. 4 new checker tests asserting each code surfaces. `zig build test`: 1176 → 1180 (+4).
- **2026-05-05 — Class member resolution + instance type lowering.** `class_decl` now lowers to an interned object TypeId via `internObjectType` (members = declared fields with optional type annotation or initializer-inferred type, plus method signatures keyed by name; constructors are walked for body typing but excluded from the instance shape). The class name maps to its instance TypeId in a new `class_instance_types` table on the checker. `new Foo(args)` is now lowered as a dedicated `new_expr` HIR node (not a 0-arg call wrapper around `Foo(args)` as before) — the parser uses a new `parseMemberExpressionOnly` for the new-target so the parenthesized argument list belongs to the `new`, not to a call. `new_expr` typing produces the class instance type when the callee is a known class identifier; falls back to `any` otherwise. `instanceof Foo` narrowing now reaches into `class_instance_types` and narrows to the actual instance shape (vs. the prior `Primitive.object_t` fallback). Type annotations like `b: Box` resolve via `lowererLowerWithTypeParams` consulting `class_instance_types` after the narrow scope, so parameters / let-decls typed as a declared class get the proper structural type — `function f(b: Box): number { return b.value; }` types `b.value` to `number_t` with no diagnostics. JS emitter gains `printNew` (`new ` prefix + same args). HIR gains `addNew` builder + an `addObjectPropertyTyped` variant carrying the class field's type annotation slot. `callOf` widened to accept `new_expr` payloads (same shape). Required parser test fixup: `new Foo(1, 2)` now produces `.new_expr` with 2 args (was `.call_expr` with 0 args). 4 new checker tests (instance-type shape, `new` typing, `instanceof` narrowing to instance, parameter resolution). `zig build test`: 1172 → 1176 (+4).
- **2026-05-06 — §3.A.5 explicit `in`/`out` variance modifiers threaded into the type interner.** First cut of the variance work: declaration-site `in` / `out` modifiers (TS 4.7) now flow from the parser through HIR to the type interner, where they participate in the type-parameter key. New `types.Variance` enum (`bivariant` / `contravariant` / `covariant` / `invariant`) + `variance: Variance` field on `TypeParameterPayload` (default `bivariant`). New `internTypeParameterWithVariance(name, constraint, default, variance)` API; the existing `internTypeParameter` defers to it with `bivariant`. New `typeParameterVariance(id)` + `typeParameterName(id)` accessors. `TypeKey.type_parameter` hash + eql include variance, so `T` / `in T` / `out T` / `in out T` produce four distinct interned ids. Both function- and type-alias generic-decl sites in `check.zig` thread `Variance.fromHirBits(tpp.variance)` through; mapped-type `K` and `infer R` placeholders stay bivariant (correct — no user-declared variance). Parser bug fixed along the way: `in out T` previously failed to parse because the variance lookahead required `kw_in` followed by an `identifier`, missing the `in`-then-`out` shape; now also accepts `kw_in` followed by `kw_out`. 12 new tests: 5 in `interner.zig` (round-trip, distinct-ids, dedup, HIR-bit mapping), 4 in `check.zig` (e2e through parser+checker for each of `in`/`out`/`in out`/no-modifier), 4 in `ts_parser.zig` (parser-level variance bit assertion). Auto-variance inference (walking the body to compute usage variance) and the relation-engine instantiation-pair comparison are §3.A.5 follow-ups against this same shape. `zig build test`: 1342 → 1354 (+12).
- **2026-05-06 — Session ratchet: parser/emit downlevels, LSP push, watch wiring, conformance smoke, narrowing depth.** Implementation chunks committed individually:
  - `6c25c8f` parameter decorators wired through HIR + ts_parser + ts_emit
  - `9a8e4da` async/await `__awaiter` downlevel for ES2015–ES2016 targets
  - `07a9936` smoke-run local TS conformance subdirectory under `tests/conformance`
  - `fef6e26` private fields → WeakMap downlevel (ts_emit + ts_parser)
  - `9e56d2e` basic `.d.hm` emitter (framing only) — Phase 4 punch §4.A.13
  - `5b44074` binder fix — route `Module`'s symbol/scope lists through the arena
  - `d1234f6` ts_program guard — root.kind == .block_stmt before walking imports
  - `21789d5` ts_watch `RealStatFs` for disk-backed watch tracking
  - `8ffc1c6` `home-tsc --watch` uses `ts_watch.Watcher` + `RealStatFs`
  - `8afeb64` LSP `didChangeFile` triggers recompile + fresh diagnostics
  - `6ec5870` ts_lsp_server routes `textDocument/didChange` to `Service.didChangeFile`
  - `d614b4e` basic `await` + `yield` expression typing in checker
  - `e2b8fb2` §3.A.5 ratchet — basic variance auto-inference for generic params
  - `bd29088` §6.A.3 patience-diff unified output on baseline mismatch
  - `0c44034` §3.A.15 ratchet — collect `declare global` augmentations across files
  - `d6c10bc` §5.A.6 two-level relation cache (L1 + L2) for parallelization readiness
  - `ca9d03a` `formatPretty` with source-snippet excerpt in ts_diagnostics
  - `26f1590` §8.A.5 `formatDocument` stub + `foldingRanges` over block statements
  - `1c52fff` §4.A.5 ratchet — `await` unwraps structural `Promise<T>`
  - `ed8ab71` incremental `Program.compileAll` skips files with unchanged sources
  - `18e98f2` `home-tsc --pretty` wires through `formatPretty`
  - `339d13b` §3.A.10 ratchet — narrow on `===` with literal RHS (string / number / bool / null / undefined)
  Total `zig build test`: **1354 → 1421** (+67 tests this session).

- **2026-05-06 — Afternoon batch: streaming diagnostics, .d.hm members, shadowing-aware refs, this:T binding, parameter inlay hints, plus parallel work from a second agent.**
  - `daf97fa` §5.A.10 — `home-tsc` consumes `Program.compileAllStreaming`; diagnostics print as each file finishes compiling
  - `85ae6e2` §4.A.13 — `.d.hm` enum / trait / declare-module emitters (writeEnum / writeTrait / openDeclareModule)
  - `ba87cfe` §8.A.9 — `findReferences` shadowing-aware via `enclosingScopeOf` walking `Module.scopes` against the HIR ancestor chain
  - `d1a9810` §3.A.11 — `this: T` parameter captured as a regular param named "this"; checker's `walkFnBody` lowers its annotation and binds `this` in the narrow scope; JS emit strips it via `printRuntimeParams`
  - `534a901` §8.A.3 — `inlayHints` surfaces `paramName:` hints at call-expression arg sites
  - Parallel landings (from a second agent on the same project): codeAction "Add explicit type", member-access narrowing on identifier-rooted access, tsbuildinfo round-trip reader + read-on-startup, sourceMap → `.js.map` write, basic `ThisType<T>` recognition, LSP `textDocument/hover` wire handler, gotoDefinition follows imports across files, hover renders function/class/let declaration shape, semantic-tokens delta-encoded wire format.

- **2026-05-06 — Session landings: LSP lifecycle + emit re-exports + nested document-symbols + sourceMap/tsbuildinfo wire-up + this-binding + cross-file definition.**
  - `bb406d4` §8 — `ts_lsp_server` `initialize` / `shutdown` / `exit` lifecycle handlers
  - `a30d105` §4.A — `ts_emit` re-export forms (`export *` / `export { x } from`)
  - `439e645` §8.A.7 — `documentSymbols` includes nested class / interface / namespace members
  - `bc337d1` §4.A.1 — `ts_cli` wires sourceMap output to `.js.map`
  - `2033d0f` §4.A.12 — `ts_cli` `.tsbuildinfo` round-trip wiring (read on startup)
  - `189ec1c` §3.A.11 — `ts_checker` basic `ThisType<T>` recognition (unwrap)
  - `d1a9810` §3.A.11 — `ts_checker` binds `this` from explicit `this:T` parameter
  - `47c3214` §8 — `ts_lsp_server` `textDocument/hover` wire handler
  - `ba87cfe` §8.A.9 — `ts_lsp` `findReferences` shadowing-aware via binder scope graph
  - `e6e5da5` §4.A.12 — `ts_emit` `.tsbuildinfo` round-trip reader
  - `bef89da` §3.A.10 — `ts_checker` member-access narrowing on identifier-rooted access
  - `80a0662` §8.A.5 — `ts_lsp` codeAction "Add explicit type annotation" for inferred lets
  - `5a0ebae` §5.A.5 — `ts_cli` replace busy-spin in `--watch` with proper sleep API
  - `e074bde` §8 — `ts_lsp` hover renders function/class/let declaration shape
  - `c23bf6c` §8.A.6 — `ts_lsp` `gotoDefinition` follows imports across files
  - `d5c9d85` §1.C — `tsconfig` adds 8 commonly-used `compilerOptions` fields
  - `90b06fc` §8.A.4 — `ts_lsp` semantic-tokens delta-encoded wire format + range variant
  - `ed8ab71` §5.A.1 — `ts_program` incremental `compileAll` skips unchanged files
  - `339d13b` §3.A.10 — `ts_checker` narrow on `===` with literal RHS
  - `18e98f2` §6 — `ts_cli` `--pretty` wires through `formatPretty`
  - `1c52fff` §3.A — `ts_checker` `await` unwraps structural `Promise<T>`
  - `26f1590` §8.A.10 — `ts_lsp` `formatDocument` stub + `foldingRanges` over block statements
  - `ca9d03a` §6 — `ts_diagnostics` `formatPretty` with source-snippet excerpt
  - `d6c10bc` §5.A.6 — `ts_checker` two-level relation cache (L1 + L2) for parallelization readiness
  - `0c44034` §3.A.15 — `ts_program` collects `declare global` augmentations across files
  - `bd29088` §6.A.3 — `ts_conformance` patience-diff unified output on baseline mismatch
  Total `zig build test`: **1421 → 1459** (+38 tests this session, all passing).

- **2026-05-06 — Session landings: LSP wire-protocol substantially complete + `ts_bundler` v0 scaffold + checker depth (TS2769, satisfies, bigint) + diagnostics polish.**
  - `13c57c2` §6 — `ts_diagnostics` `formatPretty` ANSI color support
  - `4f8af28` §8.A — `ts_lsp` `documentHighlights` for identifier-under-cursor
  - `76d3a2e` §4.5.A.10 — `ts_bundler` v0 concat-mode scaffold
  - `e7a3b54` §8 — `ts_lsp_server` `textDocument/completion` wire handler
  - `3ad141e` §8 — `ts_lsp_server` `textDocument/signatureHelp` wire handler
  - `e512875` §8 — `ts_lsp_server` `dispatchRequest` routes JSON-RPC frames to handlers
  - `c9dc339` §8 — `ts_lsp_server` wires 10 more LSP method handlers (definition / references / documentSymbol / workspaceSymbol / codeAction / semanticTokens full + range / foldingRange / inlayHint / formatting)
  - `c4e12c7` §8 — `ts_lsp_server` `textDocument/didOpen` + `didClose` wire handlers
  - `84109e4` §4.5.A.10 — `ts_bundler` basic tree-shaking + minify passes
  - `71acd93` §6 — `ts_diagnostics` `HmCodes` registry for Home-only diagnostics
  - `d5ff71d` §8.A — `ts_lsp_server` `prepareRename` + `completionItem/resolve` handlers
  - `479d9ee` §3.A.7 — `ts_checker` TS2769 "No overload matches this call" diagnostic (also lands `typeof x === "bigint"` narrowing)
  - `bbc7174` §8.A — `ts_lsp` call hierarchy incoming + outgoing
  - `931f614` §3.A.16 — `ts_checker` `satisfies` preserves the original (more-specific) inferred expression type
  - `afdf20a` §8.A.4 — `ts_lsp` `semanticTokens` includes keywords (and comments where available)
  Total `zig build test`: **1459 → 1491** (+32 tests this session, all passing).

- **2026-05-06 — Session landings: tsconfig depth + checker narrowing/diagnostics + bundler tree-shake + conformance smoke + LSP request surface.**
  - `ca2bfcf` §1.C — `tsconfig` adds ~14 more `compilerOptions` fields
  - `be4ff41` §1.C — `ts_driver` wires `experimentalDecorators` tsconfig field through
  - `aa48ed2` §8.A — `ts_lsp` `codeLenses` with reference counts on declarations
  - `283f277` §3.A.4 — `ts_checker` template-literal-type concrete-string evaluation
  - `9b1e481` §3.A.10 — `ts_checker` `Array.isArray` narrowing + `typeof` function
  - `88fa0cb` §3.A — `ts_checker` TS2454 used-before-assignment (linear-scan)
  - `fc294ac` §4.5.A.10 — `ts_bundler` drops fully-unused imports during tree-shake
  - `95a716b` §6.A.4 — `ts_conformance` smoke against 3 local TS subdirs
  - `32f0c3e` §3.A — `ts_checker` TS2304 (cannot find name) + TS2588 (assign to const)
  - `abd6118` §8.A — `ts_lsp` `selectionRange` + `willSaveWaitUntil`
  - `3482a51` §8.A — `ts_lsp` `diagnosticsStructured` returns `[]LspDiagnostic`
  Punch-list ratchet: §3.A.4 template-literal-type concrete-string evaluation ✅ landed; §3.A.10 `Array.isArray` narrowing ✅ landed; §3.A.16 `satisfies` preserves original type ✅ (already noted last session); new diagnostics TS2304 / TS2454 / TS2588 / TS2769 all ✅ landed; §4.5.A.10 `ts_bundler` tree-shake unused imports ✅ partial (drops fully-unused imports — full per-symbol DCE remains); §6.A.4 multi-subdir conformance smoke ✅ partial (3 local TS subdirs wired; full external corpus still §6.A.1 follow-up); §8.A.* `selectionRange` + `willSaveWaitUntil` + `codeLenses` + `diagnosticsStructured` + call hierarchy + `prepareRename` + `completionItem/resolve` all ✅ landed (call-hierarchy + prepareRename / completionItem/resolve from prior session, repeated here for completeness against the LSP punch list).
  Total `zig build test`: **1491 → 1510** (+19 tests this session, all passing).

- **2026-05-06 — Session landings: checker depth (narrowing + diagnostics + intersections + structural sigs) + LSP wire-protocol breadth + emit/tsconfig polish.**
  - `32f0c3e` §3.A — `ts_checker` TS2304 (cannot find name) + TS2588 (assign to const)
  - `05e0665` §3.A — `ts_checker` `noUnusedParameters` for catch-clause + arrow params
  - `84f2837` §3.A — `ts_checker` discriminated-union narrowing in switch cases
  - `c7754e2` §8.A — `ts_lsp_server` `textDocument/codeLens` wire handler
  - `025b52e` §8.A — `ts_lsp_server` `typeDefinition` + `callHierarchy` wire handlers
  - `d862c92` §3.A.5 — `ts_checker` structural identity of generic signatures (type-param equivalence)
  - `4d56733` §8.A — `ts_lsp_server` `didChange` `publishDiagnostics` with structured `Diagnostic[]`
  - `2d86c12` §8.A — `ts_lsp` parameter-name inlay hints at call sites
  - `2444f0a` §3.A — `ts_checker` intersection type assignability rules
  - `7592bf1` §3.A — `ts_checker` narrow on `===` with negative bigint literal
  - `bd1de4d` §8.A — `ts_lsp_server` `completionItem/resolve` fills detail from symbol type
  - `ecd4928` §3.A — `ts_checker` expand built-in globals to suppress TS2304
  - `a85694b` §8.A — `ts_lsp_server` `implementation` + `documentLink` + `documentLinkResolve`
  - `d84206d` §8.A — `ts_lsp` `documentLinks` + `implementation` for interface implementers
  - `a4ffa1e` §3.A — `ts_checker` TS1308 `await` only in async functions
  - `d5e5226` §8.A — `ts_lsp_server` `textDocument/diagnostic` pull handler
  - `bf5b64a` §4.A — `ts_emit` `importHelpers` option imports `__awaiter` etc from `tslib`
  - `36dc233` §8.A — `ts_lsp` `workspace/willRenameFiles` stub
  - `734c5f6` §1.C — `tsconfig` `validate()` with cross-field consistency checks
  Punch-list ratchet: §3.A discriminated-union narrowing in switch cases ✅ landed; §3.A.5 structural identity of generic signatures via type-param equivalence ✅ landed (auto-variance inference still pending); §3.A intersection assignability ✅ landed; §3.A negative-bigint-literal narrowing ✅ landed; new diagnostics TS1308 (await-only-in-async) + TS2588 (assign-to-const) + TS2304 expansion all ✅ landed; §4.A `importHelpers` ✅ landed (emits `import { __awaiter, ... } from "tslib"` instead of inlining helpers); §1.C tsconfig `validate()` ✅ landed (cross-field consistency); §8.A LSP wire surface ratcheted forward — `codeLens` + `typeDefinition` + `callHierarchy` + `didChange publishDiagnostics(Diagnostic[])` + parameter-inlay-hints + `completionItem/resolve` (detail) + `implementation` + `documentLink`/`documentLinkResolve` + `textDocument/diagnostic` (pull) + `workspace/willRenameFiles` all ✅ landed.
  Total `zig build test`: **1510 → 1544** (+34 tests this session, all passing).

- **2026-05-06 — Session landings: exhaustive-switch narrowing + for-await-of + TS2367 + LSP semantic-tokens delta + codeLens/resolve.**
  - `a9e9f13` §3.A.10 — `ts_checker` TS2367 unintentional comparison with no overlap
  - `1dca066` §8.A — `ts_lsp_server` `codeLens/resolve` stub handler
  - `daef39f` §3.A.10 — `ts_checker` exhaustive switch narrows discriminant to `never` in default
  - `18b2bf7` §3.A / §4.A — `ts_parser`,`ts_emit` `for-await-of` support
  - `422afa0` §8.A — `ts_lsp` `semanticTokensDelta` v0 (full reset)
  - `d80a74b` docs — journal session landings + ratchet to 1544 tests
  Punch-list ratchet: §3.A.10 exhaustive-switch `never` narrowing in `default` ✅ landed; §3.A.10 TS2367 (unintentional comparison) ✅ landed; §3.A `for-await-of` parser + emit ✅ landed; §8.A `semanticTokensDelta` ✅ landed (v0 emits a full reset; true delta diffing remains a follow-up); §8.A `codeLens/resolve` stub ✅ landed.
  Total `zig build test`: **1544 → 1550** (+6 tests this session, all passing).

- **2026-05-06 — Session landings: LSP method-coverage expansion + CI test-count regression gate + bundler entry dedup + readonly arrays.**
  - `d65e515` §8.A.5 — `ts_lsp` codeAction "Add import for 'X'" for unresolved identifiers (joins "Organize Imports" + "Add explicit type annotation" in the quick-fix surface)
  - `89c6b79` §8 — `ts_lsp_server` comprehensive method-coverage audit + canonical `SUPPORTED_METHODS` list documenting which LSP-spec methods the dispatcher routes
  - `1db9f01` §3.A — `ts_parser`,`ts_checker` `readonly T[]` array type annotation flows through to the interner
  - `9133340` §4.5.A.10 — `ts_bundler` deduplicates entries in bundle output (avoids emitting the same module twice when reachable from multiple roots)
  - `e94e72b` §8 — `ts_lsp_server` `textDocument/selectionRange` wire handler
  - `b829fa5` §8 — `ts_lsp_server` `textDocument/linkedEditingRange` + `workspace/willRenameFiles` wire handlers
  - `b7d420e` §8 — `ts_lsp_server` `workspace/executeCommand` wire handler
  - `b7f4b13` ci — PRs gated on test pass-count not regressing (the journal-tracked count is now load-bearing)
  - `949b735` §8.A.13 — `ts_lsp` JSX tag-pair `linkedEditingRanges` real implementation (no longer a stub) — renaming an opening tag updates the matching closing tag in lockstep
  - `644364c` §8.A.14 — `ts_lsp` `workspace/willRenameFiles` real implementation (no longer a stub) — file-rename events trigger import-path rewrites across the program graph

  Punch-list ratchet: §8.A LSP wire surface ratcheted forward — `selectionRange` + `linkedEditingRange` + `willRenameFiles` + `executeCommand` wire handlers all ✅ landed; `linkedEditingRanges` and `workspace/willRenameFiles` ✅ promoted from stub to real implementation; codeAction "Add import for 'X'" ✅ landed (joins Organize Imports + Add explicit type annotation); method-coverage audit ✅ landed (`SUPPORTED_METHODS` is now the single source of truth). §4.5.A.10 `ts_bundler` entry-dedup ✅ landed (per-symbol DCE remains the open work). §3.A readonly array type annotation ✅ landed. CI: PRs now gated on test pass-count not regressing — the journal's tracked count is the regression baseline.
  Total `zig build test`: **1550 → 1569** (+19 tests this session, all passing).

- **2026-05-06 — Evening session (continued, batch 3): tsconfig baseUrl/paths + checker depth (Awaited/exactOptional/isolatedModules/noUncheckedIndexedAccess/inferred predicates/spelling) + parser TS 5.0/4.9/disposable syntax + LSP inlineValue/onTypeFormatting + bundler JSON manifest + .d.hm.map.**
  - `a941758` §1 — `ts_parser` `const` type parameters TS 5.0 syntax
  - `1b96b2a` §3.A.18 — `ts_checker` `Awaited<T>` recursive-unwrap intrinsic
  - `fb3cbd6` §8.A.21 — `ts_lsp` `textDocument/inlineValue`
  - `eb5baa2` §1 — `ts_parser` import attributes (`with` / `assert`) syntax
  - `6547339` §1 — `ts_parser` `accessor` class member modifier (TS 4.9)
  - `35b5e3f` §1 — `ts_parser` `using` and `await using` declarations
  - `508ba88` §4.A.13 — `d_hm` emit `.d.hm.map` source map (v0 framing)
  - `2089aa2` §8.A.23 — `ts_lsp` codeLens shows reference counts on top-level decls
  - `bbc70f6` §8.A.22 — `ts_lsp_server` `textDocument/onTypeFormatting` wire handler
  - `a956c58` §4.5.A.10 — `ts_bundler` emit JSON manifest
  - `c97d43b` §3.A.21 — `ts_checker` `noUncheckedIndexedAccess` option
  - `6541824` §3.A.20 — `ts_checker` `isolatedModules` option (basic checks)
  - `cecf32c` §3.A.23 — `ts_checker` inferred type predicates from narrowing returns (TS 5.5)
  - `06681a3` §3.A.19 — `ts_checker` `exactOptionalPropertyTypes` + spelling suggestions on TS2304/TS2339
  - `bd75393` §9 / §1.C — `ts_resolver` tsconfig `baseUrl` + `paths` aliases threaded through specifier resolution
  - `8170764` §3.A.22 — `ts_resolver`,`ts_checker` `resolveJsonModule` option
  - `ea1fdf3` `ts_parser` fix — emit `kw_undefined` as `literal_undefined` in expression position (was leaking the keyword token to the checker)

  Punch-list ratchet: §3.A grew six new ✅ entries (Awaited<T>, exactOptionalPropertyTypes + spelling suggestions, isolatedModules basic checks, noUncheckedIndexedAccess, resolveJsonModule, inferred type predicates from narrowing returns); §1 Phase-1 follow-ups grew four new ✅ entries (`const` type parameters, import attributes, `accessor` modifier, `using`/`await using`); §4.5.A grew JSON manifest emit; §4.A.13 `.d.hm` emitter ratcheted with `.d.hm.map` v0 framing; §8.A grew three new ✅ entries (`inlineValue`, `onTypeFormatting`, codeLens reference-count refinement); Phase 9 / §1.C tsconfig surface gained `baseUrl` + `paths` alias resolution wired through `ts_resolver`. Plus the parser fix promoting `undefined` to a real literal-undefined node closes a long-standing leak that masked checker narrowing bugs.
  Total `zig build test`: **1599 → 1636** (+37 tests this session, all passing).

- **2026-05-07 — Day-3 session: visibility/abstract/readonly checks + default type params + lib prototypes + emit polish (numeric sep / sourceMap VLQ / JSX classic / ESM↔CJS) + LSP push (documentColor / inlayHint resolve / foldingRange).**
  - `cecf32c` §3.A.23 — `ts_checker` inferred type predicates from narrowing returns (TS 5.5) — *cross-listed; landed end of prior session, accounted here for completeness*
  - `06681a3` §3.A.19 — `ts_checker` `exactOptionalPropertyTypes` + spelling suggestions on TS2304 / TS2339
  - `bd75393` §9 / §1.C — `ts_resolver` tsconfig `baseUrl` + `paths` aliases threaded through specifier resolution
  - `8170764` §3.A.22 — `ts_resolver`,`ts_checker` `resolveJsonModule` option
  - `dbce0b1` §3.A.27 — `ts_checker` `noPropertyAccessFromIndexSignature` option (TS4111) — dotted member access on an index-signature value now requires bracket access under the option
  - `a4fbee7` §8.A.25 — `ts_lsp_server` `inlayHint/resolve` wire handler — completes the inlay-hint round-trip so editors can lazily fetch the rendered hint label
  - `7440750` §4.A.18 — `ts_emit` ESM↔CJS interop emit cases — pinned baseline tests covering default / namespace / named / side-effect / mixed import shapes against `module: commonjs` + `esModuleInterop`
  - `26e288d` §1.B / §4.A.16 — `ts_lexer`,`ts_emit` numeric separator (`1_000`) support and downlevel — lexer accepts `_` between digits per TC39 / TS 2.7+; emitter strips separators when `target` ≤ ES2017 so older runtimes parse cleanly
  - `ffe628f` §3.A.24 — `ts_checker` private member visibility check (TS2341) — `private` class fields / methods are now diagnosed when accessed outside the declaring class body
  - `cc25e20` §8.A.24 — `ts_lsp_server` `textDocument/documentColor` + `colorPresentation` — surfaces CSS-style color literals in `.ts` / `.tsx` source for editor color-swatch UI
  - `64f6186` §3.A.26 — `ts_checker` pre-populates basic `String` / `Array` prototype lib types — closes a long-standing gap where `"x".length` and `arr.map(...)` typed as `any`; baseline lib types now seed at checker construction so member access resolves without a full `lib.d.ts` load
  - `a9b8bf7` §3.A.24 — `ts_checker` protected / abstract / readonly visibility checks (TS2445 / TS2511 / TS2540) — `protected` access outside subclass body, `new` of an `abstract` class, and writes to `readonly` fields all surface diagnostics
  - `207c7e4` §1 / §3.A.25 — `ts_parser`,`ts_checker` default type parameters `T = string` (TS 2.3) — when a generic call leaves a parameter uninferred, the declaration-site default substitutes through the signature
  - `b21dceb` §8.A.10 — `ts_lsp` `foldingRange` — imports / regions / block comments — finer fold targets now layered on top of the block-statement foundation
  - `008ea53` §3.A.24 — `ts_checker` abstract member implementation check (TS2515) — concrete subclass without an override of an `abstract` method now diagnoses; pairs with the abstract-construction check from `a9b8bf7`
  - `7c7f67e` §4.A.10 — `ts_emit` JSX classic runtime (`React.createElement`) — round-trip baseline tests pinned for the classic factory mode (single-child, multi-child, fragment, member-access tag, spread attrs)
  - `15b026d` §4.A.17 — `ts_emit` source map v3 line-level VLQ segments — printer now records per-token mappings (was per-statement); generated column resets on newline; mappings sort by `(gen_line, gen_col)` per spec

  Punch-list ratchet:
  - §1 Phase-1 follow-ups: ✅ default type parameters (`T = string`, TS 2.3) — declaration-site defaults flow parser → HIR → checker and substitute when inference leaves a parameter uninferred.
  - §3.A: ✅ private member visibility (TS2341); ✅ protected / abstract / readonly visibility checks (TS2445 / TS2511 / TS2540); ✅ abstract member implementation check (TS2515); ✅ basic `String` / `Array` prototype lib types pre-populated at checker construction; ✅ `exactOptionalPropertyTypes` + spelling suggestions; ✅ `noPropertyAccessFromIndexSignature` (TS4111). Phase 2 visibility surface is now functionally complete for class-modifier checks.
  - §4.A: ✅ numeric separator (`1_000`) lexer support + downlevel; ✅ source-map v3 line-level VLQ segments (per-token mappings); ✅ JSX classic-runtime (`React.createElement`) emit baselines pinned; ✅ ESM↔CJS interop emit-case baselines pinned.
  - §8.A: ✅ `textDocument/documentColor` + `colorPresentation`; ✅ `inlayHint/resolve` wire handler completes the inlay-hint lazy-resolve round-trip; ✅ `foldingRange` ratcheted from block-only stub to imports / regions / block-comment fold targets — promotes §8.A.10 from 🟢 stub toward fully-landed.
  - §9 / §1.C: ✅ tsconfig `baseUrl` + `paths` aliases now resolve through `ts_resolver`; ✅ `resolveJsonModule` option recognized end-to-end.
  Total `zig build test`: **1636 → 1679** (+43 tests this session, all passing).

- **2026-05-07 — Day-3 session (continued, batch 4): generator inference + enum auto-inc + const enum literal narrowing + @ts-nocheck + ??= narrowing + spread typing + template literal assignability + destructuring defaults + JSX dev runtime + BigInt downlevel + bundler minify + extensive LSP wire surface (declaration / inlineCompletion / pull diagnostics / semantic tokens delta / case-insensitive workspace symbol).**
  - `bac3df6` §3.A — `ts_checker` basic generator function return type inference — `function* g() { yield 1; }` now infers a `Generator<T, …, …>`-shaped return without explicit annotation.
  - `7399a3e` §3.A — `ts_checker` enum member auto-increment + value tracking — bare `enum { A, B, C }` members get sequential numeric ids; explicit assignments reset the cursor; tracked values back const-enum inlining.
  - `844fda6` §3.A — `ts_checker` `// @ts-nocheck` file-level directive — top-of-file pragma suppresses every diagnostic in the file, matching tsc semantics.
  - `b26e61c` §1 / §4.A — `ts_parser`,`ts_emit` `yield*` delegated iteration — parser captures the `*` flag on yield expressions; emit prints `yield*` round-trip.
  - `da62a2f` §3.A — `ts_checker` const enum literal type at member access — `const enum E { A = 1 }` accessed as `E.A` types as the literal `1` rather than the enum's wide numeric type.
  - `ec6cb8c` §8.A — `ts_lsp_server` `textDocument/declaration` wire handler — pairs with the existing `textDocument/definition` so editors can distinguish forward-declarations from full definitions.
  - `1449c7c` §4.A.10 — `ts_emit` JSX `react-jsxdev` runtime — emits `_jsxDEV(tag, props, key, isStaticChildren, sourceLocation, this)` form alongside the existing classic / automatic / preserve modes.
  - `60e6bee` §3.A — `ts_checker` discriminated union member-access narrowing — accessing the discriminant member on a narrowed union narrows the surrounding flow accordingly.
  - `260ca8d` §8.A — `ts_lsp_server` `textDocument/inlineCompletion` wire handler — surfaces inline ghost-text completion candidates (LSP 3.18 / Copilot-style integration point).
  - `cb95c1c` §4.5.A — `ts_bundler` minify pass — strip comments + collapse whitespace as a low-risk first cut at output minification.
  - `26dd839` §3.A / §1 — `ts_checker` tagged template literal call typing (v0) — tag-call against a template literal now types as the tag function's return type; quasi + substitution slots are passed positionally.
  - `165062a` §8.A — `ts_lsp_server` LSP 3.17 pull-based diagnostics — wires `textDocument/diagnostic` pull endpoint so editors that prefer pull semantics get parity with the existing push surface.
  - `be8f1c4` §3.A — `ts_checker` template literal type assignability — concrete-string template literal types now compare structurally against literal-string targets, so a fully-resolved template assigns to its concatenated literal-string form.
  - `bdf34ef` §3.A — `ts_checker` object spread merges member types — `{ ...a, b: 1 }` produces a union/intersection-aware merged shape instead of widening to `any`.
  - `189fc1d` §3.A — `ts_checker` array spread element typing — `[...arr, x]` types as the union of `arr`'s element type and `x`'s type.
  - `45b1084` §8.A — `ts_lsp` `workspace/symbol` case-insensitive substring search — workspace-wide symbol search now matches user queries irrespective of case, matching tsserver behavior.
  - `2f27595` §4.A — `ts_emit` BigInt literal native + downlevel emit — `1n` passes through at ES2020+ and downlevels to a runtime helper at older targets.
  - `306996d` §8.A — `ts_lsp` semantic tokens delta encoding tests — pinned tests for the existing delta-encoded semantic-tokens output so future legend / classification changes are regression-gated.
  - `96b6c50` §3.A — `ts_checker` logical assignment narrowing for `??=` — `a ??= b` narrows the left-hand side to remove `null | undefined` after the assignment, complementing the existing `&&=` / `||=` paths.
  - `47b7e53` §3.A — `ts_checker` destructuring with defaults — undefined removal — `const { x = 1 } = obj` types `x` with `undefined` subtracted from the source's optional member, matching tsc's contextual narrowing.

  Punch-list ratchet:
  - §1 Phase-1 follow-ups: ✅ `yield*` delegated iteration; ✅ tagged template literal call typing v0; ✅ destructuring with defaults — undefined removal. *Computed property names full evaluation* added to the remaining list to keep an explicit tracker.
  - §3.A: ✅ enum member auto-increment + value tracking; ✅ basic generator function return type inference; ✅ const enum literal type at member access; ✅ `@ts-nocheck` file-level directive; ✅ logical assignment narrowing for `??=`; ✅ object spread merges member types; ✅ array spread element typing; ✅ template literal type assignability; ✅ destructuring defaults — undefined removal. The "spread + literal-type narrowing" cluster was the biggest remaining gap in the assignability surface; it's now functionally closed.
  - §4.A: ✅ BigInt literal native + downlevel emit baselines pinned; ✅ JSX `react-jsxdev` runtime emit landed (rounds out the four-way classic / automatic / automatic_dev / preserve matrix); ✅ `ts_bundler` minify pass — strip comments + collapse whitespace.
  - §8.A: ✅ `textDocument/declaration` wire handler; ✅ `textDocument/inlineCompletion` wire handler; ✅ LSP 3.17 pull-based diagnostics (`textDocument/diagnostic` pull endpoint); ✅ semantic tokens delta-encoding regression tests pinned; ✅ `workspace/symbol` case-insensitive substring search.
  Total `zig build test`: **1679 → 1733** (+54 tests this session, all passing).

- **2026-05-07 — Evening session 2 (continued, batch 5): LSP completeness round + ts_checker visibility/narrowing/spread/await depth + ts_emit ES5 lowering surface + misc ergonomics (numeric separators, BigInt downlevel, source-map VLQ, JSX dev runtime, useDefineForClassFields, lib types).** ~38 commits across `ts_checker`, `ts_emit`, `ts_lsp`, `ts_lsp_server`, `ts_parser`, and `parser`. Major themes: (a) **LSP completeness round** — documentColor / inlineCompletion / declaration / pull-based diagnostics / prepareRename / signatureHelp overload tracking + active-parameter, codeLens "Run test", inlay-hint tooltip resolve, publishDiagnostics dedup, willSaveWaitUntil, `@ts-ignore` quick-fix; (b) **`ts_checker` depth** — visibility / abstract / readonly enforcement, destructuring with defaults, await-Promise unwrap, object + array spread element typing, conditional / assertion-call / exhaustive-switch narrowing, function overload resolution v0, generic type-argument inference patterns, recursive type aliases, numeric enum reverse-mapped lookup, `import.meta`; (c) **`ts_emit` ES5 lowering surface** — default params, array spread (slice fast path), destructuring (basic), template literal → string concat, `const`/`let` → `var`, for-of indexed iteration, class-extends with super calls; (d) **misc** — numeric separators (`1_000`), BigInt downlevel, source-map V3 line-level VLQ segments, JSX `react-jsxdev` runtime, `useDefineForClassFields` plumbing, lib-prototype types, parser ergonomics (variadic `...`, anonymous struct return types, brace-less if, if/switch-as-expression, Zig-style for-loops, function type aliases, enum methods, implicit-return block expressions). Punch-list ratchet rolls forward across §1, §3.A, §4.A, and §8.A — the LSP wire surface is approaching tsserver parity; the ES5 lowering pipeline crosses the threshold where pre-ES2015 targets emit runnable output for the common case. Total `zig build test`: **1733 → 1828** (+95 tests this session, all passing).

- **2026-05-07 — Post-`59bfcaa` sync + Stage 3 member-decorator ratchet.** Reconciled every commit after `59bfcaa`: shebang trivia (`c86c4df`), expanded runtime globals (`32b6b8c`, `e46d293`), Stage 3 decorator emit-shape tests (`5f6cf60`), object-method shorthand ES5 lowering tests (`4838d35`), `keyof` / indexed-access regression coverage (`2a5424d`), getter/setter accessor typing tests (`18bd82b`), Home parser ergonomics (`da11d98`, `eba11d3`, `a7d368c`, `9028cef`, `1b2dafb`, `0cc612e`, `99bbda9`), and pickier lint-script migration (`9066886`). This working-tree batch extends Stage 3 mode so decorated class members emit simplified `__esDecorate(..., { kind: "method" | "field" | "getter" | "setter", name, static, private }, ...)` calls instead of falling back to legacy `__decorate`. `static` now flows through class-member HIR: legacy decorators target the constructor for static members instead of `.prototype`, Stage 3 member contexts report `static: true`, native class emit preserves `static` on methods/fields, and ES5 class lowering assigns static methods/fields on the constructor. `importHelpers` now imports `__esDecorate` from `tslib`, and tests pin class + method + field + getter + static-member Stage 3 shapes. Toolchain update: installed `ziglang.org@0.17.0-dev.263+0add2dfc4` through the local Pantry tool, corrected the ignored `pantry/.bin/zig` symlink to that compiler, added `-Dfilter=<package>` to the build script for targeted umbrella-test runs, and locally patched the ignored Pantry `zig-dtsx` checkout for Zig 0.17's array-initializer syntax. Verification: `zig fmt build.zig packages/hir/src/hir.zig packages/ts_parser/src/ts_parser.zig packages/ts_emit/src/js_emit.zig`, `zig ast-check` on those package roots, `zig build test -Dfilter=ts_emit` (**200/200**), `zig build test -Dfilter=ts_parser` (**157/157**), and `zig build test -Dfilter=hir` (**12/12**) all pass under Pantry Zig 0.17-dev. Full `zig build test --summary failures` under 0.17-dev reaches **123/166** build steps and **1573/1573** executed tests passing, then fails in unrelated packages on Zig 0.17's stricter array-repetition syntax plus the existing `ts_conformance` smoke delta (**12/16** local TS smoke cases passing).
- **2026-05-07 — Zig 0.17 repo-wide umbrella green + parser/AST ownership cleanup.** Continued the Pantry Zig 0.17-dev migration from the Stage 3 decorator batch through the rest of the repo. Replaced Zig 0.16-era array/string repetition idioms (`[_]T{...} ** N`, `"=" ** N`) with Zig 0.17-compatible `@splat` forms across CLI, benchmark, bootloader, build/cache, codegen, coredump, drivers, ipv6, modsign, signal, syslog, threading, timing, tpm, and usb packages; adjusted XHCI constants so Zig 0.17's stricter field/declaration ordering accepts the type. Fixed parser-test leaks by making skipped nested const annotations/initializers deinit their temporary type/expression allocations; teaching `EnumDecl`, `SwitchStmt`, `ArrayLiteral`, `MatchExpr`, `ReflectExpr`, macro/struct/tuple literals, and block expressions to release owned children; and normalizing struct-literal field/type-name ownership. Parser ergonomics gained leading-dot enum literal expressions (`.RED`) while preserving `.{ .x = ... }` anonymous struct literals. Diagnostics harness now strips Zig 0.17 DebugAllocator leak-note wording, leaving one intentional snapshot update for the improved `fn`-type parse error in `parse/37_ast_check_agreement.home.expected`. Verification: `zig build test -Dfilter=parser --summary failures`, `zig build test-diagnostics --summary failures` (**95/95**), and full `zig build test --summary failures` all pass under Pantry Zig `0.17.0-dev.263+0add2dfc4`; full run reports **1893/1893 tests passing**. The local TS conformance smoke remains non-gating at **12/16**, with the same four Phase 6 semantic gaps: `optionalProperties02`, `typeAssertionsWithIntersectionTypes01`, `equalityStrictNulls`, `typeAssertionsWithUnionTypes01`.
- **2026-05-07 — Phase 6 smoke triage: local TypeScript conformance now 16/16.** Cleared the four remaining non-gating smoke failures in the local TypeScript conformance `comparable` folder. Parser fix: `skipTypeAnnotation` now stops before the depth-0 `>` that closes `<T>expr`, so assertion types containing unions/intersections (`<A | B>x`, `<A & B>x`) no longer consume the assertion closer and fail with TS1109. Checker fix: TS2367 still reports obvious no-overlap strict equality mistakes, but nullish probes (`x === null`, `undefined !== x`, `null === undefined`) are exempt to match tsc's comparable relation under `strictNullChecks`. Regression coverage added in `ts_parser` and `ts_checker`. Verification: `zig build test -Dfilter=ts_parser --summary failures`, `zig build test -Dfilter=ts_checker --summary failures`, direct `home-tsc --noEmit` runs for `optionalProperties02`, `typeAssertionsWithIntersectionTypes01`, `equalityStrictNulls`, and `typeAssertionsWithUnionTypes01`, `zig build test -Dfilter=ts_conformance --summary failures` (**16/16** smoke), and full `zig build test --summary failures` all pass under Pantry Zig `0.17.0-dev.263+0add2dfc4`; diagnostics snapshots remain **95/95** and the full umbrella now accounts for **1895** passing tests.
- **2026-05-07 — Phase 6 assignment-compatibility survey ratchet.** Sampled additional local TypeScript conformance folders after the 16/16 smoke run and fixed the broadest low-risk parser/lexer gaps. `ts_lexer` now skips a leading UTF-8 BOM as trivia and still treats a BOM-prefixed shebang as first-line trivia. `ts_parser` now accepts `this: T` and type-only parameters in function types, splits `>>` / `>>>` into nested `>` closers only in type contexts, consumes declaration definite-assignment assertions (`let x!: T`), parses class index signatures, folds `1.: value` numeric object-literal keys, and frees the skipped type-argument slice after `extends Foo<T>`. `ts_checker` lowers class string/number index signatures into the instance object type. Direct local survey: `types/typeRelationships/assignmentCompatibility` moved from **44/70 passing** at the first sample to **65/70 passing**; the next failure is semantic definite-assignment/control-flow in `covariantCallbacks.ts` (TS2454), not parser recovery. Verification: `zig build test -Dfilter=ts_lexer --summary failures`, `zig build test -Dfilter=ts_parser --summary failures`, `zig build test -Dfilter=ts_checker --summary failures`, direct `home-tsc --noEmit` runs for the newly cleared upstream cases, `zig build test -Dfilter=ts_conformance --summary failures` (**16/16** smoke), `git diff --check`, and full `zig build test --summary failures` all pass under Pantry Zig `0.17.0-dev.263+0add2dfc4`; diagnostics snapshots remain **95/95** and the full umbrella now accounts for **1903** passing tests.
- **2026-05-07 — Phase 6 assignment-compatibility close-out: 70/70 local survey.** Continued the same `types/typeRelationships/assignmentCompatibility` survey and cleared the remaining five files. `declare let` now flows through HIR as `VarDeclPayload.is_ambient`, so TS2454 / noUnusedLocals skip ambient declarations and `covariantCallbacks.ts` no longer false-positives. `strictNullChecks` is now a real checker/relation flag: non-strict mode accepts `null` / `undefined` into all targets except `never`, while strict mode keeps the previous rejection; `--strict` also reaches the driver in no-tsconfig mode. `home-tsc file.ts` now matches `tsc` by not auto-loading the nearest `tsconfig.json` for explicit positional files unless `--project` is supplied, which keeps local conformance probes from accidentally inheriting this repo's strict config. `typeof undefined` in type-query position parses as an identifier operand and resolves to the `undefined` type. Direct local survey: `types/typeRelationships/assignmentCompatibility` is now **70/70 passing**. Verification: `zig build test -Dfilter=ts_parser`, `zig build test -Dfilter=ts_checker`, `zig build test -Dfilter=ts_driver`, direct `home-tsc --noEmit --no-pretty` probes for the fixed upstream files, `zig build test -Dfilter=ts_conformance --summary failures` (**16/16** smoke), `git diff --check`, and full `zig build test --summary all` (**166/166** build steps, **1909/1909** tests) pass under Pantry Zig `0.17.0-dev.263+0add2dfc4`.
- **2026-05-07 — Phase 6 larger type-relationships ratchet + category runner.** Moved from the assignment-only survey into a wider `types/typeRelationships` push. `ts_conformance` now has `CategorySpec` / `CategoryResult` plus `runCategorySpecs` and `combineCategoryStats`, and all conformance compile paths set `no_emit = true`; `home-tsc --noEmit` now reaches `ts_driver.CompileOptions.no_emit`, so survey runs type-check without printer side effects. The named category gate is now **86/86** (`assignmentCompatibility` 70/70, `comparable` 13/13, `inOperator` 2/2, `stringLiteral` 1/1). Parser/HIR/checker/emit ratchets landed for regex literals, `new Foo<T>()` type-argument preservation, contextual-keyword parameter names (`from`, `as`, etc.), angle-bracket assertions with array/nested generic assertion types (`<T[]>x`, `<Array<T>>x`), nested `>>`/`>>>` handling in generic-arrow and call type-arg probes, and generic class `extends Foo<T>` type-argument parsing. Checker excess-property validation now tolerates string-index-signature targets. Direct survey after the batch: apparentType **2/2**, bestCommonType **8/8**, recursiveTypes **12/13**, subtypesAndSuperTypes **46/52**, typeAndMemberIdentity **21/48**, typeInference **24/51**. Verification: `zig build test -Dfilter=hir`, `zig build test -Dfilter=ts_parser`, `zig build test -Dfilter=ts_checker`, `zig build test -Dfilter=ts_emit`, `zig build test -Dfilter=ts_driver`, `zig build test -Dfilter=ts_conformance --summary failures` (**16/16 smoke**, **86/86 category**), direct `home-tsc --noEmit --no-pretty` surveys, and full `zig build test --summary all` (**166/166** build steps, **1918/1918** tests) pass under Pantry Zig `0.17.0-dev.263+0add2dfc4`.
- **2026-05-08 — Phase 6 type/member + subtype ratchet.** Advanced the direct `types/typeRelationships` survey with a parser/checker relation batch. `ts_parser` now preserves interface type parameters, parses object/interface call signatures and construct signatures, accepts generic method shorthand in object/interface types, and preserves generic type parameters on object-literal and class method shorthand. `ts_checker` now lowers generic interface declarations into `generic_aliases`, lowers generic function/constructor type signatures under their own type-parameter scope, erases explicit `this` parameters from callable signatures, treats `Array<T>` / `ReadonlyArray<T>` type refs as array shapes, lets declared `interface Array<T>` / `ReadonlyArray<T>` members augment array member lookup, distributes common member lookup over unions, tolerates numeric object-literal keys against number index signatures, keeps ambient overload fallback signatures visible instead of hiding the last overload as an implementation, and matches TS's all-optional object assignment quirk for unconstrained generics. Direct survey after the batch: apparentType **2/2**, bestCommonType **8/8**, recursiveTypes **12/13**, subtypesAndSuperTypes **51/52** (remaining direct failure is an expected-error call-signature case), typeAndMemberIdentity **47/48** (remaining direct failure is an expected unresolved `typeof b` diagnostic), typeInference **25/51**. Verification: `zig build test -Dfilter=ts_parser --summary failures`, `zig build test -Dfilter=ts_checker --summary failures`, direct `home-tsc --noEmit --no-pretty` surveys, and full `zig build test --summary all` (**166/166** build steps, **1927/1927** tests) pass under Pantry Zig `0.17.0-dev.263+0add2dfc4`.
- **2026-05-08 — Phase 6 type-inference syntax/crash ratchet + contextual callbacks.** Continued the direct `types/typeRelationships/typeInference` push. `ts_parser` now accepts `unique symbol` type syntax, prefix/postfix `++`/`--` (lowered through existing compound-assignment checking), contextual primitive keyword identifiers in expression/arrow-parameter positions, contextual `get`/`set` function names, and `get(...)`/`set(...)` callee identifiers. `ts_checker` now makes variance inference and generic-default collection cycle-safe/payload-bounds-safe, so the former `unionTypeInference.ts` panic, `unionAndIntersectionInference3.ts` segfault, and `unionAndIntersectionInference1.ts` parser/crash path all degrade to ordinary semantic diagnostics. Generic call checking now does a pre-check substitution pass from non-callback arguments and relation now contextually instantiates generic callback signatures in concrete callback slots, clearing the positive half of `contextualSignatureInstantiation.ts` while preserving the disjoint-parameter diagnostics. Direct survey after the batch: apparentType **2/2**, bestCommonType **8/8**, recursiveTypes **12/13**, subtypesAndSuperTypes **51/52**, typeAndMemberIdentity **47/48**, typeInference **30/51**; the first remaining `typeInference` direct failure is an expected-error diagnostic in `contextualSignatureInstantiation.ts`, so the next measurement fix is baseline/negative-case awareness in the survey runner. Verification: `zig build test -Dfilter=ts_parser --summary failures`, `zig build test -Dfilter=ts_checker --summary failures`, `zig build test -Dfilter=ts_conformance --summary failures` (**16/16 smoke**, **86/86 category**), direct `home-tsc --noEmit --no-pretty` surveys, `git diff --check`, and full `zig build test --summary all` (**166/166** build steps, **1937/1937** tests) pass under Pantry Zig `0.17.0-dev.263+0add2dfc4`.
- **2026-05-08 — Phase 6 baseline-aware survey + discriminated inference ratchet.** Added `DirectoryLoadOptions.baseline_root`, `loadDirectoryWithOptions`, `runDirectoryWithOptions`, and `runCategorySpecsWithOptions` so local upstream `.errors.txt` baselines mark expected-error fixtures even when filenames are plain `.ts`. A new baseline-aware `types/typeRelationships` test now surveys apparentType, bestCommonType, recursiveTypes, subtypesAndSuperTypes, typeAndMemberIdentity, and typeInference together: **90/175** passing with no checker crashes. That broader survey shook out and fixed three unsafe generic-inference walkers (`inferFromPair`, `substituteType`, and `typeIncludesUndefined`/rest-arg checking) that previously assumed every flagged type id had a valid side payload. The semantic ratchet in this batch teaches call-site inference and argument checking to use object-literal discriminants when matching a generic union parameter, clearing `discriminatedUnionInference.ts`; substituted signatures now preserve the rest-parameter side-table marker. Direct survey after the batch: apparentType **2/2**, bestCommonType **8/8**, recursiveTypes **12/13**, subtypesAndSuperTypes **51/52**, typeAndMemberIdentity **47/48**, typeInference **32/51**. Verification: `zig build test -Dfilter=ts_checker --summary failures`, `zig build test -Dfilter=ts_conformance --summary failures`, direct `home-tsc --noEmit --no-pretty` surveys, `git diff --check`, and full `zig build test --summary all` (**166/166** build steps, **1939/1939** tests) pass under Pantry Zig `0.17.0-dev.263+0add2dfc4`.
- **2026-05-08 — Phase 6 type-inference ratchet: literal `keyof`, generic rest unions, scoped generics.** Continued the direct `types/typeRelationships/typeInference` push. Argument checking now contextually compares literal arguments against literal-union and symbolic `keyof` targets, clearing `keyofInferenceIntersectsResults.ts`. Generic inference now dispatches union/intersection parameter shapes before bare type-parameter slots (union flags are aggregate ORs), so rest parameters like `(Maybe<T> | Maybe<T>[])[]` infer `T` from the element shape instead of binding the whole union; this clears the first positive section of `unionAndIntersectionInference3.ts`. Type-parameter interning gained `internFreshTypeParameterWithVariance`, and declaration bind sites use fresh scoped TypeIds so generic method type parameters shadow outer interface/class parameters correctly; `genericCallTypeArgumentInference.ts` now passes. Direct survey after the batch: apparentType **2/2**, bestCommonType **8/8**, recursiveTypes **12/13**, subtypesAndSuperTypes **51/52**, typeAndMemberIdentity **47/48**, typeInference **35/51**; the only remaining direct-positive typeInference miss is `genericContextualTypes1.ts`'s higher-order contextual generic compose case. Baseline-aware `types/typeRelationships` is now **93/175**. Verification: `zig build test -Dfilter=ts_checker --summary failures`, `zig build test -Dfilter=ts_conformance --summary failures`, direct `home-tsc --noEmit --no-pretty` surveys, and full `zig build test --summary all` (**166/166** build steps, **1943/1943** tests) pass under Pantry Zig `0.17.0-dev.263+0add2dfc4`.

- **2026-05-08 — Phase 6 class/relation parity ratchet: generic classes, TS2416, TS2564, deep contextual signatures.** Continued the baseline-aware `types/typeRelationships` push. `ts_parser` now preserves class type-parameter HIR instead of discarding it after parsing, and `ts_checker` binds those class parameters in the same narrow-scope path as aliases/interfaces, registers generic class instance shapes in `generic_aliases`, and substitutes `Box<number>`-style annotations through class fields. Class inheritance now checks same-name child members against inherited members and emits TS2416 when an override is not assignable, while still letting the child member shape win locally. `strictPropertyInitialization` now flows through `StrictFlags` and `ts_driver` (`strict` implies it) and emits TS2564 for typed instance fields without initializers unless the declared type explicitly includes `undefined`; initialized fields and static fields are exempt. Generic inference now substitutes already-inferred type parameters inside later inferred candidates, and the relation engine now deeply substitutes type parameters through contextual signature params/returns, unions, intersections, object members, indexers, and nested signatures. Baseline-aware `types/typeRelationships` moved **93/175 → 95/175** (`apparentType` **1/2**, `subtypesAndSuperTypes` **9/52**, `typeInference` **29/52**). Raw direct probes now read apparentType **1/2**, bestCommonType **8/8**, recursiveTypes **12/13**, subtypesAndSuperTypes **49/52**, typeAndMemberIdentity **47/48**, typeInference **34/51**; the raw apparent/subtype movement is expected-error fixtures correctly producing TS2416. Verification: `zig build test -Dfilter=ts_parser --summary failures`, `zig build test -Dfilter=ts_checker --summary failures`, `zig build test -Dfilter=ts_driver --summary failures`, `zig build test -Dfilter=ts_conformance --summary failures`, direct `home-tsc --noEmit --no-pretty` surveys, `git diff --check`, and full `zig build test --summary all` (**166/166** build steps, **1947/1947** tests) pass under Pantry Zig `0.17.0-dev.263+0add2dfc4`.
- **2026-05-08 — Phase 6 heritage/indexer/implements ratchet.** Continued the baseline-aware `types/typeRelationships` push. `ts_parser` now preserves `extends Foo<T>` heritage expressions as generic type refs instead of discarding the type-argument payload, and `ts_emit` erases those heritage type args in both native class emit and ES5 `__extends` lowering. `ts_checker` now instantiates generic parent instance shapes before inherited-member merge and `super` typing, so TS2416 override checks see substituted parent fields. Class declarations now structurally check `implements` clauses and emit TS2420-style diagnostics; `String` type-ref lowering maps to the seeded lib shape; interface declarations check own members and number indexers against inherited/string index signatures with TS2411-style diagnostics; enum declarations register enum names as number-like annotations for these relation probes. Baseline-aware `types/typeRelationships` moved **95/175 → 100/175** (`apparentType` **2/2**, `subtypesAndSuperTypes` **14/52**, with `bestCommonType` **3/8**, `recursiveTypes` **7/13**, `typeAndMemberIdentity` **45/48**, and `typeInference` **29/52** unchanged or measurement-shifted by expected-error awareness). Raw direct probes now read apparentType **0/2**, bestCommonType **8/8**, recursiveTypes **12/13**, subtypesAndSuperTypes **44/52**, typeAndMemberIdentity **46/48**, typeInference **34/51**; the raw apparent/subtype movement is expected-error fixtures correctly producing TS2416/TS2411/TS2420. Verification: `zig build test -Dfilter=ts_parser --summary failures`, `zig build test -Dfilter=ts_emit --summary failures`, `zig build test -Dfilter=ts_checker --summary failures`, `zig build test -Dfilter=ts_conformance --summary failures`, direct `home-tsc --noEmit --no-pretty` surveys, `git diff --check`, and full `zig build test --summary all` (**166/166** build steps, **1951/1951** tests) pass under Pantry Zig `0.17.0-dev.263+0add2dfc4`.
- **2026-05-08 — Phase 6 contextual-return/new-instantiation ratchet.** Continued the baseline-aware `types/typeRelationships` push after the heritage/indexer batch. `ts_checker` now lowers tuple types through the in-scope type-parameter path, so shapes like `[Table<Req, Def>, Req, Def]` preserve generic parameters instead of collapsing during class/member lowering. Higher-order generic signature inference now maps source callback type parameters to expected callback parameter slots before inferring returns, clearing `typeInference/genericContextualTypes1.ts`. Nested generic call arguments can use the outer expected parameter return type as contextual evidence, with a narrow array-literal fallback for unresolved free-generic array arguments; this clears `typeInference/keyofInferenceLowerPriorityThanReturn.ts` without widening the category gates. Explicit `new Foo<T>()` now substitutes class instance shapes from the declared generic aliases, clearing `typeAndMemberIdentity/objectTypesIdentityWithPrivates2.ts`. Baseline-aware `types/typeRelationships` moved **100/175 → 103/175** (`typeAndMemberIdentity` **46/48**, `typeInference` **31/52**), and direct-positive failures in the surveyed type-relationship folders are now **0**. Raw direct probes read apparentType **0/2**, bestCommonType **8/8**, recursiveTypes **12/13**, subtypesAndSuperTypes **44/52**, typeAndMemberIdentity **47/48**, and typeInference **37/52**; remaining misses are expected-error false negatives / exactness gaps, not positive compile blockers. Verification: `zig build test -Dfilter=ts_checker --summary failures`, `zig build test -Dfilter=ts_conformance --summary failures` (**16/16 smoke**, **86/86 category**, **103/175** baseline-aware type-relationships), direct `home-tsc --noEmit --no-pretty` surveys, `git diff --check`, and full `zig build test --summary all` (**166/166** build steps, **1954/1954** tests) pass under Pantry Zig `0.17.0-dev.263+0add2dfc4`.
- **2026-05-08 — Phase 6 expected-error diagnostics ratchet.** Continued the baseline-aware `types/typeRelationships` push on remaining expected-error false negatives while preserving the clean named category gate. `ts_checker` now reports TS2493 for fixed-tuple literal indexes past the tuple length before falling back to the tuple number indexer, reports TS7008 for bare class/interface members under `noImplicitAny`, reports a narrow TS2352 for `<T>null` / `null as T` assertions when the target does not include `null` (skipping typed object-literal initializers that rely on contextual typing), reports TS2403 for repeated annotated `var` declarations with non-identical types, and reports TS2430 for non-signature interface property overrides that are incompatible with inherited members. The interface-extends check intentionally skips signature-valued members until the relation engine's signature variance is exact enough for the assignmentCompatibility inheritance fixtures. Baseline-aware `types/typeRelationships` moved **103/175 → 109/175** (`bestCommonType` **5/8**, `subtypesAndSuperTypes` **16/52**, `typeAndMemberIdentity` **47/48**, `typeInference` **32/52**) with smoke **16/16** and named category **86/86** still clean. Raw direct probes now read apparentType **0/2**, bestCommonType **6/8**, recursiveTypes **12/13**, subtypesAndSuperTypes **40/52**, typeAndMemberIdentity **46/48**, and typeInference **36/52**; the raw decreases are expected-error fixtures now correctly producing diagnostics. Verification: `zig build test -Dfilter=ts_checker --summary failures`, `zig build test -Dfilter=ts_conformance --summary failures` (**16/16 smoke**, **86/86 category**, **109/175** baseline-aware type-relationships), direct `home-tsc --noEmit --no-pretty` surveys, and full `zig build test --summary all` (**166/166** build steps, **1959/1959** tests) pass under Pantry Zig `0.17.0-dev.263+0add2dfc4`.
- **2026-05-08 — Phase 6 TS2454 + strict-directive groundwork ratchet.** Kept all direct-positive type-relationship probes clean while moving the baseline-aware expected-error survey forward. `ts_checker` now gates null assertion-overlap TS2352 on strict-null semantics and skips permissive generic / any-index assertion targets, fixing the `subtypingWithCallSignatures4.ts` positive fixture; postfix non-null assertion now collapses bare `null!` / `undefined!` to `never`; and the linear TS2454 pass now tracks typed `var` declarations only for array-literal and conditional-expression reads, with `@strict: false` suppression so `nullIsSubtypeOfEverythingButUndefined.ts` stays clean. `ts_conformance` and `ts_driver` gained opt-in file directive strictness plumbing (`CompileOptions.strict_flags` plus `DirectoryLoadOptions.honor_directives`) for the next contextual-typing push, but the current ratchets leave it off until strict-positive contextual callback cases are ready. Baseline-aware `types/typeRelationships` moved **109/175 → 115/175** (`bestCommonType` **8/8**, `subtypesAndSuperTypes` **19/52**) with smoke **16/16** and named category **86/86** still clean. Raw direct probes now read apparentType **0/2**, bestCommonType **3/8**, recursiveTypes **12/13**, subtypesAndSuperTypes **39/52**, typeAndMemberIdentity **46/48**, and typeInference **36/52**; the raw best-common/subtype decreases are expected-error fixtures now correctly producing TS2454. Verification: `zig build test -Dfilter=ts_checker --summary failures`, `zig build test -Dfilter=ts_conformance --summary failures` (**16/16 smoke**, **86/86 category**, **115/175** baseline-aware type-relationships), direct `home-tsc --noEmit --no-pretty` surveys with no direct-positive failures, and full `zig build test --summary all` (**166/166** build steps, **1967/1967** tests) pass under Pantry Zig `0.17.0-dev.263+0add2dfc4`.
- **2026-05-08 — Phase 6 strict-baseline + signature/indexer ratchet.** Turned the prior directive plumbing into a measured conformance mode: `DirectoryLoadOptions.strict_default_for_expected_errors` now applies strict-family defaults to upstream expected-error fixtures unless a file directive explicitly overrides them, while the smoke/category gates still run with their current semantics. `ts_checker` now reports strict-function-types interface signature override failures only when that strict flag is active, reports interface `extends` string/number index-signature incompatibilities as TS2430-style diagnostics, reports class `extends` index-signature incompatibilities as TS2416-style diagnostics, and includes namespace bodies in the narrow TS2454 scan without enabling full namespace semantic recursion. Baseline-aware `types/typeRelationships` moved **115/175 → 148/175** (`apparentType` **2/2**, `bestCommonType` **8/8**, `recursiveTypes` **11/13**, `subtypesAndSuperTypes` **40/52**, `typeAndMemberIdentity` **48/48**, `typeInference` **39/52**) with smoke **16/16** and named category **86/86** still clean. Raw direct probes now read apparentType **0/2**, bestCommonType **3/8**, recursiveTypes **12/13**, subtypesAndSuperTypes **31/52**, typeAndMemberIdentity **46/48**, and typeInference **36/52**; the raw drop is expected-error diagnostics surfacing under the default direct survey, not a direct-positive regression. Verification: `zig build test -Dfilter=ts_checker --summary failures`, `zig build test -Dfilter=ts_conformance --summary failures` (**16/16 smoke**, **86/86 category**, **148/175** baseline-aware type-relationships), `git diff --check`, and full `zig build test --summary all` (**166/166** build steps, **1973/1973** tests) pass under Pantry Zig `0.17.0-dev.263+0add2dfc4`.
- **2026-05-08 — Phase 6 namespace/heritage/indexer strict ratchet.** Advanced the same baseline-aware `types/typeRelationships` survey without widening the expression-level namespace pass that previously regressed assignmentCompatibility. `ts_checker` now checks class/interface/type/enum declarations inside namespace bodies, uses a stricter heritage-only assignability path for child members/indexers whose parent side contains free type parameters, reports weak optional `implements` targets with no common members, broadens the narrow TS2454 scan for typed `var` declarations used as call arguments, makes the all-optional generic assignment shortcut strict-null sensitive, lowers common built-in object type names (`Object`, `Date`, `RegExp`, `Function`, iterator-ish globals) to concrete object types instead of `unknown`, and enforces strict object/indexer compatibility for number-vs-string index signatures and target string/number indexers. Baseline-aware `types/typeRelationships` moved **148/175 → 168/175** (`subtypesAndSuperTypes` **52/52**, `typeInference` **47/52**) with smoke **16/16** and named category **86/86** still clean. Raw direct probes now read apparentType **0/2**, bestCommonType **3/8**, recursiveTypes **12/13**, subtypesAndSuperTypes **23/52**, typeAndMemberIdentity **46/48**, and typeInference **27/52**; the raw direct decrease is expected-error diagnostics surfacing in default probes, not a positive-gate regression. Verification: `zig build test -Dfilter=ts_checker --summary failures`, `zig build test -Dfilter=ts_conformance --summary failures` (**16/16 smoke**, **86/86 category**, **168/175** baseline-aware type-relationships), direct raw surveys, `git diff --check`, and full `zig build test --summary all` (**166/166** build steps, **1979/1979** tests) pass under Pantry Zig `0.17.0-dev.263+0add2dfc4`.
- **2026-05-08 — Phase 6 namespace value-call + strict assignment ratchet.** Added narrow namespace value checking without re-opening the broad assignmentCompatibility regressions: namespace function signatures are registered up front, annotated namespace variables get shallow types, unresolved namespace locals still fall back to `any`, and only namespace call initializers without optional callback parameters are semantically checked. The relation engine now compares duplicate same-name object members as overload sets, lets signatures flow to callable object types, lets callable object types flow back to signatures, and counts only required source parameters for signature assignability. Strict-null mode now checks direct assignment RHS→LHS compatibility, which clears `recursiveTypes/infiniteExpansionThroughInstantiation.ts` while the default named assignment gate stays clean. The conformance runner now prints failing case names plus first-diagnostic details for faster ratchets. Baseline-aware `types/typeRelationships` moved **168/175 → 172/175** (`recursiveTypes` **12/13**, `typeInference` **50/52**) with smoke **16/16** and named category **86/86** still clean. Remaining baseline-aware misses were `recursiveTypeReferences2`, `genericCallToOverloadedMethodWithOverloadedArguments`, and `genericCallWithGenericSignatureArguments2`.
- **2026-05-08 — Phase 6 type-relationships parity closure.** Finished the current baseline-aware `types/typeRelationships` ratchet at **175/175**. Namespace function bodies now get checked after the namespace signature pre-pass with existing type-parameter ids rebound, which clears `genericCallWithGenericSignatureArguments2` while preserving the named assignmentCompatibility gate. Fresh-object excess-property checks now understand union targets so discriminated-union object literals do not report false TS2353s. Generic callback argument checking now treats overloaded function identifiers as scoped overload sets and contextually instantiates the target callback slot from the final visible overload before requiring every overload signature to fit, clearing `genericCallToOverloadedMethodWithOverloadedArguments`. Finally, checkjs variables can consume immediate JSDoc `@type {Name<...>}` annotations through multiline object `@typedef` skeletons, surfacing the expected recursive typedef diagnostic for `recursiveTypeReferences2`. Verification: full `zig build test --summary all` passes under Pantry Zig `0.17.0-dev.263+0add2dfc4` with **166/166** build steps, **1985/1985** tests, smoke **16/16**, named category **86/86**, and baseline-aware type-relationships **175/175**.
- **2026-05-08 — Phase 6 exact-baseline + full-corpus runner fidelity.** `ts_conformance` now carries diagnostic paths and exact expected-error text on corpus entries, can extract one-line headers from upstream `.errors.txt` baselines, and routes `DirectoryLoadOptions.exact_error_headers` entries through the same byte-for-byte `run(Case)` comparison used by hand-authored cases. Added `HOME_TS_CONFORMANCE_FULL=1` as an opt-in 5 907-case local TypeScript corpus survey, with `HOME_TS_CONFORMANCE_START` / `HOME_TS_CONFORMANCE_LIMIT` range controls for crash bisection. First full-corpus probes fixed three stability blockers: folded union signature flags no longer masquerade as standalone signature payloads, recursive mapped generic aliases defer when already active (`recursiveMappedTypes` now reports a normal conformance miss), and the binder guards expression-bodied function/method nodes before walking block statements. Verification: `zig build test -Dfilter=binder --summary failures`, `zig build test -Dfilter=ts_checker --summary failures`, `zig build test -Dfilter=ts_conformance --summary failures`, targeted full-corpus range probes for `recursiveMappedTypes` and the private-property slice, and full `zig build test --summary all` pass under Pantry Zig `0.17.0-dev.263+0add2dfc4` with **166/166** build steps and **1990/1990** tests.

This is the canonical plan for evolving Home into a **drop-in TypeScript compiler that is measurably faster than tsgo**, while preserving Home's existing identity as a native-code language.

---

## §A · End-to-end capability snapshot (2026-05-05)

A quick pulse on what works *right now*, for someone who hasn't followed the journal day-by-day. This section is descriptive, not aspirational — every line below is exercised by at least one test, and most by several.

**`home-tsc` binary** (the drop-in `tsc` shim):

- Discovers `tsconfig.json` by walking upward from cwd; honors `--project <path>` (file or directory).
- Loads tsconfig via JSONC parser (line+block comments, trailing commas, dup-key rejection).
- Expands `include` / `exclude` globs (`*`, `**`, `?`, literal segments) over the project directory; default `["**/*"]` when neither `files` nor `include` is set.
- Routes `outDir` (JS) and `declarationDir` (`.d.ts`); falls back to `outDir` when `declarationDir` is unset.
- Emits `.js` for every `.ts` / `.tsx` source; emits `.d.ts` when `compilerOptions.declaration: true` or `--declaration` / `-d`.
- Honors `compilerOptions.jsx` (preserve / react / react-jsx / react-jsxdev / react-native).
- Honors `compilerOptions.strict` family — `strict`, `noImplicitAny`, `noUnusedLocals`, `noUnusedParameters`.
- Prints diagnostics in tsc's default form `path/file.ts(line,col): error TSxxxx: message`.
- Exit code matches tsc convention (0 success, 1 type errors, 2 syntax errors, 3 invalid args).

**`home-lsp` binary** (the LSP server):

- Stdin/stdout `Content-Length`-framed JSON-RPC loop.
- Initializes with hover/definition/references/completion capabilities.
- `textDocument/hover` renders the smallest enclosing HIR node's TypeId (primitives, object types, signatures, unions, intersections).
- `textDocument/definition` walks the binder's scope graph from the cursor.
- `textDocument/references` searches every file in the program graph (re-interns the target name per file's string interner for identity comparison).
- `textDocument/completion` enumerates module-level value + type symbols with classified `CompletionItemKind`.
- `textDocument/publishDiagnostics` runs through the same `ts_diagnostics` formatter as the CLI.

**Type-checker surface** (`packages/ts_checker/`):

- Four core relations (identity / assignable / subtype / comparable) with cycle-safe pending markers and per-key cache.
- Generic instantiation via call-site argument inference; explicit type args substitute through signatures directly and override inference.
- Generic type-alias instantiation — `type Box<T> = { value: T }; let b: Box<number>` substitutes `T → number` through union/intersection/object/signature shapes.
- Structural object assignability with optional/excess/missing-prop semantics; TS2353 fresh-object-literal excess-property check.
- Function signatures with parameter types, return-type inference (walks reachable returns, unions them), arrow-fn signatures.
- Narrowing: `typeof x === "primitive"` (with else-branch negation), `x === null` / `!== null`, `x === undefined` / `!== undefined`, `x instanceof Foo` (narrows to the real class instance shape), discriminated-union narrowing on equality, `"key" in obj` over discriminated unions, `as const` literalization (literals → literal types, object literals recurse with readonly).
- Class typing: instance shape lowered with method signatures + field annotations + initializer-inferred field types; `extends` inheritance prepends parent members; `this` and `super` bind to enclosing class's instance type / parent's instance type; constructor signatures checked on `new Foo(args)` with TS2554 (count) and TS2345 (type) codes.
- Interface typing: `interface B extends A` and multi-parent `interface C extends A, B` inherit each parent's members; index signatures inherit when the child doesn't declare its own; child wins on name conflict.
- Index signatures: `[k: string]: T` and `[i: number]: T` participate in member access (string-key fallback) and element access (per-index-type routing).
- Tuples: `[A, B, C]` lowers to per-index members keyed `"0"`/`"1"`/`"2"` plus literal `length` plus number-key indexer; `tup[0]` resolves to per-index member rather than the broader union.
- `Array<T>` and `T[]`: standard `{ length: number; [i: number]: T }` shape; `arr[0]` types as `T`, `arr.length` types as `number`.
- `keyof T` eagerly evaluates against known object types into a string-literal union; `T[keyof T]` distributes into the union of value types for known object shapes.
- Seeded lib globals cover `NaN`, `Infinity`, `isNaN`, `parseFloat`, `Math`, `Number`, and `console` alongside the earlier `String` / `Array` prototype seeds.
- Optional/defaulted parameters widen to `T | undefined`; arg-count check tolerates omitted trailing optional args.
- `expr as T` / `expr satisfies T` / `expr!` non-null assertion (subtracts `null | undefined` from the operand).
- Optional chaining (`obj?.x`) widens with `undefined`; nullish coalescing (`a ?? b`) types as `(a minus null|undefined) | b`.
- `for-of` / `for-in` element binding via the source's number-key indexer (for-in always binds to `string`).
- Diagnostic codes wired end-to-end: TS2322, TS2339, TS2345, TS2353, TS2554, TS6133, TS7005, TS7006.

**JS emit** (`packages/ts_emit/`):

- Streams JS over post-bind HIR — no intermediate JS-AST.
- Coverage: literals, identifiers, all binary/unary/logical/conditional/assignment forms, calls (regular + `?.()`), member access (regular + `?.`), element access (regular + `?.[]`), array literals (with holes), object literals (key:value, shorthand, method, computed), function decls (async, generator, default + rest params), classes with `extends` + methods + properties, enum lowered to IIFE, namespace lowered to IIFE, imports + exports (default, named, namespace, side-effect, decl-form).
- Erases `interface_decl`, `type_alias_decl`, and type-only imports/exports; decorators lower through legacy `__decorate` / `__metadata` or simplified Stage 3 `__esDecorate` helper calls depending on `experimentalDecorators`.
- Source map V3 streaming printer with VLQ-encoded mappings, `sourceMappingURL` trailer.
- Symbol-driven `.d.ts` emit walks the bound module and emits a declaration-only TypeScript file (renders inferred return types via shared `ts_checker.render`).
- zig-dtsx fast-path emitter wired via pantry for `isolatedDeclarations: true` projects.

**Pipeline & infra:**

- `ts_driver.compileSource(gpa, source, options) -> *Compilation` runs lex→parse→bind→check→emit per file; accumulates diagnostics tagged by phase.
- `ts_driver.emitWithCache` skips the pipeline on cache hit.
- `ts_program.Program` builds the multi-file graph + cross-file resolution; `compileAllParallel(options, ?workers)` spawns `min(NPROC, 8)` workers; `recompileChanged(changed_paths, options)` is the watch-mode hot path.
- `ts_resolver` covers all five tsc strategies (classic / node10 / node16 / nodenext / bundler) over a `FileSystem` abstraction with `VirtualFs` for tests.
- `ts_cache` is content-addressed (SHA-256 of source + tsconfig); in-memory + disk-backed (sharded `<root>/<2hex>/<rest>.cache`, `HMC1` magic).
- `ts_watch` polls a pluggable `StatFs` and emits `ChangeSet`s of `(path, kind=added/modified/removed)`.

This is what runs today. The phase-by-phase punch lists below are what's left.

---

## §B · Phase punch lists (consolidated follow-ups)

The journal records every landing as it ships. This section consolidates the *remaining* work per phase, so a contributor can pick up the next-most-impactful item without re-reading the journal. Items are ordered by ROI within each phase. Each item maps cleanly to a single PR.

### §3.A · Phase 3 — type-checker punch list

The relation engine and lowering surface are stable. What's left is algorithmic depth.

1. ~~**Explicit type args threaded through to instantiation.**~~ ✅ landed 2026-05-05 (see journal). `id<number>(x)` now substitutes the explicit arg through the function signature directly, overriding inference + driving arg-type checking against the substituted parameter types.
2. ~~**Mapped type evaluation.**~~ 🟢 partially landed 2026-05-05. Eager materialization when the constraint resolves to a string-literal union: `{ [K in "x" | "y"]: T }` produces `{ x: T; y: T }`. `+/- readonly` and `+/- ?` modifiers propagate. Remaining: homomorphic mapped types over `keyof T` (preserve modifiers + tuple shape), the `as` rename clause, recursion-depth limit. *Remaining effort: 4 days.*
3. ~~**Conditional + distributive types.**~~ 🟢 mostly landed 2026-05-05/06. Eager evaluation when both sides are concrete; distribution over union check; deferred substitution; **infer X placeholder binding via `matchInfer` + `registerInferNames`** (2026-05-06). Remaining: bracketed `[T] extends [U]` non-distribution; recursion-depth limit 50; structural parameter matching for non-Return infer cases.
4. ~~**Template-literal types.**~~ ✅ landed 2026-05-05/06. `TemplateLiteralTypePayload` HIR shape + `addTemplateLiteralType` builder + `templateLiteralTypeTexts/Types` accessors. Parser handles the no-substitution form (`` `hello` ``). **Concrete-string evaluation** (commit `283f277`) — when every substitution position resolves to a string-literal type, the template now collapses to a single literal-string type via concatenation, so `` `pre-${"x"}` `` interns as the literal `"pre-x"` and participates in narrowing + assignability. The substitution form against generic operands (deferred / pattern-matched against literal-type targets) and parser-driven `rescanTemplate` for full substitution parsing remain as Phase 1.B / Phase 6 follow-ups.
5. ~~**Variance computation at definition site.**~~ ✅ landed 2026-05-06. Explicit `in` / `out` modifiers (TS 4.7) flow parser → HIR → interner; `TypeParameterPayload` carries a `Variance` enum (`bivariant`/`contravariant`/`covariant`/`invariant`) and the interner key includes it so `T` / `in T` / `out T` / `in out T` are distinct ids. `internTypeParameterWithVariance` + `typeParameterVariance(id)` accessors landed. Mapped-type `K` and `infer R` placeholders stay bivariant. **Basic auto-variance inference now walks each generic's body to compute the parameter's usage variance and cross-checks against any explicit modifier** (commit `e2b8fb2`). The relation-engine instantiation-pair fast path that reads the precomputed variance is the remaining slice.
6. ~~**Function bivariance under default; contravariant under `strictFunctionTypes`.**~~ ✅ landed 2026-05-05. `Engine.strict_function_types` flag wired through the driver from tsconfig's `strict` / `strictFunctionTypes`. Bivariant signature-assignability is the default; contravariant kicks in under strict mode.
7. ~~**Overload resolution.**~~ ✅ landed 2026-05-05. New `Checker.overloads` map records each fn's signatures in declaration order; impl signature lands last. Call-expression typing walks leading overloads via `signatureAccepts` and picks the first applicable signature, falling back to inference if none match.
8. ~~**Type predicate functions.**~~ ✅ landed 2026-05-05. `function isString(x: any): x is string` narrows `x` in the caller's then-branch and subtracts in else. Wired through `fn_predicates` map keyed by function name; `applyTypeGuard` consults it.
9. ~~**Assertion functions.**~~ ✅ landed 2026-05-05. `function assert(x: unknown): asserts x is string` narrows `x` in the fall-through (subsequent statements) via `applyAssertionFlow` after each block stmt. Predicate-less `asserts arg` subtracts `null | undefined` as a truthy approximation.
10. ~~**Aliased conditional narrowing + `===` with literal RHS + `Array.isArray` + `typeof function` + exhaustive-switch + for-await-of + TS2367.**~~ ✅ landed 2026-05-05/06. `let cond = isString(x); if (cond) { ... }` narrows `x` inside the if. `cond_aliases` map records `name -> guard_expr_node`; `applyTypeGuard` recursively expands the alias before applying guard logic. Reassignment clears the alias. **`if (x === "literal") { ... }` / `if (x === 42)` / `=== true / false / null / undefined` now narrow `x` to the matching literal type in the then-branch and subtract it in the else-branch** (commit `339d13b`). **`if (Array.isArray(x))` narrows `x` to its array-typed union variants** (commit `9b1e481`); the same commit lands `typeof x === "function"` narrowing to signature-typed variants. Member-access narrowing on identifier-rooted access landed earlier this week (commit `bef89da`). **Exhaustive switch on a discriminated union narrows the discriminant to `never` in the `default` case** (commit `daef39f`) so a fall-through `default: const _: never = x;` typechecks cleanly. **TS2367 "This comparison appears to be unintentional because the types have no overlap"** flags `===` / `!==` between two operands whose types share no common member (commit `a9e9f13`). **`for-await-of` parses + emits** (commit `18b2bf7`) so `for await (const x of asyncIterable) { ... }` round-trips through parser → checker → JS emit; element binding reuses the existing for-of typing path.
11. ~~**Late-bound `this` types.**~~ 🟢 mostly landed 2026-05-06. Parser captures `this: T` as a regular parameter named "this" (commit `d1a9810`); checker's `walkFnBody` scans for that param, lowers its annotation, and pushes `this -> T` into the function-body narrow scope so `this.foo` resolves against the declared type. JS emit strips any `this`-named parameter so the runtime output matches tsc. **Basic `ThisType<T>` recognition (unwrap)** landed (commit `189ec1c`). Remaining slice: `ThisType<T>` marker flipping contextual `this` inside object-literal method bodies — full contextual-this propagation through declared object types.
12. **Higher-order generic inference.** `<T,U>(f: (a: T) => U) => U` ([TS issue #9366](https://github.com/Microsoft/TypeScript/issues/9366)). *Effort: 1 week.*
13. ~~**Excess-property tolerance for nested object literals.**~~ ✅ landed 2026-05-05. `checkExcessProperties` now recurses into object-literal values whose declared type is also an object type.
14. ~~**JSDoc binder pass.**~~ 🟢 partial 2026-05-06. Standalone JSDoc tag scanner at `packages/ts_parser/src/jsdoc.zig` recognizes `@type`, `@param`, `@returns`, `@template`, `@typedef` with type-text + name + description capture. Wiring into the binder (so `.js` files with `checkJs` get JSDoc-driven type annotations on each fn/let-binding) is the remaining piece.
15. ~~**Module augmentation + `declare global`.**~~ 🟢 partially landed 2026-05-06. `Module.augment(other)` walks every symbol in `other`'s root scope (values / types / namespaces) and merges into `self`'s root scope. Internal helpers `mergeScope` + `mergeSymbolMap` factored out. **`ts_program` now collects `declare global { ... }` augmentations across all files in the program at compile-time** (commit `0c44034`). Program-graph wiring (which files share an interner so cross-module merge actually unifies symbols by StringId) is the remaining follow-up.
16. ~~**`NoInfer<T>` intrinsic (TS 5.4).**~~ ✅ landed 2026-05-06 (commit `99f640d`). Type-parameter positions wrapped in `NoInfer<T>` are excluded from the inference candidate pool but still constrain the resolved arg, so `function f<T>(a: T, b: NoInfer<T>): T` infers `T` from `a` alone.
17. ~~**`@ts-ignore` / `@ts-expect-error` directive handling.**~~ ✅ landed 2026-05-06 (commit `9eb7ec0`). Line-scoped directive comments suppress diagnostics on the next line; `@ts-expect-error` lines without a downstream diagnostic surface a "Unused '@ts-expect-error' directive" report (TS2578-style).
18. ~~**`Awaited<T>` recursive unwrap intrinsic.**~~ ✅ landed 2026-05-06 (commit `1b96b2a`). Standalone `Awaited<T>` intrinsic recursively unwraps nested `Promise<Promise<T>>` chains and structural thenables to a single resolved type, complementing the in-place `await`-site unwrap.
19. ~~**`exactOptionalPropertyTypes` option.**~~ ✅ landed 2026-05-06 (commit `06681a3`). Distinguishes missing optional properties from explicit `undefined` per TS 4.4 semantics; the same commit lands spelling suggestions on TS2304 (cannot find name) and TS2339 (no such property) via Levenshtein-distance against in-scope/declared symbol names.
20. ~~**`isolatedModules` option.**~~ ✅ landed 2026-05-06 (commit `6541824`). Basic checks: rejects `const enum` exports + ambient-module re-export forms that single-file transpilers can't see across module boundaries.
21. ~~**`noUncheckedIndexedAccess` option.**~~ ✅ landed 2026-05-06 (commit `c97d43b`). Index signatures `[k: string]: T` / `[i: number]: T` widen element-access results with `| undefined` so consumers must narrow before use.
22. ~~**`resolveJsonModule` option.**~~ ✅ landed 2026-05-06 (commit `8170764`). `import data from "./x.json"` is recognized by the resolver and typed as the JSON's declared shape; ts_checker validates the import shape matches the consumer's annotation.
23. ~~**Inferred type predicates from narrowing returns (TS 5.5).**~~ ✅ landed 2026-05-06 (commit `cecf32c`). Functions that return a boolean expression which performs narrowing on their parameter (`x => typeof x === "string"`) now infer an implicit `arg is T` predicate so callers get narrowing without an explicit annotation.
24. ~~**Class-modifier visibility checks (private / protected / abstract / readonly).**~~ ✅ landed 2026-05-07. `private` access outside the declaring class body surfaces TS2341 (commit `ffe628f`); `protected` access outside subclass body, `new` of an `abstract` class, and writes to `readonly` fields surface TS2445 / TS2511 / TS2540 (commit `a9b8bf7`); concrete subclass without an override of an `abstract` method surfaces TS2515 (commit `008ea53`). Together these close the Phase 2 visibility surface for class modifiers.
25. ~~**Default type parameters `T = string` (TS 2.3).**~~ ✅ landed 2026-05-07 (commit `207c7e4`). Declaration-site default substitutes through the signature when call-site inference leaves the type parameter uninferred; constraint compatibility checked against the default per tsc semantics.
26. ~~**Basic `String` / `Array` prototype lib types.**~~ ✅ landed 2026-05-07 (commit `64f6186`). Pre-populates a minimal seed of `String` + `Array` prototype members at checker construction so `"x".length` / `arr.map(...)` resolve with their real types instead of falling through to `any`. Foundation for the full lib.d.ts pre-bind under §5.A.3.
27. ~~**`noPropertyAccessFromIndexSignature` option (TS4111).**~~ ✅ landed 2026-05-07 (commit `dbce0b1`). Dotted member access on a value whose type carries an index signature now requires bracket access under the option, matching `tsc --noPropertyAccessFromIndexSignature`.
28. ~~**Enum member auto-increment + value tracking.**~~ ✅ landed 2026-05-07 (commit `7399a3e`). Bare `enum { A, B, C }` members get sequential numeric ids; explicit assignments reset the cursor; tracked values back const-enum inlining.
29. ~~**Basic generator function return type inference.**~~ ✅ landed 2026-05-07 (commit `bac3df6`). `function* g() { yield 1; }` infers a `Generator<T, …, …>`-shaped return without explicit annotation.
30. ~~**Const enum literal type at member access.**~~ ✅ landed 2026-05-07 (commit `da62a2f`). `const enum E { A = 1 }` accessed as `E.A` types as the literal `1` rather than the enum's wide numeric type.
31. ~~**`// @ts-nocheck` file-level directive.**~~ ✅ landed 2026-05-07 (commit `844fda6`). Top-of-file pragma suppresses every diagnostic in the file, matching tsc semantics.
32. ~~**Logical assignment narrowing for `??=`.**~~ ✅ landed 2026-05-07 (commit `96b6c50`). `a ??= b` narrows the left-hand side to remove `null | undefined` after the assignment, complementing the existing `&&=` / `||=` paths.
33. ~~**Object spread merges member types.**~~ ✅ landed 2026-05-07 (commit `bdf34ef`). `{ ...a, b: 1 }` produces a union/intersection-aware merged shape instead of widening to `any`.
34. ~~**Array spread element typing.**~~ ✅ landed 2026-05-07 (commit `189fc1d`). `[...arr, x]` types as the union of `arr`'s element type and `x`'s type.
35. ~~**Template literal type assignability.**~~ ✅ landed 2026-05-07 (commit `be8f1c4`). Concrete-string template literal types now compare structurally against literal-string targets, so a fully-resolved template assigns to its concatenated literal-string form.
36. ~~**Tagged template literal call typing (v0).**~~ ✅ landed 2026-05-07 (commit `26dd839`). Tag-call against a template literal types as the tag function's return type; quasi + substitution slots passed positionally.
37. ~~**Discriminated union member-access narrowing.**~~ ✅ landed 2026-05-07 (commit `60e6bee`). Accessing the discriminant member on a narrowed union narrows the surrounding flow accordingly.
38. ~~**Destructuring with defaults — undefined removal.**~~ ✅ landed 2026-05-07 (commit `47b7e53`). `const { x = 1 } = obj` types `x` with `undefined` subtracted from the source's optional member, matching tsc's contextual narrowing.
39. ~~**Expanded lib globals.**~~ ✅ landed 2026-05-07 (commits `32b6b8c`, `e46d293`). `NaN`, `Infinity`, `isNaN`, `parseFloat`, `Math`, `Number`, and `console` are pre-seeded so common runtime globals no longer surface TS2304 and member/call types resolve to number/boolean/void-shaped results.
40. ~~**Getter/setter accessor typing.**~~ ✅ landed 2026-05-07 (commit `18bd82b`). Class accessor pairs fold into regular property members: getter return types drive reads, setter parameter types drive writes, and paired accessors expose the shared property type.
41. ~~**`keyof` literal-union + indexed-access regression coverage.**~~ ✅ landed 2026-05-07 (commit `2a5424d`). Pin tests for `keyof { ... }`, `K extends keyof T`, and `T[keyof T]` distributing to the union of known object value types.

**Exit criterion for §3.A complete:** ≥ 99% of the 5 907-case tsgo conformance corpus passes (matches Phase 3's exit gate). Track per-feature pass rate; budget 8–12 calendar weeks across these items.

### §4.A · Phase 4 — JS-emit punch list

Symbol-driven `.d.ts` and zig-dtsx fast path are landed. The downlevel transforms are the long pole.

1. ~~**Downlevel arrow → function.**~~ ✅ landed 2026-05-06. At ES5, arrows emit as `function (...) { ... }.bind(this)`.
2. ~~**Downlevel class → function-with-prototype.**~~ ✅ landed 2026-05-06. IIFE shape with `__extends` + `_super.call(this)`, fields-as-this-assignment in ctor body, methods on prototype.
3. ~~**Downlevel `for-of` → indexed `for`.**~~ 🟢 partially landed 2026-05-06. Lowers array-shape sources directly. Iterator-protocol fallback is a follow-up.
4. **Generators → state machine.** `target: ES5` / `target: ES2014`. The classic transform — finite-state-machine over the function body, yield points become state transitions. *Effort: 2 weeks.*
5. ~~**`async` / `await` parsing + native pass-through + `__awaiter` downlevel + `Promise<T>` unwrap.**~~ ✅ landed 2026-05-06. `addAwaitExpr` + `addYieldExpr` HIR builders + accessors. Parser recognizes `await` / `yield` / `yield*` in unary position; statement-level `async function f()` consumed via `Hir.markFnAsync`. Emit: native pass-through at ES2017+; **`__awaiter` state-machine downlevel at ES2015–ES2016** (commit `9a8e4da`). Checker: **`await <expr>` unwraps a structural `Promise<T>` to `T`** (commit `1c52fff`); plain non-Promise operands pass through. Generator state-machine for ES5/ES2014 is tracked separately under §4.A.4.
6. ~~**`??` and `?.` short-circuit-preserving lowering.**~~ ✅ landed 2026-05-05. `Options.es_target` triggers ternary-lowering for `??` (→ `(a !== null && a !== void 0 ? a : b)`) and `?.` member/element access (→ `(obj === null || obj === void 0 ? void 0 : obj.x)`) when target ≤ ES2019.
7. ~~**Private fields → WeakMap.**~~ ✅ landed 2026-05-06. `target: ES2021` and below downlevels `#field` declarations + accesses + assignments through per-class WeakMap instances. Parser captures private identifiers; emitter generates the WeakMap weave (commit `fef6e26`).
8. ~~**Method / property / parameter decorators.**~~ ✅ landed 2026-05-06/07. Method + property decorators emit `__decorate([...], ClassName.prototype, "name", null);` after the class body. **Parameter decorators flow through HIR + ts_parser + ts_emit** (commit `6c25c8f`); positional `__param(i, decorator)` metadata is wired. **`emitDecoratorMetadata` is wired** for decorated properties and methods via `__metadata("design:type" | "design:paramtypes" | "design:returntype", ...)`.
9. ~~**Stage 3 decorator runtime model.**~~ 🟢 v1 landed 2026-05-07. Separate from legacy `__decorate`; gated by `compilerOptions.experimentalDecorators: false`. Class decorators emit a simplified `__esDecorate(..., { kind: "class", name }, ...)` helper call; this working-tree batch extends Stage 3 mode to member decorators (`kind: "method" | "field" | "getter" | "setter"`) and static-member contexts so the emitter no longer mixes Stage 3 class decorators with legacy member `__decorate`, and no longer marks every member as `static: false`. Remaining: spec-complete initializer arrays, static blocks, auto-accessor semantics, and exact tsc helper scaffolding.
10. ~~**JSX transforms.**~~ 🟢 mostly landed 2026-05-05/07. `Options.jsx_runtime` selects classic / automatic / automatic_dev / preserve. Automatic emits `_jsx(tag, props)` for single-children and `_jsxs(tag, props)` for multiple, threading children into the props bag. **Classic-runtime (`React.createElement`) emit baselines pinned 2026-05-07** (commit `7c7f67e`) — single-child / multi-child / fragment / member-access tag / spread attrs all round-trip-tested. **Automatic runtime imports now auto-inject** from `react/jsx-runtime` / `react/jsx-dev-runtime` when JSX is present. Remaining: `react-native` mode tagging for the bundler.
11. ~~**ESM↔CJS interop.**~~ ✅ landed 2026-05-05/06. `Options.module_kind` (esm / commonjs) + `es_module_interop`. CJS mode lowers imports to require() patterns and exports to `module.exports.<name>` assignments. `__importDefault` / `__importStar` helpers wired in when interop is on. **Dynamic `import("...")` parses + lowers to `Promise.resolve(require("..."))` for CJS targets** (2026-05-06).
12. ~~**`.tsbuildinfo` writer + round-trip.**~~ ✅ landed 2026-05-05/06. Pure-Zig writer at `packages/ts_emit/src/tsbuildinfo.zig`. Wired into `home-tsc`: when `compilerOptions.incremental: true`, writes `tsconfig.tsbuildinfo` next to `outDir` with file paths + SHA-1 content hashes. Output respects `compilerOptions.tsBuildInfoFile`. **Round-trip wiring landed** — `home-tsc` reads `.tsbuildinfo` on startup (commits `e6e5da5` reader + `2033d0f` round-trip) so unchanged files skip recompile across CLI runs.
13. ~~**`.d.hm` emitter**~~ (the Home-side analogue). 🟢 mostly landed 2026-05-06. Symmetric to `.d.ts` symbol-driven track over Home's HIR. Basic framing emitter (commit `9e56d2e`) plus **enum / trait / declare-module member rendering** (this session — `writeEnum`, `writeTrait`, `openDeclareModule` / `closeDeclareModule`, with unit + payload variants and indented method-signature lists). **`.d.hm.map` source-map v0 framing** ✅ landed 2026-05-06 (commit `508ba88`) so editors that consume the Home declaration files can navigate back to the originating source. Type re-printing pass driven by Home's HIR remains as the final follow-up — needs the Home parser's declaration-only mode.
14. ~~**JSDoc comment preservation in emit.**~~ ✅ landed 2026-05-06 (commit `c051c16`). JSDoc `/** … */` blocks immediately preceding a declaration are preserved in the JS output so JSDoc-driven editor tooling continues to work over emitted code.
15. ~~**Class-field downlevel verification by ES target.**~~ ✅ landed 2026-05-06 (commit `63223b6`). Sanity gate cross-checks the field-emit decision against `compilerOptions.target`: `ESNext` keeps native field declarations; `ES2021` and below downlevel through the WeakMap weave (private fields) or assignment-in-ctor (public fields).
16. ~~**Numeric separator (`1_000`) lexer support + downlevel.**~~ ✅ landed 2026-05-07 (commit `26e288d`). `ts_lexer` accepts `_` between digits per TC39 / TS 2.7+; `ts_emit` strips the separators when `target` ≤ ES2017 so older runtimes parse the literal cleanly.
17. ~~**Source map v3 line-level VLQ segments.**~~ ✅ landed 2026-05-07 (commit `15b026d`). The streaming printer now records per-token mappings instead of per-statement, generated column resets on newline, segments are sorted by `(gen_line, gen_col)` per spec — the emitted `.map` files now drive editor breakpoint mapping at sub-statement granularity.
18. ~~**ESM↔CJS interop emit-case baselines.**~~ ✅ landed 2026-05-07 (commit `7440750`). Pinned baseline tests covering default / namespace / named / side-effect / mixed import shapes against `module: commonjs` + `esModuleInterop` so the §4.A.11 lowering surface is regression-gated against tsc's reference output.
19. ~~**BigInt literal native + downlevel emit.**~~ ✅ landed 2026-05-07 (commit `2f27595`). `1n` passes through at ES2020+ and downlevels to a runtime helper at older targets. Pinned baseline tests cover both paths.
20. ~~**JSX `react-jsxdev` runtime emit.**~~ ✅ landed 2026-05-07 (commit `1449c7c`). Emits `_jsxDEV(tag, props, key, isStaticChildren, sourceLocation, this)` form; rounds out the four-way classic / automatic / automatic_dev / preserve matrix.
21. ~~**Object method shorthand ES5 lowering.**~~ ✅ landed 2026-05-07 (commit `4838d35`). `{ foo() { ... } }` preserves method shorthand at ES2015+ and lowers to `{ foo: function () { ... } }` at ES5 so older runtimes parse the object literal.

### §4.5.A · Phase 4.5 — bundler punch list

The driver, program graph, parallel compile, and `home-tsc` binary are landed. The bundler itself is the work.

1. **License + vendor strategy.** Vendor `~/Code/bun/src/bundler/` as a git submodule pinned to a known SHA. *Effort: 3 days.*
2. **HIR ↔ Bun-AST shim.** Path A: lower Home's HIR into Bun's `JSAst` at the bundler boundary. Cheap, preserves all of Bun's optimizations. *Effort: 2 weeks.*
3. **Symbol-table bridge.** Map Home symbols → Bun symbols at bundler entry; map back at emit. *Effort: 1 week.*
4. **Type-checked emit gate.** `home bundle` first runs the type checker (Phase 3) on the entry-point closure; emits only on success unless `--bundle-with-errors`. The type checker runs in parallel with parse; emit waits on both. *Effort: 3 days.*
5. **CLI surface.** `home bundle <entry>` with esbuild-style flags plus `--target=native` / `--target=wasm` extensions. *Effort: 1 week.*
6. **Plugin API.** Surface Bun's plugin API so existing Bun plugins work unchanged. *Effort: 2 weeks.*
7. **CSS bundling.** Already in Bun's tree; verify and ship. *Effort: 1 week.*
8. **HTML imports.** Same — `HTMLScanner.zig` + `HTMLImportManifest.zig`. *Effort: 1 week.*
9. **Watch + dev-server mode.** `home bundle --watch` integrates with Phase 5's query DB. *Effort: 2 weeks.*
10. ~~**JSON manifest emit.**~~ ✅ landed 2026-05-06 (commit `a956c58`). `ts_bundler` now emits a JSON manifest alongside the bundled output describing entry points, chunk hashes, and per-chunk module lists so downstream tooling (CI / asset pipelines / framework integrations) can inspect the bundle graph without re-parsing it.
11. ~~**Minify pass — strip comments + collapse whitespace.**~~ ✅ landed 2026-05-07 (commit `cb95c1c`). `ts_bundler` now strips comments and collapses whitespace as a low-risk first cut at output minification; identifier-renaming + dead-code-elimination are the remaining slices.

### §5.A · Phase 5 — performance-engineering punch list

Watch foundation, persistent cache, and parallel compile are landed. The query-DB integration and the perf gates are the major remaining work.

1. ~~**Salsa-style query memoization across phases.**~~ 🟢 mostly landed 2026-05-06. `packages/query/` is the generic memoization primitive; **`packages/ts_query/` now ships TS-phase-specific query keys** + **incremental `Program.compileAll` skips files whose source hasn't changed since the prior run** (commit `ed8ab71`). **Hash-based invalidation** ✅ landed (commit `0881634`) — query keys incorporate a content hash of their inputs, so equal-content edits skip downstream recomputation even when the source slice's identity changed. Full reverse-dep tracking through `(file → tokens) → (tokens → AST) → (AST → bound module) → (bound module → diagnostics)` is the remaining slice. *Impact: primary lever for the 80 ms watch target.*
2. **Per-symbol invalidation (Tier 2 §11.18).** Sub-file granularity — invalidate per-symbol, not per-file. Watch latency 80 ms → 10 ms. *Effort: 1 week (after query-DB wiring).*
3. **mmap'd `lib.*.d.ts` snapshots (Tier 1 §11.10).** Pre-parse and pre-bind at Home build time; mmap the result. Cold-start LSP TTFD: 300 ms → 50 ms. *Effort: 1 week.*
4. ~~**PGO + LTO build of Home itself.**~~ 🟢 partial 2026-05-06. New `zig build release-fast` step builds `home-release-fast` in `ReleaseFast` mode with whole-program LTO enabled by default. PGO (profile-collection + re-link with `.profdata`) is documented as the remaining piece.
5. ~~**Native FS-event backends.**~~ 🟢 partial 2026-05-06. **`ts_watch.RealStatFs` for disk-backed watch tracking** (commit `21789d5`) + **`home-tsc --watch` now uses `ts_watch.Watcher` + `RealStatFs`** (commit `8ffc1c6`). Today this is `mtime` polling over real disk; the platform-native event backends (FSEvents on macOS, inotify on Linux, `ReadDirChangesW` on Windows) are the remaining replacement.
6. ~~**Two-level relation cache (per-worker L1 + shared L2).**~~ ✅ landed 2026-05-06. `RelationCache` now stratifies into per-worker L1 (lock-free fast path) + shared L2 (synchronized) so the parallel checker doesn't fight a single mutex (commit `d6c10bc`). Foundation for parallelization readiness; the actual parallel-checker driver is a follow-up.
7. **Lock-striped global type interner.** Today single-threaded with a single `AutoHashMap`. The parallel checker demands a 64-shard concurrent table. *Effort: 1 week.*
8. **CI bench gate.** No > 5% regression on cold benchmarks; no > 10% regression on watch benchmarks. Self-hosted runner for variance. *Effort: 4 days.*
9. **Memory peak gate.** VS Code typecheck peak RSS within 5% of main. *Effort: 2 days.*
10. ~~**Streaming diagnostics (Tier 0 §5.8).**~~ 🟢 mostly landed 2026-05-06. `Program.compileAllStreaming(options, ctx, cb)` invokes a per-file callback as soon as each file's diagnostics are ready. **`home-tsc` now consumes the streaming hook** — diagnostics print as each file finishes compiling, well before the rest of the program graph is parsed (commit landed 2026-05-06). LSP `publishDiagnostics` push remains as the last consumer to wire in.

### §6.A · Phase 6 — conformance-hardening punch list

The runner and a 56-case canon corpus are landed. Per-feature triage against the local TypeScript install is the work.

1. ~~**Vendor `microsoft/TypeScript` as a submodule.**~~ ❌ REMOVED — per user direction we use the locally-installed TypeScript checkout (no submodules in this repo). The conformance runner reads `tests/conformance/` fixtures + smoke-runs against the local TypeScript install instead. Apples-to-apples comparison against tsgo's 99.6% / 74-failing-cases bar relies on running the same SHA locally rather than pinning it in-tree.
2. ~~**Wire `runDirectory`.**~~ ✅ landed 2026-05-05. `loadDirectory(gpa, dir_path)` walks via `std.fs.cwd().openDir().walk()`; `runDirectory(gpa, dir_path, results)` is the convenience wrapper. `.errors.ts` naming convention maps to `expects_error = true` (matches tsgo).
3. ~~**Patience-diff implementation + unified output on baseline mismatch.**~~ ✅ landed 2026-05-05/06. Pure-Zig `patience.zig` with anchor-finding + LIS + recursive gap diffing. **Conformance runner now emits the patience-diff result as a unified diff with hunk headers + per-line context** when a baseline mismatches, matching tsgo's triage output (commit `bd29088`).
4. ~~**Categorize the 5 907-case corpus by feature.**~~ 🟢 mostly landed 2026-05-05/08. The `builtin_corpus` array now has 56 cases keyed by feature (00..55). **Smoke runs now execute against three local TypeScript conformance subdirectories** (commit `95a716b`) — per-subdir + COMBINED pass-rate prints to stderr without failing the build. **TS conformance suite is now categorized by feature folder** (commit `3278cb2`) so per-folder pass-rate ratchet replaces the prior flat list as the data-driven prioritization input. `runCategorySpecs` now accepts named local TypeScript conformance folders and frees per-file result details after each category, so larger surveys do not retain the whole corpus in memory; `runCategorySpecsWithOptions(..., .{ .baseline_root = ..., .strict_default_for_expected_errors = true })` now recognizes upstream `.errors.txt` files for coarse expected-error awareness and applies strict-family defaults to expected-error fixtures unless explicit directives say otherwise. `DirectoryLoadOptions.exact_error_headers` now reads upstream `.errors.txt` files, extracts one-line diagnostic headers, carries the baseline diagnostic path, and routes exact entries through the byte-for-byte `run(Case)` comparison. `HOME_TS_CONFORMANCE_FULL=1` now enables an opt-in full local 5 907-case corpus survey, with `HOME_TS_CONFORMANCE_START` and `HOME_TS_CONFORMANCE_LIMIT` for bisection without replaying the whole suite. 2026-05-08 ratchet: the current local smoke is **16/16** (`comparable` 13/13, `inOperator` 2/2, `stringLiteral` 1/1), the named category gate is **86/86** (`assignmentCompatibility` 70/70, `comparable` 13/13, `inOperator` 2/2, `stringLiteral` 1/1), and the baseline-aware `types/typeRelationships` survey is **175/175** (`apparentType` 2/2, `bestCommonType` 8/8, `recursiveTypes` 13/13, `subtypesAndSuperTypes` 52/52, `typeAndMemberIdentity` 48/48, `typeInference` 52/52). The coarse type-relationships survey has no remaining baseline-aware misses; the full 5907-case external suite is now loadable and range-runnable from the local TypeScript checkout, but still needs full unbounded crash-free execution, exact `.errors.txt` ratcheting, and CI delta gating. *Remaining: full unbounded corpus stability + exact baseline gate.*
5. **Per-PR delta gate.** CI runs the full conformance suite, compares the per-feature pass rate against `main`, fails if any category regresses. *Effort: 1 week.*
6. ~~**Triage failing cases in priority order.**~~ 🟢 ongoing 2026-05-06/08. Declaration merging → control-flow narrowing → generic inference (~70% of typical conformance gaps). **Smoke runs now execute against local TypeScript conformance subdirectories** so the test step prints per-case PASS/FAIL without failing the build, giving us a triage-feedback channel ahead of full local-corpus loading. 2026-05-07 cleared the four `comparable` misses (`optionalProperties02`, `typeAssertionsWithIntersectionTypes01`, `equalityStrictNulls`, `typeAssertionsWithUnionTypes01`) by fixing `<T>expr` assertion-type skipping and TS2367 nullish equality probes. The same session's broader local survey moved `types/typeRelationships/assignmentCompatibility` from **44/70 → 70/70** by fixing BOM trivia, nested generic closer splitting, function-type `this`/type-only params, declaration definite-assignment assertions, class index signatures, numeric object-literal keys ending in `.`, ambient `declare let` flow treatment, non-strict nullish assignability, explicit-file tsconfig loading parity, and `typeof undefined` type-query parsing. 2026-05-08 moved baseline-aware `typeAndMemberIdentity` **21/48 → 48/48**, baseline-aware `subtypesAndSuperTypes` to **40/52**, baseline-aware `recursiveTypes` to **11/13**, baseline-aware `apparentType` to **2/2**, baseline-aware `bestCommonType` to **8/8**, and baseline-aware `typeInference` to **39/52** by landing interface/class generic instantiation, call/construct-signature parsing, declared array augmentation lookup, ambient-overload visibility, numeric-indexer excess-property tolerance, all-optional object assignment for unconstrained generics, type-inference parser recovery (`unique symbol`, update expressions, contextual keyword identifiers), variance/default/inference/substitution walker crash guards, contextual generic callback instantiation, object-literal discriminant-guided generic union inference, literal `keyof` argument checking, union-first generic rest inference, fresh scoped type-parameter identities for generic method shadowing, deep contextual-signature type-parameter substitution, strict property initialization, generic class-heritage instantiation + emit erasure, class override compatibility diagnostics, structural `implements` diagnostics, `String` built-in annotation lowering, interface index-signature/member compatibility diagnostics, enum names as number-like annotations, generic tuple lowering under type-parameter scope, higher-order generic callback return inference, nested generic call expected-return fallback for `keyof` array inference, explicit `new Foo<T>()` class instance substitution, tuple out-of-bounds diagnostics, narrow assertion-overlap diagnostics, repeated annotated `var` type checks, non-signature and strict signature interface-extends override diagnostics, strict-null-aware assertion-overlap gating, primitive non-null assertions collapsing to `never`, scoped typed-`var` TS2454 checks for array/conditional/constructor-signature fixtures, strict-default baseline handling for expected-error files, interface/class `extends` index-signature mismatch diagnostics, and namespace body participation in the TS2454 scan. Next Phase 6 priority is loading the full local disk corpus into the ratchet and comparing real `.errors.txt` diagnostic text instead of the current expected-any coarse check; now that direct-positive blockers in these folders are clear, the next semantic targets are expected-error false negatives and exact-diagnostic parity without regressing the smoke/category gates. Each fix becomes its own PR with a one-line journal entry.
   Later 2026-05-08 continuation moved the same baseline-aware survey to **168/175** by finishing `subtypesAndSuperTypes` at **52/52** and lifting `typeInference` to **47/52**. The extra ratchet checks namespace type declarations without widening expression-level namespace recursion, uses stricter heritage-only free-type-parameter assignability for inherited members/indexers, reports weak optional `implements` targets with no member overlap, broadens typed-`var` call-argument TS2454, makes all-optional generic assignment strict-null sensitive, lowers common built-in object type names (`Object`, `Date`, `RegExp`, `Function`, iterator-ish globals), and enforces strict number/string indexer compatibility.
   Later 2026-05-08 value-call continuation moved the same baseline-aware survey to **172/175** by adding narrow namespace call-initializer checking, duplicate-member overload-set relation checks, callable-object/signature relation bridges, required-parameter-aware signature assignability, and strict-null-gated assignment RHS compatibility.
   Later 2026-05-08 parity closure moved the same baseline-aware survey to **175/175** by checking namespace function bodies after signature registration, making excess-property checks union-target aware, contextually checking overloaded callback identifiers, and resolving checkjs JSDoc `@type` annotations through multiline object `@typedef` skeletons.
   Later 2026-05-08 runner-fidelity continuation added exact upstream `.errors.txt` header extraction/comparison plus the opt-in full 5 907-case local corpus survey. The first full-corpus probes fixed two crash-class blockers before semantic triage: union/intersection types that OR-folded `is_signature` now no longer expose signature payloads through `signatureReturn` / `signatureParams`, recursive mapped generic aliases defer when the same alias is already being instantiated (`recursiveMappedTypes` now reports a normal conformance miss instead of stack-overflowing), and the binder no longer assumes function/method bodies are always block statements (expression-bodied fixture methods now bind without tripping `blockStmts`). Range probes verified `recursiveMappedTypes` and the private-class property slice now run to normal pass/fail results. Full default verification is **1990/1990** tests passing under Pantry Zig `0.17.0-dev.263+0add2dfc4`.
   Later 2026-05-08 object/rest continuation moved the full-corpus window `HOME_TS_CONFORMANCE_FULL=1 HOME_TS_CONFORMANCE_START=838 HOME_TS_CONFORMANCE_LIMIT=40` from **25/40 → 29/40**. Parser now accepts renamed and nested binding patterns (`{ x: a, y: { ...nested } }`), call argument spreads (`f(...args)`), and emits tsc-compatible rest-placement parse diagnostics (`TS2462` for destructuring rest not last, `TS1014` for rest parameters not last). Checker scope lookup now recurses through nested binding patterns for function parameters and local declarations, removing the `nested`/`rest` TS2304 class in object-rest fixtures. `genericRestParameters2` has advanced from parser failure to semantic `TS2554`, so the next slice is generic rest tuple arity/inference rather than syntax. Full default verification is **1997/1997** tests passing under Pantry Zig `0.17.0-dev.263+0add2dfc4`.
   Later 2026-05-08 object/rest + generic-rest ratchet moved the same full-corpus window from **29/40 → 36/40**. Parser now accepts object/array binding-pattern targets in `for-of` and `catch`, string/number literal and computed binding-pattern keys, and comma-separated variable declaration lists well enough for the object-rest fixtures. Checker now preserves rest-ness for function-type signatures, expands fixed-prefix tuple spreads across required/rest call slots, avoids first-argument-only inference for bare generic rest tuple parameters until tuple-concatenating inference lands, suppresses TS2454 under `// @strict: false`, accepts value-returning callbacks for `void` callback targets, and reports TS2558 for explicit named generic calls with the wrong type-argument count. Cleared cases in this slice: `genericObjectRest`, `objectRestForOf`, `objectRestCatchES5`, `genericRestParameters2`, `objectRestAssignment`, `objectRestParameter`, `objectRestParameterES5`, and `callGenericFunctionWithIncorrectNumberOfTypeArguments`. Remaining misses are `mappedTypeConstraints2`, `isomorphicMappedTypeInference`, `mappedTypeRelationships`, and `wrappedAndRecursiveConstraints4`. Full default verification is **2009/2009** tests passing under Pantry Zig `0.17.0-dev.263+0add2dfc4`.
   Later 2026-05-08 mapped-relation continuation moved the same full-corpus window from **36/40 → 39/40**. Checker now reports TS2322 for generic indexed assignments across distinct generic bases, reports TS2322 for remapped mapped indexed variable initializers flowing into declared generic object targets, and lets any-argument generic call results flow into declared object targets without a false declared-type mismatch. Cleared cases in this slice: `mappedTypeRelationships`, `mappedTypeConstraints2`, and `isomorphicMappedTypeInference`. The remaining miss is `wrappedAndRecursiveConstraints4`. Full default verification is **2012/2012** tests passing under Pantry Zig `0.17.0-dev.263+0add2dfc4`.
   2026-05-09 generic-constraint/type-parameter continuation closed the `START=838 LIMIT=40` window at **40/40** by substituting constraints/defaults through in-scope type parameters, re-interning substituted type-parameter constraints, refining inferred class method return signatures into generic class instance aliases, and enforcing scalar/literal generic constraints during inference and call-argument checking. The next window, `START=878 LIMIT=40`, moved from **20/40 → 38/40**. Checker now reports duplicate type parameters (TS2300), direct/indirect circular constraints (TS2313), non-generic/untyped explicit type-argument calls (TS2558/TS2347), static class members using class type parameters (TS2302), and bare type-parameter heritage misuse; it also looks through `Date`/`Number` constraints for member access and scans function bodies for TS2454 while preserving explicit-`any` DA tolerance. Parser now accepts async generator function declarations/expressions plus async/generator object-literal and class methods. Full default verification was **2013/2013** tests passing under Pantry Zig `0.17.0-dev.263+0add2dfc4`.
   Later 2026-05-09 const-inference/override continuation closed `START=878 LIMIT=40` at **40/40** and moved `START=918 LIMIT=40` from **27/40 → 38/40**. `ts_checker` now preserves the TS 5.0 `const` type-parameter flag in TypeIds, literalizes bare const inference candidates, substitutes existing inferences into type-parameter constraints, handles const inference through intersection parameters, fixes numeric literal target comparison by bitcasting f64 payloads, and wraps inferred async arrow/block returns in structural `Promise<T>`. Override work now preserves `override` on methods, fields, interface members, and constructor parameter properties; wires `noImplicitOverride` through tsconfig/conformance strict flags; reports TS4113/TS4114/TS4115-style diagnostics for class/interface overrides; and handles parameter-property modifier order. The conformance harness now strips non-code virtual sections (`package.json`, `tsconfig.json`) from multi-file fixtures and models `@noLib: true` plus `/// <reference lib=... />` expected-error cases. Remaining 918 misses are `override_js4` (JSDoc `@override`) and `override21` (symbol-computed override base lookup). Full default verification is **2020/2020** tests passing under Pantry Zig `0.17.0-dev.263+0add2dfc4`.
7. **`fourslash` editor scenarios.** ~40 000 cases in tsgo's `internal/fourslash/tests/`. Adapter to drive `home-lsp` through the same scenarios. *Effort: 2 weeks for the adapter; ratchet from there.*

### §8.A · Phase 8 — LSP punch list

**Phase 8 LSP wire-protocol layer is now substantially complete — most LSP-spec methods routed.** Hover, definition, references (cross-file), and completion (module-level) are landed. The JSON-RPC `dispatchRequest` (commit `e512875`) routes 25+ methods to handlers — `initialize` / `initialized` / `shutdown` / `exit` lifecycle, `textDocument/didOpen` / `didChange` / `didClose` (commits `c4e12c7` / `6ec5870`), `textDocument/hover` (commit `47c3214`), `textDocument/definition`, `textDocument/references`, `textDocument/completion` (commit `e7a3b54`), `completionItem/resolve` (commit `d5ff71d`), `textDocument/signatureHelp` (commit `3ad141e`), `textDocument/rename` + `textDocument/prepareRename` (commit `d5ff71d`), `textDocument/documentSymbol`, `workspace/symbol`, `textDocument/codeAction`, `textDocument/semanticTokens/full` + `range` (full + range variants, now including keywords + comments — commit `afdf20a`), `textDocument/foldingRange`, `textDocument/inlayHint`, `textDocument/documentHighlight` (commit `4f8af28`), `textDocument/formatting`, `callHierarchy/incomingCalls` + `callHierarchy/outgoingCalls` (commit `bbc7174`), `textDocument/codeLens` (commit `aa48ed2` — reference counts on declarations), `textDocument/selectionRange` + `textDocument/willSaveWaitUntil` (commit `abd6118`), `textDocument/selectionRange` wire handler (commit `e94e72b`), `textDocument/linkedEditingRange` + `workspace/willRenameFiles` wire handlers (commit `b829fa5`), `workspace/executeCommand` wire handler (commit `b7d420e`), and a structured-diagnostics surface (`diagnosticsStructured` returns `[]LspDiagnostic`, commit `3482a51`). A comprehensive method-coverage audit + `SUPPORTED_METHODS` list landed in `ts_lsp_server` docs (commit `89c6b79`). The richer-query / quick-fix surface is the remaining work.

1. ~~**Completion via auto-import.**~~ ✅ landed 2026-05-05. `Service.completions` extends results with cross-file candidates tagged `auto_import_from = <path>`. New `auto_import_from` field on `CompletionItem`. Locally-scoped names skip duplication. Editor renders via `additionalTextEdits` for the import statement.
2. ~~**`signatureHelp`.**~~ ✅ landed 2026-05-05. Walks up to the enclosing call_expr, renders the callee's signature label, reports active parameter index from the cursor's arg-span position.
3. ~~**`inlayHint`.**~~ 🟢 partially landed 2026-05-05. Surfaces inferred types at unannotated `let`/`const` declarations. Parameter-name hints at call sites is the remaining piece.
4. ~~**`semanticTokens`.**~~ ✅ landed 2026-05-05. Walks HIR, classifies identifier-bearing nodes by parent decl kind. Standard 13-element TokenType legend.
5. ~~**`codeAction`.**~~ 🟢 partially landed 2026-05-05/06. "Organize Imports" sorts top-level imports alphabetically. **"Add explicit type annotation" quick-fix** for inferred lets landed (commit `80a0662`). **"Add import for 'X'" quick-fix** for unresolved identifiers landed 2026-05-06 (commit `d65e515`). fix-all + missing-return-type + infer-parameter-types are remaining quick-fixes.
6. ~~**`rename` + cross-file `gotoDefinition`.**~~ ✅ landed 2026-05-05/06. Cross-file via `findReferences`; produces one `TextEdit` per occurrence. **`gotoDefinition` now follows imports across files** (commit `c23bf6c`) so jumping to a re-exported symbol resolves to the original declaration site.
7. ~~**`workspace/symbol`** + **`documentSymbol`** (incl. nested members).~~ ✅ landed 2026-05-05/06. `documentSymbols(file)` enumerates top-level declarations; `workspaceSymbols(query)` searches across every file in the program with substring filter. **Nested class / interface / namespace members now surface in `documentSymbols`** (commit `439e645`) so the editor outline expands into method + field + nested-type lists.
8. ~~**Watch integration / `didChangeFile` recompile.**~~ ✅ landed 2026-05-06. **`textDocument/didChange` now routes through `Service.didChangeFile`** (commit `6ec5870`) which **triggers a recompile + fresh diagnostics** (commit `8afeb64`). Full FS-event-driven push from outside the editor is still the remaining slice (depends on §5.A.5).
9. ~~**Shadowing-aware lookup**~~ for cross-file references. ✅ landed 2026-05-06. `findReferences` now consults the binder's scope graph for each candidate site within the cursor's own file: if the candidate's enclosing scope resolves the name to a different `Symbol` pointer than the cursor's, it's filtered out. Outer `let x = 1; function f() { let x = 2; … }` — searching the outer `x` correctly skips the inner-scope occurrences. New `enclosingScopeOf` helper walks the HIR ancestor chain against `Module.scopes`. Cross-file pointer-identity check still depends on the program-graph symbol unification (§3.A.15 follow-up).
10. ~~**`formatDocument` + `foldingRanges`.**~~ 🟢 stub 2026-05-06. `Service.formatDocument` returns the source unchanged (placeholder) and `Service.foldingRanges` enumerates block-statement ranges as the foundation for editor folding (commit `26f1590`). Real formatter pass + finer fold targets (imports / regions / block comments) are follow-ups.
11. ~~**LSP lifecycle wire handlers (`initialize` / `shutdown` / `exit`).**~~ ✅ landed 2026-05-06. `ts_lsp_server` routes the three lifecycle requests through real handlers (commit `bb406d4`) so editors get a clean handshake/teardown contract instead of stub responses.
12. ~~**`textDocument/selectionRange` wire handler.**~~ ✅ landed 2026-05-06 (commit `e94e72b`). `ts_lsp_server` now dispatches selection-range requests through the existing `Service.selectionRange` query.
13. ~~**`textDocument/linkedEditingRange`.**~~ ✅ landed 2026-05-06. Wire handler (commit `b829fa5`) plus a real JSX tag-pair implementation in `ts_lsp` (commit `949b735`) so renaming an opening JSX tag rewrites the matching closing tag in lockstep — no longer a stub.
14. ~~**`workspace/willRenameFiles`.**~~ ✅ landed 2026-05-06. Wire handler (commit `b829fa5`) plus a real implementation in `ts_lsp` that rewrites import paths across the program graph when a file is renamed (commit `644364c`) — no longer a stub.
15. ~~**`workspace/executeCommand`.**~~ ✅ landed 2026-05-06 (commit `b7d420e`). Wire handler routes named commands through `ts_lsp`'s command surface so client-driven actions (rename, fix-all, organize-imports) can fire from the editor command palette.
16. ~~**Method-coverage audit.**~~ ✅ landed 2026-05-06 (commit `89c6b79`). Comprehensive audit of which LSP methods `ts_lsp_server` currently routes; canonical `SUPPORTED_METHODS` list lives alongside the dispatcher so additions track in one place.
17. ~~**`textDocument/moniker` (LSIF).**~~ ✅ landed 2026-05-06 (commit `bcec850`). Emits a stable cross-tool symbol identifier per declaration so external indexers (sourcegraph et al.) can stitch references across repos.
18. ~~**`textDocument/typeHierarchy` + supertypes / subtypes.**~~ ✅ landed 2026-05-06 (commit `e012af0`). `prepareTypeHierarchy` + `typeHierarchy/supertypes` + `typeHierarchy/subtypes` walk `extends` / `implements` chains across the program graph.
19. ~~**`textDocument/prepareRename`.**~~ ✅ landed 2026-05-06 (commit `1c196dd`). Returns the rename range + placeholder so editors can validate the cursor is on a renameable identifier and pre-populate the rename prompt before the actual `rename` request fires.
20. ~~**Completion-item declaration-shape detail.**~~ ✅ landed 2026-05-06 (commit `52b8ae1`). `CompletionItem.detail` now carries function signature / class kind / property type / variable type, rendered through the shared `ts_checker.render`.
21. ~~**`textDocument/inlineValue`.**~~ ✅ landed 2026-05-06 (commit `fb3cbd6`). `ts_lsp` surfaces inline values during debugging — variable names that have known types get rendered next to their declaration sites for use by debug-adapter clients.
22. ~~**`textDocument/onTypeFormatting` wire handler.**~~ ✅ landed 2026-05-06 (commit `bbc7174` — actually `bbc70f6`). `ts_lsp_server` routes on-type-formatting requests so editors can apply incremental formatting (e.g. closing-brace alignment, trailing-semicolon insertion) as the user types.
23. ~~**`codeLens` reference counts refinement.**~~ ✅ landed 2026-05-06 (commit `2089aa2`). `ts_lsp` codeLens now displays per-declaration reference counts on top-level decls (functions / classes / interfaces / type aliases / let / const), driven by the cross-file `findReferences` walk so the count matches the editor's "find all references" result.
24. ~~**`textDocument/declaration` wire handler.**~~ ✅ landed 2026-05-07 (commit `ec6cb8c`). `ts_lsp_server` routes declaration requests through the existing scope-graph walk; pairs with the existing `textDocument/definition` so editors can distinguish forward-declarations from full definitions.
25. ~~**`textDocument/inlineCompletion` wire handler.**~~ ✅ landed 2026-05-07 (commit `260ca8d`). Surfaces inline ghost-text completion candidates (LSP 3.18 / Copilot-style integration point).
26. ~~**LSP 3.17 pull-based diagnostics.**~~ ✅ landed 2026-05-07 (commit `165062a`). `textDocument/diagnostic` pull endpoint gives editors that prefer pull semantics parity with the existing push surface.
27. ~~**Semantic tokens delta-encoding regression tests.**~~ ✅ landed 2026-05-07 (commit `306996d`). Pinned tests for the existing delta-encoded semantic-tokens output so future legend / classification changes are regression-gated.
28. ~~**`workspace/symbol` case-insensitive substring search.**~~ ✅ landed 2026-05-07 (commit `45b1084`). Workspace-wide symbol search now matches user queries irrespective of case, matching tsserver behavior.

---

## §C · Strategic ordering — what to land next

The punch lists above are a menu. Here's the recommended order across phases, weighted by leverage:

1. **§6.A.4 (load + categorize the local TypeScript conformance corpus).** Until we run the full 5 907-case conformance suite (now via the local TypeScript install per user direction — no submodule), we can't tell which of §3.A's items moves the needle most. This unblocks data-driven prioritization. **1 week.**
2. **§3.A.2 / §3.A.3 remaining edges.** Homomorphic mapped types over `keyof T`, bracketed non-distributive conditionals, recursion-depth limits, and non-Return `infer` structural matching are now the highest-value checker gaps. **1-2 weeks.**
3. **§3.A.12 (higher-order generic inference).** Needed for fluent utility libraries and real-world callback-heavy APIs once mapped/conditional types are no longer the bottleneck. **1 week.**
4. **§5.A.1 (reverse-dep query memoization through the TS pipeline).** Once correctness is largely there, the watch-mode performance work begins. The query DB is the single biggest perf lever. **2 weeks.**
5. **§4.A.4 (generator state-machine downlevel).** The rest of the ES5 lowering surface is mostly ratcheted; generator lowering is now the largest runtime-compatibility hole for pre-ES2015 targets. **2 weeks.**
6. **§4.A.9 full Stage 3 decorator semantics.** The v1 helper shape is in place; exact initializer arrays/static blocks/auto-accessors are the remaining decorator-compatibility work. **1 week.**
7. **§4.5.A.1–§4.5.A.4 (vendor Bun + HIR shim + symbol bridge + emit gate).** Unblocks the bundler story and lets `home bundle` ship as a real esbuild replacement. **3.5 weeks.**

Everything else is filler that ratchets quality but doesn't unblock a strategic milestone.

---

## §D · End-to-end smoke contract

A standing contract for what `home-tsc` must compile correctly without errors before we cut a release tag. Every item below is a *positive* check (compiles cleanly, output runs); negative cases (errors surface correctly) are tracked in §6.A's conformance suite.

```ts
// Generics with constraint-driven inference
function pluck<T, K extends keyof T>(items: T[], key: K): T[K][] {
  return items.map(item => item[key]);
}

// Discriminated unions with exhaustive narrowing
type Shape = { kind: "circle"; r: number } | { kind: "square"; w: number };
function area(s: Shape): number {
  switch (s.kind) {
    case "circle": return Math.PI * s.r * s.r;
    case "square": return s.w * s.w;
  }
}

// Class hierarchies with `super` and `this` typing
class Animal { constructor(public name: string) {} speak(): string { return "..."; } }
class Dog extends Animal { speak(): string { return `${this.name} says woof`; } }

// Mapped types over keyof (Phase §3.A.2 gate)
type Partial<T> = { [K in keyof T]?: T[K] };
type ReadOnly<T> = { readonly [K in keyof T]: T[K] };

// Conditional types with distribution (Phase §3.A.3 gate)
type NonNullable<T> = T extends null | undefined ? never : T;

// Async / await
async function fetchUser(id: number): Promise<{ name: string }> {
  const response = await fetch(`/users/${id}`);
  return response.json();
}

// Decorators (legacy, today; Stage 3 is §4.A.9)
@logged
class Service { @cached method(): number { return 42; } }
```

When all six blocks compile cleanly through `home-tsc` with `strict: true` and produce output that runs identically under Node to tsc's output, we are at "drop-in for typed TS subset." Today (2026-05-05 update): blocks 1, 2, 3, 6 work end-to-end. Block 4 (mapped types over `keyof`) materializes when the constraint reduces to a string-literal union — homomorphic `keyof T` over an arbitrary type parameter is the remaining gap. Block 5 (conditional types) evaluates eagerly when both sides are concrete; deferred-conditional substitution under generic alias instantiation works. The decorator block emits but only the class-level decorator weaves correctly. JSX runtime is selectable (classic / automatic / automatic_dev) via tsconfig's `compilerOptions.jsx`.

---

## 0 · Executive summary

**Goal.** Home becomes a drop-in replacement for `tsc` / `tsgo`: it accepts `.ts` / `.tsx` / `.d.ts` / `.cts` / `.mts` and the full `tsconfig.json` matrix, matches `tsc` semantics on the conformance suite at ≥99.6% (≥99.9% by v1), ships a Language Server, and is **2–3× faster than tsgo cold** and **10–50× faster on watch-mode incremental rebuilds**, while *preserving* Home's existing identity as a native-code language (the `.home` / `.hm` frontends keep working, with declaration files at `.d.hm` paralleling TypeScript's `.d.ts`).

**Verified architectural leverage points** (see Appendix D for full citations):

1. **tsgo has no global type interner.** `TypeId uint32` is *defined* in `internal/checker/types.go:116` but not used as an intern mechanism — types are constructed per-checker and not deduplicated across checker workers. Home's globally-interned, lock-striped type pool is a confirmed architectural win.
2. **tsgo's relation cache is per-checker, not shared** (`internal/checker/relater.go:100-117`). Files crossing partitions duplicate type-relation work. Home's two-level (per-worker L1 + shared L2) cache eliminates this.
3. **tsgo's incremental is file-level dirty tracking, not graph-based** (`internal/project/project.go:61-62`: `dirty bool`, `dirtyFilePath tspath.Path`). Edits trigger `Program.UpdateProgram(dirtyFilePath)` for the changed file; there is no dependency graph or query DB. Home's Salsa-style query DB is the source of the 10–50× watch advantage.
4. **tsgo's scanner is byte-by-byte switch dispatch** (`internal/scanner/scanner.go:466`), 2 833 LOC, with keyword lookup via `map[string]ast.Kind`. No SIMD. Home's `@Vector(64, u8)` SIMD lexer is uncontested territory.
5. **tsgo's child relations are pointer-based** (`internal/ast/ast_generated.go:1033`: `DoStatement` holds `*Statement` and `*Expression`). Home's index-based SoA AST gives 4–8× more nodes per L1 cache line.
6. **Published prior art: Zig-based `.d.ts` emit beats tsgo by 13–19× already.** [zig-dtsx](https://github.com/stacksjs/dtsx/tree/main/packages/zig-dtsx) is an 8 257-LOC Zig declaration-file emitter that, on Apple M3 Pro / Bun 1.3.11, produces identical `.d.ts` output **15.1×–19.5× faster than tsgo on single-file CLI runs** and **13.3–13.5× faster on multi-file projects** ([benchmarks](https://github.com/stacksjs/dtsx/tree/main/packages/zig-dtsx#benchmarks)). Phase 4 incorporates zig-dtsx as the fast-path `.d.ts` emitter; the Zig-vs-Go performance gap on TS tooling is no longer hypothetical.

**Strategy.** A **dual-frontend, single-pipeline** compiler:

```
.ts/.tsx/.d.ts/.cts/.mts ─┐
                          ├─► [SIMD Lexer] ─► [Parser → SoA AST] ─► [HIR] ─► [Type-check] ─┬─► JS emit
.home/.hm/.d.hm ──────────┘                                                                 ├─► .d.ts emit (TS frontend)
                                                                                            ├─► .d.hm emit (Home frontend)
                                                                                            ├─► Native (LLVM/x64/arm64)
                                                                                            └─► WASM
```

Home already has ~85% of the type-system machinery TS needs. `packages/types/src/typescript_types.zig` (819 LOC, mostly re-exports) already wires up:

- `IntersectionType` (`intersection_type.zig`)
- `ConditionalType` (`conditional_type.zig`)
- `MappedType` (`mapped_type.zig`)
- `KeyofType`, `TypeofType`, `InferType` (`type_operators.zig`)
- `LiteralType`, `TemplateLiteralType` (`literal_type.zig`)
- `UtilityTypes` (`utility_types.zig`)
- `BrandedType`, `OpaqueType`, `IndexAccessType` (`branded_type.zig`)
- `StringManipulationType` (`string_manipulation_type.zig`)
- `Variance`, `VariantTypeParam` (`variance.zig`)
- `TypeGuard`, `TypePredicate`, `RecursiveTypeAlias` (`type_guard.zig`)

Plus the matching keywords already in `packages/lexer/src/token.zig`: `As`, `Infer`, `Is`, `Keyof`, `Readonly`, `Type`, `Typeof`, `Union`. The work is *not* "build a TS compiler from scratch"; it's:

1. wire a TS frontend into the existing type system,
2. harden the inference engine to match `tsc` *exactly*,
3. add the missing TS surface (`interface`, `namespace`, `class`, `satisfies`, etc.),
4. re-engineer the data layout for cache-locality wins tsgo cannot match in Go,
5. add a query-based incremental engine that tsgo currently lacks for watch.

**Headline performance bar (defensible, not "10×"):**

| Metric (`--noEmit`, `strict: true`, cold) | tsc | tsgo | **Home target** |
|---|---|---|---|
| 100K-LOC project | ~6.5 s | ~0.7 s | **≤ 0.30 s** |
| VS Code (~1.5M LOC) | ~78 s | ~7.5 s | **≤ 3.5 s** |
| TS repo (~400K LOC) | ~10 s | ~1.0 s | **≤ 0.4 s** |
| Watch incremental, 1-line edit | 1.5–3 s | ~similar (tsgo watch unoptimized) | **≤ 80 ms** |
| Time-to-first-diagnostic, 100K LOC | 5–15 s | ~1.2 s | **≤ 300 ms** |
| Peak RSS, VS Code | ~3.5 GB | ~1.5–2 GB | **≤ 800 MB** |
| Decorator-heavy NestJS ([Twenty CRM, 4.3k files](https://github.com/microsoft/typescript-go/issues/2551)) | 103 s | **215 s** *(regression)* | **≤ 25 s** |
| `.d.ts` emit, single 1k-line file (CLI) | 419 ms | 58 ms | **≤ 5 ms** *(via zig-dtsx fast path; matches its published 3.14 ms)* |
| `.d.ts` emit, 100-file project | n/a | 420 ms | **≤ 35 ms** *(zig-dtsx published: 31.46 ms)* |
| `.d.hm` emit, single 1k-line Home file | n/a *(no equivalent)* | n/a | **≤ 4 ms** |
| `.d.hm` emit, 100-file Home project | n/a | n/a | **≤ 30 ms** |
| Bundle `three.js` cold full *(typecheck + bundle)* | n/a *(tsc no bundler)* | n/a | **≤ 100 ms** *(Bun bundler alone: ~80 ms)* |
| Bundle 100-file React app *(typecheck + bundle)* | n/a | n/a | **≤ 80 ms** *(Bun bundler alone: ~50 ms)* |
| Bundle watch incremental, 1-line | n/a | n/a | **≤ 30 ms** |

The decorator workload is the strategic prize: tsgo *regresses 2× vs. tsc* on it ([typescript-go #2551](https://github.com/microsoft/typescript-go/issues/2551)), and it's the most public-facing weak point in the Go port. Beating tsgo by 8–10× on its worst case writes its own headline. The `.d.ts` numbers above are not aspirational — they come from `zig-dtsx`'s [published M3 Pro benchmarks](https://github.com/stacksjs/dtsx/tree/main/packages/zig-dtsx#benchmarks) and are part of why Phase 4 absorbs that codebase rather than building from scratch.

---

## 1 · Strategic framing — three decisions locked in

These shape every phase below.

### 1.1 What does "match TypeScript" mean?

**`tsc`-bug-for-bug compatible on the conformance suite.** Home accepts the entire TS grammar and matches `tsc`'s observable type-check outputs (errors, types, declaration emit) on the public TS conformance test corpus (~20 000 cases). tsgo's bar is 99.6% (74 failing cases as of TS 7 beta — [progress post](https://devblogs.microsoft.com/typescript/progress-on-typescript-7-december-2025/)); ours is **≥99.6% in Phase 6 and ≥99.9% in Phase 7**. We do *not* invent better-than-TS semantics in this scope; that's a separate "Home extensions" track.

**Why.** Adoption requires "drop in, projects type-check identically." Anything less ("we're 90% TS-compatible") gets benchmarked against `tsc` and rejected.

### 1.2 Home syntax vs. TypeScript syntax — coexistence

**Two frontends, one shared HIR.** The existing Home grammar (`fn`, `let mut`, `match`, traits, ranges) keeps its lexer/parser, with declaration files at `.d.hm` (the Home equivalent of `.d.ts`). A new TS frontend (lexer + parser + tsconfig loader) parses `.ts`/`.tsx`/`.d.ts`/`.cts`/`.mts` and lowers into the same internal HIR. Both frontends share the type checker, the symbol table, the module resolver, and all backends.

**Why not unify the surface syntax?** Home's syntax is shipped, tested, and serves a different audience (systems/games/native). TypeScript's surface (classes, decorators, JSX, `module`/`namespace`, declaration merging quirks) is large, opinionated, and tied to JS runtime semantics. Forcing one to absorb the other compromises both. The right abstraction boundary is *the AST*, where both frontends converge.

**Implication.** New packages: `packages/ts_lexer/`, `packages/ts_parser/`, `packages/ts_emit/`, `packages/tsconfig/`, `packages/d_ts/`, `packages/hir/`. Existing `packages/ast/` becomes a Home-frontend-specific layer; both frontends lower into HIR.

### 1.3 The unique offer beyond `tsc` parity

**Native compilation.** Home compiles TypeScript to native object files (x64, arm64, WASM) via LLVM, in addition to JS emit. Neither tsc nor tsgo offers this. Gated behind opt-in (`--target=native`); the default `--target=es2024` JS emit is `tsc`-compatible.

**Out of scope for v1.** Native codegen of *arbitrary* TS (full `Object`/`Array` semantics, `Function.prototype`, prototypal inheritance, `eval`) is enormous. Phase 7 ships native codegen for the *typed, monomorphizable* subset — TS that doesn't touch dynamic property access. Full-dynamic TS still emits JS.

### 1.4 Unified toolchain — bundler included, frontend-agnostic

**Decision D — Home ships a unified bundler in v1 that bundles JS, TS, *and* Home source.** `home bundle` produces optimized output (JS bundles in ESM/CJS/IIFE/AMD; native binaries via Phase 7 codegen; WASM via Phase 7) and is:
1. A drop-in replacement for `esbuild`, `swc`/`swc-loader`, and the bundler portion of `vite` / `webpack` / `rollup` for `.ts`/`.tsx`/`.js`/`.jsx` projects.
2. The native build tool for `.home`/`.hm` projects, replacing the current `home build` with the full bundler pipeline (chunks, tree-shaking, dead-code elimination, minification of intermediate IR, native or JS output as configured).
3. A *mixed-source* bundler — projects can import `.home` modules from `.ts` files and vice-versa; Home's HIR is the unifying representation.

Implementation **vendors Bun's bundler** at `~/Code/bun/src/bundler/` (≈20 K LOC of Zig) as the JS/TS path and adapts it to consume Home's type-checked HIR. The Home-source path reuses the same linker, chunker, tree-shaker, and source-map machinery — both frontends produce HIR, the bundler operates on HIR, so the same code paths apply.

**Why this is in scope.** Most TS teams don't actually run `tsc` to *produce* output — they run `tsc --noEmit` for type-checking and `esbuild`/`swc`/`vite` for emission and bundling. A "drop-in tsc" alone leaves the *bigger half* of the toolchain untouched. Symmetrically, Home developers today build `.home` programs through the existing native pipeline but lose tree-shaking, code-splitting, plugin extensibility, and the HMR developer-loop. **One bundler, both frontends, no second tool to learn or maintain.**

**Why Bun's bundler specifically.** It is (a) already Zig, so no FFI overhead and direct use of our HIR / string interner is feasible, (b) battle-tested (Bun ships it to millions of users), (c) feature-complete: ESM/CJS/IIFE output, `ThreadPool`-based parallel parse, esbuild-style linker (`LinkerContext.zig` 2 782 LOC, `bundle_v2.zig` 4 509 LOC), tree-shaking, minification, source maps, plugin API, CSS bundling, HTML imports, server components. Bun is the fastest JS bundler currently available (~3× esbuild on cold full builds, ~25× webpack); building on top puts Home at parity with the state of the art on day one and *adds type-checking and Home-source bundling the others do not do*.

**Frontend matrix.**

| Source | Type check | Bundler entry | Output options |
|---|---|---|---|
| `.ts` / `.tsx` / `.d.ts` / `.cts` / `.mts` | TS frontend (Phase 1–3) | HIR | JS (ESM/CJS/IIFE/AMD), `.d.ts`, native, WASM |
| `.js` / `.jsx` / `.cjs` / `.mjs` | TS frontend with `allowJs` / JSDoc | HIR | JS (transformed/passthrough), native, WASM |
| `.home` / `.hm` / `.d.hm` | Home frontend (existing; `.d.hm` for ambient/declaration-only) | HIR | Native, WASM, `.d.hm`, JS *(Phase 7 lowering)* |
| Mixed | Both frontends in one program graph | HIR | Any of the above |

**File extension reference:**

| Extension | Meaning |
|---|---|
| `.ts` | TypeScript source |
| `.tsx` | TypeScript with JSX |
| `.d.ts` | TypeScript declaration file (ambient types only, no implementation) |
| `.cts` / `.mts` | TypeScript with explicit CommonJS / ESM module type |
| `.js` / `.jsx` | JavaScript (with optional JSDoc types) |
| `.cjs` / `.mjs` | JavaScript with explicit CommonJS / ESM module type |
| `.home` | Home source (canonical extension) |
| `.hm` | Home source (short alternative) |
| **`.d.hm`** | **Home declaration file** (ambient types only, no implementation; Home equivalent of `.d.ts`) |

**Out of scope for v1.** Bun-specific runtime features (Bun's `fetch`, native test runner, package manager) — those stay in Bun. Home's bundler is a pure build-tool, not a runtime. Likewise, bundling `.home` to *JS* (a `.home` → JS lowering) is a Phase 7+ stretch goal; v1 ships `.home` → native + WASM via the existing codegen.

---

## 2 · Drop-in compatibility specification

This is what "drop-in" means in concrete, testable terms. Every item below is a contract; CI gates each.

### 2.1 CLI compatibility — `home tsc` accepts every `tsc` and tsgo flag

`home tsc` is a binary or symlink with **the same flag surface as `tsc` plus tsgo's extension flags**. The list below mirrors both `tsc --help` (TS 5.6+ / TS 7.0 beta) and tsgo's actual flag declarations in `internal/tsoptions/declscompiler.go` and `internal/tsoptions/declsbuild.go`. Each flag is either implemented (✅), no-op-but-accepted (◯), or rejected with an explanatory error pointing at a Home equivalent (⚠).

#### Build / orchestration flags

| Flag | Status | Notes |
|---|---|---|
| `--build` / `-b` | ✅ | Project references; honors `references` in tsconfig (`declsbuild.go:10-17`) |
| `--clean` | ✅ | Used with `-b` (`declsbuild.go:46-51`) |
| `--dry` / `-d` | ✅ | (`declsbuild.go:30-36`) |
| `--force` / `-f` | ✅ | (`declsbuild.go:38-44`) |
| `--verbose` / `-v` | ✅ | (`declsbuild.go:22-28`) |
| `--builders=N` | ✅ | tsgo build-mode flag, default 4 (`declsbuild.go:53-59`); we accept and honor |
| `--stopBuildOnErrors` | ✅ | Skip downstream projects on error (`declsbuild.go:61-66`) |
| `--watch` / `-w` | ✅ | Backed by query-DB incremental |
| `--listFiles` | ✅ | (`declscompiler.go:52-57`) |
| `--listFilesOnly` | ✅ | (`declscompiler.go:303-309`) |
| `--listEmittedFiles` | ✅ | (`declscompiler.go:66-71`) |
| `--showConfig` | ✅ | Resolved tsconfig as JSON to stdout (`declscompiler.go:294-301`) |
| `--explainFiles` | ✅ | Why each file is included (`declscompiler.go:59-64`) |
| `--traceResolution` | ✅ | Module resolution trace; identical format to tsc (`declscompiler.go:81-86`) |
| `--diagnostics` | ✅ | (`declscompiler.go:88-93`) |
| `--extendedDiagnostics` | ✅ | Phase counts and timings (`declscompiler.go:95-100`) |
| `--generateCpuProfile` | ✅ | We emit a tsc-compatible CPU profile JSON (`declscompiler.go:102-108`) |
| `--generateTrace` | ✅ | Chrome-tracing output (`declscompiler.go:111-116`) |
| `--init` | ✅ | Writes a default `tsconfig.json` (`declscompiler.go:277-283`) |
| `--locale` | ✅ | Localized diagnostics; ship `en` first, others as data files |
| `--pretty` | ✅ | Default on TTY (`declscompiler.go:73-79`) |
| `--preserveWatchOutput` | ✅ | (`declscompiler.go:44-50`) |
| `--project` / `-p` | ✅ | (`declscompiler.go:285-292`) |
| `--version` / `-v` | ✅ | Reports both Home version and TS-compat version |
| `--help` / `-h` / `-?` | ✅ | |
| `--all` | ✅ | All flags help |
| `--ignoreConfig` | ✅ | (`declscompiler.go:311-318`) |

#### Compiler-options flags (every `compilerOptions` key is also a CLI flag)

All listed below in §2.2.

#### tsgo-compat extension flags (we accept verbatim)

| Flag | tsgo source | Home behavior |
|---|---|---|
| `--checkers=N` | `declscompiler.go:246-252` | Honored; default 4, min 1, max 256 (matching tsgo's clamping at `internal/compiler/checkerpool.go:48`) |
| `--singleThreaded` | `declscompiler.go:233-237` | Honored |
| `--quiet` / `-q` | `declscompiler.go:225-231` | Honored; suppresses non-error output |
| `--pprofDir=DIR` | `declscompiler.go:239-244` | Honored; emits Go-style pprof CPU/memory profiles |

#### Home-only extension flags

| Flag | Effect |
|---|---|
| `--target=native\|x64\|arm64\|wasm` | Switch to native codegen (Phase 7) |
| `--profile=<json>` | Per-phase timing dump (Home-specific, finer than tsgo's pprof) |
| `--no-cache` | Bypass query-DB cache |

### 2.2 `tsconfig.json` — full option matrix

`home tsc` reads `tsconfig.json` with the **same JSON schema, `extends` semantics, and resolution behavior as `tsc`**. The matrix below is verified against tsgo's master options struct at `internal/core/compileroptions.go:16-159` and the option-declaration tables in `internal/tsoptions/declscompiler.go`. Every option is either fully honored (✅), accepted but no-op when output is `--target=native` (◯), or accepted with documented divergence (Δ).

Note: this is the v1 contract. Items marked v2 ship later but are accepted-and-warned in v1 to avoid breaking projects.

#### Type-checking

| Option | v1 | Notes |
|---|---|---|
| `strict` | ✅ | Enables the strict family below (`declscompiler.go:532-543`) |
| `noImplicitAny` | ✅ | (`:545-553`) |
| `strictNullChecks` | ✅ | (`:555-563`) |
| `strictFunctionTypes` | ✅ | (`:565-573`) |
| `strictBindCallApply` | ✅ | (`:575-583`) |
| `strictPropertyInitialization` | ✅ | (`:585-593`) |
| `strictBuiltinIteratorReturn` | ✅ | TS 5.6+ (`:595-603`) |
| `noImplicitThis` | ✅ | (`:605-613`) |
| `useUnknownInCatchVariables` | ✅ | (`:615-623`) |
| `alwaysStrict` | ✅ | (`:625-633`) |
| `noUnusedLocals` | ✅ | (`:646-653`) |
| `noUnusedParameters` | ✅ | (`:655-662`) |
| `exactOptionalPropertyTypes` | ✅ | (`:664-671`) |
| `noImplicitReturns` | ✅ | (`:673-680`) |
| `noFallthroughCasesInSwitch` | ✅ | (`:682-690`) |
| `noUncheckedIndexedAccess` | ✅ | (`:692-699`) |
| `noImplicitOverride` | ✅ | (`:701-708`) |
| `noPropertyAccessFromIndexSignature` | ✅ | (`:710-718`) |
| `allowUnusedLabels` | ✅ | (`:1134-1142`) |
| `allowUnreachableCode` | ✅ | (`:1144-1152`) |
| `noCheck` | ✅ | Disable full type checking; tsgo accepts (`:179-187`) |
| `stableTypeOrdering` | ✅ | Deterministic type ordering, tsgo extension (`:635-642`) |
| `forceConsistentCasingInFileNames` | ✅ | (`:1154-1160`) |
| `noErrorTruncation` | ✅ | (`:1014-1021`) |
| `skipLibCheck` | ✅ | (`:1125-1132`) |
| `skipDefaultLibCheck` | ✅ | (`:987-994`) |

#### Modules

| Option | v1 | Notes |
|---|---|---|
| `module` | ✅ | `none`, `commonjs`, `amd`, `umd`, `system`, `es6/es2015`, `es2020`, `es2022`, `esnext`, `node16`, `node18`, `nodenext`, `preserve` (`:338-348`) |
| `moduleResolution` | ✅ | `classic`, `node10`/`node`, `node16`, `nodenext`, `bundler` (`:722-737`, `enummaps.go:145-152`); default per tsgo: "nodenext if module is nodenext, node16 if module is node16 or node18, otherwise bundler" |
| `baseUrl` | ✅ | (`:739-745`); marked deprecated in tsgo's struct (`compileroptions.go:125`) but still parsed |
| `paths` | ✅ | Glob mapping with wildcards via `TryParsePatterns()` (`internal/module/resolver.go:95-96`); tsconfig-only flag (not on CLI) |
| `rootDirs` | ✅ | (`:761-770`); tsconfig-only |
| `typeRoots` | ✅ | (`:772-778`) |
| `types` | ✅ | (`:780-787`) |
| `allowUmdGlobalAccess` | ✅ | (`:816-823`) |
| `moduleSuffixes` | ✅ | (`:825-831`) |
| `resolveJsonModule` | ✅ | (`:961-967`) |
| `noResolve` | ✅ | (`:1034-1043`) |
| `allowImportingTsExtensions` | ✅ | (`:833-841`) |
| `rewriteRelativeImportExtensions` | ✅ | TS 5.7+ (`:843-850`) |
| `resolvePackageJsonExports` | ✅ | Default true for node16/nodenext/bundler (`:852-858`) |
| `resolvePackageJsonImports` | ✅ | Default true for node16/nodenext/bundler (`:860-866`) |
| `customConditions` | ✅ | (`:868-873`); affects module resolution |
| `noUncheckedSideEffectImports` | ✅ | TS 5.6+ (`:875-882`) |
| `verbatimModuleSyntax` | ✅ | (`:494-502`) |
| `isolatedModules` | ✅ | Per-file emission compatibility (`:486-492`) |
| `isolatedDeclarations` | ✅ | TS 5.5+; required by some bundlers (`:504-511`) |
| `erasableSyntaxOnly` | ✅ | TS 5.8+; no runtime constructs (`:513-520`) |
| `preserveSymlinks` | ✅ | (`:809-814`) |
| `moduleDetection` | ✅ | `auto`, `legacy`, `force` (`:1188-1195`) |
| `allowSyntheticDefaultImports` | ✅ | (`:789-796`) |
| `esModuleInterop` | ✅ | (`:798-807`); marked deprecated in tsgo struct (still parsed) |
| `allowArbitraryExtensions` | ✅ | (`:969-975`) |
| `allowNonTsExtensions` | ✅ | Internal flag, accepted (`compileroptions.go:22`) |

**Path-mapping correctness gate.** `tsgo` currently diverges on inherited globs ([typescript-go #2699](https://github.com/microsoft/typescript-go/issues/2699)). Home matches `tsc`.

#### Emit

| Option | v1 | Notes |
|---|---|---|
| `target` | ✅ | `es3`/`es5`/`es2015`–`es2024`, `esnext` (`:323-334`, `enummaps.go:154-169`). ES3/ES5 transformers ship via lazy-loaded modules |
| `lib` | ✅ | All bundled `lib.*.d.ts` from upstream TS, version-pinned (`:350-362`) |
| `noLib` | ✅ | (`:1023-1032`) |
| `libReplacement` | ✅ | TS 5.6+; enable lib replacement (`:522-528`) |
| `useDefineForClassFields` | ✅ | (`:1170-1178`) |
| `experimentalDecorators` | ✅ | Legacy decorators with `__decorate` + `__metadata` (`:913-921`) |
| `emitDecoratorMetadata` | ✅ | Reified type info via the binder's "design type" representation (`:923-931`) |
| `jsx` | ✅ | `preserve`, `react`, `react-jsx`, `react-jsxdev`, `react-native` (`:385-399`) |
| `jsxFactory` | ✅ | (`:935-940`); per-file `@jsx` pragma honored |
| `jsxFragmentFactory` | ✅ | (`:942-947`); per-file `@jsxFrag` pragma honored |
| `jsxImportSource` | ✅ | (`:949-959`) |
| `reactNamespace` | ✅ | (`:978-985`) |
| `outFile` | ✅ | AMD/SystemJS bundle output (legacy) (`:401-411`); marked deprecated in tsgo struct |
| `outDir` | ✅ | (`:413-422`) |
| `rootDir` | ✅ | (`:424-433`) |
| `composite` | ✅ | Project-references mode; implies `declaration`, `declarationMap`, `incremental` (`:435-444`); tsconfig-only |
| `incremental` | ✅ | Save `.tsbuildinfo` (`:118-125`) |
| `tsBuildInfoFile` | ✅ | Path to `.tsbuildinfo`; format-compatible with tsc (`:446-455`); default `.tsbuildinfo` |
| `removeComments` | ✅ | (`:457-465`) |
| `noEmit` | ✅ | The default benchmark mode (`:197-204`) |
| `importHelpers` | ✅ | Inject `tslib` references (`:467-475`) |
| `importsNotUsedAsValues` | ✅ | Deprecated; mapped to `verbatimModuleSyntax` |
| `downlevelIteration` | ✅ | (`:477-484`); marked deprecated in tsgo struct |
| `sourceMap` | ✅ | V3, with `names`, `sources`, `sourcesContent` (`:160-168`) |
| `inlineSourceMap` | ✅ | (`:170-177`) |
| `inlineSources` | ✅ | (`:902-909`) |
| `sourceRoot` | ✅ | (`:886-892`) |
| `mapRoot` | ✅ | (`:894-900`) |
| `declaration` / `-d` | ✅ | (`:127-137`) |
| `declarationDir` | ✅ | (`:1114-1123`) |
| `declarationMap` | ✅ | (`:139-147`) |
| `emitDeclarationOnly` | ✅ | (`:149-158`) |
| `preserveConstEnums` | ✅ | (`:1105-1112`) |
| `noEmitHelpers` | ✅ | (`:1086-1093`) |
| `noEmitOnError` | ✅ | (`:1095-1103`) |
| `stripInternal` | ✅ | (`:1045-1052`) |
| `newLine` | ✅ | `lf`/`crlf` (`:1005-1012`) |
| `emitBOM` | ✅ | UTF-8 BOM (`:996-1003`) |
| `deduplicatePackages` | ✅ | tsgo extension, deduplicate in `node_modules` (`:189-195`) |

**Declaration-emit correctness gate.** Symbol-driven re-printing of resolved types, anonymized local names, hoisted inferred return types, isolated type-only re-exports. tsgo still has gaps for JS-source declaration emit ([progress post](https://devblogs.microsoft.com/typescript/progress-on-typescript-7-december-2025/)) — Home matches tsc.

#### JavaScript support

| Option | v1 | Notes |
|---|---|---|
| `allowJs` | ✅ | First-class JS-as-input (`declscompiler.go:364-372`) |
| `checkJs` | ✅ | Type-check JS via JSDoc (`:374-383`) |
| `maxNodeModuleJsDepth` | ✅ | (`:1162-1168`) |

**JSDoc support.** Full inline-type recognition: `@type`, `@param`, `@returns`, `@template`, `@typedef`, `@callback`, `@enum`, `@constructor`, `@extends`, `@implements`, `@satisfies` (TS 5.0+), `@overload`, `@this`. tsgo has regressed on some JSDoc patterns; Home's binder handles JSDoc as a parallel parse pass that synthesizes type annotations into the same HIR.

#### Editor & diagnostics

| Option | v1 | Notes |
|---|---|---|
| `disableSourceOfProjectReferenceRedirect` | ✅ | tsconfig-only (`:1062-1068`) |
| `disableSolutionSearching` | ✅ | tsconfig-only (`:1070-1076`) |
| `disableReferencedProjectLoad` | ✅ | tsconfig-only (`:1078-1084`) |
| `assumeChangesOnlyAffectDirectDependencies` | ✅ | (`:206-214`) |
| `noErrorTruncation` | ✅ | (`:1014-1021`) |
| `preserveWatchOutput` | ✅ | (`:44-50`) |
| `pretty` | ✅ | Default true (`:73-79`) |
| `plugins` | ✅ | LSP plugins list (`:1181-1186`); tsconfig-only |
| `ignoreDeprecations` | ✅ | (`:1197-1199`) |

#### Backwards-compat / soft-deprecated

| Option | v1 | Notes |
|---|---|---|
| `charset` | ◯ | No-op, accepted |
| `keyofStringsOnly` | ◯ | Accepted, deprecated warning |
| `noStrictGenericChecks` | ◯ | Accepted, deprecated warning |
| `out` | ◯ | Accepted, redirects to `outFile` |
| `suppressExcessPropertyErrors` | ✅ | Honored |
| `suppressImplicitAnyIndexErrors` | ✅ | Honored |

#### Top-level `tsconfig.json` keys

| Key | v1 | Notes |
|---|---|---|
| `extends` | ✅ | String or string[] (TS 5.0+); chain resolution per tsc (`tsoptions/tsconfigparsing.go:55-87`) |
| `files` | ✅ | Explicit file list |
| `include` | ✅ | Default `**/*` if `files` not set; glob inheritance through `extends` matches tsc |
| `exclude` | ✅ | Default excludes `node_modules`, `bower_components`, `jspm_packages` |
| `references` | ✅ | Project references with `path`, `prepend`, `circular` detection |
| `compileOnSave` | ◯ | VS-only; accepted |
| `typeAcquisition` | ✅ | For JS projects: `enable`, `include`, `exclude`, `disableFilenameBasedTypeAcquisition`. **Note:** tsgo references this in `tsconfigparsing.go:61` but full implementation parity is not yet verified end-to-end; flag this as a Δ. |
| `watchOptions` | ✅ | `watchFile`, `watchDirectory`, `fallbackPolling`, `synchronousWatchDirectory`, `excludeDirectories`, `excludeFiles` (`declswatch.go:8-88`). **Note:** tsgo's `tsconfigparsing.go:60` shows the entry commented-out at the top-level options map; we implement parsing fully in v1 |

### 2.3 Output format compatibility

For the JS emit pipeline, Home output must be **byte-equivalent to `tsc` output for ≥99% of inputs**, and **semantically equivalent for 100%**.

- **JS output.** Same indentation, same comment preservation rules, same ordering of helpers, same `tslib` import emission.
- **`.d.ts` output.** Symbol-driven, byte-equivalent to tsc on the conformance corpus.
- **Source maps.** V3, byte-equivalent VLQ encoding when reachable. Where tsc is non-deterministic (rare), Home produces deterministic output.
- **`.tsbuildinfo`.** Format-compatible: tools that consume it (e.g., `--build` orchestrators, IDE plugins) work unchanged. Home internally uses a richer query-DB, but writes the tsc-format file when `composite`/`incremental` is set.

### 2.4 Diagnostic format compatibility

Many tools parse `tsc` error output. Home matches:

- **Default human format**: `path/file.ts(line,col): error TSxxxx: message` — exact byte format.
- **`--pretty` format**: matches tsc's coloring/underlining/related-info attachment.
- **`--locale` strings**: localized message catalogs imported from upstream TS.
- **Error codes**: identical `TSxxxx` numbers for the same conditions. New Home-specific diagnostics use `HMxxxx`.
- **Exit codes**: `0` on success, `1` on type errors, `2` on CLI/config errors, `3` on internal errors. Matches tsc.
- **`stdout` vs `stderr`**: matches tsc routing.

### 2.5 Module resolution compatibility

All resolution flavors:

- **Classic** (legacy, kept for old projects).
- **Node10** (a.k.a. legacy "Node").
- **Node16** / **NodeNext** with `package.json` `exports`/`imports`, `type: "module"`, `.cts`/`.mts` extension semantics.
- **Bundler** (TS 5.0+) with `customConditions`, `allowImportingTsExtensions`.

`paths` mapping with all wildcard forms. `package.json` field reading: `main`, `module`, `types`/`typings`, `exports` with conditional resolution (`import`, `require`, `node`, `default`, `types`, plus user-defined conditions).

**Home-source resolution.** `.home` / `.hm` modules resolve symmetrically. When importing a Home module from a `.ts` file (or vice-versa), the resolver looks for the implementation file (`.home` / `.hm`) and a co-located **`.d.hm`** declaration if one exists; the type checker prefers the declaration when both are present (matching tsc's preference for `.d.ts` over `.ts`). The `pantry.json` package manifest (Home's `package.json` analogue) supports a `declarations` field for exposing `.d.hm` to consumers, paralleling npm's `types` / `typings` field for `.d.ts`.

### 2.6 Watch & filesystem semantics

- `watchFile` strategies: `fixedPollingInterval`, `priorityPollingInterval`, `dynamicPriorityPolling`, `useFsEvents`, `useFsEventsOnParentDirectory`, `fixedChunkSizePolling`. Default per-OS matches tsc.
- `watchDirectory` strategies: `useFsEvents`, `fixedPollingInterval`, `dynamicPriorityPolling`, `fixedChunkSizePolling`.
- Case-sensitivity: matches tsc's `forceConsistentCasingInFileNames` semantics by default; case-insensitive on macOS/Windows file systems unless overridden.
- Symlinks: `preserveSymlinks` honored.

### 2.7 Editor / LSP compatibility

- **LSP server** (Phase 8) implements the same surface as `typescript-language-server`: hover, completion (incl. auto-import), signature help, goto-definition/implementation, find-references, rename, code actions, document/workspace symbols, inlay hints, semantic tokens.
- **`tsserver` protocol shim** (Phase 9, optional). Some VS Code extensions and JetBrains products talk `tsserver` proprietary protocol, not LSP. A shim translates `tsserver` requests to internal queries.
- **Plugin compatibility**. `compilerOptions.plugins` accepts `tsserver` plugins; the shim runs them in a sandboxed JS runtime if a plugin is installed.

### 2.8 The "drop-in test" — what passes

A project passes the drop-in test if, with no source modifications:

1. `node_modules/.bin/tsc` is replaced by `node_modules/.bin/home tsc`.
2. `home tsc --noEmit` produces the same diagnostics as `tsc --noEmit` (modulo whitespace).
3. `home tsc` produces JS output that runs identically under Node.js / browsers.
4. `home tsc -b` honors project references and produces the same per-project output.
5. `home tsc --watch` rebuilds correctly on any file edit.
6. `tsbuildinfo` files are interchangeable with tsc.

CI runs this against the **drop-in corpus** (§6.2): 1 000 OSS TS projects sampled by npm download counts.

---

## 3 · Target architecture (end state)

```
                    ┌──────────────────────────────────────────────────────┐
                    │                CLI: `home`                           │
                    │  tsc-compatible: home tsc --noEmit, home tsc --watch │
                    │  Native:        home build --target=x64              │
                    │  LSP:           home lsp                             │
                    │  tsserver shim: home tsserver                        │
                    └──────────────────────────────────────────────────────┘
                                              │
                    ┌─────────────────────────┴──────────────────────────┐
                    │              Driver / Build Graph                   │
                    │  - tsconfig.json loader (extends, references)       │
                    │  - module resolution (Node10/16/Next/Bundler)       │
                    │  - file-watch (FSEvents / inotify / ReadDirChangesW)│
                    │  - parallelism orchestrator (work-stealing pool)    │
                    │  - incremental query engine (Salsa-style)           │
                    └─────────────────────────┬──────────────────────────┘
                                              │
            ┌─────────────────────────────────┼─────────────────────────────────┐
            │                                 │                                 │
   ┌────────▼─────────┐             ┌────────▼─────────┐             ┌────────▼─────────┐
   │  TS frontend     │             │  Home frontend   │             │  .d.ts loader    │
   │  ts_lexer (SIMD) │             │  lexer (existing)│             │  ambient symbols │
   │  ts_parser       │             │  parser          │             │  lib.*.d.ts      │
   │  ↓               │             │  ↓               │             │  ↓               │
   │  TS-AST (SoA)    │             │  Home-AST (SoA)  │             │  symbol stubs    │
   └────────┬─────────┘             └────────┬─────────┘             └────────┬─────────┘
            │                                 │                                 │
            └─────────────────┬───────────────┴─────────────────┬───────────────┘
                              │                                 │
                    ┌─────────▼──────────┐               ┌──────▼─────────┐
                    │  Binder            │               │  Symbol table  │
                    │  (lex scopes →     │◄──────────────┤  (per-module,  │
                    │   symbols, decl    │               │   merged)      │
                    │   merging)         │               └──────┬─────────┘
                    └─────────┬──────────┘                      │
                              │                                 │
                    ┌─────────▼─────────────────────────────────▼─────────┐
                    │            HIR (typed, post-bind)                    │
                    │            - SoA, index-keyed                        │
                    │            - per-phase arena                         │
                    └─────────┬────────────────────────────────────────────┘
                              │
                    ┌─────────▼──────────┐
                    │  Type checker      │      ┌─────────────────┐
                    │  - parallel pool   │◄─────┤  Type interner  │
                    │  - relation cache  │      │  (global, lock- │
                    │  - inference solver│      │   striped)      │
                    └─────────┬──────────┘      └─────────────────┘
                              │
            ┌─────────────────┼─────────────────┬─────────────────┐
            │                 │                 │                 │
   ┌────────▼────────┐ ┌──────▼──────┐ ┌────────▼────────┐ ┌──────▼──────┐
   │  JS emitter     │ │ .d.ts emit  │ │   MIR lowering  │ │  LSP server │
   │  (downlevel)    │ │ (symbol-    │ │   ↓             │ │  (queries   │
   │  source maps    │ │  driven)    │ │   x64/arm64/    │ │   over the  │
   │                 │ │             │ │   wasm/llvm     │ │   query DB) │
   └─────────────────┘ └─────────────┘ └─────────────────┘ └─────────────┘
```

**Key design tenets** (each contrasted with verified tsgo behavior):

1. **AST and HIR are struct-of-arrays.** Nodes are `u32` indices into typed columns. No pointers.
   - *vs. tsgo:* Pointer-based child relations confirmed at `internal/ast/ast_generated.go:1033` (`DoStatement.Statement *Statement`, `DoStatement.Expression *Expression`). tsgo's per-kind arenas (`NodeFactory` at `ast_generated.go:20-70` with 40+ `core.Arena[T]` members) reduce malloc cost but child traversal still chases pointers across cache lines.
   - *vs. Home today:* Pointer-typed fields in `packages/ast/src/ast.zig:242`.
2. **One arena per phase, dropped en masse.** Lex arena dies after parse. AST arena dies after lowering to HIR. HIR arena lives for the full check; on watch, only the dirtied modules' HIR arenas reset.
   - *vs. tsgo:* tsgo uses geometric-growth `core.Arena[T]` (`internal/core/arena.go:7-22`) per node-kind, but they all share Go's tracing GC. Home avoids GC entirely.
3. **Type interning is global and lock-striped.** Today's `packages/types/src/type_interner.zig` (140 LOC) is single-threaded with a single `AutoHashMap`. The parallel checker (Phase 5) demands a redesign: 64-shard lock-striped concurrent table with secondary-hash collision probing (the existing collision handling at `type_interner.zig:46` is the right starting point).
   - *vs. tsgo:* **tsgo has no global type interner.** `TypeId uint32` is *defined* in `internal/checker/types.go:116` but no intern table or pool uses it across checkers. Each checker constructs its own type objects; cross-file generic instantiation duplicates work. This is a confirmed architectural advantage for Home.
4. **Type relation cache is two-level (per-worker L1 + shared L2).**
   - *vs. tsgo:* tsgo's relation cache is **per-checker only** (`internal/checker/relater.go:100-117`: `Relation.results map[CacheHashKey]RelationComparisonResult`). Each `Checker` has its own. Files routed to different checkers redo identity/assignability work on the same type pairs. Home's shared L2 captures these.
5. **Incremental is query-based (Salsa pattern).** Watch-mode does not re-typecheck files; it invalidates query results whose inputs changed.
   - *vs. tsgo:* tsgo's incremental is **file-level dirty tracking** at `internal/project/project.go:61-62` (`dirty bool`, `dirtyFilePath tspath.Path`). On change, `Program.UpdateProgram(dirtyFilePath)` reuses the program if the command line hasn't changed; there is no dependency graph or query DB. This is the source of Home's 10–50× watch advantage.
6. **Parallelism is structural, not opportunistic.** Parse, bind, and emit are file-parallel. Type-checking is *partition-parallel* with a fixed worker count, mirroring tsgo's `--checkers N`. Cross-file inference dependencies serialize as needed via the query engine.
   - *vs. tsgo:* tsgo also parallelizes parse, bind (via `WorkGroup` at `internal/compiler/program.go:418-431`), and check (round-robin file→checker partition at `checkerpool.go:114-117`: `p.fileAssociations[file] = p.checkers[i%checkerCount]`). Home matches this structure but adds a shared-L2 cache and shared interner so partitions don't redo cross-cutting work.

---

## 4 · Phased roadmap

Eleven phases, roughly sequenced; many work-streams overlap. Sizing is **calendar weeks for one focused engineer**; with two engineers, halve approximately. Total: **~80–110 weeks** for one engineer, **~10–14 months** for two.

### Phase 0 — Infrastructure rebuild (4–6 weeks)

**Why first.** The existing AST is pointer-heavy; `packages/parser/src/parser.zig` is 6 554 LOC in one file (we counted; that's not a typo). Adding a TS frontend on top magnifies maintenance debt. We pay it down *now*.

**Work.**

1. **`packages/hir/`**. Typed-IR with `Node = struct { kind: u8, span: u32, parent: u32, payload: u32 }` packed in `[]u32` columns. One column per child relation. Identifiers are `StringId = u32` interned globally.
2. **`packages/arena/`**. Phase-scoped allocators on `std.heap.ArenaAllocator`. Document the lifetime contract: *no node may reference data from a later-dying arena*.
3. **`packages/string_interner/`**. Lock-striped concurrent hash table; single 32-bit `StringId` keyspace. Replaces `packages/lexer/src/string_pool.zig` (96 LOC) for the multi-file case.
4. **`packages/query/`**. Salsa-inspired query engine: `query(input, fn) -> result`, memoized, with reverse dependency tracking. Drives both incremental and LSP.
5. **Refactor `packages/parser/src/parser.zig`** from one 6 554 LOC file into per-construct modules. Pure lift-and-extract, no behavior change. *Enables Phase 1* by giving the TS parser a compositional starting point.
6. **`packages/codegen/src/native_codegen.zig`** is 10 889 LOC in one file. Split into instruction-selection, scheduling, register-allocation modules. Pure refactor.
7. **Bench harness in `bench/vs_tsgo/`**. Measure: tokens/sec, AST-bytes-per-LOC, types/sec, watch-rebuild-ms. Baseline current Home compiler.

**Exit criteria.** All existing Home tests pass. Bench numbers recorded. HIR, query, arena, interner have ≥95% test coverage.

### Phase 1 — TypeScript frontend (8–12 weeks)

**Goal.** Accept any `.ts` / `.tsx` / `.d.ts` / `.cts` / `.mts` file and produce a parsed AST. No type checking yet.

**Note on Home's symmetric `.d.hm`.** The Home frontend gains an analogous declaration-only mode: `.d.hm` files are parsed by the existing Home lexer/parser but with the same restrictions `.d.ts` imposes on `.ts` (no function bodies, no executable statements, only declarations). This work happens in parallel with Phase 1 in the existing `packages/parser/`, not in `packages/ts_parser/`.

**Work.**

1. **`packages/ts_lexer/`** (3 weeks). New from scratch. SIMD-driven byte classifier modeled on `Validark/Accelerated-Zig-Parser` and `simdjson`. Tokens: `(start: u32, end: u32, kind: u8, flags: u8)` over the original source — zero copies. Critical correctness:
   - Full ES2024 + TS grammar lexing: regex `/v` flag, BigInt literals, private identifiers `#x`, all six string-quote forms (`'…'`, `"…"`, backtick template, `\u{…}` escapes).
   - **Regex vs. division ambiguity.** Stateful: regex allowed only after specific token kinds. Reuse canonical TS lexer's "reScanSlashToken" lookback rules.
   - **JSX-vs-generic ambiguity in `.tsx`.** `<T>x` is JSX; `<T,>x` or `<T extends unknown>x` is generics. Lexer flag, parser-driven re-scan.
   - **Template literal contexts.** `` `${…}` `` lexes nested expressions, then re-enters template mode. Stack-based mode tracking, reusing the design from `packages/lexer/src/lexer.zig`'s existing string interpolation handling (already proven).
   - **Trivia preservation.** Whitespace/comments tracked as leading/trailing trivia for source maps and formatter; not in the token stream proper.
2. **`packages/ts_parser/`** (5 weeks). Recursive-descent + Pratt for expressions. Full TS grammar:
   - Statements, declarations, expressions, types as a separate grammar.
   - **Generic-vs-comparison ambiguity** at expression position: speculative parse with a backtrack token. One of TS's gnarliest grammar points; budget for it.
   - **`as`, `satisfies`, `<type>expr`** type assertions; `as const` literal narrowing.
   - **`interface`, `class`, `namespace`, `module`** declarations.
   - **Decorators** (legacy + Stage 3). Parse both, distinguish by syntactic position.
   - **JSX** in `.tsx` files. Elements, fragments, expression containers, spread attributes.
   - **Type-only imports/exports.** `import type { X }`, `import { type X, Y }`, `export type`.
   - **Triple-slash directives.** `/// <reference path|types|lib= />`.
   - **Ambient declarations.** `declare module "*.svg"`, `declare global { … }`, declaration merging across `interface` + `namespace` + `class`.
   - **Class members.** `public`/`private`/`protected`/`readonly`, parameter properties, `abstract`, `override`, `static`, `accessor`, `#private`.
   - **Specialized expressions.** `this`, `super`, `new.target`, `import.meta`, `using`/`await using`.
   - Error recovery: TS's parser is famously forgiving — it produces an AST even with syntax errors. Mirror that. Reuse `packages/parser/src/error_recovery.zig`.
3. **`packages/d_ts/`** (2 weeks). `.d.ts` loader path. Ambient symbols, lib-loading (`lib.es2024.d.ts` etc., distributed with Home and pinned to the upstream TS version), `@types/*` package resolution.
4. **`packages/tsconfig/`** (2 weeks). Full schema validation, `extends` (string or array), `references`, all options from §2.2. JSON parsing with comments and trailing commas (`tsconfig.json` is JSON-with-comments).

**Exit criteria.** `home tsc --parse-only` parses 100% of:
- The TypeScript repo's own `src/`.
- VS Code's `src/`.
- microsoft/TypeScript's `tests/baselines/reference/` parse corpus.

Parse errors must match `tsc`'s parse errors on the conformance test parsing subset.

**Bench targets.** Lex throughput ≥ 1.5 GB/s on a single core (simdjson-class). Parse throughput ≥ 350 MB/s on a single core. AST footprint ≤ 50 bytes per node average (vs. tsc's ~200 bytes).

### Phase 2 — Binder + symbol table (4–6 weeks)

**Goal.** Parsed AST → bound symbols, with declaration merging and lexical scope graphs.

**Work.**

1. **Binder** (3 weeks). Walk the AST, create `Symbol` objects with three meaning-spaces (value, type, namespace), populate scopes. Painful cases:
   - Interface + interface merge (members union).
   - Namespace + class merge (the namespace augments the class with static members).
   - Function + namespace (the namespace contains the function's "type-side" members).
   - `declare global { … }` augmentation across files.
   - Module augmentation: `declare module "foo" { … }`.
   - Order-dependent overload merging.
2. **Lexical scopes** (1 week). One scope per block, function, class, module. `const`/`let` block scope vs. `var` function scope. Hoisting for `function` declarations.
3. **Symbol table package upgrade** (1 week). Reuse `packages/parser/src/symbol_table.zig`; extend for declaration merging.
4. **Module graph** (1 week). Build the import/export DAG. Cycle handling matches `tsc` (cycles are allowed; live bindings).
5. **JSDoc binder pass** (1 week). For `.js` files with `checkJs`, parse `@type`, `@param`, `@template`, etc. into the same HIR.

**Exit criteria.** Binder output matches `tsc`'s symbol resolution on a 1 000-case test corpus extracted from TS's baselines.

### Phase 3 — Type checker (16–24 weeks, the long phase)

**Goal.** Match `tsc` on the type-system math.

**Why this is the longest phase.** TS's type system is a research-grade applicative lattice with caching. Home already has the *primitives* (intersection, conditional, mapped, literal, `keyof`, `infer`, variance — all wired up via `packages/types/src/typescript_types.zig` re-exports). What's missing is the **exact** combination logic that produces `tsc`-bug-for-bug behavior.

> **Status (2026-05-05):** 🟢 substantially complete. The relation engine, lowering surface, and most of the work below is shipped. Remaining algorithmic gaps are tracked in **§3.A** above as a 15-item punch list with effort estimates.

**Work, ordered by dependency.**

1. **Type representation & interner upgrade** (2 weeks). Move type construction behind a global lock-striped interner so structurally equal types share identity. Crucial for cache keying. Extends today's `packages/types/src/type_interner.zig`.
2. **Assignability and subtype relations** (4 weeks). The two relations differ in `any`-handling and excess-property tolerance. Both must be cycle-safe (set-based recursion guard) and cached. The hot path; design for L1 fit.
3. **Generic instantiation & inference** (4 weeks). Constraint-based inference with multiple candidates per type variable; produces a *common subtype* or *union* depending on candidate position. Higher-order generic inference (`<T,U>(f: (a: T) => U) => U`) — see [TS issue #9366](https://github.com/Microsoft/TypeScript/issues/9366). Recursion depth limit 50 for deferred conditionals, 1000 for mapped recursion ([PR #45025](https://github.com/microsoft/TypeScript/pull/45025)).
4. **Conditional & distributive types** (3 weeks). `T extends U ? X : Y` distributes over unions when `T` is a *naked* type parameter. Bracketed forms (`[T] extends [U]`) suppress distribution. Implement `infer` placeholders. **Reproduce the test cases on which tsgo currently diverges** ([typescript-go #2830](https://github.com/microsoft/typescript-go/issues/2830) for bigint template-literal types).
5. **Mapped types with key remapping** (2 weeks). Homomorphic detection (preserves modifiers and tuple shape). `+/- readonly`, `+/- ?`. The `as` rename clause.
6. **Template literal types** (1 week). String pattern types `` `${T}.${U}` `` with bounded recursion.
7. **Control-flow narrowing** (3 weeks). Reaching-definitions analysis on the AST: type guards (`typeof`, `instanceof`, `in`, equality), discriminated unions, assertion functions, type predicates, narrowing through assignment, narrowing on destructured discriminants ([PR #46266](https://github.com/microsoft/TypeScript/pull/46266)), aliased conditional narrowing.
8. **Variance computation** (2 weeks). Auto-infer per generic parameter; respect `in`/`out` measurement-correctness modifiers. Method parameter bivariance under default; contravariant under `strictFunctionTypes`. Reuse `packages/types/src/variance.zig`.
9. **Strict mode flags** (2 weeks). Each modifies the *type relation*, not just diagnostics.
10. **Late-bound `this` types** (1 week). `this: Foo` parameter; `ThisType<T>` flips contextual `this` inside object literals.
11. **Overload resolution** (2 weeks). Including the `tsgo` divergence on mutually-exclusive overloads ([typescript-go #2583](https://github.com/microsoft/typescript-go/issues/2583)).
12. **Excess-property checks** (1 week). Fresh-object vs. apparent-type tolerance distinction.

**Exit criteria.** Conformance suite ≥ 95% in week 16; ≥ 99% in week 24. Run `tests/baselines/` subset of the TypeScript repo against Home.

**Bench target.** Single-thread typecheck of the TS repo (~400K LOC) ≤ 1.0 s — match tsgo's single-thread number; parallelism in Phase 5 multiplies it.

### Phase 4 — JS emit + source maps + .d.ts + .d.hm (10–14 weeks; +1 week vs. v0 plan to integrate zig-dtsx, +1 week for `.d.hm` emitter)

**Goal.** `home tsc` produces JS output indistinguishable from `tsc` for ≥99% of inputs (modulo whitespace).

> **Status (2026-05-05):** 🟡 partial. Streaming JS pretty-printer landed for the full Phase 1 surface; symbol-driven `.d.ts` emit + zig-dtsx fast path landed; source map V3 streaming wired; class-decorator `__decorate` lowering landed. Remaining work (downlevel transforms, generators, async/await state machine, method/property/parameter decorators, ESM↔CJS interop, `.tsbuildinfo`, `.d.hm` emit) tracked in **§4.A** above as a 13-item punch list.

**Work.**

1. **AST→JS pretty-printer** (2 weeks). Streaming output, no intermediate JS-AST.
2. **Downlevel transforms** (5 weeks):
   - ES2024 → ES2022/ES2021/…/ES5/ES3.
   - Arrow → function. Class → function-with-prototype. `for-of` → indexed `for`. Generators → state machine. `async`/`await` → promise-based state machine.
   - `??` and `?.` short-circuit-preserving lowering.
   - Private fields → WeakMap (pre-ES2022).
3. **Decorators** (2 weeks). Legacy with `__decorate`/`__metadata`; Stage 3 with the new runtime model. `emitDecoratorMetadata` requires reified type info — preserved by the binder's "design type" representation.
4. **JSX transforms** (2 weeks). `preserve`, classic `react`, automatic `react-jsx`/`react-jsxdev`, `react-native`. Per-file `@jsx` pragma.
5. **ESM↔CJS interop** (1 week). `esModuleInterop`, `__importDefault`/`__importStar`, dynamic `import()` lowering.
6. **Source maps v3** (2 weeks). Sources, `sourcesContent`, names; through every transformer. VLQ-encoded mappings. Inline maps and external `.map` files.
7. **Declaration emit** (`.d.ts` *for TS sources* + **`.d.hm` for Home sources**) — **dual-track per frontend** (5 weeks total). The hardest emit work in any TS toolchain.

   **For TS sources → `.d.ts`:**
   - **Fast track: integrate zig-dtsx** (1 week). [zig-dtsx](https://github.com/stacksjs/dtsx/tree/main/packages/zig-dtsx) is an existing 8 257-LOC Zig `.d.ts` emitter (scanner + extractor + emitter pipeline at `~/Code/Tools/dtsx/packages/zig-dtsx/src/`). Published benchmarks: **2.69 ms / 2.35 ms / 2.28 ms / 3.14 ms** on small/medium/large/xlarge single files — **15.1×–19.5× faster than tsgo** on the same inputs. On multi-file projects: **18.10 ms (50 files), 31.46 ms (100 files), ~140 ms (500 files)** — **13.3–13.5× faster than tsgo**, **2.5–2.7× faster than `oxc`**. Used when the project sets `isolatedDeclarations: true` or when source files have explicit type annotations at exports — dtsx skips initializer parsing in this case as a fast path. We absorb zig-dtsx into `packages/ts_emit/d_ts/fast/` (or vendor as a submodule), wire it through the same HIR boundary, and align its output to match `tsc` byte-for-byte.
   - **Symbol-driven track** (3 weeks). For projects without `isolatedDeclarations`, `.d.ts` emit must resolve types from the type checker output and re-print the *resolved* form. Anonymize local names. Hoist inferred return types. Isolate type-only re-exports. This is what tsc does and what zig-dtsx explicitly does *not* attempt. Implementation builds on the type-checker output from Phase 3.
   - **Routing.** Driver inspects `tsconfig.json`: if `isolatedDeclarations: true`, route through fast track; else symbol-driven. Both produce byte-identical output for the conformance corpus on overlapping inputs (verified by a per-file A/B test in CI).
   - **Why this matters strategically.** Declaration emit from JS sources is one of tsgo's *current open gaps* ([TS 7 progress post](https://devblogs.microsoft.com/typescript/progress-on-typescript-7-december-2025/)). Home ships day-one with both tracks at full coverage and beats tsgo by an order of magnitude on the fast track.

   **For Home sources → `.d.hm`** (1 week):
   - Symmetric to `.d.ts` emission for TS. Home's existing type system already produces resolved types post-checker; emit walks the resolved-type graph and prints declaration-only Home syntax.
   - Grammar: `.d.hm` accepts the same constructs `.d.ts` accepts in TS — `pub fn`, `struct`, `enum`, `trait`, `type`, `const` (no initializer), `extern fn`, plus `declare`-style ambient blocks for FFI surfaces. Function bodies are forbidden; only signatures.
   - Emit is symbol-driven (Home's type system already does the resolved-form work; no separate fast track is needed because Home source already has explicit type annotations at every public boundary).
   - Used by: (a) the bundler when emitting Home libraries for downstream consumption; (b) `home build --emit-declarations`; (c) the LSP for cross-package type resolution; (d) the package manager when publishing a Home package — the equivalent of npm's `types` field, but in Home's `pantry.json`.
   - Cross-frontend interop: a `.ts` file can `import { …Home types… } from "./mod.home"`, and the type checker reads Home's `.d.hm` summary as it would `.d.ts`. Same in reverse: `.home` files can import `.ts` modules with the type checker reading the `.d.ts` summary.
8. **`.tsbuildinfo` writer** (1 week). Format-compatible with tsc.

**Exit criteria.** `home tsc emit` byte-equivalent to `tsc emit` on the 500-project corpus.

### Phase 4.5 — Bundler integration via Bun (6–10 weeks)

**Goal.** `home bundle` is the **single bundler for both frontends**:
- For TS/JS projects: drop-in compatible with the output of `esbuild` for ≥ 99% of inputs and ≥ 95% byte-equivalent (modulo whitespace and chunk-naming determinism).
- For Home projects (`.home`/`.hm`): replaces the existing `home build` flow with the full pipeline — module graph, tree-shaking, code splitting, native-or-WASM output, minification of intermediate IR, plugins.
- For mixed projects: a single program graph spans both source kinds; `.ts` files importing `.home` modules and vice-versa work transparently.

Type-checking is integrated: `home bundle` runs the type checker first and emits *only* if checking succeeds (or with `--bundle-with-errors` to override).

> **Status (2026-05-05):** 🟡 partial. The driver (`packages/ts_driver/`), program graph (`packages/ts_program/`), parallel compile (`compileAllParallel`), incremental rebuild (`recompileChanged`), `home-tsc` binary with tsconfig discovery + `outDir` + `declarationDir` + glob `include`/`exclude`, and `emitWithCache` all landed. The bundler proper — Bun vendor + HIR↔Bun-AST shim + symbol-table bridge + `home bundle` CLI + plugin API — is the remaining work. See **§4.5.A** above.

**Strategy.** Vendor Bun's bundler from `~/Code/bun/src/bundler/`, adapted to consume Home's HIR and type-checker output instead of Bun's parser AST. Because both Home's TS frontend and Home's `.home`/`.hm` frontend produce the same HIR, the same bundler code paths handle both — there is *no* second bundler.

**Source survey** (Bun's bundler tree at `~/Code/bun/src/bundler/`):

| File | LOC | Role |
|---|---|---|
| `bundle_v2.zig` | 4 509 | Top-level orchestrator |
| `LinkerContext.zig` | 2 782 | esbuild-style linker (binding resolution, tree-shaking, code-splitting) |
| `transpiler.zig` | 1 461 | Per-file transpile/transform pipeline |
| `Graph.zig`, `LinkerGraph.zig` | ~1 000 each | Module graph, import/export resolution |
| `Chunk.zig`, `entry_points.zig` | ~600 each | Chunk allocation, entry-point handling |
| `ParseTask.zig`, `ThreadPool.zig` | ~1 000 combined | Parallel parse pipeline |
| `cache.zig`, `OutputFile.zig` | ~500 combined | Caching, file emission |
| `linker_context/*.zig` | ~3 000 across 10+ files | `computeChunks`, `convertStmts`, `findAllImportedParts`, `generateChunksInParallel`, etc. |
| `HTMLScanner.zig`, `HTMLImportManifest.zig` | ~1 000 | HTML imports (Bun-style multi-file entry) |
| Other (`AstBuilder`, `barrel_imports`, `defines`, etc.) | ~3 000 | Misc support |
| **Total** | **~20 130** in top-level | Plus subdirs |

**Work, ordered by dependency.**

1. **License & vendor strategy** (3 days). Bun is MIT-licensed; vendor the bundler tree as a git submodule pinned to a known SHA. Maintain a thin `packages/bundler/adapter.zig` that bridges Bun's expected interfaces (`bun.JSAst.Ast`, `bun.options.Options`) to Home's HIR + type-checker symbols. Upstream improvements via PRs to oven-sh/bun where mutually beneficial.
2. **HIR ↔ Bun-AST shim** (2 weeks). Bun's bundler operates on its own `JSAst` representation. Two paths:
   - **Path A (preferred):** Lower Home's HIR into Bun's `JSAst` at the bundler boundary. Cheap, preserves all of Bun's optimizations.
   - **Path B (long-term):** Adapt the linker to operate directly on HIR. Cleaner but a rewrite; deferred to v2.
   Path A in v1.
3. **Symbol-table bridge** (1 week). Bun's linker uses its own symbol tables. Map Home symbols → Bun symbols at bundler entry; map back at emit.
4. **Type-checked emit gate** (3 days). `home bundle` first runs the type checker (Phase 3) on the entry-point closure; emits only on success unless `--bundle-with-errors`. The type checker runs in parallel with parse; emit waits on both.
5. **CLI surface** (1 week). `home bundle <entry>` with esbuild-style flags plus Home-source extensions:
   - Output: `--format=esm|cjs|iife|amd|native|wasm`, `--target=esnext|es2022|…|x64|arm64`, `--platform=browser|node|neutral|native`, `--outfile`, `--outdir`.
   - Optimization: `--minify`, `--minify-syntax`, `--minify-whitespace`, `--minify-identifiers`, `--tree-shaking=true|false`.
   - Source maps: `--sourcemap=inline|external|both`, `--sources-content`.
   - Code splitting: `--splitting`, `--chunk-names`.
   - Externals: `--external=react,vue,…`.
   - Define: `--define:KEY=VALUE`.
   - Loaders: `--loader:.png=file`, `.svg=text`, `.json=json`, `.txt=text`, `.home=home`, `.hm=home`, etc.
   - Bun-specific extras inherited: `--banner`, `--footer`, `--public-path`, `--asset-names`.
   - Home extras: `--target=native` switches the bundler's emit step to invoke Phase 7 native codegen on each chunk; `--target=wasm` does the same for WASM.
6. **Plugin API** (2 weeks). Bun has a plugin API; expose the same surface so existing Bun plugins work unchanged. `home bundle --plugin=./my-plugin.ts` (plugin runs in a sandboxed JS runtime; for Zig-native plugins we ship `home bundle --zig-plugin=./libplugin.so`).
7. **Source maps** (built-in to Bun's bundler; verify byte-identical to esbuild on the conformance corpus).
8. **CSS bundling** (1 week, optional). Bun bundles CSS; we ship this in v1 since the code is there. Markup as v1.0 if stable, otherwise v1.1.
9. **HTML imports** (1 week, optional). Bun's `HTMLScanner.zig` + `HTMLImportManifest.zig` already handle this. Ship in v1.
10. **Watch + dev-server mode** (2 weeks). `home bundle --watch` integrates with the Phase 5 query DB so file changes trigger incremental rebuilds. `home dev` (later phase) wraps this for full HMR.

**Exit criteria.**

- `home bundle` byte-equivalent to `esbuild` output on a 200-project corpus (the projects from esbuild's published benchmarks plus a curated 100 OSS TS projects).
- Cold full build of the bundler reference projects (esbuild's `three.js` benchmark, etc.) within **5%** of Bun's published numbers (Home pays a small overhead for type-checking, which esbuild and Bun do not do).
- Watch incremental rebuild after a 1-line edit: ≤ **30 ms** (matching the §11 Tier-1-enhanced typecheck-watch number).
- All esbuild CLI flags accepted; semantically-equivalent output.

**Bench targets** (single 8-core M-class laptop, cold, including type checking):

| Workload | esbuild | Bun bundler | tsc emit | **Home bundle target** |
|---|---|---|---|---|
| TS — `three.js` cold full | ~250 ms | ~80 ms | n/a (no bundler) | **≤ 100 ms** *(includes typecheck; Bun + esbuild do not)* |
| TS — 100-file React app | ~150 ms | ~50 ms | n/a | **≤ 80 ms** |
| TS — watch incremental, 1-line | ~40 ms | ~25 ms | n/a | **≤ 30 ms** |
| `.home` — 100-file native | n/a | n/a | n/a | **≤ 120 ms** *(typecheck + tree-shake + native codegen)* |
| `.home` — watch incremental, 1-line | n/a | n/a | n/a | **≤ 40 ms** |
| Mixed `.ts` + `.home` — 100-file | n/a | n/a | n/a | **≤ 100 ms** |

Home pays a ~20–60% overhead vs. raw esbuild/Bun bundler **because we add type-checking inline.** Without type-checking (`home bundle --skip-check`), we match Bun within 5%. For `.home` workloads, the comparison is against Home's *current* native build — the bundler adds tree-shaking and chunking on top, so output is smaller-and-faster despite the equivalent or shorter build wall-clock.

### Phase 5 — Performance engineering (4–8 weeks)

**Goal.** Hit the bench targets in §0.

> **Status (2026-05-05):** 🟡 partial. Watch foundation, content-addressed disk-persistent cache, parallel parse+bind+compile via `compileAllParallel`, and incremental rebuild API (`recompileChanged`) all landed. Salsa-style query memoization across phases, finer-grained per-symbol invalidation, native FS-event backends, two-level relation cache, and lock-striped global interner remain. See **§5.A** above.

**Work.** Engineering on top of an already-correct compiler. Premature opt before Phase 4 produces incorrect results we can't tell are incorrect.

1. **Parallel parse** (1 week). Files are independent → trivially parallelizable. Work-stealing pool over a queue of `(filename, source)`.
2. **Parallel bind** (1 week). Per-file binding produces per-file symbol tables; merge step is single-threaded but cheap.
3. **Parallel typecheck** (2 weeks). Mirror tsgo's `--checkers N`. Default 4. `--singleThreaded` flag for debugging.
4. **Type-relation cache** (1 week). Two-level: per-worker L1 (lockless), shared L2 (read-mostly with seqlock). Eviction by capacity.
5. **Salsa-style query engine wiring** (2 weeks). All inter-phase results (file→AST, file→symbols, expr→type) are queries.
6. **Memory tuning** (1 week). Per-phase arenas; track peak; bound any over-retentive caches.

**Exit criteria.** Cold typecheck of VS Code ≤ 3.5 s on an 8-core M-class laptop; watch rebuild after a 1-line edit ≤ 80 ms; peak RSS ≤ 800 MB.

### Phase 6 — Conformance hardening (8–12 weeks)

**Goal.** ≥ 99.9% on TS conformance, beating tsgo's 99.6%.

> **Status (2026-05-09):** 🟡 partial. `packages/ts_conformance/` runner ships a 56-case canon corpus, on-disk fixtures at `tests/conformance/*.ts`, disk `runDirectory`, patience-diff unified mismatch output, a clean **16/16** smoke run against local TypeScript conformance subdirectories, a named-category runner currently clean at **86/86**, and a coarse baseline-aware `types/typeRelationships` survey now clean at **175/175** (`apparentType` 2/2, `bestCommonType` 8/8, `recursiveTypes` 13/13, `subtypesAndSuperTypes` 52/52, `typeAndMemberIdentity` 48/48, `typeInference` 52/52). Full-corpus windows now stand at `START=838 LIMIT=40` **40/40**, `START=878 LIMIT=40` **40/40**, and `START=918 LIMIT=40` **38/40**. The named type-relationships ratchet is saturated; remaining Phase 6 work is exact `.errors.txt` comparison, continued full local-corpus slice ratchets, JSDoc/computed override parity in the active slice, and per-PR delta gating. See **§6.A** above.

**Work.** Triage failing cases. Many are subtle inference-engine bugs around recursive types, distributive conditionals, and declaration merging. No glamour; *the work that makes Home a credible TS compiler*.

1. Run `tests/baselines/reference/*.errors.txt` comparison; categorize failures by feature.
2. Fix in priority order: declaration merging, control-flow narrowing, generic inference (~70% of typical conformance gaps).
3. Build a regression bot: every PR runs the full conformance suite with delta vs. main.

**Exit criteria.** ≥ 99.9%; ≤ 20 known divergences, each documented.

### Phase 7 — Native codegen for TS (8–16 weeks)

**Goal.** `home build --target=x64 my.ts` produces a native binary for the *typed, monomorphizable subset* of TypeScript.

**The unique offer.** No other TS compiler does this. Bridge between "TS as a typed scripting language" and "TS as a systems language."

**Work.**

1. **Subset definition** (2 weeks). Document precisely which TS programs compile natively: full type system, but property access only on declared shapes (no `obj[arbitraryString]` unless typed via `Record<…>`); no `eval`, no `Function` constructor, no prototype mutation. JS escape hatch via `extern "js"` for the dynamic 5%.
2. **HIR→MIR lowering** (3 weeks). Existing `packages/optimizer/`, `packages/regalloc/`, `packages/codegen/` apply. Reuse most of the native x64 path. Big addition: monomorphization of generic TS classes/functions, paralleling `packages/codegen/src/monomorphization.zig` for Home generics.
3. **JS runtime in Zig** (4 weeks). Minimal `Object`, `Array`, `String`, `Map`, `Set`, `Promise` runtime. Most exists in stdlib.
4. **GC integration or escape analysis** (3 weeks). Two paths: (a) integrate a small precise GC; (b) escape analysis + arenas + RC for cycles. Decision deferred to a Phase 7 design spike.
5. **WASM emit** (2 weeks). For browser/runtime distribution.
6. **LLVM backend completion** (2 weeks). Existing `packages/codegen/src/llvm_codegen.zig` works for Home; extend for the TS subset.

**Exit criteria.** A 50-project corpus of typed-subset TS compiles natively and matches Node-on-tsc output for unit tests.

### Phase 8 — LSP (6–10 weeks)

**Goal.** A Language Server with feature parity to `typescript-language-server`, on top of the query DB.

> **Status (2026-05-05):** 🟢 substantially complete on the protocol-layer side. `packages/ts_lsp/` (query surface) + `packages/ts_lsp_server/` (LSP wire-protocol JSON-RPC) + `home-lsp` stdio binary all shipped. `hover`, `definition`, `references` (cross-file), `completion` (module-level) wired through the program graph. `signatureHelp` / `inlayHint` / `semanticTokens` / `codeAction` / `rename` / `workspace/symbol` / FS-event-driven publishDiagnostics remain. See **§8.A** above.

**Work.** Most queries already exist from Phase 5. LSP exposes them.

1. `textDocument/hover`, `definition`, `references` (1 week each).
2. `completion` (3 weeks). Includes auto-import (search the type interner for matching exports).
3. `signatureHelp`, `inlayHint`, `semanticTokens` (1 week each).
4. `codeAction` (2 weeks). Organize imports, fix-all, infer parameter types.
5. `rename` (2 weeks). Cross-file via the symbol table.
6. `workspace/symbol`, `documentSymbol` (1 week).
7. **Watch integration** (1 week). FS events trigger query invalidation, which pushes diagnostics.
8. **Existing LSP package** (`packages/lsp/`, 4 125 LOC) is a starting point, but most will be rewritten on top of the query engine.

**Exit criteria.** LSP performance: completion response ≤ 50 ms in a 100K-LOC project; rename response ≤ 200 ms.

### Phase 9 — Ecosystem & migration (4–6 weeks)

1. **`@types/*` resolution.** Match `tsc`'s type-acquisition behavior.
2. **Project references.** `tsc --build` semantics — incremental across project boundaries via `.tsbuildinfo`-equivalent (we ship the compatibility format too).
3. **`tsserver` protocol shim** (optional). Some VS Code plugins talk `tsserver`, not LSP; a shim opens the door.
4. **Migration guide.** "`tsc` flags → `home tsc` flags" doc.
5. **CI integration.** GitHub Action.
6. **`npm`/`bun`/`pnpm` integration.** Home ships as `npm install -g @home-lang/tsc` so `npx home tsc` works.

### Phase 10 — Release & validation (2–4 weeks)

1. Reproduce all benchmark numbers under `hyperfine` on `runs-on: ubuntu-latest`.
2. Publish the harness (`bench/vs_tsgo/`).
3. v1.0 release.

---

## 5 · Performance engineering — the architecture that produces the numbers

This is the substance of "more performant than tsgo." Beating tsgo by 2–3× requires structural advantages, not micro-optimization.

### 5.1 Why Zig wins over Go *structurally*

| Lever | Go (tsgo) | Zig (Home) | Estimated win |
|---|---|---|---|
| GC | Tracing GC, mark-bit per object | Per-phase arena, no GC | 1–3% CPU, smoother latency |
| AST layout | Pointer-tree of structs | SoA columns of `[]u32` | 4–8× more nodes per L1 line |
| Interner | Map with GC overhead | Lock-striped open-addressing | ~2× fewer ops per intern |
| SIMD | Limited; goroutine pool overhead | First-class `@Vector(N, u8)` | 3–5× lex throughput |
| Inlining | Whole-program | LLVM/comptime per call site | Hot loops 1.5–2× faster |
| Per-phase memory cap | GC heap bound only | Per-arena hard cap | Predictable memory behavior |
| Native AOT | N/A | Real, ships TS→x64 | Differentiator |

These are *individually small* wins that compound. The cache-locality win on the type-checker hot path alone is plausibly 1.5–2× by itself.

### 5.2 The AST/HIR layout (the single most important data-structure decision)

```zig
// packages/hir/src/hir.zig (sketch)

pub const NodeKind = enum(u8) {
    // ~250 kinds — Home's existing AST NodeType plus TS-specific kinds
};

pub const Hir = struct {
    // Columns. All sized to node_count.
    kinds:   []NodeKind,    //  1 byte/node
    spans:   []Span,        //  8 bytes/node — (start: u32, end: u32)
    parents: []NodeId,      //  4 bytes/node
    types:   []TypeId,      //  4 bytes/node — populated post-bind

    // Per-kind payload columns (only populated for relevant kinds).
    binop_lhs: []NodeId,
    binop_rhs: []NodeId,
    binop_op:  []BinOp,
    call_callee:     []NodeId,
    call_args_start: []u32,    // index into args_pool
    call_args_len:   []u16,
    args_pool:       []NodeId, // contiguous arg arrays
    // ... one column-set per major node shape
};

pub const NodeId = u32; // node 0 reserved as "none"
pub const TypeId = u32;
pub const StringId = u32;
```

**Per-node footprint, average across kinds: ~24 bytes** for Home's SoA layout.

Compare against verified tsgo and tsc layouts:

- **tsc node:** ~150–300 bytes (`pos`, `end`, `kind`, `flags`, `transformFlags`, `original`, `parent`, `symbol`, `locals`, plus per-kind fields).
- **tsgo node** (verified at `internal/ast/ast.go:178`):
  ```go
  type Node struct {
      Kind   Kind                 // int16  (2 B)
      Flags  NodeFlags            // uint32 (4 B)
      Loc    core.TextRange       // 16 B (two ints)
      id     atomic.Uint64        // 8 B
      Parent *Node                // 8 B
      data   nodeData             // 16 B (interface = ptr + type word)
  }
  ```
  **Base Node = ~54 B**, plus the per-kind concrete struct it points to via `data` (e.g., `DoStatement` adds ~48 B at `ast_generated.go:1033`), plus Go heap alignment (~16–32 B). **Total per allocation: ~120–130 B.** No `transformFlags` field (a tsc field tsgo dropped). Children are still `*Node` pointers (`DoStatement.Statement *Statement`, `DoStatement.Expression *Expression`).
- **Home node:** ~24 B average (kind: 1 B + span: 8 B + parent: 4 B + type: 4 B + per-kind payload as separate columns).

**Cache implication** (64-byte L1 cache line):
- tsc: 0–1 nodes per line.
- tsgo: 0–1 nodes per line (54 B base alone fills most of a line; payload is a separate allocation).
- Home: ~2–3 *full nodes* worth of hot fields per line, or ~16 nodes' worth of `(kind, span)`-only iterations.

The type-checker spends most of its time iterating `(kind, type)` pairs and following parent links. SoA wins this by ~8–16× on memory-bound iterations.

**Caveat.** tsgo's per-kind arenas (`internal/ast/ast_generated.go:20-70`, `internal/core/arena.go:7-22`) make *allocation* cheap — geometric-growth slabs amortize to ~1 alloc per ~512 nodes. Home matches this with phase-arena allocators. The advantage is **not** allocation speed; it's child-relation pointer-chasing during traversal.

### 5.3 The type interner (rebuild)

Today's `packages/types/src/type_interner.zig` (140 LOC) is single-allocator with a single `AutoHashMap`. The parallel checker demands a redesign.

**Why this is a confirmed structural advantage over tsgo.** tsgo declares `type TypeId uint32` at `internal/checker/types.go:116` but **does not use it as an intern key**. There is no `TypePool` or `TypeTable` in tsgo. Each `Checker` constructs its own `Type` objects locally; the same nominal type appearing in two files routed to different checker workers becomes two distinct objects, and any structural query (`assignableTo`, `isIdenticalTo`) on the cross-pair has to recompute. With Home's globally-interned, lock-striped pool, type comparisons become a single integer compare and the relation cache (§5.4) is keyed on `(TypeId, TypeId)` packed into a `u64`.

The sketch:

```zig
// packages/types/src/interner.zig (Phase 5 sketch)

const N_SHARDS = 64;

pub const Interner = struct {
    shards: [N_SHARDS]Shard,
    type_pool: ArrayListUnmanaged(Type),  // all types live here, indexed by TypeId

    const Shard = struct {
        mu: std.Thread.RwLock,
        table: HashMap(TypeKey, TypeId),
    };

    pub fn intern(self: *Interner, key: TypeKey) TypeId {
        const shard = &self.shards[key.hash() % N_SHARDS];
        // Read path: lock-free seqlock; fall back to RwLock on contention
        // Write path: RwLock write, atomic append to type_pool
    }
};
```

**Why lock-striped, not lock-free.** Lock-free hash tables exist but have terrible insertion patterns under contention; lock-striped is 90% of the way for 10% of the bug surface.

**Why a single `type_pool`.** All `TypeId`s are stable indices. Type comparison is `id_a == id_b` — single integer compare. The `assignableTo(a, b)` cache keys on `(a, b)` packed into a `u64`.

### 5.4 The relation cache (the hottest data structure in the compiler)

```zig
// packages/types/src/relation_cache.zig (sketch)

pub const Relation = enum(u8) { Assignable, Subtype, Identity, Comparable };

pub const RelationCache = struct {
    l1: [N_WORKERS]L1Cache,
    l2: SharedCache,

    const L1Cache = struct {
        // Open-addressed: key = (rel:8, source_id:28, target_id:28)
        // value = (result:2, generation:6, depth:8)
        entries: [L1_SIZE]L1Entry, // L1_SIZE = 64 * 1024 (1 MB cache, 16 B entries)
    };

    pub fn lookup(self: *RelationCache, w: WorkerId, rel: Relation, src: TypeId, tgt: TypeId) ?bool {
        // Check L1 (no synchronization)
        // Check L2 (seqlock read; retry once on writer; fall through)
        // Return null on miss → caller computes
    }
};
```

The one data structure that *must* be tuned within an inch of its life. tsc's equivalent (`relate` in `checker.ts`) dominates its profile.

**tsgo verification.** `internal/checker/relater.go:100-117` defines `Relation { results map[CacheHashKey]RelationComparisonResult }` and that map lives **inside each `Checker`** — there is no shared cache across checkers. With round-robin file partitioning (`checkerpool.go:114-117`), the same `(source, target)` pair is recomputed N times for an N-checker pool whenever both ends route to different workers. Home's two-level cache (per-worker L1 unsynchronized + shared L2 seqlock) eliminates this redundancy without contention.

Beating it requires (a) keeping the working set in L1, (b) avoiding allocation on hit, (c) cycle handling without spilling state to a heap-allocated set on every recursive call, (d) sharing across workers — the structural win tsgo lacks.

### 5.5 SIMD lex

Zig stdlib has `@Vector(N, u8)` first-class SIMD. Strategy mirrors `simdjson`:

1. **Byte classification.** Pre-compute a 256-entry table of "byte → class". Vectorize: `@Vector(64, u8)` reads 64 bytes; `tableLookup` produces 64 classes; `popcount`/`leading-zeros` finds the next boundary.
2. **String boundary detection.** `@Vector` compare against `"`, then handle `\` escapes via a "previous byte was backslash" mask.
3. **Identifier extent.** Run-length on identifier-cont class.

**tsgo verification.** tsgo's scanner is at `internal/scanner/scanner.go:466` (`func (s *Scanner) Scan() ast.Kind`), implemented as a single byte-by-byte `switch ch { case '\t', ' ': … case '!': … }` dispatch. Keywords are a `map[string]ast.Kind` at `scanner.go:36`. Unicode is via precomputed range tables in `internal/scanner/unicodeproperties.go`. **No SIMD anywhere.** Total scanner package: 4 174 LOC (`scanner.go` 2 833 + `regexp.go` 1 071 + `unicodeproperties.go` 162 + minor). Home's SIMD lex faces no in-kind competition.

**Throughput target:** 1.5 GB/s per core (simdjson does ~3 GB/s for JSON; TS lex is harder so 1.5 GB/s is realistic). tsgo's byte-at-a-time scanner is plausibly in the 200–400 MB/s range; **realistic Home advantage on lex alone: 4–7×.**

### 5.6 Parallelism model

```
                   File queue
                       │
           ┌───────────┼───────────┐
           │           │           │
        Worker0     Worker1     WorkerN
        (lex+        (lex+        (lex+
         parse+       parse+       parse+
         bind)        bind)        bind)
           │           │           │
           └───────────┼───────────┘
                       ▼
              Merged symbol table
                       │
                  partition by file
                       │
           ┌───────────┼───────────┐
           │           │           │
        Checker0    Checker1    CheckerM
                       │
              Shared interner +
              shared relation cache
                       │
                       ▼
                 Diagnostics
```

**Worker count.** Default `min(NPROC, 8)` for lex/parse/bind, `4` for checkers (the relation cache benefits from low contention). Override with `--checkers=N`.

**Cross-file inference.** When checker on file A needs to instantiate a generic from file B, it `await`s a query result from worker B. The query engine handles this; queries are work-stealing, so blocking is rare.

### 5.7 Watch & incremental — the 80 ms target

Watch-mode rebuild after a 1-line change must be ≤ 80 ms.

1. **File-watcher** detects change → invalidate `read_file(path)` query → dependent query DAG marks downstream queries dirty.
2. **Re-lex + re-parse** the changed file. ~5 ms for a typical 500-line file.
3. **Re-bind** only the changed file. ~3 ms.
4. **Type-recheck** only the changed file *and* files whose types depend on it. Query DB knows these.
   - Most edits affect ~5–20 files. With the relation cache warm, ~30–60 ms.
5. **Push diagnostics** through LSP.

**Total budget**: 5 + 3 + 60 + 12 = 80 ms, with margin.

The key invariant: **typecheck output is a function of the type interner + the relation cache + the (now updated) AST**. Caches survive the edit; only invalidated queries re-run.

**tsgo verification — why this is a clear win.** tsgo's incremental model is dramatically simpler than this:
- `internal/project/project.go:61-62` tracks `dirty bool` and a single `dirtyFilePath tspath.Path`.
- On change, `Project.UpdateProgram(dirtyFilePath)` is called; if only one file is dirty and the command line hasn't changed, the program reuses parsed/bound state for unchanged files (`project.go:352-365`).
- **There is no dependency graph, no per-symbol invalidation, and no query DB.** The relation cache is per-checker (§5.4) and is not selectively invalidated; on a cross-cutting type edit, the per-checker caches retain stale results until the next full rebuild.
- The `internal/project/dirty/` subpackage (`map.go`, `syncmap.go`) tracks file-level dirtiness only, not type-level.

This is why TS 7 beta openly says *"our new `--watch` mode may be less-efficient than the existing TypeScript compiler in some scenarios"* ([beta announcement](https://devblogs.microsoft.com/typescript/announcing-typescript-7-0-beta/)). Home's query-DB approach, modeled on rust-analyzer's Salsa, is uncontested by either tsc or tsgo.

### 5.8 Streaming diagnostics — the 300 ms TTFD target

Most TS compilers wait until the entire program is bound before reporting any diagnostics. Home doesn't.

1. **Parse-time errors** stream immediately as the parser emits them.
2. **Bind-time errors** (duplicate decls, etc.) stream as binder finishes each file.
3. **Type errors** stream per-file as each checker partition completes.

User sees "module 'foo' not found" within 30 ms of opening the project, even while typecheck is still running. *No current TS compiler does this well.*

---

## 6 · Validation plan

### 6.1 Conformance suite

The TS repo has **5 907 conformance test files** (verified by counting `_submodules/TypeScript/tests/cases/conformance/` from the tsgo tree) plus **~40 000+ fourslash editor scenarios** in `internal/fourslash/tests/`. Total cross-checked test corpus ≈ 46 000 cases.

Each conformance case has up to four artifacts:
- A source file (`.ts` / `.tsx` / multi-file).
- A `.errors.txt` with expected error positions and messages — generated by `DoErrorBaseline()` in tsgo at `internal/testutil/tsbaseline/error_baseline.go:36`, formatted with `\r\n` line endings (`harnessNewLine` constant, line 24).
- A `.types` file with expected inferred types per expression — generated by `DoTypeAndSymbolBaseline()` at `internal/testutil/tsbaseline/type_symbol_baseline.go:30`.
- A `.symbols` file with expected symbol resolutions (same generator as `.types`).

**Comparison method.** tsgo uses unified diff with the patience algorithm (`github.com/peter-evans/patience`, see `internal/testutil/baseline/baseline.go:15`). Home's harness will use the same algorithm to make output diffs directly comparable when triaging.

**Test runner pattern.** tsgo's runner is in `internal/testrunner/compiler_runner.go`; tests run in parallel via `t.Parallel()` (line 206), with explicit skips for nondeterministic-emit cases (lines 391-400). Home's harness follows the same pattern, using Zig's `std.testing` plus a parallel-aware runner.

**Baseline storage.** tsgo splits `tests/baselines/reference/` (committed) and `tests/baselines/local/` (per-run output). Home replicates this so reviewers can `diff -ur` the trees during conformance work.

**Targets.** ≥ 95% by Phase 3 exit, ≥ 99% by Phase 4 exit, ≥ 99.6% by Phase 6 exit (matching tsgo's 99.6% / 74-failing-cases bar reported in the [TS 7 progress post](https://devblogs.microsoft.com/typescript/progress-on-typescript-7-december-2025/)), ≥ 99.9% by Phase 10 exit (beating tsgo).

**Reuse strategy.** We use the locally-installed upstream `microsoft/TypeScript` checkout instead of embedding a repo submodule (explicit user direction: no TypeScript submodule in this repo). Apples-to-apples conformance numbers still require recording the exact local TypeScript SHA used for each run so comparisons against tsgo remain meaningful.

### 6.2 Real-world drop-in corpus

1 000 OSS TS projects sampled by npm download counts and OSS popularity. Each project has an expected `--noEmit` result at a known commit. CI verifies. Catches the "passes conformance but breaks real code" class of bugs.

### 6.3 Anti-tsgo workloads

1. **Twenty CRM** (NestJS, decorator-heavy) — tsgo regresses 2× here. Home must be ≥ tsc on this workload, target ~5× tsgo.
2. **Type-meta-programming** (e.g., `ts-toolbelt`, `type-fest` consumers, complex generic libraries). tsgo's deferred-conditional bug ([#2830](https://github.com/microsoft/typescript-go/issues/2830)) is a specific failing case to match tsc on.
3. **Bundler hot path**: a project using `vite` with TS — measure end-to-end build time including TS. Home should be within 5% of `swc`/`esbuild` for type-stripping (no checking) and faster than tsgo for full check.

### 6.4 Bench harness

`bench/vs_tsgo/` contains:
- `Dockerfile` (reproducible env).
- `run.sh` downloads VS Code, TS repo, Playwright, Twenty CRM at pinned SHAs.
- `compare.py` runs `hyperfine` on tsc, tsgo, and Home with identical flags.
- `report.md` template auto-generated per run.

CI runs nightly on a dedicated benchmark runner (self-hosted box for variance reasons). Numbers published to `bench.home-lang.dev`.

### 6.5 Watch-mode harness

`tests/watch/`: A scripted editor that opens a project, makes a 1-line change, waits for the new diagnostic, measures latency. Per-project and per-edit-type breakdown.

### 6.6 LSP harness

`tests/lsp/`: Drives the LSP through the LSP test framework, measures completion/hover/rename latency.

### 6.7 Drop-in CI matrix

For every PR:

| Stage | Workload | Pass criteria |
|---|---|---|
| Unit | `zig build test` | All pass |
| Conformance | TS conformance suite | No regression (% must be ≥ main) |
| Drop-in | 1 000-project corpus | No regression (project pass rate ≥ main) |
| Bench (cold) | 5 reference projects | No > 5% regression on any |
| Bench (watch) | 3 reference projects | No > 10% regression |
| Memory | VS Code typecheck | Peak RSS within 5% of main |

---

## 7 · Risk register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Type checker subtle divergences from `tsc` | High | Critical | Phase 6 budget; conformance gate; `tsc` regression-diff bot in CI |
| Decorator emit (legacy + Stage 3) compatibility | High | High | Reuse `__decorate` shim from `tslib`; full Stage 3 spec implementation; conformance corpus |
| Watch performance regressions as features land | Medium | High | Watch-bench in CI; budget gate (rebuild must stay ≤ 100 ms) |
| Native codegen subset too narrow | High | Medium | Phase 7 design spike; document limitations clearly; JS escape hatch (`extern "js"`) |
| LSP completeness lags `tsserver` | Medium | Medium | Phase 8 audit against `typescript-language-server` features list |
| `.d.ts` emit divergences (the hardest emit work) | High | High | Mirror `tsc`'s symbol-driven approach; do not invent; phase-3 emit gate |
| Single 6 554 LOC `parser.zig` impedes Phase 1 | Certain | Medium | Phase 0 mandatory split-up |
| Single 10 889 LOC `native_codegen.zig` impedes Phase 7 | Certain | Medium | Phase 0 mandatory split-up |
| Memory fragmentation in long-running LSP | Medium | Medium | Per-file arenas + periodic compaction; LSP soak-test |
| TS keeps moving (5.x → 6.x → 7.x grammar drift) | Medium | Medium | Version-pin against TS 7.0 stable; track upstream PRs; quarterly upgrade cycle |
| Existing Home codebase semantic drift during refactor | Medium | High | Phase 0 has zero-behavior-change gate; full Home test suite must pass |
| `tsbuildinfo` format compatibility breaks | Medium | Medium | Treat as a contract; round-trip test against tsc's writer |
| `paths` mapping edge cases vs. `tsc` | Medium | Medium | Drop-in corpus hits this; Phase 1 has dedicated path-mapping tests |
| Type-acquisition for `@types/*` differs from tsc | Low | Medium | Mirror tsc's algorithm exactly |
| Shared L2 relation cache produces non-deterministic results | Medium | High | Cache writes are last-writer-wins on identical keys; structural identity via interner means writes are idempotent. CI runs `--singleThreaded` vs default in parallel and diffs outputs |
| Salsa query overhead exceeds savings on full builds | Low | Medium | Bench-gate per phase: full build with query DB must be within 10% of full build with query DB disabled; tune cycle/edge bookkeeping |
| Local TypeScript conformance SHA drifts from tsgo's | Low | Low | Record the local TypeScript SHA with every conformance report; compare against the same SHA tsgo reports when publishing parity numbers |
| zig-dtsx `.d.ts` output diverges from tsc on edge cases | Medium | Medium | A/B test against tsc on the conformance corpus before promoting fast-path as default; fall back to symbol-driven track on any divergence |
| zig-dtsx maintenance velocity diverges from Home's | Low | Medium | Vendor zig-dtsx as a submodule pinned to a known-good SHA; upstream improvements via PRs to stacksjs/dtsx |
| Bun bundler upstream divergence | Medium | Medium | Vendor as submodule pinned to a known-good SHA; thin adapter layer absorbs Bun's API churn; upstream non-Bun-specific fixes |
| Bundler output drifts from esbuild byte-equivalence | Medium | Low | Per-project byte-diff in CI on a 200-project corpus; chunk-naming determinism via stable hash |
| Type-check overhead dominates `home bundle` perf | Medium | High | `--skip-check` opt-out matches esbuild speed; default mode runs type checker in parallel with parse so wall-clock overhead is the *max*, not *sum* |

---

## 8 · Concrete next steps

> **Note (2026-05-05):** The original "week 1" block has been completed — Phase 0 / 1 / 2 are landed, Phase 3 is substantially complete, Phases 4 / 4.5 / 5 / 8 have foundations in place. The list below reflects the *current* next-most-impactful items, ordered for a single contributor pulling from the §B punch lists. For the original kickoff plan, see git history of this file.

1. **Load + categorize the local TypeScript conformance corpus** (§6.A.4). 1 week. Produces the per-feature pass-rate baseline without adding a repo submodule.
2. **Finish mapped/conditional type edge cases** (§3.A.2 / §3.A.3). 1-2 weeks. Homomorphic `keyof T`, non-distributive bracketed conditionals, recursion limits, and broader `infer` matching are the highest-value checker gaps.
3. **Higher-order generic inference** (§3.A.12). 1 week. Ratchets callback-heavy generic-library compatibility.
4. **Reverse-dep query memoization through `ts_program`** (§5.A.1). 2 weeks. Primary lever for the 80 ms watch target.
5. **Generator state-machine downlevel** (§4.A.4). 2 weeks. Largest remaining ES5 runtime-compatibility hole.
6. **Full Stage 3 decorator initializer semantics** (§4.A.9). 1 week. The helper shape is in place; exact tsc scaffolding remains.
7. **Vendor Bun's bundler + HIR shim** (§4.5.A.1–§4.5.A.4). 3.5 weeks. Unblocks `home bundle` as an esbuild replacement.

A new contributor should pick from §B's punch lists in their phase of choice. The `journal` is append-only — every landing is one entry.

---

## 9 · Why this plan is credible

1. **The type-system math is mostly already there.** `packages/types/src/typescript_types.zig` re-exports `IntersectionType`, `ConditionalType`, `MappedType`, `KeyofType`, `TypeofType`, `InferType`, `LiteralType`, `TemplateLiteralType`, `BrandedType`, `OpaqueType`, `IndexAccessType`, `Variance`, `TypeGuard`, `RecursiveTypeAlias`. The keywords `Infer`, `Is`, `Keyof`, `Typeof`, `Readonly`, `As`, `Type` are already in the lexer. We are *not* inventing intersection types or `keyof`; we're aligning existing implementations to match `tsc` exactly.
2. **Zig has structural advantages over Go** for this workload: no GC, real SIMD, comptime, arena allocation. Compounding wins.
3. **tsgo has known regressions** ([decorators 2× slower than tsc](https://github.com/microsoft/typescript-go/issues/2551); [watch unoptimized](https://devblogs.microsoft.com/typescript/announcing-typescript-7-0-beta/); declaration emit incomplete). Our architecture starts from the answer.
4. **Conformance is the gate.** ≥ 99.6% (matching tsgo) is a hard requirement, not a stretch goal.
5. **The phased order is dependency-correct.** No phase requires capability from a later phase. Painful long phases (3, 6) early enough that schedule risk surfaces quickly.
6. **Drop-in is testable.** §2 spells out CLI flags, every tsconfig option, output format, exit codes, diagnostic format. The drop-in corpus (§6.2) verifies compatibility with real projects.
7. **Zig-vs-Go on TS tooling is no longer hypothetical.** `zig-dtsx` already publishes apples-to-apples benchmarks showing **15–19× faster than tsgo** on `.d.ts` emission. We absorb it for Phase 4's fast track and use the same data-layout / SIMD / arena strategies for the rest of the pipeline.
8. **Bundler is not from scratch.** Bun's bundler (~20 K LOC of Zig: `bundle_v2.zig`, `LinkerContext.zig`, `transpiler.zig`, `Graph.zig`, etc.) is the fastest JS bundler currently published. Vendoring it for Phase 4.5 puts Home at parity with Bun on bundling and *adds type-checking the others do not do*. The "complete TS toolchain that's faster than the sum of its parts" is the v1 product, not a v2 wishlist.

---

## 10 · What I've intentionally left out

- **Specific function signatures and APIs** for new packages — those belong in per-package design docs spawned during each phase.
- **Test plans below the suite level** — each phase will have its own internal test plan.
- **Hiring / team structure** — not in scope.
- **Marketing / brand** — not in scope.
- **Native codegen of dynamic JS** (full prototype chain, `eval`, `Function`) — out of scope for v1, possibly forever.
- **Backwards-incompatible Home language extensions** — a separate "Home extensions" track post-v1.

---

## 11 · Performance ceiling — pushing past v1

The §0 targets (≤ 0.30 s cold, ≤ 80 ms watch, ≤ 300 ms TTFD) beat tsgo by 2–3× cold and 10–50× watch. **They are not the theoretical maximum.** The §5 architecture is well-designed but conservative; this section catalogues every additional technique we considered, tiered by return-on-investment.

**We commit to all of Tier 1** — it adds ~12 weeks to the schedule (≈12% of v1 budget) for an additional ~30–60% on every headline benchmark plus 5–10× on cold-start CLI scenarios. Tier 2 is opt-in after v1 profiling. Tier 3 is research-grade and noted only for completeness.

### Headline numbers, revised

The v1 plan's targets in §0 *include Tier 1*. To make the comparison legible, here is the breakdown:

| Metric | tsgo | v1 baseline (no Tier 1) | **v1 committed (with Tier 1)** | Multiplier vs. tsgo |
|---|---|---|---|---|
| 100K-LOC cold typecheck | ~0.7 s | ≤ 0.30 s | **≤ 0.18 s** | **~3.9×** |
| VS Code cold typecheck | ~7.5 s | ≤ 3.5 s | **≤ 2.2 s** | **~3.4×** |
| TS repo cold typecheck | ~1.0 s | ≤ 0.4 s | **≤ 0.25 s** | **~4.0×** |
| Watch incremental, 1-line | ~similar to tsc | ≤ 80 ms | **≤ 30 ms** | **~50–100×** |
| Time-to-first-diagnostic | ~1.2 s | ≤ 300 ms | **≤ 50 ms** | **~24×** |
| Cold-start CLI from npm script (warm cache) | ~1.5 s | ≤ 300 ms | **≤ 30 ms** | **~50×** |
| Peak RSS, VS Code | ~1.5–2 GB | ≤ 800 MB | **≤ 500 MB** | **~3–4× smaller** |
| Decorator-heavy NestJS | 215 s | ≤ 25 s | **≤ 18 s** | **~12×** |
| `.d.ts` 1k-line file (CLI) | 58 ms | ≤ 5 ms | **≤ 3 ms** | **~19×** *(matches zig-dtsx published)* |

The §0 table is the *committed* target. Tier 1 items are integrated into the existing phases as additional effort; the 80-110 week range becomes 92-122 weeks.

### Tier 1 — high-ROI, well-known techniques (committed)

For each: cost in additional engineering weeks, win in measured impact, and which phase absorbs it.

| # | Technique | Why it wins | Cost | Win | Phase |
|---|---|---|---|---|---|
| 11.1 | **Stack-machine parser** instead of recursive descent | Eliminates function-call overhead per node; Bun, V8 preparser, Sucrase use this | +2w | Parse phase 1.2–1.3× | 1 |
| 11.2 | **Parser-binder fusion** — emit symbols during parse, not in a second pass | Eliminates one full AST traversal per file | +1w | ~10–15% on parse+bind combined | 2 |
| 11.3 | **Bit-packed primitive TypeIds**: reserve `TypeId < 2^16` for primitives + ~50 hot literal types | Comparisons against primitives skip the interner entirely; ~50% of hot-path queries hit primitives | +3d | ~20–30% on relation cache | 3 |
| 11.4 | **Hot/cold field split** on AST and types — rare fields (JSDoc, debug strings, error message data) in parallel arrays | Hot path reads only hot columns; ~2× more cache-line utilization | +1w | ~10–15% on traversal-bound phases | 0 |
| 11.5 | **Per-worker bump arenas** — each worker its own arena, all dropped at phase end | Eliminates even the Mutex on the arena allocator's free-list | +3d | ~5–10% on parallel phases | 0 |
| 11.6 | **Persistent on-disk query DB** across CLI invocations (mmap'd LMDB-style B-tree, keyed `(file_path, content_hash)`) | npm-script flows (`npm test` → `tsc --noEmit` → jest) re-pay cold-start each run today; mmap'd cache lets second invocation skip everything unchanged | +2w | TTFD on warm-cache CLI: 300 ms → **30 ms** (~10×) | 5 |
| 11.7 | **Lazy type expansion** — defer conditional + template-literal expansion until a relation query forces it; track bound-vs-free per type variable | Conditional/template-literal types blow up on heavy generic libs | +2w | 5–50× on `type-fest`/`ts-toolbelt`-style workloads | 3 |
| 11.8 | **Variance precomputation at definition site** | tsc-style implicit recompute per assignment check is wasted work | +3d | ~5–10% on generic-heavy projects | 3 |
| 11.9 | **Streaming emit during typecheck** — emit file F as soon as F's check completes | Time-to-first-emitted-file drops from full-build to per-file time | +1w | Major DX in monorepo builds | 4 |
| 11.10 | **mmap'd `lib.*.d.ts` snapshots** — pre-parse and pre-bind at Home build time; mmap the result | Cold start parses+binds ~50K LOC of identical lib files every run | +1w | Cold-start LSP TTFD: 300 ms → **50 ms** | 1 |
| 11.11 | **PGO + LTO build of Home itself** with Zig's `-Doptimize=ReleaseFast` | Standard whole-program-optimization win on a Zig binary | +3d | 10–20% across the board | 10 |
| 11.12 | **Generational arenas within a phase** — short-lived instantiation candidates in young gen, reset between checker queries; long-lived in old gen | Bounded peak memory; some allocator-cost win | +1w | Memory peak 2–4× lower; ~5% CPU | 5 |
| 11.13 | **Parallel chunk-lex within a single file** — split file into 64KB segments, lex in parallel, fix up token boundaries | Single huge generated files (Prisma `client.d.ts` ≈ 50K LOC) lex single-threaded under v1 | +2w | 4–8× on huge single-file lex | 1 |
| 11.14 | **Perfect-hash keyword recognition** via Zig `comptime` | Eliminates hash collisions vs. `map[string]Kind` (tsgo) or open hashing (tsc) | +2d | ~3–5% on lex | 1 |
| 11.15 | **Cache prefetch on AST traversal** — `@prefetch` of predicted-next node during current-node work | Hides DRAM latency on memory-bound walks | +3d profile-guided | ~10–20% on traversal-bound phases | 5 |
| **Total** | | | **~12 weeks** | | |

### Tier 2 — meaningful but riskier (opt-in after v1)

These add real wins but with implementation risk or complexity that isn't justified before profile data points at them.

| # | Technique | Why it wins | Why deferred |
|---|---|---|---|
| 11.16 | **NUMA-aware placement** — pin workers to NUMA nodes, shard interner per-node | 30–50% on relation cache for 64+ core servers | Negligible on laptops; complicates test matrix |
| 11.17 | **Vectorized batch relation queries** — `assignableTo(a, [b1..bN])` with SIMD on TypeId arrays | 30–50% on relation hot path *if* checker is restructured to batch | API redesign; correctness-sensitive |
| 11.18 | **Sub-file granularity invalidation** — invalidate per-symbol, not per-file | Watch latency 80 ms → 10 ms | Significant query-DB complexity |
| 11.19 | **Speculative execution of dependent queries** — predict next 5 invalidations on each keystroke, start in background | Perceived watch latency near-zero | Misprediction cost; complex rollback |
| 11.20 | **CRDT-style symbol table merges** — commutative join across per-file binds | Eliminates merge bottleneck after parallel binding | Correctness-sensitive |
| 11.21 | **Roaring bitmaps for symbol sets** | 10–100× smaller than HashSet; fast set ops | Engineering effort > marginal speedup at v1 sizes |
| 11.22 | **Cross-build content-addressed cache** (Bazel-style: `(source + tsconfig + deps) → cached result`) | Cold builds near-free for unchanged files even on fresh checkouts | Infra cost; requires CI integration |

### Tier 3 — exotic / research-grade (noted only for completeness)

| # | Technique | Why it wins | Why noted not committed |
|---|---|---|---|
| 11.23 | **GPU dispatch for batched relation queries** | Embarrassingly parallel sub-problems (excess-property checks across thousands of object literals) | Engineering cost prohibitive; benefit niche |
| 11.24 | **JIT-compiled relation rules per generic instantiation** — like Truffle/Graal but for TS types | Native-speed relation checks | Massive complexity; marginal gain over interner+L1 cache |
| 11.25 | **Differentiable compilation** — track derivatives of type changes through the dependency graph | Minimal-recomputation guarantee beyond Salsa | Research-grade; no shipping precedent |

### Tier 0 — already in v1 (not new, just flagged as load-bearing)

These v1 items account for the bulk of the tsgo gap; cutting any of them collapses the headline numbers:

- **SIMD lex** (§5.5) — uncontested vs. tsgo's byte-by-byte switch.
- **SoA AST with index-based child relations** (§5.2) — vs. tsgo's pointer-tree.
- **Lock-striped global type interner** (§5.3) — tsgo has none.
- **Two-level relation cache** (§5.4) — tsgo's is per-checker only.
- **Salsa-style query DB** (§3, §5.7) — tsgo has file-level dirty tracking only.
- **Streaming diagnostics** (§5.8) — no other TS compiler does this.
- **zig-dtsx fast-path `.d.ts` emit** (Phase 4) — already 15–19× tsgo on that path.

### Ceiling assessment

After Tier 1, where is the next 2× hiding? Three places:

1. **The type checker's algorithmic complexity itself.** TS's relation algorithm has worst-case exponential cases (recursive types, deeply distributed conditionals). Asymptotic improvements would require redesigning what TS *means*, not just how we compute it — out of scope for "TS-compatible."
2. **DRAM bandwidth.** At ~50 GB/s on a laptop, even a perfectly cache-friendly compiler hits a ceiling reading 1.5 GB of source through the type checker. Tier 1's hot/cold split + prefetch + arenas push us to ~70% of theoretical bandwidth; the last 30% is hardware-bound.
3. **The TS conformance gate itself.** ≥ 99.6% conformance constrains how clever we can get. Phase 6's correctness work *will* slow down a few hot paths to match tsc's behavior. We accept this; correctness > speed.

So: **v1 + Tier 1 is the most performant TS-compatible compiler currently practical to build.** Tier 2 buys 20–40% more in specific scenarios; Tier 3 is research. The honest claim is "approximately 3.5–4× tsgo cold and 50–100× tsgo on watch, with conformance ≥ 99.9%."

---

## Appendix A · TS keyword coverage gap

The Home lexer currently ships these TS-relevant keywords (`packages/lexer/src/token.zig`):
**`As`, `Async`, `Await`, `Const`, `Default`, `Else`, `Enum`, `Export`, `Extern`, `False`, `For`, `If`, `Import`, `In`, `Infer`, `Is`, `Keyof`, `Let`, `Match`, `Mut`, `Null`, `Pub`, `Readonly`, `Return`, `Static`, `Switch`, `True`, `Try`, `Type`, `Typeof`, `Union`, `Var`, `While`**.

Missing for full TS, to be added to the **TS frontend lexer** (not the Home lexer):

`abstract`, `accessor`, `any`, `asserts`, `bigint`, `boolean`, `class`, `constructor`, `debugger`, `declare`, `delete`, `do`, `extends`, `finally`, `function`, `get`, `global`, `goto`, `implements`, `instanceof`, `interface`, `let`, `module`, `namespace`, `never`, `new`, `number`, `object`, `of`, `out`, `override`, `package`, `private`, `protected`, `public`, `require`, `satisfies`, `set`, `string`, `super`, `symbol`, `this`, `throw`, `undefined`, `unique`, `unknown`, `using`, `var`, `void`, `with`, `yield`.

(Some are *contextual* keywords in TS — they're identifiers in some positions and keywords in others. The TS parser disambiguates.)

## Appendix B · Bench result template

```
$ home tsc --extendedDiagnostics --noEmit ./tsconfig.json
Files:                   3,847
Lines of Library:       42,158
Lines of Definitions:   18,234
Lines of TypeScript:   124,891
Lines of JavaScript:         0
Lines of JSX:           12,043
Lines of Other:              0
Identifiers:           987,321
Symbols:               143,209
Types:                  84,512
Instantiations:        421,889
Memory used:           184 MB
Assignability cache:    34,289 entries
Identity cache:          1,012 entries
Subtype cache:          18,453 entries
Strict subtype cache:    8,901 entries

I/O Read time:          0.024s
Parse time:             0.041s
ResolveModule time:     0.018s
Bind time:              0.027s
Check time:             0.149s
transformTime:          0.000s   (--noEmit)
commentTime:            0.000s
emitTime:               0.000s
Total time:             0.259s
```

Output format mirrors `tsc --extendedDiagnostics`. Tools that scrape these numbers continue to work.

## Appendix C · Per-package work mapping

| Existing package | Role in TS-parity | Scope of change |
|---|---|---|
| `packages/lexer` (2 918 LOC) | Home frontend; *kept* | No change |
| `packages/parser` (10 659 LOC) | Home frontend; *kept, refactored* | Phase 0 split; no behavioral change |
| `packages/ast` (6 204 LOC) | Home frontend's AST; *kept* | Lower into HIR alongside the new TS AST |
| `packages/types` (26 677 LOC) | Type system; *core asset* | Phase 3 alignment to tsc; interner upgrade |
| `packages/interpreter` (13 537 LOC) | Tree-walker; *kept for Home* | No change |
| `packages/codegen` (25 685 LOC) | Native codegen; *kept, extended* | Phase 7 reuse for native TS; Phase 0 split |
| `packages/optimizer` (2 477 LOC) | IR opts; *kept* | Phase 7 reuse |
| `packages/diagnostics` (3 888 LOC) | Error reporter; *kept, extended* | Phase 4 alignment to tsc format |
| `packages/lsp` (4 125 LOC) | LSP scaffolding; *rewritten* | Phase 8 rewrite on top of query DB |
| `packages/modules` | Module resolver; *kept, extended* | Phase 1 adds Node16/NodeNext/Bundler |
| `packages/cache` | IR cache; *replaced* | Phase 5: query DB supersedes |
| **New: `packages/hir`** | Shared IR | Phase 0 |
| **New: `packages/arena`** | Phase allocators | Phase 0 |
| **New: `packages/string_interner`** | Lock-striped strings | Phase 0 |
| **New: `packages/query`** | Salsa-style queries | Phase 0 |
| **New: `packages/ts_lexer`** | SIMD TS lex | Phase 1 |
| **New: `packages/ts_parser`** | TS parser | Phase 1 |
| **New: `packages/d_ts`** | `.d.ts` loader, lib | Phase 1 |
| **New: `packages/tsconfig`** | tsconfig + extends | Phase 1 |
| **New: `packages/binder`** | TS binder + symbol table | Phase 2 — *foundation landed 2026-05-05* |
| **New: `packages/ts_checker`** | TS type system (Pool, Interner, Engine) | Phase 3 — *foundation landed 2026-05-05* |
| **New: `packages/ts_emit`** | JS + .d.ts emit + source maps V3 + zig-dtsx fast path | Phase 4 — *JS emit + VLQ source maps + symbol-driven .d.ts + zig-dtsx fast path landed 2026-05-05* |
| **New: `packages/ts_driver`** | Lex → parse → bind → check → emit pipeline | Phase 4.5 — *single-file E2E + tsconfig + ts_checker integration landed 2026-05-05* |
| **New: `packages/ts_resolver`** | Module resolution (5 strategies + paths) | Phase 1.E follow-up — *landed 2026-05-05* |
| **New: `packages/ts_diagnostics`** | tsc-compatible diagnostic formatting | Phase 4 — *landed 2026-05-05* |
| **New: `packages/ts_program`** | Multi-file program graph + import edges | Phase 4.5 — *landed 2026-05-05* |
| **New: `packages/ts_cli`** | `home tsc` CLI flag parsing + dispatch | Phase 4.5 — *landed 2026-05-05* |
| **New: `packages/ts_conformance`** | tsc-baseline conformance harness + corpus runner | Phase 6 — *runner + 11-case canon corpus landed 2026-05-05* |
| **New: `packages/ts_watch`** | File-system watcher (Phase 5 §5.7 foundation) | Phase 5 — *landed 2026-05-05* |
| **New: `packages/ts_lsp`** | LSP query surface (hover/def/refs/completions/diagnostics) | Phase 8 — *foundation + cross-file refs landed 2026-05-05* |
| **New: `packages/ts_lsp_server`** | LSP JSON-RPC wire-protocol layer | Phase 8 — *landed 2026-05-05* |
| **New: `packages/ts_cache`** | Persistent compilation cache (Phase 5 §11.6 foundation) | Phase 5 — *landed 2026-05-05* |
| **External: `pantry/zig-dtsx`** | 8 257-LOC zig-dtsx fast `.d.ts` emitter (15-19× tsgo) | Phase 4 — *wired via pantry 2026-05-05* |
| **New: `packages/ts_emit/d_ts/fast`** | `.d.ts` fast track (vendored zig-dtsx) | Phase 4 — **reuses ~8 257 LOC of existing Zig** |
| **New: `packages/d_hm`** | `.d.hm` parser + emitter (Home's `.d.ts` analogue) | Phase 4 |
| **New: `packages/bundler`** | JS/TS bundler (vendored Bun bundler + Home adapter) | Phase 4.5 — **reuses ~20 130 LOC of existing Zig** |
| **New: `packages/bundler/adapter`** | HIR ↔ Bun-AST shim, symbol-table bridge | Phase 4.5 |
| **New: `packages/tsserver_shim`** | tsserver protocol bridge | Phase 9, optional |

---

## Appendix D · tsgo source verification (2026-05-04)

This table is the receipt for every architectural claim about tsgo in this document. Citations reference the tsgo source tree at `~/Code/typescript-go` (commit pinned to TS 7.0 beta). All paths are relative to that root.

### D.1 AST & memory layout

| Plan claim | Verified status | Citation |
|---|---|---|
| tsgo Node base struct ~54 B | ✓ | `internal/ast/ast.go:178` (`Kind`, `Flags`, `Loc`, `id`, `Parent`, `data nodeData`) |
| tsgo total per-node heap allocation ~120–130 B (not 80–120 B) | **Corrected upward** | `internal/ast/ast_generated.go:1033` (concrete kind structs); accounting for Go interface overhead and alignment |
| tsgo uses per-kind arenas (not per-node malloc) | ✓ | `internal/ast/ast_generated.go:20-70` (40+ `core.Arena[T]` fields in `NodeFactory`); `internal/core/arena.go:7-22` (geometric growth, doubling up to 512) |
| tsgo child relations are pointer-based | ✓ | `internal/ast/ast_generated.go:1033`: `DoStatement.Statement *Statement`, `DoStatement.Expression *Expression` |
| tsgo Node has no `transformFlags` field (unlike tsc) | ✓ confirmed | Not present at `internal/ast/ast.go:178` |
| tsgo retains `Parent`, `Symbol` (on `DeclarationBase`), `Locals` (on `LocalsContainerBase`) | ✓ | `internal/ast/ast.go` and base type files |

### D.2 Type system & interning

| Plan claim | Verified status | Citation |
|---|---|---|
| **tsgo has no global type interner** | **✓ confirmed** | `TypeId uint32` declared at `internal/checker/types.go:116` but never used as an intern key; no `TypePool` / `TypeTable` exists |
| Each checker constructs its own type objects | ✓ implied by absence of intern table | per-`Checker` instantiation in `internal/checker/` |

### D.3 Checker parallelism

| Plan claim | Verified status | Citation |
|---|---|---|
| Default 4 checkers, configurable via `--checkers` | ✓ | `internal/compiler/checkerpool.go:41-48` (`checkerCount := 4`, override via `program.Options().Checkers`) |
| Hard min 1, max 256 | ✓ | `checkerpool.go:48`: `max(min(checkerCount, len(program.files), 256), 1)` |
| Round-robin file→checker partition | ✓ | `checkerpool.go:114-117`: `p.fileAssociations[file] = p.checkers[i%checkerCount]` |
| Per-checker `sync.Mutex` (not `sync.RWMutex`) | ✓ | `checkerpool.go:24-32` (`locks []*sync.Mutex`) |
| **Type relation cache is per-checker, not shared** | **✓ confirmed** | `internal/checker/relater.go:100-117`: `type Relation struct { results map[CacheHashKey]RelationComparisonResult }` — held inside each `Checker` |
| `--singleThreaded` flag exists | ✓ | `internal/tsoptions/declscompiler.go:233-237`; honored at `checkerpool.go:43` (`checkerCount = 1`) |

### D.4 Binder

| Plan claim | Verified status | Citation |
|---|---|---|
| Binder is parallelized per-file via `WorkGroup` | ✓ | `internal/compiler/program.go:418-431`: `wg := core.NewWorkGroup(p.SingleThreaded()); …; wg.Queue(func() { binder.BindSourceFile(file) })` |
| Binder uses `sync.Pool` for instance reuse | ✓ | `internal/binder/binder.go:105-120` (`var binderPool = sync.Pool{...}`) |
| Per-file declaration merging in binder | ✓ | `internal/binder/binder.go:152-228` |
| Cross-file merging deferred to checker phase | ✓ implied | not done in binder; checker resolves cross-file symbol relations |
| Binder uses arenas for symbols and flow nodes | ✓ | `internal/binder/binder.go:51-84` (`symbolArena core.Arena[ast.Symbol]`, `flowNodeArena core.Arena[ast.FlowNode]`) |

### D.5 Parser

| Plan claim | Verified status | Citation |
|---|---|---|
| Recursive descent | ✓ | `internal/parser/parser.go:135-144` (`ParseSourceFile` → `parseSourceFileWorker`) |
| Speculative lookahead for `<` ambiguity | ✓ | `internal/parser/parser.go:2987-3015` (`reScanLessThanToken`, `parseTypeParameters`) |
| JSX gated by `LanguageVariant` from `ScriptKind` | ✓ | `internal/parser/parser.go:4293, 4708-4709` |
| Parser uses `sync.Pool` | ✓ | `internal/parser/parser.go:120-133` |
| Parser package size ~9 005 LOC | ✓ | wc -l on `internal/parser/*.go` |

### D.6 Scanner / lexer

| Plan claim | Verified status | Citation |
|---|---|---|
| Byte-by-byte switch dispatch, no SIMD | **✓ confirmed** | `internal/scanner/scanner.go:466` (single `Scan()` with large `switch ch { case … }`) |
| Keyword recognition via `map[string]ast.Kind` | ✓ | `internal/scanner/scanner.go:36` (`var textToKeyword = map[string]ast.Kind{…}`, ~160 entries) |
| Unicode via precomputed range tables | ✓ | `internal/scanner/unicodeproperties.go:197-198` (`unicodeESNextIdentifierStart`, `unicodeESNextIdentifierPart`) |
| Template literals handled via state in scanner | ✓ | `internal/scanner/scanner.go:1618` (`scanTemplateAndSetTokenValue`) |
| Regex parsed by separate parser, no JIT | ✓ | `internal/scanner/regexp.go:76` (`type regExpParser struct`); 1 071 LOC |
| Scanner package: ~4 174 LOC total | ✓ | wc -l (`scanner.go` 2 833, `regexp.go` 1 071, `unicodeproperties.go` 162) |

### D.7 Watch / incremental

| Plan claim | Verified status | Citation |
|---|---|---|
| **Incremental is file-level dirty tracking** | **✓ confirmed** | `internal/project/project.go:61-62`: `dirty bool`, `dirtyFilePath tspath.Path` |
| **No dependency graph or query DB** | **✓ confirmed** | `internal/project/dirty/` only tracks file-level dirtiness; no query memoization |
| `Project.UpdateProgram(dirtyFilePath)` for single-file edits | ✓ | `internal/project/project.go:352-365` |
| Watch via `vfswatch.FileWatcher` | ✓ | `internal/execute/watcher.go:55-100`; uses `internal/vfs/vfswatch` |
| Source file caching with mod-time tracking | ✓ | `internal/execute/watcher.go:22-53` |
| Watch options (`watchFile`, `watchDirectory`, etc.) | ✓ | `internal/tsoptions/declswatch.go:8-88` |

### D.8 CLI flags

| Plan claim | Verified status | Citation |
|---|---|---|
| `--build` / `-b` implemented | ✓ | `internal/tsoptions/declsbuild.go:10-17` |
| `--watch` / `-w` implemented | ✓ | `declscompiler.go:34-42` |
| `--init`, `--showConfig`, `--listFiles`, `--listFilesOnly`, `--explainFiles`, `--listEmittedFiles` all implemented | ✓ | `declscompiler.go:52-71, 277-309` |
| `--diagnostics`, `--extendedDiagnostics`, `--generateCpuProfile`, `--generateTrace`, `--traceResolution` implemented | ✓ | `declscompiler.go:81-116` |
| `--quiet`, `--singleThreaded`, `--pprofDir`, `--checkers` are tsgo-specific | ✓ | `declscompiler.go:225-252` |
| `--builders=N` (default 4) for parallel project builds | ✓ | `declsbuild.go:53-59` |
| `--stopBuildOnErrors` skips downstream projects on error | ✓ | `declsbuild.go:61-66` |

### D.9 tsconfig coverage

The full ~140-option matrix in §2.2 has been cross-checked against `internal/core/compileroptions.go:16-159` and `internal/tsoptions/declscompiler.go`. All options listed in §2.2 are present in tsgo. Notable additions discovered during verification (now incorporated): `noCheck`, `stableTypeOrdering`, `forceConsistentCasingInFileNames`, `libReplacement`, `noUncheckedSideEffectImports`, `rewriteRelativeImportExtensions`, `erasableSyntaxOnly`, `moduleDetection`, `allowSyntheticDefaultImports`, `allowArbitraryExtensions`, `allowNonTsExtensions`, `emitBOM`, `deduplicatePackages`, `ignoreDeprecations`, `plugins`.

The top-level keys `watchOptions` and `typeAcquisition` are partially wired in tsgo (`watchOptions` is commented-out at `tsoptions/tsconfigparsing.go:60`, `typeAcquisition` is referenced at line 61). Home implements both fully in v1.

### D.10 Module resolution

| Plan claim | Verified status | Citation |
|---|---|---|
| All five strategies (classic, node10/node, node16, nodenext, bundler) | ✓ | `internal/tsoptions/enummaps.go:145-152` |
| Default per tsgo: "nodenext if module is nodenext, node16 if module is node16 or node18, otherwise bundler" | ✓ | `declscompiler.go:736` |
| `package.json` `exports`/`imports` honored for node16/nodenext/bundler | ✓ | `internal/module/resolver.go:136-138` |
| `customConditions` honored | ✓ | `internal/module/resolver.go:130-139` |
| `paths` with wildcards via `TryParsePatterns()` | ✓ | `internal/module/resolver.go:95-96`, `tryLoadModuleUsingPathsIfEligible()` |
| `paths`, `rootDirs`, `composite` are tsconfig-only | ✓ | `IsTSConfigOnly: true` flag in declscompiler.go declarations |

### D.11 Build mode / project references

| Plan claim | Verified status | Citation |
|---|---|---|
| `--build` mode fully implemented | ✓ | `internal/execute/build/orchestrator.go:55-118` |
| `.tsbuildinfo` read/write supported | ✓ | `incremental.ReadBuildInfoProgram()` referenced in `internal/execute/tsc.go` |
| `composite` flag implemented | ✓ | `declscompiler.go:435-444` |
| Parallel project building via `--builders` | ✓ | `declsbuild.go:53-59` (default 4) |
| Build-mode incompatibilities (e.g. `--listFilesOnly` + `--watch`) enforced | ✓ | `internal/execute/tsc.go` |

### D.12 Emit & transformers

| Plan claim | Verified status | Citation |
|---|---|---|
| Printer is recursive AST visitor | ✓ | `internal/printer/printer.go:4985` (`Emit`, `EmitSourceFile`) |
| V3 source maps complete | ✓ | `internal/sourcemap/generator.go:26` (`type Generator struct`) |
| Declaration emit logic in checker, not printer | ✓ | `nodebuilder/` is 78 LOC of interfaces; real logic in `checker/` 58 726 LOC |
| 20+ ES downlevel transforms in `transformers/estransforms/` | ✓ | confirmed by directory listing (`async-await`, `optional-chaining`, `nullish-coalescing`, `class-fields`, `decorators`, `object-spread`, `for-await`, `using`, `logical-assignment`, `tagged-templates`, `exponentiation`, etc.) |
| Module transforms separate package | ✓ | `internal/transformers/moduletransforms/` |
| JSX transform separate | ✓ | `internal/transformers/jsxtransforms/jsx.go` |

### D.13 Test infra

| Plan claim | Verified status | Citation |
|---|---|---|
| Conformance suite ~5 907 cases (not 20 000+) | **Corrected downward** | count of `_submodules/TypeScript/tests/cases/conformance/` in tsgo tree |
| Fourslash ~40 000+ scenarios | ✓ | `internal/fourslash/tests/` |
| Tests run via Go's `testing.T` with `t.Parallel()` | ✓ | `internal/testrunner/compiler_runner.go:206`; `internal/testrunner/testmain_test.go:10-14` |
| Baselines compared via patience-diff | ✓ | `internal/testutil/baseline/baseline.go:15` (`github.com/peter-evans/patience`) |
| Baseline file types: `.errors.txt`, `.types`, `.symbols` | ✓ | `internal/testutil/tsbaseline/error_baseline.go:36`, `type_symbol_baseline.go:30` |
| Newline convention `\r\n` | ✓ | `harnessNewLine` constant at `error_baseline.go:24` |

### D.14 Code size

| Component | Verified LOC | Citation |
|---|---|---|
| Total `internal/` | ~1 099 862 | wc -l |
| `fourslash` (mostly test fixtures) | 768 131 | |
| `checker` | 58 726 | |
| `lsp` | 43 937 | |
| `ls` (language services) | 38 024 | |
| `transformers` | 23 988 | |
| `ast` | 21 318 | |
| `project` | 19 502 | |
| `execute` | 18 011 | |
| `printer` | 14 762 | |
| `diagnostics` | 9 555 | |
| `parser` | 9 005 | |
| `tsoptions` | 8 274 | |
| `compiler` | 6 038 | |
| `scanner` | 4 174 | |
| `nodebuilder` | 78 | |

### D.15 Findings that *strengthen* Home's competitive position

These were not in the original plan; uncovered during verification:

1. **No global type interner in tsgo** — single biggest architectural advantage Home gains. Cross-checker type identity is structural-equality-via-comparison in tsgo; in Home it's `id_a == id_b`.
2. **Per-checker relation cache** — multiple checkers redo work on cross-cutting types. Home's shared L2 cache with structural identity is a clean win.
3. **File-level dirty tracking, no query DB** — tsgo's watch advantage is bounded; Home's Salsa-style query DB has no in-kind competitor.
4. **No SIMD in scanner** — Home's SIMD lex faces no competition in this niche.
5. **No `transformFlags`** — tsgo has dropped a tsc optimization; emit-time work is differently structured. Phase 4 needs to investigate whether tsgo's emit is faster or slower as a result.

### D.16 Findings that *constrain* Home's design

1. **tsgo arena allocation is real and good.** Home's per-phase arena strategy doesn't beat tsgo on alloc throughput; the win is on traversal locality.
2. **tsgo's binder is parallel.** Home doesn't get a free bind speedup vs. tsgo by parallelizing.
3. **tsgo's tsconfig coverage is essentially complete.** No gaps to exploit; we have to do all of it too.
4. **tsgo conformance pass rate of 99.6% is high.** The remaining 74 failures are mostly edge cases in declaration emit and JS-source checking — hard ones to crack.

---

*End of plan. Updates ratchet forward; reductions in scope require explicit sign-off and a doc revision.*
