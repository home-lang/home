# The Home Programming Language

> **The speed of Zig. The safety of Rust. The joy of TypeScript.**

A systems & application language that doesn't compromise: blazing compile times, memory safety without ceremony, and APIs that spark joy.

---

## ⚠️ Project Status

**🚧 Active Development**

Home is currently in the foundation phase with a working compiler infrastructure and core packages.

- ✅ Lexer & Parser implementation
- ✅ AST & Type system foundation
- ✅ Interpreter & Code generation _(x64)_
- ✅ Package system with 27 core packages
- ✅ Modern testing framework with snapshots, mocks & benchmarks
- ✅ Standard library _(HTTP, Queue, Database)_
- ✅ VSCode extension with advanced debugging & profiling

**Follow Progress**: Watch this repo • [Discussions](../../discussions) • [Roadmap](./ROADMAP.md)

---

## Why Home?

Modern systems languages force impossible choices:

- **Zig**: Fast compilation, but manual memory management
- **Rust**: Memory safe, but slow compilation and steep learning curve
- **Go**: Fast builds, but garbage collected (unpredictable performance)
- **C/C++**: Performance, but undefined behavior everywhere

**Home refuses to choose.** We're building a language that delivers:

### ⚡ Speed

- **30-50% faster compile times than Zig** via aggressive IR caching
- **Sub-100ms incremental rebuilds** for rapid iteration
- **Runtime performance matching Zig/C** with zero-cost abstractions

### 🔒 Safety

- **Memory safety by default** with inferred ownership
- **No ceremony** - borrow checker infers most annotations
- **Fearless concurrency** with compile-time race detection

### 😊 Joy

- **TypeScript-inspired syntax** - familiar and clean
- **Helpful error messages** with fix suggestions
- **All tools in one binary** - no Makefile, no npm, no cargo
- **Batteries included** - Package manager, HTTP, JSON, CLI tools, database access in basics

---

## Quick Example

```home
import basics/http { Server }
import basics/database { Connection }

fn main() {
  let server = Server.bind(":3000")
  let db = Connection.open("app.db")

  server.get("/", fn(req) {
    return "Hello from Home!"
  })

  server.get("/users", fn(req) -> async Response {
    let users = await db.query("SELECT * FROM users")
    return Response.json(users)
  })

  server.get("/user/:id", fn(req) -> async Response {
    let user = await fetch_user(db, req.param("id"))
    return Response.json(user)
  })

  print("Server running on http://localhost:3000")
  server.listen()
}

fn fetch_user(db: &Connection, id: string) -> async Result<User> {
  let stmt = db.prepare("SELECT * FROM users WHERE id = ?")
  stmt.bind(1, id)
  return stmt.execute().first()
}

struct User {
  id: i64
  name: string
  email: string
}
```

**Key Features**:

- Clean syntax (TypeScript-like)
- Async/await without runtime overhead
- Result-based error handling
- Native database access (SQLite)
- Pattern matching
- Comptime evaluation
- Zero-cost abstractions

---

## Getting Started

### Installation

```bash
# Clone repository
git clone https://github.com/stacksjs/home.git
cd home

# Build compiler
zig build

# Run tests (200+ tests)
zig build test

# Run examples
zig build examples
```

### Your First Home Program

```bash
# Run the HTTP server example
zig build example-router

# Run the database example
zig build example-database

# Run the queue system example
zig build example-queue
```

### Prerequisites

- **Zig 0.15+** - For building the compiler
- **SQLite 3** - For database functionality (optional)

```bash
# Install Zig
curl -L https://ziglang.org/download/0.15.0/zig-macos-aarch64-0.15.0.tar.xz | tar xJ

# On macOS with Homebrew
brew install zig sqlite3

# On Ubuntu/Debian
sudo apt install zig libsqlite3-dev

# On Arch Linux
sudo pacman -S zig sqlite
```

---

## Core Architecture

Home is built as a **modular monorepo** with specialized packages:

### Compiler Packages

