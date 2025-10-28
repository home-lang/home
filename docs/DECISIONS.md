# Home Technical Decisions

Track architectural and design decisions to maintain consistency and provide historical context.

**Format**: Each decision includes context, options considered, chosen approach, and rationale.

---

## Language Design

### D001: Borrow Annotations - Implicit vs Explicit
**Status**: ✅ **Decided**: Hybrid (Option C)  
**Priority**: HIGH  
**Decided**: 2025-10-21

**Context**:
Home aims for "safety without ceremony." Need to decide how much borrowing syntax users must write.

**Options**:

**A) Fully Explicit (Rust-style)**:
```home
fn process(data: &string) -> usize {  // & required
  return data.len()
}

fn modify(data: &mut string) {  // &mut required
  data.push("!")
}
```
*Pros*: Clear intent, familiar to Rust devs  
*Cons*: Verbose, ceremony

**B) Fully Implicit (Inferred)**:
```home
fn process(data: string) -> usize {  // compiler infers &string
  return data.len()
}

fn modify(data: mut string) {  // compiler infers &mut string
  data.push("!")
}
```
*Pros*: Clean syntax, less ceremony  
*Cons*: Less obvious, harder to reason about ownership

**C) Hybrid (Default implicit, explicit override)**:
```home
// Implicit by default
fn process(data: string) {  // inferred: &string
  print(data)
}

// Explicit when taking ownership
fn consume(data: own string) {  // explicit ownership
  // data is moved
}

// Explicit mutable borrow
fn modify(data: mut string) {  // inferred: &mut string
  data.push("!")
}
```
*Pros*: Best of both worlds  
*Cons*: Need to learn inference rules

**Chosen**: **Option C (Hybrid)**  

**Rationale**: Reduces ceremony for common cases while allowing explicit control. Most functions don't need ownership, so default to borrowing.

**Implementation**:
- Compiler infers `&T` when function doesn't move
- `own T` keyword for explicit ownership transfer
- `mut` implies `&mut T` for parameters
- Escape analysis determines stack vs heap

---

### D002: Generic Syntax
**Status**: ✅ **Decided**: Parentheses (Option B)  
**Priority**: HIGH  
**Decided**: 2025-10-21

**Context**:
Need consistent syntax for generic types that's familiar but distinct.

**Options**:

**A) Angle Brackets (Rust/TypeScript/C++)**:
```home
fn identity<T>(value: T) -> T { value }
let list: Vec<int> = Vec.new()
let map: Map<string, User> = Map.new()
```
*Pros*: Familiar to most developers  
*Cons*: Parsing complexity (>> vs >), visual noise

**B) Parentheses (Zig-style)**:
```home
fn identity(comptime T: type)(value: T) -> T { value }
let list: Vec(int) = Vec.new()
let map: Map(string, User) = Map.new()
```
*Pros*: Easier parsing, consistent with function calls  
*Cons*: Less familiar, function syntax verbose

**C) Square Brackets**:
```home
fn identity[T](value: T) -> T { value }
let list: Vec[int] = Vec.new()
let map: Map[string, User] = Map.new()
```
*Pros*: Easy parsing, distinct from expressions  
*Cons*: Conflicts with array syntax

**D) Hybrid (Square for types, parens for bounds)**:
```home
fn identity[T](value: T) -> T { value }
fn bounded[T: Trait](value: T) -> T { value }
let list: Vec[int] = Vec.new()
```
*Pros*: Clear separation, no parsing ambiguity  
*Cons*: Two syntaxes to learn

**Chosen**: **Option B (Parentheses)**  

**Rationale**: Easier parsing, no `>>` issues, consistent with function calls. Zig-style syntax familiar to systems programmers.

**Implementation**:
```home
fn identity(comptime T: type)(value: T) -> T { value }
let list: Vec(int) = Vec.new()
let map: Map(string, User) = Map.new()
```

---

### D003: Error Handling - Result Type Signature
**Status**: ✅ **Decided**: Default Error Type (Option B)  
**Priority**: MEDIUM  
**Decided**: 2025-10-21

**Context**:
Need to decide Result type API and default error type.

**Options**:

**A) Explicit Error Type (Rust-style)**:
```home
fn read_file(path: string) -> Result<string, IOError> {
  // ...
}
```
*Pros*: Type-safe, explicit  
*Cons*: Verbose for simple cases

