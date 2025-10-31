# Inline Functions Package

Comprehensive function inlining support for the Home programming language, providing performance optimization through intelligent inline decisions.

## Features

### Inline Hints
- **None**: No explicit inlining preference
- **Inline**: Suggest function inlining (compiler may ignore)
- **AlwaysInline**: Force inlining (compiler should always inline)
- **NoInline**: Prevent function inlining

### Inline Strategies
- **Auto**: Compiler decides based on heuristics (default)
- **Small**: Inline small functions only (< 128 bytes or < 10 instructions)
- **Hot**: Inline functions in performance-critical paths (frequently called)
- **Aggressive**: Inline everything possible (< 100 instructions)
- **Conservative**: Only inline when explicitly marked

### Function Metadata
Track key metrics for inline decisions:
- Instruction count estimation
- Function size in bytes
- Call frequency tracking
- Recursion detection
- Side effect analysis

### Cost Model
Intelligent cost-benefit analysis:
- Call overhead calculation
- Parameter passing cost
- Stack frame setup cost
- Inline expansion cost
- Benefit-from-inlining analysis

### Decision Engine
- Register functions with metadata
- Track call sites
- Apply inline strategies
- Generate statistics
- Optimize inline depth

## Usage

```zig
const inline_pkg = @import("inline");

// Create decision engine
var engine = inline_pkg.InlineDecisionEngine.init(allocator, .Auto);
defer engine.deinit();

// Register a function
var func = inline_pkg.FunctionMetadata.init("fast_function");
func.instruction_count = 5;
func.size_bytes = 32;
func.hint = .Inline;
try engine.registerFunction(func);

// Record calls
try engine.recordCall("fast_function");

// Check if should inline
if (engine.shouldInline("fast_function")) {
    // Perform inlining transformation
}

// Get statistics
const stats = engine.getStatistics();
std.debug.print("Inline ratio: {d:.2}%\n", .{stats.inlineRatio() * 100});
```

## Inline Attributes

```zig
const attrs = inline_pkg.InlineAttribute;

// Force inline
const always = attrs.always(); // .AlwaysInline

// Prevent inline
const never = attrs.never(); // .NoInline

// Suggest inline
const suggest = attrs.suggest(); // .Inline
```

## Cost Model Example

```zig
const model = inline_pkg.CostModel{};

var func = inline_pkg.FunctionMetadata.init("compute");
func.instruction_count = 10;
func.call_count = 100;

// Check if inlining provides benefit
if (model.benefitsFromInlining(func, 3)) {
    // Inline this function - cost reduction expected
}
```

## Inline Transformer

```zig
var transformer = inline_pkg.InlineTransformer.init(allocator, &engine);

const call = inline_pkg.CallSite{
    .function_name = "my_function",
    .location = .{ .file = "main.zig", .line = 42, .column = 10 },
    .arguments = &[_][]const u8{ "arg1", "arg2" },
};

if (try transformer.transformCall(call)) |inlined| {
    // Successfully inlined
    std.debug.print("Inlined {s}, size: {} bytes\n", .{
        call.function_name,
        inlined.inlined_size,
    });
}
```

## Heuristics

### Auto Strategy
Automatically inlines functions when:
- Size < 64 bytes OR instructions < 5 (tiny functions)
- Call count > 5 AND instructions < 20 (small hot functions)
- Call count > 20 AND instructions < 50 (very hot functions)

### Inline Limits
- Max inline depth: 3 (prevents deep inline chains)
- Max inline size: 512 bytes (prevents code bloat)

### Never Inline
- Recursive functions
- Functions marked with `.NoInline`
- Functions exceeding size limits

## Statistics

Track inline optimization impact:

```zig
const stats = engine.getStatistics();

std.debug.print("Total functions: {}\n", .{stats.total_functions});
std.debug.print("Inlined: {}\n", .{stats.inlined_functions});
std.debug.print("Inline ratio: {d:.2}%\n", .{stats.inlineRatio() * 100});
std.debug.print("Total inlined size: {} bytes\n", .{stats.total_inlined_size});
```

## Testing

Run the test suite:

```bash
cd packages/inline
zig build test
```

All 9 tests validate:
- Inline hint behavior
- Function metadata and heuristics
- Decision engine functionality
- Statistics calculation
- Cost model analysis
- Transformer operations
- Recursive function handling
- Attribute creation

## Integration

This package integrates with:
- **AST**: Extend `FnDecl` with `is_inline: InlineHint` field
- **Parser**: Parse `inline`, `@always_inline`, `@no_inline` attributes
- **Codegen**: Apply inline transformations during code generation
- **Optimizer**: Use cost model for optimization passes

## Performance Benefits

Inlining provides:
- **Eliminated call overhead**: No function prologue/epilogue
- **Better optimization**: Compiler can optimize across inlined boundaries
- **Reduced stack usage**: No additional stack frames
- **Improved cache locality**: Less instruction cache pressure

Trade-offs:
- **Code size increase**: Inlined functions replicated at call sites
- **Compilation time**: More analysis required
- **Binary bloat**: Aggressive inlining increases binary size

The decision engine balances these trade-offs automatically.
