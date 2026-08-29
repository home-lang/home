# Editor and CLI Tooling

Home treats the toolchain as part of the language. The formatter, test runner,
language server, documentation generator and package commands all ship in the
same binary as the compiler, so there is one thing to install and one version
to keep straight.

## The daily loop

```bash
home dev              # watch and rebuild
home fix src/         # format and apply safe fixes
home test             # run the test suite
home check src/       # type-check without building
```

`home dev` runs the `dev` script from `home.toml` when there is one, and
otherwise watches `src/main.home` or `src/main.hm`.

`home fix` walks the tree for `.home` and `.hm` files, formats them, and
applies the auto-fixes that cannot change behaviour. It is the command to wire
into a pre-commit hook.

## Understanding a codebase

```bash
home symbols src/                     # list public declarations
home docs src --out docs/API.md       # generate Markdown API docs
home api-diff old.d.hm new.d.hm       # compare public API surfaces
home size zig-out                     # report build output sizes
```

`home api-diff` reads Home declaration files, the `.d.hm` format that carries
package API metadata. It reports additions and removals between two versions,
which is what you want in a release checklist rather than a diff of the whole
source tree.

## Diagnostics you can ask about

Every diagnostic has a code, and every code can be explained without leaving
the terminal:

```bash
home explain T0001
```

`home explain` covers Home's own `Txxxx` codes; the TypeScript `TSxxxx`
catalogue is published as
[diagnostic code status](/docs/TS_DIAGNOSTIC_CODE_STATUS) and backs hover in
the editor.

## Language server

```bash
home lsp --stdio
```

`home lsp --stdio` is the stable editor entrypoint. 76 of roughly 80 protocol
methods are routed:

- **Navigation**: definition, declaration, type definition, implementation,
  cross-file references, document and workspace symbols
- **Editing**: completion with resolve, signature help, rename with
  prepare-rename, linked editing ranges, formatting and on-type formatting
- **Display**: hover, semantic tokens including delta and range, inlay hints
  with resolve, code lens, document links, folding and selection ranges,
  document colour
- **Structure**: call hierarchy and type hierarchy, both directions
- **Diagnostics**: publish-based and pull-based, plus workspace diagnostics

Known gaps: quick-fix breadth is partial. Organize imports, add import and add
explicit type annotation have landed; fix-all, missing return type and infer
parameter types have not. Push diagnostics are not yet driven by filesystem
events, `formatDocument` currently returns the source unchanged, and
auto-import completion does not yet search the cross-file interner.

## Packages and toolchain

Home reuses [Pantry](/docs/PANTRY_INTEGRATION) rather than growing a second
ecosystem manager:

```bash
home pkg tools          # what the project pins
home pkg search http    # find a package
home pkg info zig       # inspect one
home pkg audit          # check for advisories
home pkg dedupe         # collapse duplicate versions
```

Because Pantry pins toolchains as well as libraries, the Zig version the
compiler is built against lives in the project rather than on the machine. A
fresh clone plus `pantry install` gets the exact toolchain.

## Editor extensions

The VS Code extension lives in `packages/vscode-home` in the repository and
provides syntax highlighting, diagnostics and the usual language features
through `home lsp`. Any editor with a language-server client can be pointed at
`home lsp --stdio` directly.

## Related

- [DX commands](/docs/DX_COMMANDS), the full command reference
- [TypeScript compiler](/docs/features/typescript), the front end behind the server
- [Package management](/docs/PACKAGE-MANAGEMENT), how Pantry is used