**B) Default Error Type**:
```home
fn read_file(path: string) -> Result<string> {  // Error type implicit
  // returns Result<string, Error>
}
```
*Pros*: Cleaner for common case  
*Cons*: Less type safety, hidden type

**C) Multiple Return Values (Go-style)**:
```home
fn read_file(path: string) -> (string, error) {
  // ...
}
```
*Pros*: Simple, familiar to Go devs  
*Cons*: No `?` operator, must check manually

**Chosen**: **Option B (Default with override)**  

**Rationale**: Reduce ceremony for typical errors while allowing specificity when needed. Global `Error` trait that custom errors implement.

**Implementation**:
```home
// Default error type
fn read_file(path: string) -> Result(string) { }

// Explicit when needed
fn parse(input: string) -> Result(Config, ParseError) { }
```

---

### D004: Module System - File-based vs Explicit
**Status**: ✅ **Decided**: Hybrid (Option C)  
**Priority**: HIGH  
**Decided**: 2025-10-21

**Context**:
How do modules map to files and how are they imported?

**Options**:

**A) File-based (Rust/TypeScript)**:
```
src/
  main.home
  parser/
    mod.home      # or parser.home
    lexer.home
```
```home
import parser/lexer { Lexer, Token }
```
*Pros*: Simple, predictable  
*Cons*: File structure dictates API

**B) Explicit Modules**:
```home
// lexer.home
module parser.lexer

export struct Lexer { }
```
```home
// main.home
import parser.lexer { Lexer }
```
*Pros*: Flexible, decoupled from filesystem  
*Cons*: More ceremony, can be confusing

**C) Hybrid (File-based with re-exports)**:
```
src/
  main.home
  parser.home   # Re-exports lexer + parser
  parser/
    lexer.home
    parser.home
```
```home
// parser.home
export * from parser/lexer
export * from parser/parser

// main.home
import parser { Lexer, Parser }
```
*Pros*: Control over public API, familiar  
*Cons*: Need to maintain re-exports

**Chosen**: **Option C (Hybrid)**  

**Rationale**: File-based for simplicity with explicit exports for API control. Matches TypeScript/Rust patterns.

**Implementation**:
```home
// parser.home - controls public API
export * from parser/lexer
export * from parser/parser

// main.home
import parser { Lexer, Parser }
```

---

### D005: String Type - UTF-8 or Byte Slice
**Status**: ✅ **Decided**: UTF-8 with Unsafe Escape (Option D)  
**Priority**: HIGH  
**Decided**: 2025-10-21

**Context**:
Balance between safety, performance, and ergonomics.

**Options**:

**A) UTF-8 Validated**:
```home
let s: string = "Hello"  // Always valid UTF-8
// Invalid UTF-8 rejected at compile time or runtime
```
*Pros*: Safe, prevents encoding bugs  
*Cons*: Performance overhead, validation cost

**B) Byte Slice**:
```home
let s: string = "Hello"  // Just []u8
// No validation, raw bytes
```
*Pros*: Zero-cost, maximum performance  
*Cons*: Unsafe, can have invalid UTF-8

**C) Two Types (Swift/Rust-style)**:
```home
let s: String = "Hello"  // UTF-8 validated, heap allocated
let b: &str = "Hello"    // UTF-8 slice, borrowed
```
*Pros*: Flexibility, performance when needed  
*Cons*: Complexity, two types to learn

**D) UTF-8 with unsafe escape**:
```home
let s: string = "Hello"  // Validated by default
let raw = unsafe { string.from_bytes(bytes) }  // Skip validation
```
*Pros*: Safe by default, fast path available  
*Cons*: Unsafe blocks for performance

**Chosen**: **Option D (UTF-8 + unsafe)**  

**Rationale**: Default to safety and correctness. Provide unsafe path for performance-critical code. Most code doesn't need raw bytes.

**Implementation**:
```home
let s: string = "Hello"  // UTF-8 validated
let raw = unsafe { string.from_bytes(bytes) }  // Skip validation
```

---

### D006: Integer Overflow Behavior
**Status**: ✅ **Decided**: Debug Panic + Explicit (Option A+D)  
**Priority**: MEDIUM  
**Decided**: 2025-10-21

**Context**:
What happens when integer arithmetic overflows?

**Options**:

**A) Panic in Debug, Wrap in Release (Rust)**:
```home
let x: u8 = 255
let y = x + 1  // Panics in debug, wraps to 0 in release
```

**B) Always Panic**:
```home
let x: u8 = 255
let y = x + 1  // Always panics
```

