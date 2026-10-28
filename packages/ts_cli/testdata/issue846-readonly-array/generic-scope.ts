import { readonlyValues, values } from './owner.js';

type Alias<U> = number;
const localValues: readonly number[] = [1, 2];

const imported: number[] = readonlyValues.flatMap(() => readonlyValues);
const mutable: number[] = values.flatMap(() => readonlyValues);
const local: number[] = localValues.flatMap(() => localValues);
const wrong: string[] = readonlyValues.flatMap(() => readonlyValues);

void [imported, mutable, local, wrong];
