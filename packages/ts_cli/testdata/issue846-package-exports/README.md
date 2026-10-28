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

At `maxNodeModuleJsDepth: 0`, the same `.cjs` target is unadmitted and
TypeScript 5.7.3 instead exits 2 with the stdout below (empty stderr); the
path placeholder represents the absolute path to this fixture:

```text
main.ts(1,21): error TS7016: Could not find a declaration file for module 'pkg'. '<absolute fixture path>/node_modules/pkg/number.cjs' implicitly has an 'any' type.
  Try `npm i --save-dev @types/pkg` if it exists or add a new declaration (.d.ts) file containing `declare module 'pkg';`
```

Changing only the `exports` target to `./types.d.ts` at depth zero replaces
that diagnostic with the TS2322 line above. The LSP revision test applies
both metadata states and reverses them, checking that the declaration source
is admitted only while selected and the JS implementation stays excluded.
