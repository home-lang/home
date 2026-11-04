function read<T extends number[]>(values: T | readonly string[]) {
  for (const value of values) {
    const onlyString: string = value;
    void onlyString;
  }
}

function readStringOrArray<T extends number[]>(values: T | string) {
  for (const value of values) {
    const onlyString: string = value;
    void onlyString;
  }
}