**C) Always Wrap**:
```home
let x: u8 = 255
let y = x + 1  // Always wraps to 0
```

**D) Explicit Methods**:
```home
let y = x.wrapping_add(1)  // Explicit wrapping
let y = x.saturating_add(1)  // Saturates at max
let y = x.checked_add(1)  // Returns Result
```

**Chosen**: **Option A + D (Debug panic, release wrap, explicit methods)**  

**Rationale**: Catch bugs in development while maintaining performance in production. Provide explicit methods for different semantics.

**Implementation**:
```home
let y = x + 1              // Panic in debug, wrap in release
let y = x.wrapping_add(1)  // Explicit wrapping
let y = x.saturating_add(1) // Saturating
let y = x.checked_add(1)?  // Returns Result
```

---

## Compiler Architecture

### D007: IR Format - SSA or Register-based
**Status**: ✅ **Decided**: SSA  
**Priority**: HIGH  
**Decided**: 2025-10-21

**Chosen**: SSA (Static Single Assignment)

**Rationale**:
- Easier optimization (def-use chains)
- Better for incremental compilation
- Cranelift expects SSA
- Standard in modern compilers

**Implementation**:
```
%0 = load @var_x
%1 = load @var_y
%2 = add i32 %0, %1
ret %2
```

---

### D008: Backend - Cranelift vs LLVM vs Custom
**Status**: ✅ **Decided**: Cranelift primary, LLVM optional  
**Priority**: HIGH  
**Decided**: 2025-10-21

**Chosen**: Cranelift for development builds, optional LLVM for release

**Rationale**:
- Cranelift compiles faster (critical for DX)
- LLVM optimizes better (important for production)
- Backend abstraction allows both
- Match Rust's approach

**Implementation Plan**:
```
ion build         # Uses Cranelift (fast)
ion build --opt   # Uses LLVM (slow but optimized)
```

---

### D009: Cache Storage - Filesystem vs Database
**Status**: ✅ **Decided**: Filesystem (content-addressable)  
**Priority**: MEDIUM  
**Decided**: 2025-10-21

**Chosen**: Content-addressable filesystem cache

**Rationale**:
- Simple, no external dependencies
- Easy to inspect/debug
- Git-like model (familiar)
- Fast enough for typical projects

**Structure**:
```
.home/cache/
  ir/
    ab/cd/abcdef123...  # IR files by hash
  obj/
    12/34/123456...     # Object files
  meta/
    modules.db          # SQLite for metadata
```

---

### D010: Borrow Checker Algorithm
**Status**: ✅ **Decided**: Hybrid (Option D)  
**Priority**: HIGH  
**Decided**: 2025-10-21

**Context**:
Which algorithm to use for borrow checking?

**Options**:

**A) NLL (Non-Lexical Lifetimes) - Rust 2018**:
- Flow-sensitive analysis
- Precise but complex

**B) Polonius - Next-gen Rust**:
- Datalog-based
- More precise than NLL
- Still experimental

**C) Conservative - Simple Scopes**:
- Lexical scopes only
- Simple but restrictive
- Fast to implement

**D) Hybrid - Conservative with NLL hints**:
- Start conservative
- Add NLL for common patterns
- Progressive enhancement

**Chosen**: **Option D (Hybrid)**  

**Rationale**: Ship conservative checker quickly (Month 5), iterate to NLL precision (Month 8). Avoid premature complexity.

**Implementation Plan**:
- **Phase 1 (Month 5)**: Conservative lexical scopes
- **Phase 2 (Month 8)**: Add NLL for common patterns
- **Phase 3 (Month 12)**: Full NLL precision

---

## Tooling

### D011: LSP - Standalone vs Embedded
**Status**: ✅ **Decided**: Both (Option C)  
**Priority**: MEDIUM  
**Decided**: 2025-10-21

**Options**:

**A) Standalone Process**:
```bash
ion lsp    # Separate server process
```
*Pros*: Standard LSP, works with all editors  
*Cons*: Extra process, startup time

**B) Embedded in Daemon**:
```bash
ion daemon start  # Includes LSP
```
*Pros*: Shared cache, zero startup  
*Cons*: Tightly coupled

**C) Both**:
```bash
ion lsp          # Quick standalone
ion daemon lsp   # Via daemon
```
*Pros*: Flexibility  
*Cons*: Maintenance burden

**Chosen**: **Option C (Both)**  

**Rationale**: Maximum flexibility for different editor setups. Daemon provides shared cache, standalone for simplicity.

