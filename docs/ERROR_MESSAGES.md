# Error Messages and Diagnostics in Home

This document describes the comprehensive error message and diagnostic system implemented for the Home programming language.

## Overview

Home provides **rich, user-friendly error messages** inspired by Rust's diagnostic system, with the following features:

- **Colored output**: Visual hierarchy with colors for severity levels
- **Source context**: Show the exact location of errors with code snippets
- **Primary and secondary labels**: Highlight relevant code locations
- **Helpful suggestions**: "Did you mean?" suggestions for typos
- **Error recovery**: Continue parsing to find multiple errors at once
- **Builder pattern**: Fluent API for constructing custom diagnostics
- **Common diagnostics**: Pre-built error messages for frequent cases

## Architecture

The error message system consists of three main components:

### 1. Rich Diagnostics

Located in `packages/diagnostics/src/diagnostics.zig`, this provides the core diagnostic types and rendering system.

```zig
const diag = try CommonDiagnostics.typeMismatch(
    allocator,
    location,
    "Int",
    "String"
);

try diag.display("example.home", source_code, std.io.getStdErr().writer());
```

### 2. Error Recovery

Located in `packages/parser/src/error_recovery.zig`, this provides strategies for recovering from parse errors to continue finding more errors.

```zig
var recovery = ErrorRecovery.init(.Moderate, 100);
recovery.synchronizeToStatement(tokens, &current);
```

### 3. Diagnostic Builder

Provides a fluent API for constructing custom diagnostics:

```zig
var builder = DiagnosticBuilder.init(allocator, .Error, "E0001", "custom error");
_ = builder.withPrimaryLabel(location, "here's the problem");
_ = try builder.withNote("additional context");
_ = builder.withHelp("try this instead");
const diag = try builder.build();
```

## Key Components

### RichDiagnostic

The main diagnostic type that contains all information about an error:

```zig
pub const RichDiagnostic = struct {
    severity: Severity,           // Error, Warning, Info
    error_code: []const u8,       // e.g., "T0001", "V0001"
    title: []const u8,            // Brief description
    primary_label: Label,         // Main error location
    secondary_labels: []const Label,  // Related locations
    notes: []const []const u8,    // Additional information
    help: ?[]const u8,            // Suggestion for fixing
    suggestion: ?Suggestion,       // Code suggestion with replacement
};
```

### Labels

Labels point to specific locations in source code:

```zig
pub const Label = struct {
    location: ast.SourceLocation,  // Line and column
    message: []const u8,           // Description
    style: LabelStyle,             // Primary or Secondary
};
```

**Output format**:
```
  5 | let x: Int = "hello"
    |              ^^^^^^^ expected Int, found String
```

### Suggestions

Code suggestions provide automatic fixes:

```zig
pub const Suggestion = struct {
    location: ast.SourceLocation,
    message: []const u8,
    replacement: []const u8,  // Suggested code
};
```

**Output format**:
```
help: try using type conversion
    |
  5 |     let x: Int = "hello".parse()
    |                  ~~~~~~~~~~~~~~~
```

### Severity Levels

```zig
pub const Severity = enum {
    Error,    // Red - compilation failure
    Warning,  // Yellow - potential issue
    Info,     // Blue - informational
};
```

## Common Diagnostics

Pre-built diagnostics for frequent error cases:

### Type Mismatch (T0001)

```home
let x: Int = "hello"
```

**Diagnostic**:
```
error[T0001]: type mismatch: expected Int, found String
 --> example.home:1:14
  |
1 | let x: Int = "hello"
  |              ^^^^^^^ expected Int, but found String
  |
help: consider using type conversion or checking your types
```

### Undefined Variable (V0001)

```home
let result = variabel + 10
```

**Diagnostic**:
```
error[V0001]: undefined variable 'variabel'
 --> example.home:1:14
  |
1 | let result = variabel + 10
  |              ^^^^^^^^ not found in this scope
  |
help: did you mean 'variable'?
```

### Cannot Mutate (M0001)

```home
let count = 0
count = count + 1
```

**Diagnostic**:
```
error[M0001]: cannot mutate immutable variable 'count'
 --> example.home:2:1
  |
1 | let count = 0
  |     ----- variable defined here as immutable
2 | count = count + 1
  |       ^ cannot mutate
  |
help: consider making this variable mutable: let mut count = 0
```

### Argument Count Mismatch (F0001)

```home
fn add(x, y) = x + y
let result = add(1, 2, 3)
```