```
packages/
├── lexer/          # Tokenization and scanning
├── parser/         # AST generation from tokens
├── ast/            # Abstract Syntax Tree structures
├── types/          # Type system and inference
├── diagnostics/    # Error reporting with color output
├── interpreter/    # Direct code execution
├── codegen/        # Native x64 code generation
├── formatter/      # Code formatting
├── lsp/            # Language Server Protocol
├── pkg/            # Package manager
└── testing/        # Modern test framework (snapshots, mocks, benchmarks)
```

### Standard Library Packages

```
packages/
├── basics/         # Core standard library
│   ├── http_router # HTTP server with routing
│   └── zyte        # Desktop app integration
├── database/       # SQL database access (SQLite)
├── queue/          # Background job processing
├── async/          # Async runtime
├── build/          # Build system
├── cache/          # Caching utilities
└── tools/          # Development tools
```

### Advanced Features

```
packages/
├── comptime/       # Compile-time execution
├── generics/       # Generic type system
├── macros/         # Macro system
├── modules/        # Module system
├── patterns/       # Pattern matching
├── safety/         # Memory safety checks
├── traits/         # Trait system
└── acthome/         # GitHub Actions integration
```

### Developer Tooling

```
packages/
└── vscode-home/     # VSCode extension with:
    ├── Language Server Protocol (LSP)
    ├── Debug Adapter Protocol (DAP)
    ├── Time-travel debugging
    ├── Memory profiling with leak detection
    ├── CPU profiling with flame graphs
    ├── Multi-threaded debugging (deadlock detection)
    ├── GC profiling with pressure analysis
    └── Chrome DevTools format export
```

---

## Current Capabilities

### ✅ Working Now

#### HTTP Server (Laravel-style)

```home
import http_router { Router }

let router = Router.init()

// Route parameters
router.get("/user/:id", handler)

// Middleware
router.use(logger_middleware)
router.use(auth_middleware)

// Route groups
let api = router.group("/api")
api.get("/users", get_users)
api.post("/users", create_user)

// JSON responses
fn handler(req: Request) Response {
  return Response.json(.{ message = "Hello!" })
}
```

#### Database Access (Native SQLite)

```home
import database { Connection }

let conn = Connection.open(":memory:")

// Execute SQL
conn.exec("CREATE TABLE users (id INTEGER, name TEXT)")

// Prepared statements
let stmt = conn.prepare("INSERT INTO users VALUES (?, ?)")
stmt.bind_int(1, 42)
stmt.bind_text(2, "Alice")
stmt.step()

// Query with iteration
let result = conn.query("SELECT * FROM users")
while (result.next()) |row| {
  print("User: {s}", row.get_text(1))
}

// Query builder
let builder = QueryBuilder.init()
  .from("users")
  .where("age > 18")
  .order_by("name DESC")
  .limit(10)
let sql = builder.build()  // Generates SQL string
```

#### Background Jobs (Queue System)

```home
import queue { Queue, QueueConfig }

let config = QueueConfig.default()
let queue = Queue.init(config)

// Dispatch jobs
queue.dispatch("emails", "send_welcome_email")
queue.dispatch_sync("logs", "write_log")  // Execute immediately
queue.dispatch_after(60, "cleanup", "purge_cache")  // Delayed

// Process jobs
let worker = Worker.init(&queue)
worker.work(job_handler)

// Batch processing
let batch = Batch.init("batch_001")
batch.add(job1)
batch.add(job2)
batch.dispatch(&queue)

// Monitor queue
print("Pending: {}", queue.pending_count())
print("Failed: {}", queue.failed_count())
queue.retry_failed()  // Retry all failed jobs
```

### 🏗️ In Progress

- **Type inference** - Full Hindley-Milner with bidirectional checking
- **Ownership analysis** - Move semantics and borrow checking
- **Async/await** - Zero-cost async runtime
- **Pattern matching** - Exhaustive match expressions
- **Comptime execution** - Run code at compile time

---

## Package System

Home uses a **workspace-based monorepo** structure:

### File Extensions

Home supports multiple file extensions for flexibility:

**Source Files:**
- `.home` - Full extension (e.g., `main.home`)
- `.hm` - Short extension (e.g., `main.hm`)

**Configuration Files:**
- `couch.jsonc` - JSON with comments (recommended)
- `couch.json` - JSON configuration
- `home.json` - Alternative JSON name
- `home.toml` - TOML configuration
- `couch.toml` - Alternative TOML name (symlink to home.toml)

