declare const nums: number[];
declare function takeObj(x: { v: [string, number] }): void;
declare function takeTupleArr(x: [string, number][]): void;
declare function takeTuple(x: [string, number]): void;
declare function takeArr(x: string[]): void;
declare function takeNested(x: { v: { w: [string, number] } }): void;

// A tuple target reached through a property or an element reported twice:
// the element, and the argument or the property comparing the widened
// literal against the tuple.
takeObj({ v: [1, 2] });
takeTupleArr([[1, 2]]);
takeNested({ v: { w: [1, 2] } });

// A direct tuple or array argument already reported once.
takeTuple([1, 2]);
takeArr([1]);

// The same literals in a declaration position, which already reported once.
const assigned: { v: [string, number] } = { v: [1, 2] };
const inArray: [string, number][] = [[1, 2]];
const direct: [string, number] = [1, 2];
const plain: string[] = [1];

// With no diagnostic inside the argument, the argument itself still owns one:
// an all-spread literal has the spread's array type, and a wholly wrong shape
// has nothing inner to report.
takeArr([...nums]);
takeTuple(nums);
takeObj({ v: nums });

// Clean controls.
takeObj({ v: ['x', 2] });
takeTupleArr([['x', 2]]);
takeTuple(['x', 2]);
takeArr(['x']);

void assigned;
void inArray;
void direct;
void plain;