**Diagnostic**:
```
error[F0001]: function 'add' expects 2 arguments, but 3 were provided
 --> example.home:2:14
  |
2 | let result = add(1, 2, 3)
  |              ^^^^^^^^^^^^ expected 2 arguments, found 3
  |
help: remove the extra arguments
```

### Missing Return (R0001)

```home
fn calculate(): Int {
    let x = 42
    // missing return
}
```

**Diagnostic**:
```
error[R0001]: function 'calculate' must return a value of type Int
 --> example.home:3:1
  |
3 | }
  | ^ expected return statement
  |
note: function signature declares return type Int
help: add a return statement: return <expr>
```

### Non-Exhaustive Match (P0001)

```home
match option {
    Some(x) => x
}
```

**Diagnostic**:
```
error[P0001]: non-exhaustive pattern match
 --> example.home:1:1
  |
1 | match option {
  | ^^^^^^^^^^^^ missing patterns
  |
note: missing pattern: Some(T)
note: missing pattern: None
help: add missing patterns or use a wildcard (_)
```

### Division by Zero (A0001)

```home
let x = 10 / 0
```

**Diagnostic**:
```
error[A0001]: attempt to divide by zero
 --> example.home:1:12
  |
1 | let x = 10 / 0
  |            ^^^ division by zero
  |
note: this is a compile-time error for constant expressions
```

### Index Out of Bounds (A0002)

```home
let arr = [1, 2, 3]
let x = arr[5]
```

**Diagnostic**:
```
error[A0002]: index 5 is out of bounds for array of length 3
 --> example.home:2:9
  |
2 | let x = arr[5]
  |         ^^^^^^ index out of bounds
  |
help: valid indices are 0..3
```

### Unreachable Code (W0001)

```home
fn example() {
    return 42
    let x = 10  // unreachable
}
```

**Diagnostic**:
```
warning[W0001]: unreachable code
 --> example.home:3:5
  |
3 |     let x = 10
  |     ^^^^^^^^^^ unreachable statement
  |
note: any code after return statement will never be executed
help: remove the unreachable code
```

### Unused Variable (W0002)

```home
fn example() {
    let temp = 42
    // temp is never used
}
```

**Diagnostic**:
```
warning[W0002]: unused variable 'temp'
 --> example.home:2:9
  |
2 |     let temp = 42
  |         ^^^^ unused variable
  |
help: if intentional, prefix with underscore: _temp
```

### Cannot Infer Type (T0002)

```home
let x = []
```

**Diagnostic**:
```
error[T0002]: cannot infer type in this context
 --> example.home:1:9
  |
1 | let x = []
  |         ^^ type must be known at this point
  |
note: context: empty array literal
help: provide an explicit type annotation: let x: [Int] = []
```

## Error Recovery

The parser uses multiple strategies to recover from errors and continue parsing:

### Recovery Modes

```zig
pub const RecoveryMode = enum {
    /// Stop at first error in statement
    Minimal,
    /// Skip to next statement boundary
    Moderate,
    /// Try to recover within expressions
    Aggressive,
};
```

### Synchronization Points

Recovery synchronizes to these boundaries:

- **Statement**: Semicolon or statement-starting keywords (`let`, `fn`, `if`, etc.)
- **Expression**: Comma, semicolon, or closing delimiters
- **Declaration**: Declaration keywords (`fn`, `struct`, `enum`, etc.)
- **Block**: Matching closing brace
- **Function**: Next function declaration
- **Struct/Enum**: Next type declaration

### Panic Mode Recovery

Skip tokens until reaching a synchronization point:

```zig
panicModeRecover(tokens, &current, .Statement);
```

### Phrase-Level Recovery

Suggest common corrections:

```zig
// User typed '=' in comparison
pub const common_substitutions = [_]Substitution{
    .{
        .wrong = .Equal,
        .correct = .EqualEqual,
        .message = "use '==' for comparison, '=' is for assignment"
    },
};
```

### Error Suggestions

#### Fuzzy Name Matching

Uses Levenshtein distance to suggest similar names:

```zig
const suggestion = ErrorSuggestions.suggestSimilarName(
    allocator,
    "variabel",
    &.{"variable", "value", "variance"}
);
// Returns "variable" (distance of 1)
```

**Algorithm**: Dynamic programming implementation of Levenshtein distance
- Maximum distance: 3 edits
- O(n×m) time complexity
- Stack allocation for strings < 100 chars

#### Keyword Suggestions

Suggest complete keywords from partial input:

