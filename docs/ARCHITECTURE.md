# Home Compiler Architecture

> **Last Updated**: 2025-10-22
> **Status**: Home is at 88% completion (43/49 tasks complete)

## Overview

The Home compiler is a modern, multi-stage compiler written in Zig that compiles Home source code through several distinct phases:

```
Source Code → Lexer → Parser → Type Checker → Interpreter/Codegen
```

## Project Structure

```
home/
├── packages/           # Core compiler packages
│   ├── lexer/         # Tokenization (220+ tests)
│   ├── parser/        # AST construction (33 tests)
│   ├── ast/           # Abstract Syntax Tree definitions
│   ├── types/         # Type system and ownership (38 tests)
│   ├── interpreter/   # Bytecode interpreter
│   ├── codegen/       # Native code generation (12 tests)
│   ├── diagnostics/   # Error reporting and warnings
│   ├── modules/       # Module system and imports
│   └── patterns/      # Pattern matching
├── src/               # Main CLI application
├── examples/          # Example Home programs
├── tests/             # Integration tests
└── docs/              # Documentation

```

## Compiler Phases

### 1. Lexical Analysis (Lexer)

**Location**: `/packages/lexer/src/lexer.zig`

The lexer transforms source code into a stream of tokens. It handles:

- **Keywords**: `let`, `fn`, `struct`, `enum`, `if`, `while`, `for`, etc.
- **Literals**: Integers, floats, strings (with escape sequences), booleans, arrays
- **Operators**: Arithmetic (`+`, `-`, `*`, `/`, `%`), comparison (`==`, `!=`, `<`, `>`, `<=`, `>=`), logical (`&&`, `||`, `!`), bitwise (`&`, `|`, `^`, `<<`, `>>`), assignment (`=`)
- **Delimiters**: `()`, `{}`, `[]`, `,`, `;`, `.`, `:`, `..`, `..=`
- **Comments**: Single-line (`//`) and multi-line (`/* */`)
- **String Escapes**: `\n`, `\t`, `\r`, `\"`, `\\`, `\xNN` (hex), `\u{NNNN}` (unicode)

**Features**:
- Line and column tracking for error reporting
- Invalid character detection
- Zero-copy string slicing

**Test Coverage**: 23 tests covering all token types and edge cases

### 2. Syntax Analysis (Parser)

**Location**: `/packages/parser/src/parser.zig`

The parser constructs an Abstract Syntax Tree (AST) from the token stream using a recursive descent parsing algorithm.

**Supported Constructs**:

#### Expressions
- Literals: integers, floats, strings, booleans, arrays
- Binary operations with proper precedence
- Unary operations (`-`, `!`)
- Function calls
- Array indexing: `arr[0]`
- Array slicing: `arr[1..3]`, `arr[..5]`, `arr[2..]`, `arr[1..=5]`
- Member access: `obj.field`
- Range expressions: `0..10`, `1..=100`
- Assignment: `x = value`

#### Statements
- Variable declarations: `let x = 10;`
- Function declarations: `fn add(a: int, b: int): int { ... }`
- Struct declarations: `struct Point { x: int, y: int }`
- Enum declarations: `enum Color { Red, Green, Blue }`
- Type aliases: `type UserId = int;`
- If-else statements
- While loops: `while condition { ... }`
- For loops: `for item in items { ... }`, `for i in 0..10 { ... }`
- Return statements
- Expression statements

**Error Recovery**:
- Panic mode recovery on syntax errors
- Synchronization at statement boundaries (`;`, `}`, keywords)
- Collects multiple errors (up to 100) before stopping
- Block-level error recovery

**Recursion Safety**:
- Maximum expression nesting depth: 256 levels
- Prevents stack overflow on deeply nested expressions

**Test Coverage**: 33 parser tests covering all major constructs

### 3. Semantic Analysis (Type Checker)

**Location**: `/packages/types/src/type_system.zig`

The type checker performs type inference and validates type correctness.

**Type System**:
- **Primitive Types**: `int` (i64), `float` (f64), `bool`, `string`, `void`
- **Composite Types**: Arrays, Structs, Enums, Functions
- **Advanced Types**: Generics (`Result<T, E>`), References (`&T`, `&mut T`)
- **Type Aliases**: User-defined type names

**Type Checking Features**:
- Type inference from expressions
- Function signature verification
- Struct field type checking
- Array element homogeneity
- Binary operation type compatibility
- Member access validation
- Index expression validation
- Slice expression validation

**Compile-Time Error Detection**:
- Division by zero detection
- Type mismatches
- Undefined variables
- Invalid operations
- Overflow in numeric literals

**Ownership Tracking** (Location: `/packages/types/src/ownership.zig`):
- Move semantics for non-copy types
- Use-after-move detection
- Copy types: `int`, `float`, `bool`
- Move types: `String`, `Struct`, `Function`, `Array`

**Test Coverage**: 38 ownership tests + comprehensive type system tests

### 4. Interpretation (Interpreter)

**Location**: `/packages/interpreter/src/interpreter.zig`

The interpreter executes the type-checked AST directly.

**Memory Management**:
- **Strategy**: Arena allocator pattern
- All runtime values allocated from single arena
- Zero memory leaks by design
- Bulk deallocation when interpreter deinits
- Optimal for script execution and short-lived programs

