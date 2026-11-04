# Generic Array and ReadonlyArray union calls (#972)

TypeScript 5.7.3 combines the two generic `map<U>` signatures on `T | readonly string[]` when `T extends number[]`. It contextually types the callback's value as `number | string`, its index as `number`, and its array as `number[] | readonly string[]`. The positive assignments pin those types; the narrower callback assignments and the final `number` result assignment report three intentional TS2322 diagnostics.

This fixture is the matched control for [#972](https://github.com/home-lang/home/issues/972) and the ReadonlyArray surface work in [#960](https://github.com/home-lang/home/issues/960).
