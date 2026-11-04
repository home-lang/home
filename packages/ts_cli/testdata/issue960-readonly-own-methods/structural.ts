interface Arrayish extends ReadonlyArray<number> {
  tag: string;
}

interface ReadonlyIndexed {
  readonly length: number;
  readonly [index: number]: number;
}

declare const extendsArray: Arrayish;
declare const indexed: ReadonlyIndexed;

const inherited: ReadonlyArray<number> = extendsArray;
const missingMethods: ReadonlyArray<number> = indexed;

declare const nested: readonly Arrayish[];
const flattened: number[] = nested.flat();

declare const indexedNested: readonly ReadonlyIndexed[];
const unflattened: ReadonlyIndexed[] = indexedNested.flat();
const wrongElement: number[] = indexedNested.flat();