**Value Types** (Location: `/packages/interpreter/src/value.zig`):
- Int (i64), Float (f64), Bool, String
- Array (slices of values)
- Struct (name + field map)
- Function (name + params + body)
- Void

**Execution Features**:
- Variable binding and environment management
- Function calls with parameter passing
- Control flow (if/else, while, for loops)
- Array operations (indexing, slicing)
- Struct field access
- Arithmetic, comparison, logical, and bitwise operations
- String concatenation
- Return value handling

**Runtime Error Detection**:
- Division by zero
- Array index out of bounds
- Slice bounds validation
- Type mismatches
- Undefined variables/functions

### 5. Code Generation (Codegen)

**Location**: `/packages/codegen/src/native_codegen.zig`

The code generator produces native machine code for x86-64 architecture.

**Status**: Basic implementation (185 lines)
- ELF file format generation
- x86-64 instruction encoding
- System call support (in progress)
- Function calling conventions (in progress)
- Linking (in progress)

**Test Coverage**: 12 codegen tests for basic functionality

## Diagnostic System

**Location**: `/packages/diagnostics/src/diagnostics.zig`

Comprehensive error and warning reporting system.

**Features**:
- **Severity Levels**: Error, Warning, Info, Hint
- **Source Location Tracking**: File, line, column
- **Colorized Output**: Terminal-friendly error display
- **Source Line Context**: Shows problematic code with context
- **Suggestions**: Helpful hints for fixing errors
- **JSON Output**: LSP-compatible diagnostic format

**Warning Detection** (Location: `/packages/diagnostics/src/warnings.zig`):
- Unused variable detection
- Prefix with `_` convention for intentionally unused variables
- Extensible warning framework

## Design Decisions

### Why Arena Allocator for Interpreter?

**Advantages**:
1. **Memory Safety**: Impossible to leak or double-free
2. **Performance**: Fast bump allocation, no per-value overhead
3. **Simplicity**: No complex lifetime tracking required
4. **Correctness**: Zero memory bugs by design

**Trade-offs**:
- Memory usage grows during execution
- Cannot free individual values
- Best suited for scripts and short-running programs
- Long-running REPL sessions may need periodic arena reset

**Documented in**:
- `/packages/interpreter/src/value.zig` (lines 19-36)
- `/packages/interpreter/src/interpreter.zig` (lines 18-37)

### Why Recursive Descent Parser?

**Advantages**:
1. **Simplicity**: Easy to understand and maintain
2. **Error Messages**: Clear context for syntax errors
3. **Flexibility**: Easy to add new constructs
4. **Performance**: O(n) parsing for most grammars

**Limitations**:
- Left-recursive grammars require transformation
- Deep nesting can cause stack overflow (mitigated with depth limit)

### Ownership Model

Inspired by Rust's ownership system but simplified:

1. **Copy Types**: Primitive types are copied implicitly
2. **Move Types**: Complex types transfer ownership
3. **Use-After-Move**: Compile-time error detection
4. **No Runtime Overhead**: Pure compile-time checks

## Testing Strategy

### Unit Tests
- **Lexer**: 23 tests (token recognition, escape sequences, edge cases)
- **Parser**: 33 tests (all language constructs, error recovery)
- **Type System**: 38+ tests (ownership, type inference, error detection)
- **Codegen**: 12 tests (instruction generation, ELF format)

**Total**: 244+ unit tests, all passing, zero memory leaks

### Integration Tests
- End-to-end pipeline tests
- Real-world code examples
- Located in `/tests/integrathome/`

## Performance Characteristics

### Lexer
- **Time Complexity**: O(n) where n = source length
- **Space Complexity**: O(1) - zero-copy token slicing

### Parser
- **Time Complexity**: O(n) for most cases
- **Space Complexity**: O(n) for AST storage
- **Max Nesting Depth**: 256 levels

### Type Checker
- **Time Complexity**: O(n) single-pass type inference
- **Space Complexity**: O(n) for type information

### Interpreter
- **Time Complexity**: O(n) for tree-walking interpretation
- **Space Complexity**: O(n) with arena allocator (monotonic growth)

## Error Handling Philosophy

1. **Fail Fast**: Detect errors as early as possible
2. **Clear Messages**: Explain what went wrong and why
3. **Helpful Suggestions**: Guide users to fix issues
4. **Multiple Errors**: Don't stop at first error (up to 100)
5. **Source Context**: Show problematic code with line numbers

## Future Work

See [TODO.md](../TODO.md) for detailed roadmap.

**High Priority**:
- Integration test debugging (arena allocator issue)
- String interpolation
- Pattern matching integration
- Import system integration
- Native codegen completion

**Medium Priority**:
- String interning for memory optimization
- Long-running REPL support
- Incremental compilation

**Low Priority**:
- LSP server implementation
- Standard library expansion
- Parallel compilation

## Contributing

When adding new features:

1. **Add Tests First**: Write failing tests, then implement
2. **Update Documentation**: Keep architecture docs current
3. **Run Full Test Suite**: `zig build test`
4. **Check Memory**: Ensure zero leaks with arena allocator
5. **Update TODO.md**: Track progress on roadmap

## References

- [Home Language Specification](./LANGUAGE.md) (TODO)
- [TODO Roadmap](../TODO.md)
- [Configuration Guide](./CONFIGURATION.md)
- [Examples](../examples/)
