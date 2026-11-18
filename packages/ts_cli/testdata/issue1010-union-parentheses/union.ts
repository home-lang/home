enum Color { Red, Green }

declare const first: (() => void) | { b: 2 } | (new () => object);
const firstCheck: 1 = first;

declare const middle: { b: 2 } | (() => void) | { c: 3 };
const middleCheck: 1 = middle;

declare const last: { b: 2 } | (new () => object) | (() => void);
const lastCheck: 1 = last;

const enumCheck: Color | "s" = true;
