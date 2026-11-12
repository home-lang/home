// Exported values whose initializer the declaration graph cannot write down
// before checking. The importer gets their checked type.
export const annotated: -5 = -5;
export const sum = 2 + 3;
export const call = Math.abs(1);
export const object = { k: 1 };
export const fixed = 5 as const;
export const negativeMember = { k: -1 };
export const not = !0;
export const negative = -5;
export const literal = 5;
export const text = "s";
export const list = [1, 2];
export const parenthesized = (5);
export const template = `t${1}`;
export const arrow = () => 1;
export const nestedList = { k: [1] };
export const nestedObject = { k: { j: 1 } };
export const computedMember = { k: 1 + 1 };
export const nothing = null;
export let mutable = 5;
export let mutableNegative = -5;
export const alias = literal;
export const map = new Map<string, number>();
export const set = new Set([1]);
export const promise = Promise.resolve(1);
export class Box { x = 1 }
export const box = new Box();
