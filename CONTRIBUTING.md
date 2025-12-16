# Contributing to Home Programming Language

Thank you for your interest in contributing to Home! This document provides guidelines and information for contributors.

## Table of Contents

1. [Getting Started](#getting-started)
2. [Development Setup](#development-setup)
3. [Code Style Guide](#code-style-guide)
4. [Testing Guidelines](#testing-guidelines)
5. [Pull Request Process](#pull-request-process)
6. [Architecture Overview](#architecture-overview)

---

## Getting Started

### Prerequisites

- **Zig**: Version 0.11.0 or later
- **Git**: For version control
- **A text editor**: VS Code with Zig extension recommended

### Building from Source

```bash
# Clone the repository
git clone https://github.com/home-lang/home.git
cd home

# Build the compiler
zig build

# Run tests
zig build test

# Run with debug logging
zig build -Ddebug-log=true
```

---

## Development Setup

### Project Structure

```
home/
├── src/               # Main compiler source
├── packages/          # Modular packages
│   ├── lexer/         # Tokenization
│   ├── parser/        # Parsing
│   ├── ast/           # Abstract Syntax Tree
│   ├── types/         # Type system
│   ├── codegen/       # Code generation
│   └── ...            # Other packages
├── tests/             # Integration tests
├── examples/          # Example programs
└── docs/              # Documentation
```

### Build Options

```bash
# Debugging options
-Ddebug-log=true        # Enable verbose logging
-Dtrack-memory=true     # Track allocations

# Performance options
-Dparallel=true         # Parallel compilation
-Dir-cache=true         # IR caching

# Safety options
-Dextra-safety=true     # Additional runtime checks
-Dsanitize-address=true # AddressSanitizer

# Profiling
-Dprofile=true          # Profiling instrumentation
-Dcoverage=true         # Code coverage
```

---

## Code Style Guide

### General Principles

1. **Clarity over cleverness**: Write readable code
2. **Consistency**: Follow existing patterns
3. **Documentation**: Document public APIs
4. **Testing**: Write tests for new features

### Naming Conventions

```zig
// Types: PascalCase
const MyStruct = struct { ... };
const ErrorType = error{ ... };

// Functions: camelCase
fn processData() void { ... }
pub fn parseExpression() !*Expr { ... }

// Variables: snake_case
var item_count: usize = 0;
const max_size: usize = 1024;

// Constants: SCREAMING_SNAKE_CASE for compile-time
const MAX_BUFFER_SIZE: usize = 4096;
```

### Formatting

- **Indentation**: 4 spaces (no tabs)
- **Line length**: 120 characters max
- **Braces**: Same line for functions

```zig
// Good
fn add(x: i32, y: i32) i32 {
    return x + y;
}

// Avoid
fn add(x: i32, y: i32) i32
{
    return x + y;
}
```

### Documentation Comments

```zig
/// Brief description of the function.
///
/// Detailed explanation if needed.
///
/// Parameters:
///   - x: First operand
///   - y: Second operand
///
/// Returns: Sum of x and y
///
/// Example:
/// ```zig
/// const result = add(2, 3);
/// ```
pub fn add(x: i32, y: i32) i32 {
    return x + y;
}
```

### Error Handling

```zig
// Use explicit error types
const ParseError = error{
    UnexpectedToken,
    InvalidSyntax,
    OutOfMemory,
};

// Return errors, don't panic
fn parse() ParseError!*Ast {
    if (invalid) return error.InvalidSyntax;
    return ast;
}

// Use errdefer for cleanup
fn allocateAndParse() !*Ast {
    const mem = try allocator.alloc(u8, size);
    errdefer allocator.free(mem);
    return try parse(mem);
}
```

---

## Testing Guidelines

### Test Structure

```zig
test "module - specific behavior" {
    // Arrange
    const input = "test input";
    
    // Act
    const result = parse(input);
    
    // Assert
    try testing.expectEqual(expected, result);
}
```

### Test Categories

1. **Unit tests**: Test individual functions
2. **Integration tests**: Test module interactions
3. **Fuzz tests**: Test with random inputs (see `packages/fuzz`)
4. **Regression tests**: Tests for fixed bugs

### Running Tests

```bash
# All tests
zig build test

# Specific package
zig build test-parser

# With verbose output
zig build test -- --verbose

# Filter tests
zig build test -- --test-filter="lexer"
```

---

## Pull Request Process

### Before Submitting

1. **Create an issue** for significant changes
2. **Fork the repository**
3. **Create a feature branch**: `git checkout -b feature/my-feature`
4. **Write tests** for new functionality
5. **Update documentation** if needed
6. **Run all tests**: `zig build test`
7. **Format code**: Follow style guide

### PR Checklist

- [ ] Tests pass locally
- [ ] Code follows style guide
- [ ] Documentation updated
- [ ] Commit messages are clear
- [ ] No merge conflicts
- [ ] Changes are focused (one feature per PR)

### Commit Message Format

```
type(scope): short description

Longer description if needed.

Fixes #123
```

Types:
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation
- `style`: Formatting
- `refactor`: Code restructuring
- `test`: Adding tests
- `chore`: Maintenance

### Review Process

1. Submit PR with clear description
2. Address review comments
3. Maintain one commit per logical change
4. Squash before merge if requested

---

## Architecture Overview

### Compiler Pipeline

```
Source → Lexer → Parser → AST → Type Checker → Codegen → Binary
```

### Key Modules

| Module | Purpose |
|--------|---------|
| `lexer` | Tokenization |
| `parser` | AST construction |
| `types` | Type checking & inference |
| `codegen` | x64 code generation |
| `optimizer` | IR optimization passes |

See [ARCHITECTURE.md](ARCHITECTURE.md) for detailed documentation.

---

## Questions?

- Open a GitHub issue for questions
- Check existing issues/PRs before submitting
- Join discussions in existing issues

Thank you for contributing!
