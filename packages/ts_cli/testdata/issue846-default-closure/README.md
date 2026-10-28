# JavaScript default-expression import closure (#846)

`owner.js` exports an object expression as the default value. `direct.ts`
imports it directly; `main.ts` imports it through `bridge.js`, both as a
default binding and as a namespace member. The configs admit JavaScript from
TypeScript roots rather than listing either JavaScript file as an explicit
root. Both `checkJs` modes must still type-check TypeScript consumers.

TypeScript 5.7.3, run with `-p <config> --pretty false --noEmit`, exits 2 with
empty stderr. For `tsconfig.json` and `tsconfig-no-checkjs.json`, stdout is:

```text
main.ts(6,7): error TS2322: Type 'number' is not assignable to type 'string'.
main.ts(7,1): error TS2322: Type 'string' is not assignable to type 'number'.
main.ts(8,7): error TS2322: Type 'string' is not assignable to type 'number'.
main.ts(9,1): error TS2322: Type 'number' is not assignable to type 'string'.
```

For `tsconfig-direct.json`, stdout is:

```text
direct.ts(3,7): error TS2322: Type 'number' is not assignable to type 'string'.
direct.ts(4,1): error TS2322: Type 'string' is not assignable to type 'number'.
```

`test-tsc-streams` pins stdout, empty stderr, and exit status for all three
controls. The focused Program regression also exercises serial and parallel
owner checking. This fixture covers inferred object-literal default exports;
it does not assert that every JavaScript expression shape is supported.
