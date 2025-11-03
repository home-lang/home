# VS Code Extension Implementation Plan for Home Language

## Overview
This document outlines the complete implementation plan for creating a professional VS Code extension for the Home programming language (.home, .hm files).

## Project Goals
1. Provide comprehensive syntax highlighting for all Home language features
2. Enable IntelliSense and code completion via LSP integration
3. Support debugging, formatting, and refactoring
4. Provide code snippets for common patterns
5. Deliver excellent developer experience matching TypeScript/Rust quality

---

## Phase 1: Project Setup & Structure

### Task 1.1: Initialize Extension Project
**Location:** `/Users/chrisbreuer/Code/home/vscode-home/`

**Files to Create:**
- `package.json` - Extension manifest and metadata
- `tsconfig.json` - TypeScript configuration
- `.vscodeignore` - Files to exclude from package
- `README.md` - Extension documentation
- `CHANGELOG.md` - Version history
- `LICENSE` - MIT license

**Dependencies:**
- `vscode` - VS Code API
- `vscode-languageclient` - LSP client library
- TypeScript for extension development

### Task 1.2: Directory Structure
```
vscode-home/
├── package.json
├── tsconfig.json
├── .vscodeignore
├── README.md
├── CHANGELOG.md
├── LICENSE
├── src/
│   ├── extension.ts          # Main extension entry point
│   └── lspClient.ts          # LSP client configuration
├── syntaxes/
│   └── home.tmLanguage.json  # TextMate grammar
├── language-configuration.json
├── snippets/
│   └── home.json             # Code snippets
├── themes/
│   └── home-dark.json        # Optional custom theme
└── images/
    └── icon.png              # Extension icon
```

---

## Phase 2: Language Configuration

### Task 2.1: Language Registration (`package.json`)
**Capabilities:**
- Register `.home` and `.hm` file extensions
- Associate with language ID `home`
- Define contribution points for:
  - Grammar
  - Language configuration
  - Snippets
  - Commands
  - LSP activation

### Task 2.2: Language Configuration (`language-configuration.json`)
**Features:**
- **Comments:**
  - Line comment: `//`
  - Block comment: `/* */`
- **Brackets:**
  - `()` parentheses
  - `{}` braces
  - `[]` square brackets
- **Auto-closing pairs:**
  - `"` double quotes
  - `'` single quotes
  - `` ` `` backticks (for potential template strings)
  - `()`, `{}`, `[]` bracket pairs
- **Surrounding pairs:**
  - Same as auto-closing pairs
- **Folding:**
  - Markers for `{...}` blocks
  - Region markers for custom folding
- **Indentation rules:**
  - Increase after: `{`, `(`
  - Decrease after: `}`, `)`
- **Word pattern:**
  - Regex for identifier matching

---

## Phase 3: Syntax Highlighting (TextMate Grammar)

### Task 3.1: Create TextMate Grammar (`syntaxes/home.tmLanguage.json`)

**Scope Hierarchy:**
```
source.home
├── comment.line.double-slash.home
├── comment.block.home
├── string.quoted.double.home
├── constant.numeric.integer.home
├── constant.numeric.float.home
├── constant.language.boolean.home
├── keyword.control.home
├── keyword.other.home
├── storage.type.home
├── storage.modifier.home
├── entity.name.function.home
├── entity.name.type.home
├── variable.parameter.home
├── variable.other.home
├── support.function.home
├── support.type.home
├── meta.function.home
├── meta.struct.home
├── meta.enum.home
├── meta.trait.home
└── meta.attribute.home
```

**Pattern Categories to Implement:**

#### 3.1.1: Comments
- Single-line: `// ...`
- Multi-line: `/* ... */`

#### 3.1.2: Strings & Literals
- Double-quoted strings with escape sequences
- Integer literals (decimal, hex, binary, octal)
- Float literals
- Boolean literals: `true`, `false`

#### 3.1.3: Keywords (43 total)
**Control Flow:**
- `if`, `else`, `while`, `loop`, `do`, `for`, `in`
- `break`, `continue`, `return`
- `switch`, `case`, `default`, `match`

**Declarations:**
- `fn`, `let`, `const`, `mut`, `struct`, `enum`, `union`
- `type`, `trait`, `impl`, `import`

**Advanced:**
- `async`, `await`, `comptime`, `defer`
- `try`, `catch`, `finally`, `unsafe`, `asm`, `where`
- `self`, `Self`, `dyn`

#### 3.1.4: Operators
**Arithmetic:** `+`, `-`, `*`, `/`, `%`
**Comparison:** `==`, `!=`, `<`, `<=`, `>`, `>=`
**Logical:** `&&`, `||`, `!`, `and`, `or`
**Bitwise:** `&`, `|`, `^`, `~`, `<<`, `>>`
**Special:** `->`, `|>`, `??`, `?.`, `?`, `..`, `..=`, `...`
**Assignment:** `=`, `+=`, `-=`, `*=`, `/=`, `%=`

