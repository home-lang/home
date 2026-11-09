declare const nums: number[];
declare const ro: readonly string[];
declare const pair: [number, string];
declare const setOf: Set<number>;
declare const mapOf: Map<string, number>;

// `entries()` yields `[number, T]`, a tuple of exactly two elements. An
// unrecorded tuple renders — and relates — with a trailing rest element
// whose type is the union of its own members.
for (const entry of nums.entries()) {
    const wrong: never = entry;
    void wrong;
}
for (const entry of ro.entries()) {
    const wrong: never = entry;
    void wrong;
}
for (const entry of pair.entries()) {
    const wrong: never = entry;
    void wrong;
}

// The iterator's own display name carries the yielded tuple, so it has to be
// recorded before that name is built.
const iterator: never = nums.entries();
const readonlyIterator: never = ro.entries();
const spread: never = [...nums.entries()];

// `Set<T>` iterates `[T, T]`, the same shape `Map<K, V>` already had right.
const setEntries: never = setOf.entries();
const mapEntries: never = mapOf.entries();

// The positional element types stay distinct and destructure.
for (const [index, value] of nums.entries()) {
    const badIndex: string = index;
    const badValue: string = value;
    void badIndex;
    void badValue;
}
const keys: never = nums.keys();
const values: never = nums.values();

void iterator;
void readonlyIterator;
void spread;
void setEntries;
void mapEntries;
void keys;
void values;
