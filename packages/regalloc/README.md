# Register Allocation Hints Package

Comprehensive register allocation support with manual optimization hints for the Home programming language. Enables fine-grained control over register usage for performance-critical code.

## Features

### Architecture Support
- **x86-64**: 16 general purpose registers (rax-r15)
- **AArch64**: 31 general purpose registers (x0-x30)
- **RISC-V**: 32 general purpose registers (x0-x31)

Each architecture tracks:
- Total register count
- Caller-saved registers (temporary values)
- Callee-saved registers (preserved across calls)

### Register Classes
- **General**: Integer/pointer registers
- **Float**: Floating-point registers (xmm, v, f)
- **Vector**: SIMD/vector registers (ymm, v)
- **Special**: Stack pointer, frame pointer

### Register Hints

#### Hint Types
- **None**: No preference, compiler decides
- **Prefer**: Suggest specific register (fallback to others)
- **Require**: Force specific register (error if unavailable)
- **Avoid**: Prevent using specific register
- **AnyInClass**: Any register in the class
- **CallerSaved**: Prefer temporary registers
- **CalleeSaved**: Prefer preserved registers

#### Constraint API

```zig
const regalloc = @import("regalloc");

// No preference
const none = regalloc.RegisterConstraint.none(.x86_64);

// Prefer register 5 (rbp on x86-64)
const prefer = regalloc.RegisterConstraint.prefer(.x86_64, .General, 5);

// Require specific register (syscall number in rax)
const require = regalloc.RegisterConstraint.require(.x86_64, .General, 0);

// Avoid stack pointer
const avoid = regalloc.RegisterConstraint.avoid(.x86_64, .General, 4);

// Any general purpose register
const any_gp = regalloc.RegisterConstraint.anyInClass(.x86_64, .General);

// Prefer caller-saved (for temp values)
const temp = regalloc.RegisterConstraint.callerSaved(.x86_64, .General);

// Prefer callee-saved (for loop counters)
const preserved = regalloc.RegisterConstraint.calleeSaved(.x86_64, .General);
```

### Live Range Analysis

Track variable lifetimes to determine register allocation:

```zig
const range = regalloc.LiveRange{
    .start = 10,  // First use
    .end = 50,    // Last use
    .variable = "loop_counter",
};

// Check if ranges overlap (variables need different registers)
const overlap = range1.overlaps(range2);

// Check if variable is live at point
const is_live = range.contains(30);

// Get lifetime length
const length = range.length(); // 40 instructions
```

### Register Allocator

Complete register allocation with constraint satisfaction:

```zig
const allocator = std.heap.page_allocator;

// Initialize allocator for x86-64
var ralloc = try regalloc.RegisterAllocator.init(allocator, .x86_64);
defer ralloc.deinit();

// Add constraints
try ralloc.addConstraint("loop_var",
    regalloc.RegisterConstraint.calleeSaved(.x86_64, .General));

try ralloc.addConstraint("syscall_num",
    regalloc.RegisterConstraint.require(.x86_64, .General, 0)); // rax

// Set live ranges
try ralloc.setLiveRange("loop_var", .{
    .start = 0,
    .end = 100,
    .variable = "loop_var",
});

// Allocate registers
const reg = try ralloc.allocate("loop_var");
if (reg) |r| {
    std.debug.print("Allocated register {}\n", .{r});
} else {
    // Need to spill - no registers available
}

// Free when done
ralloc.free(reg.?);

// Get statistics
const stats = ralloc.getStatistics();
std.debug.print("Using {}/{} registers ({d:.1}%)\n", .{
    stats.allocated_registers,
    stats.total_registers,
    stats.utilizationRatio() * 100,
});
```

### Spill Cost Optimization

Guide spilling decisions with priority hints:

```zig
// Set custom spill weight (higher = keep in register)
try ralloc.setSpillWeight("hot_loop_var", 1000.0);
try ralloc.setSpillWeight("cold_temp", 1.0);

// Calculate spill cost (based on live range or custom weight)
const cost = ralloc.spillCost("hot_loop_var");
```

### Interference Graph

Graph coloring for optimal allocation:

```zig
var graph = regalloc.InterferenceGraph.init(allocator);
defer graph.deinit();

// Add interference edges (variables that are live simultaneously)
try graph.addEdge("x", "y");  // x and y need different registers
try graph.addEdge("y", "z");

// Query interference
const do_interfere = graph.interfere("x", "y"); // true

// Get degree (number of interfering variables)
const degree = graph.getDegree("y"); // 2 (interferes with x and z)
```

### Profiling-Guided Allocation

Use runtime profiling to prioritize register allocation:

