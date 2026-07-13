# TypeScript parity

Detailed per-feature status for Home's TypeScript frontend
(`packages/ts_*`). This is the drill-down view; the at-a-glance
section is in the
[README parity status](../README.md#typescript-parity--home-tsc-vs-tsc--tsgo).

> **Headline:** 5,907 / 5,907 (100%) coarse, 4,871 / 5,907 (~82.5%)
> exact byte-for-byte against upstream conformance baselines.
> Reproduce: `HOME_TS_CONFORMANCE_FULL=1 HOME_TS_CONFORMANCE_EXACT=1
> ./pantry/.bin/zig build test -Dfilter=ts_conformance`.

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
the constructor`), `TS2532` / `TS2533` (possibly undefined / null
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

🟡 `classic`, `node10`, `node16`, `nodenext`, `bundler` strategies
all parse. Classic / nodenext / node16 path semantics — 🟢.
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
emission. CLI flag surface in [`packages/ts_cli`](../packages/ts_cli/).

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
under [`packages/ts_diagnostics/src/ts_diagnostic_codes.zig`](../packages/ts_diagnostics/src/ts_diagnostic_codes.zig).
Powers `home-lsp` hover-on-`TS1234`.

### Strict-mode flags

🟢 `strict`, `noImplicitAny` (TS7005 / TS7006), `strictNullChecks`
(TS18047 / TS18048 / TS18049), `strictPropertyInitialization`
(TS2564), `noUnusedLocals` / `noUnusedParameters` (TS6133),
`strictFunctionTypes` (bivariant ↔ contravariant signature
assignability), `useUnknownInCatchVariables` (TS18046),
`alwaysStrict`, `noImplicitThis`.

## LSP

See [README LSP coverage](../README.md#lsp--ide-coverage--home-lsp-vs-tsserver) for the
53 / ~70 wire methods routed (~76%). Canonical
`SUPPORTED_METHODS` list lives in
[`packages/ts_lsp_server/src/ts_lsp_server.zig`](../packages/ts_lsp_server/src/ts_lsp_server.zig).

## Watch mode

🟢 `home-tsc --watch` uses `ts_watch.Watcher` + `RealStatFs` —
recompiles incrementally on FS events. Incremental `compileAll`
skips unchanged files; persistent on-disk compilation cache.

## Conformance by 1,000-case slice

| Slice | Pass rate | % |
|---|---|---|
| `START=0   LIMIT=1000` | 604 / 1,000 | 60.4% |
| `START=1000 LIMIT=1000` | 611 / 1,000 | 61.1% |
| `START=2000 LIMIT=1000` | 907 / 1,000 | **90.7%** |
| `START=3000 LIMIT=1000` | 646 / 1,000 | 64.6% |
| `START=4000 LIMIT=1000` | 864 / 1,000 | **86.4%** |
| `START=5000 LIMIT=907`  | 545 / 907   | 60.1% |

100%-passing exact-baseline category sweeps (586 fixtures across 19
folders):

`apparentType`, `bestCommonType`, `recursiveTypes`, `typeInference`,
`keyof`, `conditional`, `instanceOf`, `widenedTypes`, `specifyingTypes`,
`primitives`, `any`, `import`, `uniqueSymbol`, `namedTypes`,
`localTypes`, `forAwait`, `unknown`, `witness`, `typeAliases`,
`asyncGenerators`.

## Summary

| Category | Status |
|---|---|
| Coarse-mode corpus | 🟢 5,907 / 5,907 (100%) |
| Exact-mode corpus (byte-for-byte) | 🟡 4,871 / 5,907 (~82.5%; 1,036 remain) |
| Baseline-aware category sweep | 🟢 586 / 586 (100%) |
| Named-category survey | 🟢 86 / 86 (100%) |
| Smoke gate | 🟢 16 / 16 (100%) |
| Diagnostic-code catalogue | 🟢 ~2,000 entries |
| JS emit | 🟢 substantial |
| `.d.ts` emit | 🟢 |
| Source maps V3 | 🟢 |
| LSP wire surface | 🟡 53 / ~70 (~76%) |

Open work tracked in [`docs/TS_PARITY_PLAN.md`](./TS_PARITY_PLAN.md)
(parity plan + dated journal entries).
