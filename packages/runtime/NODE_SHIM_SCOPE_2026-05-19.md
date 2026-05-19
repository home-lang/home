# Phase 12.7 Node:* Namespace Shims Scope

**Date:** 2026-05-18  
**Goal:** Unblock 88 Node-only tests runnable today (Phase 12.7)  
**Status:** Scoping complete

---

## Executive Summary

Phase 12.7 must implement node:* namespace shims to unlock 88 test files that import ONLY Node APIs (no Bun imports). The highest-impact modules—**node:path, node:assert, and node:test**—appear in 67, 16, and 15 test files respectively. Implementing these 3 modules would unblock ~70% of node-only tests. Adding node:fs and node:events brings coverage to ~95%.

**Top 5 modules by test impact:**
1. **node:path** (67 tests) — 10 API methods, 81 LOC — **Effort: 4h**
2. **node:assert** (16 tests) — 30+ methods, 1036 LOC — **Effort: 12h**
3. **node:test** (15 tests) — ~15 exports, 449 LOC — **Effort: 10h**
4. **node:fs** (11 tests) — 50+ methods, 1397 LOC — **Effort: 20h**
5. **node:events** (10 tests) — ~10 methods, 865 LOC — **Effort: 10h**

---

## Test Count Per Module

| Module | Test Count | Import Frequency | % of 88 Tests |
|--------|------------|-------------------|---------------|
| **node:path** | 67 | 67 | 76% |
| **node:assert** | 16 | 16 | 18% |
| **node:test** | 15 | 15 | 17% |
| **node:fs** | 11 | 11 | 12% |
| **node:events** | 10 | 10 | 11% |
| node:net | 6 | 6 | 7% |
| node:stream | 5 | 5 | 6% |
| node:tls | 4 | 4 | 5% |
| node:os | 4 | 4 | 5% |
| node:http | 4 | 4 | 5% |
| node:child_process | 4 | 4 | 5% |
| node:util | 3 | 3 | 3% |
| node:http2 | 3 | 3 | 3% |
| node:worker_threads | 2 | 2 | 2% |
| node:url | 2 | 2 | 2% |
| node:readline | 2 | 2 | 2% |
| node:vm | 1 | 1 | 1% |
| node:https | 1 | 1 | 1% |
| node:crypto | 1 | 1 | 1% |
| node:fs/promises | 2 | 2 | 2% |

**Total unique test files importing node:* (no bun):** 88

---

## API Surface Per Module

### Tier 1: High Impact, Moderate Complexity

#### **node:path** (67 tests, 76% coverage)
**Functions:** resolve, normalize, join, isAbsolute, relative, dirname, basename, extname, format, parse  
**API Count:** 10 main functions  
**Implementation:** Binding dispatch to C++ path parser (Path.cpp in Bun)  
**Complexity:** Low (thin wrapper over existing C++ binding)  
**LOC in Bun:** 81  
**Estimated Effort:** 4 agent-hours  
**Notes:** Uses Bun's existing Path.cpp binding; posix/win32 dual namespace. Porting is mechanical rewrite of Bun's thin JS layer.

#### **node:assert** (16 tests, 18% coverage)
**Functions:** ok, equal, deepEqual, strictEqual, deepStrictEqual, throws, doesNotThrow, rejects, doesNotReject, match, doesNotMatch, ifError, fail, AssertionError  
**API Count:** 14+ main functions + strict namespace  
**Implementation:** Pure JS port from Node.js (1036 LOC)  
**Complexity:** Medium (requires internal/primordials, internal/validators, util/types)  
**LOC in Bun:** 1036  
**Estimated Effort:** 12 agent-hours  
**Notes:** Mostly JS copy from Node.js; depends on node:util/types, internal validators (already available).

#### **node:test** (15 tests, 17% coverage)
**Functions:** test, describe, it, beforeEach, afterEach, mock, skip, only, todo  
**API Count:** 15+ exports  
**Implementation:** Bun's test runner (449 LOC)  
**Complexity:** Medium-High (deeply tied to runtime lifecycle)  
**LOC in Bun:** 449  
**Estimated Effort:** 10 agent-hours  
**Notes:** Requires test framework integration (Phase 12.8 dependency). Can stub basic version now; full integration deferred to 12.8.

