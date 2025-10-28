# Home Monorepo Structure

## Overview

Home now features a Bun/pnpm-style monorepo structure with independent packages that can be developed, tested, and versioned separately while being managed together.

## Directory Structure

```
home/
├── ion.toml                    # Root workspace configuration (or ion.json)
├── packages/                   # All Home packages (22 total)
│   ├── lexer/                 # Tokenization and scanning
│   ├── parser/                # Syntax analysis and AST generation
│   ├── ast/                   # Abstract syntax tree definitions
│   ├── types/                 # Type system with ownership
│   ├── interpreter/           # Runtime execution engine
│   ├── codegen/               # Native code generation
│   ├── diagnostics/           # Error reporting and diagnostics
│   ├── formatter/             # Code formatting
│   ├── async/                 # Async runtime and concurrency
│   ├── build/                 # Build system (parallel, watch mode)
│   ├── cache/                 # IR caching
│   ├── comptime/              # Compile-time execution
│   ├── generics/              # Generic types and functions
│   ├── lsp/                   # Language Server Protocol
│   ├── macros/                # Macro system
│   ├── modules/               # Module resolution
│   ├── patterns/              # Pattern matching
│   ├── safety/                # Unsafe blocks and safety
│   ├── tools/                 # Developer tools (doc gen, etc.)
│   ├── traits/                # Trait system
│   ├── basics/                # Standard library (HTTP, crypto, fs, etc.)
│   └── pkg/                   # Package manager
├── src/                       # Main Home CLI and compiler
│   ├── main.zig              # CLI entry point
│   └── ion.zig               # Root library module
├── tests/                     # Integration tests
├── bench/                     # Benchmarks
└── examples/                  # Example projects
```

## Root Workspace Configuration

The root `ion.toml` defines the workspace:

```toml
[package]
name = "ion"
version = "0.1.0"
authors = ["Home Contributors"]

[workspaces]
packages = [
  "packages/*"
]

[scripts]
build = "zig build"
test = "zig build test"
bench = "zig build bench"
format = "find src packages -name '*.zig' -exec zig fmt {} +"
run = "zig build run"
dev = "zig build run -- run examples/hello.home"
```

## Package Structure

Each package has its own `ion.toml` with:

### Example: Lexer Package

```toml
[package]
name = "home-lexer"
version = "0.1.0"
authors = ["Home Contributors"]
description = "Home Language Lexer - Tokenization and scanning"
license = "MIT"

[dependencies]
# No external dependencies

[scripts]
test = "zig test src/lexer.zig"
```

### Example: Parser Package (with dependencies)

```toml
[package]
name = "home-parser"
version = "0.1.0"
authors = ["Home Contributors"]
description = "Home Language Parser - AST generation from tokens"
license = "MIT"

[dependencies]
home-lexer = { path = "../lexer" }
home-ast = { path = "../ast" }

[scripts]
test = "zig test src/parser.zig"
```

## Package Dependencies

The package dependency graph:

```
home-lexer (no deps)
    ↓
home-ast (no deps)
    ↓
home-parser → home-lexer, home-ast
    ↓
home-types → home-ast
    ↓
home-interpreter → home-ast
    ↓
home-codegen → home-ast
    ↓
home-diagnostics (no deps)
home-formatter → home-ast
home-basics → home-ast, home-types
home-pkg (no deps)
```

## Benefits of This Structure

### 1. **Clear Separation of Concerns**
Each package has a single, well-defined responsibility:
- `lexer`: Tokenization only
- `parser`: Syntax analysis only
- `ast`: Abstract syntax tree definitions
- `types`: Type checking and inference
- etc.

### 2. **Independent Development**
- Each package can be developed independently
- Run tests for a single package: `cd packages/lexer && zig test src/lexer.zig`
- Packages can have their own versioning

### 3. **Reusability**
- Packages can be used independently
- Other projects can depend on just the lexer, parser, etc.
- Easier to create tools that use parts of Home

### 4. **Better Testing**
- Unit tests stay within each package
- Integration tests in root `tests/` directory
- Faster feedback loop when testing specific components

### 5. **Workspace Features**
Home's package manager supports workspace operations:
```bash
# Discover all packages in workspace
ion pkg tree

# Run scripts across workspace
ion pkg run test  # Runs tests for all packages

# List all available scripts
ion pkg scripts
```

## Working with Packages

### Adding a New Package

1. Create directory: `mkdir -p packages/my-package/src`
2. Create `packages/my-package/ion.toml`:
   ```toml
   [package]
   name = "home-my-package"
   version = "0.1.0"
   authors = ["Your Name"]
   description = "Description"
   license = "MIT"

   [dependencies]
   # Add dependencies here

   [scripts]
   test = "zig test src/main.zig"
   ```
3. Add your code to `packages/my-package/src/`
4. The workspace will automatically discover it

### Running Package Scripts

From the root:
```bash
# Run a script across all packages
ion pkg run test

# List all scripts
ion pkg scripts
```

From within a package:
```bash
cd packages/lexer
zig test src/lexer.zig
```

### Managing Dependencies

Packages can depend on each other using path dependencies:

```toml
[dependencies]
home-lexer = { path = "../lexer" }
home-ast = { path = "../ast" }
```

Or depend on external packages:
```toml
[dependencies]
some-lib = "1.0.0"              # Registry
user/repo = { git = "..." }     # GitHub
```

## Current Status

✅ **Completed:**
- Created packages/ directory structure
- Moved all code to individual packages
- Created ion.toml for each package
- Defined package dependencies
- Root workspace configuration
- All builds and tests passing

🚧 **Future Work:**
- Migrate build system to fully use packages/ (currently uses src/)
- Update all imports to use package references
- Add per-package testing in CI
- Implement workspace commands (install, update, etc.)
- Add package publishing workflow

## Transition Plan

The codebase currently maintains both structures:
- `src/` - Original structure (currently active)
- `packages/` - New structure (ready for migration)

This allows for:
1. Gradual migration without breaking changes
2. Testing the new structure in parallel
3. Validating workspace features
4. Maintaining backwards compatibility

To complete the migration:
1. Update `build.zig` to use packages/ paths
2. Update all import paths in src/main.zig and src/ion.zig
3. Remove old src/ subdirectories
4. Keep src/main.zig and src/ion.zig as the CLI/root entry points

## Workspace Commands

Home's package manager includes workspace support:

```bash
# Initialize workspace
ion pkg init

# Show dependency tree
ion pkg tree

# Run script across workspace
ion pkg run <script>

# List all available scripts
ion pkg scripts

# Install all workspace dependencies
ion pkg install
```

## Example: Using Packages

Other Home projects can now depend on Home packages:

```toml
# my-project/ion.toml
[package]
name = "my-tool"
version = "0.1.0"

[dependencies]
home-lexer = { path = "../home/packages/lexer" }
home-parser = { path = "../home/packages/parser" }
```

## Summary

The monorepo structure provides:
- ✅ Clear organization
- ✅ Independent packages
- ✅ Workspace management
- ✅ Better testing
- ✅ Reusability
- ✅ Bun-style developer experience

This positions Home for better modularity, easier contribution, and more flexible usage patterns.
