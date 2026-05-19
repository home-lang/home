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

## Parity status

The whole status, percentage-based. Every number is a **byte-for-byte,
file-count, or row-count measurement** against an external baseline —
not an aspirational target. Each row cites the package, harness, or
upstream source that produces it.

> Refreshed 2026-05-19. Coarse-mode TS corpus and per-slice exact mode
> are regression-gated on every PR; Bun port % is file-count progress
> and grows with each `packages/runtime/src/**` landing.

### Headline numbers

| Area | Coverage | Source |
|---|---|---|
| **TypeScript — coarse corpus** | **5,907 / 5,907 — 100%** | `HOME_TS_CONFORMANCE_FULL=1` against upstream conformance corpus |
| **TypeScript — exact (byte-for-byte)** | **~4,060 / 5,907 — ~68.7%** | `HOME_TS_CONFORMANCE_FULL=1 HOME_TS_CONFORMANCE_EXACT=1` |
| **TypeScript — baseline-aware (19 folders)** | **586 / 586 — 100%** | per-fixture `.errors.txt` byte comparison |
| **TypeScript — named-category survey** | **86 / 86 — 100%** | `assignmentCompatibility` + `comparable` + `inOperator` + `stringLiteral` |
| **TypeScript — diagnostic codes** | **~2,000 entries** | mirrors the full upstream `diag(code, …)` table |
| **LSP wire methods** | **53 / ~70 — ~76%** | `SUPPORTED_METHODS` in `packages/ts_lsp_server/` |
| **Bun runtime — source files ported** | **380 / 1,193 — ~31.9%** | substrate only (functional after JSC bring-up) |
| **Node.js — `node:*` binding files** | **15 files** | blocked on Phase 12.2 JSC |
| **Language features (capability matrix)** | **9 stable / 33 partial / 1 not-yet — 43 total** | ~21% stable, ~77% in progress, ~2% not yet |
| **Total test count** | **3,300+ / 3,300+ — ~100%** | `zig build test --summary all` (pre-existing `d_ts_fast` + `home_rt` env aside) |

### TypeScript parity — `home tsc` vs `tsc` / `tsgo`

Measured by running the upstream TypeScript conformance corpus through
`packages/ts_conformance/`. The harness compares **byte-for-byte against
upstream `.errors.txt` baselines** in exact mode (`HOME_TS_CONFORMANCE_EXACT=1`);
coarse mode (`HOME_TS_CONFORMANCE_FULL=1` alone) only asserts that we emit
the same *families* of diagnostics.

| Measurement | Pass rate | Notes |
|---|---|---|
| **Coarse mode (5,907 cases)** | **5,907 / 5,907 — 100%** | Saturated; remains the per-PR merge gate. |
| **Exact mode (byte-for-byte, full corpus)** | **~4,060 / 5,907 — ~68.7%** | Ratcheting weekly. |
| Baseline-aware exact categories (19 folders, 586 cases) | 586 / 586 — 100% | `apparentType`, `bestCommonType`, `recursiveTypes`, `typeInference`, `keyof`, `conditional`, `instanceOf`, `widenedTypes`, `specifyingTypes`, `primitives`, `any`, `import`, `uniqueSymbol`, `namedTypes`, `localTypes`, `forAwait`, `unknown`, `witness`, `typeAliases`, `asyncGenerators`. |
| Named-category exact survey (4 folders, 86 cases) | 86 / 86 — 100% | `assignmentCompatibility` 70/70, `comparable` 13/13, `inOperator` 2/2, `stringLiteral` 1/1. |
| Smoke (3 folders, 16 cases) | 16 / 16 — 100% | Per-PR fast path. |
| TS diagnostic-code catalogue | ~2,000 entries | Mirrors the full upstream code → message table; powers `home-lsp` hover-on-`TS1234`. |

**Exact mode by 1,000-case slice (latest):**

| Slice | Pass rate | % |
|---|---|---|
| `START=0   LIMIT=1000` | 604 / 1,000 | 60.4% |
| `START=1000 LIMIT=1000` | 611 / 1,000 | 61.1% |
| `START=2000 LIMIT=1000` | **907 / 1,000** | **90.7%** |
| `START=3000 LIMIT=1000` | 646 / 1,000 | 64.6% |
| `START=4000 LIMIT=1000` | **864 / 1,000** | **86.4%** |
| `START=5000 LIMIT=907`  | 545 / 907   | 60.1% |

Reproduce locally:

```bash
HOME_TS_CONFORMANCE_FULL=1 \
HOME_TS_CONFORMANCE_EXACT=1 \
HOME_TS_CONFORMANCE_START=2000 \
HOME_TS_CONFORMANCE_LIMIT=1000 \
zig build test -Dfilter=ts_conformance
```

