const values = [1, 2, 3].values();
values.toArray();
values.map((value) => value + 1);

interface AuthoredIterator extends IterableIterator<number> {
  toArray(): number[];
}
declare const authored: AuthoredIterator;
const authoredValues: number[] = authored.toArray();
void authoredValues;
