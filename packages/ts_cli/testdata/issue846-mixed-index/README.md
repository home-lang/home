# Mixed readonly index signatures (#951)

Run both compilers from this directory:

```sh
tsc -p tsconfig.json --pretty false
../../../../zig-out/bin/home-tsc -p tsconfig.json --pretty false
```

The second command uses a freshly built Home binary at the repository root.
Both programs use the same checked-JavaScript owner and
TypeScript consumer. TypeScript 5.7.3 reports TS2542 only at `main.ts:3:1`,
`7:1`, and `8:1`; string and number index permissions are independent, and
numeric-string key `"0"` selects the number index. At the initial checkpoint,
Home also reports TS2542 at lines `4:1`, `5:1`, and `6:1`, which are valid
writes. This fixture is a red reproducer until #951 is fixed; it is not counted
as a passing parity test.
