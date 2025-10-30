# Change Log

All notable changes to the "vscode-home" extension will be documented in this file.

## [0.1.0] - 2024-01-15

### Added
- Initial release of Home Language Support extension
- Comprehensive syntax highlighting for all Home language features
- Support for `.home` and `.hm` file extensions
- Language Server Protocol (LSP) integration
  - IntelliSense and code completion
  - Hover information
  - Go to definition
  - Find references
  - Document symbols
  - Real-time diagnostics
  - Code formatting
- 50+ code snippets for common patterns
- Smart editing features
  - Auto-closing brackets and quotes
  - Comment toggling
  - Code folding
  - Smart indentation
- Build and run integration
  - Build current file command
  - Run current file command
  - Run tests command
  - VS Code task provider
- Extension settings for customization
  - LSP enable/disable
  - Custom LSP server path
  - Format on save
  - Build on save
  - Inlay hints
  - Diagnostics control
- Status bar indicator for LSP connection
- Comprehensive documentation

### Language Features
- Keywords: 43 language keywords
- Operators: Arithmetic, logical, bitwise, and special operators
- Types: Primitives, structs, enums, unions, traits
- Functions: Regular, async, and generic functions
- Pattern matching and destructuring
- Closures and higher-order functions
- Array comprehensions
- Attributes and macros
- Error handling (try-catch-finally)
- Async/await support
- Compile-time evaluation
- Inline assembly
- Module system

### Editor Features
- Bracket matching and auto-closing
- Comment formatting (line and block)
- Word-based navigation
- Indentation rules
- Folding regions

### Commands
- `Home: Restart Language Server`
- `Home: Build Current File`
- `Home: Run Current File`
- `Home: Run Tests`
- `Home: Format Document`

### Known Issues
- Semantic highlighting is not yet implemented
- Some advanced type system features may have limited LSP support
- Debug adapter protocol (DAP) not yet implemented

---

## Future Plans

### [0.2.0] - Planned
- Semantic token highlighting
- Code actions and quick fixes
- Refactoring support (rename symbol, extract function)
- Improved error messages and diagnostics
- Code lens for tests and implementations
- Better inlay hints

### [0.3.0] - Planned
- Debug Adapter Protocol (DAP) integration
- Visual debugger with breakpoints
- Variable inspection
- Call stack navigation
- Watch expressions

### [0.4.0] - Planned
- Inline REPL/Playground
- Package manager integration
- Dependency browser
- Documentation viewer
- AI-powered code suggestions

---

Check [README.md](README.md) for detailed usage instructions.
