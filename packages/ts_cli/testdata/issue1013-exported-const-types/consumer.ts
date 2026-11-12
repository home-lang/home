import {
  annotated, sum, call, object, fixed, negativeMember, not, negative, literal, text, list,
  parenthesized, template, arrow, nestedList, nestedObject, computedMember, nothing, mutable,
  mutableNegative, alias, map, set, promise, box,
} from "./owner";

// Each import used to be `any`, so none of these was reported.
const s1: symbol = annotated;
const s2: symbol = sum;
const s3: symbol = call;
const s4: symbol = object;
const s5: symbol = fixed;
const s6: symbol = negativeMember;
const s7: symbol = not;
const s8: symbol = negative;
const s9: symbol = literal;
const s10: symbol = text;
const s11: symbol = list;
const s12: symbol = parenthesized;
const s13: symbol = template;
const s14: symbol = arrow;
const s15: symbol = nestedList;
const s16: symbol = nestedObject;
const s17: symbol = computedMember;
const s18: symbol = nothing;
const s19: symbol = mutable;
const s20: symbol = mutableNegative;
const s21: symbol = alias;
const s22: symbol = map;
const s23: symbol = set;
const s24: symbol = promise;
const s25: symbol = box;

// A const keeps its literal type across the import; a `let` widens.
const l1: 5 = negative;
const l2: 6 = fixed;
const l4: 6 = alias;
const l5: -5 = mutableNegative;
void [s1, s2, s3, s4, s5, s6, s7, s8, s9, s10, s11, s12, s13, s14, s15, s16, s17, s18, s19, s20, s21, s22, s23, s24, s25, l1, l2, l4, l5];
export {};
