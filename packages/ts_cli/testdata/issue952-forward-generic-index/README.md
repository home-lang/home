# Forward generic index instantiation (#952)

From this directory, run:

```sh
tsc -p tsconfig.json --pretty false
../../../../zig-out/bin/home-tsc -p tsconfig.json --pretty false
```

TypeScript 5.7.3 reports only TS2542 at `repro.ts:6:1`, naming
`Beta<number>`. Home currently reports TS2542 naming `Beta<T>` and an
additional TS2322 at `repro.ts:7:1` because the mutable number index
still has unresolved type `T`. The numeric-string write at line 8 is
also valid. This is a red reproducer; do not count it as passing until
the diagnostics, text, and exit status match the TypeScript oracle.
