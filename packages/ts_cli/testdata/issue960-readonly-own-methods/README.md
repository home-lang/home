# Array stringification methods (#960)

TypeScript 5.7.3 declares `toString` and `toLocaleString` directly on both `Array<T>` and `ReadonlyArray<T>`. The control checks that they are in each `keyof` set, that both calls return `string`, and that readonly arrays still reject `push`.

`tsconfig-structural.json` checks the complete structural `ReadonlyArray<T>`
relation. An interface extending `ReadonlyArray<number>` inherits its methods
and is assignable to that type; an object with only a readonly length and
numeric index is not. The same distinction determines whether `.flat()`
unwraps an element. TypeScript 5.7.3 reports only the missing-method assignment
and the intentionally wrong flattened element assignment.
