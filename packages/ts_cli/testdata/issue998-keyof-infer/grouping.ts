declare function fromArray<T>(keys: (keyof T)[]): T;
const array = fromArray(["arrayA", "arrayB"]);
array.arrayA;
array.arrayB;
array.missing;

declare function fromRest<T>(...keys: (keyof T)[]): T;
const rest = fromRest("restA", "restB");
rest.restA;
rest.restB;
rest.missing;

const spreadKeys = ["spreadA", "spreadB"] as const;
const spread = fromRest(...spreadKeys);
spread.spreadA;
spread.spreadB;
spread.missing;

declare function fromTuple<T>(keys: readonly [keyof T, keyof T]): T;
const tuple = fromTuple(["tupleA", "tupleB"]);
tuple.tupleA;
tuple.tupleB;
tuple.missing;

declare function fromConditional<T>(key: keyof T): T;
declare const condition: boolean;
const conditional = fromConditional(condition ? "left" : "right");
conditional.left;
conditional.right;
conditional.missing;

declare function constrained<T extends { present: number }>(...keys: (keyof T)[]): T;
constrained(...(["missing"] as const));
fromRest<{ present: number }>(...(["missing"] as const));

declare function withValue<T>(value: T, ...keys: (keyof T)[]): T;
withValue({ present: 1 }, ...(["missing"] as const));
