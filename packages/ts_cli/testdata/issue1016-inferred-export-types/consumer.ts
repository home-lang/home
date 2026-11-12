import {
  map, set, promise, pattern, date, error, big, negativeBig, tuple,
  identity, add, later, pair, make, overload, arrow, box,
} from "./owner";

// Each of these used to be `any`, so none was reported.
const v1: symbol = map;
const v2: symbol = set;
const v3: symbol = promise;
const v4: symbol = pattern;
const v5: symbol = date;
const v6: symbol = error;
const v7: symbol = big;
const v8: symbol = tuple;
const v9: symbol = box;

// The literal types survive the import.
const l1: 6n = big;
const l2: 5n = negativeBig;
const l3: [1, "a"] = tuple;
const l4: readonly [2, "a"] = tuple;

// A call sees the inferred signature.
const c1: string = identity(5);
const c2: string = add(1, 2);
add("x", 2);
const c3: number = later();
const c4: [1, "a"] = pair();
const c5: { k: string } = make();
const c6: number = overload("s");
const c7: symbol = arrow();
void [v1, v2, v3, v4, v5, v6, v7, v8, v9, l1, l2, l3, l4, c1, c2, c3, c4, c5, c6, c7];
export {};
