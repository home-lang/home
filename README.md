<p align="center"><img src="https://github.com/home-lang/home/blob/main/.github/art/banner.jpg?raw=true" alt="Social Card of this repo"></p>

<p align="center">
  A modern programming language for systems, apps, and games —<br>
  the speed of Zig, the safety of Rust, the joy of TypeScript.
</p>

<p align="center">
  <a href="https://home-lang.org">Website</a> ·
  <a href="https://home-lang.org/docs">Documentation</a> ·
  <a href="https://home-lang.org/docs/guide/getting-started">Getting started</a> ·
  <a href="https://home-lang.org/docs/PARITY-STATUS">Parity status</a> ·
  <a href="./CHANGELOG.md">Changelog</a>
</p>

---

Home compiles to native binaries with no garbage collector and no runtime to
ship alongside them. The same toolchain also type-checks and builds the
TypeScript you already have: `home-tsc` reads your `tsconfig.json` and emits
`tsc`-compatible diagnostics, and `home run` executes TypeScript and JavaScript
on Home's own JavaScriptCore realm.

> **Status:** under active development. The lexer, parser, type inference,
> TypeScript front end, and tree-walking interpreter are usable today; native
> codegen, tooling, and the Bun-compatible runtime are still maturing.
> [Project status](#project-status) has the short version and
> [Parity status](https://home-lang.org/docs/PARITY-STATUS) has every number
> with the harness that produces it.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/home-lang/home/main/install.sh | bash
```

The installer detects your platform, downloads a release tarball from GitHub
Releases, verifies its checksum, and installs the `home` binary to `~/.home/bin`.
macOS (Intel + Apple Silicon), Linux (x64 + arm64), and Windows (x64 + arm64,
via Git Bash / WSL) are supported.

Environment variables: `HOME_VERSION` pins a release tag (default `latest`),
`HOME_INSTALL_DIR` overrides the install location (default `~/.home`), and
`HOME_BIN_DIR` overrides where the binary is placed.

## Quick start

```home
// hello.home
fn main() {
  print("Hello, Home!")
}
```

```bash
home build hello.home    # native executable, nothing to install beside it
./hello                  # Hello, Home!

home run hello.home      # or run it directly
home check hello.home    # type-check without building
```

Source files use the `.home` extension, or `.hm` for short. The
[getting started guide](https://home-lang.org/docs/guide/getting-started) walks
through a first project.

## Why Home

- **Native binaries, no collector.** Ownership and borrowing settle lifetimes at
  compile time — no pauses, no runtime shipped beside the binary.
  ([memory model](https://home-lang.org/docs/advanced/memory))
- **One toolchain for two languages.** The same compiler builds `.home` files and
  type-checks TypeScript, so a mixed codebase needs one tool instead of two.
  ([how it works](https://home-lang.org/docs/features/typescript))
- **Exhaustive pattern matching.** A missing branch is a compile error, not a
  runtime surprise. ([pattern matching](https://home-lang.org/docs/features/pattern-matching))
- **Compile time is just code.** `comptime` runs real Home during compilation.
  ([comptime](https://home-lang.org/docs/advanced/comptime))
- **Errors as values.** `Result` types with `?` propagation, plus null-safety
  operators (`?.`, `?:`, `??`, `?[]`).
  ([error handling](https://home-lang.org/docs/advanced/error-handling))
- **Batteries in the stdlib.** HTTP, database, JSON, async, threading and FFI.
  ([standard library](https://home-lang.org/docs/reference/stdlib))

## Language tour

A condensed pass over the syntax. Each section links to the full page in the
[language guide](https://home-lang.org/docs).

### Variables and control flow

```home
let name = "Alice"           // immutable by default
let mut counter = 0          // mutable
let age: int = 25            // explicit type
const PI = 3.14159           // compile-time constant

if (counter > 5) {
  print("big")
} else {
  print("small")
}

for (item in items) { print(item) }
for (i in 0..10) { print(i) }
for (index, item in items) { print("{index}: {item}") }

while (counter < 10) { counter = counter + 1 }
```

Strings interpolate with `{}`, ranges come with `.len()`, `.step()`,
`.contains()` and `.to_array()`, and arithmetic includes `**` (power) and `~/`
(truncating integer division). Full reference:
[variables](https://home-lang.org/docs/guide/variables) and
[control flow](https://home-lang.org/docs/guide/control-flow).

### Functions

```home
fn add(a: int, b: int): int {
  return a + b
}

fn greet(name: string = "World") {   // default parameters
  print("Hello, {name}!")
}

fn fetch_data(): async Result<Data> {
  let response = await http.get("/api/data")
  return response.json()
}
```

More: [functions](https://home-lang.org/docs/guide/functions),
[async](https://home-lang.org/docs/advanced/async).

### Structs, enums and pattern matching

```home
struct User {
  id: i64
  name: string
}

enum Color {
  Red,
  Green,
  Custom(r: int, g: int, b: int)
}

let user = User { id: 1, name: "Alice" }

match color {
  Color.Red => print("red"),
  Color.Green => print("green"),
  Color.Custom(r, g, b) => print("rgb({r}, {g}, {b})")
}
```

`if` and `match` are expressions, so they return values:

```home
let status = if (code == 200) { "ok" } else { "error" }

let label = match x {
  1 => "one",
  2 => "two",
  _ => "other"
}
```

More: [structs and enums](https://home-lang.org/docs/guide/structs-enums),
[pattern matching](https://home-lang.org/docs/features/pattern-matching),
[traits](https://home-lang.org/docs/guide/traits).

### Null safety and errors

```home
let name = user?.name ?: "Anonymous"   // elvis
let city = user?.address?.city         // safe navigation
let first = items?[0]                  // safe indexing

fn read_file(path: string): Result<string, Error> {
  let file = fs.open(path)?            // ? propagates errors
  return Ok(file.read_all())
}

match read_file("config.home") {
  Ok(content) => process(content),
  Err(e) => print("Failed: {e}")
}
```

More: [type system](https://home-lang.org/docs/features/type-system),
[error handling](https://home-lang.org/docs/advanced/error-handling).

### Generics and comptime

```home
struct Stack<T> {
  items: []T

  fn push(self, item: T) { self.items.append(item) }
  fn pop(self): Option<T> { return self.items.pop() }
}

comptime fn factorial(n: int): int {
  if (n <= 1) { return 1 }
  return n * factorial(n - 1)
}

const FACT_10 = factorial(10)   // computed at compile time
```

More: [generics](https://home-lang.org/docs/features/generics),
[comptime](https://home-lang.org/docs/advanced/comptime),
[macros](https://home-lang.org/docs/features/macros),
[FFI](https://home-lang.org/docs/features/ffi).

### A server, end to end

```home
import http { Server, Response }

fn main() {
  let server = Server.bind(":3000")

  server.get("/users/:id", fn(req): Response {
    let id = req.param("id")
    return Response.json({ id: id })
  })

  server.listen()
}
```

More: [standard library](https://home-lang.org/docs/reference/stdlib),
[web services](https://home-lang.org/docs/use-cases/web-services).

## TypeScript and JavaScript

Home ships a drop-in `tsc` / `tsgo`-compatible TypeScript front end, built as
its own set of Zig packages (`ts_lexer`, `ts_parser`, `binder`, `ts_checker`,
`ts_emit`, `ts_program`, `ts_resolver`, `ts_lsp`, …). It runs the upstream
TypeScript conformance corpus and compares **byte-for-byte** against baselines
generated by the reference compiler.

```bash
cd my-typescript-app
home-tsc --noEmit        # same diagnostics, same codes, same exit status
home-tsc --watch         # incremental recompiles on change
home-lsp                 # TypeScript language server for your editor
home run server.ts       # run it on Home's own JavaScriptCore realm
```

`home-tsc` and `home-lsp` build alongside the compiler into `zig-out/bin/`;
`home lsp --stdio` is the separate language server for `.home` sources.
Details: [TypeScript compiler](https://home-lang.org/docs/features/typescript),
[editor and CLI tooling](https://home-lang.org/docs/features/tooling),
[TypeScript migration](https://home-lang.org/docs/use-cases/typescript-migration).

## Project status

Conservative on purpose: anything not exercised by an example or a test stays
"maturing" even when the underlying code is largely there.

| Area | Status | Detail |
|---|---|---|
| Lexer, parser, type inference | Usable today | [Capability matrix](https://home-lang.org/docs/CAPABILITY_MATRIX) |
| TypeScript conformance (coarse + byte-exact) | 5,907 / 5,907 — 100% | [TypeScript parity](https://home-lang.org/docs/PARITY-TYPESCRIPT) |
| TypeScript diagnostic codes emitted | 1,620 / 2,079; **0 reachable targets left** | [Diagnostic reachability](https://home-lang.org/docs/TS_DIAGNOSTIC_REACHABILITY) |
| Language server methods routed | 76 / ~80 | [Parity status](https://home-lang.org/docs/PARITY-STATUS#lsp--ide-coverage--home-lsp-vs-tsserver) |
| Native codegen | Maturing — single-entrypoint LLVM builds work | [Parity status](https://home-lang.org/docs/PARITY-STATUS#codegen-targets) |
| Bun runtime port | 552 / 1,193 files integrated | [Bun parity](https://home-lang.org/docs/PARITY-BUN) |
| `node:*` modules JS-callable | 24 / 47 (partial surfaces) | [Node.js parity](https://home-lang.org/docs/PARITY-NODE) |
| Compiler test suite | ~8,415 tests | [Parity status](https://home-lang.org/docs/PARITY-STATUS) |

Every figure is a file-count, row-count or byte-for-byte measurement against an
external baseline, refreshed with `scripts/measure-parity.sh`. The full
breakdown — headline numbers, per-phase runtime port, LSP method list,
frontend performance snapshots — lives in
[Parity status](https://home-lang.org/docs/PARITY-STATUS).

## Build from source

Requires the Pantry-pinned Zig 0.17 dev toolchain; nothing is installed globally.

```bash
git clone https://github.com/home-lang/home.git
cd home
pantry install              # installs the pinned Zig 0.17 dev toolchain
./pantry/.bin/zig build     # ./pantry/.bin/zig is a stable symlink to it

./zig-out/bin/home build examples/fibonacci.home
./examples/fibonacci
```

Common commands:

| Command | What it does |
|---|---|
| `./pantry/.bin/zig build` | Build the compiler |
| `./pantry/.bin/zig build test` | Run the unit-test suite |
| `./pantry/.bin/zig build examples` | Run the native example executables |
| `./pantry/.bin/zig build run -- examples/fibonacci.home` | Build, then run a file |
| `scripts/check-examples.sh` | `home check` every `.home` example |
| `scripts/measure-parity.sh --diff` | Fail if the published parity numbers drifted |

## Repository layout

```
home/
├── src/main.zig      # CLI entry point
├── packages/         # 130+ Zig packages, each with its own tests
│   ├── lexer/  parser/  ast/  types/  codegen/  interpreter/
│   ├── ts_lexer/  ts_parser/  ts_checker/  ts_emit/  ts_program/
│   ├── ts_lsp/  ts_lsp_server/  ts_conformance/  ts_resolver/
│   ├── hir/  binder/  diagnostics/  compat/  runtime/
│   └── ...           # http, database, async, ffi, graphics, …
├── docs/             # Documentation site (home-lang.org)
├── examples/         # Example programs
├── tests/            # Integration tests
└── stdlib/           # Standard library
```

[Monorepo structure](https://home-lang.org/docs/MONOREPO-STRUCTURE) and
[architecture](https://home-lang.org/docs/ARCHITECTURE) go deeper.

## Contributing

Contributions welcome — see [CONTRIBUTING.md](./.github/CONTRIBUTING.md).
Release notes live in [CHANGELOG.md](./CHANGELOG.md).

## License

MIT — see [LICENSE](./LICENSE).
