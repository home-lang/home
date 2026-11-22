declare const readonlyNumbers: readonly number[];
declare const mutableNumbers: number[];
declare const indexedOnly: { readonly length: number; readonly [index: number]: number };
declare const fullShape: {
  readonly length: number;
  readonly [index: number]: number;
  join(separator?: string): string;
  slice(start?: number, end?: number): number[];
};

readonlyNumbers.concat(indexedOnly);
mutableNumbers.concat(indexedOnly);
readonlyNumbers.concat([1, 2], ["x"]);
mutableNumbers.concat([1, 2], ["x"]);

readonlyNumbers.concat(fullShape);
mutableNumbers.concat(fullShape);
readonlyNumbers.concat([1, 2], 3);
mutableNumbers.concat([1, 2], 3);
