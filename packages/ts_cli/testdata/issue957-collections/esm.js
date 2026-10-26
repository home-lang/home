const key = { id: 1 };

export const map = new Map([["ready", 1]]);
/** @type {ReadonlyMap<string, number>} */
export const readonlyMap = new Map([["ready", 1]]);
export const set = new Set([1]);
/** @type {ReadonlySet<number>} */
export const readonlySet = new Set([1]);
export const weakMap = new WeakMap([[key, { value: 1 }]]);
export const weakSet = new WeakSet([key]);
