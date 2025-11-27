# Home Diagnostics

Beautiful, compiler-quality error messages with source context and helpful suggestions.

## Overview

The diagnostics package provides Rust-quality error reporting with rich visual formatting, source code context, multi-level severity, and actionable suggestions. Designed to help developers understand and fix issues quickly.

## Features

### Enhanced Error Reporting
- **Rich visual formatting**: Color-coded errors, warnings, and notes
- **Source context**: Shows relevant code lines with line numbers
- **Multi-character spans**: Highlights full identifiers and operators (`^~~~`)
- **Contextual labels**: Primary, secondary, and note-style annotations
- **Severity levels**: Error, Warning, Note, Help

### Developer Experience
- **Actionable suggestions**: Provides fix recommendations with code replacements
- **Configurable output**: Control colors, context lines, and suggestion display
- **Source file tracking**: Maintains source content for accurate diagnostics
- **Cross-references**: Links related errors and notes

## Architecture

```
EnhancedReporter
├── source_files: HashMap<Path, Source>
├── diagnostics: ErrorBag
└── config: ReporterConfig
    ├── use_color: bool
    ├── show_suggestions: bool
    ├── show_context: bool
    └── context_lines: usize
```

## Usage

### Basic Setup

```zig
const diagnostics = @import("diagnostics");
const EnhancedReporter = diagnostics.EnhancedReporter;

// Create reporter
var reporter = EnhancedReporter.init(allocator, .{
    .use_color = true,
    .show_suggestions = true,
    .show_context = true,
    .context_lines = 2,
});
defer reporter.deinit();
```

### Register Source Files

```zig
const source = try std.fs.cwd().readFileAlloc(allocator, "main.home", 1024 * 1024);
try reporter.registerSource("main.home", source);
```

### Report Errors

```zig
const diagnostic = EnhancedReporter.EnhancedDiagnostic{
    .severity = .Error,
    .code = "E0308",
    .message = "mismatched types",
    .location = .{ .line = 10, .column = 5 },
    .labels = &[_]EnhancedReporter.EnhancedDiagnostic.Label{
        .{
            .location = .{ .line = 10, .column = 5 },
            .message = "expected `i32`, found `string`",
            .style = .primary,
        },
    },
    .notes = &[_][]const u8{
        "consider converting the string to an integer",
    },
    .help = "use `parseInt()` to convert strings to integers",
    .suggestion = .{
        .message = "try converting with parseInt",
        .replacement = .{
            .location = .{ .line = 10, .column = 5 },
            .text = "parseInt(value)",
        },
    },
};

try reporter.report(diagnostic, "main.home");
```

### Output Example

```
error[E0308]: mismatched types
  --> main.home:10:5
   |
 8 |     let x: i32 = 42;
 9 |     let y: string = "hello";
10 |     let z = x + y;
   |                 ^ expected `i32`, found `string`
   |
  note: consider converting the string to an integer
  help: use `parseInt()` to convert strings to integers

  help: try converting with parseInt
  --> main.home:10:5
   |
   | parseInt(value)
   |
```

## API Reference

### EnhancedReporter

**Methods:**
- `init(allocator, config)`: Create new reporter
- `deinit()`: Clean up resources
- `registerSource(file_path, source)`: Register source file for context
- `report(diagnostic, file_path)`: Report a diagnostic

**Configuration:**
```zig
pub const Config = struct {
    use_color: bool = true,           // Enable ANSI color codes
    show_suggestions: bool = true,     // Show fix suggestions
    show_context: bool = true,         // Show source context
    context_lines: usize = 2,          // Lines before/after error
};
```

### EnhancedDiagnostic

```zig
pub const EnhancedDiagnostic = struct {
    severity: Severity,           // Error, Warning, Note
    code: ?[]const u8 = null,     // Error code (e.g., "E0308")
    message: []const u8,          // Main error message
    location: SourceLocation,      // Primary location
    labels: []Label,              // Annotations
    notes: [][]const u8 = &.{},   // Additional notes
    help: ?[]const u8 = null,     // Help text
    suggestion: ?Suggestion = null, // Fix suggestion
};
```

### Label

```zig
pub const Label = struct {
    location: SourceLocation,
    message: []const u8,
    style: Style = .primary,

    pub const Style = enum {
        primary,    // Red, main error location
        secondary,  // Blue, related location
        note,       // Cyan, informational
    };
};
```

### Suggestion

```zig
pub const Suggestion = struct {
    message: []const u8,
    replacement: ?Replacement = null,

    pub const Replacement = struct {
        location: SourceLocation,
        text: []const u8,  // Suggested fix
    };
};
```

## Features in Detail

### 1. Color-Coded Severity

```zig
pub const Severity = enum {
    Error,    // Red, bold
    Warning,  // Yellow, bold
    Note,     // Cyan
    Help,     // Green

    pub fn color(self: Severity) Color {
        return switch (self) {
            .Error => .Red,
            .Warning => .Yellow,
            .Note => .Cyan,
            .Help => .Green,
        };
    }
};
```

