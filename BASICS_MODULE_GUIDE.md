# Home Basics Module

> **A friendly, Home-style wrapper around core functionality**

---

## 🎯 What is Basics?

`Basics` is Home's answer to Zig's `std` library. Instead of the generic "standard library" naming, Home uses **Basics** - a more welcoming, descriptive name that aligns with our philosophy of making programming feel like home.

```zig
// Instead of this:
const std = @import("std");

// Home uses this:
const Basics = @import("basics");
```

---

## 🌟 Why Basics?

### More Welcoming
- "Basics" is friendly and descriptive
- Easier for newcomers to understand
- Aligns with Home's philosophy

### Same Power
- Full access to all core functionality
- Zero overhead - just a naming wrapper
- All Zig std features available

### Home Conventions
- Follows Home's naming style
- Includes Home-specific helpers
- Better developer experience

---

## 📚 API Overview

### Core Imports

```zig
const Basics = @import("basics");

// Common types
Basics.Allocator
Basics.ArrayList
Basics.HashMap
Basics.StringHashMap
Basics.AutoHashMap
```

### Memory Management

```zig
// Allocators
const allocator = Basics.heap.page_allocator;
var gpa = Basics.heap.GeneralPurposeAllocator(.{}){};
var arena = Basics.heap.ArenaAllocator.init(allocator);

// Memory operations
Basics.mem.eql(u8, "hello", "hello")  // true
Basics.mem.copy(u8, dest, source)
Basics.mem.indexOf(u8, haystack, needle)
Basics.mem.startsWith(u8, str, prefix)
Basics.mem.endsWith(u8, str, suffix)
```

### Debug & Printing

```zig
// Print functions
Basics.debug.print("Hello, {s}!\n", .{"World"});
Basics.debug.assert(condition);

// Home-friendly shortcuts
Basics.print("Value: {d}\n", .{42});
Basics.println("Hello, {s}!", .{"World"});  // Adds newline automatically
```

### Formatting

```zig
// Parse values
const num = try Basics.fmt.parseInt(i32, "42", 10);
const float = try Basics.fmt.parseFloat(f64, "3.14");

// Format strings
const str = try Basics.fmt.allocPrint(allocator, "Value: {d}", .{42});
```

### Math Operations

```zig
Basics.math.min(10, 20)      // 10
Basics.math.max(10, 20)      // 20
Basics.math.abs(-42)         // 42
Basics.math.sqrt(16)         // 4
Basics.math.pow(f64, 2, 3)   // 8
Basics.math.sin(Basics.math.pi)
Basics.math.cos(Basics.math.pi)
Basics.math.ceil(3.2)        // 4
Basics.math.floor(3.8)       // 3
Basics.math.round(3.5)       // 4
```

### File System

```zig
// File operations
const file = try Basics.fs.cwd().openFile("data.txt", .{});
defer file.close();

const dir = try Basics.fs.cwd().openDir("mydir", .{});
try Basics.fs.cwd().makePath("path/to/dir");
```

### Networking

```zig
// TCP server
var server = Basics.net.StreamServer.init(.{});
try server.listen(Basics.net.Address.parseIp("127.0.0.1", 8080) catch unreachable);

const conn = try server.accept();
defer conn.stream.close();
```

### Time Operations

```zig
// Timestamps
const now = Basics.time.timestamp();         // seconds
const millis = Basics.time.milliTimestamp(); // milliseconds
const nanos = Basics.time.nanoTimestamp();   // nanoseconds

// Sleep
Basics.time.sleep(1_000_000_000);  // Sleep 1 second

// Home-friendly shortcuts
const now = Basics.now();           // seconds
const millis = Basics.nowMillis();  // milliseconds
Basics.sleepMs(500);                // Sleep 500ms
Basics.sleepSec(2);                 // Sleep 2 seconds
```

### Threading

```zig
// Spawn threads
const thread = try Basics.Thread.spawn(.{}, myFunction, .{});
thread.join();

// Synchronization
var mutex = Basics.Thread.Mutex{};
var rwlock = Basics.Thread.RwLock{};
```