### Package Configuration (`home.toml` or `couch.jsonc`)

```toml
[package]
name = "home-database"
version = "0.1.0"
authors = ["Home Contributors"]
description = "SQL database access with SQLite driver"
license = "MIT"

[dependencies]
home-diagnostics = { path = "../diagnostics" }

[scripts]
test = "zig test src/database.zig"
bench = "zig build bench"
```

### Workspace Root (`home.toml` or `couch.jsonc`)

```toml
[package]
name = "home"
version = "0.1.0"

[workspaces]
packages = ["packages/*"]

[scripts]
build = "zig build"
test = "zig build test"
format = "find src packages -name '*.zig' -exec zig fmt {} +"
```

### Installing Home Packages

```bash
# Install from registry (planned)
home add http database queue

# Install from GitHub
home add github:user/repo

# Install from Git URL
home add https://github.com/user/repo.git

# Install specific version
home add database@0.1.0
```

### Package Storage

Home uses a unique approach to dependency management:

**Dependency Directory: `pantry/`**
- All dependencies are installed to the `pantry/` directory (not `node_modules`)
- Keeps your project organized and themed

**Lockfile: `.freezer`**
- Ensures reproducible builds by freezing exact versions
- JSON format for easy inspection and version control
- Stores checksums for integrity verification
- Example:
  ```json
  {
    "version": 1,
    "packages": {
      "http@1.0.0": {
        "name": "http",
        "version": "1.0.0",
        "resolved": "https://packages.home-lang.org/http/1.0.0",
        "integrity": "sha256-...",
        "source": {
          "type": "registry",
          "url": "https://packages.home-lang.org"
        }
      }
    }
  }
  ```

---

## Testing

Home has comprehensive test coverage across all packages:

```bash
# Run all tests (200+ tests)
zig build test

# Test specific package
zig test packages/database/tests/database_test.zig

# Run with verbose output
zig build test --summary all

# Run benchmarks
zig build bench
```

### Test Infrastructure

Home features a modern testing framework inspired by Vitest and Jest:

```home
import { test, expect, describe, mock, snapshot } from '@home/testing'

describe('User API', () => {
  test('creates user successfully', async () => {
    const user = await createUser({ name: 'Alice' })
    expect(user.name).toBe('Alice')
    expect(user).toMatchSnapshot()
  })

  test('handles validation errors', () => {
    const mockDb = mock(database)
    mockDb.save.mockReject(new Error('Invalid email'))

    expect(() => createUser({})).toThrow('Invalid email')
  })
})
```

**Features:**
- Snapshot testing with auto-update
- Comprehensive matchers (toBe, toEqual, toThrow, etc.)
- Mock functions with call tracking
- Async/await support
- Benchmarking utilities
- Parallel test execution
- Watch mode for development

**Test Statistics:**
- **Core Compiler**: 89 tests (lexer, parser, AST, types)
- **Standard Library**: 95 tests (HTTP, database, queue)
- **Code Generation**: 12 tests (x64 assembler)
- **Interpreter**: 15 tests (value system)
- **Diagnostics**: 12 tests (error reporting)
- **Total**: **200+ tests passing**

---

## VSCode Extension & Developer Tools

Home includes a comprehensive VSCode extension with professional-grade debugging and profiling tools:

### Installation

```bash
# From the Home repository
cd packages/vscode-home
npm install
npm run compile

# Install in VSCode
# Open Command Palette (Cmd+Shift+P)
# Run: Extensions: Install from VSIX
```

### Features

#### 🔍 **Time-Travel Debugging**
Step backward and forward through execution history:
- Record full program state at each step
- Compare snapshots to see what changed
- Navigate execution timeline
- Export/import debug sessions

```typescript
// Automatically records snapshots during debugging
// Use debugger controls to step back/forward
// View variable changes between any two points
```

#### 💾 **Memory Profiling**
Track allocations and detect leaks:
- Real-time allocation tracking
- Memory leak detection with heuristics
- Heap snapshot comparison
- Fragmentation analysis
- HTML reports with visualizations

