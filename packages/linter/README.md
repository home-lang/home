# Home Linter

A comprehensive, fast linter for the Home programming language with auto-fix capabilities. Inspired by ESLint, Biome, and Zig's built-in formatter.

## Features

- **Fast**: Written in Zig for maximum performance
- **Auto-fixable**: Most rules can automatically fix issues
- **Configurable**: Customize rules via `home.jsonc`, `home.json`, `home.toml`, or `package.jsonc`
- **IDE Integration**: Works seamlessly with LSP for on-save fixes
- **Zero Config**: Works out of the box with sensible defaults

## Usage

### CLI

```bash
# Lint a file and show diagnostics
home lint src/main.home

# Lint and auto-fix issues
home lint --fix src/main.home

# Format (alias for lint --fix)
home fmt src/main.home
```

### Configuration

Add a `linter` section to your `home.jsonc`, `home.json`, `home.toml`, or `package.jsonc`:

**home.jsonc** (recommended):
```jsonc
{
  "linter": {
    "max_line_length": 100,
    "indent_size": 4,
    "use_spaces": true,
    "trailing_comma": true,
    "semicolons": false,
    "quote_style": "double",
    "rules": {
      "no-unused-vars": { "enabled": true, "severity": "warning", "auto_fix": true },
      "no-console": { "enabled": false },
      "prefer-const": { "enabled": true, "severity": "warning", "auto_fix": true },
      "no-var": { "enabled": true, "severity": "error", "auto_fix": true }
    }
  }
}
```

**home.toml** (alternative):
```toml
[linter]
max_line_length = 100
indent_size = 4
use_spaces = true
trailing_comma = true
semicolons = false
quote_style = "double"

[linter.rules]
no-unused-vars = { enabled = true, severity = "warning", auto_fix = true }
no-console = { enabled = false }
prefer-const = { enabled = true, severity = "warning", auto_fix = true }
no-var = { enabled = true, severity = "error", auto_fix = true }
```

## Rules

### Code Quality

#### `no-unused-vars` ⚠️ Auto-fixable

Disallow unused variables.

```home
// ❌ Bad
let unused = 42
let x = 10

// ✅ Good
let x = 10
print(x)
```

#### `prefer-const` ⚠️ Auto-fixable

Prefer `const` over `let` for variables that are never reassigned.

```home
// ❌ Bad
let x = 10
print(x)

// ✅ Good
const x = 10
print(x)
```

#### `no-var` 🔴 Auto-fixable

Disallow `var` keyword (deprecated in favor of `let` and `const`).

```home
// ❌ Bad
var x = 10

// ✅ Good
let x = 10
```

#### `no-shadow` ⚠️

Disallow variable shadowing.

```home
// ❌ Bad
let x = 10
if (true) {
  let x = 20  // shadows outer x
}

// ✅ Good
let x = 10
if (true) {
  let y = 20
}
```

#### `no-magic-numbers` ⚠️

Disallow magic numbers (use named constants instead).

```home
// ❌ Bad
fn calculateArea(radius: f64): f64 {
  return 3.14159 _ radius _ radius
}

// ✅ Good
const PI = 3.14159

fn calculateArea(radius: f64): f64 {
  return PI _ radius _ radius
}
```

#### `explicit-function-return-type` ⚠️

Require explicit return types for functions.

```home
// ❌ Bad
fn add(a: i32, b: i32) {
  return a + b
}

// ✅ Good
fn add(a: i32, b: i32): i32 {
  return a + b
}
```

#### `no-unreachable` 🔴

Disallow unreachable code after return/throw.

```home
// ❌ Bad
fn example(): i32 {
  return 42
  print("This will never run")
}

// ✅ Good
fn example(): i32 {
  print("This will run")
  return 42
}
```

#### `no-empty` ⚠️

Disallow empty blocks.

```home
// ❌ Bad
if (condition) {
}

// ✅ Good
if (condition) {
  doSomething()
}
```

### Style

#### `indent` 🔴 Auto-fixable

Enforce consistent indentation.

```home
// ❌ Bad (mixed spaces/tabs)
fn example() {
    let x = 10
    let y = 20
}

// ✅ Good
fn example() {
    let x = 10
    let y = 20
}
```

#### `max-line-length` ⚠️

