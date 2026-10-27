const readonlyValues: readonly number[] = [1, 2];
readonlyValues.map((value, index, array) => {
  array.push(value);
  const mutable: number[] = array;
  void mutable;
  return value + index;
});
