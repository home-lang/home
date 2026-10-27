import { readonlyValues, values } from './owner.js';

const reversed: number[] = readonlyValues.toReversed();
const spliced: number[] = readonlyValues.toSpliced(0, 1, 3);
const shortened: number[] = readonlyValues.toSpliced(1);
const replaced: number[] = readonlyValues.with(0, 3);
const text: string = readonlyValues.toString();
const localized: string = readonlyValues.toLocaleString();
const mutableReversed: number[] = values.toReversed();
const mutableSpliced: number[] = values.toSpliced(0, 1, 3);
const mutableReplaced: number[] = values.with(0, 3);

readonlyValues.with(0, 'wrong');
readonlyValues.toSpliced(0, 1, 'wrong');
const wrongResult: string = readonlyValues.toReversed();
void [reversed, spliced, shortened, replaced, text, localized, mutableReversed, mutableSpliced, mutableReplaced, wrongResult];