### JSON

```zig
// Parse JSON
const parsed = try Basics.json.parseFromSlice(MyStruct, allocator, json_string, .{});
defer parsed.deinit();

// Stringify
const json = try Basics.json.stringifyAlloc(allocator, data, .{});
defer allocator.free(json);
```

### Cryptography

```zig
// Hashing
var hash = Basics.crypto.hash.sha256.init(.{});
hash.update("Hello, World!");
const digest = hash.final();

// Random
const random = Basics.crypto.random.int(u64);
```

### Testing

```zig
test "example test" {
    try Basics.testing.expect(true);
    try Basics.testing.expectEqual(42, 42);
    try Basics.testing.expectEqualStrings("hello", "hello");
}
```

---

## 🚀 Home-Specific Extensions

### Friendly Print Functions

```zig
// Print with automatic newline
Basics.println("Count: {d}", .{count});

// Regular print (no newline)
Basics.print("Loading", .{});
```

### String Operations

```zig
// Easy string equality
if (Basics.strEql(name, "Alice")) {
    // ...
}
```

### Time Helpers

```zig
// Get current time
const timestamp = Basics.now();        // seconds
const millis = Basics.nowMillis();     // milliseconds

// Sleep convenience functions
Basics.sleepMs(100);   // Sleep 100 milliseconds
Basics.sleepSec(2);    // Sleep 2 seconds
```

### Allocator Helpers

```zig
// Create allocators easily
var gpa = Basics.createAllocator();
defer _ = gpa.deinit();

var arena = Basics.createArena(Basics.heap.page_allocator);
defer arena.deinit();
```

### Type Aliases

```zig
// Friendly type names
const name: Basics.String = "Alice";           // []const u8
const buffer: Basics.MutableString = &[_]u8{}; // []u8
const count: Basics.Integer = 42;              // i64
const price: Basics.Float = 19.99;             // f64
const active: Basics.Boolean = true;           // bool
```

### Result Type

```zig
pub fn divide(a: i32, b: i32) Basics.Result(i32) {
    if (b == 0) {
        return .{ .err = Basics.Error.InvalidInput };
    }
    return .{ .ok = @divTrunc(a, b) };
}

const result = divide(10, 2);
if (result.isOk()) {
    const value = result.unwrap();
}
```

### Option Type

```zig
pub fn findUser(id: i64) Basics.Option(User) {
    const user = getUserById(id);
    if (user) |u| {
        return .{ .some = u };
    }
    return .{ .none = {} };
}

const maybe_user = findUser(123);
if (maybe_user.isSome()) {
    const user = maybe_user.unwrap();
}
```

---

## 🎨 Complete Example

```zig
const Basics = @import("basics");

pub fn main() !void {
    // Create allocator
    var gpa = Basics.createAllocator();
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Friendly printing
    Basics.println("Welcome to Home!", .{});

    // String operations
    const name = "Alice";
    if (Basics.strEql(name, "Alice")) {
        Basics.println("Hello, {s}!", .{name});
    }

    // Collections
    var list = Basics.ArrayList(i32).init(allocator);
    defer list.deinit();

    try list.append(10);
    try list.append(20);
    try list.append(30);

    // Math
    const sum = Basics.math.min(10, 20) + Basics.math.max(30, 40);
    Basics.println("Sum: {d}", .{sum});

    // Time
    const timestamp = Basics.now();
    Basics.println("Current time: {d}", .{timestamp});

    // Sleep
    Basics.println("Waiting...", .{});
    Basics.sleepMs(500);
    Basics.println("Done!", .{});

    // Option type
    const user = findUser(123);
    if (user.isSome()) {
        Basics.println("Found user: {s}", .{user.unwrap().name});
    } else {
        Basics.println("User not found", .{});
    }

    // Result type
    const result = divide(10, 2);
    if (result.isOk()) {
        Basics.println("Result: {d}", .{result.unwrap()});
    } else {
        Basics.println("Error occurred", .{});
    }
}

fn findUser(id: i64) Basics.Option(User) {
    // Stub implementation
    _ = id;
    return .{ .none = {} };
}

fn divide(a: i32, b: i32) Basics.Result(i32) {
    if (b == 0) {
        return .{ .err = Basics.Error.InvalidInput };
    }
    return .{ .ok = @divTrunc(a, b) };
}

const User = struct {
    id: i64,
    name: []const u8,
};
```

