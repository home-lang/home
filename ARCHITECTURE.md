# Home Programming Language Architecture

This document provides a comprehensive overview of the Home programming language architecture, including the compiler pipeline, module structure, and system components.

## Table of Contents

1. [Overview](#overview)
2. [Compiler Pipeline](#compiler-pipeline)
3. [Package Structure](#package-structure)
4. [Module Dependencies](#module-dependencies)
5. [Type System](#type-system)
6. [Code Generation](#code-generation)
7. [Runtime Components](#runtime-components)
8. [Security Architecture](#security-architecture)

---

## Overview

Home is a systems programming language designed for building reliable, efficient software. It features:

- **Static typing** with Hindley-Milner type inference
- **Ownership and borrowing** for memory safety without garbage collection
- **Pattern matching** with exhaustiveness checking
- **Algebraic data types** (enums with associated data)
- **Generics** with trait bounds
- **Async/await** for concurrent programming
- **Native compilation** to x64 machine code

```
┌─────────────────────────────────────────────────────────────────┐
│                    Home Language Stack                          │
├─────────────────────────────────────────────────────────────────┤
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐        │
│  │  Lexer   │─▶│  Parser  │─▶│   AST    │─▶│  Types   │        │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘        │
│       │                                          │              │
│       ▼                                          ▼              │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐        │
│  │ Comptime │  │ Generics │  │  Traits  │  │ Codegen  │        │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘        │
│                                                  │              │
│                                                  ▼              │
│  ┌──────────────────────────────────────────────────────┐      │
│  │              Native x64 Machine Code                 │      │
│  └──────────────────────────────────────────────────────┘      │
└─────────────────────────────────────────────────────────────────┘
```

---

## Compiler Pipeline

### Phase 1: Lexical Analysis

**Package**: `packages/lexer`

The lexer converts source code into a stream of tokens.

```
Source Code ─▶ Lexer ─▶ Token Stream
                 │
                 ├─ Handles Unicode (UTF-8)
                 ├─ String interpolation
                 ├─ Numeric literals (hex, binary, octal)
                 └─ Raw strings
```

Key files:
- `lexer.zig` - Main lexer implementation
- Token types include: keywords, identifiers, operators, literals

### Phase 2: Parsing

**Package**: `packages/parser`

The parser constructs an Abstract Syntax Tree (AST) from tokens.

```
Token Stream ─▶ Parser ─▶ AST
                  │
                  ├─ Recursive descent for statements
                  ├─ Pratt parser for expressions
                  ├─ Panic-mode error recovery
                  └─ Recursion depth limiting (256 max)
```

Key components:
- `parser.zig` - Main parser with statement/expression parsing
- `trait_parser.zig` - Trait declaration parsing
- `closure_parser.zig` - Closure and lambda parsing
- `asm_parser.zig` - Inline assembly parsing
- `module_resolver.zig` - Import resolution
- `symbol_table.zig` - Symbol tracking

### Phase 3: Type Checking

**Package**: `packages/types`

Static type analysis with inference and safety checks.

```
AST ─▶ Type Checker ─▶ Typed AST
            │
            ├─ Hindley-Milner inference
            ├─ Ownership tracking
            ├─ Borrow checking
            ├─ Pattern exhaustiveness
            └─ Trait bound verification
```

Key components:
- `type_system.zig` - Core type definitions
- `type_inference.zig` - HM type inference engine
- `ownership.zig` - Ownership tracking
- `pattern_checker.zig` - Pattern matching analysis
- `generics.zig` - Generic type handling
- `trait_checker.zig` - Trait implementation verification

### Phase 4: Optimization

**Package**: `packages/optimizer`

Intermediate optimizations on the AST/IR.

```
Typed AST ─▶ Optimizer ─▶ Optimized IR
                │
                ├─ Constant folding
                ├─ Dead code elimination
                ├─ Function inlining
                ├─ Loop unrolling
                └─ Common subexpression elimination
```

### Phase 5: Code Generation

**Package**: `packages/codegen`

Native machine code generation.

```
Optimized IR ─▶ Codegen ─▶ Machine Code
                  │
                  ├─ x64 assembly generation
                  ├─ Register allocation
                  ├─ Instruction selection
                  ├─ SIMD vectorization
                  └─ ELF/Mach-O output
```

Key components:
- `native_codegen.zig` - Main x64 code generator
- `x64.zig` - x64 assembler
- `regalloc.zig` - Register allocation
- `instruction_selection.zig` - Instruction selection
- `vectorizer.zig` - SIMD auto-vectorization
- `elf.zig` / `macho.zig` - Binary format output

---

## Package Structure

```
packages/
├── Core Compiler
│   ├── lexer/          # Tokenization
│   ├── parser/         # Parsing
│   ├── ast/            # Abstract Syntax Tree
│   ├── types/          # Type system
│   ├── codegen/        # Code generation
│   ├── interpreter/    # Tree-walking interpreter
│   ├── comptime/       # Compile-time evaluation
│   ├── generics/       # Generic type system
│   ├── traits/         # Trait system
│   └── macros/         # Macro expansion
│
├── Standard Library
│   ├── collections/    # Data structures
│   ├── json/           # JSON parsing
│   ├── http/           # HTTP client/server
│   ├── database/       # Database connectivity
│   ├── async/          # Async runtime
│   ├── websocket/      # WebSocket protocol
│   ├── file/           # File I/O
│   ├── network/        # Networking primitives
│   └── math/           # Mathematical functions
│
├── Platform
│   ├── kernel/         # Kernel components
│   ├── syscall/        # System calls
│   ├── memory/         # Memory management
│   ├── threading/      # Thread primitives
│   ├── drivers/        # Device drivers
│   └── bootloader/     # Boot process
│
├── Media
│   ├── audio/          # Audio processing
│   ├── video/          # Video codecs
│   ├── image/          # Image formats
│   └── graphics/       # Graphics/OpenGL
│
├── Security
│   ├── auth/           # Authentication
│   ├── mac/            # Mandatory Access Control
│   ├── tpm/            # TPM support
│   └── modsign/        # Module signing
│
└── Tools
    ├── lsp/            # Language Server Protocol
    ├── formatter/      # Code formatting
    ├── linter/         # Static analysis
    ├── docgen/         # Documentation generator
    ├── pkg/            # Package manager
    ├── fuzz/           # Fuzzing infrastructure
    └── validation/     # Input validation
```

---

## Module Dependencies

```
                    ┌─────────┐
                    │  lexer  │
                    └────┬────┘
                         │
                    ┌────▼────┐
            ┌───────│   ast   │───────┐
            │       └────┬────┘       │
            │            │            │
       ┌────▼────┐  ┌────▼────┐  ┌────▼────┐
       │ parser  │  │ types   │  │ traits  │
       └────┬────┘  └────┬────┘  └────┬────┘
            │            │            │
            └────────────┼────────────┘
                         │
                    ┌────▼────┐
                    │ codegen │
                    └────┬────┘
                         │
                    ┌────▼────┐
                    │   x64   │
                    └─────────┘
```

---

## Type System

### Core Types

```
Type = Int | Float | Bool | String | Void
     | Array<T>
     | Map<K, V>
     | Tuple<T...>
     | Function(params) -> return
     | Struct { fields }
     | Enum { variants }
     | Generic<T: Bound>
     | Result<T, E>
     | Optional<T>
     | Reference<T>
     | MutableReference<T>
```

### Type Inference

Uses Hindley-Milner algorithm with extensions:

1. **Constraint Generation** - Walk AST, generate type equations
2. **Unification** - Solve equations to find substitution
3. **Generalization** - Create polymorphic type schemes

### Ownership Model

```
┌─────────────────────────────────────────┐
│            Ownership Rules              │
├─────────────────────────────────────────┤
│ 1. Each value has exactly one owner    │
│ 2. When owner goes out of scope,       │
│    value is dropped                    │
│ 3. References may not outlive owner    │
│ 4. Only one mutable reference OR       │
│    multiple immutable references       │
└─────────────────────────────────────────┘
```

---

## Code Generation

### x64 Calling Convention (System V AMD64 ABI)

```
Arguments:  RDI, RSI, RDX, RCX, R8, R9 (then stack)
Return:     RAX (or RAX:RDX for 128-bit)
Callee-save: RBX, RBP, R12-R15
Caller-save: RAX, RCX, RDX, RSI, RDI, R8-R11
```

### Stack Frame Layout

```
Higher addresses
    ┌─────────────────────┐
    │   Return address    │  [RBP + 8]
    ├─────────────────────┤
    │   Saved RBP         │  [RBP]
    ├─────────────────────┤
    │   Local var 1       │  [RBP - 8]
    ├─────────────────────┤
    │   Local var 2       │  [RBP - 16]
    ├─────────────────────┤
    │   ...               │
    └─────────────────────┘
Lower addresses (RSP)
```

### SIMD Vectorization

Auto-vectorization for array operations:

```
// Scalar (before)
for i in 0..n { c[i] = a[i] + b[i] }

// Vectorized (after) - 4 elements per iteration
MOVDQA xmm0, [rdi + offset]    // Load 4 from a
MOVDQA xmm1, [rsi + offset]    // Load 4 from b
PADDD  xmm0, xmm1              // Add 4 pairs
MOVDQA [rdx + offset], xmm0    // Store 4 to c
```

---

## Runtime Components

### Memory Allocation

```
┌────────────────────────────────────────┐
│              Heap Layout               │
├────────────────────────────────────────┤
│  Heap Start: 0x10000000               │
│  Heap Size:  1MB (configurable)        │
│  Strategy:   Bump allocator (simple)   │
│             + Arena allocators         │
└────────────────────────────────────────┘
```

### String Representation

```
┌─────────┬─────────┬─────────────────┐
│ Length  │ Capacity│ Data (UTF-8)    │
│ 8 bytes │ 8 bytes │ Variable        │
└─────────┴─────────┴─────────────────┘
```

---

## Security Architecture

### Input Validation

```
┌────────────────────────────────────────┐
│          Validation Limits             │
├────────────────────────────────────────┤
│ Max recursion depth:    256            │
│ Max input size:         10MB           │
│ Max tokens:             1,000,000      │
│ Max AST nodes:          500,000        │
│ Parse timeout:          30s            │
└────────────────────────────────────────┘
```

### Security Modules

- **MAC** - Mandatory Access Control
- **TPM** - Trusted Platform Module integration
- **ModSign** - Module signature verification
- **Capabilities** - Capability-based security

---

## Testing Infrastructure

### Test Types

1. **Unit Tests** - Per-module tests in `tests/` directories
2. **Integration Tests** - `tests/integration/` for multi-module tests
3. **Fuzz Tests** - `packages/fuzz/` for fuzzing
4. **Conformance Tests** - Language specification tests

### Running Tests

```bash
# All tests
zig build test

# Specific package
zig build test-parser

# With coverage (planned)
zig build test --coverage
```

---

## Build System

### Build Options

```bash
# Debugging
zig build -Ddebug-log=true -Dtrack-memory=true

# Performance
zig build -Dparallel=true -Dir-cache=true

# Safety
zig build -Dextra-safety=true

# Profiling
zig build -Dprofile=true
```

### Output Formats

- **ELF** - Linux executables
- **Mach-O** - macOS executables
- **WASM** - WebAssembly (planned)

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

### Code Style

- 4-space indentation
- Doc comments on public functions
- Error handling with explicit errors
- Tests for new functionality

### Architecture Decisions

Major changes should be discussed via:
1. GitHub Issues for proposals
2. RFC documents for significant changes
3. Code review for implementation
