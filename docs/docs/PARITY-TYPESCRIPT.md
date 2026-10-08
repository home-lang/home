---
title: TypeScript Parity
description: Track Home's TypeScript parser, checker, emit, diagnostics, LSP, watch mode, and conformance status against upstream baselines.
---

# TypeScript parity

Detailed per-feature status for Home's TypeScript frontend
(`packages/ts_*`). This is the drill-down view; the at-a-glance
section is in the
[README parity status](/docs/PARITY-STATUS#typescript-parity--home-tsc-vs-tsc--tsgo).

> Corrected 2026-10-07: previous TypeScript corpus pass counts are withdrawn.
> The harness contained fixture-name expected-result replacements, copied
> baseline diagnostics, mismatch rescues and diagnostic filtering. Fresh actual
> measurements and the remaining input/options/library audit are tracked in
> [#840](https://github.com/home-lang/home/issues/840) and
> [#832](https://github.com/home-lang/home/issues/832). Feature statuses below
> also require revalidation wherever their evidence relied on this harness.

Legend:

- 🟢 **Fully implemented** — feature works end-to-end across the
  related conformance fixtures, no known false-positive or
  false-negative diagnostics.
- 🟡 **Partially implemented** — works for common shapes, has known
  gaps listed inline (anchored by fixture names).
- 🔴 **Not implemented** — recognized in the parser but no checker /
  emit support, or omitted entirely.

## Types

### Primitives & literals

🟢 `string`, `number`, `boolean`, `bigint`, `symbol`, `null`,
`undefined`, `void`, `never`, `unknown`, `any`, `object`, plus all
literal types (`"foo"`, `42`, `true`, `null`, `undefined`, BigInt
literals). Coercion / widening rules per upstream.

### Object types

🟢 Object-type literals, property optionality, readonly modifier,
index signatures (string / number / symbol), call + construct
signatures, method shorthand, getters / setters.

### Arrays & tuples

🟡 `T[]` / `Array<T>` — 🟢. Tuples — 🟡; arity + variadic
(`[A, ...T, B]`) work for common shapes, but
`unionsOfTupleTypes1` / `arityAndOrderCompatibility01` show
remaining gaps in TS2493 / TS2741 message shape and tuple-vs-union
distribution.

### Union & intersection

🟢 `A | B`, `A & B`, union narrowing via control flow, intersection
property merging, distribution into mapped types.

### Type aliases & interfaces

🟢 `type Alias = T` (generic + non-generic), `interface I { ... }`,
`extends` heritage chains, **same-scope declaration merging** for
interfaces (multi-way back-patched), cross-namespace merging via
namespace paths.

### Generics

🟡 Generic functions, classes, interfaces, type aliases — 🟢.
Variadic tuple generics — 🟡. Higher-order contextual generic
inference — 🟡 (`genericContextualTypes1` still has the higher-order
`compose` case open). `NoInfer<T>` utility — 🔴.

### Mapped types

🟡 Basic mapped types (`{ [K in keyof T]: ... }`) — 🟢. Homomorphic
mapped types — 🟢. `as` clause for key remapping — 🟢. Distributive
mapping over template literals — 🟡 (`templateLiteralTypes*`).

### Conditional types

🟡 Distributive over unions — 🟢. Deferred under generic alias
instantiation — 🟢. `infer` in extends clause — 🟢. `infer` outside
extends — explicitly rejected per TS1338 (correct). Recursion-depth
limits + non-Return `infer` structural matching — 🟡.

### Template literal types

🟡 Basic interpolation — 🟢. `${number}` / `${string}` /
`${bigint}` placeholders — 🟢. `Capitalize` / `Uncapitalize` /
`Uppercase` / `Lowercase` — 🟡. Complex pattern distribution
(`templateLiteralTypes1.ts(40+)`, `stringMappingOverPatternLiterals`) — 🟡.

### Indexed access types (`T[K]`)

🟢 `T[K]`, `T[keyof T]`, nested indexed access, distribution into
unions.

### keyof / typeof operators

🟢 `keyof T`, `typeof x`, `keyof typeof x`, `typeof X` over
qualified names. `typeof <non-identifier>` rejected per TS1003 — 🟡
(message shape diffs in `invalidTypeOfTarget`).

### Type predicates

🟢 `arg is T`, `asserts arg`, `asserts arg is T`. Fall-through
narrowing after `asserts`.

### Decorators

🟡 Legacy decorators (`experimentalDecorators: true`) — 🟢. Stage 3
decorators — 🟡 (helper shape + static-member contexts work; exact
initializer arrays / static blocks / auto-accessors are remaining).

### `as const` assertions

🟢 Literals → literal types, object literals → readonly recursion.

### `satisfies` operator

🟢 With proper preservation of the source type.

### Non-null assertion (`expr!`)

🟢 Subtracts `null | undefined` from operand.

### Optional chaining (`?.`)

🟢 Widens with `undefined`; integrates with nullish coalescing.

### Nullish coalescing (`??`)

🟢 Types as `(a minus null|undefined) | b`.

## Control flow

### Narrowing

🟢 `typeof x === 'primitive'` (with else-branch negation),
`x === null` / `!== null`, `x === undefined` / `!== undefined`,
`x instanceof Foo` (narrows to class instance type),
discriminated-union narrowing on equality, `"key" in obj` over
discriminated unions, `===` with literal RHS narrowing, `==` /
`!=` with null narrowing, `Array.isArray`, `typeof === 'object'`
keeping nullable when union has null.

### Definite assignment

🟢 `TS2454` (`X is used before being assigned`), `TS2564`
(`Property X has no initializer and is not definitely assigned in
the constructor`), `TS2532`/`TS2533` (possibly undefined / null
object).

### Evolving any

🟡 `var p;` → evolving-any at the declaration site (TS7034
fires). Per-use TS7005 emission on reads — 🟡 (cluster of
`tsxReactEmit*` and similar).

## Classes

🟢 Instance / static fields, methods, accessors, generic classes,
`extends`, `implements`, abstract members, `private` / `protected`
visibility, ECMAScript private fields (`#x`), static blocks,
constructor parameter properties, `this` / `super` typing,
`override` modifier (TS4114 / TS4115 / TS4116), `strictPropertyInitialization`
(TS2564), incompatible-override (TS2416), structural implements
(TS2420). N-way **interface declaration merging** lands; class /
interface merging — 🟡.

## Modules

### Import / export forms

🟢 `import x from 'm'`, `import { a, b } from 'm'`,
`import * as ns from 'm'`, `import 'm'` (side-effect), `import type`,
`import { type X }`, dynamic `import(...)`. Equivalent export forms
plus `export * from`, `export * as ns from`, `export { x } from`,
`export type`, `export default`. Re-export module-resolution
TS2307 emits.

### Module resolution

Home's compiler-option dialect follows native TypeScript 7. Legacy
TypeScript 6 options are parsed only far enough to produce the corresponding
TypeScript 7 removed-option diagnostic; `ignoreDeprecations` does not switch
the frontend to an older dialect. Consequently, TS6-only configurations are
reported separately and are not admitted into shared multi-compiler
benchmarks. Removed options retain their `tsconfig.json` key/value source
anchor as appropriate ([#847](https://github.com/home-lang/home/issues/847)).

🟡 `classic`, `node10`, `node16`, `nodenext`, `bundler` strategies
all parse, but TypeScript 7 rejects `classic` and `node10` before resolution.
Nodenext / node16 path semantics — 🟢.
`bundler` with `customConditions` / `exports` / `imports` — 🟡
(many fixtures in slice 0-100 are bundler-mode).
`paths` aliasing — 🟢.

### Resolution-mode imports

🟡 `import('m', { with: { type: 'json' } })` parsed; `resolutionMode`
attribute — 🟡 (the `resolutionModeTripleSlash*` cluster fails).

### Import attributes

🟡 Parses `with { type: "json" }` and legacy `assert { ... }`
(discarded). Module-kind-aware grammar diagnostics — 🟡
(`importAttributes*` cluster).

## JSX

🟢 JSX intrinsic + component elements, fragments (`<>...</>`),
spread attributes, JSX expressions (`{expr}`), namespaced tag names
(`<svg:path>`), namespaced attribute names. `--jsx preserve / react /
react-jsx / react-jsxdev / react-native`. JSX target-type computed
via `JSX.IntrinsicAttributes & PropsType`. Synthetic `JSX.Element`
when `react.d.ts` is the lib anchor. Fragment recovery (named close
tag) emits TS17015 + TS17014 + TS2304 at the bogus name. TS2604
embeds the tag's source text (`'this'`). `IntrinsicAttributes` excess-
prop synthesis for component props — 🟡
(`checkJsxChildrenProperty15`, `tsxAttributeResolution12`). Generic
component inference — 🟡 (`checkJsxGenericTagHasCorrectInferences`,
`tsxStatelessFunctionComponentsWithTypeArguments2`).

## Emit

### `home tsc` (CLI)

🟢 Driver wires lex → parse → bind → check → emit end-to-end with
multi-file program graph, parallel compile, source maps,
tsc-compatible diagnostics, zig-dtsx fast path for `.d.ts`
emission. CLI flag surface in [`packages/ts_cli`](https://github.com/home-lang/home/blob/main/packages/ts_cli/).

### JavaScript emit

🟢 Streams JS over post-bind HIR — no intermediate JS-AST. Full
Phase 1 surface: literals, identifiers, all binary/unary/logical/
conditional/assignment forms, calls (regular + optional chain),
member access, element access, array/object literals (with holes,
shorthand, method, computed), function decls (async, generator,
default + rest params), classes (extends + methods + properties),
enums (lowered to IIFE), namespaces (lowered to IIFE),
imports/exports (all forms). Type-only nodes erased.

### Generic class heritage type-argument erasure

🟢

### `??` and `?.` lowering at ES2019 and below

🟢

### JSX automatic runtime (`_jsx`/`_jsxs`/`_jsxDEV`)

🟢

### CommonJS module emit with `__importDefault` / `__importStar`

🟢

### Async/await `__awaiter` downlevel for ES2015-ES2016

🟢

### Private fields → WeakMap

🟢

### Legacy decorators with parameter metadata

🟢

### Stage 3 class/member decorator helper shape

🟡 With static-member contexts. Exact initializer arrays / static
blocks / auto-accessors — 🟡.

### Object-method shorthand ES5 lowering

🟢

### Generator state-machine downlevel

🟡 `for (yield E)` works in restricted forms; multi-yield bodies
fall back to native `function*`.

### Source maps

🟢 V3 streaming printer with VLQ mappings, `sourceMappingURL`
trailer.

### `.d.ts` emit

🟢 Symbol-driven walk renders inferred return types via shared
`ts_checker.render`. zig-dtsx fast path for `isolatedDeclarations`
projects.

### `.d.hm` emit

🟡 Basic framing.

## Diagnostics

### tsc-compatible formatting

🟢 Default form (`path/file.ts(line,col): error TSxxxx: message.`)
and `--pretty` (ANSI colored with source-snippet excerpt).

### Diagnostic-code catalogue

🟢 ~2,000 entries mirror the full upstream `diag(code, …)` table
under [`packages/ts_diagnostics/src/ts_diagnostic_codes.zig`](https://github.com/home-lang/home/blob/main/packages/ts_diagnostics/src/ts_diagnostic_codes.zig).
Powers `home-lsp` hover-on-`TS1234`.

### Strict-mode flags

🟢 `strict`, `noImplicitAny` (TS7005 / TS7006), `strictNullChecks`
(TS18047 / TS18048 / TS18049), `strictPropertyInitialization`
(TS2564), `noUnusedLocals` / `noUnusedParameters` (TS6133),
`strictFunctionTypes` (bivariant ↔ contravariant signature
assignability), `useUnknownInCatchVariables` (TS18046),
`alwaysStrict`, `noImplicitThis`.

## LSP

See [README LSP coverage](/docs/PARITY-STATUS#lsp--ide-coverage--home-lsp-vs-tsserver) for the
76 / ~80 wire methods routed (~95%). Canonical
`SUPPORTED_METHODS` list lives in
[`packages/ts_lsp_server/src/ts_lsp_server.zig`](https://github.com/home-lang/home/blob/main/packages/ts_lsp_server/src/ts_lsp_server.zig).

## Watch mode

🟢 `home-tsc --watch` uses `ts_watch.Watcher` + `RealStatFs` —
recompiles incrementally on FS events. Incremental `compileAll`
skips unchanged files; persistent on-disk compilation cache.

## Conformance by 1,000-case slice

Previous green slice counts are withdrawn. All slices require fresh execution
after removing result substitutions and auditing compiler options and library
inputs. Retained historical logs describe the old harness's output only.

Two recovery fixtures now have direct exact unit gates:
`decoratorOnClassMethod12` rejects a dependent TS1241 after the authoritative
TS2660, and `asyncFunctionDeclarationParameterEvaluation` retains TS2538
alongside its unresolved-key TS2304. A leading-prefix count will be published
only after a fresh serial run on current `main`.

### Harness input fidelity

The conformance loader now executes every explicit multi-valued compiler
configuration instead of choosing one lexicographic baseline. It mirrors the
pinned TypeScript runner's Cartesian product, boolean/enum `*` expansion,
exclusions, alias deduplication, 25-configuration ceiling, and configured-name
suffixes. Selected scalar directives determine compiler inputs before any
expected diagnostic file is read, so changing expected text cannot alter case
admission, source routing, options, or actual diagnostic filenames.

Focused evidence is retained in
[the 2026-10-08 variant-execution checkpoint](./bun-port-evidence/2026-10-08-ts-variant-execution/README.md):
the pinned `emitRestParametersFunction` target matrix passes both configured
variants, and the named local category gate expands from 86 collapsed entries
to **87/87** real configured cases. These focused results are not a restored
full-corpus claim. Root-file admission and default-library/compiler-API input
fidelity remain open in [#841](https://github.com/home-lang/home/issues/841).

The program route also now separates upstream root files from other files on
the fixture filesystem. Without a tsconfig, Home mirrors the pinned runner's
all-files rule and its last-file-only rule for `noImplicitReferences`,
`require(`, and triple-slash path references. Direct virtual tsconfigs select
roots from `files` and `include`/`exclude`, including `allowJs` discovery;
unselected files remain available to import and reference resolution. Empty
virtual units remain addressable, missing configured roots stay visible as
failures, and UMD globals are derived from the reachable program instead of
every declaration present on disk. The focused controls and pinned fixture
evidence are recorded in
[the root-admission checkpoint](./bun-port-evidence/2026-10-08-ts-root-admission/README.md).

Virtual config graphs now expand inherited configs before deriving roots,
strict/checking flags, JS admission, and resolver settings. The adapter covers
ordered `extends` arrays, cross-directory paths, package export mappings,
package config defaults, cycle/missing-parent failures, and inherited
`baseUrl`/`paths`. The pinned compiler cases pass **4/4**, the two inherited
module-mode conformance cases pass **2/2**, and the named category regression
remains **87/87**. Exact scope and guarded resource evidence are recorded in
[the virtual-tsconfig checkpoint](./bun-port-evidence/2026-10-08-tsconfig-extends/README.md).

Inherited compiler options now also preserve TypeScript's distinction between
an absent property and a present value converted to `undefined`. A child
`null` therefore clears a parent compiler option, while `files`, `include`,
and `exclude` set to `null` remain absent and inherit. Invalid `extends`
entries retain usable parents and emit TS5024 at the exact scalar or array
element; string-list nulls are filtered while other invalid elements retain
their diagnostics. The behavior and locations match the TypeScript 6.0.3
parser API oracle. Guarded results and the deliberately non-passing broad-run
attempt are recorded in
[the null-override checkpoint](./bun-port-evidence/2026-10-08-tsconfig-null-overrides/README.md).
Default-library/compiler-API fidelity and honest unsupported/skip accounting
remain open under #841; these focused gates are not a complete-corpus claim.

Configured variants that the pinned `typescript-go` compiler runner cannot
execute are now retained as explicit skips instead of being compiled by a
different option surface and potentially credited as passes. The loader
classifies the runner's eight dynamic unsupported-option conditions only after
virtual-tsconfig inheritance and selected matrix overrides: AMD/UMD/System
modules, Node10/Classic resolution, explicit false interop flags, `baseUrl`,
`outFile`, ES5, and explicit `alwaysStrict: false`. A focused matrix proves an
ES5 variant remains visible as one skip while its ES2015 sibling compiles and
passes; the 87-case category gate remains **87/87** with no skips. Guarded
results and the exact boundary of this port are recorded in
[the upstream-skip checkpoint](./bun-port-evidence/2026-10-08-ts-upstream-skips/README.md).
The runner's 45-file pre-enumeration exclusion list is now retained as one
explicit skip per source, before reading or expanding fixture variants. Its
case-sensitive split preserves the ten compiler-API fixtures that require a
built `typescript.d.ts` and the 35 fixtures using removed compiler options.
Both pinned reason-group controls report one skip and no pass/failure, while
the named category gate remains **87/87**. Evidence is recorded in
[the static-skip checkpoint](./bun-port-evidence/2026-10-08-ts-static-skips/README.md).
The program's default-library selector now matches the pinned native runner:
an unspecified target uses `lib.es2025.full.d.ts`, ES2015 uses the intentional
`lib.es6.d.ts` compatibility name, ES2016 through ESNext use their `.full`
entry points, and ES3/ES5 fall back to `lib.d.ts`. The complete target table
and guarded package regression are recorded in
[the default-library selection checkpoint](./bun-port-evidence/2026-10-08-ts-default-lib-selection/README.md).
Mounting those pinned library bytes into every applicable conformance program
and compiler-API input fidelity remain open in
[#841](https://github.com/home-lang/home/issues/841).

The previous exact-baseline category sweep covered 586 fixtures across 19
folders; its passing count also requires revalidation:

`apparentType`, `bestCommonType`, `recursiveTypes`, `typeInference`,
`keyof`, `conditional`, `instanceOf`, `widenedTypes`, `specifyingTypes`,
`primitives`, `any`, `import`, `uniqueSymbol`, `namedTypes`,
`localTypes`, `forAwait`, `unknown`, `witness`, `typeAliases`,
`asyncGenerators`.

## Summary

| Category | Status |
|---|---|
| Coarse-mode corpus | Previous pass count withdrawn; fresh validation pending |
| Exact-mode corpus (byte-for-byte) | Previous pass count withdrawn; fresh validation pending |
| Baseline-aware category sweep | Previous pass count withdrawn; fresh validation pending |
| Named-category survey | Previous pass count withdrawn; fresh validation pending |
| Smoke gate | Previous pass count withdrawn; fresh validation pending |
| Diagnostic-code catalogue | 🟢 ~2,000 entries |
| JS emit | 🟢 substantial |
| `.d.ts` emit | 🟢 |
| Source maps V3 | 🟢 |
| LSP wire surface | 🟡 76 / ~80 (~95%) |

Open work tracked in [`docs/TS_PARITY_PLAN.md`](./TS_PARITY_PLAN.md)
(parity plan + dated journal entries).
