# Bun Test Corpus Baseline: Runnable-Today vs Phase-12.2-Blocked

**Date:** 2026-05-18  
**Corpus Version:** fd0b6f1a (pinned in UPSTREAM_SHA.txt)  
**Total Files:** 8634

---

## File Classification

| Category | Count | Notes |
|----------|-------|-------|
| **Test files** (*.test.ts / *.test.js) | 1720 | Runnable substrate |
| **Fixtures/** | 2060 | Test inputs, not tests themselves |
| **Config files** | 469 | package.json, tsconfig.json, bunfig.toml, etc. |
| **Test harness & utilities** | 5 | harness.ts, preload.ts, http-test-server.ts, etc. |
| **Snapshots/** | ~3000+ | Expected outputs (*.hmr.*, *.debug.*, etc.) |
| **Snippets/** | 79 | Code snippet fixtures |
| **Docker & CI setup** | ~100 | docker/, docker-compose.yml, etc. |
| **Docs & metadata** | 125 | *.md, *.txt, *.supp files |
| **Other** | 476 | _util/, collections, misc. |

---

## Test Classification by API Surface

| Classification | Test Count | Runnable Today? | Blocking Phase |
|---|---|---|---|
| **Pure JS/TS** (no imports from bun or node:) | 130 | ✓ YES | None |
| **Node-API only** (node: imports, no bun) | 88 | ~ PARTIAL | 12.7 (node: shims) |
| **Bun-API-light** (bun:test only, no heavy APIs) | 300+ | ~ PARTIAL | 12.2 (test framework) |
| **Bun-API-heavy** (Bun.serve, Bun.spawn, Bun.build, Bun.write, etc.) | 900+ | ✗ NO | 12.2 (JSC bridge) |
| **Mixed** (both bun + node imports) | 365 | ✗ NO | 12.2 + 12.7 |

**Bun API imports breakdown (top 5):**
- `bun:test` (test framework): 1547 occurrences
- `bun` (Bun.spawn, Bun.file, etc.): 576 occurrences
- `bun:bundle` (bundler API): 25 occurrences
- `bun:jsc` (JSC introspection): 20 occurrences
- `Bun.SQL` (database layer): 19 occurrences

**Heavy Bun APIs found in corpus:**
- Bun.spawn or spawn(): 657 tests
- Bun.write or Bun.file: 189 tests
- Bun.serve: 150 tests
- Bun.build: 45 tests
- $ shell API: 54 tests

---

## Test Count Metrics

| Metric | Count |
|--------|-------|
| test() calls | 11,100 |
| describe() blocks | 2,580 |
| expect() assertions | 44,531 |
| it() aliases | 5,183 |

**Estimated assertions per test:** 4.0 (mean)

---

## Runnable-Today Estimate

| Category | Test Files | Estimated Assertions |
|----------|-------|---|
| Pure JS/TS | 130 | ~520 |
| Node-API only (with Home node: shims) | 88 | ~352 |
| **bun:test framework only** (once 12.2 lands) | 300+ | ~1200+ |
| | | |
| **TODAY RUNNABLE (without Phase 12.2)** | **≤218** | **≤872** |
| **TODAY RUNNABLE (with Phase 12.2 JSC bridge)** | **1300+** | **5200+** |

---

## Surprises & Non-Obvious Findings

1. **Massive snapshot/fixture corpus (~3000+ files):** The `snapshots/`, `fixtures/`, and bundler fixture trees dominate file count. These are NOT tests themselves but expected outputs and inputs. The actual test code (1720 files) is a fraction of the stored corpus.

2. **87% of tests depend on Phase 12.2 JSC bridge:** 1502 tests import from `bun` or `bun:*` (excluding pure bun:test). Heavy APIs (serve, spawn, file, build) appear in ~900 tests. Pure JS/TS tests (130) represent only 7.6% of the corpus.

3. **bun:test is the critical bottleneck:** 1547 tests import `bun:test`. Until the test framework is available (Phase 12.2), these tests cannot even load. This is the single largest blocker.

4. **Assertion density is high:** 44,531 expect() calls across 1720 test files = ~26 assertions per file. The baseline runway is deep once APIs are ready.

5. **Node compat is narrow:** Only 88 tests use ONLY node: APIs; they'll pass once Phase 12.7 lands. The majority of real tests are Bun-native by design (integration tests, process spawning, HTTP servers).

---

## Acceptance Gate Denominator

| Scenario | Total Runnable Tests | Test Count | Assertion Count |
|----------|---|---|---|
| **Baseline (today, May 2026)** | Pure JS only | 130 | 520 |
| **Phase 12.2 complete** | Bun APIs + test framework | 1500+ | 6000+ |
| **Phase 12.7 complete** | Add Node compat shims | 1600+ | 6500+ |
| **Final (all phases)** | 100% acceptance gate target | **1720** | **44,531** |

**100% acceptance gate success = 0 failing tests out of 1720, across macOS, Linux, WASM targets.**

---

**Report generated:** 2026-05-18  
**Analysis method:** File enumeration + grep-based classification (read-only)  
**Time spent:** ~20 minutes
