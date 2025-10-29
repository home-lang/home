# Home Programming Language - Security Hardening Guide

**Date**: 2025-10-24
**Status**: Security Recommendations for Language-Level Hardening

---

## 🎯 Overview

This document outlines security improvements at the **programming language level** (compiler, runtime, type system) beyond the kernel security features already implemented.

Your language already has:
- ✅ Ownership/borrow checking (Rust-style)
- ✅ Unsafe block tracking
- ✅ Type system with dependent types
- ✅ Effect system

---

## 🛡️ Language-Level Security Improvements

### 1. **Enhanced Type System Security**

#### A. Taint Tracking System
**Purpose**: Track untrusted data flow through the program

```zig
// packages/types/src/taint_tracking.zig
pub const TaintLevel = enum {
    Trusted,
    UserInput,
    Network,
    FileSystem,
    Database,
    Untrusted,
};

pub const TaintedType = struct {
    base_type: Type,
    taint_level: TaintLevel,

    pub fn canAssignTo(self: TaintedType, target: TaintedType) bool {
        // Trusted can accept anything
        if (target.taint_level == .Trusted) return false;

        // Cannot assign more tainted to less tainted
        return @intFromEnum(self.taint_level) <= @intFromEnum(target.taint_level);
    }
};
```

**Implementation**:
- Track taint level in type system
- Prevent untrusted data in security-critical contexts
- Require explicit sanitization functions

**Example Usage**:
```home
// Good - sanitized
let user_input: Tainted<String, UserInput> = read_input();
let safe_sql = sanitize_sql(user_input); // Returns Tainted<String, Trusted>
execute_query(safe_sql); // OK

// Bad - unsanitized (compile error)
let user_input: Tainted<String, UserInput> = read_input();
execute_query(user_input); // ERROR: Cannot pass UserInput taint to Trusted parameter
```

#### B. Capability-Based Types
**Purpose**: Embed security capabilities in types

```zig
// packages/types/src/capability_types.zig
pub const Capability = enum {
    ReadFile,
    WriteFile,
    Network,
    Exec,
    // ... 32 capabilities from kernel
};

pub const CapabilitySet = std.EnumSet(Capability);

pub const CapableType = struct {
    base_type: Type,
    required_caps: CapabilitySet,

    pub fn check(self: CapableType, available: CapabilitySet) !void {
        if (!available.containsAll(self.required_caps)) {
            return error.InsufficientCapabilities;
        }
    }
};
```

**Example**:
```home
// Function type includes capabilities
fn open_file(path: String) -> File requires ReadFile {
    // Implementation
}

// Compiler enforces capability check at call site
```

#### C. Information Flow Control
**Purpose**: Prevent information leakage via types

```zig
// packages/types/src/information_flow.zig
pub const SecurityLevel = enum(u8) {
    Public = 0,
    Internal = 1,
    Confidential = 2,
    Secret = 3,
    TopSecret = 4,
};

pub const SecureType = struct {
    base_type: Type,
    security_level: SecurityLevel,

    pub fn canFlowTo(self: SecureType, target: SecureType) bool {
        return @intFromEnum(self.security_level) <= @intFromEnum(target.security_level);
    }
};
```

---

### 2. **Compile-Time Security Checks**

#### A. Integer Overflow Detection
```zig
// packages/safety/src/overflow_check.zig
pub const OverflowChecker = struct {
    pub fn checkAddition(comptime T: type, a: T, b: T) !T {
        var result: T = undefined;
        if (@addWithOverflow(a, b, &result)) {
            return error.IntegerOverflow;
        }
        return result;
    }

    pub fn checkMultiplication(comptime T: type, a: T, b: T) !T {
        var result: T = undefined;
        if (@mulWithOverflow(a, b, &result)) {
            return error.IntegerOverflow;
        }
        return result;
    }
};
```

**Compiler Integration**:
- Insert overflow checks by default (opt-in to unchecked)
- Flag: `--overflow-checks=on` (default)
- Allow `unchecked { }` blocks for performance-critical code

#### B. Null Safety Enforcement
```zig
// packages/types/src/null_safety.zig
pub const NullSafety = enum {
    RequireExplicitNullCheck,
    DisallowNull,
    AllowNull,
};

// Type system integration
pub fn analyzeNullability(expr: *ast.Expr) !NullabilityInfo {
    // Track which expressions can be null
    // Require explicit handling before dereference
}
```

**Example**:
```home
// Compiler enforces null checks
let value: ?i32 = maybe_get_value();

// ERROR: Cannot use value without null check
print(value);

// OK: Explicit null check
if (value) |v| {
    print(v);
}
```