Enforce maximum line length (default: 100).

```home
// ❌ Bad
const veryLongVariableName = "This is a very long string that exceeds the maximum line length limit"

// ✅ Good
const veryLongVariableName =
  "This is a very long string that is properly wrapped"
```

#### `no-trailing-spaces` ⚠️ Auto-fixable

Disallow trailing whitespace.

```home
// ❌ Bad
let x = 10

// ✅ Good
let x = 10
```

#### `no-multiple-empty-lines` ⚠️ Auto-fixable

Disallow multiple consecutive empty lines.

```home
// ❌ Bad
let x = 10

let y = 20

// ✅ Good
let x = 10

let y = 20
```

#### `eol-last` ⚠️ Auto-fixable

Require newline at end of file.

#### `no-mixed-spaces-and-tabs` 🔴 Auto-fixable

Disallow mixed spaces and tabs for indentation.

#### `quotes` ⚠️ Auto-fixable

Enforce consistent quote style.

```home
// With quote_style = "double"
// ❌ Bad
let name = 'John'

// ✅ Good
let name = "John"
```

#### `semi` ⚠️ Auto-fixable

Enforce semicolon usage (or lack thereof).

```home
// With semicolons = false
// ❌ Bad
let x = 10;

// ✅ Good
let x = 10
```

#### `comma-dangle` ⚠️ Auto-fixable

Enforce trailing commas in multi-line structures.

```home
// With trailing_comma = true
// ❌ Bad
const obj = {
  name: "John",
  age: 30
}

// ✅ Good
const obj = {
  name: "John",
  age: 30,
}
```

#### `brace-style` ⚠️ Auto-fixable

Enforce consistent brace style.

```home
// ❌ Bad (inconsistent)
if (condition)
{
  doSomething()
}

// ✅ Good
if (condition) {
  doSomething()
}
```

#### `camelcase` ⚠️

Enforce camelCase naming convention.

```home
// ❌ Bad
let user_name = "John"

// ✅ Good
let userName = "John"
```

### Best Practices

#### `no-console` ⚠️

Warn about console.log usage (disabled by default).

```home
// ⚠️ Warning
console.log("Debug message")

// ✅ Use proper logging
logger.debug("Debug message")
```

#### `prefer-template` ⚠️ Auto-fixable

Prefer template strings over concatenation.

```home
// ❌ Bad
let message = "Hello, " + name + "!"

// ✅ Good
let message = `Hello, ${name}!`
```

## Severity Levels

- 🔴 **error**: Will cause lint to fail (exit code 1)
- ⚠️ **warning**: Will be reported but won't fail
- ℹ️ **info**: Informational messages
- 💡 **hint**: Suggestions for improvement

## IDE Integration

The linter integrates with the Home LSP server for real-time diagnostics and auto-fixes on save.

### VS Code

Add to your `.vscode/settings.json`:

```json
{
  "home.lint.enable": true,
  "home.lint.autoFixOnSave": true,
  "editor.formatOnSave": true
}
```

### Configuration Priority

1. `home.jsonc` in project root
2. `home.json` in project root
3. `package.jsonc` with `linter` field
4. `package.json` with `linter` field
5. `home.toml` with `[linter]` section
6. `couch.toml` with `[linter]` section (legacy)
7. Default configuration

## Performance

The linter is designed for speed:

- **Incremental**: Only re-lints changed files
- **Parallel**: Can lint multiple files concurrently
- **Cached**: Results are cached for unchanged files
- **Fast**: Written in Zig with zero-cost abstractions

## Examples

### Basic Usage

```bash
# Lint and show issues
home lint src/main.home

# Lint and auto-fix
home lint --fix src/main.home
# or
home fmt src/main.home

# Lint entire directory
home lint src/
```

### CI/CD Integration

```yaml
# GitHub Actions

- name: Lint Home code

  run: home lint src/
```

```bash
# Pre-commit hook
# !/bin/bash
home lint --fix $(git diff --cached --name-only --diff-filter=ACM | grep '\.home$')
```

## Contributing

To add a new rule:

1. Add rule implementation in `linter.zig`
2. Add rule to default config in `createDefaultConfig()`
3. Document the rule in this README
4. Add tests for the rule

## License

MIT