#### ⚡ **CPU Profiling**
Sample-based performance profiling:
- Function call time tracking
- Interactive flame graphs
- Chrome DevTools format export
- Self-time vs total-time analysis

#### 🧵 **Multi-threaded Debugging**
Debug concurrent programs safely:
- Thread state tracking
- Automatic deadlock detection
- Race condition detection
- Synchronization event timeline
- Resource contention statistics

#### 🗑️ **Garbage Collection Profiling**
Analyze GC performance:
- GC event tracking (minor/major/incremental)
- Object lifetime analysis
- Generation statistics
- GC pressure detection
- Performance recommendations

### Commands

Available in VSCode Command Palette:

```
Home: Start Debugging
Home: Start CPU Profiler
Home: Stop CPU Profiler
Home: Generate Flame Graph
Home: Export Chrome DevTools Profile
Home: Start Memory Profiler
Home: Stop Memory Profiler
Home: Take Memory Snapshot
Home: Generate Memory Report
Home: Start GC Profiler
Home: Stop GC Profiler
Home: Analyze GC Pressure
Home: Time-Travel: Step Back
Home: Time-Travel: Step Forward
Home: Multi-thread: Show Deadlocks
Home: Multi-thread: Show Race Conditions
```

### Keybindings

- **F5**: Start debugging
- **Shift+F5**: Stop debugging
- **F10**: Step over
- **F11**: Step into
- **Shift+F11**: Step out
- **Cmd+Shift+B**: Time-travel step back
- **Cmd+Shift+F**: Time-travel step forward

---

## Examples

### HTTP Server Example

```bash
zig build example-router
```

Creates an HTTP server with:
- Route parameters (`/user/:id`)
- Middleware (logging, auth)
- Route groups (`/api/v1/*`)
- JSON responses
- Query parameters

### Database Example

```bash
zig build example-database
```

Demonstrates:
- Table creation and migrations
- CRUD operations
- Prepared statements
- JOIN queries
- Aggregate functions
- Query builder
- Transaction patterns

### Queue System Example

```bash
zig build example-queue
```

Shows:
- Job dispatching
- Delayed jobs
- Synchronous execution
- Batch processing
- Job retry logic
- Failed job handling
- Worker processes

### Full-Stack Example

```bash
zig build example-fullstack
```

Combines HTTP + Database + Queue for a complete application.

---

## Language Features (Planned)

### Memory Management
```home
// Ownership (implicit, no ceremony)
let data = read_file("config.home")  // data owns the string

// Automatic borrowing
fn process(data: string) {  // compiler infers &string
  print(data.len())
}

process(data)  // auto-borrow
print(data)    // still valid!

// Explicit ownership transfer
fn consume(data: string) {  // takes ownership
  // data is moved here
}

consume(data)
// print(data)  // Error: value moved
```

### Error Handling
```home
fn read_config() -> Result<Config> {
  let file = fs.read_file("config.home")?  // ? propagates errors
  let config = json.parse(file)?
  return Ok(config)
}

match read_config() {
  Ok(config) => app.start(config),
  Err(e) => log.error("Failed: {e}")
}

// Or unwrap with default
let config = read_config().unwrap_or(Config.default())
```

### Async/Await
```home
fn fetch_users() -> async []User {
  let tasks = [
    http.get("/users/1"),
    http.get("/users/2"),
    http.get("/users/3"),
  ]
  return await Promise.all(tasks)
}

// Concurrent database queries
fn get_dashboard_data() -> async Dashboard {
  let [users, posts, stats] = await Promise.all([
    db.query("SELECT * FROM users"),
    db.query("SELECT * FROM posts"),
    db.query("SELECT COUNT(*) FROM analytics"),
  ])

  return Dashboard { users, posts, stats }
}
```

### Comptime Magic
```home
// Run at compile time
comptime fn generate_routes() -> []Route {
  return fs.glob("routes/**/*.home")
    .map(|path| Route.from_path(path))
}

const ROUTES = generate_routes()  // executed during compilation

// Compile-time SQL validation
comptime fn validate_query(sql: string) {
  let parsed = sql_parser.parse(sql)
  if (!parsed.is_valid()) {
    @compile_error("Invalid SQL: " ++ sql)
  }
}

// Use at compile time
comptime validate_query("SELECT * FROM users WHERE id = ?")
```

