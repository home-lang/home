declare const readonlyValues: readonly number[];
declare const readonlyPair: readonly [number, string];
declare const values: number[];

declare function takesMutable(items: number[]): void;
declare function takesReadonly(items: readonly number[]): void;
declare function takesMutablePair(pair: [number, string]): void;
declare function takesGeneric<T>(items: T[]): T;

takesMutable(readonlyValues);
takesMutable([...readonlyValues]);
takesMutable(values);
takesReadonly(readonlyValues);
takesReadonly(values);
takesMutablePair(readonlyPair);
takesMutablePair([1, "one"]);
const inferred: number = takesGeneric(readonlyValues);
const sorted: number[] = readonlyValues.toSorted();
const joined: string = readonlyValues.join(",");
void inferred;
void sorted;
void joined;
