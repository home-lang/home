# Home Language Support for Visual Studio Code

Official Visual Studio Code extension for the [Home programming language](https://github.com/home-lang/home) - combining the speed of Zig, the safety of Rust, and the joy of TypeScript.

## Features

### 🎨 Syntax Highlighting
- Complete syntax highlighting for all Home language features
- Support for both `.home` and `.hm` file extensions
- Optimized TextMate grammar for fast, accurate highlighting
- Highlighting for:
  - Keywords (43 language keywords)
  - Operators (arithmetic, logical, bitwise, special)
  - Types (primitives, structs, enums, unions, traits)
  - Functions and closures
  - Pattern matching
  - Attributes and macros
  - Comments (line and block)

### 🔧 Language Features (via LSP)
- **IntelliSense** - Smart code completion
- **Hover Information** - Documentation on hover
- **Go to Definition** - Jump to symbol definitions
- **Find References** - Find all references to a symbol
- **Document Symbols** - Outline view of file structure
- **Diagnostics** - Real-time error and warning reporting
- **Code Formatting** - Automatic code formatting

### 📝 Code Snippets
50+ code snippets for common patterns:
- `fn` - Function declaration
- `afn` - Async function
- `struct` - Struct definition
- `enum` - Enum definition
- `trait` - Trait definition
- `impl` - Trait implementation
- `match` - Pattern matching
- `if`, `while`, `for` - Control flow
- And many more...

### 🔨 Build & Run Integration
- Build current file (`Cmd+Shift+B` / `Ctrl+Shift+B`)
- Run current file
- Run tests
- Task provider for common operations

### ⚙️ Smart Editing
- Auto-closing brackets and quotes
- Comment toggling (`Cmd+/` / `Ctrl+/`)
- Code folding
- Smart indentation
- Block comment formatting

## Installation

### From VSIX (Local)
1. Download the latest `.vsix` file
2. Open VS Code
3. Go to Extensions view (`Cmd+Shift+X` / `Ctrl+Shift+X`)
4. Click "..." menu → "Install from VSIX..."
5. Select the downloaded file

### From Source
```bash
cd vscode-home
npm install
npm run compile
npm run package
code --install-extension vscode-home-*.vsix
```

## Requirements

- Visual Studio Code 1.70.0 or higher
- Home language compiler (for LSP features)

## Extension Settings

This extension contributes the following settings:

* `home.lsp.enabled`: Enable/disable Language Server Protocol support (default: `true`)
* `home.lsp.path`: Path to Home language server executable (leave empty to auto-detect)
* `home.lsp.trace.server`: Trace communication with language server (`off`, `messages`, `verbose`)
* `home.format.onSave`: Automatically format files on save (default: `false`)
* `home.build.onSave`: Automatically build files on save (default: `false`)
* `home.inlayHints.enabled`: Enable inlay hints for type information (default: `true`)
* `home.diagnostics.enabled`: Enable diagnostic messages (default: `true`)

## Commands

* `Home: Restart Language Server` - Restart the LSP server
* `Home: Build Current File` - Build the active file
* `Home: Run Current File` - Run the active file
* `Home: Run Tests` - Run all tests in the workspace
* `Home: Format Document` - Format the current document

## Keyboard Shortcuts

* `Cmd+Shift+B` / `Ctrl+Shift+B` - Build current file
* `Cmd+/` / `Ctrl+/` - Toggle line comment
* `Shift+Alt+F` / `Shift+Alt+F` - Format document

## Usage

### Quick Start

1. Create a new file with `.home` or `.hm` extension
2. Start typing - IntelliSense and syntax highlighting work automatically
3. Use snippets for common patterns (type `fn` and press Tab)
4. Build with `Cmd+Shift+B` / `Ctrl+Shift+B`

### Example

```home
// hello.home
fn main() {
  print("Hello, Home!")
}
```

### Working with Projects

```bash
# Initialize a new project
home init my-project
cd my-project

# Open in VS Code
code .

# Start coding in src/main.home
```

## Language Features Supported

### Keywords
Control flow: `if`, `else`, `while`, `loop`, `do`, `for`, `in`, `break`, `continue`, `return`, `match`, `switch`, `case`, `default`

Declarations: `fn`, `let`, `const`, `mut`, `struct`, `enum`, `union`, `type`, `trait`, `impl`, `import`

Advanced: `async`, `await`, `comptime`, `defer`, `try`, `catch`, `finally`, `unsafe`, `asm`, `where`

### Operators
- Arithmetic: `+`, `-`, `*`, `/`, `%`
- Comparison: `==`, `!=`, `<`, `<=`, `>`, `>=`
- Logical: `&&`, `||`, `!`, `and`, `or`
- Bitwise: `&`, `|`, `^`, `~`, `<<`, `>>`
- Special: `->`, `|>`, `??`, `?.`, `?`, `..`, `..=`, `...`

### Type System
- Primitives: `int`, `float`, `bool`, `string`, `char`, `void`
- Sized integers: `i8`, `i16`, `i32`, `i64`, `u8`, `u16`, `u32`, `u64`
- Floating point: `f32`, `f64`
- Compound: `struct`, `enum`, `union`, `trait`
- Generics with type parameters and constraints

## Troubleshooting

### Language Server not starting
1. Check that Home compiler is installed: `home --version`
2. Set the path manually in settings: `home.lsp.path`
3. Check output: View → Output → "Home Language Server"

### Syntax highlighting not working
1. Ensure file has `.home` or `.hm` extension
2. Try reloading window: `Cmd+Shift+P` / `Ctrl+Shift+P` → "Reload Window"

### IntelliSense not working
1. Verify LSP is enabled: `home.lsp.enabled`
2. Restart language server: `Home: Restart Language Server`
3. Check for errors in Output panel

## Known Issues

- Semantic highlighting is a work in progress
- Some advanced type system features may not be fully supported in LSP yet

## Contributing

Contributions are welcome! Please see the [Home repository](https://github.com/home-lang/home) for contribution guidelines.

## Release Notes

### 0.1.0

Initial release with:
- Comprehensive syntax highlighting
- Language Server Protocol integration
- 50+ code snippets
- Smart editing features
- Build and run integration
- Task provider

## License

MIT License - see LICENSE file for details

---

**Enjoy coding in Home!** 🏠
