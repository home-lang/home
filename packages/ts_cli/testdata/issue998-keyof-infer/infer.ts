declare function fromKeys<T>(first: keyof T, second: keyof T): T;
const keys = fromKeys("alpha", "beta");
keys.alpha;
keys.beta;
keys.missing;

declare function fromValue<T>(value: T, key: keyof T): T;
const value = fromValue({ present: 1 }, "present");
value.present;
value.missing;
