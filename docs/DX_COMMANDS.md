# Home DX Commands

Home should feel like one coherent toolchain. These commands are the stable
front doors for everyday development.

## Daily Loop

```bash
home dev
home fix src/
home test
home check src/
home symbols src/
home docs src --out docs/API.md
home explain T0001
home size zig-out
```

- `home dev` runs the `dev` script from `home.toml` when present, otherwise it

  watches `src/main.home` or `src/main.hm`.

- `home fix [path]` recursively finds `.home` and `.hm` files, then runs the

  formatter and safe auto-fixes.

- `home lsp` prints the language-server capabilities.
- `home lsp --stdio` is the stable editor entrypoint and speaks JSON-RPC over

  stdio for initialization, completion, hover, symbols, formatting, and related
  requests.

- `home symbols [path]` lists public declarations found in `.home` and `.hm`

  files.

- `home docs [path] --out docs/API.md` generates Markdown API docs from Home

  declaration metadata.

- `home explain <code>` explains diagnostic codes and usual fixes.
- `home api-diff <old.d.hm> <new.d.hm>` compares generated declaration files

  for public API additions/removals.

- `home size [path]` reports package/build output sizes while skipping common

  dependency caches.

## Package And Toolchain

Home package commands intentionally reuse Pantry for package and toolchain work
instead of growing a separate ecosystem manager.

```bash
home pkg tools
home pkg search http
home pkg info zig
home pkg audit
home pkg dedupe
home pkg tree
home pkg why <package>
home pkg outdated
home pkg declarations
home pkg declarations --check
home pkg docs
home pkg api-diff old.d.hm new.d.hm
```

Commands that need Pantry delegate to the `pantry` binary. Local fallback output
exists for `tree`, `why`, and `outdated` so projects still get useful feedback.