#### C. Array Bounds Checking
```zig
// packages/safety/src/bounds_check.zig
pub fn insertBoundsCheck(
    array_access: *ast.ArrayAccess,
    index_expr: *ast.Expr,
    array_len: *ast.Expr,
) !void {
    // Insert runtime check: if (index >= len) panic
    // Optimize away when provably safe
}
```

---

### 3. **Memory Safety Enhancements**

#### A. Lifetime Analysis
```zig
// packages/safety/src/lifetime_analysis.zig
pub const Lifetime = struct {
    id: u32,
    scope: *Scope,

    pub fn outlives(self: Lifetime, other: Lifetime) bool {
        // Check if self's scope contains other's scope
    }
};

pub const LifetimeChecker = struct {
    pub fn checkReference(
        ref_lifetime: Lifetime,
        referent_lifetime: Lifetime,
    ) !void {
        if (!referent_lifetime.outlives(ref_lifetime)) {
            return error.LifetimeViolation;
        }
    }
};
```

#### B. Use-After-Move Detection
```zig
// packages/safety/src/move_checker.zig
pub const MoveState = enum {
    Initialized,
    Moved,
    Borrowed,
};

pub const MoveChecker = struct {
    states: std.StringHashMap(MoveState),

    pub fn checkMove(self: *MoveChecker, var_name: []const u8) !void {
        const state = self.states.get(var_name) orelse .Initialized;

        if (state == .Moved) {
            return error.UseAfterMove;
        }

        try self.states.put(var_name, .Moved);
    }

    pub fn checkUse(self: *MoveChecker, var_name: []const u8) !void {
        const state = self.states.get(var_name) orelse .Initialized;

        if (state == .Moved) {
            return error.UseAfterMove;
        }
    }
};
```

#### C. Drop Safety
```zig
// packages/safety/src/drop_safety.zig
pub const DropChecker = struct {
    pub fn checkDoubleDrop(value: *Value) !void {
        if (value.is_dropped) {
            return error.DoubleDrop;
        }
        value.is_dropped = true;
    }

    pub fn checkLeaks(scope: *Scope) !void {
        for (scope.values.items) |value| {
            if (value.needs_drop and !value.is_dropped) {
                return error.MemoryLeak;
            }
        }
    }
};
```

---

### 4. **Concurrency Safety**

#### A. Data Race Detection
```zig
// packages/safety/src/race_detector.zig
pub const AccessPattern = struct {
    var_name: []const u8,
    is_write: bool,
    location: SourceLocation,
    thread_id: usize,
};

pub const RaceDetector = struct {
    accesses: std.ArrayList(AccessPattern),

    pub fn checkDataRace(self: *RaceDetector) !void {
        // Sort by variable name
        // Check for conflicting accesses from different threads
        // Report if any write conflicts with read or write
    }
};
```

#### B. Send/Sync Trait System
```zig
// packages/traits/src/concurrency_traits.zig
pub const Send = struct {
    /// Marker trait for types safe to send between threads
    pub fn check(comptime T: type) bool {
        // Check if all fields are Send
        // Check if no interior mutability without sync primitives
    }
};

pub const Sync = struct {
    /// Marker trait for types safe to share between threads
    pub fn check(comptime T: type) bool {
        // Check if immutable or uses proper synchronization
    }
};
```

**Example**:
```home
// Compiler checks Send/Sync at compile time
fn spawn_thread<T: Send>(data: T) -> Thread {
    // OK only if T implements Send
}

fn share_reference<T: Sync>(data: &T) {
    // OK only if T implements Sync
}
```

#### C. Deadlock Detection
```zig
// packages/safety/src/deadlock_detector.zig
pub const LockGraph = struct {
    edges: std.ArrayList(LockEdge),

    pub fn detectCycle(self: *LockGraph) !?[]LockEdge {
        // Find cycles in lock acquisition graph
        // Return cycle if found (potential deadlock)
    }
};
```

---

### 5. **Runtime Security**

#### A. Stack Overflow Protection
```zig
// packages/interpreter/src/stack_guard.zig
pub const StackGuard = struct {
    max_depth: usize,
    current_depth: usize,

    pub fn enterFunction(self: *StackGuard) !void {
        self.current_depth += 1;
        if (self.current_depth > self.max_depth) {
            return error.StackOverflow;
        }
    }

    pub fn exitFunction(self: *StackGuard) void {
        self.current_depth -= 1;
    }
};
```

#### B. Heap Guard Pages
```zig
// packages/interpreter/src/heap_guard.zig
pub const HeapGuard = struct {
    pub fn allocate(size: usize) ![]u8 {
        // Allocate with guard pages before and after
        const total_size = size + 2 * PAGE_SIZE;
        const memory = try allocator.alloc(u8, total_size);

        // Mark guard pages as inaccessible
        try mprotect(memory[0..PAGE_SIZE], PROT_NONE);
        try mprotect(memory[size + PAGE_SIZE..], PROT_NONE);

        return memory[PAGE_SIZE..size + PAGE_SIZE];
    }
};
```

