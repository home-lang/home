# Crash-Class Bug Audit: check.zig (Round 2)
**Audit Date**: 2026-05-19  
**File**: `/Users/chrisbreuer/Code/Home/lang/packages/ts_checker/src/check.zig`  
**Prior Fixes**: fec2e038, eb702b3b (5 dangling-slice sites fixed)

---

## Risk Categories

| Category | Description |
|----------|-------------|
| **Unbounded Recursion** | Recursive functions without depth guards (stack overflow on deep types) |
| **@intCast Overflow** | Type casts from larger types without bounds checking (usize→u32, u64→usize) |
| **Unsafe Pool Index Access** | payloadOf/flagsOf without prior bounds validation |
| **Recursive Slice Borrow** | Borrowed slices while recursive calls grow pools (same pattern as dangling-slice bug) |
| **Optional Unwrap on Computed** | `.?` operator on optionals without prior null-checks |

---

## HIGH-RISK Sites

### 1. inferFromPair :: Unbounded Recursion (42534-42653)
```
File:Line: packages/ts_checker/src/check.zig:42534-42653
Function: inferFromPair
Risk: HIGH
```
**Issue**: Recursive function dispatches through unions/intersections/signatures/objects without depth tracking. Can call itself at lines 42555, 42560, 42567, 42603, 42609, 42614, 42643, 42648 on deeply-nested generic types → SIGABRT on stack exhaustion.

**Observable symptom**: Stack overflow crash on pathological type hierarchies (e.g., `T extends { a: T extends ... }`).

**Suggested fix**: Add `depth: u8` parameter; return early if `depth > 64`.

---

### 2. substituteType :: Unbounded Recursion (42926-43085+)
```
File:Line: packages/ts_checker/src/check.zig:42926
Function: substituteType
Risk: HIGH
```
**Issue**: Recursive type substitution for unions, intersections, signatures, object members at lines 42943, 42956, 42968, 42970, 43028, 43044, 43048, 43052, 43060, 43067-43069 without depth guards. Can exhaust stack on cyclic type substitutions.

**Observable symptom**: Stack overflow during deep generic instantiation or recursive type parameter substitution.

**Suggested fix**: Add `depth: u8` parameter; cap at depth 64.

---

### 3. presentObjectMembersAssignable :: Unbounded Recursion (20287-20308)
```
File:Line: packages/ts_checker/src/check.zig:20287
Function: presentObjectMembersAssignable
Risk: HIGH
```
**Issue**: Recursive function calls itself at line 20305 within a loop. Combined with recursive `heritageAssignable()` at line 20304, can recurse unboundedly on deeply-nested interface hierarchies.

**Observable symptom**: Stack overflow on complex interface extend chains.

**Suggested fix**: Add depth parameter (pass through heritageAssignableDeep at line 20284); guard: `if (depth > 48) return true;`.

---

### 4. @intCast(param_ix) :: u32 Overflow (43006, 43012)
```
File:Line: packages/ts_checker/src/check.zig:43006
Function: substituteType (signature param iteration)
Risk: HIGH
```
**Issue**: `param_ix` (usize) cast to `u16` (SignatureParamKey.param_index). Signatures with >65535 parameters will wrap/corrupt the key.

**Observable symptom**: Silent key corruption in signature_param_predicates map; incorrect predicate lookups → type-checking errors or false positives.

**Suggested fix**: Add bounds check: `if (param_ix >= 65536) break;` before @intCast.

---

### 5. @intCast(i) :: u64→usize Overflow (26964)
```
File:Line: packages/ts_checker/src/check.zig:26964
Function: renderTupleDisplay (tupleElementType call)
Risk: HIGH
```
**Issue**: Loop variable `i: u64` cast to `usize` for tuple element lookup. On 32-bit systems, i>2³¹ overflows.

**Observable symptom**: Incorrect tuple rendering in diagnostics; potential access of wrong elements.

**Suggested fix**: Change loop: `for (0..@min(length, 10_000)) |i_cast|` to cap tuple display width.

---

### 6. @intCast(source.len) :: Potential Overflow (50725, 50727)
```
File:Line: packages/ts_checker/src/check.zig:50725-50727
Function: ?
Risk: HIGH
```
**Issue**: source.len (usize) cast to return type (u32). Files >4GB will overflow.

**Observable symptom**: Incorrect line-number calculation on huge source files.

**Suggested fix**: Add bounds check: `if (source.len > 4_000_000_000) return error.FileTooLarge;`.

---