### 2. Multi-Character Spans

Automatically detects and highlights full tokens:

```zig
// Identifiers
variable_name
^~~~~~~~~~~~~

// Two-char operators
x == y
  ^^

// Operators detected: ==, !=, <=, >=, &&, ||, ->, ::
```

### 3. Source Context

Shows code with line numbers and gutter:

```
  |
8 | let x: i32 = 42;
9 | let y: string = "hello";
10| let z = x + y;
  |                 ^ expected `i32`, found `string`
  |
```

### 4. Suggestions with Replacements

Provides actionable fixes:

```
help: try converting with parseInt
  --> main.home:10:5
   |
   | parseInt(value)
   |
```

## Real-World Examples

### Type Mismatch

```zig
const diagnostic = .{
    .severity = .Error,
    .code = "E0308",
    .message = "mismatched types",
    .location = .{ .line = 15, .column = 12 },
    .labels = &[_]Label{
        .{
            .location = .{ .line = 15, .column = 12 },
            .message = "expected `bool`, found `i32`",
            .style = .primary,
        },
    },
    .help = "use a comparison operator to create a boolean",
};
```

### Undefined Variable

```zig
const diagnostic = .{
    .severity = .Error,
    .code = "E0425",
    .message = "cannot find value `count` in this scope",
    .location = .{ .line = 20, .column = 10 },
    .labels = &[_]Label{
        .{
            .location = .{ .line = 20, .column = 10 },
            .message = "not found in this scope",
            .style = .primary,
        },
    },
    .notes = &[_][]const u8{"did you mean `counter`?"},
    .suggestion = .{
        .message = "try using the correct variable name",
        .replacement = .{
            .location = .{ .line = 20, .column = 10 },
            .text = "counter",
        },
    },
};
```

### Borrow Checker Error

```zig
const diagnostic = .{
    .severity = .Error,
    .code = "E0502",
    .message = "cannot borrow `x` as mutable because it is also borrowed as immutable",
    .location = .{ .line = 25, .column = 5 },
    .labels = &[_]Label{
        .{
            .location = .{ .line = 23, .column = 10 },
            .message = "immutable borrow occurs here",
            .style = .secondary,
        },
        .{
            .location = .{ .line = 25, .column = 5 },
            .message = "mutable borrow occurs here",
            .style = .primary,
        },
        .{
            .location = .{ .line = 26, .column = 5 },
            .message = "immutable borrow later used here",
            .style = .note,
        },
    },
};
```

## Color Codes

```zig
pub const Color = enum {
    Reset,
    Bold,
    Dim,
    Red,
    Green,
    Yellow,
    Blue,
    Cyan,

    pub fn code(self: Color) []const u8 {
        return switch (self) {
            .Reset => "\x1b[0m",
            .Bold => "\x1b[1m",
            .Dim => "\x1b[2m",
            .Red => "\x1b[31m",
            .Green => "\x1b[32m",
            .Yellow => "\x1b[33m",
            .Blue => "\x1b[34m",
            .Cyan => "\x1b[36m",
        };
    }
};
```

## Testing

```bash
# Run diagnostics tests
zig test packages/diagnostics/tests/diagnostics_test.zig

# Run enhanced reporter tests
zig test packages/diagnostics/tests/enhanced_reporter_test.zig

# Test with color output
zig test packages/diagnostics/tests/color_test.zig
```

## Integration

The diagnostics package integrates with the compiler pipeline:

```zig
const parser = @import("parser");
const diagnostics = @import("diagnostics");

var reporter = diagnostics.EnhancedReporter.init(allocator, .{});
defer reporter.deinit();

// Register source
try reporter.registerSource(file_path, source);

// Parse with error reporting
const ast = parser.parse(tokens) catch |err| {
    const diagnostic = .{
        .severity = .Error,
        .code = "E0001",
        .message = "parse error",
        .location = parser.current_location,
        .labels = &[_]diagnostics.Label{
            .{
                .location = parser.current_location,
                .message = try std.fmt.allocPrint(allocator, "{}", .{err}),
                .style = .primary,
            },
        },
    };

    try reporter.report(diagnostic, file_path);
    return err;
};
```

## Best Practices

### 1. Always Register Sources

```zig
// Register before reporting
try reporter.registerSource("main.home", source);
```

### 2. Use Error Codes

```zig
// Makes errors searchable and documentable
.code = "E0308",  // mismatched types
.code = "E0425",  // undefined variable
.code = "E0502",  // borrow conflict
```

### 3. Provide Multiple Labels

```zig
// Show related locations
.labels = &[_]Label{
    .{ .location = def_loc, .message = "defined here", .style = .secondary },
    .{ .location = use_loc, .message = "used here", .style = .primary },
},
```

### 4. Add Suggestions When Possible

```zig
// Help users fix the issue
.suggestion = .{
    .message = "try using the correct type",
    .replacement = .{ .location = loc, .text = "i32" },
},
```

## License

Part of the Home programming language project.
