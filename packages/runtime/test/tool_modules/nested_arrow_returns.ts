const pair = (): Array<Array<number>> => [[7]];
const triple = (): Array<Array<Array<number>>> => { return [[[8]]]; };
const object = (): { values: Array<Array<number>> } => ({ values: [[9]] });
const factory = (): (() => Array<Array<number>>) => () => [[10]];
type Callback = () => number;
const mixed = async (): Promise<Awaited<ReturnType<Callback>> | undefined> => 11;
const spaced = (): Array<Array<number> > => [[12]];

const results = [
  pair()[0][0],
  triple()[0][0][0],
  object().values[0][0],
  factory()()[0][0],
  await mixed(),
  spaced()[0][0],
];
if (JSON.stringify(results) !== "[7,8,9,10,11,12]") {
  throw new Error("Nested generic arrow return execution changed");
}
// Expression shifts retain their original operator tokens.
if ((256 >> 2) !== 64 || (-1 >>> 28) !== 15) {
  throw new Error("Generic closer lookahead changed expression shifts");
}