```zig
const profiling = regalloc.ProfilingData{
    .variable = "i",
    .access_count = 10000,      // Hot variable
    .loop_depth = 3,            // Deep in nested loops
    .is_induction_variable = true, // Loop counter
};

// Calculate priority (higher = more important to keep in register)
const priority = profiling.calculatePriority();
// Priority: 10000 * (2^3) * 1.5 = 120000
```

Priority calculation:
- Base priority from access count
- Multiplied by 2^(loop_depth) for nested loops
- Multiplied by 1.5 for induction variables

## Usage Examples

### Example 1: System Call

```zig
// System calls on x86-64 require specific registers:
// syscall number in rax, args in rdi, rsi, rdx, r10, r8, r9

var ralloc = try regalloc.RegisterAllocator.init(allocator, .x86_64);
defer ralloc.deinit();

// Syscall number must be in rax (register 0)
try ralloc.addConstraint("syscall_num",
    regalloc.RegisterConstraint.require(.x86_64, .General, 0));

// First argument in rdi (register 7)
try ralloc.addConstraint("arg1",
    regalloc.RegisterConstraint.require(.x86_64, .General, 7));

const num_reg = try ralloc.allocate("syscall_num");
const arg_reg = try ralloc.allocate("arg1");
```

### Example 2: Hot Loop Optimization

```zig
// Loop counter should stay in a callee-saved register
try ralloc.addConstraint("i",
    regalloc.RegisterConstraint.calleeSaved(.x86_64, .General));

// Set high spill weight (accessed 1000 times per iteration)
try ralloc.setSpillWeight("i", 10000.0);

// Temporary calculation can use caller-saved
try ralloc.addConstraint("temp",
    regalloc.RegisterConstraint.callerSaved(.x86_64, .General));
```

### Example 3: Avoiding Conflicts

```zig
// Variable x needs register, avoid rsp (stack pointer)
try ralloc.addConstraint("x",
    regalloc.RegisterConstraint.avoid(.x86_64, .General, 4));

// Prefer rbx for preserved value
try ralloc.addConstraint("preserved",
    regalloc.RegisterConstraint.prefer(.x86_64, .General, 3));
```

### Example 4: SIMD Operations

```zig
// Allocate vector registers for SIMD
try ralloc.addConstraint("vec_a",
    regalloc.RegisterConstraint.anyInClass(.x86_64, .Vector));

try ralloc.addConstraint("vec_b",
    regalloc.RegisterConstraint.anyInClass(.x86_64, .Vector));
```

## Architecture-Specific Details

### x86-64 Registers

**Caller-saved (9):** rax, rcx, rdx, rsi, rdi, r8-r11
- Use for temporary values
- Not preserved across function calls

**Callee-saved (7):** rbx, rbp, r12-r15
- Preserved across function calls
- Good for loop counters and long-lived variables

**Special:** rsp (stack pointer), rip (instruction pointer)

### AArch64 Registers

**Caller-saved (18):** x0-x17
- x0-x7: Argument/result registers
- x8-x17: Temporary registers

**Callee-saved (11):** x19-x29
- x29: Frame pointer
- x30: Link register

**Special:** x31 (stack pointer/zero register)

### RISC-V Registers

**Caller-saved (15):** t0-t6, a0-a7
- a0-a7: Arguments/results
- t0-t6: Temporaries

**Callee-saved (12):** s0-s11
- s0: Frame pointer

## Testing

Run the test suite:

```bash
cd packages/regalloc
zig build test
```

All 9 tests validate:
- Architecture register counts
- Register constraint creation and validation
- Live range overlap detection
- Register allocation with constraints
- Conflict resolution
- Spill cost calculation
- Interference graph operations
- Profiling priority calculation
- Register class counts

## Integration

This package integrates with:
- **Codegen**: Apply register hints during code generation
- **Optimizer**: Use interference graphs for optimization
- **AST**: Extend with register hint annotations
- **Profiler**: Feed runtime data into allocation decisions

## Performance Benefits

Register allocation provides:
- **Reduced memory access**: Keep hot variables in registers
- **Lower latency**: Register access is ~100x faster than L1 cache
- **Better instruction selection**: More opportunities for register-based instructions
- **Reduced code size**: Fewer load/store instructions

Trade-offs:
- **Spilling overhead**: May need to save/restore when out of registers
- **Increased complexity**: Manual hints require understanding of architecture
- **Portability**: Hints may need adjustment for different architectures

## Best Practices

1. **Use caller-saved for temporaries**: Short-lived values that don't cross calls
2. **Use callee-saved for loop variables**: Long-lived values accessed frequently
3. **Set spill weights based on profiling**: Prioritize hot variables
4. **Build interference graphs**: Understand which variables conflict
5. **Prefer hints over requirements**: Allow compiler flexibility
6. **Validate constraints**: Ensure hints are architecturally valid