---

## 🆚 Comparison

### Zig (std)
```zig
const std = @import("std");

std.debug.print("Hello\n", .{});
const equal = std.mem.eql(u8, a, b);
const timestamp = std.time.timestamp();
std.time.sleep(1_000_000_000);
```

### Home (Basics)
```zig
const Basics = @import("basics");

Basics.println("Hello", .{});
const equal = Basics.strEql(a, b);
const timestamp = Basics.now();
Basics.sleepSec(1);
```

**Benefits:**
- ✅ More descriptive names
- ✅ Friendly helper functions
- ✅ Same performance (zero overhead)
- ✅ Better beginner experience

---

## 📦 Module Organization

### Memory (`Basics.mem`)
- Allocator types
- Memory operations
- String utilities

### Heap (`Basics.heap`)
- Allocator implementations
- Memory management

### Debug (`Basics.debug`)
- Printing
- Assertions
- Debugging tools

### Format (`Basics.fmt`)
- String formatting
- Parsing

### Math (`Basics.math`)
- Mathematical operations
- Constants (pi, e)

### File System (`Basics.fs`)
- File operations
- Directory management

### Network (`Basics.net`)
- TCP/UDP
- Address handling

### Time (`Basics.time`)
- Timestamps
- Sleep functions
- Timers

### Threading (`Basics.Thread`)
- Thread spawning
- Synchronization primitives

### JSON (`Basics.json`)
- Parsing
- Serialization

### Crypto (`Basics.crypto`)
- Hashing
- Random generation

### Testing (`Basics.testing`)
- Test utilities
- Assertions

---

## 🎯 Design Philosophy

### 1. Friendly Naming
- Use descriptive, welcoming names
- Avoid abbreviations where possible
- Make code self-documenting

### 2. Convenience Without Sacrifice
- Add helpful shortcuts
- Never sacrifice performance
- Zero-overhead abstractions

### 3. Gradual Learning
- Start with simple helpers
- Access advanced features when needed
- Progressive complexity

### 4. Home Style
- Follow Home conventions
- Integrate with Home ecosystem
- Feel at home in Home

---

## 🚀 Migration Guide

### From Zig std to Home Basics

1. **Change import:**
   ```zig
   // Before
   const std = @import("std");

   // After
   const Basics = @import("basics");
   ```

2. **Use friendly helpers:**
   ```zig
   // Before
   std.debug.print("Hello\n", .{});

   // After
   Basics.println("Hello", .{});
   ```

3. **Leverage Home extensions:**
   ```zig
   // Before
   if (std.mem.eql(u8, a, b)) { }

   // After
   if (Basics.strEql(a, b)) { }
   ```

4. **Enjoy the same power:**
   - All `std` functionality available through `Basics`
   - Zero performance overhead
   - Same capabilities, better DX

---

## 🎉 Summary

The **Basics** module provides:

✅ **Friendly naming** - "Basics" instead of "std"
✅ **Home-style helpers** - `println()`, `strEql()`, `now()`
✅ **Type aliases** - `String`, `Integer`, `Float`
✅ **Result/Option types** - Rust-style error handling
✅ **Zero overhead** - Pure naming wrapper
✅ **Full compatibility** - All std features available
✅ **Better DX** - More welcoming for beginners

**Result**: The power of Zig's std with Home's friendly touch!

---

*Home Programming Language - Basics Module*
*Making core functionality feel like home*
*Version 1.0.0*
