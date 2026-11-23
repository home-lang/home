declare function fromKey<T>(key: keyof T): T;

const numeric = fromKey(42);
numeric[42];
numeric["42"];
numeric.missing;

declare const key: unique symbol;
const symbolic = fromKey(key);
symbolic[key];
symbolic.missing;

declare const choose: boolean;
const mixed = fromKey(choose ? 42 : "name");
mixed[42];
mixed.name;
mixed.missing;