### Pattern Matching
```home
match value {
  Ok(x) if x > 0 => print("Positive: {x}"),
  Ok(0) => print("Zero"),
  Ok(x) => print("Negative: {x}"),
  Err(e) => print("Error: {e}")
}

// Destructuring
match point {
  Point { x: 0, y: 0 } => print("Origin"),
  Point { x, y: 0 } => print("On x-axis at {x}"),
  Point { x: 0, y } => print("On y-axis at {y}"),
  Point { x, y } => print("Point ({x}, {y})")
}

// Enum matching
match response {
  HttpResponse.Ok(body) => send(body),
  HttpResponse.NotFound => send_404(),
  HttpResponse.Error(code, msg) => log_error(code, msg),
}
```

### Generics
```home
fn map<T, U>(items: []T, f: fn(T) -> U) -> []U {
  let result = []U.init(items.len)
  for (item, i in items) {
    result[i] = f(item)
  }
  return result
}

struct Result<T, E> {
  value: union {
    Ok(T),
    Err(E)
  }

  fn unwrap(self) -> T {
    match self.value {
      Ok(v) => return v,
      Err(e) => panic("Called unwrap on Err: {e}")
    }
  }

  fn unwrap_or(self, default: T) -> T {
    match self.value {
      Ok(v) => return v,
      Err(_) => return default
    }
  }
}
```

## Performance Goals

### Compile Time (vs Zig)
| Benchmark | Home Target | Zig Baseline |
|-----------|------------|-------------|
| Hello World | <50ms | ~70ms |
| 1000 LOC | <500ms | ~700ms |
| 10K LOC | <3s | ~5s |
| Incremental (1 file) | <50ms | ~150ms |

### Runtime Performance (vs Zig/C)
| Benchmark | Home Target | Zig/C |
|-----------|------------|-------|
| Fibonacci | ±5% | baseline |
| HTTP throughput | ±5% | baseline |
| Memory ops | ±5% | baseline |
| Database queries | ±5% | baseline |

*Benchmarks will be validated continuously starting Month 4*

---

## Community

### Get Involved

- **Discussions**: [GitHub Discussions](../../discussions) - Ideas, questions, feedback
- **Issues**: [GitHub Issues](../../issues) - Bug reports and feature requests
- **Contributing**: [`CONTRIBUTING.md`](./CONTRIBUTING.md) - How to contribute
- **Discord**: [Coming soon] - Real-time chat

### Contributors Welcome

We're looking for:
- **Compiler engineers** - Core implementation
- **Systems programmers** - Basics library development
- **DX enthusiasts** - Tooling and LSP
- **Technical writers** - Documentation
- **Early adopters** - Feedback and testing
- **Profiling experts** - Advanced debugging tools

[See open issues →](../../issues)

---

## FAQ

**Q: Is Home production-ready?**
A: Not yet. Home has a working compiler infrastructure and 200+ passing tests, but the full language specification is still being implemented. Expect alpha release by Month 6, 1.0 by Month 24.

**Q: Can I use Home now?**
A: Yes, for experimentation! You can build the compiler, run the examples, and explore the standard library. Not recommended for production use yet.

**Q: How can Home be faster than Zig?**
A: Aggressive IR caching at function level + parallel compilation + simpler type system. Will be validated via continuous benchmarking starting Month 4.

**Q: Why another systems language?**
A: Because none of Zig, Rust, Go, or C give us all three: speed + safety + joy. Home does.

**Q: What about garbage collection?**
A: No GC. Manual memory management with ownership/borrowing for safety.

**Q: What platforms are supported?**
A: **Full support** for Windows, macOS, and Linux on both x86_64 and ARM64. Native async I/O uses epoll (Linux), kqueue (macOS), and IOCP (Windows). See [CROSS_PLATFORM_SUPPORT.md](./CROSS_PLATFORM_SUPPORT.md) for details.

**Q: How is this funded?**
A: Open source, community-driven. Considering sponsorships/grants for sustainability.

