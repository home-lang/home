<p align="center"><img src="https://github.com/home-lang/home/blob/main/.github/art/banner.jpg?raw=true" alt="Social Card of this repo"></p>

A modern programming language for systems, apps, and games. Combines the speed of Zig, the safety of Rust, and the joy of TypeScript.

> **Status**: Home is under active development. The lexer, parser, type
> inference, and tree-walking interpreter are usable today; native codegen,
> tooling, and most of the stdlib are still maturing. See the [capability
> matrix](#capability-matrix) below — and [`docs/CAPABILITY_MATRIX.md`](./docs/CAPABILITY_MATRIX.md)
> for the full breakdown — for an honest view of what works vs. what is
> in progress.

## Capability Matrix

A condensed view; see [`docs/CAPABILITY_MATRIX.md`](./docs/CAPABILITY_MATRIX.md)
for the full list. Legend: ✅ Stable · 🚧 In progress / partial · ❌ Not yet.

| Area | Feature | Status |
|---|---|---|
| Frontend (Home) | Lexer | ✅ Stable |
| Frontend (Home) | Parser (with error recovery) | ✅ Stable |
| Frontend (Home) | Type inference | ✅ Stable |
| Frontend (Home) | Tree-walking interpreter | ✅ Stable |
| Frontend (TS) | TS lexer (full ES2024 + TS keyword set) | 🚧 In progress |
| Frontend (TS) | TS parser (statements, expressions, decls, JSX, generics, decorators) | 🚧 In progress |
| Frontend (TS) | Type-annotation parser (unions/intersections/generics/conditional/mapped/keyof/typeof/tuple/fn types) | 🚧 In progress |
| TS pipeline | Binder + symbol table (3 meaning-spaces, declaration merging) | 🚧 In progress |
| TS pipeline | Type checker (interner + relation cache + expression typing + assignability) | 🚧 In progress |
| TS pipeline | JS emitter (full Phase 1 surface, source maps V3) | 🚧 In progress |
| TS pipeline | `.d.ts` emitter (symbol-driven + zig-dtsx fast path via pantry) | 🚧 In progress |
| TS pipeline | Multi-file program graph + parallel compile | 🚧 In progress |
| TS pipeline | Module resolver (5 strategies + paths) | 🚧 In progress |
| TS pipeline | tsc-compatible diagnostic formatting | 🚧 In progress |
| TS pipeline | `home tsc` CLI flag surface | 🚧 In progress |
| TS pipeline | `home-lsp` Language Server (~50 LSP methods routed: hover, definition, references, completion, codeActions, semantic tokens, inlay hints, folding, …) | 🚧 In progress |
| TS pipeline | Conformance harness (tsc-baseline format) | 🚧 In progress |
| Language | Pattern matching | 🚧 In progress |
| Language | Closures | 🚧 In progress |
| Language | Traits / `impl` | 🚧 In progress |
| Language | Trait objects | 🚧 In progress |
| Language | Generics | 🚧 In progress |
| Language | Const generics | ❌ Not yet |
| Language | Comptime evaluation | 🚧 In progress |
| Language | Async / await | 🚧 In progress |
| Language | Ownership / borrow checking | 🚧 In progress |
| Codegen | x86-64 native | 🚧 In progress |
| Codegen | arm64 native | 🚧 Partial |
| Codegen | WebAssembly | 🚧 Stub |
| Codegen | LLVM backend | 🚧 In progress |
| Tooling | `home check` / `home run` | ✅ Stable |
| Tooling | `home build` | 🚧 In progress |
| Tooling | Formatter / Linter / LSP / REPL | 🚧 In progress |
| Stdlib | Strings, ranges, arrays | ✅ Stable |
| Stdlib | HTTP, database, threading, FFI | 🚧 In progress |

For release notes see [`CHANGELOG.md`](./CHANGELOG.md).

## TypeScript parity

Home is being extended with a drop-in `tsc` / `tsgo` compatible
TypeScript frontend. The plan is documented in
[`docs/TS_PARITY_PLAN.md`](./docs/TS_PARITY_PLAN.md). Phase 4.5 is
substantially complete: a `home tsc` driver wires lex → parse →
bind → check → emit end-to-end with multi-file program graph,
parallel compile, source maps, tsc-compatible diagnostics, and a
zig-dtsx fast path for `.d.ts` emission.

Top-level shape (each link is a Zig package with its own tests):

- [`packages/ts_lexer`](./packages/ts_lexer/) — full ES2024 + TS keyword scanner (16-byte tokens, comptime perfect-hash keywords)
- [`packages/ts_parser`](./packages/ts_parser/) — recursive-descent statements, Pratt expressions, JSX, generics, decorators, full type-annotation grammar
- [`packages/hir`](./packages/hir/) — SoA HIR (21 B/node hot footprint, gated at compile time)
- [`packages/binder`](./packages/binder/) — symbol table with three TS meaning-spaces and declaration merging
- [`packages/ts_checker`](./packages/ts_checker/) — type interner, relation cache, expression-level checking
- [`packages/ts_emit`](./packages/ts_emit/) — streaming JS pretty-printer, V3 source maps, symbol-driven `.d.ts`, zig-dtsx fast path
- [`packages/ts_driver`](./packages/ts_driver/) — single-file end-to-end compile (lex → parse → bind → check → emit)
- [`packages/ts_program`](./packages/ts_program/) — multi-file program graph with parallel compileAllParallel
- [`packages/ts_resolver`](./packages/ts_resolver/) — module resolution across the five tsc strategies + path mapping
- [`packages/ts_diagnostics`](./packages/ts_diagnostics/) — tsc-compatible diagnostic formatting (default + pretty)
- [`packages/ts_cli`](./packages/ts_cli/) — `home tsc` CLI flag surface
- [`packages/ts_conformance`](./packages/ts_conformance/) — tsc-baseline conformance harness
- [`packages/ts_lsp`](./packages/ts_lsp/) — Language Server query surface (hover, definition, references, completion, codeActions, semantic tokens, inlay hints, folding, document symbols, …)
- [`packages/ts_lsp_server`](./packages/ts_lsp_server/) — JSON-RPC framing + method dispatch (~50 LSP-spec methods routed)
- [`packages/ts_cache`](./packages/ts_cache/) — content-addressed compilation cache with sharded disk persistence
- [`packages/ts_watch`](./packages/ts_watch/) — pluggable `StatFs` + watcher driving incremental recompiles in `home-tsc --watch`
- [`packages/d_hm`](./packages/d_hm/) — Home declaration files (the `.d.ts` analogue for `.home`)
- [`pantry/zig-dtsx`](https://github.com/stacksjs/dtsx/tree/main/packages/zig-dtsx) — vendored as a pantry dep; powers the `.d.ts` fast path (15-19× faster than tsgo per published benchmarks)

`home-tsc` and `home-lsp` ship as standalone binaries — see the
[`zig build` invocation](#build-commands) to compile them; they
install into `zig-out/bin/`.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/home-lang/home/main/install.sh | bash
```

The installer detects your platform, downloads a release tarball from GitHub
Releases, verifies its checksum, and installs the `home` binary to
`~/.home/bin`. It supports macOS (Intel + Apple Silicon), Linux (x64 + arm64),
and Windows (x64 + arm64, via Git Bash / WSL).

Useful environment variables:

- `HOME_VERSION=v0.1.0` (or `0.1.0`) &mdash; pin a specific release tag (default: `latest`)
- `HOME_INSTALL_DIR=/opt/home` &mdash; override install location (default: `~/.home`)
- `HOME_BIN_DIR=/usr/local/bin` &mdash; override where the binary is placed

## Build from Source

```bash
# Clone and build
git clone https://github.com/home-lang/home.git
cd home
pantry install        # pulls zig 0.16-dev from pantry
zig build             # build the compiler

# Run an example
./zig-out/bin/home build examples/fibonacci.home
./examples/fibonacci
```

Useful commands:

- `zig build` &mdash; build the compiler
- `zig build test` &mdash; run the unit-test suite
- `zig build examples` &mdash; run the native example executables (http_router, craft, fullstack, queue)
- `zig build run -- examples/fibonacci.home` &mdash; build, then run a file
- `scripts/check-examples.sh` &mdash; `home check` every `.home` example
- `zig build -Dgenerals=true generals` &mdash; opt in to the C&C Generals example (needs Xcode frameworks)

## Hello World

```home
fn main() {
  print("Hello, Home!")
}
```

## Language Overview

### Variables

```home
let name = "Alice"           // immutable by default
let mut counter = 0          // mutable
let age: int = 25            // explicit type
const PI = 3.14159           // compile-time constant
```

### Control Flow

```home
// if statements (parentheses required)
if (x > 5) {
  print("big")
} else {
  print("small")
}

// while loops
while (count < 10) {
  count = count + 1
}

// for loops
for (item in items) {
  print(item)
}

for (i in 0..10) {
  print(i)
}

// for with index
for (index, item in items) {
  print("{index}: {item}")
}
```

### Functions

```home
fn add(a: int, b: int): int {
  return a + b
}

fn greet(name: string) {
  print("Hello, {name}!")
}

// default parameter values
fn greet_with_default(name: string = "World") {
  print("Hello, {name}!")
}

greet_with_default()          // prints: Hello, World!
greet_with_default("Alice")   // prints: Hello, Alice!

// async functions
fn fetch_data(): async Result<Data> {
  let response = await http.get("/api/data")
  return response.json()
}
```

### Structs

```home
struct Point {
  x: int
  y: int
}

struct User {
  id: i64
  name: string
  email: string
}

let origin = Point { x: 0, y: 0 }
let user = User { id: 1, name: "Alice", email: "alice@example.com" }
```

### Enums

```home
enum Color {
  Red,
  Green,
  Blue,
  Custom(r: int, g: int, b: int)
}

enum Result<T, E> {
  Ok(T),
  Err(E)
}
```

### Pattern Matching

```home
match value {
  Ok(x) => print("Got: {x}"),
  Err(e) => print("Error: {e}")
}

match color {
  Color.Red => print("red"),
  Color.Green => print("green"),
  Color.Blue => print("blue"),
  Color.Custom(r, g, b) => print("rgb({r}, {g}, {b})")
}
```

### Expression Forms

If and match can be used as expressions that return values:

```home
// if expression
let status = if (code == 200) { "ok" } else { "error" }

// match expression
let name = match x {
  1 => "one",
  2 => "two",
  _ => "other"
}
```

### Null Safety Operators

```home
// Elvis operator (?:) - returns right side if left is null
let name = user?.name ?: "Anonymous"

// Null coalescing (??) - same as Elvis
let value = maybeNull ?? defaultValue

// Safe navigation (?.) - returns null if object is null
let city = user?.address?.city

// Safe indexing (?[]) - returns null if index out of bounds
let first = items?[0]
let safe = items?[10] ?: defaultItem
```

### Error Handling

```home
fn read_file(path: string): Result<string, Error> {
  let file = fs.open(path)?   // ? propagates errors
  return Ok(file.read_all())
}

// handle errors
match read_file("config.home") {
  Ok(content) => process(content),
  Err(e) => print("Failed: {e}")
}

// or with default
let content = read_file("config.home").unwrap_or("default")
```

### Arrays and Slices

```home
let numbers = [1, 2, 3, 4, 5]
let first = numbers[0]
let slice = numbers[1..4]      // [2, 3, 4]

for (n in numbers) {
  print(n)
}

// Array methods
numbers.len()       // 5
numbers.is_empty()  // false
numbers.first()     // 1
numbers.last()      // 5
```

### String Methods

```home
let s = "  Hello World  "

// Length
s.len()              // 15

// Case conversion
s.upper()            // "  HELLO WORLD  "
s.lower()            // "  hello world  "

// Trimming
s.trim()             // "Hello World"
s.trim_start()       // "Hello World  "
s.trim_end()         // "  Hello World"

// Searching
s.contains("World")  // true
s.starts_with("  H") // true
s.ends_with("  ")    // true

// Splitting and replacing
"a,b,c".split(",")           // ["a", "b", "c"]
s.replace("World", "Home")   // "  Hello Home  "

// Other methods
"ab".repeat(3)       // "ababab"
s.is_empty()         // false
s.char_at(2)         // "H"
"hello".reverse()    // "olleh"

// Method chaining
"  HELLO  ".trim().lower()  // "hello"
```

### Arithmetic Operators

```home
// Power operator (**)
let squared = 5 ** 2      // 25
let cubed = 2 ** 3        // 8
let power10 = 2 ** 10     // 1024

// Integer division (~/)
let result = 7 ~/ 2       // 3 (truncates toward zero)
let another = 17 ~/ 5     // 3

// Standard operators
let sum = 10 + 5          // 15
let diff = 10 - 3         // 7
let prod = 4 * 3          // 12
let quot = 10 / 4         // 2.5 (regular division)
let rem = 10 % 3          // 1 (modulo)
```

### Range Methods

```home
// Create ranges
let r = 0..10            // exclusive: 0,1,2,...,9
let inclusive = 0..=10   // inclusive: 0,1,2,...,10

// Range methods
r.len()                  // 10
r.first()                // 0
r.last()                 // 9
r.contains(5)            // true
r.contains(10)           // false (exclusive)

// Step through range
let stepped = (0..10).step(2)
stepped.to_array()       // [0, 2, 4, 6, 8]

// Inclusive range
inclusive.len()          // 11
inclusive.contains(10)   // true
inclusive.last()         // 10
```

### Generics

```home
fn map<T, U>(items: []T, f: fn(T): U): []U {
  let result = []U.init(items.len)
  for (i, item in items) {
    result[i] = f(item)
  }
  return result
}

struct Stack<T> {
  items: []T

  fn push(self, item: T) {
    self.items.append(item)
  }

  fn pop(self): Option<T> {
    return self.items.pop()
  }
}
```

### Comptime

```home
comptime fn factorial(n: int): int {
  if (n <= 1) {
    return 1
  }
  return n * factorial(n - 1)
}

const FACT_10 = factorial(10)  // computed at compile time
```

## Standard Library

### HTTP Server

```home
import http { Server, Response }

fn main() {
  let server = Server.bind(":3000")

  server.get("/", fn(req) {
    return "Hello from Home!"
  })

  server.get("/users/:id", fn(req): Response {
    let id = req.param("id")
    return Response.json({ id: id })
  })

  server.listen()
}
```

### Database

```home
import database { Connection }

fn main() {
  let db = Connection.open("app.db")

  db.exec("CREATE TABLE users (id INTEGER, name TEXT)")

  let stmt = db.prepare("INSERT INTO users VALUES (?, ?)")
  stmt.bind(1, 42)
  stmt.bind(2, "Alice")
  stmt.execute()

  let users = db.query("SELECT * FROM users")
  for (row in users) {
    print("User: {row.name}")
  }
}
```

### Async/Await

```home
fn fetch_users(): async []User {
  let response = await http.get("/api/users")
  return response.json()
}

fn main(): async {
  let users = await fetch_users()
  for (user in users) {
    print(user.name)
  }
}
```

## Project Structure

```
home/
├── src/main.zig           # CLI entry point
├── packages/              # 130+ Zig packages, each with its own tests
│   ├── lexer/             # Home tokenization
│   ├── parser/            # Home AST generation
│   ├── ast/               # Home syntax tree types
│   ├── types/             # Home type system
│   ├── codegen/           # Native code generation (x64 + arm64)
│   ├── interpreter/       # Tree-walking execution
│   ├── diagnostics/       # Error reporting
│   ├── ts_lexer/          # TS scanner (full ES2024 + TS keywords)
│   ├── ts_parser/         # TS parser (statements, expressions, JSX, generics)
│   ├── ts_checker/        # TS type interner, relation cache, expression typing
│   ├── ts_emit/           # JS + .d.ts emit (V3 source maps, zig-dtsx fast path)
│   ├── ts_driver/         # End-to-end per-file lex→parse→bind→check→emit
│   ├── ts_program/        # Multi-file graph + parallel compile + watch
│   ├── ts_resolver/       # Module resolution (5 tsc strategies + paths)
│   ├── ts_lsp/            # Language Server query surface
│   ├── ts_lsp_server/     # JSON-RPC framing + dispatch
│   ├── ts_conformance/    # tsc-baseline conformance harness
│   ├── hir/               # SoA HIR shared between both frontends
│   ├── binder/            # Symbol table (3 TS meaning-spaces, decl merging)
│   └── ...                # http, database, async, ffi, graphics, …
├── examples/              # Example programs
├── tests/                 # Integration tests
└── stdlib/                # Standard library
```

## Building

### Prerequisites

- Zig 0.16-dev (for building the compiler)

```bash
# Pulls the pinned zig dev build from pantry into ./pantry/zig/
pantry install
```

### Build Commands

```bash
# Build the compiler
zig build

# Run tests
zig build test

# Check all .home examples through `home check`
scripts/check-examples.sh

# Build and run an example
zig build run -- examples/fibonacci.home
```

## File Extensions

- `.home` - Standard source file extension
- `.hm` - Short alternative

## Features

- **Fast compilation** - Incremental builds with IR caching
- **Memory safety** - Ownership and borrowing without ceremony
- **Native performance** - Compiles to native x64 code
- **Modern syntax** - TypeScript-inspired, clean and readable
- **Pattern matching** - Exhaustive match expressions
- **Expression-oriented** - If and match as expressions
- **Null safety** - Elvis (`?:`), safe navigation (`?.`), safe indexing (`?[]`)
- **Async/await** - Zero-cost async programming
- **Generics** - Type-safe generic functions and types
- **Comptime** - Compile-time code execution
- **Error handling** - Result types with `?` propagation
- **Power operator** — `**` for exponentiation (`2 ** 10`)
- **Integer division** - `~/` for truncating division
- **Range methods** - `.len()`, `.step()`, `.contains()`, `.to_array()`
- **Default parameters** - `fn greet(name: string = "World")`
- **String methods** - `.trim()`, `.upper()`, `.split()`, and more

## Current Status

Home is under active development. For a granular, conservative view of what
works today vs. what is partial, in progress, or not yet started, see the
[capability matrix](#capability-matrix) above and the longer write-up at
[`docs/CAPABILITY_MATRIX.md`](./docs/CAPABILITY_MATRIX.md). Release notes live
in [`CHANGELOG.md`](./CHANGELOG.md).

## Contributing

Contributions welcome! See [CONTRIBUTING.md](./CONTRIBUTING.md).

## License

MIT License - see [LICENSE](./LICENSE)