### Bun runtime port (`packages/runtime/`)

Phase 12 vendors Bun's Zig source under MIT and rewrites it to compile
against Home's stdlib. **Substrate only today** — the runtime won't `run`
JS / TS until JSC bring-up (sub-phase 12.2) lands.

| Measurement | Coverage | % |
|---|---|---|
| **Bun source files ported** | **380 / 1,193** | **~31.9%** |
| Subsystems scaffolded | 54 directories under `packages/runtime/src/` | — |
| Functional runtime | 🚧 Substrate only | — |

Upstream pinned at `fd0b6f1a` (see
[`packages/runtime/UPSTREAM_SHA.txt`](./packages/runtime/UPSTREAM_SHA.txt));
full audit at
[`packages/runtime/PORT_AUDIT_2026-05-18.md`](./packages/runtime/PORT_AUDIT_2026-05-18.md).
The release gate per [`packages/runtime/README.md`](./packages/runtime/README.md):
Bun's `test/` corpus must pass **100% with no skips** once feature-complete.

**Phase-by-phase status:**

| Sub-phase | Source under `~/Code/bun/src/` | Status |
|---|---|---|
| 12.1 — CLI | `cli/` | 🚧 scaffold landed |
| 12.2 — JSC bring-up | `jsc/`, `bun.js.zig` | ❌ blocked on JSC C++ engine |
| 12.3 — Event loop / IO / async | `event_loop/`, `io/`, `async/` | 🚧 not started |
| 12.4 — Module loader | `resolver/`, `module_loader.zig` | 🚧 blocked on 12.2 |
| 12.5 — Web / HTTP / DNS | `web/`, `http/`, `csrf/`, `dns/` | 🚧 blocked on 12.3 |
| 12.6 — Home.* JS surface | `bun.zig` (renamed to `Home.*`) | 🚧 blocked on 12.2 |
| 12.7 — `node:*` shims | `node/` | 🚧 blocked on 12.2 (15 binding files copied) |
| 12.8 — `home test` runner | `test/` | 🚧 blocked on 12.2 |
| 12.9 — Pantry integration | `install/` | 🚧 scaffold in progress |
| 12.10 — CLI surface | `cli/` | 🚧 scaffold landed |
| 12.11 — Cross-compile + bundles | `build/` | 🚧 not started |

### Node.js compatibility (`packages/runtime/src/node/`)

Node's `node:*` namespace lands as part of the Bun runtime port (Bun
ships `node:*` shims natively, which we vendor verbatim). Numbers
below are Zig-side only; the JS-visible `node:*` surface attaches once
JSC is up.

| Measurement | Coverage | Notes |
|---|---|---|
| Node binding files ported | 15 files | `path`, `Stat`, `StatFS`, `dir_iterator`, `time_like`, `fs_events`, `os_constants`, `nodejs_error_code`, `node_fs_constant`, `node_net_binding`, `node_error_binding`, `uv_signal_handle_windows`, `types`, `util/parse_args_utils`, `assert/myers_diff`. |
| Functional `node:*` modules | 🚧 Blocked on Phase 12.2 (JSC) | Pantry CLI replaces `npm install` / `bun install`; everything else routes through the Bun runtime port once JSC is live. |

### LSP / IDE coverage — `home-lsp` vs `tsserver`

| Measurement | Coverage | % |
|---|---|---|
| **Wire methods routed** | **53 / ~70** | **~76%** |

Routed methods (`SUPPORTED_METHODS` in
[`packages/ts_lsp_server/src/ts_lsp_server.zig`](./packages/ts_lsp_server/src/ts_lsp_server.zig)):
hover, definition, declaration, typeDefinition, implementation,
references (cross-file), completion + completionItem/resolve,
signatureHelp, semanticTokens (full + delta + range), inlayHint
(+ resolve), codeAction, codeLens (+ resolve), documentLink (+ resolve),
foldingRange, selectionRange, linkedEditingRange, documentHighlight,
documentSymbol + workspace/symbol, rename + prepareRename,
prepareCallHierarchy + incoming/outgoingCalls,
prepareTypeHierarchy + supertypes/subtypes, willSaveWaitUntil,
willRenameFiles, executeCommand, moniker (LSIF), inlineValue,
inlineCompletion, formatting + onTypeFormatting,
documentColor + colorPresentation, pull-based diagnostic +
workspace/diagnostic, lifecycle (initialize / initialized /
shutdown / exit), synchronization (didOpen / didChange / didClose /
publishDiagnostics).

