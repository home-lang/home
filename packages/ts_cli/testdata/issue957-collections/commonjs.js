const key = { id: 1 };

exports.map = new Map([["ready", 1]]);
/** @type {ReadonlyMap<string, number>} */
const readonlyMap = new Map([["ready", 1]]);
exports.readonlyMap = readonlyMap;
exports.set = new Set([1]);
/** @type {ReadonlySet<number>} */
const readonlySet = new Set([1]);
exports.readonlySet = readonlySet;
exports.weakMap = new WeakMap([[key, { value: 1 }]]);
exports.weakSet = new WeakSet([key]);