#### C. Fuzzing Support
```zig
// packages/testing/src/property_fuzzer.zig
pub const PropertyFuzzer = struct {
    pub fn fuzz(
        comptime func: anytype,
        property: fn(@TypeOf(func).Args) bool,
        iterations: usize,
    ) !void {
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            const args = generateRandomArgs(@TypeOf(func).Args);
            const result = func(args);

            if (!property(result)) {
                return error.PropertyViolation;
            }
        }
    }
};
```

---

### 6. **Sanitization & Validation**

#### A. Input Validation Framework
```zig
// packages/safety/src/validation.zig
pub const Validator = struct {
    pub fn validateString(
        input: []const u8,
        max_length: usize,
        allowed_chars: []const u8,
    ) ![]const u8 {
        if (input.len > max_length) {
            return error.StringTooLong;
        }

        for (input) |char| {
            if (!mem.containsAtLeast(u8, allowed_chars, 1, &[_]u8{char})) {
                return error.InvalidCharacter;
            }
        }

        return input;
    }

    pub fn validateInteger(
        value: i64,
        min: i64,
        max: i64,
    ) !i64 {
        if (value < min or value > max) {
            return error.OutOfRange;
        }
        return value;
    }
};
```

#### B. SQL Injection Prevention
```zig
// packages/database/src/sql_safe.zig
pub const SqlSafe = struct {
    query: []const u8,
    params: []const Param,

    pub fn prepare(query: []const u8) SqlSafe {
        // Parse query, identify parameters
        // Ensure no string interpolation
        return .{ .query = query, .params = &[_]Param{} };
    }

    pub fn bind(self: *SqlSafe, param: Param) !void {
        // Type-safe parameter binding
        try self.params.append(param);
    }
};
```

**Example**:
```home
// Good - parameterized
let query = SqlSafe.prepare("SELECT * FROM users WHERE id = ?");
query.bind(user_id);
db.execute(query);

// Bad - compile error
let user_input = get_input();
let query = "SELECT * FROM users WHERE name = '" + user_input + "'";
db.execute(query); // ERROR: Raw string concatenation in SQL
```

#### C. XSS Prevention
```zig
// packages/web/src/html_escape.zig
pub const HtmlSafe = struct {
    content: []const u8,

    pub fn escape(raw: []const u8) HtmlSafe {
        // Escape <, >, &, ", '
        return .{ .content = escapeHtml(raw) };
    }

    pub fn raw(unsafe: []const u8) HtmlSafe {
        // Requires explicit opt-in
        @compileLog("Warning: Using raw HTML");
        return .{ .content = unsafe };
    }
};
```

---

### 7. **Secure Coding Patterns**

#### A. Builder Pattern with Validation
```zig
// packages/patterns/src/secure_builder.zig
pub fn SecureBuilder(comptime T: type) type {
    return struct {
        data: T,
        validated: std.EnumSet(ValidatedField),

        pub fn build(self: *@This()) !T {
            // Ensure all required fields are validated
            if (!self.validated.containsAll(required_fields)) {
                return error.IncompleteValidation;
            }
            return self.data;
        }
    };
}
```

#### B. Resource Cleanup with RAII
```zig
// packages/safety/src/raii.zig
pub fn Resource(comptime T: type) type {
    return struct {
        inner: T,
        cleanup: fn(*T) void,

        pub fn acquire(value: T, cleanup_fn: fn(*T) void) @This() {
            return .{ .inner = value, .cleanup = cleanup_fn };
        }

        pub fn deinit(self: *@This()) void {
            self.cleanup(&self.inner);
        }
    };
}
```

---

### 8. **Compiler Hardening Flags**

#### A. Security Compilation Modes
```zig
// build.zig
pub const SecurityLevel = enum {
    None,          // No security checks
    Basic,         // Essential checks only
    Standard,      // Recommended for production
    Paranoid,      // Maximum security, slower
};

pub fn setSecurityLevel(b: *std.Build, level: SecurityLevel) void {
    switch (level) {
        .None => {},
        .Basic => {
            b.addCompileOption("bounds-check", "true");
            b.addCompileOption("overflow-check", "true");
        },
        .Standard => {
            b.addCompileOption("bounds-check", "true");
            b.addCompileOption("overflow-check", "true");
            b.addCompileOption("null-check", "true");
            b.addCompileOption("move-check", "true");
        },
        .Paranoid => {
            b.addCompileOption("bounds-check", "true");
            b.addCompileOption("overflow-check", "true");
            b.addCompileOption("null-check", "true");
            b.addCompileOption("move-check", "true");
            b.addCompileOption("race-detector", "true");
            b.addCompileOption("taint-tracking", "true");
        },
    }
}
```