#### 3.1.5: Type Annotations
- Function signatures: `fn name(x: i32) -> i32`
- Variable declarations: `let x: i32 = 10`
- Generic parameters: `<T>`, `<T, U>`
- Trait bounds: `where T: Clone`

#### 3.1.6: Function Definitions
- Function name highlighting
- Parameter list
- Return type annotation
- Generic type parameters

#### 3.1.7: Struct/Enum/Union/Trait Definitions
- Definition name highlighting
- Field declarations
- Variant patterns

#### 3.1.8: Attributes/Annotations
- `@test`, `@TypeOf`, `@sizeOf`, etc.

#### 3.1.9: Pattern Matching
- Match arms
- Pattern destructuring
- Guard clauses

#### 3.1.10: Closures
- `|| expression`
- `|x, y| expression`
- `move || expression`

---

## Phase 4: Code Snippets

### Task 4.1: Create Snippet Library (`snippets/home.json`)

**Essential Snippets:**

1. **fn** - Function declaration
2. **afn** - Async function
3. **gfn** - Generic function
4. **test** - Test function with @test
5. **main** - Main entry point
6. **struct** - Struct definition
7. **enum** - Enum definition
8. **trait** - Trait definition
9. **impl** - Trait implementation
10. **if** - If statement
11. **ife** - If-else statement
12. **while** - While loop
13. **for** - For loop
14. **loop** - Infinite loop
15. **match** - Match expression
16. **switch** - Switch statement
17. **try** - Try-catch-finally
18. **let** - Variable declaration
19. **const** - Constant declaration
20. **import** - Import statement
21. **closure** - Closure expression
22. **comp** - Array comprehension
23. **defer** - Defer statement
24. **asm** - Inline assembly
25. **unsafe** - Unsafe block

---

## Phase 5: LSP Integration

### Task 5.1: Extension Activation (`src/extension.ts`)
**Responsibilities:**
- Activate on `.home` and `.hm` files
- Start LSP client
- Register commands
- Handle configuration changes

### Task 5.2: LSP Client Setup (`src/lspClient.ts`)
**Configuration:**
- Server executable: `/Users/chrisbreuer/Code/home/zig-out/bin/home lsp`
- Server transport: stdio
- Document selector: `{ scheme: 'file', language: 'home' }`

**Client Capabilities to Enable:**
- Text document sync (full or incremental)
- Completion
- Hover
- Signature help
- Go to definition
- Find references
- Document symbols
- Workspace symbols
- Code actions
- Code lens
- Document formatting
- Range formatting
- Rename
- Diagnostics

### Task 5.3: Commands to Register
- `home.restartLanguageServer` - Restart LSP
- `home.showOutputChannel` - Show LSP logs
- `home.build` - Build current file
- `home.run` - Run current file
- `home.test` - Run tests
- `home.format` - Format document

---

## Phase 6: Advanced Features

### Task 6.1: Semantic Highlighting
**Token Types:**
- namespace
- class
- enum
- interface
- struct
- typeParameter
- parameter
- variable
- property
- enumMember
- function
- method
- macro
- keyword
- modifier
- comment
- string
- number
- regexp
- operator

**Token Modifiers:**
- declaration
- definition
- readonly
- static
- deprecated
- abstract
- async
- modification
- documentation
- defaultLibrary

### Task 6.2: Debug Adapter Protocol (DAP)
**Future Enhancement:**
- Debug configuration provider
- Breakpoint support
- Variable inspection
- Call stack navigation

### Task 6.3: Task Provider
**Build Tasks:**
- `home build` - Compile current file
- `home run` - Run current file
- `home test` - Run tests
- `home check` - Type check only
- `home format` - Format code

---

## Phase 7: Extension Metadata & Publishing

### Task 7.1: Package.json Configuration
**Metadata:**
- Name: `vscode-home`
- Display Name: `Home Language Support`
- Description: `Official VS Code extension for the Home programming language`
- Version: `0.1.0`
- Publisher: TBD
- Repository: GitHub link
- Categories: `["Programming Languages", "Linters", "Formatters"]`
- Keywords: `["home", "homelang", "zig", "rust", "typescript"]`
- Icon: Home logo
- License: MIT

**Activation Events:**
- `onLanguage:home`
- `onCommand:home.*`

**Contributes:**
- languages
- grammars
- snippets
- configuration
- commands
- taskDefinitions

### Task 7.2: Documentation
**README.md sections:**
- Features overview with screenshots
- Installation instructions
- Quick start guide
- Language features
- Extension settings
- Building from source
- Contributing guidelines
- License information

### Task 7.3: Extension Settings
**Configuration Options:**
```json
{
  "home.lsp.enabled": true,
  "home.lsp.path": "",
  "home.lsp.trace.server": "off",
  "home.format.onSave": false,
  "home.build.onSave": false,
  "home.inlayHints.enabled": true,
  "home.diagnostics.enabled": true
}
```

