# TypeScript Parity Plan — Home

> **Status:** Phase 0 in progress (started 2026-05-04). Authored 2026-05-04. Verified against tsgo source 2026-05-04 (see Appendix D).
>
> Cross-references: [`ARCHITECTURE.md`](./ARCHITECTURE.md), [`COMPILER_PIPELINE.md`](./COMPILER_PIPELINE.md), [`CAPABILITY_MATRIX.md`](./CAPABILITY_MATRIX.md), [`ROADMAP-WEB-COMPETITIVE.md`](./ROADMAP-WEB-COMPETITIVE.md).
>
> **Source verification.** All claims about tsgo internals in this document have been verified against the tsgo source tree at `~/Code/typescript-go` (Go port of `tsc` from microsoft/typescript-go). Citations use the form `path/file.go:line` referencing that tree. See Appendix D for a full verification table.

---

## Process State

**Last updated:** 2026-05-05
**Current phase:** Phase 3 type checker substantially complete — generic instantiation (incl. explicit-type-args), structural object assignability, signatures, narrowing (typeof + null + else-branch + instanceof against the real class instance type), arrow-fn signatures, discriminated-union narrowing, object-literal/array-literal inference, **class member resolution + instance type lowering (`new Foo()` → instance shape, `b: Box` parameter types resolve)**, member access typing with TS2339, argument count + type diagnostics (TS2554/TS2345). Phase 8 LSP wire-protocol layer + `home-lsp` stdio binary; Phase 4.5 `home-tsc` binary compiles + emits to disk. Phase 5 incremental rebuild flow, persistent on-disk compilation cache, and multi-file cache wiring all landed.
**Active deliverable:** Phase 6 — full TS conformance corpus integration; Phase 7 — native codegen for typed TS subset; Phase 4.5 — bundler integration

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

**Phase 1 follow-ups (mechanical, gated by per-feature tests):** ✅ control flow (if/while/for/switch/try) landed 2026-05-05; ✅ function/class/interface/enum/namespace declarations landed 2026-05-05; ✅ imports/exports incl. type-only forms landed 2026-05-05; ✅ array + object literals (incl. shorthand/method/computed) + this/super/new landed 2026-05-05; ✅ var_decl/let_decl/const_decl HIR nodes (replacing assignment lowering) landed 2026-05-05; ✅ full type-annotation parsing (primitives, type refs, qualified names, unions, intersections, arrays, tuples, fn/constructor types, indexed access, keyof, typeof, infer, conditional, mapped, literal types) landed 2026-05-05; ✅ arrow functions (with the `(T) => U` ambiguity resolved by speculative parse) landed 2026-05-05; ✅ generic type parameters on function/class/interface/type-alias decls (with `extends` constraints, `=` defaults, `in`/`out` variance modifiers) landed 2026-05-05; ✅ JSX/TSX parsing (structured form — elements, attributes, expression children, fragments, member-access tags) landed 2026-05-05. *Remaining:* decorators (legacy + Stage 3) — currently parsed and discarded; template literal substitutions (parser-driven `rescanTemplate` after each interpolated expression); regex literal scanning (parser-driven `rescanSlashAsRegex`); free JSX text content (requires lexer mode switching); full Unicode ID-Start / ID-Continue tables; lib loading.

### Phases ahead

