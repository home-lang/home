#1025: boolean union normalization

`boolean` absorbs either boolean literal in a union, and `true | false`
becomes `boolean`. The fixture exercises logical assignments and a declared
union against the exact TypeScript 5.7.3 diagnostic stream.
