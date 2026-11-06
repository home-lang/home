const values: number[] = [1, 2, 3];
const it = values.values();
it.take();
it.map();
it.bogus();
it.reduce();
const wrongTag: number = it[Symbol.toStringTag];
void wrongTag;