| Phase | Status | Notes |
|---|---|---|
| 2 — Binder + symbol table | 🟡 foundation landed | `packages/binder/` ships value/type/namespace meaning-spaces, scope graph, declaration merging (interface+interface, class+namespace, enum tri-space). Phase 2 follow-ups: parser emits dedicated `var_decl` nodes for hoisting; cross-file `Module.augment(other)` for `declare global` and module augmentation. |
| 3 — Type checker | 🟡 foundation landed | `packages/ts_checker/` ships SoA Pool, structural Interner with sort+dedup canonicalization, RelationCache + Engine with the four core relations (identity/assignable/subtype/comparable). HIR → type lowering, generic instantiation, mapped/conditional evaluation, narrowing, variance are Phase 3 / 6 follow-ups. |
| 4 — JS emit + .d.ts + .d.hm | 🟡 JS emit + .d.hm scaffold landed | `packages/ts_emit/` streams JS for the full Phase 1 surface (statements + expressions, with TS-only constructs erased). `packages/d_hm/` ships the lib catalog and Loader scaffold. Symbol-driven `.d.ts` re-printer + zig-dtsx fast-path integration are Phase 4 follow-ups. |
| 4.5 — Bundler integration | ⬜ blocked-by Phase 4 follow-ups | |
| 5 — Performance engineering | ⬜ blocked-by Phase 4 | |
| 6 — Conformance hardening | ⬜ blocked-by Phase 5 | |
| 7 — Native codegen for TS | ⬜ blocked-by Phase 6 | |
| 8 — LSP | ⬜ blocked-by Phase 5 | |
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
- **2026-05-05 — Class member resolution + instance type lowering.** `class_decl` now lowers to an interned object TypeId via `internObjectType` (members = declared fields with optional type annotation or initializer-inferred type, plus method signatures keyed by name; constructors are walked for body typing but excluded from the instance shape). The class name maps to its instance TypeId in a new `class_instance_types` table on the checker. `new Foo(args)` is now lowered as a dedicated `new_expr` HIR node (not a 0-arg call wrapper around `Foo(args)` as before) — the parser uses a new `parseMemberExpressionOnly` for the new-target so the parenthesized argument list belongs to the `new`, not to a call. `new_expr` typing produces the class instance type when the callee is a known class identifier; falls back to `any` otherwise. `instanceof Foo` narrowing now reaches into `class_instance_types` and narrows to the actual instance shape (vs. the prior `Primitive.object_t` fallback). Type annotations like `b: Box` resolve via `lowererLowerWithTypeParams` consulting `class_instance_types` after the narrow scope, so parameters / let-decls typed as a declared class get the proper structural type — `function f(b: Box): number { return b.value; }` types `b.value` to `number_t` with no diagnostics. JS emitter gains `printNew` (`new ` prefix + same args). HIR gains `addNew` builder + an `addObjectPropertyTyped` variant carrying the class field's type annotation slot. `callOf` widened to accept `new_expr` payloads (same shape). Required parser test fixup: `new Foo(1, 2)` now produces `.new_expr` with 2 args (was `.call_expr` with 0 args). 4 new checker tests (instance-type shape, `new` typing, `instanceof` narrowing to instance, parameter resolution). `zig build test`: 1172 → 1176 (+4).

This is the canonical plan for evolving Home into a **drop-in TypeScript compiler that is measurably faster than tsgo**, while preserving Home's existing identity as a native-code language.

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

**Reuse strategy.** We embed the upstream `microsoft/TypeScript` repo as a git submodule at the same path tsgo uses (`_submodules/TypeScript/`), pinned to the same SHA tsgo pins. This guarantees apples-to-apples conformance numbers and avoids divergent test-pinning that would make our number incomparable to tsgo's.

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
| Conformance submodule SHA drifts from tsgo's | Low | Low | Pin to the same SHA tsgo pins; track tsgo's submodule update commits |
| zig-dtsx `.d.ts` output diverges from tsc on edge cases | Medium | Medium | A/B test against tsc on the conformance corpus before promoting fast-path as default; fall back to symbol-driven track on any divergence |
| zig-dtsx maintenance velocity diverges from Home's | Low | Medium | Vendor zig-dtsx as a submodule pinned to a known-good SHA; upstream improvements via PRs to stacksjs/dtsx |
| Bun bundler upstream divergence | Medium | Medium | Vendor as submodule pinned to a known-good SHA; thin adapter layer absorbs Bun's API churn; upstream non-Bun-specific fixes |
| Bundler output drifts from esbuild byte-equivalence | Medium | Low | Per-project byte-diff in CI on a 200-project corpus; chunk-naming determinism via stable hash |
| Type-check overhead dominates `home bundle` perf | Medium | High | `--skip-check` opt-out matches esbuild speed; default mode runs type checker in parallel with parse so wall-clock overhead is the *max*, not *sum* |

---

## 8 · Concrete next steps (week 1)

1. **Day 1.** Land this document at `docs/TS_PARITY_PLAN.md`, link from `docs/index.md` and `docs/ROADMAP-WEB-COMPETITIVE.md`. Open issues/milestones for Phases 0–10. Tag `ts-parity-v0` as the long-running development branch.
2. **Day 2.** Set up the bench harness skeleton at `bench/vs_tsgo/`. Run baseline on current Home compiler: tokens/sec, AST-bytes-per-LOC, watch-rebuild-ms.
3. **Day 3–4.** Spike the SoA AST: a 200-LOC prototype that lex/parses a small Home program into the new layout; measure footprint vs. current AST. Validate the column-layout choice with real numbers before committing.
4. **Day 5.** Commit Phase 0 packages skeletons (`packages/hir/`, `packages/arena/`, `packages/query/`) with empty-but-tested stubs. Begin parser-split refactor.

After week 1, the team executes Phase 0 in earnest.

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
