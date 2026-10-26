interface InvalidIndexes<T> {
  [key: string]: T;
  [index: number]: () => T;
}
