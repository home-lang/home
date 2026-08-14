# TypeScript Port-Divergence Notes

> Companion to [`TS_DIAGNOSTIC_CODE_STATUS.md`](./TS_DIAGNOSTIC_CODE_STATUS.md) and
> [`TS_PARITY_PLAN.md`](./TS_PARITY_PLAN.md). Records diagnostic codes where Home's
> faithful-parity reference (the Microsoft Go port, `_submodules/typescript-go`) and
> the original TypeScript compiler (`_submodules/typescript-go/_submodules/TypeScript/src`)
> disagree, and how Home resolves the disagreement.

## Policy

Home targets parity with **TypeScript's observable diagnostic behavior**. The Go port
is the primary porting reference because its data structures map cleanly onto Home's,
but the port is incomplete: some subsystems (notably the isolatedDeclarations / JS
declaration-emit transformer) are not yet ported, so a handful of codes the **original
TypeScript** compiler genuinely emits have **no emission site in the Go port** today.

Decision tree when a `catalog-only` code has no emission site in
`internal/{checker,parser,binder,transformers}` of the Go port:

1. **Original TS also never emits it** (the message exists only in
   `diagnosticMessages.json` / the generated table, with no `Diagnostics.<Name>` use in
   `_submodules/TypeScript/src/compiler`). → **Skip.** There is no reference behavior to
   match; implementing it would invent semantics. (Example historically flagged: TS2553.)

2. **Original TS emits it, the Go port just hasn't ported that subsystem yet.** → **Keep
   in scope.** Implement faithfully against the **original TypeScript** source and record
   the divergence here. Do not skip it merely because the Go port dropped it — it is real,
   shipping TypeScript behavior that "makes sense having."

Verification for case (2) uses the original TS source + that compiler's own test
baselines (`_submodules/TypeScript/tests/baselines/reference/…`) since the Go port has
no baseline for an unported feature.

## Codes kept against original TypeScript (Go port has not ported them)

| Code | Message (abridged) | Original-TS emission site | Subsystem the Go port lacks | Home status |
| --- | --- | --- | --- | --- |
| TS9005 | Declaration emit … requires using private name '{0}'. An explicit type annotation may unblock declaration emit. | `compiler/transformers/declarations.ts` `transformDeclarationsForJS` (≈L451) | JS (`allowJs`+`declaration`) decl-emit privacy fallback | planned — privacy-family JS variant |
| TS9006 | Declaration emit … requires using private name '{0}' from module '{1}'. … | same site (the `errorModuleName` branch) | same | planned |
| TS9026 | Declaration emit … requires preserving this import for augmentations. Not supported with --isolatedDeclarations. | `compiler/transformers/declarations.ts` (augmentation-preservation path) | isolatedDeclarations augmentation handling | deferred — needs the .d.ts transformer |

Notes:

- **TS9005/TS9006** are the **JavaScript-file** analogues of the TS40xx declaration-emit
  privacy family (TS4023/4024/4025/4030/4031/…). Upstream installs a
  `getSymbolAccessibilityDiagnostic` override in `transformDeclarationsForJS` so that,
  when emitting `.d.ts` for a `.js`/`checkJs` file, a symbol whose type would leak a
  private name reports the generic "An explicit type annotation may unblock declaration
  emit" message (TS9005, or TS9006 when the name comes from another module) instead of the
  position-specific TS40xx error. They reuse the **same** module-local-private and
  cross-module export detection Home already has for the TS40xx family — only the message
  selection and the JS-file gate differ. Tracked under the privacy-walk work in the parity
  plan.
- **TS9026** needs Home to actually attempt isolatedDeclarations `.d.ts` emission and
  detect an import that must be preserved for an augmentation; that depends on the
  declaration-emit transformer, which Home has not built. Left deferred (not skipped).
