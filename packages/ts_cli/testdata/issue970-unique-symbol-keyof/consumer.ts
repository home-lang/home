import { key, type Box } from './owner';

declare const box: Box;
declare const other: unique symbol;

const validKey: keyof Box = key;
const invalidKey: keyof Box = other;
const value: number = box[key];
const invalidValue = box[other];
declare const readonlyBox: Readonly<Box>;
const readonlyValue: number = readonlyBox[key];
const invalidReadonlyValue = readonlyBox[other];
void [validKey, invalidKey, value, invalidValue, readonlyValue, invalidReadonlyValue];