```zig
const suggestion = ErrorSuggestions.suggestKeyword("ret");
// Returns "return"
```

#### Closing Delimiter Suggestions

Suggest matching closing delimiters:

```zig
const closing = ErrorSuggestions.suggestClosingDelimiter(.LeftParen);
// Returns .RightParen
```

### Minimal Edit Suggestions

Suggest the smallest edit to fix syntax:

```zig
pub const Edit = union(enum) {
    Insert: Token,        // Insert a missing token
    Delete: usize,        // Delete an extra token
    Replace: struct {     // Replace with correct token
        index: usize,
        new_token: Token,
    },
};
```

## Output Format

### Error Message Structure

```
error[CODE]: title
 --> file.home:line:column
  |
line | source code
  |  ^^^^^ primary label
  |  ----- secondary label
  |
note: additional information
help: suggestion for fixing
```

### Color Scheme

- **Error**: Bold red header, red underlines
- **Warning**: Bold yellow header, yellow underlines
- **Info**: Bold blue header, blue underlines
- **Primary labels**: Use severity color
- **Secondary labels**: Cyan color
- **Line numbers**: Dim blue
- **Source code**: Default terminal color
- **Suggestions**: Green color

### Multi-Label Display

When multiple labels exist:

```
error[E0001]: conflicting definitions
 --> example.home:10:5
  |
10 |     fn process() { }
   |        ^^^^^^^ first definition here
20 |     fn process() { }
   |        ^^^^^^^ second definition here
  |
help: rename one of the functions
```

## Usage Examples

### Creating Custom Diagnostics

```zig
const allocator = std.heap.page_allocator;

// Using the builder pattern
var builder = DiagnosticBuilder.init(
    allocator,
    .Error,
    "CUSTOM01",
    "something went wrong"
);

const location = ast.SourceLocation{ .line = 10, .column = 5 };
_ = builder.withPrimaryLabel(location, "this is the problem");

const related_loc = ast.SourceLocation{ .line = 5, .column = 8 };
_ = try builder.withSecondaryLabel(related_loc, "related to this");

_ = try builder.withNote("This happened because...");
_ = builder.withHelp("Try doing this instead");

const diag = try builder.build();
try diag.display("file.home", source_code, writer);
```

### Using Common Diagnostics

```zig
// Type mismatch
const diag = try CommonDiagnostics.typeMismatch(
    allocator,
    location,
    "Int",
    "String"
);
try diag.display(file_path, source, writer);

// Undefined variable with suggestion
const diag = try CommonDiagnostics.undefinedVariable(
    allocator,
    location,
    "variabel",
    "variable"  // Similar name
);
try diag.display(file_path, source, writer);
```

### Error Recovery in Parser

```zig
// When an error occurs during parsing
fn parseStatement(self: *Parser) !*ast.Stmt {
    if (self.match(.Let)) {
        return self.parseLetDeclaration() catch |err| {
            // Report the error
            try self.reportError("invalid let declaration");

            // Recover to next statement
            var recovery = ErrorRecovery.init(.Moderate, 100);
            recovery.synchronizeToStatement(self.tokens, &self.current);

            // Return error to skip this statement
            return err;
        };
    }
    // ... other cases
}
```

### Collecting Multiple Errors

```zig
var errors = std.ArrayList(RichDiagnostic).init(allocator);
defer errors.deinit();

// Parser continues after errors
while (parser.current < parser.tokens.len) {
    parser.parseStatement() catch |err| {
        if (parser.last_diagnostic) |diag| {
            try errors.append(diag);
        }
        continue;  // Keep parsing
    };
}

// Display all collected errors
for (errors.items) |diag| {
    try diag.display(file_path, source, writer);
}
```

## Error Code Prefixes

Error codes follow a systematic naming scheme:

- **T0xxx**: Type system errors (mismatch, inference, conversion)
- **V0xxx**: Variable errors (undefined, redeclaration, shadowing)
- **M0xxx**: Mutability errors (immutable assignment, move after use)
- **F0xxx**: Function errors (argument count, return type, signature)
- **R0xxx**: Return statement errors (missing, unreachable)
- **P0xxx**: Pattern matching errors (non-exhaustive, invalid pattern)
- **A0xxx**: Arithmetic errors (division by zero, overflow, bounds)
- **W0xxx**: Warnings (unreachable code, unused variables)
- **I0xxx**: Informational messages
- **S0xxx**: Syntax errors (unexpected token, missing delimiter)
- **L0xxx**: Lifetime and borrow errors

