declare global {
  interface ReadonlyArray<T> {
    firstOrUndefined(): T | undefined;
  }
}
export {};

const readonlyValues: readonly number[] = [1, 2];
const mutableValues: number[] = [1, 2];
const firstReadonly: number | undefined = readonlyValues.firstOrUndefined();
const firstMutable: number | undefined = mutableValues.firstOrUndefined();
readonlyValues.push(3);
void [firstReadonly, firstMutable];
