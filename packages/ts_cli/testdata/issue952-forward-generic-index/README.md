# Forward generic index instantiation (#952)

From this directory, run:

```sh
tsc -p tsconfig.json --pretty false
../../../../zig-out/bin/home-tsc -p tsconfig.json --pretty false
```

TypeScript 5.7.3 reports only TS2542 at `repro.ts:6:1`, naming
`Beta<number>`. The number-index write at line 7 and numeric-string
write at line 8 are valid. Home originally saw `Beta<T>` and emitted an
additional TS2322 at line 7; the exact one-diagnostic CLI result is now
asserted in `test-tsc-streams`.

`simple.ts` is a non-recursive generic control, and `recursive.ts` checks
the same forward-return mechanism through a concrete `value` property.
Both should compile cleanly under `--strict --noEmit`. `invalid.ts` is the
negative control: after concretizing `T` to `string`, assigning a number
must still report TS2322 at line 5.
