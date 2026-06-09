# Hand-off: red `ts_checker` tests + full-corpus recursion crash

Captured 2026-06-09 against `main` (HEAD `31928a91`, "Object.prototype members
resolve on all object types"). These are regressions/known-gaps left by the
recent ts-parity sprint. The diagnostic-code coverage is in great shape
(emitted 1522, reachable parity targets 89, exact-mode ~75% on sampled
windows) — this note is the cleanup list.

---

## 1. Full-corpus survey crash — `checkExpression` stack overflow

**Symptom.** `HOME_TS_CONFORMANCE_FULL=1 HOME_TS_CONFORMANCE_EXACT=1 zig build
test -Dfilter=ts_conformance` aborts with `signal ABRT` (no panic message)
partway through the ~5,900-case corpus. Bounded windows complete cleanly
(0–1000, 2500–3500, 4500–5500 all pass), so the offending fixture sits in one
of the un-sampled ranges (1000–2500 / 3500–4500 / 5500–end).

**Cause.** Unbounded recursion in `checkExpression` → stack overflow. The crash
stack is a long self-recursive `checkExpression` chain through these arms:

```
check.zig:60186  const raw_callee_t = try self.checkExpression(c.callee);   // call expr
check.zig:62398  const inner_t = try self.checkExpression(a.expr);          // as/<T> assertion
check.zig:62253  } else try self.checkExpression(op.value);                 // object-literal property value
check.zig:62379  try self.checkFnDeclWithFlowBoundary(node);               // fn expr in expr position
  -> walkFnBody -> checkStatement -> checkVarDecl -> checkExpression -> ...
```

i.e. a pathological deeply-nested expression (nested object literals / calls /
assertions / function expressions) blows the native stack. `checkExpression`
has **no recursion-depth guard**, unlike other walkers in this file.

**Suggested fix.** Add a depth guard to `checkExpression` (degrade to `any` past
a threshold), matching the existing idiom already used elsewhere:

```
check.zig:8684   if (depth > 16 or ...) return false;
check.zig:18366  if (... or depth > 8) return false;
```

A `self.expr_check_depth` counter incremented at the top of `checkExpression`
and decremented on exit, returning `types.Primitive.any` past ~N (tsc uses
a large but finite limit and emits nothing / `any`), would convert the crash
into a graceful degradation and let the full survey run end-to-end.

**To pinpoint the fixture:** re-run with `HOME_TS_CONFORMANCE_TRACE=1` — it
prints `[ts_conformance full-corpus] RUN i/N <name>` before each case; the last
printed name is the crasher.

> Note: a separate, unrelated harness consideration — the full survey backs
> per-fixture work with `std.testing.allocator` (leak-detecting, retains freed
> metadata). Once the crash above is fixed, watch for cumulative memory growth
> across the full run; routing the per-fixture work through
> `std.heap.smp_allocator` (results list stays on `T.allocator`) is the cheap
> mitigation if it bites.

---

## 2. Red `ts_checker` unit tests (20)

`zig build test -Dfilter=ts_checker` → **2581 pass / 20 fail**. Grouped by
likely root cause:

### a) Harness directive-application (4) — *test-side, low risk*
The fixture uses a `// @experimentalDecorators` / `// @jsx` / `// @target`
directive in `newSetup`, but the unit harness doesn't apply compiler-option
directives the way the CLI flag does (verified: `@dec prop` emits TS1240 via
`home-tsc --experimentalDecorators`, but the directive-comment form does not).
Either teach `newSetup` to parse these directives, or set the equivalent flag
on the test checker.
- `non-callable property decorator emits TS1240`
- `JSX factory reports tag arity beyond factory callback`
- `TS2818 for Reflect collision with super in static initializer`
- `TS2816 forbids this in legacy decorated class static field initializer`

### b) Literal flag/payload divergence (3) — *core, same class as the fixed `literalOf` crash*
`singleStringLiteralIndexKey` returns null because the index-key literal (e.g.
`T["x"]`) resolves to a type carrying `is_literal`/`is_string` flags whose
payload index is out of range — so TS4105 never fires. Same root cause as the
`literalOf` OOB crash already fixed (`712c572e`): the indexed-access literal-key
construction produces a mis-flagged literal type. Fix at the construction site.
- `TS4105 rejects private indexed access on type parameter`
- `TS4105 rejects protected indexed access on type parameter`
- `TS4105 leaves missing and union keys on TS2536 path`

### c) Predicate-signature elaboration chain (3)
Assertions on the nested `d.chain` of a TS2322; the chain entry / nesting under
the assignment doesn't match.
- `TS1224 boolean signature is not assignable to predicate signature`
- `TS1226 incompatible predicate target is nested under assignment`
- `TS1227 predicate parameter position mismatch is nested under TS1226`

### d) Enum nominal modelling (3)
- `enum assignment compat models enum value object and member literals`
- `enum member literal assignable to its enum-typed slot`
- `repeated var declaration records inferred enum nominal type`

### e) Other isolated (7)
- `namespace import call carries TS7038 related info`
- `namespace import construction carries TS7038 related info`
- `unresolved await call suggests async function`
- `virtual js subpath with existing @types package emits TS7040 hint`
- `instantiation expression with no applicable type arg signature reports TS2635`
- `bare generic type alias in type parameter constraint emits TS2314`
- `computed method overload dynamic key emits TS1168`

## 3. Red `ts_conformance` unit tests (4)
`zig build test -Dfilter=ts_conformance` → **1356 pass / 4 fail** (0 crashes
after the `literalOf` fix landed). Non-crashing assertion mismatches:
- `arrayLiteralInference passes clean`
- `EnumAndModuleWithSameNameAndCommonRoot passes clean`
- `ModuleAndEnumWithSameNameAndCommonRoot passes clean`
- `redeclaredProperty diagnoses TS2729 on this.b access`
