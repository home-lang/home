# Home Language - Comprehensive TODO & Improvements

> A complete catalog of all TODOs, improvements, and enhancements found throughout the Home programming language codebase.  
> Generated: 2025-11-24

---

## Table of Contents

1. [Core Compiler](#1-core-compiler)
2. [Code Generation](#2-code-generation)
3. [Type System](#3-type-system)
4. [Parser](#4-parser)
5. [Interpreter](#5-interpreter)
6. [Language Server (LSP)](#6-language-server-lsp)
7. [Testing Framework](#7-testing-framework)
8. [Build System](#8-build-system)
9. [Package Manager](#9-package-manager)
10. [Kernel & OS](#10-kernel--os)
11. [Drivers](#11-drivers)
12. [Networking](#12-networking)
13. [Graphics & Input](#13-graphics--input)
14. [AST & Macros](#14-ast--macros)
15. [Documentation](#15-documentation)
16. [Async Runtime](#16-async-runtime)
17. [Debugger](#17-debugger)
18. [Comptime](#18-comptime)
19. [Standard Library](#19-standard-library)
20. [General Improvements](#20-general-improvements)

---

## 1. Core Compiler

### `src/main.zig`

| Priority | Location | Description | Status |
|----------|----------|-------------|--------|
| ~~High~~ | ~~Line 1123~~ | ~~**Implement actual test execution** - Currently only validates test existence, doesn't run test functions~~ | ✅ DONE |
| ~~Medium~~ | ~~Line 1898~~ | ~~**Parse home.toml for scripts** - `pkg run` command needs to read actual scripts from config~~ | ✅ DONE |
| ~~Medium~~ | ~~Line 1919~~ | ~~**Parse home.toml for available scripts** - `pkg scripts` shows hardcoded examples~~ | ✅ DONE |

---

## 2. Code Generation

### `packages/codegen/src/native_codegen.zig`

| Priority | Location | Description | Status |
|----------|----------|-------------|--------|
| ~~High~~ | ~~Line 2013~~ | ~~**Create array slice for rest patterns** - Rest pattern (`...rest`) binds whole array pointer instead of remaining elements~~ | ✅ DONE |
| ~~High~~ | ~~Line 3264~~ | ~~**Implement proper break** - Break statement is a no-op, needs loop exit position tracking~~ | ✅ DONE |
| ~~High~~ | ~~Line 3268~~ | ~~**Implement proper continue** - Continue statement is a no-op, needs loop start position tracking~~ | ✅ DONE |
| ~~High~~ | ~~Line 3272~~ | ~~**Implement proper assertion** - AssertStmt skipped in release mode, needs runtime check in debug~~ | ✅ DONE |
| ~~Medium~~ | ~~Line 4881~~ | ~~**Implement floating point sqrt** - Math.sqrt returns value unchanged (placeholder)~~ | ✅ DONE |
| ~~Medium~~ | ~~Line 4964~~ | ~~**Implement proper NaN/Inf check** - `is_finite` always returns true~~ | ✅ DONE |
| ~~Low~~ | ~~Line 5321~~ | ~~**String literal support in comptime** - String constants need data section support~~ | ✅ DONE |
| ~~Low~~ | ~~Line 2100~~ | ~~**Complex patterns** - Range patterns in match expressions~~ | ✅ DONE |

### `packages/codegen/src/home_kernel_codegen.zig`

| Priority | Location | Description | Status |
|----------|----------|-------------|--------|
| ~~Medium~~ | ~~Line 121~~ | ~~**Store variables on stack** - Let declarations don't track stack offsets~~ | ✅ DONE |
| ~~Medium~~ | ~~Line 209~~ | ~~**Collect string literals for .rodata** - String data emitted inline, should be in data section~~ | ✅ DONE |
| ~~Medium~~ | ~~Line 298~~ | ~~**Track variable offsets** - Identifier loads don't have proper stack tracking~~ | ✅ DONE |

### `packages/codegen/src/llvm_backend.zig`

| Priority | Location | Description | Status |
|----------|----------|-------------|--------|
| ~~High~~ | ~~Line 97~~ | ~~**Handle other statement types** - Only FunctionDecl, StructDecl, EnumDecl implemented~~ | ✅ DONE |
| ~~High~~ | ~~Line 127~~ | ~~**Generate function body statements** - Function bodies are empty~~ | ✅ DONE |
| Medium | Line 159 | **Implement enum generation** - Enums as tagged unions not implemented | TODO |

### `packages/codegen/src/async_transform.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| High | Line 189 | **Proper liveness analysis** - Live variables at await points not tracked |
| High | Line 427 | **Actual poll logic** - Await state machine has placeholder poll |

### `packages/codegen/src/type_guided_optimizations.zig`

| Priority | Location | Description | Status |
|----------|----------|-------------|--------|
| Medium | Line 49 | ~~**Track constant values** - Identifier constant propagation incomplete~~ | ✅ DONE |
| Medium | Line 98 | ~~**Check equal constants** - Binary comparison optimization incomplete~~ | ✅ DONE |
| Medium | Line 160 | ~~**Calculate struct size** - Struct size returns default pointer size~~ | ✅ DONE |

### `packages/codegen/src/instruction_selection.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| Low | Line 136 | **Detect shift operand** - ARM64 shift+add pattern detection |

### `packages/codegen/src/move_checker.zig`

| Priority | Location | Description | Status |
|----------|----------|-------------|--------|
| Medium | Line 206 | ~~**Get actual type** - Move checker uses "unknown" type placeholder~~ | ✅ DONE |

### `packages/codegen/src/type_integration.zig`

| Priority | Location | Description | Status |
|----------|----------|-------------|--------|
| Medium | Line 119 | ~~**Full parameter type inference** - Only uses annotated types~~ | ✅ DONE |

---

## 3. Type System

### `packages/types/src/type_inference.zig`

| Priority | Location | Description | Status |
|----------|----------|-------------|--------|
| High | Line 374 | ~~**Struct field type lookup** - MemberExpr returns fresh type variable~~ | ✅ DONE |
| High | Line 407 | ~~**Parse type annotation** - Closure parameter types not parsed~~ | ✅ DONE |
| High | Line 418 | ~~**Parse return type annotation** - Closure return types not parsed~~ | ✅ DONE |
| Medium | Line 482 | ~~**Check trait bounds** - Trait bound constraints not verified~~ | ✅ DONE |

### `packages/types/src/trait_checker.zig`

| Priority | Location | Description | Status |
|----------|----------|-------------|--------|
| High | Line 167 | ~~**Verify parameter/return types match** - Trait method signature validation incomplete~~ | ✅ DONE |
| Medium | Line 203 | ~~**Verify type satisfies bounds** - Associated type bounds not checked~~ | ✅ DONE |
| Medium | Line 260 | **Get actual location** - Error locations hardcoded to 0,0 | |
| Medium | Line 315 | ~~**Verify method signature** - Self type usage validation incomplete~~ | ✅ DONE |

### `packages/types/src/error_handling.zig`

| Priority | Location | Description | Status |
|----------|----------|-------------|--------|
| Medium | Line 95 | ~~**Trait-based error conversion** - From/Into traits not implemented~~ | ✅ DONE |
| Medium | Line 169 | ~~**Check From trait implementation** - Error conversion incomplete~~ | ✅ DONE |
| Medium | Line 178 | ~~**Generate conversion code** - From trait codegen not implemented~~ | ✅ DONE |
| Medium | Line 205 | ~~**Analyze control flow** - Result return path analysis incomplete~~ | ✅ DONE |

### `packages/types/src/generics.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| High | Line 123 | **Create monomorphized AST** - Generic instantiation only registers, doesn't create AST |

---

## 4. Parser

### `packages/parser/src/parser.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| Low | Line 1188 | **Remove debug logging** - Module resolution logs to stdout |

### `packages/parser/src/closure_parser.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| Medium | Line 79 | **Support async closures** - `is_async` hardcoded to false |
| Medium | Line 227 | **Analyze for purity** - Closure purity analysis not implemented |
| Medium | Line 228 | **Detect recursion** - Recursive closure detection not implemented |
| Medium | Line 240 | **Walk expression tree** - Capture analysis for expressions incomplete |
| Medium | Line 244 | **Walk block statements** - Capture analysis for blocks incomplete |

---

## 5. Interpreter

### `packages/interpreter/src/interpreter.zig`

| Priority | Location | Description | Status |
|----------|----------|-------------|--------|
| High | Line 371 | ~~**Handle labeled breaks** - Break labels ignored~~ | ✅ DONE |
| High | Line 376 | ~~**Handle labeled continues** - Continue labels ignored~~ | ✅ DONE |
| High | Line 770 | **Implement compound assignment targets** - Array/struct field assignment not supported | |
| Medium | Line 753 | **Pointer operations** - Deref, AddressOf, Borrow, BorrowMut not implemented | |

### `packages/interpreter/src/debugger.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| High | Line 262 | **Implement step over logic** - StepOver command incomplete |
| High | Line 266 | **Implement step in logic** - StepIn command incomplete |
| High | Line 270 | **Implement step out logic** - StepOut command incomplete |
| High | Line 277 | **Implement expression evaluation** - Evaluate command incomplete |
| High | Line 280 | **Implement variable retrieval** - GetVariable command incomplete |
| High | Line 283 | **Implement variable modification** - SetVariable command incomplete |

---

## 6. Language Server (LSP)

### `packages/lsp/src/lsp.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| High | Line 269 | **Semantic analysis** - Type checking, undefined variables not implemented |
| High | Line 312 | **Add symbols from AST** - Completions don't include functions/variables/structs |
| High | Line 324 | **Implement symbol resolution** - Go to definition not implemented |
| High | Line 336 | **Implement reference finding** - Find all references not implemented |
| Medium | Line 408 | **Provide type information** - Hover documentation not implemented |
| Medium | Line 417 | **Use formatter package** - Document formatting returns unchanged text |

---

## 7. Testing Framework

### `packages/testing/src/cli.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| High | Line 71 | **Run discovered tests** - Test discovery doesn't execute tests |

### `packages/testing/src/vitest.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| Low | Various | **TODO test support** - `todo` tests are tracked but implementation is complete |

---

## 8. Build System

### `packages/build/src/lto.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| High | Line 280 | **Parse IR for exports/imports** - LTO analysis simulated |
| High | Line 298 | **Build actual call graph** - Call graph simulated |
| High | Line 309 | **Actual IPO passes** - Devirtualization, argument specialization not implemented |
| High | Line 328 | **Actually inline functions** - Inlining simulated |
| High | Line 355 | **Remove unused globals** - Dead code elimination simulated |
| High | Line 370 | **Propagate constants** - Cross-module constant propagation simulated |
| High | Line 380 | **Hash and merge functions** - Identical function merging simulated |
| High | Line 395 | **Promote small constants** - Global optimization simulated |
| High | Line 409 | **Write optimized IR/object** - Output is placeholder |
| Medium | Line 463 | **Create module summary** - Thin LTO summary not implemented |
| Medium | Line 469 | **Resolve imports** - Thin LTO import resolution not implemented |
| Medium | Line 476 | **Parallel optimization** - Thin LTO parallelization not implemented |

### `packages/build/src/ir_cache.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| Medium | Line 384 | **Parse JSON metadata** - Cache metadata loading incomplete |
| Medium | Line 392 | **Serialize entries to JSON** - Cache metadata saving incomplete |

### `packages/build/src/build_pipeline.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| Medium | Line 136 | **Parse dependencies from source** - Build dependency tracking incomplete |

### `packages/build/src/linker_script.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| Medium | Line 290 | **Actual ENTRY parsing** - Linker script parsing incomplete |

### `packages/build/src/coverage_builder.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| Medium | Line 260 | **Intelligent test suggestion** - Coverage-based test suggestions not implemented |

---

## 9. Package Manager

### `packages/pkg/src/auth.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| High | Line 355 | **Hide password input** - Password shown in terminal (platform-specific) |
| High | Line 418 | **Implement HTTP authentication** - Returns password as token (dev mode) |
| Medium | Line 371 | **Parse expiry from registry** - Token expiry hardcoded to 0 |
| Medium | Line 450 | **Actual token verification** - Only checks token existence |

### `packages/pkg/src/package_manager.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| Medium | Line 897 | **Add dependencies to JSON** - Package JSON export incomplete |

---

## 10. Kernel & OS

### `packages/kernel/src/syscall.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| Critical | Line 700 | **Implement vfs.open** - sys_open not implemented |
| Critical | Line 720 | **Schedule next process** - sys_exit doesn't schedule |
| Critical | Line 844 | **Implement brk** - Memory allocation syscall not implemented |
| Critical | Line 863 | **Implement mmap** - Memory mapping not implemented |
| Critical | Line 874 | **Implement munmap** - Memory unmapping not implemented |
| High | Line 881 | **Yield to scheduler** - sched_yield not implemented |
| High | Line 892 | **Implement nanosleep** - Sleep syscall not implemented |
| High | Line 904 | **Implement gettimeofday** - Time syscall not implemented |
| High | Line 915 | **Implement clock_gettime** - Clock syscall not implemented |

### `packages/kernel/src/exec.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| Critical | Line 154 | **Write args/env to stack** - Program arguments not passed |
| Critical | Line 195 | **Load executable from path** - ELF loading incomplete |
| Critical | Line 210 | **Create initial thread** - Thread creation incomplete |
| Critical | Line 241 | **Load executable file** - execve loading incomplete |
| High | Line 262 | **Check FD_CLOEXEC flag** - File descriptor handling incomplete |
| High | Line 270-273 | **Reset signal handlers/masks** - Signal cleanup incomplete |
| High | Line 326-328 | **Wake parent, send SIGCHLD** - Process exit incomplete |
| Medium | Line 366 | **Sleep until child exits** - waitpid blocking incomplete |

### `packages/kernel/src/process.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| High | Various | **12 TODOs** - Process management incomplete (see file) |

### `packages/kernel/src/smp.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| High | Various | **9 TODOs** - SMP/multiprocessor support incomplete |

### `packages/kernel/src/thread.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| High | Various | **7 TODOs** - Thread management incomplete |

### `packages/kernel/src/fork.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| High | Various | **6 TODOs** - Process forking incomplete |

### `packages/kernel/src/signal.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| High | Various | **6 TODOs** - Signal handling incomplete |

### `packages/kernel/src/shm.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| High | Various | **7 TODOs** - Shared memory incomplete |

### `packages/kernel/src/namespaces.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| High | Line 71 | **Cleanup resources** - Namespace destruction incomplete |
| High | Line 100-102 | **Use actual VFS mount type** - Mount namespace uses anyopaque |
| High | Line 138 | **Network interface list** - Net namespace uses anyopaque |
| High | Line 335 | **Copy mounts from parent** - Namespace cloning incomplete |

### `packages/kernel/src/limits.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| High | Line 198 | **Get current time** - Rate limiter time hardcoded |
| High | Line 208 | **Get current timestamp** - Rate limiter uses placeholder |
| High | Line 456 | **Implement signal sending** - OOM killer incomplete |

### `packages/kernel/src/paging.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| High | Line 484 | **Send IPI to all CPUs** - TLB shootdown incomplete |
| High | Line 503 | **Send IPI to all CPUs** - Range TLB shootdown incomplete |

### `packages/kernel/src/timer.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| High | Line 103 | **Calibrate TSC frequency** - Uses estimated 2GHz |

### `packages/kernel/src/mqueue.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| Medium | Line 121 | **Implement timeout** - Message send timeout ignored |
| Medium | Line 154 | **Implement timeout** - Message receive timeout ignored |

### `packages/kernel/src/boot.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| High | Line 63 | **Implement full IDT setup** - IDT setup pending |

### `packages/kernel/src/interrupts.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| High | Line 538 | **Get actual stack base** - Stack overflow detection incomplete |
| High | Line 561 | **Integrate with thread structure** - Stack base uses estimate |

### `packages/kernel/src/debug.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| Medium | Various | **4 TODOs** - Debug infrastructure incomplete |

### `packages/kernel/src/profiler.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| Medium | Various | **3 TODOs** - Kernel profiler incomplete |

### `packages/kernel/src/audit.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| Medium | Various | **3 TODOs** - Security audit logging incomplete |

### `packages/kernel/src/dma.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| Medium | Various | **3 TODOs** - DMA support incomplete |

---

## 11. Drivers

### `packages/drivers/src/usb/xhci.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| High | Line 460 | **Sleep 1ms** - Uses busy wait instead of timer |
| High | Line 473 | **Sleep 1ms** - Reset wait uses busy loop |
| High | Line 483 | **Sleep 1ms** - Ready wait uses busy loop |
| High | Line 514 | **Sleep 1ms** - Run wait uses busy loop |
| High | Line 534 | **Sleep 10ms** - Port reset uses busy loop |
| High | Line 547 | **Enumerate device** - USB device enumeration incomplete |
| High | Line 776 | **Build TRB chain** - Transfer submission incomplete |
| High | Line 864 | **Cancel URB** - URB cancellation not implemented |

### `packages/drivers/src/usb/hid.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| High | Line 156 | **Proper synchronization** - Keyboard polling uses busy wait |
| High | Line 273 | **Proper synchronization** - Mouse polling uses busy wait |
| High | Line 337 | **Register with input subsystem** - Keyboard not registered |
| High | Line 347 | **Register with input subsystem** - Mouse not registered |

### `packages/drivers/src/usb/mass_storage.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| High | Line 191 | **Proper sync** - CBW transfer uses busy wait |
| High | Line 207 | **Proper sync** - Data transfer uses busy wait |
| High | Line 221 | **Proper sync** - CSW transfer uses busy wait |
| High | Line 412 | **Register as block device** - Storage not registered |

### `packages/drivers/src/usb/usb.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| High | Line 266 | **Sleep/yield** - Control transfer uses busy wait |

### `packages/drivers/src/ahci.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| High | Line 305 | **Use proper timer delay** - Port reset uses busy wait |
| High | Line 336 | **Use actual timer** - Command wait uses iteration count |
| Medium | Line 624 | **Implement FLUSH CACHE** - Disk flush not implemented |

### `packages/drivers/src/nvme.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| High | Line 155 | **Free DMA buffers** - Queue cleanup incomplete |
| High | Line 516 | **Implement identify command** - Namespace discovery incomplete |

### `packages/drivers/src/e1000.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| Medium | Line 489 | **Disable RX/TX** - Network stop incomplete |

### `packages/drivers/src/block.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| Medium | Line 298 | **Call device cleanup** - Block device cleanup incomplete |

---

## 12. Networking

### `packages/net/src/protocols.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| High | Line 242 | **Get actual monotonic time** - Returns 0 |
| High | Line 482 | **ARP lookup for dest_mac** - Uses broadcast MAC |
| High | Line 557 | **Send echo reply** - ICMP echo not implemented |
| Medium | Line 664 | **Register socket with UDP layer** - UDP binding incomplete |
| Medium | Line 946 | **Register listening socket** - TCP listen incomplete |
| Medium | Line 1163 | **Get from device configuration** - IP address hardcoded |

### `packages/net/src/netdev.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| Medium | Line 259 | **Wake up network stack** - RX notification incomplete |

---

## 13. Graphics & Input

### `packages/graphics/src/input.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| Medium | Line 347 | **Detect key repeat** - Key repeat always false |
| Medium | Line 443 | **Track previous position** - Mouse delta calculation incomplete |
| Medium | Line 448 | **Calculate delta** - Mouse dx/dy always 0 |
| Medium | Line 454 | **Get scroll delta** - Scroll wheel incomplete |

### `packages/graphics/src/metal_renderer.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| High | Line 333 | **Upload texture data** - Texture creation incomplete |
| High | Line 342 | **Compile shader** - Shader compilation incomplete |

---

## 14. AST & Macros

### `packages/ast/src/splat_nodes.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| High | Line 238 | **Check if expression is iterable** - Splat validation incomplete |
| High | Line 289 | **Implement desugaring** - Array splat desugaring not implemented |
| High | Line 298 | **Implement desugaring** - Call splat desugaring not implemented |
| High | Line 310 | **Implement desugaring** - Destructure splat desugaring not implemented |

### `packages/ast/src/comprehension_nodes.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| High | Line 236 | **Implement desugaring** - Array comprehension desugaring not implemented |
| High | Line 247 | **Implement desugaring** - Map comprehension desugaring not implemented |

### `packages/ast/src/dispatch_nodes.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| Medium | Line 170 | **Check subtype relationships** - Multiple dispatch type checking incomplete |

### `packages/macros/src/macro_system.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| Low | Various | **Built-in macros** - todo!, unimplemented!, debug_assert! implemented |

---

## 15. Documentation

### `packages/tools/src/doc.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| Medium | Line 60 | **Extract from comments** - Doc comments not parsed |
| Medium | Line 66 | **Add visibility modifiers** - All functions marked public |
| Medium | Line 256 | **Generate individual pages** - HTML doc generation incomplete |

---

## 16. Async Runtime

### `packages/async/src/timer.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| High | Line 209 | **Get timer wheel from context** - Uses actual sleep instead of async |

---

## 17. Debugger

See [Interpreter section](#5-interpreter) - Debugger TODOs are in `packages/interpreter/src/debugger.zig`

---

## 18. Comptime

### `packages/comptime/src/integration.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| Medium | Line 133 | **Handle other expression types** - Comptime expression evaluation incomplete |
| Medium | Line 183 | **Handle other statement types** - Comptime statement evaluation incomplete |
| Medium | Line 200 | **Handle other declaration types** - Comptime declaration handling incomplete |

### `packages/comptime/src/macro.zig`

| Priority | Location | Description |
|----------|----------|-------------|
| Low | Various | **Built-in macros** - todo!, unreachable!, assert! implemented |

---

## 19. Standard Library

### Missing Standard Library Features (from README promises)

| Priority | Feature | Status |
|----------|---------|--------|
| High | **Collections (Vec, HashMap, Set)** | Not implemented |
| High | **File I/O** | Partial |
| High | **Networking** | Partial |
| High | **JSON parsing** | Partial |
| High | **HTTP client/server** | Partial |
| Medium | **Testing framework** | Partial (discovery works, execution incomplete) |
| Medium | **Closures** | Parser support exists, codegen incomplete |
| Medium | **Generics** | Parser support exists, monomorphization incomplete |
| Medium | **Traits/Interfaces** | Type system exists, codegen incomplete |

---

## 20. General Improvements

### Architecture Improvements

| Priority | Area | Description |
|----------|------|-------------|
| High | **Error Messages** | Many errors use generic messages; need context-specific suggestions |
| High | **Memory Safety** | Borrow checker exists but not fully integrated |
| High | **Incremental Compilation** | IR cache exists but metadata serialization incomplete |
| Medium | **Cross-compilation** | Only x86-64 fully supported; ARM64 partial |
| Medium | **Debug Info** | DWARF generation incomplete |
| Medium | **Optimization Passes** | LTO simulated, not implemented |

### Code Quality

| Priority | Area | Description |
|----------|------|-------------|
| Medium | **Busy Waits** | Many drivers use busy loops instead of proper timers |
| Medium | **Placeholder Values** | Several functions return hardcoded values |
| Medium | **anyopaque Usage** | Kernel namespaces use anyopaque instead of proper types |
| Low | **Debug Logging** | Parser logs module resolution to stdout |

### Testing

| Priority | Area | Description |
|----------|------|-------------|
| High | **Test Execution** | Test discovery works but tests don't actually run |
| Medium | **Coverage** | Coverage builder exists but test suggestions not implemented |
| Medium | **Integration Tests** | Need more comprehensive test suite |

---

## Summary Statistics

| Category | Total TODOs | Critical | High | Medium | Low |
|----------|-------------|----------|------|--------|-----|
| Core Compiler | 3 | 0 | 1 | 2 | 0 |
| Code Generation | 18 | 0 | 8 | 6 | 4 |
| Type System | 14 | 0 | 6 | 8 | 0 |
| Parser | 6 | 0 | 0 | 5 | 1 |
| Interpreter | 10 | 0 | 8 | 2 | 0 |
| LSP | 6 | 0 | 4 | 2 | 0 |
| Testing | 2 | 0 | 1 | 0 | 1 |
| Build System | 16 | 0 | 10 | 6 | 0 |
| Package Manager | 5 | 0 | 2 | 3 | 0 |
| Kernel & OS | 60+ | 4 | 40+ | 15+ | 0 |
| Drivers | 20+ | 0 | 15+ | 5+ | 0 |
| Networking | 7 | 0 | 3 | 4 | 0 |
| Graphics | 6 | 0 | 2 | 4 | 0 |
| AST & Macros | 7 | 0 | 5 | 1 | 1 |
| Documentation | 3 | 0 | 0 | 3 | 0 |
| Async | 1 | 0 | 1 | 0 | 0 |
| Comptime | 4 | 0 | 0 | 3 | 1 |

**Total: ~180+ TODOs across the codebase**

---

## Recommended Priority Order

### Phase 1: Core Language Completion (Immediate)

1. Test execution in test framework
2. Break/continue statement implementation
3. Labeled loops support
4. Array/struct field assignment in interpreter
5. LSP semantic analysis

### Phase 2: Standard Library (Short-term)

1. Collections (Vec, HashMap, Set)
2. File I/O completion
3. JSON parsing
4. HTTP client/server

### Phase 3: Advanced Features (Medium-term)

1. Closures codegen
2. Generics monomorphization
3. Trait codegen
4. Async runtime completion

### Phase 4: Kernel & Drivers (Long-term)

1. Core syscalls (mmap, brk, open)
2. Process management
3. USB driver completion
4. Network stack completion

---

*This document should be updated as TODOs are resolved or new ones are discovered.*
