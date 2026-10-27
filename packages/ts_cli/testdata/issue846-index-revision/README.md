# Admitted JavaScript index revisions (#846)

The two configurations are exact TypeScript 5.7.3 CLI oracles with `allowJs`,
`checkJs`, `strict`, and `noEmit`. They keep the consumer statements identical
while changing the imported JavaScript owner's JSDoc shape:

- `tsconfig-number.json`: a mutable numeric string index and numeric named
  member; the consumer has no diagnostics.
- `tsconfig-string.json`: a readonly string-valued index and string-valued
  named member; the consumer gets three TS2322 diagnostics and one TS2542.

The Program and LSP tests apply those two owner bodies to the **same** logical
`/owner.js` path and check the transition in both directions. That detects
stale exported types and stale editor diagnostics that fresh CLI invocations
cannot expose.
