# Hand-off: red `ts_checker` tests + full-corpus recursion crash

Captured 2026-06-09 against `main` (HEAD `31928a91`, "Object.prototype members
resolve on all object types"). These are regressions/known-gaps left by the
recent ts-parity sprint. The diagnostic-code coverage is in great shape
(emitted 1522, reachable parity targets 89, exact-mode ~75% on sampled
windows) — this note is the cleanup list.

---

## 1. Full-corpus survey crash — `checkExpression` stack overflow — **FIXED**

> **Resolved 2026-06-10** (`c0fa25f6`). The guard existed but its 1000 ceiling
> sat *above* the empirical native-stack overflow point (~290 frames), so it
> never fired. Lowered `max_expression_depth` to 200; past the limit the
> expression degrades to `any`. The full exact-mode survey now completes
> end-to-end for the first time: **total=5907 passed=4497 pass_rate=0.76,
> 0 crashes** (confirming the earlier ~75% sampled estimate). The
> smp_allocator note below did not bite. A separate, much deeper *parser*
> stack overflow (~2000-deep nested parens/braces) still exists but no corpus
> fixture reaches it. Original analysis kept below for reference.

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

---

## 4. Decorator parity: TS1278/TS1279 vs legacy TS1238/1240/1241 (contested)

**Evidence of a parity gap.** Under `// @experimentalDecorators: true`, the
conformance baselines emit the *legacy* "unable to resolve signature of X
decorator" codes, NOT the TC39 standard-decorator runtime-arity codes:

| fixture (`@experimentalDecorators`) | tsc emits | home emits |
| --- | --- | --- |
| decoratorOnClass8 | TS1238 (3,1) | **+TS1278** (3,1) |
| decoratorOnClassMethod8/10 | TS1241 (4,6) | **+TS1278** (4,6) |
| decoratorOnClassProperty6 | TS1240 (4,6) | **+TS1278** (4,6) |
| decoratorOnClassProperty7 | TS1240 (4,5) | **+TS1278** (4,5) |

i.e. home runs the standard-decorator runtime-arity check (TS1278/TS1279) even
under `experimentalDecorators`, where tsc instead reports the signature as
unresolvable (TS1238/1240/1241 by kind, at the identical anchor).

**Why this is left for you.** A one-line gate in `checkDecoratorRuntimeArity`
(emit `signature_unresolved_code` under `sourceUsesLegacyDecorators()`,
keeping the existing `dec_pos`) flips all 5 fixtures cleanly — verified
locally (+5 on the 0–1500 window). BUT it contradicts 5 *deliberate* unit
tests that assert TS1278/TS1279 under `@experimentalDecorators`
("property/class/method decorator exact runtime arity emits TS1278",
"...TS1278 anchors at @...", "rest property decorator runtime arity emits
TS1279"). Those tests would need to change to expect TS1240/1241/1238. Since
that's a deliberate-behavior decision in actively-edited code, it's yours to
make — the fix + the test updates should land together.

---

## 5. Near-passing worklist (134 fixtures within 1–2 diagnostic lines)

From an exact-mode 0–1500 window (DUMP). Each is 1–2 `+`/`-` mismatches from
passing. `+TS` = we over-emit (suppress); `-TS` = we under-emit (add). Bucketed
by frequency so the highest-leverage single root cause comes first:

```
count  code
  27 +TS2322
  27 -TS2322
  12 +TS2339
   9 -TS2454
   8 -TS2345
   7 -TS18013
   5 +TS2345
   5 +TS2307
   5 +TS1278
   5 -TS2318
   4 +TS2304
   4 -TS2807
   4 -TS2558
   4 -TS2430
   4 -TS2339
   3 -TS1117
   2 +TS2741
   2 +TS2693
   2 +TS2367
   2 +TS2364
   2 -TS7006
   2 -TS2806
```

Full fixture list (sorted by mismatch count, then name):

```
1	assignmentCompatWithNumericIndexer3	 -TS2322
1	bundlerConditionsExcludesNode	 +TS7016
1	bundlerImportESM	 +TS1293
1	callSignatureAssignabilityInInheritance	 -TS2430
1	callSignaturesWithParameterInitializers2	 -TS1005
1	classAbstractInstantiations2	 -TS2391
1	classExtendsItselfIndirectly	 -TS2449
1	classExtendsShadowedConstructorFunction	 -TS2507
1	classImplementsMergedClassInterface	 -TS2720
1	classWithoutExplicitConstructor	 -TS2322
1	classWithStaticFieldInParameterBindingPattern.3	 +TS2373
1	conditionalExportsResolutionFallback	 +TS2307
1	constructSignatureAssignabilityInInheritance	 -TS2430
1	declarationFileForHtmlFileWithinDeclarationFile	 +TS2305
1	decoratorOnClassProperty11	 +TS1271
1	derivedClassFunctionOverridesBaseClassAccessor	 -TS2416
1	derivedClassWithoutExplicitConstructor	 -TS2322
1	genericCallWithNonSymmetricSubtypes	 -TS2454
1	genericCallWithObjectTypeArgs	 -TS2345
1	genericCallWithOverloadedConstructorTypedArguments	 -TS2769
1	genericSetterInClassTypeJsDoc	 +TS2304
1	genericTypeReferenceWithoutTypeArgument2	 +TS2339
1	importTypeAmbientMissing	 +TS2693
1	importTypeGenericTypes	 +TS2304
1	infiniteExpansionThroughInstantiation	 -TS2322
1	intersectionAsWeakTypeSource	 -TS2739
1	mappedTypeInferenceErrors	 -TS2322
1	mergedClassInterface	 +TS2339
1	mixinAbstractClasses.2	 +TS2510
1	mixinAccessors3	 -TS2611
1	mixinWithBaseDependingOnSelfNoCrash1	 -TS2345
1	numericIndexerConstrainsPropertyDeclarations	 -TS2322
1	numericIndexerConstrainsPropertyDeclarations2	 -TS2322
1	privateNameInInExpressionUnused	 -TS6133
1	privateNameInObjectLiteral-3	 -TS18028
1	privateNameNestedMethodAccess	 -TS2339
1	privateNameSetterNoGetter	 -TS2806
1	privateNamesUnique-1	 -TS2322
1	privateNamesUnique-5	 -TS2322
1	privateStaticNotAccessibleInClodule2	 -TS2341
1	privateWriteOnlyAccessorRead	 -TS2806
1	protectedStaticNotAccessibleInClodule	 -TS2445
1	stringLiteralsWithTypeAssertions01	 +TS2352
1	subtypingWithCallSignaturesWithSpecializedSignatures	 -TS2430
1	subtypingWithConstructSignaturesWithSpecializedSignatures	 -TS2430
1	typeReferenceRelatedFiles	 +TS2688
1	typesVersions.ambientModules	 +TS2307
1	typesVersionsDeclarationEmit.ambient	 +TS2307
1	typesVersionsDeclarationEmit.multiFileBackReferenceToSelf	 -TS2305
1	unionTypeFromArrayLiteral	 +TS2322
1	untypedModuleImport_allowJs	 -TS2339
2	assignFromBooleanInterface2	 +TS2322 +TS2322
2	assignFromNumberInterface2	 +TS2322 +TS2322
2	assignFromStringInterface2	 -TS2740 +TS2322
2	assignmentCompatWithCallSignatures2	 -TS2322 -TS2322
2	assignmentCompatWithConstructSignatures2	 -TS2322 -TS2322
2	assignmentCompatWithEnumIndexer	 -TS2741 +TS2741
2	assignmentCompatWithGenericCallSignatures4	 -TS2322 +TS2322
2	bestCommonTypeOfTuple	 +TS2322 +TS2322
2	bundlerCommonJS	 +TS2307 +TS2307
2	callGenericFunctionWithIncorrectNumberOfTypeArguments	 -TS2558 -TS2558
2	callSignaturesThatDifferOnlyByReturnType2	 -TS2320 +TS2320
2	classAbstractInheritance2	 -TS2650 +TS2650
2	classBodyWithStatements	 -TS1068 -TS1128
2	classExtendingClassLikeType	 -TS2508 -TS2510
2	classExtendingPrimitive2	 -TS1109 +TS2304
2	classWithEmptyBody	 +TS2322 +TS2322
2	commonTypeIntersection	 -TS2322 +TS2322
2	constructorParameterShadowsOuterScopes	 -TS2301 -TS2301
2	constructorWithAssignableReturnExpression	 -TS2409 -TS2322
2	contextualTypeWithUnionTypeCallSignatures	 -TS7006 -TS7006
2	decoratorOnClass8	 -TS1238 +TS1278
2	decoratorOnClassMethod10	 -TS1241 +TS1278
2	decoratorOnClassMethod8	 -TS1241 +TS1278
2	decoratorOnClassProperty6	 -TS1240 +TS1278
2	decoratorOnClassProperty7	 -TS1240 +TS1278
2	decoratorOnUsing	 -TS1134 +TS1005
2	derivedGenericClassWithAny	 -TS2322 -TS2322
2	discriminatedUnionTypes1	 -TS2367 +TS2367
2	duplicateNumericIndexers	 -TS2374 -TS2374
2	duplicatePropertyNames	 -TS1117 -TS1117
2	enumLiteralTypes3	 -TS2322 -TS2322
2	functionLiterals	 +TS2322 +TS2322
2	genericCallWithFunctionTypedArguments3	 -TS2454 +TS2345
2	genericCallWithFunctionTypedArguments4	 -TS2454 +TS2345
2	genericCallWithObjectTypeArgsAndConstraints	 -TS2454 -TS2454
2	genericCallWithObjectTypeArgsAndConstraints3	 -TS2345 -TS2345
2	genericClassExpressionInFunction	 +TS2749 +TS2339
2	genericClassWithObjectTypeArgsAndConstraints	 -TS2454 -TS2454
2	importTypeAmbient	 +TS2693 +TS2503
2	importTypeLocalMissing	 -TS2694 +TS2694
2	instantiateNonGenericTypeWithTypeArguments	 -TS2558 -TS2558
2	intersectionNarrowing	 -TS2367 +TS2367
2	libReferenceNoLib	 -TS2318 -TS2318
2	libReferenceNoLibBundle	 -TS2318 -TS2318
2	mappedTypeAsClauses	 -TS2345 +TS2345
2	methodSignaturesWithOverloads2	 +TS2322 +TS2322
2	missingDecoratorType	 -TS2318 +TS2318
2	narrowingGenericTypeFromInstanceof01	 -TS2345 +TS2345
2	nonPrimitiveAndTypeVariables	 -TS2322 +TS5082
2	nonPrimitiveConstraintOfIndexAccessType	 -TS2322 +TS2322
2	numericStringNamedPropertyEquivalence	 -TS2717 -TS1117
2	objectSpreadSetonlyAccessor	 +TS2322 +TS2322
2	privateNameEmitHelpers	 -TS2807 -TS2807
2	privateNameFieldParenthesisLeftAssignment	 +TS2364 +TS2364
2	privateNameMethodClassExpression	 -TS18013 -TS18013
2	privateNamesInNestedClasses-2	 -TS18014 +TS18014
2	privateNamesInterfaceExtendingClass	 -TS18013 +TS2339
2	privateNameStaticEmitHelpers	 -TS2807 -TS2807
2	privateNameStaticFieldDerivedClasses	 -TS18013 +TS2339
2	privateNameStaticMethodAsync	 -TS1029 +TS7055
2	privateNameStaticMethodClassExpression	 -TS18013 -TS18013
2	privateNamesUnique-2	 -TS18013 +TS2339
2	privateNamesUnique-4	 -TS2741 +TS2741
2	privateNamesUseBeforeDef	 -TS2729 -TS2729
2	protectedClassPropertyAccessibleWithinSubclass3	 -TS2340 +TS2855
2	recursiveIntersectionTypes	 +TS2339 +TS2339
2	recursiveTypeReferences2	 -TS2322 +TS2322
2	resolutionModeTripleSlash4	 -TS2552 +TS2304
2	spreadUnion3	 -TS2322 -TS2322
2	staticIndexSignature7	 -TS2411 +TS2411
2	stringLiteralTypesAndParenthesizedExpressions01	 +TS2322 +TS2322
2	subtypingWithCallSignaturesA	 -TS2345 +TS2322
2	templateLiteralTypes7	 +TS2322 +TS2322
2	thisTypeInClasses	 -TS2352 -TS2352
2	typeOfThisInStaticMembers	 +TS2339 +TS2339
2	typeOfThisInStaticMembers8	 -TS2339 +TS2339
2	typeParameterDirectlyConstrainedToItself	 -TS2313 -TS2313
2	typeParametersAvailableInNestedScope	 -TS2454 -TS2454
2	unionThisTypeInFunctions	 -TS2684 +TS2684
2	unionTypeInference	 -TS2345 +TS2345
2	unionTypeReadonly	 -TS2339 +TS2339
2	validEnumAssignments	 -TS2322 +TS2322
2	wideningTuples4	 -TS2322 +TS2322
```