---

## Phase 8: Testing & Quality Assurance

### Task 8.1: Test Files
Create comprehensive test files covering:
- All keywords and operators
- Function definitions (regular, async, generic)
- Type definitions (struct, enum, union, trait)
- Control flow (if, while, for, match, switch)
- Pattern matching
- Closures and higher-order functions
- Array comprehensions
- Error handling (try-catch, ?)
- Async/await
- Compile-time features
- Attributes and macros
- Import statements

### Task 8.2: Extension Testing
- Test syntax highlighting accuracy
- Verify bracket matching and auto-closing
- Test code folding regions
- Validate snippet expansion
- Test LSP features (completion, hover, goto-def)
- Verify command execution
- Test with various VS Code themes

### Task 8.3: Performance Testing
- Test with large files (10k+ lines)
- Verify LSP responsiveness
- Check memory usage
- Test multi-file workspaces

---

## Phase 9: Packaging & Distribution

### Task 9.1: Build Extension Package
```bash
npm install -g vsce
vsce package
```
Produces: `vscode-home-0.1.0.vsix`

### Task 9.2: Local Testing
```bash
code --install-extension vscode-home-0.1.0.vsix
```

### Task 9.3: Publish to Marketplace (Future)
```bash
vsce publish
```

---

## Implementation Timeline

### Sprint 1: Foundation (Tasks 1-2)
- Project setup
- Language configuration
- Duration: 1-2 hours

### Sprint 2: Syntax Highlighting (Task 3)
- Complete TextMate grammar
- Duration: 3-4 hours

### Sprint 3: Snippets & LSP (Tasks 4-5)
- Code snippets
- LSP client integration
- Duration: 2-3 hours

### Sprint 4: Advanced Features (Task 6)
- Semantic highlighting
- Task provider
- Duration: 2-3 hours

### Sprint 5: Polish & Testing (Tasks 7-9)
- Documentation
- Testing
- Packaging
- Duration: 2-3 hours

**Total Estimated Time:** 10-15 hours

---

## Success Criteria

✅ **Must Have:**
1. Accurate syntax highlighting for all Home language features
2. Working LSP integration with completion, hover, and diagnostics
3. Code snippets for common patterns
4. Bracket matching and auto-closing
5. Comment toggling (Ctrl+/)
6. Code folding
7. Professional documentation

✅ **Should Have:**
8. Semantic highlighting
9. Task integration for build/run/test
10. Configurable extension settings
11. Inlay hints for type information
12. Format on save option

✅ **Nice to Have:**
13. Custom dark theme optimized for Home
14. Debug adapter integration
15. Refactoring support
16. Code actions (quick fixes)

---

## Dependencies & Prerequisites

**Required:**
- Node.js (v16+)
- npm or yarn
- TypeScript (v4.5+)
- VS Code (v1.70+)
- Home language compiler built at `/Users/chrisbreuer/Code/home/zig-out/bin/home`

**Optional:**
- vsce (Visual Studio Code Extensions) for packaging
- yo generator-code for scaffolding

---

## Technical Decisions

### Why TextMate Grammar?
- Fast, proven syntax highlighting
- Works offline
- VS Code native support
- No runtime overhead

### Why TypeScript for Extension?
- Type safety
- Better VS Code API integration
- Industry standard for VS Code extensions
- Rich ecosystem

### LSP Architecture
- Reuse existing Home LSP server
- Separation of concerns (server = Zig, client = TS)
- Standard protocol for future editor support

---

## Future Enhancements

1. **Inline REPL/Playground**
   - Execute code snippets inline
   - Show results in editor

2. **Package Manager Integration**
   - Browse Home packages
   - Install dependencies from editor

3. **Visual Debugger**
   - Full DAP implementation
   - Breakpoints, watches, step debugging

4. **Refactoring Tools**
   - Rename symbol across workspace
   - Extract function/variable
   - Inline variable

5. **Code Lens**
   - Show test results inline
   - Run/debug buttons
   - Implementation count

6. **Inlay Hints**
   - Type annotations
   - Parameter names
   - Return types

7. **AI-Powered Features**
   - Code suggestions
   - Documentation generation
   - Test generation

---

## References

- [VS Code Extension API](https://code.visualstudio.com/api)
- [Language Server Protocol](https://microsoft.github.io/language-server-protocol/)
- [TextMate Grammars](https://macromates.com/manual/en/language_grammars)
- [VS Code Extension Samples](https://github.com/microsoft/vscode-extension-samples)
- Home Language Codebase: `/Users/chrisbreuer/Code/home/`

---

## Appendix: File Extension Details

### Supported Extensions
- `.home` - Primary extension
- `.hm` - Alternative/shorthand

### MIME Type
- `text/x-home`

### Language ID
- `home`

---

*This plan will be updated as implementation progresses.*
