# Contextual overload diagnostic oracle (#959, related #846)

Run `tsc -p tsconfig.json --pretty false` from this directory with
TypeScript 5.7.3. `strict` and `noEmit` are enabled. The TypeScript command
exits 2, writes nothing to stderr, and emits:

```text
main.ts(9,1): error TS2769: No overload matches this call.
  Overload 1 of 2, '(point: [(number | undefined)?], tag: "numeric"): boolean', gave the following error.
    Argument of type '"text"' is not assignable to parameter of type '"numeric"'.
  Overload 2 of 2, '(point: [(string | undefined)?], tag: "text"): boolean', gave the following error.
    Type 'number | undefined' is not assignable to type 'string | undefined'.
      Type 'number' is not assignable to type 'string'.
main.ts(9,17): error TS18048: 'y' is possibly 'undefined'.
main.ts(9,19): error TS2339: Property 'length' does not exist on type 'number'.
```

Before the #959 fix, Home also exited 2 and emitted the same top-level codes
and nested `number`-to-`string` reason, but differed in three exact details:
TS2769 started at column 6 rather than 1, the signatures omitted the optional
tuple markers, and the first child widened `"text"` to `string`. The source
fix now matches TypeScript's entire stdout, empty stderr, and exit 2; the
exact stream is pinned by `test-tsc-streams`.

`tsconfig-different-arguments.json` provides the complementary anchor control.
Each overload fails at a different *direct* argument, so TypeScript anchors
the combined TS2769 at the `choose` call, not at either argument. TypeScript
5.7.3 exits 2 with empty stderr and this stdout:

```text
different-arguments.ts(4,1): error TS2769: No overload matches this call.
  Overload 1 of 2, '(value: number, mode: "number"): void', gave the following error.
    Argument of type 'string' is not assignable to parameter of type 'number'.
  Overload 2 of 2, '(value: string, mode: "string"): void', gave the following error.
    Argument of type '"number"' is not assignable to parameter of type '"string"'.
```

Together with the existing imported-JavaScript overload fixtures (whose
candidate errors share one argument span), this distinguishes the actual
TypeScript rule: retain a common candidate error span; otherwise use the
call-expression span.

The guarded `test-tsc-streams` step passed with both controls and the existing
imported-JavaScript overload cases. The newly built checker executable passed
4,713 / 4,713 tests when run directly under the memory guard. The separate
#846 99-config auditor was not rerun for this change at that memory level.
