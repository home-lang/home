# Generic indexed return diagnostics (#1063)

The four errors cover generic object indexed returns, optional indexed
returns, a fixed object's generic key, and the `unknown` result of indexing
an instantiated generic object. The exact-stream audit compares this project
with the installed TypeScript 5.7.3 compiler. The separate installed-SDK
probe also compares these cases with native TypeScript 7.0.2.