**Q: Why Zig for bootstrapping?**
A: To learn from Zig's strengths/weaknesses while building a fast foundation. Self-host in Home at Phase 6.

**Q: What about C interop?**
A: Full C interop planned. You can already see this in the database package (SQLite bindings).

**Q: Does Home have a package registry?**
A: Not yet. Packages currently installed from Git. Official registry planned for Phase 1.

**Q: What makes Home's debugging tools special?**
A: Home includes time-travel debugging (step backward through execution), automatic deadlock detection for multi-threaded programs, memory leak detection, CPU flame graphs, and GC pressure analysis - all integrated into VSCode. Most languages don't have this level of tooling out of the box.

**Q: Can I use Home's testing framework now?**
A: Yes! The testing framework is fully functional with snapshot testing, mocks, async support, and benchmarking utilities. It's inspired by Vitest and Jest but designed for systems programming.

---

## Comparison

|  | Home | Zig | Rust | Go | C++ |
|---|-----|-----|------|----|----|
| Compile speed | ⚡⚡⚡ | ⚡⚡ | ⚡ | ⚡⚡⚡ | ⚡ |
| Memory safety | ✅ | ⚠️ | ✅ | ❌ GC | ❌ |
| Learning curve | 😊 | 🤔 | 😰 | 😊 | 😱 |
| Async/await | ✅* | ❌ | ⚠️ | ✅ | ⚠️ |
| Comptime | ✅* | ✅ | ⚠️ | ❌ | ⚠️ |
| Package manager | ✅ | ⚠️ | ✅ | ✅ | ❌ |
| IDE support | ✅ | ⚡ | ✅ | ✅ | ✅ |
| Modern testing | ✅ | ⚠️ | ✅ | ✅ | ⚠️ |
| Time-travel debug | ✅ | ❌ | ❌ | ❌ | ❌ |
| Database access | ✅ | ⚠️ | ✅ | ✅ | ⚠️ |
| HTTP server | ✅ | ⚠️ | ✅ | ✅ | ⚠️ |

*Planned, not yet implemented

---

## Project Structure

```
home/
├── src/
│   ├── main.zig          # CLI entry point
│   └── ion.zig           # Compiler library
├── packages/             # Core packages (27 total)
│   ├── lexer/           # Tokenization
│   ├── parser/          # AST generation
│   ├── ast/             # Syntax tree
│   ├── types/           # Type system
│   ├── interpreter/     # Code execution
│   ├── codegen/         # x64 generation
│   ├── diagnostics/     # Error reporting
│   ├── formatter/       # Code formatting
│   ├── testing/         # Modern test framework
│   ├── basics/          # Standard library
│   ├── database/        # SQLite access
│   ├── queue/           # Job processing
│   └── vscode-home/      # VSCode extension with advanced tooling
├── examples/            # Usage examples
│   ├── http_router_example.zig
│   ├── database_example.zig
│   ├── queue_example.zig
│   └── full_stack_zyte.zig
├── bench/               # Benchmarks
├── docs/                # Documentation
├── build.zig            # Build configuration
└── ion.toml             # Workspace configuration
```

---

## License

**MIT License**

Free for individuals, academia, and private enterprise.

[Full license →](./LICENSE)

---

## Acknowledgments

Home stands on the shoulders of giants:

- **Zig**: Comptime philosophy, honest design, and build system inspiration
- **Rust**: Memory safety model, ownership semantics, and error handling
- **TypeScript**: Developer experience, syntax ergonomics, and tooling standards
- **Bun**: Speed-first mentality, all-in-one tooling, and package management
- **Laravel**: Expressive APIs, queue system design, and developer joy
- **SQLite**: Embedded database excellence and reliability

Thank you to the language design community for paving the way.

---

## Citation

If you reference Home in academic work:

```bibtex
@software{home2025,
  title = {Home: A Systems Language for Speed, Safety, and Joy},
  author = {Stacks.js Team and Contributors},
  year = {2025},
  url = {https://github.com/stacksjs/home},
}
```

---

**Built with ❤️ by the Stacks.js team and contributors**

[GitHub](https://github.com/stacksjs/ion) • [Discussions](../../discussions) • [Issues](../../issues)