---

### Tier 2: Medium Impact, High Complexity

#### **node:fs** (11 tests, 12% coverage)
**Functions:** readFile, writeFile, readdir, stat, watch, rename, unlink, mkdir, rmdir, copyFile, + promises variant  
**API Count:** 50+ methods  
**Implementation:** Binding dispatch to Bun's file system layer (1397 LOC)  
**Complexity:** High (requires FSWatcher, EventEmitter inheritance, native binding dispatch)  
**LOC in Bun:** 1397  
**Estimated Effort:** 20 agent-hours  
**Notes:** Depends on node:events (EventEmitter). Large surface; most tests use subset (stat, readFile, writeFile, watch).

#### **node:events** (10 tests, 11% coverage)
**Functions:** EventEmitter, once, on, off, removeAllListeners, emit, addListener, removeListener  
**API Count:** 8+ methods  
**Implementation:** Bun's EventEmitter (865 LOC)  
**Complexity:** High (class-based, inheritance patterns, listener mgmt)  
**LOC in Bun:** 865  
**Estimated Effort:** 10 agent-hours  
**Notes:** Base class for FSWatcher, net.Server, etc. Many tests depend on this indirectly.

---

### Tier 3: Low Impact, Varying Complexity

#### **node:net** (6 tests)
- createServer, Socket, connect, listen, Server.address
- Complexity: Very High (socket binding, event lifecycle)
- Estimated Effort: 25+ agent-hours

#### **node:stream** (5 tests)
- Readable, Writable, Transform, PassThrough, pipeline
- Complexity: Very High (backpressure, end-of-stream, transformations)
- Estimated Effort: 25+ agent-hours

#### **node:http** (4 tests)
- Server, ClientRequest, createServer, request
- Complexity: Very High (depends on net, requires HTTP parser)
- Estimated Effort: 30+ agent-hours

#### **node:util** (3 tests)
- promisify, inspect, types (isDate, isRegExp, etc.)
- Complexity: Medium
- Estimated Effort: 8 agent-hours

#### **node:os** (4 tests)
- tmpdir, platform, arch, cpus, totalmem
- Complexity: Low-Medium
- Estimated Effort: 6 agent-hours

#### **node:child_process** (4 tests)
- spawn, exec, fork, execFile
- Complexity: Very High (depends on event_loop, requires process management)
- Estimated Effort: 28+ agent-hours

---

## Blocking Dependencies

