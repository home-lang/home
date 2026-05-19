# Dangling-Slice Bug Audit: check.zig

**Audit Date**: 2026-05-18  
**File**: `/Users/chrisbreuer/Code/Home/lang/packages/ts_checker/src/check.zig`  
**Pattern Sought**: Slice borrowed from growable pools (e.g., `self.interner.pool.object_member_pool.items`), then used while recursive type-interning machinery grows the pool, invalidating the slice's base pointer.

---

## Summary

**Total Sites Scanned**: 60+ call sites with `interner.objectMembers()` / `interner.signatureParams()` / `interner.unionMembers()`

| Risk Level | Count | Status |
|------------|-------|--------|
| **HIGH** (critical) | 3 | **UNFIXED** |
| **MEDIUM** (probable) | 4 | **UNFIXED** |
| **LOW** (safe) | 53+ | Safe or already fixed |

---

## High-Risk Sites (Must Fix)

### 1. checkInterfaceExtendsCompatibility :: nested loops (19610-19612)
```
File:Line: packages/ts_checker/src/check.zig:19610-19619
Function: checkInterfaceExtendsCompatibility (line 19569)
Borrowed slices: objectMembers(parent_t) [line 19610], objectMembers(other_t) [line 19612]
Recursive callees: heritageAssignable() [line 19619] -> engine.isAssignableTo() -> computeAssignable()
Risk: HIGH
```
**Why dangerous**: Nested for-loops iterate over borrowed `objectMembers(parent_t)` and `objectMembers(other_t)` while calling `heritageAssignable()` which chains to `engine.isAssignableTo()`. The `computeAssignable()` function recursively interns new types, growing the `object_member_pool` and invalidating the slice base pointers.

**Observable symptom**: Segfault mid-iteration when complex inheritance hierarchies or cross-interface extends checks trigger pool reallocation (seen with `parserRealSource11` / `parserRealSource14` before fix).

---

### 2. intersectionHasDisjointSharedProperty :: nested loop (28259-28266)
```
File:Line: packages/ts_checker/src/check.zig:28259-28266
Function: intersectionHasDisjointSharedProperty (line 28245)
Borrowed slice: objectMembers(a) [line 28259]
Recursive callees: heritageAssignable() [lines 28265-28266]
Risk: HIGH
```
**Why dangerous**: For-loop iterates over `objectMembers(a)` while making two `heritageAssignable()` calls inside the loop body. Each call can trigger recursive `engine.isAssignableTo()` which interns types and grows the pool.

**Observable symptom**: Potential segfault when checking intersection type member overlap with complex recursive type assignments.

---

### 3. presentObjectMembersAssignable :: recursive descent (19886-19892)
```
File:Line: packages/ts_checker/src/check.zig:19886-19892
Function: presentObjectMembersAssignable (line 19881)
Borrowed slice: objectMembers(target) [line 19886]
Recursive callees: heritageAssignable() [line 19891], recursive presentObjectMembersAssignable() [line 19892]
Risk: HIGH
```
**Why dangerous**: For-loop borrows `objectMembers(target)` while calling recursive `heritageAssignable()` (which interns types) AND recursive `presentObjectMembersAssignable()` (which borrows more slices). Recursive descent accumulates borrowed slices on the stack while the pool grows.

**Observable symptom**: Segfault in deep interface extension hierarchies during assignability checks.

---

## Medium-Risk Sites (Should Fix)

### 4-7. Type Comparison Functions with Pool Borrowing
- **signatureObjectTypesHaveComparableOverlap** (37816): Borrows `objectMembers(a)`, calls recursive `signaturesHaveComparableOverlap()` → `typesHaveComparableOverlapLimit()` (can intern)
- **objectTypesHaveIndependentOverlap** (37888): Borrows `objectMembers(a)`, calls comparison functions
- **heritageAssignableDeep** (19876): Calls `presentObjectMembersAssignable()` which borrows
- **Recursive chain**: presentObjectMembersAssignable → heritageAssignable → engine.isAssignableTo → computeAssignable

**Risk**: MEDIUM - May trigger pool growth under complex type scenarios

---

## Already-Fixed Sites

✓ **mergeExtendedMembers** (15887-15891): Snapshots parent_members before loop  
✓ **inferFromPair** (42034-42038): Snapshots p_members before loop  
✓ Various **relation.zig** sites: Already use `.dupe()` or similar snapshots

---

## Safe/Low-Risk Sites

Read-only iterations without recursive interning calls:
- `objectStringIndexObjectValueCompatible` (20376)
- `appendInheritedInterfaceMembers` (20468)
- `collectClosestMember` (15099)
- `objectHasCallOrConstructSignature` (28204)
- Multiple predicate/name-lookup iterations

---

## Fix Pattern

From commit fec2e038 — apply to high-risk sites:

```zig
// Before (DANGEROUS):
for (self.interner.objectMembers(t)) |m| {
    try self.recursiveFunction(m.type);  // Can intern and grow pool!
}

// After (SAFE):
const members_borrow = self.interner.objectMembers(t);
var members_copy: std.ArrayListUnmanaged(types.ObjectMember) = .empty;
defer members_copy.deinit(self.gpa);
try members_copy.appendSlice(self.gpa, members_borrow);
const members = members_copy.items;
for (members) |m| {
    try self.recursiveFunction(m.type);  // Safe - using snapshot
}
```

---

## Recommendations

1. **URGENT**: Apply snapshot fix to sites 1-3 (high-risk)
2. Apply to sites 4-7 (medium-risk) 
3. Add defensive snapshots to any new recursive paths that borrow and iterate
4. Consider adding a pool-stability check or snapshot-wrapper utility to prevent future bugs

