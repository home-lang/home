# Mixed readonly index signatures (#951)

Run both compilers from this directory:

```sh
tsc -p tsconfig.json --pretty false
../../../../zig-out/bin/home-tsc -p tsconfig.json --pretty false
```

The second command uses a freshly built Home binary at the repository root.
Both programs use the same checked-JavaScript owner, TypeScript consumer,
and local declaration cases. TypeScript 5.7.3 reports TS2542 only at
`main.ts:3:1`, `7:1`, `8:1`, and `13:1`, plus `local.ts:3:1`, `10:1`,
`11:1`, `18:1`, `28:1`, `29:1`, `34:1`, `45:1`, `46:1`, `52:1`, and
`56:1`. String, number, and symbol index
permissions are independent, numeric-string key `"0"` selects the number
index, named writes use the string index, and inherited signatures retain
their own readonly domain.
The exact diagnostic text, order, and exit status are asserted in the
`tsc-streams` suite.
