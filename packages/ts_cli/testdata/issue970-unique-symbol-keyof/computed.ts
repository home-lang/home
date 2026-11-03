declare const first: unique symbol;
declare const second: unique symbol;

interface Box {
  [first]: number;
  readonly [second]?: string;
  plain: boolean;
}

declare const box: Box;
const firstKey: keyof Box = first;
const secondKey: keyof Box = second;
const plainKey: keyof Box = 'plain';
const wrongKey: keyof Box = Symbol.unscopables;

const firstValue: number = box[first];
const secondValue: string | undefined = box[second];
const invalidValue = box[Symbol.unscopables];
void [firstKey, secondKey, plainKey, wrongKey, firstValue, secondValue, invalidValue];