| Module | Unblocked By | Ready To Land |
|--------|-------------|---------------|
| **node:path** | None (pure JS) | Phase 12.7 now |
| **node:assert** | node:util/types, internal/* | Phase 12.7 now |
| **node:test** | Phase 12.8 (test framework) | Phase 12.7 (stub) |
| **node:fs** | node:events | Phase 12.7 after events |
| **node:events** | None (pure JS) | Phase 12.7 now |
| node:os | None (pure JS) | Phase 12.7 now |
| node:util | None (pure JS) | Phase 12.7 now |
| node:net | Phase 12.2 (JSC bridge for socket binding) | Phase 12.8+ |
| node:http | node:net, Phase 12.2 | Phase 12.8+ |
| node:stream | Phase 12.2 (stream backing) | Phase 12.8+ |

---

## Recommended Phasing: 3+2 Approach

### Phase 12.7a (Weeks 1-2) — Core 3 Modules
Land in parallel:
1. **node:path** (4h) — no dependencies
2. **node:assert** (12h) — no dependencies
3. **node:events** (10h) — no dependencies
4. **node:util** (8h) — bonus, low effort

**Tests unblocked:** ~76 (path alone covers most)  
**Total effort:** 34 agent-hours (3 agents × 2 weeks)

### Phase 12.7b (Weeks 3-4) — Tier 2 Heavyweights
5. **node:fs** (20h, depends on events from 12.7a)
6. **node:test** (10h, stub version before 12.8)

**Tests unblocked:** 88 → ~90 (subset of fs/test)  
**Total effort:** 30 agent-hours (2 agents × 2 weeks)

---

## Implementation Strategy

### Approach 1: Copy-Paste Porting (Recommended)
1. Copy Bun's node:* files from `~/Code/bun/src/js/node/` to `packages/runtime/src/node/`
2. Rewrite `@import("bun")` → `@import("home_rt")`; `$cpp()` → `home_rt_binding()`
3. Port binding dispatch stubs to Zig (see Phase 12.2 scope for JSC bridge model)
4. Add inline tests per Phase 12 requirements (one test per copied file)
5. Run `home test packages/runtime/test/bun-corpus/js/node/*` to validate

### Approach 2: Minimal Pure-JS (Fallback)
For **node:path, node:assert, node:test** only:
- Port pure JS from Bun (no C++ binding)
- Implement path operations in JS (regex + string ops)
- Stub C++ bindings as noop dispatchers
- Unblock 76 tests without landing full Zig binding layer

---

## Effort Estimate Summary

| Module | Lines | Exported APIs | Agent-Hours | Critical Path |
|--------|-------|----------------|-------------|---------------|
| node:path | 81 | 10 | 4 | Day 1 |
| node:assert | 1036 | 14 | 12 | Day 2–3 |
| node:events | 865 | 8 | 10 | Days 2–3 |
| node:util | 338 | 10 | 8 | Day 4 (bonus) |
| node:test | 449 | 15 | 10 | Days 5–6 |
| node:fs | 1397 | 50+ | 20 | Days 7–8 |
| **Total (3+2 modules)** | **4,166** | **107** | **64** | **2 weeks** |
| node:os | 150 | 8 | 6 | Day 4 (bonus) |

**Parallel agent count:** 2–3 agents  
**Wall-clock time:** 2–3 weeks (assuming 12h/day throughput)

---

## Success Criteria

- [ ] 88 test files import node:* with zero compilation errors
- [ ] Top 3 modules (path, assert, events) land Day 5
- [ ] 76+ tests passing after path+assert+events
- [ ] Full 88-test coverage after fs+test land
- [ ] `home test packages/runtime/test/bun-corpus/ --grep "node-only" --reporter=json` shows 0 failures
- [ ] CI check: no regressions in pure-JS tests (130 baseline)

---

## Risk Mitigation

| Risk | Probability | Mitigation |
|------|-------------|-----------|
| Binding dispatch panics on first call | High | Start with pure-JS variants (path, assert, util); defer C++ binding to Phase 12.8 |
| Missing internal/* modules | Medium | Cherry-pick validators, primordials from Bun; inline stubs if needed |
| Phase 12.2 JSC bridge not ready | Medium | De-couple node:fs, node:events from JSC; ship pure-JS versions now, bind later |
| Tests use bun-only features mixed in | Low | All 88 are verified node-only via grep; spot-check 5 random files before landing |

---

## Files to Land

**Home package destinations:**
```
packages/runtime/src/node/
├── path.ts                  # node:path (4h)
├── assert.ts                # node:assert (12h)
├── assert.strict.ts         # node:assert.strict (bundled in above)
├── events.ts                # node:events (10h)
├── util.ts                  # node:util (8h, bonus)
├── test.ts                  # node:test (10h, stub before 12.8)
├── fs.ts                    # node:fs (20h)
├── os.ts                    # node:os (6h, bonus)
└── (others deferred to 12.8)

packages/runtime/test/bun-corpus/js/node/
└── (existing 88 test files, no new files needed)
```

**Test output:**
```
88 tests in 88 files ✓
~352 assertions (4 per test avg)
Coverage: path + assert + events + util = 76+ tests on Day 3
Coverage: + test + fs + os = 88+ tests on Day 8
```

---

## Next Steps

1. **Verify node-only test list** (already done: grep confirms 88 files, no bun imports)
2. **Prioritize top 3 modules**: path, assert, events (Weeks 1–2)
3. **Land pure-JS versions first**, defer C++ bindings to Phase 12.2 unblock
4. **Allocate 2–3 parallel agents** starting Monday
5. **Check in every 2 days** against test count growth (target: 50% by Day 5, 88% by Day 10)

