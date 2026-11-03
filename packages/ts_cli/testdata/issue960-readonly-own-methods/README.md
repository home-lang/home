# Array stringification methods (#960)

TypeScript 5.7.3 declares `toString` and `toLocaleString` directly on both `Array<T>` and `ReadonlyArray<T>`. The control checks that they are in each `keyof` set, that both calls return `string`, and that readonly arrays still reject `push`.
