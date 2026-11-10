# Generic argument oracle (#1000)

Two instances of the same generic relate their type arguments, and TypeScript
explains such a failure with the failing pair alone. Home walked the expanded
bodies instead and landed on whatever the generic happens to declare, which
produced a different wrong shape per origin: a property level for `Box<T>`, an
index signature and then an entry tuple for `Map`, an extra index-signature
level for `Set`, and the internal field name `__home_promise_value` for
`Promise` — a modelling detail in a user-visible diagnostic. `Holder<T>`
rendered correctly only by accident, its single property chain collapsing to
the same text.

`buildAssignabilityElaborationChainDepth` resolves both operands through
`resolveGenericType` on entry and recurses with the expanded pair, so every
dispatch branch below it sees an ordinary object type; these types never
carried an instantiation header into the chain at all. The arguments remain
recoverable from machinery that already existed: `alias_type_args` records them
where the substitution path builds the `Box<string>` display text, and
`heritageGenericInstantiationAssignable` already decided "same generic" from
`namedTypeForId` with a `genericInstanceBaseName` fallback. That base test is
now shared as `genericInstancesShareBase`, so the relation and its diagnostic
cannot drift apart on what "same generic" means.

Run TypeScript 5.7.3 and Home from this directory with
`-p tsconfig.json --pretty false --noEmit`; the `test-tsc-streams` step
compares stdout, stderr and exit status exactly.

`generics.ts` pins the one-line argument elaboration for an interface, a
class, and the `Map`, `Set` and `Promise` globals — the two-argument `Map`
case fixing the argument that is reported, and `Promise` standing guard over
the internal field name.

The rest are the controls that bound the shortcut. A union instantiation is
explained by the member that failed, so `Container<number>` against
`Container<string>` keeps `Type 'number' is not assignable to type
'Container<string>'.`; an earlier draft of the fix regressed exactly that and
was caught by `checker: recursive generic union alias shortcut preserves type
arguments`. Two *different* generics are not the same generic however alike
they look, so `Box<string>` against `Crate<number>` keeps its
`Types of property 'value' are incompatible.` chain. A matching argument is
still accepted, and so is a widening one.

The element *anchor* for a generic instance inside an array literal —
`Map<string, number>[] = [ms]`, which TypeScript reports at the element — is
#999, not this issue. Only the chain is pinned here.

[Issue #1000](https://github.com/home-lang/home/issues/1000) tracks this work.
