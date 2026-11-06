const values: number[] = [1, 2, 3];
const it = values.values();
declare function isEven(value: number): value is 2 | 4;
const evens: (2 | 4)[] = it.filter(isEven).toArray();
const foundEven: 2 | 4 | undefined = it.find(isEven);
const inline: 2[] = it.filter((value): value is 2 => value === 2).toArray();
void evens; void foundEven; void inline;
