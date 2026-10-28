import { readonlyValues, values } from './owner.js';

const flattened: number[] = readonlyValues.flatMap(() => readonlyValues);
const flattenedMutable: number[] = values.flatMap(() => readonlyValues);
const scalar: number[] = readonlyValues.flatMap(value => value + 1);
const mixed: number[] = readonlyValues.flatMap(value => value > 1 ? readonlyValues : value);
const callbackArray: number[] = readonlyValues.flatMap((value, index, array) => {
  void index;
  array.push(value);
  return value;
});
const wrong: string[] = readonlyValues.flatMap(() => readonlyValues);
const explicit: number[] = readonlyValues.flatMap<number>(() => readonlyValues);

void [flattened, flattenedMutable, scalar, mixed, callbackArray, wrong, explicit];
