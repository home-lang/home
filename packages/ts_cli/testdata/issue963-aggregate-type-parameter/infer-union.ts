type UnwrapNullable<T> = T extends infer U | null ? U : never;

type NumberResult = UnwrapNullable<number>;
const good: NumberResult = 42;
const wrong: NumberResult = 'x';

type NullResult = UnwrapNullable<null>;
const nullGood: NullResult = null;
void [good, wrong, nullGood];
