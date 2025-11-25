# Home Language Support for Visual Studio Code

Official Visual Studio Code extension for the Home programming language.

## Features

- **Syntax Highlighting** - Full syntax highlighting for Home language constructs
- **IntelliSense** - Smart code completion with context awareness
- **Go to Definition** - Navigate to symbol definitions with F12
- **Find All References** - Find all usages of symbols
- **Hover Information** - Type information and documentation on hover
- **Diagnostics** - Real-time error checking and warnings
- **Code Formatting** - Automatic code formatting
- **Rename Symbol** - Refactor code by renaming symbols
- **Semantic Highlighting** - Context-aware syntax coloring

## Requirements

The Home Language Server must be installed and accessible. You can specify its location in settings.

## Extension Settings

This extension contributes the following settings:

* `homeLanguageServer.path`: Path to the Home language server executable
* `homeLanguageServer.trace.server`: Enable/disable tracing of the language server communication

## Getting Started

1. Install the extension
2. Open a `.home` file
3. The language server will automatically start
4. Start coding with full IDE support!

## Commands

* `Home: Restart Language Server` - Restart the language server

## Language Features

### Type System
- Rust-style ownership and borrowing
- Pattern matching with exhaustiveness checking
- Generics with trait bounds
- Result types for error handling

### Syntax
- Function declarations with `fn`
- Struct, enum, and trait definitions
- Pattern matching with `match`
- Async/await syntax

Example:
```home
fn greet(name: String) -> String {
    return "Hello, " + name;
}

struct Point {
    x: i32,
    y: i32,
}

enum Result<T, E> {
    Ok(T),
    Err(E),
}
```

## Known Issues

- Cross-file navigation not yet implemented
- Some advanced refactorings are work in progress

## Release Notes

### 0.1.0

Initial release with core language server features:
- Syntax highlighting
- Code completion
- Go to definition
- Find references
- Hover information
- Diagnostics
- Code formatting
- Symbol renaming
- Semantic highlighting

## Contributing

Contributions are welcome! Please visit the [Home Language repository](https://github.com/home-lang/home) for more information.

## License

MIT
