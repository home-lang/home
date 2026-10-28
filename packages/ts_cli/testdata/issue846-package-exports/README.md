# Package exports revisions for admitted JavaScript (#846)

Both `number.cjs` and `string.cjs` exist throughout the test. Only the
`exports` target in `node_modules/pkg/package.json` changes. With
`"exports":"./number.cjs"`, TypeScript 5.7.3 `tsc -p tsconfig.json --pretty
false` exits 0 with empty stdout and stderr. With
`"exports":"./string.cjs"`, it exits 2 with empty stderr and exactly:

```text
main.ts(2,7): error TS2322: Type 'string' is not assignable to type 'number'.
```

The committed fixture starts at the number target. The LSP revision test
changes the same metadata field to the string target and back, checking
importer diagnostics, source membership, and stable FileIds. It must not
retain the previous JS owner or treat `package.json` as a source file.
