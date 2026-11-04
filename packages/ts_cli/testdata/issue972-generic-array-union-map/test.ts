function read<T extends number[]>(values: T | readonly string[]) {
  const mapped = values.map((value, index, array) => {
    const element: string | number = value;
    const position: number = index;
    const receiver: number[] | readonly string[] = array;
    const onlyString: string = value;
    const onlyMutable: number[] = array;
    void element;
    void position;
    void receiver;
    void onlyString;
    void onlyMutable;
    return value;
  });
  const onlyNumber: number = mapped[0];
  void onlyNumber;
}