**Implementation**:
```bash
ion lsp          # Standalone process
ion daemon lsp   # Via daemon (shared cache)
```

---

## Standard Library

### D012: Async Runtime - Bundled vs Optional
**Status**: ✅ **Decided**: Implicit Tree-Shakeable (Option C)  
**Priority**: HIGH  
**Decided**: 2025-10-21

**Options**:

**A) Bundled (Go/JavaScript)**:
```home
// Runtime always available
async fn handler() { }
```
*Pros*: Zero setup, consistent  
*Cons*: Binary size, not needed for all programs

**B) Optional (Rust)**:
```home
import std/runtime { Runtime }

fn main() {
  let rt = Runtime.new()
  rt.block_on(async_main())
}
```
*Pros*: Minimal binaries when not needed  
*Cons*: Setup boilerplate

**C) Implicit but Tree-Shakeable**:
```home
// Runtime linked only if async used
async fn handler() { }  // Pulls in runtime automatically
```
*Pros*: Zero boilerplate, minimal when unused  
*Cons*: Magic linking

**Chosen**: **Option C (Implicit + tree-shakeable)**  

**Rationale**: Best DX. Linker can eliminate runtime if no async functions. Compiler warns if runtime size is large.

**Implementation**:
```home
// Runtime auto-linked only if async used
async fn handler() { }  // Pulls in runtime
fn main() { }           // No async = no runtime overhead
```

---

### D013: Collections - Interface-based vs Concrete
**Status**: ✅ **Decided**: Hybrid (Option C)  
**Priority**: MEDIUM  
**Decided**: 2025-10-21

**Options**:

**A) Concrete Types (Zig/Go)**:
```home
let v: Vec<int> = Vec.new()
let m: Map<string, int> = Map.new()
```

**B) Interface-based (Java)**:
```home
let v: List<int> = Vec.new()
let m: Dict<string, int> = HashMap.new()
```

**C) Hybrid (Rust)**:
```home
// Concrete by default
let v: Vec<int> = Vec.new()

// Trait when needed
fn process(items: impl Iterator<int>) { }
```

**Chosen**: **Option C (Hybrid)**  

**Rationale**: Concrete for simplicity, traits for abstraction. Most code doesn't need interface indirection.

**Implementation**:
```home
// Concrete by default
let v: Vec(int) = Vec.new()

// Traits when needed
fn process(items: impl Iterator(int)) { }
```

---

## Open Questions

Questions that need research before deciding:

### Q001: Can we achieve zero-cost async?
**Research Needed**:
- Measure overhead vs hand-rolled state machines
- Compare with Rust's async
- Profile typical async workloads

### Q002: How to handle C interop with borrow checker?
**Research Needed**:
- Study Rust's FFI model
- Consider automatic `unsafe` boundaries
- Test with real C libraries

### Q003: WASM target performance expectations?
**Research Needed**:
- Benchmark Cranelift WASM output
- Compare with Rust/C WASM
- Identify optimization opportunities

### Q004: Can comptime replace macros entirely?
**Research Needed**:
- List all macro use cases (Rust, C++)
- Prototype in comptime
- Identify gaps

---

## Decision Process

**How to make decisions**:

1. **Research**: Gather data, build prototypes, study prior art
2. **Document**: Write options in this file with pros/cons
3. **Discuss**: Get feedback (Discord, GitHub issues)
4. **Prototype**: Build smallest test to validate
5. **Decide**: Choose based on goals (speed, safety, DX)
6. **Ship**: Implement and iterate
7. **Review**: Revisit if problems emerge

**Decision Criteria Priority**:
1. Compile time performance (beat Zig)
2. Runtime performance (match Zig)
3. Developer experience (beat Rust)
4. Safety (beat C/Zig, approach Rust)
5. Simplicity (implementation and mental model)

---

## Versioning Strategy

**How decisions evolve**:

- **Phase 0-1** (Months 1-8): High flexibility, iterate rapidly
- **Phase 2-3** (Months 9-14): Stabilizing, breaking changes allowed with notice
- **Phase 4-5** (Months 15-20): Limited breaking changes
- **Phase 6** (Months 21-24): No breaking changes, 1.0 prep

**After 1.0**:
- Breaking changes only in major versions
- Deprecation warnings for 2+ minor versions
- Edition system (like Rust) if needed

---

**Last Updated**: 2025-10-21  
**Next Review**: When starting each phase  
**Decision Template**: See D001 format above
