interface ReadonlyIndexed {
  readonly length: number;
  readonly [index: number]: number;
}

declare const indexed: ReadonlyIndexed;
declare const readonlyValues: readonly number[];
declare const mutableValues: number[];

indexed.join();
indexed.slice();
indexed.push(1);

const joined: string = readonlyValues.join();
const sliced: number[] = readonlyValues.slice();
const pushed: number = mutableValues.push(1);
void [joined, sliced, pushed];
