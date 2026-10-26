# Imported checked-JavaScript index signatures

From the repository root, run the same project with TypeScript 5.7.3 and a
freshly built Home compiler:

```sh
tsc -p packages/ts_cli/testdata/issue846-index/tsconfig.json --pretty false
zig-out/bin/home-tsc -p packages/ts_cli/testdata/issue846-index/tsconfig.json --pretty false
```

Both report TS2322 at `owner.js:4:1` and `main.ts:5:1`, `6:1`, `12:1`, and
`15:1`, plus TS2542 at `main.ts:8:1` and `9:1`, with the same messages. The
fixture exercises valid indexed reads, invalid writes through string, number,
and symbol indexes, and readonly-index writes after importing a checked JS
owner. It also verifies that a mutable index with the same key and value types
remains writable. Both processes now exit 2. Diagnostic print order still
differs: TypeScript prints the TS consumer first; Home prints the JS owner
first.
