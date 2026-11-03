declare const readonlyValues: readonly number[];
declare const mutableValues: number[];

const readonlyStringKey: keyof readonly number[] = 'toString';
const readonlyLocaleKey: keyof readonly number[] = 'toLocaleString';
const mutableStringKey: keyof number[] = 'toString';
const mutableLocaleKey: keyof number[] = 'toLocaleString';
const invalidReadonlyKey: keyof readonly number[] = 'push';
const invalidMutableKey: keyof number[] = 'missingMethod';

const readonlyString: string = readonlyValues.toString();
const readonlyLocale: string = readonlyValues.toLocaleString();
const mutableString: string = mutableValues.toString();
const mutableLocale: string = mutableValues.toLocaleString();
const invalidResult: number = readonlyValues.toLocaleString();

void [readonlyStringKey, readonlyLocaleKey, mutableStringKey, mutableLocaleKey];
void [invalidReadonlyKey, invalidMutableKey, readonlyString, readonlyLocale];
void [mutableString, mutableLocale, invalidResult];
