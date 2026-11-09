declare const iterable: Iterable<string>;
declare const nums: number[];

// Explicit type arguments instantiate the binders: `of<T>`, `from<T>` and
// `from<T, U>`, where `U` defaults to `T`.
const ofExplicit: number[] = Array.of<number>(1, 2);
const fromExplicit: number[] = Array.from<number>(nums);
const fromMappedExplicit: number[] = Array.from<string, number>(iterable, (value) => value.length);
const ofExplicitWrong: string[] = Array.of<number>(1, 2);
const fromExplicitWrong: string[] = Array.from<number>(nums);

// The trailing parameters stay optional through instantiation, and the
// mapped callback still receives the instantiated element type.
Array.from<string, number>(iterable, (value) => value.length, {});
Array.from<string, number>(iterable, (value) => value.bogus.length);

void ofExplicit;
void fromExplicit;
void fromMappedExplicit;
void ofExplicitWrong;
void fromExplicitWrong;