**Remaining surface:** quick-fix breadth (organize imports + add
import + add explicit type annotation landed; fix-all,
missing-return-type, infer-parameter-types pending), FS-event-driven
push diagnostics, full formatter pass (current `formatDocument`
returns source unchanged), richer auto-import completion via
cross-file interner search.

### Language features

16 language rows from the
[Capability Matrix](./docs/CAPABILITY_MATRIX.md):

| Status | Count | % |
|---|---|---|
| ✅ Stable | 3 | 18.8% |
| 🚧 In progress / partial | 12 | 75.0% |
| ❌ Not yet | 1 | 6.3% |

**Per-feature:**

| Feature | Status |
|---|---|
| Lexer (full token set, escapes, line/col tracking) | ✅ Stable |
| Recursive-descent parser with error recovery | ✅ Stable |
| Type inference (primitives, structs, enums, arrays) | ✅ Stable |
| Pattern matching (`match` over enums, primitives, wildcards) | 🚧 In progress |
| Closures | 🚧 In progress |
| Traits / `impl` blocks | 🚧 In progress |
| Trait objects / dynamic dispatch | 🚧 In progress |
| Generics (functions and types) | 🚧 In progress |
| Comptime evaluation | 🚧 In progress |
| Macros (`todo!`, `assert!`, `unreachable!`, …) | 🚧 In progress |
| Null-safety operators (`?.`, `?:`, `??`, `?[]`) | 🚧 In progress |
| Result types and `?` propagation | 🚧 In progress |
| Async / await | 🚧 In progress |
| Ownership / move checking | 🚧 In progress |
| Borrow checker | 🚧 In progress |
| Const generics | ❌ Not yet |

### Codegen targets

7 codegen rows:

| Status | Count | % |
|---|---|---|
| ✅ Stable | 1 | 14.3% |
| 🚧 In progress / partial | 6 | 85.7% |

**Per-target:**

| Target | Status |
|---|---|
| Tree-walking interpreter | ✅ Stable |
| x86-64 native codegen | 🚧 Substantial (primary target) |
| arm64 codegen | 🚧 Partial (assembler scaffolding only) |
| WebAssembly codegen | 🚧 Stub |
| LLVM backend | 🚧 In progress |
| ELF object emission | 🚧 In progress |
| Mach-O object emission | 🚧 In progress |

### Tooling

11 tooling rows:

| Status | Count | % |
|---|---|---|
| ✅ Stable | 2 | 18.2% |
| 🚧 In progress / partial | 9 | 81.8% |

**Per-tool:**

| Tool | Status |
|---|---|
| `home check` (type-check) | ✅ Stable |
| `home run` (interpret) | ✅ Stable |
| `home build` (native binary) | 🚧 In progress |
| `home test` runner | 🚧 In progress |
| Formatter | 🚧 In progress |
| Linter | 🚧 In progress |
| LSP / IDE integration | 🚧 In progress (see [LSP coverage](#lsp--ide-coverage--home-lsp-vs-tsserver)) |
| VSCode extension | 🚧 In progress |
| REPL | 🚧 In progress |
| Package manager (`pkg`) | 🚧 In progress |
| Incremental compilation / IR cache | 🚧 In progress |

### Standard library

9 stdlib categories tracked in the capability matrix (the project ships
**135 packages under `packages/`** — most are 🚧 until end-to-end validated):

| Status | Count | % |
|---|---|---|
| ✅ Stable | 3 | 33.3% |
| 🚧 In progress / partial | 6 | 66.7% |

**Per-module:**

| Module | Status |
|---|---|
| Core primitives (`int`, `float`, `bool`, `string`, arrays) | ✅ Stable |
| String methods (`trim`, `upper`, `split`, …) | ✅ Stable |
| Range methods (`len`, `step`, `contains`, …) | ✅ Stable |
| HTTP server | 🚧 In progress |
| Database / SQL | 🚧 In progress |
| Threading | 🚧 In progress |
| FFI / C interop | 🚧 In progress |
| Audio / video / graphics | 🚧 In progress |
| Kernel / OS modules | 🚧 In progress |

### Capability matrix — combined totals

All 43 rows from [`docs/CAPABILITY_MATRIX.md`](./docs/CAPABILITY_MATRIX.md):

| Status | Count | % |
|---|---|---|
| ✅ Stable | 9 | ~20.9% |
| 🚧 In progress / partial | 33 | ~76.7% |
| ❌ Not yet | 1 | ~2.3% |

The conservative bias is intentional: anything not exercised by an
example or test stays 🚧 even when the underlying code is largely there.

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
- [`packages/ts_lsp_server`](./packages/ts_lsp_server/) — JSON-RPC framing + method dispatch (53 LSP-spec methods routed; see [parity status](#lsp-coverage--home-lsp-vs-tsserver))
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
