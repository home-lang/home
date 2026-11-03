const values: number[] = [1, 2, 3];
const strings: string[] = values.values()
  .filter((value) => value > 1)
  .map((value) => value.toString())
  .toArray();
values.toArray();
void strings;
