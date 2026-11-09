declare const nums: number[];

// A synthesized result is a real array: it satisfies the readonly array
// surface, not only `{ length, [n: number] }`.
const readonlyOf: readonly number[] = Array.of(1);
const readonlyFrom: ReadonlyArray<number> = Array.from(nums);
const readonlyAny: readonly any[] = Array.of(1);
const mutableOf: number[] = Array.of(1);
const concatenated: number[] = Array.of(1).concat(nums);
const joined: string = Array.from(nums).join(",");

// Argument inference outranks the contextual return type, but a literal
// contextual element keeps the argument's literal type.
const literalElement: 1[] = Array.of(1);
const widenedElement: number[] = Array.of(1);
const unionElement: (string | number)[] = Array.of(1, "a");

// A source whose element type is not statically known keeps `any[]`.
declare const loose: any;
const fromLoose: number[] = Array.from(loose);
const fromLooseString: string[] = Array.from(loose);

void readonlyOf;
void readonlyFrom;
void readonlyAny;
void mutableOf;
void concatenated;
void joined;
void literalElement;
void widenedElement;
void unionElement;
void fromLoose;
void fromLooseString;
