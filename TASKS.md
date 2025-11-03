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
- [ ] Update type inference (deferred)
- [ ] Update documentation

## Phase 0.4: Numeric Literals
- [x] Add binary literal support (0b)
- [x] Add hex literal support (0x)
- [x] Add octal literal support (0o)
- [x] Add underscore support (1_000)
- [x] Add tests
- [ ] Add type suffixes (42i32) - deferred

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
- [ ] Import aliasing
- [ ] Pattern binding with @
- [ ] For loop with index (enumerate)
- [ ] Labeled break/continue
- [ ] Better error messages

## Phase 3: Advanced Features (v0.3)
- [ ] Closures with inferred move
- [ ] Trait system completion
  - [ ] Associated type bounds
  - [ ] Default trait implementations
  - [ ] Trait objects (dyn)
- [ ] Async/await completion
  - [ ] Async runtime
  - [ ] Error propagation in async
  - [ ] Async trait methods
- [ ] Compile-time evaluation
  - [ ] Comptime interpreter
  - [ ] Comptime control flow
  - [ ] Integration with type system

## Phase 4: Optimization & Tooling (v0.4)
- [ ] Language Server Protocol (LSP)
  - [ ] Auto-completion
  - [ ] Go to definition
  - [ ] Find references
  - [ ] Hover information
  - [ ] Code actions
- [ ] Formatter
  - [ ] Consistent code formatting
  - [ ] Configurable style
  - [ ] Editor integration
- [ ] Optimizations
  - [ ] Constant propagation
  - [ ] Dead code elimination
  - [ ] Inline small functions
  - [ ] Loop unrolling

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
