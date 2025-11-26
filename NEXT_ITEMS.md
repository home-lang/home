# Next 3 Recommended Implementation Items (Session 4)

Generated: 2025-11-26
Status: Ready for selection

---

## Option 1: Memory Safety Integration (Borrow Checker)

**Priority**: High
**Effort**: Large (~600 lines, 2-3 files)
**Status**: Partial (borrow checker exists but not fully integrated)

### What's Already Done
- ✅ Borrow checker implementation in `/packages/types/src/ownership.zig` (400+ lines)
- ✅ OwnershipTracker with move semantics
- ✅ Lifetime tracking infrastructure

### What Needs to Be Implemented
1. **Integration with Type Checker**: Connect borrow checker to type system
2. **Compiler Integration**: Add borrow checking pass to compilation pipeline
3. **Error Reporting**: Enhanced error messages for borrow check failures
4. **Lifetime Elision**: Automatic lifetime inference for common patterns
5. **Unsafe Blocks**: Support for `unsafe { }` blocks to bypass checks

### Why This Matters
- **Eliminates entire categories of bugs** (use-after-free, double-free, data races)
- Provides Rust-like memory safety without garbage collection
- Critical for systems programming and OS development
- Enables fearless concurrency

### Files to Modify/Create
- `/packages/types/src/ownership.zig` (enhance integration - ~200 lines)
- `/packages/compiler/src/borrow_check_pass.zig` (new - ~300 lines)
- `/packages/diagnostics/src/borrow_errors.zig` (new - ~100 lines)

### Example Impact
```home
// Before: Compiles but crashes at runtime
let data = vec![1, 2, 3];
let ptr = &data[0];
data.push(4);  // Reallocates!
println(*ptr); // Use-after-free 💥

// After: Compile error with helpful message
error[E0502]: cannot borrow `data` as mutable because it is also borrowed as immutable
  --> src/main.home:3:1
   |
2  | let ptr = &data[0];
   |           ---- immutable borrow occurs here
3  | data.push(4);
   | ^^^^^^^^^^^^ mutable borrow occurs here
4  | println(*ptr);
   |         ---- immutable borrow later used here
```

---

## Option 2: Incremental Compilation System

**Priority**: High
**Effort**: Medium-Large (~500 lines, 2-3 files)
**Status**: Partial (IR cache exists, metadata serialization incomplete)

### What's Already Done
- ✅ IR cache infrastructure in `/packages/cache/`
- ✅ Basic caching layer
- ✅ File change detection

### What Needs to Be Implemented
1. **Metadata Serialization**: Serialize/deserialize compilation artifacts
2. **Dependency Tracking**: Track file dependencies for invalidation
3. **Incremental Type Checking**: Cache type information between builds
4. **Module Fingerprinting**: Content-based hashing for change detection
5. **Cache Management**: LRU eviction, size limits, cleanup

### Why This Matters
- **Dramatically faster rebuild times** (seconds instead of minutes)
- Essential for large projects and rapid iteration
- Improves developer experience significantly
- Industry standard (Rust, Go, TypeScript all have incremental compilation)

### Files to Modify/Create
- `/packages/cache/src/incremental.zig` (new - ~300 lines)
- `/packages/compiler/src/metadata_serializer.zig` (new - ~200 lines)
- `/packages/cache/src/dependency_tracker.zig` (enhance - ~150 lines)

### Expected Speedup
```
Initial build:  45 seconds
After change:
  - Without incremental: 45 seconds (full rebuild)
  - With incremental:     2 seconds (only changed modules) 🚀
```

---

## Option 3: Networking Layer Completion

**Priority**: High (marked as "Partial" in TODO-UPDATES.md)
**Effort**: Medium (~400 lines, 2-3 files)
**Status**: Partial (basic TCP/UDP exists, missing high-level features)

### What's Already Done
- ✅ Basic TCP/UDP sockets (`/packages/network/src/network.zig`)
- ✅ IPv4 address parsing
- ✅ TcpStream and TcpListener
- ✅ UdpSocket

### What Needs to Be Implemented
1. **IPv6 Support**: Full IPv6 addressing and dual-stack operation
2. **DNS Resolution**: Async DNS lookups (A, AAAA, CNAME records)
3. **Connection Pooling**: Reusable connections for HTTP clients
4. **Non-blocking I/O**: Integration with async runtime
5. **TLS Integration**: Connect networking with HTTP TLS layer

### Why This Matters
- **Enables modern network applications**
- Required for production HTTP/RPC services
- IPv6 is increasingly important
- Async networking critical for scalability

### Files to Modify/Create
- `/packages/network/src/network.zig` (enhance IPv6 - ~100 lines)
- `/packages/network/src/dns.zig` (new - ~250 lines)
- `/packages/network/src/pool.zig` (new - ~150 lines)

### Example Code After Completion
```home
// DNS resolution
let addresses = await dns.lookup("example.com")?;

// IPv6 support
let server = TcpListener::bind("[::1]:8080")?;

// Connection pooling
let pool = ConnectionPool::new(config);
let conn = await pool.get("example.com:443")?;

// Non-blocking async
let stream = await TcpStream::connect_async("example.com:80")?;
```

---

## Recommendation

Based on priority and impact:

1. **Option 1 (Memory Safety)** - Highest impact on reliability and safety
2. **Option 2 (Incremental Compilation)** - Biggest developer experience improvement
3. **Option 3 (Networking)** - Completes a partial feature marked as High priority

However, choose based on your goals:
- Want Rust-like safety? → **Option 1**
- Want faster builds? → **Option 2**
- Want complete networking? → **Option 3**

---

**Current Progress**: 145 of 180 TODOs complete (80%)
**Session 3 Delivered**: 1,945 lines across 3 major systems
**Ready for Session 4**: Pick your number (1, 2, 3, or "all 3")
