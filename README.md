# 🧬 Ion

> **The speed of Zig. The safety of Rust. The joy of TypeScript.**

A systems language that doesn't compromise: blazing compile times, memory safety without ceremony, and APIs that spark joy.

---

## ⚠️ Project Status

**🚧 In Design & Early Development** (Phase 0)

Ion is currently in the foundation phase. The compiler is being built, core decisions are being made, and benchmarks are being established. **Not ready for production use.**

- ✅ Strategic roadmap complete
- 🏗️ Compiler implementation in progress
- 📊 Benchmark infrastructure: TBD
- 🎯 Target: First working compiler by Month 3

**Follow Progress**: Watch this repo • [Discussions](../../discussions) • [Roadmap](./ROADMAP.md)

---

## Why Ion?

Modern systems languages force impossible choices:

- **Zig**: Fast compilation, but manual memory management
- **Rust**: Memory safe, but slow compilation and steep learning curve  
- **Go**: Fast builds, but garbage collected (unpredictable performance)
- **C/C++**: Performance, but undefined behavior everywhere

**Ion refuses to choose.** We're building a language that delivers:

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
- **Batteries included** - HTTP, JSON, CLI tools in stdlib

---

## Quick Example

```ion
import std/http { Server }

fn main() {
  let server = Server.bind(":3000")
  
  server.get("/", fn(req) {
    return "Hello from Ion!"
  })
  
  server.get("/user/:id", fn(req) -> async Response {
    let user = await fetch_user(req.param("id"))
    return Response.json(user)
  })
  
  print("Server running on http://localhost:3000")
  server.listen()
}

fn fetch_user(id: string) -> async Result<User> {
  let response = await http.get("/api/users/{id}")
  return response.json()
}

struct User {
  name: string
  email: string
}
```

**Key Features**:
- Clean syntax (TypeScript-like)
- Async/await without runtime overhead
- Result-based error handling
- Pattern matching
- Comptime evaluation
- Zero-cost abstractions

---

## Getting Started

### For Contributors (Phase 0)

Ion is in early development. Here's how to contribute:

1. **Read the roadmap**: [`ROADMAP.md`](./ROADMAP.md) - Strategic vision
2. **Check milestones**: [`MILESTONES.md`](./MILESTONES.md) - Track progress  
3. **Start building**: [`GETTING-STARTED.md`](./GETTING-STARTED.md) - Implementation guide
4. **Understand decisions**: [`DECISIONS.md`](./DECISIONS.md) - Architecture choices

### Prerequisites

```bash
# Install Zig (for compiler development)
curl -L https://ziglang.org/download/ | tar xz

# Clone repository
git clone https://github.com/stacksjs/ion.git
cd ion

# Build compiler (when implemented)
zig build

# Run tests
zig build test
```

### Current Focus: Phase 0 (Months 1-3)

- ✅ Week 1: Lexer implementation
- ⏳ Week 2: Parser (AST construction)
- ⏳ Week 3: Interpreter (direct execution)
- ⏳ Week 4-6: Compilation + benchmarks vs Zig

---

## Core Principles

### 1. Predictable Performance
- No GC, no hidden allocations, no JIT
- What you write is what runs
- Profile-guided optimization available

### 2. Fast Builds by Design  
- Incremental compilation at function level
- IR caching with content-addressable storage
- Parallel compilation by default
- Sub-100ms rebuilds for typical changes

### 3. Safety Without Friction
- Ownership and borrowing inferred by compiler
- Move semantics by default
- Automatic borrow insertion for read-only access
- `unsafe` escape hatch when needed

### 4. Comptime as Superpower
- Full language available at compile time
- Filesystem access, reflection, codegen
- No separate macro system needed
- Zig-level power, cleaner syntax

### 5. Unified Toolchain
- One binary: `ion`
- Built-in: compiler, package manager, formatter, LSP, test runner
- No glue scripts or third-party tools required

### 6. Developer Joy
- Minimal syntax inspired by TypeScript
- Error messages with fix suggestions
- Instant LSP feedback
- Comprehensive stdlib (HTTP, JSON, async I/O)

---

## Language Features (Planned)

### Memory Management
```ion
// Ownership (implicit, no ceremony)
let data = read_file("config.ion")  // data owns the string

// Automatic borrowing
fn process(data: string) {  // compiler infers &string
  print(data.len())
}

process(data)  // auto-borrow
print(data)    // still valid!
```

### Error Handling
```ion
fn read_config() -> Result<Config> {
  let file = fs.read_file("config.ion")?  // ? propagates errors
  let config = json.parse(file)?
  return Ok(config)
}

match read_config() {
  Ok(config) => app.start(config),
  Err(e) => log.error("Failed: {e}")
}
```

### Async/Await
```ion
fn fetch_users() -> async []User {
  let tasks = [
    http.get("/users/1"),
    http.get("/users/2"),
    http.get("/users/3"),
  ]
  return await Promise.all(tasks)
}
```

### Comptime Magic
```ion
// Run at compile time
comptime fn generate_routes() -> []Route {
  return fs.glob("routes/**/*.ion")
    .map(|path| Route.from_path(path))
}

const ROUTES = generate_routes()  // executed during compilation
```

### Pattern Matching
```ion
match value {
  Ok(x) if x > 0 => print("Positive: {x}"),
  Ok(0) => print("Zero"),
  Ok(x) => print("Negative: {x}"),
  Err(e) => print("Error: {e}")
}
```