### 7. @intCast(self.hir.kinds.items.len) :: u32 Overflow (22030)
```
File:Line: packages/ts_checker/src/check.zig:22030
Function: ?
Risk: HIGH
```
**Issue**: items.len (usize) cast to NodeId (u32). HIR with >2³² nodes will overflow.

**Observable symptom**: Silent NodeId corruption; incorrect node references.

**Suggested fix**: Validate at module load: `if (self.hir.kinds.items.len > std.math.maxInt(u32)) return error.ModuleTooLarge;`.

---

### 8. inferFromArgument :: Unbounded Recursion (42715+)
```
File:Line: packages/ts_checker/src/check.zig:42715-42800+
Function: inferFromArgument
Risk: HIGH
```
**Issue**: Calls `inferFromArgument` recursively (line 42728) for intersection members without depth tracking. Can chain on nested intersections.

**Observable symptom**: Stack overflow on pathological intersection types.

**Suggested fix**: Pass depth parameter; cap at 48.

---

## MEDIUM-RISK Sites

### 9-14. Recursive Borrowed Slices (Similar Pattern to Fixed Sites)

**heritageAssignable chains** (17187, 20282-20284):
- `heritageAssignable()` → `presentObjectMembersAssignable()` → recursive `heritageAssignable()` 
- Borrowed slices in nested loops without snapshots remain (fixed in eb702b3b for some sites)
- Additional at: ~17187, ~19876 may still need snapshots

**typesHaveComparableOverlapLimit** (38185-38250):
- Has depth guard (line 38187: `if (depth > 32) return true;`) ✓
- But calls `typesHaveComparableOverlapLimit` recursively 4+ times per branch
- Risk: MEDIUM (guard helps, but deep types can still hit stack limits)

### 15-20. Optional Unwrap Patterns

Lines with `.?` on computed values (risk of panic on null):
- **Line 7763-7764**: `self.string_interner.get(param_name.?)` — param_name checked to not-null at 7762 ✓
- **Line 12598**: `const member_name = member_name_opt.?` — checked at 12595 ✓  
- **Line 20047-20049**: `self.string_interner.get(child_name_id.?)` — checked at 20046 ✓
- **Line 37814**: `d.pos != null and d.pos.?` — double-check pattern, safe ✓
- **Line 43475**: `rest_max_count.?` — checked at 43470 ✓

**Status**: Most are safely guarded; **Line 50890** has unchecked slice:
```zig
src[d.pos.? .. d.pos.? + "await".len]  // if d.pos is null → panic
```
**Risk**: MEDIUM — only in test code (lines 50889-50905), but still unsafe pattern.

### 21-30. Payload Index Bounds (MEDIUM-Risk Sample)

Patterns like `pool.payloadOf(t) >= pool.object_type_payloads.items.len`:
- **Lines ~42589**: checked before use ✓
- **Lines ~10833**: checked before use ✓
- But many callsites DON'T check before calling `self.interner.objectMembers()` or similar
- **Line 9061**: `if (member >= self.interner.pool.typeCount()) continue;` but then uses member in loop
- **Risk**: MEDIUM — defensive checks help, but inconsistent coverage

---

## Summary

**HIGH-RISK (8 sites)**:
- **Recursion**: 4 functions without depth guards (inferFromPair, substituteType, presentObjectMembersAssignable, inferFromArgument)
- **@intCast overflows**: 4 instances (u32, u64→usize, file size, module size)

**MEDIUM-RISK (20+ sites)**:
- Residual dangling-slice patterns in heritageAssignable chains
- Optional unwrap without guard in tests
- Inconsistent payload bounds checking

**Total HIGH**: 8  
**Total MEDIUM**: 22 (estimated from patterns)

---

## Recommendations (Priority Order)

1. **URGENT**: Add depth parameters to `inferFromPair`, `substituteType`, `inferFromArgument` (4 sites; likely stack-overflow crashes in production)
2. **URGENT**: Add bounds checks for `@intCast(param_ix)` → u16 (line 43006) and file-size casting (lines 50725-50727)
3. **HIGH**: Add depth to `presentObjectMembersAssignable` recursive calls
4. **HIGH**: Validate `self.hir.kinds.items.len <= maxInt(u32)` at module load
5. **MEDIUM**: Snapshot remaining borrowed slices in heritageAssignable chains (check lines 17187, 19876)
6. **MEDIUM**: Replace unsafe `.?` with explicit null-coalesce in test code (line 50890)
7. **LOW**: Consider adding a pool-reallocation callback that invalidates cached slices (defense-in-depth against future dangling-slice bugs)