## Integration with Parser

The diagnostic system integrates with the parser at multiple points:

1. **Lexical errors**: Invalid tokens, unterminated strings
2. **Syntax errors**: Unexpected tokens, missing delimiters
3. **Semantic errors**: Type mismatches, undefined variables
4. **Warning generation**: Unused variables, unreachable code

### Parser Error Reporting

```zig
fn expect(self: *Parser, token_type: TokenType, message: []const u8) !Token {
    if (self.check(token_type)) {
        return self.advance();
    }

    // Create diagnostic
    var builder = DiagnosticBuilder.init(
        self.allocator,
        .Error,
        "S0001",
        message
    );

    const location = ast.SourceLocation.fromToken(self.peek());
    _ = builder.withPrimaryLabel(location, "unexpected token");

    if (self.current > 0) {
        const prev_loc = ast.SourceLocation.fromToken(self.previous());
        _ = try builder.withSecondaryLabel(prev_loc, "after this");
    }

    const diag = try builder.build();
    self.last_diagnostic = diag;

    return error.ParseError;
}
```

## Performance Considerations

- **Allocation**: Diagnostics allocate for labels, notes, and messages
- **String formatting**: Uses Zig's `std.fmt` for efficient formatting
- **Color codes**: Minimal overhead, just ANSI escape sequences
- **Recovery**: O(n) token skipping in worst case
- **Levenshtein distance**: O(n×m) but limited to strings < 100 chars

## Testing

The diagnostic system has comprehensive tests in `packages/diagnostics/tests/rich_diagnostics_test.zig`:

### Common Diagnostic Tests

- Type mismatch error (T0001)
- Undefined variable with suggestion (V0001)
- Cannot mutate immutable (M0001)
- Argument count mismatch - too many (F0001)
- Argument count mismatch - too few (F0001)
- Missing return statement (R0001)
- Non-exhaustive match (P0001)
- Division by zero (A0001)
- Index out of bounds (A0002)
- Unreachable code warning (W0001)
- Unused variable warning (W0002)
- Cannot infer type (T0002)

### Builder Tests

- Custom error with builder
- Diagnostic with suggestion
- Multiple secondary labels
- Multiple notes
- Error without primary label (should fail)

### Error Recovery Tests

Located in `packages/parser/src/error_recovery.zig` tests:

- Synchronization to statement boundary
- Synchronization to expression boundary
- Synchronization to declaration boundary
- Block depth tracking
- Missing token recovery
- Delimiter matching

Run tests with:
```bash
zig build test
```

## Future Enhancements

Potential improvements to the diagnostic system:

1. **IDE integration**: LSP diagnostics for real-time feedback
2. **Fix-it hints**: Automatic code fixes with apply button
3. **Diagnostic groups**: Related errors grouped together
4. **Error explanations**: Detailed explanations with examples
5. **Localization**: Error messages in multiple languages
6. **Telemetry**: Track common errors to improve messages
7. **Interactive mode**: Ask questions to clarify intent
8. **Diff display**: Show before/after for suggestions
9. **Call stack traces**: For runtime errors
10. **Batch mode**: Suppress repeated similar errors

## Best Practices

### For Compiler Developers

1. **Use common diagnostics** when possible for consistency
2. **Provide context** with secondary labels
3. **Suggest fixes** with help messages when known
4. **Recover gracefully** to find multiple errors
5. **Use appropriate severity** (Error vs Warning vs Info)
6. **Include error codes** for documentation lookup
7. **Test error messages** to ensure clarity

### For Language Users

1. **Read the full diagnostic** including notes and help
2. **Check secondary labels** for related context
3. **Look up error codes** in documentation for details
4. **Use suggestions** as starting points for fixes
5. **Report unclear messages** to improve the system

## References

- [Rust Error Handling](https://doc.rust-lang.org/error-index.html)
- [Elm Compiler Messages](https://elm-lang.org/news/compiler-errors-for-humans)
- [Clang Diagnostics](https://clang.llvm.org/diagnostics.html)
- [Levenshtein Distance Algorithm](https://en.wikipedia.org/wiki/Levenshtein_distance)

## Files

- **Core**: `packages/diagnostics/src/diagnostics.zig` (includes RichDiagnostic, DiagnosticBuilder, CommonDiagnostics)
- **Recovery**: `packages/parser/src/error_recovery.zig`
- **Tests**: `packages/diagnostics/tests/rich_diagnostics_test.zig`
