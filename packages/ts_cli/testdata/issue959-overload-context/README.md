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

The current Home CLI also exits 2 and has the same three top-level codes,
including the nested `number`-to-`string` reason. It differs in three exact
details: TS2769 starts at column 6 rather than 1, the two overload signatures
print `[number | undefined]` / `[string | undefined]` without the optional
tuple markers, and the first child prints `string` rather than the literal
`"text"`. This fixture records the unfixed differential; it is not a passing
parity claim or a suppressed diagnostic.
