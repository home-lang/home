const as = 1, satisfies = 2, using = 3, accessor = 4, override = 5, readonly = 6, asserts = 7, infer = 8, keyof = 9, unique = 10, is = 11, abstract = 12;
const values = {
  as: as,
  satisfies: satisfies,
  using: using,
  accessor: accessor,
  override: override,
  readonly: readonly,
  asserts: asserts,
  infer: infer,
  keyof: keyof,
  unique: unique,
  is: is,
  abstract: abstract,
};
const array = [as, satisfies, using, accessor, override, readonly, asserts, infer, keyof, unique, is, abstract];
const shorthand = {as, satisfies, using, accessor, override, readonly, asserts, infer, keyof, unique, is, abstract};
const identity = (as) => as;
for (let i = 0; i < array.length; i++) {
  const name = Object.keys(values)[i];
  if (array[i] !== i + 1 || values[name] !== i + 1 || shorthand[name] !== i + 1 || identity(array[i]) !== i + 1) throw new Error("contextual identifier value");
}
console.log("OK contextual identifier object values, arrays, shorthand and arrows");
