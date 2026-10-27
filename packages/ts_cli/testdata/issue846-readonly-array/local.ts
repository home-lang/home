const readonlyValues: readonly number[] = [1, 2];
readonlyValues.push(4);
readonlyValues[0] = 3;
const forbidden: keyof readonly number[] = 'push';
const mapped: number[] = readonlyValues.map(value => value + 1);
const sliced: number[] = readonlyValues.slice();
void [forbidden, mapped, sliced];
