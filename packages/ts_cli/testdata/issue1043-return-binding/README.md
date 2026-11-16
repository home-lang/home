#1043: returning a binding versus calling it

The function's binding has a function type before its return type is inferred.
Returning that binding, or returning an object that owns the method, is not a
return-type cycle. Calling the function being inferred is a cycle and reports
TS7023. The exact diagnostic stream is compared with TypeScript 5.7.3 by
`scripts/tests/compare-issue846-oracles.mjs`.
