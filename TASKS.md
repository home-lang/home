# Implementation Tasks

## Phase 0.1: Semicolon Rules
- [x] Add isAtNewLine() to parser
- [x] Add optionalSemicolon() to parser
- [x] Create semicolon_style linter rule
- [x] Create semicolon tests
- [x] Wire optionalSemicolon() into letDeclaration
- [x] Wire optionalSemicolon() into returnStatement
- [x] Wire optionalSemicolon() into expressionStatement
- [x] Fix failing test (parser_test.zig line 280)
- [x] Wire into other statement types (deferStatement done, others don't need it)
- [x] Update checkSemicolons() in linter
- [x] Test and verify

## Phase 0.2: String Interpolation
- [x] Fixed config package (prerequisite)
- [x] Add interpolation detection in lexer string()
- [x] Create StringInterpolation token types
- [x] Parse interpolated string expressions
- [x] Generate string concatenation code (interpreter)
- [x] Add tests
- [ ] Document syntax

## Phase 0.3: Type System
- [x] Define default types (int=i64, float=f64)
- [x] Add all integer types (i8, i16, i32, i64, i128, u8, u16, u32, u64, u128)
- [x] Add float types (f32, f64)
- [x] Add resolveDefault() helper function
- [x] Update equals() for new types
- [x] Update format() for new types
- [x] Add tests
- [x] Update type inference
  - [x] Add TypeVar variant to Type union
  - [x] Implement Hindley-Milner style type inference
  - [x] Type variable generation and fresh variables
  - [x] Constraint collection for expressions
  - [x] Unification algorithm with occurs check
  - [x] Substitution and type resolution
  - [x] Let-polymorphism (generalization/instantiation)
  - [x] Bidirectional type checking infrastructure
  - [x] Inference for literals, binary ops, arrays, tuples
  - [x] Inference for closures and function calls
  - [x] Comprehensive test suite (12 tests)
- [ ] Update documentation

## Phase 0.4: Numeric Literals
- [x] Add binary literal support (0b)
- [x] Add hex literal support (0x)
- [x] Add octal literal support (0o)
- [x] Add underscore support (1_000)
- [x] Add tests
- [x] Add type suffixes (42i32)
  - [x] Lexer support for type suffix detection
  - [x] AST IntegerLiteral/FloatLiteral with type_suffix field
  - [x] Parser support for extracting type suffixes
  - [x] Interpreter bounds checking for typed literals
  - [x] Tests for type suffixes

## Phase 0.5: Raw Strings
- [x] Implement r"string" syntax
- [x] Implement r#"string"# syntax
- [x] Add tests

## Phase 1: Core Language
- [x] Module system with pub keyword
- [x] Collection literals
- [x] Documentation comments (/// syntax defined, full implementation deferred)
- [x] Type conversions (as operator)
- [x] Attributes system

## Phase 2: Ergonomics & Developer Experience (v0.2)
- [x] Import aliasing (import path/to/module as Alias)
  - [x] AST support (ImportDecl.alias)
  - [x] Parser support
  - [x] Symbol table integration
- [x] Pattern binding with @ (pattern @ identifier)
  - [x] AST support (Pattern.As)
  - [x] Parser support in match expressions
- [x] For loop with index (for i, item in items)
  - [x] AST support (ForStmt.index)
  - [x] Parser support for enumerate syntax
  - [x] Interpreter support
- [x] Labeled break/continue (break 'label, continue 'label)
  - [x] AST nodes (BreakStmt, ContinueStmt)
  - [x] Lexer support (Break, Continue tokens)
  - [x] Parser support with label parsing
  - [x] Interpreter support with control flow
- [x] Better error messages
  - [x] Rich diagnostics with colored output (Rust-style)
  - [x] Primary and secondary labels for context
  - [x] Error codes with systematic naming (T0xxx, V0xxx, etc.)
  - [x] DiagnosticBuilder with fluent API
  - [x] CommonDiagnostics with 11 pre-built error types
    - [x] Type mismatch (T0001)
    - [x] Undefined variable (V0001)
    - [x] Cannot mutate (M0001)
    - [x] Argument count mismatch (F0001)
    - [x] Missing return (R0001)
    - [x] Non-exhaustive match (P0001)
    - [x] Division by zero (A0001)
    - [x] Index out of bounds (A0002)
    - [x] Unreachable code (W0001)
    - [x] Unused variable (W0002)
    - [x] Cannot infer type (T0002)
  - [x] Error recovery strategies
    - [x] Recovery modes (Minimal, Moderate, Aggressive)
    - [x] Synchronization to statement/expression/declaration boundaries
    - [x] Panic mode recovery
    - [x] Phrase-level recovery for common typos
  - [x] Error suggestions
    - [x] Fuzzy name matching with Levenshtein distance
    - [x] Keyword completion suggestions
    - [x] Closing delimiter suggestions
    - [x] Minimal edit suggestions (Insert, Delete, Replace)
  - [x] Comprehensive test suite (17 tests)
  - [x] Complete documentation (ERROR_MESSAGES.md)

## Phase 3: Advanced Features (v0.3)
- [x] Closures with inferred move
  - [x] Closure expressions with |params| syntax
  - [x] Move semantics support
  - [x] Capture analysis
- [x] Trait system completion
  - [x] Associated type bounds
  - [x] Default trait implementations
  - [x] Trait objects with VTable dispatch
  - [x] Operator traits
- [x] Async/await completion
  - [x] Async runtime with Future/Poll
  - [x] Task executor
  - [x] Waker system
- [x] Compile-time evaluation
  - [x] Comptime interpreter
  - [x] Comptime control flow
  - [x] Integration with type system
  - [x] Reflection support

## Phase 4: Optimization & Tooling (v0.4)
- [x] Language Server Protocol (LSP)
  - [x] Auto-completion
  - [x] Go to definition
  - [x] Find references
  - [x] Hover information
  - [x] Code actions
  - [x] Document symbols
  - [x] Semantic tokens
  - [x] Rename support
- [x] Formatter
  - [x] Consistent code formatting
  - [x] Configurable style (indent, quotes, braces, semicolons)
  - [x] AST-based formatting
- [x] Optimizations
  - [x] Constant propagation
  - [x] Dead code elimination
  - [x] Function inlining
  - [x] Loop optimization
  - [x] Instruction scheduling
  - [x] Register allocation
  - [x] Vectorization

## Phase 5: Stabilization (v1.0)
- [ ] Comprehensive testing
- [ ] Documentation
- [ ] Performance benchmarks
- [ ] Security audit
- [ ] Ecosystem

## Web Framework (Priority)
- [x] HTTP methods and status codes
- [x] HTTP headers module
- [x] HTTP request struct
- [x] HTTP response struct
- [x] Router with pattern matching
- [x] Middleware system (Laravel-inspired)
- [x] HTTP server implementation
- [x] PostgreSQL driver (with connection pooling)
- [x] Query Builder (fluent SQL API)
- [x] Basic ORM (Eloquent-inspired with relationships)
- [x] Testing framework (comprehensive with coverage)
