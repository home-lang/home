# Ion Implementation Guide - Quick Start

Your tactical guide to start implementing Ion **today**.

---

## Phase 0: Week 1-3 Setup

### Week 1: Lexer

**Goal**: Tokenize Ion source code

**Steps**:
1. Create repository structure
2. Set up Zig build system
3. Implement Token types (keywords, operators, literals)
4. Implement Lexer with basic scanning
5. Add tests for tokenization
6. Create `ion parse` command

**Deliverables**:
- `src/lexer/token.zig` - Token definitions
- `src/lexer/lexer.zig` - Lexer implementation
- `tests/lexer_test.zig` - Test suite
- `examples/hello.ion` - First example file

**Validate**:
```bash
zig build test
./zig-out/bin/ion parse examples/hello.ion
```

### Week 2: Parser

**Goal**: Build Abstract Syntax Tree from tokens

**Steps**:
1. Define AST node types (Expr, Stmt, Decl)
2. Implement recursive descent parser
3. Parse expressions with precedence
4. Parse statements and declarations
5. Add comprehensive error reporting
6. Create test suite

**Deliverables**:
- `src/ast/ast.zig` - AST definitions
- `src/parser/parser.zig` - Parser implementation
- `tests/parser_test.zig` - Parser tests

**Validate**:
```bash
ion parse --ast examples/hello.ion
```

### Week 3: Interpreter

**Goal**: Execute AST directly for rapid iteration

**Steps**:
1. Create Value type for runtime values
2. Implement expression evaluator
3. Add variable storage
4. Implement function calls
5. Add basic std functions (print, assert)
6. Create `ion run` command

**Deliverables**:
- `src/interpreter/interpreter.zig`
- `src/interpreter/value.zig`
- Working hello world execution

**Validate**:
```bash
ion run examples/hello.ion
# Output: Hello, Ion!
```

---

## Phase 0: Week 4-6 Compilation

### Week 4: Type System

**Goal**: Type checking and inference

**Steps**:
1. Define type representation
2. Implement type checking pass
3. Add type inference for `let` bindings
4. Check function signatures
5. Validate expressions

**Deliverables**:
- `src/types/types.zig`
- `src/semantic/checker.zig`

### Week 5: IR Generation

**Goal**: Lower AST to intermediate representation

**Steps**:
1. Design IR instruction set
2. Implement IR builder
3. Lower expressions to IR
4. Lower control flow
5. Add IR serialization

**Deliverables**:
- `src/ir/ir.zig`
- `src/ir/builder.zig`
- `src/lower/lower.zig`

### Week 6: Cranelift Backend

**Goal**: Generate native code

**Steps**:
1. Integrate Cranelift dependency
2. Translate IR to Cranelift IR
3. Generate object files
4. Link executable
5. Create `ion build` command

**Deliverables**:
- `src/codegen/cranelift.zig`
- Native binary output
- First benchmark vs Zig

**Validate**:
```bash
ion build examples/hello.ion
./hello
time ion build examples/benchmark.ion  # Compare to Zig
```

---

## Phase 1: Month 4-8 Core Features

### Quick Implementation Checklist

**Month 4: Language Features**
- [ ] Generics with monomorphization
- [ ] Result<T> and error handling
- [ ] Pattern matching
- [ ] Basic ownership tracking
- [ ] Conservative borrow checker

**Month 5: Safety**
- [ ] Move semantics
- [ ] Automatic borrow inference  
- [ ] Lifetime analysis
- [ ] Memory safety diagnostics

**Month 6: Tooling**
- [ ] `ion fmt` - code formatter
- [ ] `ion check` - fast validation
- [ ] `ion doc` - documentation generator
- [ ] Rich error messages with colors

**Month 7: Build System**
- [ ] Module system
- [ ] Dependency graph
- [ ] Incremental compilation
- [ ] IR caching strategy
- [ ] Parallel builds

**Month 8: Package Manager**
- [ ] `ion.toml` manifest
- [ ] `ion add` command
- [ ] Git dependency resolution
- [ ] Lockfile generation

---

## Quick Reference: Project Structure

