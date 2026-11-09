declare const iterable: Iterable<string>;
declare const nums: number[];
declare const setOfNums: Set<number>;

// `of<T>(...items: T[]): T[]` is a rest signature: every arity is legal and
// the element type is the first argument's, widened.
const ofThree: string = Array.of(1, 2, 3);
const ofMixed: string = Array.of(1, "a");
const ofEmpty: string = Array.of();
const ofSpread: string = Array.of(...nums);
const ofNested: string = Array.of(nums);

// `from<T>(src): T[]` resolves the element through the array-like numeric
// index, the iteration protocol, and an array-like object's numeric members.
const fromIterable: number = Array.from(iterable);
const fromArray: string = Array.from(nums);
const fromSet: string = Array.from(setOfNums);
const fromString: number = Array.from("abc");
const fromArrayLike: string = Array.from({ length: 2, 0: 1, 1: 2 });

// `from<T, U>(src, mapfn): U[]` yields the callback's result, and the
// callback's parameters are the element type and the index.
const fromMapped: string = Array.from(iterable, (value) => value.length);
const fromIndex: string = Array.from(iterable, (value, index) => index);
const fromThisArg: string = Array.from(iterable, function (value) {
    return value.length;
}, {});
const fromLiteral: number = Array.from(iterable, () => "x");
Array.from(iterable, (value) => value.bogus);
Array.from(nums, (value) => value.toFixed(2));

void ofThree;
void ofMixed;
void ofEmpty;
void ofSpread;
void ofNested;
void fromIterable;
void fromArray;
void fromSet;
void fromString;
void fromArrayLike;
void fromMapped;
void fromIndex;
void fromThisArg;
void fromLiteral;
