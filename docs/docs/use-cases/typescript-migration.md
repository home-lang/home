# TypeScript Migration

Most migrations fail because they ask for a rewrite before they deliver
anything. Home's TypeScript front end lets you invert that: start by checking
the code you already have, and move code only where moving it pays.

## Stage one: check what you have

Nothing changes in your repository. Point `home-tsc` at the project and it
reads the `tsconfig.json` that is already there:

```bash
cd my-typescript-app
home-tsc --noEmit
```

Diagnostics carry the same `TSxxxx` codes as the reference compiler, so CI
matchers, editor integrations and problem matchers keep working:

```
error TS2345: Argument of type 'string' is not assignable to parameter of type 'number'.
```

Unfamiliar codes are catalogued in
[diagnostic code status](/docs/TS_DIAGNOSTIC_CODE_STATUS), alongside the codes
the reference compiler never emits and Home therefore does not either.

This stage is reversible in the literal sense: you can stop after it and have
lost nothing.

## Stage two: run it side by side in CI

Add `home-tsc` next to your existing type-check rather than replacing it. Any
disagreement between the two is information: either a real bug in Home worth
reporting, or a case where your build was relying on something surprising.

```bash
tsc --noEmit && home-tsc --noEmit
```

Coarse and byte-for-byte exact conformance against the pinned upstream corpus
are saturated at 5,907 of 5,907 cases. See
[the TypeScript compiler](/docs/features/typescript) for how both numbers are
produced.

## Stage three: move one hot path

Pick something small, self-contained and CPU-bound: a parser, a codec, an
image resize, a hashing loop. Write it in Home, build it, and call it from the
service you already have.

```bash
home build src/tokenizer.home -o tokenizer
```

This is where the language earns its place or does not. If the hot path is not
actually hot, you will not see anything, and that is a useful result too.

## Stage four: adopt the toolchain

Once Home code is in the repository, the rest of the toolchain is already
installed:

```bash
home fix src/       # format and safe fixes
home test           # run the suite
home lsp --stdio    # the editor endpoint
```

See [editor and CLI tooling](/docs/features/tooling).

## What to expect from each stage

| Stage | Cost | What you get back |
|---|---|---|
| Check with `home-tsc` | One command | A second opinion on your types |
| Run side by side in CI | One CI step | Confidence, and any disagreements surfaced early |
| Move one hot path | One module rewritten | A real measurement, not an estimate |
| Adopt the toolchain | Team habit change | One toolchain instead of two |

## Honest limits

Be clear about what is not ready before planning around it:

- The verified byte-for-byte diagnostic baseline covers the pinned 5,907-case
  tsgo corpus; future upstream revisions can introduce new differences.
- Native JavaScript builds are single-entrypoint today; bundling the imported
  module graph is in progress.
- The Bun-compatible runtime is maturing. 24 `node:*` modules are callable
  through Home's own JavaScriptCore realm, and the default `home run` still
  delegates to Pantry's `bun`.

The [capability matrix](/docs/CAPABILITY_MATRIX) and the parity pages for
[TypeScript](/docs/PARITY-TYPESCRIPT), [Node](/docs/PARITY-NODE) and
[Bun](/docs/PARITY-BUN) are kept current and are the right thing to read before
committing.

## Related

- [TypeScript compiler](/docs/features/typescript)
- [TypeScript parity](/docs/PARITY-TYPESCRIPT)
- [Web services](/docs/use-cases/web-services)
- [Getting started](/docs/guide/getting-started)
