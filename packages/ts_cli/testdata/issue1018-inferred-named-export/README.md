# Inferred exports retain named local types (#1018)

An exported value inferred from a function returning a local interface or
non-generic object alias carries the declaration across the Program boundary.
An unrelated object literal with the same shape remains anonymous. The
annotated export is a control for the existing syntactic schema path.

TypeScript 5.7.3 and native TypeScript 7.0.2 agree on all four diagnostic
lines. The oracle audit compares the complete output against 5.7.3. See
[issue #1018](https://github.com/home-lang/home/issues/1018).
