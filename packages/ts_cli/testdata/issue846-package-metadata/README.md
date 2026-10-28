# Admitted JavaScript package metadata (#846)

The two packages have byte-identical `index.js` sources. Only their
`package.json` `type` fields differ. From this directory, TypeScript 5.7.3
reports the following exact streams for `tsc -p CONFIG --pretty false`:

`tsconfig-esm.json`:

```text
main-esm.ts(1,21): error TS1479: The current file is a CommonJS module whose imports will produce 'require' calls; however, the referenced file is an ECMAScript module and cannot be imported with 'require'. Consider writing a dynamic 'import("pkg-esm")' call instead.
  To convert this file to an ECMAScript module, change its file extension to '.mts' or create a local package.json file with `{ "type": "module" }`.
main-esm.ts(4,7): error TS2322: Type 'number' is not assignable to type 'string'.
main-esm.ts(5,1): error TS2322: Type 'string' is not assignable to type 'number'.
```

`tsconfig-cjs.json`:

```text
main-cjs.ts(4,7): error TS2322: Type 'number' is not assignable to type 'string'.
main-cjs.ts(5,1): error TS2322: Type 'string' is not assignable to type 'number'.
```

Both commands exit 2 with empty stderr. The LSP revision test changes the
package metadata in place from ESM to CommonJS and back without changing the
JavaScript source. The importer must lose and regain TS1479 while preserving
its typed read and write errors.