---

## Roadmap to 1.0

### Phase 0: Foundation (Months 1-3) ← **We are here**
- Lexer, parser, interpreter
- First compilation to native binary
- Benchmark infrastructure
- **Goal**: Prove 30% faster compile times vs Zig

### Phase 1: Core Language (Months 4-8)
- Type system with generics
- Ownership & borrow checking
- Developer tooling (fmt, doc, check)
- Package manager
- **Goal**: Sub-100ms incremental builds

### Phase 2: Async & Concurrency (Months 9-11)
- Async/await syntax
- Thread safety analysis
- Async I/O and networking
- **Goal**: Match Tokio throughput

### Phase 3: Comptime (Months 12-14)
- Compile-time execution
- Reflection and codegen
- Advanced optimizations
- **Goal**: Zig-level metaprogramming

### Phase 4-6: Production (Months 15-24)
- Complete standard library
- Cross-platform (Linux, macOS, Windows, WASM)
- Full IDE support (LSP)
- Package registry
- Self-hosting compiler
- **Goal**: 1.0 release

[Full roadmap →](./ROADMAP.md)

---

## Performance Goals

### Compile Time (vs Zig)
| Benchmark | Ion Target | Zig Baseline |
|-----------|------------|-------------|
| Hello World | <50ms | ~70ms |
| 1000 LOC | <500ms | ~700ms |
| 10K LOC | <3s | ~5s |
| Incremental (1 file) | <50ms | ~150ms |

### Runtime Performance (vs Zig/C)
| Benchmark | Ion Target | Zig/C |
|-----------|------------|-------|
| Fibonacci | ±5% | baseline |
| HTTP throughput | ±5% | baseline |
| Memory ops | ±5% | baseline |

*Benchmarks validated continuously starting Month 3*

---

## Community

### Get Involved

- **Discussions**: [GitHub Discussions](../../discussions) - Ideas, questions, feedback
- **Discord**: [Coming soon] - Real-time chat
- **Contributing**: [`CONTRIBUTING.md`](./CONTRIBUTING.md) - How to contribute
- **Twitter**: [@ionlang](https://twitter.com/ionlang) - Updates [TBD]

### Contributors Welcome

We're looking for:
- **Compiler engineers** - Core implementation
- **Systems programmers** - stdlib development  
- **DX enthusiasts** - Tooling and LSP
- **Technical writers** - Documentation
- **Early adopters** - Feedback and testing

[See open issues →](../../issues)

---

## FAQ

**Q: Is Ion production-ready?**  
A: No. Ion is in Phase 0 (foundation). Expect 1.0 by Month 24.

**Q: How can Ion be faster than Zig?**  
A: Aggressive IR caching at function level + parallel compilation + simpler type system. Validated via continuous benchmarking.

**Q: Why another systems language?**  
A: Because none of Zig, Rust, Go, or C give us all three: speed + safety + joy. Ion does.

**Q: What about garbage collection?**  
A: No GC. Manual memory management with ownership/borrowing for safety.

**Q: Can I use Ion now?**  
A: Not yet. Watch this repo for updates. Compiler basics expected Month 3.

**Q: How is this funded?**  
A: Open source, community-driven. Considering sponsorships/grants for sustainability.

**Q: Why Zig for bootstrapping?**  
A: To learn from Zig's strengths/weaknesses. Self-host in Ion at Phase 6.

[More FAQ →](./docs/FAQ.md) [TBD]

---

## Comparison

|  | Ion | Zig | Rust | Go | C++ |
|---|-----|-----|------|----|----|  
| Compile speed | ⚡⚡⚡ | ⚡⚡ | ⚡ | ⚡⚡⚡ | ⚡ |
| Memory safety | ✅ | ⚠️ | ✅ | ❌ GC | ❌ |
| Learning curve | 😊 | 🤔 | 😰 | 😊 | 😱 |
| Async/await | ✅ | ❌ | ⚠️ | ✅ | ⚠️ |
| Comptime | ✅ | ✅ | ⚠️ | ❌ | ⚠️ |
| Package manager | ✅ | ⚠️ | ✅ | ✅ | ❌ |
| IDE support | ✅* | ⚡ | ✅ | ✅ | ✅ |

*Planned for Phase 6

---

## License

**MIT + Pro-Democracy License**

Free for individuals, academia, and private enterprise.  
Restricted for authoritarian governments or state-sponsored misuse.

[Full license →](./LICENSE) [TBD]

---

## Acknowledgments

Ion stands on the shoulders of giants:

- **Zig**: Comptime philosophy and honest design
- **Rust**: Memory safety model and ownership semantics  
- **TypeScript**: Developer experience and ergonomics
- **Bun**: Speed-first mentality and tooling integration

Thank you to the language design community for paving the way.

---

## Citation

If you reference Ion in academic work:

```bibtex
@software{ion2025,
  title = {Ion: A Better Systems Language},
  author = {Stacks.js Team},
  year = {2025},
  url = {https://github.com/stacksjs/ion}
}
```

---

**Built with ❤️ by the Stacks.js team and contributors**

[Website](https://ion.land) [TBD] • [Documentation](./docs) [TBD] • [GitHub](https://github.com/stacksjs/ion)