#### B. Warnings as Errors
```zig
pub const SecurityWarnings = struct {
    treat_as_error: bool = true,

    pub fn check(self: SecurityWarnings, warning: Warning) !void {
        if (self.treat_as_error) {
            return error.SecurityWarning;
        }
    }
};
```

---

### 9. **Standard Library Security**

#### A. Secure Random Number Generator
```zig
// packages/std/src/crypto_random.zig
pub const CryptoRandom = struct {
    pub fn fill(buffer: []u8) !void {
        // Use /dev/urandom or hardware RNG
        // Never use predictable PRNG for security
    }

    pub fn int(comptime T: type) !T {
        var bytes: [@sizeOf(T)]u8 = undefined;
        try fill(&bytes);
        return @bitCast(bytes);
    }
};
```

#### B. Secure String Comparison
```zig
// packages/std/src/crypto.zig
pub fn constantTimeEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;

    var diff: u8 = 0;
    for (a, b) |byte_a, byte_b| {
        diff |= byte_a ^ byte_b;
    }

    return diff == 0;
}
```

#### C. Secure Memory Clearing
```zig
pub fn secureZero(buffer: []u8) void {
    @memset(buffer, 0);
    // Prevent compiler optimization
    asm volatile ("" : : : "memory");
}
```

---

### 10. **Linter Security Rules**

Create a security-focused linter:

```zig
// packages/tools/src/security_linter.zig
pub const SecurityLinter = struct {
    pub fn checkFile(ast: *AST) ![]SecurityIssue {
        var issues = std.ArrayList(SecurityIssue).init(allocator);

        // Check for dangerous patterns
        try checkUnsafeBlocks(ast, &issues);
        try checkStringConcatenation(ast, &issues);
        try checkIntegerOperations(ast, &issues);
        try checkFileOperations(ast, &issues);
        try checkNetworkCalls(ast, &issues);

        return issues.toOwnedSlice();
    }
};
```

**Security Rules**:
- Warn on `unsafe { }` blocks
- Flag string concatenation in SQL/HTML contexts
- Detect potential integer overflows
- Require validation on external input
- Check for timing attack vulnerabilities

---

## 📋 Implementation Priority

### Phase 1: Critical (Implement First)
1. ✅ Overflow checking (your language may already have this)
2. ✅ Null safety enforcement
3. ✅ Array bounds checking
4. ⬜ Taint tracking system
5. ⬜ Use-after-move detection

### Phase 2: High Priority
6. ⬜ Data race detection
7. ⬜ Send/Sync traits
8. ⬜ Stack overflow protection
9. ⬜ Input validation framework
10. ⬜ SQL injection prevention

### Phase 3: Medium Priority
11. ⬜ Capability-based types
12. ⬜ Information flow control
13. ⬜ Lifetime analysis improvements
14. ⬜ Deadlock detection
15. ⬜ Fuzzing support

### Phase 4: Nice-to-Have
16. ⬜ Heap guard pages
17. ⬜ XSS prevention
18. ⬜ Security linter
19. ⬜ Formal verification hooks
20. ⬜ Constant-time guarantee annotations

---

## 🎯 Quick Wins

These can be implemented quickly with high security impact:

1. **Add `--security-level` flag** to compiler
2. **Implement overflow checking** by default
3. **Add taint tracking** to type system
4. **Create security linter** with basic rules
5. **Add bounds checking** optimization

---

## 📚 Resources

### Similar Language Security Features
- **Rust**: Ownership, lifetimes, unsafe blocks
- **Ada/SPARK**: Formal verification, contracts
- **Cyclone**: Region-based memory management
- **TypeScript**: Taint tracking plugins

### Papers
- "Taint Tracking for Program Analysis" (Schwartz et al.)
- "Information Flow Control for Standard OS Abstractions" (Zeldovich et al.)
- "Capability-Based Computer Systems" (Levy)

---

## ✅ Summary

Your language can add these security layers **beyond kernel security**:

1. **Type System**: Taint tracking, capabilities, information flow
2. **Compile-Time**: Overflow, null, bounds, move checking
3. **Memory Safety**: Lifetime analysis, drop safety, leak detection
4. **Concurrency**: Data race, deadlock detection, Send/Sync
5. **Runtime**: Stack guards, heap guards, fuzzing
6. **Validation**: Input sanitization, SQL/XSS prevention
7. **Tooling**: Security linter, compilation modes

This creates a **defense-in-depth** strategy where security is enforced at:
- Hardware level (kernel features)
- OS level (kernel syscalls)
- Language level (compiler/type system)
- Application level (coding patterns)

**Estimated Implementation**: 20-40 hours for Phase 1+2
**Security Impact**: Prevents entire classes of vulnerabilities at compile time
**Performance Impact**: Minimal (most checks compile to zero cost)
