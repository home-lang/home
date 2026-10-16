# Numeric index signatures in generic write constraints

This closes the remaining `keyofAndIndexedAccess2.ts` mismatch in [#832](https://github.com/home-lang/home/issues/832), within the broader [#66](https://github.com/home-lang/home/issues/66) work. Home reported an extra TS2345 for `cb(param.elements[0])` when `T` extends a union of `string[]` and `number[]`-valued `elements` properties and the callback accepts `T["elements"][number]`. The reference TypeScript baseline has no diagnostic there.

TypeScript 5.7.3 gives the argument type `string | number` and the parameter type `T["elements"][number]`. Its indexed-target assignment relation resolves the target's base constraint **for writing**. The `NoIndexSignatures` guard rejects string and symbol index signatures after a generic receiver is replaced by its constraint, but it explicitly permits a number index signature. Home's corresponding resolver rejected all index signatures, so it could not relate the argument to the callback parameter. The checker now permits numeric index signatures in that guarded lookup while retaining the rejection of string-indexed generic writes.

The added checker regression includes the accepted numeric case and two rejected cases: a value passed to `{ a: 123; b: "some string" }[K]` for an unresolved key `K`, and a number passed to `T[string]` for a generic string-indexed dictionary. Installed TypeScript 5.7.3 produces TS2345 for both negative controls, and Home's direct test requires exactly those two TS2345 diagnostics. The upstream fixture and baseline are unchanged.

All substantial runs were serial through `run_bounded` with `HOME_RUN_MAX_MB=3840`:

| Gate | Before | After |
| --- | --- | --- |
| Exact `keyofAndIndexedAccess2` fixture | 1 extra TS2345 | 1/1 matches |
| Focused checker regression | not present | 2/2 test targets pass |
| Thirteen-case neighboring exact window | 12 pass, 1 fail | 13 pass, 0 fail |
| Unfiltered checker suite | not rerun before this change | 4,651/4,651 pass; 2,299 MB peak tree footprint |
| Unfiltered Program suite | not rerun before this change | 321/321 pass; 2,397 MB peak tree footprint |

The full 1,000-case slice, the entire TypeScript conformance corpus, and the Bun test suite have not been shown to pass by this focused change. The changed files pass targeted Pickier and Zig formatting; a prior repository-wide Pickier run still reports unrelated errors and was not repeated here. Source and reference SHA-256 hashes are in [manifest.json](manifest.json).
