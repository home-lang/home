declare const readonlyValues: readonly number[];
declare const mutableValues: number[];
declare const other: unique symbol;
declare const ordinary: symbol;

const readonlyKey: keyof readonly number[] = Symbol.unscopables;
const mutableKey: keyof number[] = Symbol.unscopables;

const wrongReadonlyUnique: keyof readonly number[] = other;
const wrongMutableUnique: keyof number[] = other;
const wrongReadonlyOrdinary: keyof readonly number[] = ordinary;
const wrongMutableOrdinary: keyof number[] = ordinary;

void [readonlyValues, mutableValues, readonlyKey, mutableKey,
  wrongReadonlyUnique, wrongMutableUnique, wrongReadonlyOrdinary, wrongMutableOrdinary];
