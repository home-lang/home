const values = [1, 2, 3].values();
const result = values.next();
if (result.done) {
  const completed: undefined = result.value;
  void completed;
} else {
  const yielded: number = result.value;
  void yielded;
}

declare const explicit: IteratorObject<number, string, unknown>;
const explicitResult = explicit.next();
if (explicitResult.done) {
  const completed: string = explicitResult.value;
  void completed;
} else {
  const yielded: number = explicitResult.value;
  void yielded;
}
