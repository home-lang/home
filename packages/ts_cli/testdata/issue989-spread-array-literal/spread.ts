declare const nums: number[];
declare const strs: string[];
declare const iter: Iterable<number>;
declare const setOf: Set<number>;
declare function take(items: string[]): void;

// An array literal made only of spreads of non-tuple arrays has the spread's
// own array type, so the whole value is reported against the target.
const onlySpread: string[] = [...nums];
const twoSpreads: string[] = [...nums, ...nums];
const unionSpread: string[] = [...nums, ...strs];
const iterableSpread: string[] = [...iter];
const setSpread: string[] = [...setOf];
const assertedSpread: string[] = [...(nums as number[])];
const readonlyTarget: readonly string[] = [...nums];
take([...nums]);

// A fixed element, a spread of a literal, or a tuple spread each keep the
// positional reporting.
const leadingElement: string[] = [1, ...nums];
const trailingElement: string[] = [...nums, 1];
const literalSpread: string[] = [...[1, 2], ...nums];
const literalSpreadLast: string[] = [...nums, ...[1]];
const plainElement: string[] = [nums[0]];
take([1, ...nums]);

// Clean controls: a matching element type, an empty literal, and a string.
const matching: number[] = [...nums];
const empty: string[] = [];
const chars: string[] = [..."ab"];

void onlySpread;
void twoSpreads;
void unionSpread;
void iterableSpread;
void setSpread;
void assertedSpread;
void readonlyTarget;
void leadingElement;
void trailingElement;
void literalSpread;
void literalSpreadLast;
void plainElement;
void matching;
void empty;
void chars;