```
ion/
├── build.zig                 # Zig build configuration
├── ion.toml                  # Ion project manifest (future)
├── README.md                 # Project overview
├── ROADMAP.md               # Strategic roadmap (this doc's companion)
├── GETTING-STARTED.md       # This file
│
├── src/
│   ├── main.zig            # CLI entrypoint
│   ├── lexer/
│   │   ├── lexer.zig       # Tokenization
│   │   └── token.zig       # Token types
│   ├── parser/
│   │   └── parser.zig      # AST construction
│   ├── ast/
│   │   └── ast.zig         # AST node definitions
│   ├── semantic/
│   │   ├── checker.zig     # Type checking
│   │   └── resolver.zig    # Name resolution
│   ├── types/
│   │   └── types.zig       # Type system
│   ├── interpreter/
│   │   ├── interpreter.zig # Tree-walking interpreter
│   │   └── value.zig       # Runtime values
│   ├── ir/
│   │   ├── ir.zig          # IR definitions
│   │   └── builder.zig     # IR construction
│   ├── lower/
│   │   └── lower.zig       # AST -> IR lowering
│   ├── codegen/
│   │   └── cranelift.zig   # Code generation
│   ├── cache/
│   │   └── cache.zig       # Build cache
│   └── cli/
│       └── commands.zig    # CLI commands
│
├── std/                     # Standard library (future)
│   ├── io.ion
│   ├── fs.ion
│   └── http.ion
│
├── tests/                   # Test suite
│   ├── lexer_test.zig
│   ├── parser_test.zig
│   └── integration/
│
├── examples/               # Example programs
│   ├── hello.ion
│   ├── fibonacci.ion
│   └── http_server.ion
│
├── bench/                  # Benchmarks
│   ├── compile_time.sh
│   ├── runtime_perf.sh
│   └── vs_zig/
│
└── docs/                   # Documentation
    ├── grammar.md
    ├── type_system.md
    └── ir_spec.md
```

---

## Quick Reference: Commands to Implement

```bash
# Phase 0 (Months 1-3)
ion parse <file>           # Tokenize and parse (Week 1-2)
ion run <file>             # Interpret and execute (Week 3)
ion build <file>           # Compile to native (Week 6)

# Phase 1 (Months 4-8)
ion check                  # Type check only
ion fmt                    # Format code
ion doc                    # Generate docs
ion add <package>          # Add dependency
ion test                   # Run tests

# Phase 2+ (Months 9+)
ion daemon start           # Start compiler daemon
ion lsp                    # Language server
ion publish                # Publish package
ion profile                # Profile execution
```

---

## Quick Reference: Example Ion Code

**hello.ion** (Week 1 target):
```ion
fn main() {
  let message = "Hello, Ion!"
  print(message)
}
```

**fibonacci.ion** (Week 3 target):
```ion
fn fib(n: int) -> int {
  if n <= 1 {
    return n
  }
  return fib(n - 1) + fib(n - 2)
}

fn main() {
  let result = fib(10)
  print(result)
}
```

**http_server.ion** (Month 16 target):
```ion
import std/http { Server }

fn main() {
  let server = Server.bind(":3000")
  
  server.get("/", fn(req) {
    return "Hello from Ion!"
  })
  
  server.listen()
}
```

---

## Benchmarking from Day 1

Create `bench/compile_time.sh`:
```bash
#!/bin/bash

echo "Ion Compile Time Benchmark"
echo "=========================="

# Ion
time ./ion build examples/benchmark.ion

echo ""
echo "Zig Compile Time Benchmark"
echo "=========================="

# Zig
time zig build-exe examples/benchmark.zig

echo ""
echo "Comparison"
echo "=========="
# Calculate and display difference
```

Run weekly and track results:
```bash
bash bench/compile_time.sh >> bench/results/week_$(date +%U).txt
```

---

## Next Immediate Actions

**Today**:
1. Create repository: `mkdir ion && cd ion && git init`
2. Create directory structure
3. Initialize `build.zig`
4. Create first test: `tests/lexer_test.zig`

**This Week**:
1. Implement Token types
2. Implement Lexer
3. Write 20+ lexer tests
4. Create example file

**This Month**:
1. Complete lexer (Week 1)
2. Complete parser (Week 2)
3. Complete interpreter (Week 3)
4. Write design doc for types/IR (Week 4)

---

## Resources & Learning

**Compilers**:
- "Crafting Interpreters" by Bob Nystrom
- "Engineering a Compiler" by Cooper & Torczon
- Zig compiler source code

**IR Design**:
- LLVM IR documentation
- Cranelift IR documentation
- QBE (lightweight backend)

**Type Systems**:
- "Types and Programming Languages" by Pierce
- Rust RFC 0401 (lifetime elision)
- TypeScript compiler source

**Borrow Checking**:
- Rust Nomicon
- Polonius (Rust borrow checker rewrite)
- "Oxide: The Essence of Rust" paper

---

## Decision Log

Track key decisions as you go:

| Date | Decision | Rationale |
|------|----------|-----------|
| 2025-10-21 | Bootstrap in Zig | Learn Zig pain points; Meta-learning |
| TBD | Syntax: fn vs func | TBD |
| TBD | Generics: <T> vs (T) | TBD |
| TBD | Modules: file-based vs explicit | TBD |

---

## Weekly Progress Template

Copy to `progress/week_XX.md`:

```markdown
# Week XX Progress (Date - Date)

## Goals
- [ ] Goal 1
- [ ] Goal 2
- [ ] Goal 3

## Completed
- [x] Thing 1
- [x] Thing 2

## Blockers
- Issue 1
- Issue 2

## Learnings
- Learning 1
- Learning 2

## Next Week
- [ ] Next goal 1
- [ ] Next goal 2

## Metrics
- Build time: Xms
- Test coverage: X%
- LOC: X
```

---

**Last Updated**: 2025-10-21  
**Status**: Active development guide
