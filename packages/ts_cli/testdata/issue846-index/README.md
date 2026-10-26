# Imported checked-JavaScript index signatures

From the repository root, run the same project with TypeScript 5.7.3 and a
freshly built Home compiler:

```sh
tsc -p packages/ts_cli/testdata/issue846-index/tsconfig.json --pretty false
zig-out/bin/home-tsc -p packages/ts_cli/testdata/issue846-index/tsconfig.json --pretty false
```

Both report TS2322 at `owner.js:4:1` and `main.ts:5:1`, `6:1`, `8:1`, and
`11:1`, with the same messages. The fixture exercises valid indexed reads and
invalid writes through string, number, and symbol indexes after importing a
checked JS owner. Diagnostic print order differs (TypeScript prints the TS
consumer first; Home prints the JS owner first), as do process exit codes
(TypeScript 2, Home 1). This fixture does not assert readonly-index parity.
