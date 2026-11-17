type RO<T> = { readonly [K in keyof T]: T[K] };
declare function mutate(items: number[]): void;
declare const builtIn: Readonly<number[]>;
declare const mapped: RO<number[]>;

builtIn.push(1);
builtIn[0] = 2;
mutate(builtIn);
const builtInRead: readonly number[] = builtIn;

mapped.push(1);
mapped[0] = 2;
mutate(mapped);
const mappedRead: readonly number[] = mapped;

declare const tuple: Readonly<[number, string]>;
tuple[0] = 1;
const mutableTuple: [number, string] = tuple;
const readonlyTuple: readonly [number, string] = tuple;

void builtInRead;
void mappedRead;
void mutableTuple;
void readonlyTuple;
export {};
