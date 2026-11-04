# Aggregate type parameter and infer regression (#963)

`tsconfig.json` checks the generic conditional return type used by an admitted JavaScript caller.

`tsconfig-infer-union.json` checks a union on the `extends` side of a conditional type. The union inherits its member's type-parameter flag, but its payload identifies the union, not the `infer U` parameter. TypeScript 5.7.3 binds `U` to `number` for `UnwrapNullable<number>` and to `null` for `UnwrapNullable<null>`. Its only diagnostic is TS2322 on the string assignment in `infer-union.ts`.

`tsconfig-infer-intersection.json` covers the matching intersection case. Intersections carry their own flag in Home, but still need structural infer matching. `infer U` captures the source only when that source also satisfies `{ x: number }`. TypeScript reports TS2322 on the wrong `y` property and on assigning to the `never` result.

`tsconfig-iterable-union.json` checks iteration on `T | readonly string[]` and `T | string` where `T extends number[]`. Aggregate unions inherit their constituents' type-parameter and string flags; neither flag may prevent traversal of the union. TypeScript reports only the two intentional TS2322 assignments of `string | number` to `string`. Combining the generic `map` signatures on the array union is tracked separately in [#972](https://github.com/home-lang/home/issues/972).

`tsconfig-heritage-union.json` checks that `U | V` assigns to `T` when both
parameters extend `T`, while `U | number` does not. TypeScript 5.7.3 reports
one TS2322 on the incompatible function's return expression. The union's
inherited type-parameter flag must not make the whole union pass as one
parameter.

Run the exact CLI comparison through `scripts/tests/compare-issue846-oracles.mjs` after building `home-tsc`.
