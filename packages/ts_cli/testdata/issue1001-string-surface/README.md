# String surface oracle (#1001)

Home's synthesized `String` surface was missing 15 members TypeScript's lib
declares, so ordinary valid code was rejected:

```text
error TS2551: Property 'bold' does not exist on type '"x"'. Did you mean 'bold'?
```

The self-contradicting suggestion came from a workaround rather than the
surface: `closestPropertyMemberName` keeps its own list of the HTML methods for
spelling suggestions, so lookup on the real surface failed and the suggestion
pass then found an exact match. `lib.stringProto` now carries `trimLeft` and
`trimRight` (`lib.es2019.string.d.ts`) and the 13 HTML methods of
`lib.es2015.core.d.ts`, including both `fontsize` overloads.

Synthesized signatures carry no parameter names, so an overload error rendered
`'(x0: number): string'` where TypeScript prints `'(size: number): string'`.
`LibCache.lib_param_names` now names them, consulted by `signatureParamNameAt`
beside the existing `sort_comparator_signatures` case. Each named method gets
its own signature for that: sharing one `(string): string` cannot carry four
different names, and naming the shared `(number): string` would also have
renamed `charAt`'s parameter.

Run TypeScript 5.7.3 and Home from this directory with
`-p tsconfig.json --pretty false --noEmit`; the `test-tsc-streams` step
compares stdout, stderr and exit status exactly.

`strings.ts` calls each member as declared, then passes a wrong argument to
each parameterized method — `fontsize`'s pinning the two-overload TS2769 with
its parameter names — an extra argument to a nullary one, and assigns a result
to `number` to show the members return `string` rather than `any`.

Not covered here: `String`'s numeric index signature and `[Symbol.iterator]`,
which `keyof string` also needs; those belong to #995. The 34 members that
already existed still render `x0` in an overload error; naming them uses the
same table and is separate work.

[Issue #1001](https://github.com/home-lang/home/issues/1001) tracks this work.
