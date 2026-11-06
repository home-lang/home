const values: number[] = [1, 2, 3];
const it = values.values();

const mapped: string[] = it.map((value) => value.toString()).toArray();
const filtered: number[] = it.filter((value) => value > 1).toArray();
const taken: number[] = it.take(2).toArray();
const dropped: number[] = it.drop(1).toArray();
const flat: string[] = it.flatMap((value) => [value.toString()]).toArray();
const reduced: number = it.reduce((acc, value) => acc + value);
const reducedInit: number = it.reduce((acc, value) => acc + value, 10);
const reducedOther: string = it.reduce((acc, value) => acc + value.toString(), "");
const found: number | undefined = it.find((value) => value > 1);
const anyMatch: boolean = it.some((value) => value > 1);
const allMatch: boolean = it.every((value) => value > 1);
const tag: string = it[Symbol.toStringTag];
it.forEach((value) => { void value; });
const forEachResult: void = it.forEach((value) => { void value; });

void mapped; void filtered; void taken; void dropped; void flat;
void reduced; void reducedInit; void reducedOther; void found;
void anyMatch; void allMatch; void tag; void forEachResult;
